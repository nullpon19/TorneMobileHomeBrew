/// EPG (programme guide) tests (plan 21 / 24): the ARIB STD-B24
/// decoder, the EPG / logo payload parsers, the acquisition
/// request format at the service boundary, and the guide screen.
///
/// All fixtures are synthetic, built in this file: no broadcast
/// programme data is stored in the repository.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/epg_screen.dart';
import 'package:tmhb/ui/live_screen.dart';

// ---------------------------------------------------------------------------
// Synthetic EPG plaintext builder
// ---------------------------------------------------------------------------

const _channel = Channel(
  broadcastingType: 2,
  networkId: 0x1111,
  transportStreamId: 0x2222,
  serviceId: 0x3333,
  serviceType: 1,
  channelNumber: 1,
  serviceName: 'テスト局',
);

/// B24 bytes of 「テレビ」 (LS3R + GR katakana), verified against
/// the reference decoder.
const _titleTv = [0x1b, 0x7c, 0xc6, 0xec, 0xd3];

/// B24 bytes of 「番組内容」 (GL kanji pairs).
const _labelContent = [0x48, 0x56, 0x41, 0x48, 0x46, 0x62, 0x4d, 0x46];

/// B24 bytes of 「番組」.
const _valueContent = [0x48, 0x56, 0x41, 0x48];

Uint8List _descriptor(int tag, List<int> body) =>
    Uint8List.fromList([tag, body.length, ...body]);

Uint8List _shortEvent(List<int> name, List<int> text) {
  return _descriptor(0x4d, [
    0x6a, 0x70, 0x6e, // 'jpn'
    name.length, ...name,
    text.length, ...text,
  ]);
}

Uint8List _extendedEvent(List<int> label, List<int> value) {
  final items = <int>[
    label.length, ...label,
    value.length, ...value,
  ];
  return _descriptor(0x4e, [
    0x00, // descriptor_number 0, last 0
    0x6a, 0x70, 0x6e,
    items.length, ...items,
    0, // text length
  ]);
}

Uint8List _event({
  required int id,
  required int mjd,
  required List<int> timeBcd,
  required List<int> durationBcd,
  List<int> descriptors = const [],
}) {
  final out = BytesBuilder();
  out.add([id >> 8, id & 0xff, mjd >> 8, mjd & 0xff]);
  out.add(timeBcd);
  out.add(durationBcd);
  out.add([descriptors.length >> 8, descriptors.length & 0xff]);
  out.add(descriptors);
  return out.toBytes();
}

/// CRC-32/MPEG-2, written independently of the parser's copy so
/// the fixture builder and the parser cross-check each other.
int _crc32Mpeg(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80000000) != 0
          ? ((crc << 1) ^ 0x04c11db7) & 0xffffffff
          : (crc << 1) & 0xffffffff;
    }
  }
  return crc;
}

/// One EIT section for the synthetic channel, in the real layout
/// (plan 22): 14-byte header, events, trailing CRC-32/MPEG-2.
Uint8List _section({
  required int tableId,
  required int sectionNumber,
  required List<int> eventsBytes,
}) {
  final out = BytesBuilder();
  final sectionLength = 11 + eventsBytes.length + 4;
  out.add([tableId]);
  out.add([0xb0 | ((sectionLength >> 8) & 0x0f), sectionLength & 0xff]);
  out.add([0x33, 0x33]); // +3 serviceId
  out.add([0xc1]); // +5 version 0, current
  out.add([sectionNumber, 0x3f]); // +6 section_number, last
  out.add([0x22, 0x22]); // +8 transportStreamId
  out.add([0x11, 0x11]); // +10 originalNetworkId
  out.add([0x3f, 0x50]); // +12 segment last, last table id
  out.add(eventsBytes);
  final crc = _crc32Mpeg(out.toBytes());
  out.add([(crc >> 24) & 0xff, (crc >> 16) & 0xff, (crc >> 8) & 0xff, crc & 0xff]);
  return out.toBytes();
}

/// Two events on 2026-11-16 (MJD 61360), carried the ARIB way:
/// a basic section (0x50) with the 0x4D/0x54 side and an extended
/// section (0x58) with the 0x4E side, listing the SAME events —
/// a titled 09:55-10:25 event and a no-information 10:25 event.
/// The parser must merge the copies into two guide events.
Uint8List syntheticPlaintext() {
  final ev1Basic = _event(
    id: 0x101,
    mjd: 61360,
    timeBcd: [0x09, 0x55, 0x00],
    durationBcd: [0x00, 0x30, 0x00],
    descriptors: [
      ..._shortEvent(_titleTv, const []),
      ..._descriptor(0x54, [0x70]),
    ],
  );
  final ev1Extended = _event(
    id: 0x101,
    mjd: 61360,
    timeBcd: [0x09, 0x55, 0x00],
    durationBcd: [0x00, 0x30, 0x00],
    descriptors: [
      ..._extendedEvent(_labelContent, _valueContent),
    ],
  );
  final ev2 = _event(
    id: 0x102,
    mjd: 61360,
    timeBcd: [0x10, 0x25, 0x00],
    durationBcd: [0x00, 0x05, 0x00],
  );
  return Uint8List.fromList([
    ..._section(
        tableId: 0x50, sectionNumber: 32, eventsBytes: [...ev1Basic, ...ev2]),
    ..._section(
        tableId: 0x58,
        sectionNumber: 32,
        eventsBytes: [...ev1Extended, ...ev2]),
  ]);
}

/// Wraps a plaintext the way the device does: zlib, then XOR.
List<int> wrapEpgResponse(List<int> plain) {
  final zipped = ZLibEncoder().convert(plain);
  return zipped.map((b) => b ^ epgXorKey).toList();
}

/// Builds a synthetic EPG version table (plan 24): a 12-byte
/// header, one 144-byte record per service (triple + 0xc000 flags
/// + zeroed version blocks) and the 8-byte footer.
List<int> versionTableOf(List<EpgServiceRef> services) {
  final out = BytesBuilder();
  out.add(List.filled(12, 0));
  for (final s in services) {
    out.add([
      s.networkId >> 8, s.networkId & 0xff,
      s.transportStreamId >> 8, s.transportStreamId & 0xff,
      s.serviceId >> 8, s.serviceId & 0xff,
      0xc0, 0x00,
    ]);
    out.add(List.filled(136, 0));
  }
  out.add(List.filled(8, 0));
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// Synthetic logo file builder
// ---------------------------------------------------------------------------

Uint8List _logoRecord(int serviceId, List<int>? png) {
  final body = BytesBuilder();
  final total = 20 + (png?.length ?? 0);
  body.add([
    0, 0, total >> 8, total & 0xff, // decompressed length
    0, 0, 1, 0, 0, 0x2a, // variant / index bytes
    0, 0, 0, 0,
    serviceId >> 8, serviceId & 0xff,
    0, 0,
    (png?.length ?? 0) >> 8, (png?.length ?? 0) & 0xff,
  ]);
  if (png != null) body.add(png);
  return body.toBytes();
}

List<int> syntheticLogoFile() {
  final png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3];
  final out = BytesBuilder();
  out.add(ZLibEncoder().convert([7, 225, 10, 24, 11, 10, 28, 0])); // header
  out.add(ZLibEncoder().convert(_logoRecord(0x3333, png)));
  out.add(ZLibEncoder().convert(_logoRecord(0x4444, null)));
  return out.toBytes().map((b) => b ^ epgXorKey).toList();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ARIB STD-B24 decoder', () {
    test('GL kanji pairs', () {
      expect(decodeAribB24(_labelContent), '番組内容');
    });

    test('SS3 single-shifts to the katakana set for one character', () {
      expect(decodeAribB24([0x1d, 0x46]), 'テ');
    });

    test('LS3R invokes G3 (katakana) into GR', () {
      expect(decodeAribB24(_titleTv), 'テレビ');
    });

    test('additional symbols decode to the enclosed ideograph', () {
      expect(decodeAribB24([0x1b, 0x24, 0x3b, 0x7a, 0x56]), '🈑');
    });

    test('alnum is fullwidth at the standard size', () {
      expect(decodeAribB24([0x0e, 0x41, 0x31, 0x0f]), 'Ａ１');
    });

    test('GR defaults to the hiragana set', () {
      expect(decodeAribB24([0xa4]), 'い');
    });

    test('undecodable input degrades, never throws', () {
      expect(decodeAribB24([0x1b]), '');
      expect(decodeAribB24([0x21]), ''); // truncated pair: dropped
      expect(decodeAribB24([0x7e, 0x7e]), '□'); // unmapped cell
    });
  });

  group('broadcast text normalisation (EPG path)', () {
    test('enclosed ideograph marks become bracket labels', () {
      expect(normalizeBroadcastText('ニュース🈑'), 'ニュース[字]');
      expect(normalizeBroadcastText('番組🈟🈞'), '番組[新][再]');
    });
  });

  group('X-DTVToken over binary bodies', () {
    test('known values (SHA-1 over PIN + path + body[:256])', () {
      final body = [
        for (var i = 0; i < 256; i++) i,
        for (var i = 0; i < 44; i++) i,
      ];
      expect(
        TokenProvider.computeTokenBytes('58daf0', '/chEpg/EPGGet', body),
        'bMewukHcBeDzR98CFaWM5QaernU=',
      );
      expect(
        TokenProvider.computeTokenBytes('58daf0', '/chEpg/EPGGet', const []),
        'Xqt+rPF+cp7Umm93PIotmL7gZ4w=',
      );
    });
  });

  group('CRC-32/MPEG-2', () {
    test('known-answer vector', () {
      expect(crc32Mpeg('123456789'.codeUnits), 0x0376e6e7);
    });
  });

  group('EPG plaintext parser', () {
    test('parses sections, merges basic/extended copies, JST times', () {
      final guide = parseEpgGuide(
        syntheticPlaintext(),
        const [_channel],
        broadcastingType: 2,
      );
      expect(guide.services, hasLength(1));
      final events = guide.services.single.events;
      expect(events, hasLength(2));

      final ev = events[0];
      expect(ev.eventId, 0x101);
      // 2026-11-16 09:55 JST = 00:55 UTC.
      expect(ev.start, DateTime.utc(2026, 11, 16, 0, 55));
      expect(ev.duration, const Duration(minutes: 30));
      expect(ev.title, 'テレビ');
      expect(ev.description, '番組');
      expect(ev.genreLevel1, 7);
      expect(ev.genreLevel2, 0);

      expect(events[1].title, isNull);
      expect(guide.eventCount, 2);
      expect(guide.from, DateTime.utc(2026, 11, 16, 0, 55));
    });

    test('a section with a broken CRC is ignored', () {
      final extra = _event(
        id: 0x103,
        mjd: 61360,
        timeBcd: [0x11, 0x00, 0x00],
        durationBcd: [0x00, 0x10, 0x00],
        descriptors: [..._shortEvent(_titleTv, const [])],
      );
      final corrupt = _section(
          tableId: 0x50, sectionNumber: 40, eventsBytes: extra);
      corrupt[20] ^= 0xff; // damage an event byte; the CRC no longer matches
      final plain = Uint8List.fromList([...syntheticPlaintext(), ...corrupt]);
      final guide = parseEpgGuide(plain, const [_channel],
          broadcastingType: 2);
      expect(guide.eventCount, 2);
    });

    test('an extended-only copy keeps its description, title stays null',
        () {
      final ev = _event(
        id: 0x104,
        mjd: 61360,
        timeBcd: [0x12, 0x00, 0x00],
        durationBcd: [0x00, 0x15, 0x00],
        descriptors: [..._extendedEvent(_labelContent, _valueContent)],
      );
      final plain = _section(
          tableId: 0x58, sectionNumber: 48, eventsBytes: ev);
      final guide = parseEpgGuide(plain, const [_channel],
          broadcastingType: 2);
      final event = guide.services.single.events.single;
      expect(event.title, isNull);
      expect(event.description, '番組');
    });

    test('response wrapping round-trips (XOR + zlib)', () {
      final plain = inflateEpgResponse(wrapEpgResponse(syntheticPlaintext()));
      expect(plain, syntheticPlaintext());
    });
  });

  group('channel logo parser', () {
    test('extracts PNGs by serviceId, skipping empty records', () {
      final logos = parseChannelLogos(syntheticLogoFile());
      expect(logos.keys, [0x3333]);
      expect(logos[0x3333]!.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    });
  });

  group('EPGGet request format (plan 24)', () {
    test('version table services are enumerated in table order', () {
      final table = versionTableOf(const [
        EpgServiceRef(0x1111, 0x2222, 0x3333),
        EpgServiceRef(0x4444, 0x5555, 0x6666),
      ]);
      expect(parseEpgVersionServices(table), const [
        EpgServiceRef(0x1111, 0x2222, 0x3333),
        EpgServiceRef(0x4444, 0x5555, 0x6666),
      ]);
    });

    test('enumeration stops at a record without the flags value', () {
      final table = versionTableOf(const [
        EpgServiceRef(0x1111, 0x2222, 0x3333),
        EpgServiceRef(0x4444, 0x5555, 0x6666),
      ]);
      table[12 + 144 + 6] = 0x00; // second record's flags high byte
      expect(parseEpgVersionServices(table),
          const [EpgServiceRef(0x1111, 0x2222, 0x3333)]);
      expect(parseEpgVersionServices(const []), isEmpty);
      expect(parseEpgVersionServices(List.filled(12, 0)), isEmpty);
    });

    test('request body layout: header count, records, bitmaps', () {
      final body = buildEpgGetBody(const [
        EpgServiceRef(0x1111, 0x2222, 0x3333),
        EpgServiceRef(0x4444, 0x5555, 0x6666),
      ]);
      expect(body.length, 8 + 24 * 2);
      expect(body.sublist(0, 8), [0, 0, 0, 0, 0, 2, 0, 0]);
      expect(body.sublist(8, 16),
          [0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0, 0]);
      expect(body.sublist(16, 32), List.filled(16, 0xff));
      expect(body.sublist(32, 40),
          [0x44, 0x44, 0x55, 0x55, 0x66, 0x66, 0, 0]);
    });

    test('bitmap sides and the linked-description flag are separate',
        () {
      const services = [EpgServiceRef(0x1111, 0x2222, 0x3333)];
      final basicOnly = buildEpgGetBody(services, extended: false);
      expect(basicOnly.sublist(16, 24), List.filled(8, 0xff));
      expect(basicOnly.sublist(24, 32), List.filled(8, 0));
      final extOnly = buildEpgGetBody(services, basic: false);
      expect(extOnly.sublist(16, 24), List.filled(8, 0));
      expect(extOnly.sublist(24, 32), List.filled(8, 0xff));
      final withLdt =
          buildEpgGetBody(services, includeLinkedDescriptions: true);
      expect(withLdt[8 + 6], 1);
      expect(buildEpgGetBody(services)[8 + 6], 0);
    });

    test('record count is a u16 BE in the header', () {
      final many = List.generate(300, (i) => EpgServiceRef(1, 2, i));
      final body = buildEpgGetBody(many);
      expect(body.sublist(4, 6), [0x01, 0x2c]);
      expect(body.length, 8 + 24 * 300);
    });
  });

  group('EPG acquisition (service boundary)', () {
    test('verinfo -> EPGGet request -> parsed guide; logos parsed',
        () async {
      final versionTable = versionTableOf(const [
        EpgServiceRef(0x1111, 0x2222, 0x3333),
      ]);
      late http.Request epgRequest;
      final client = MockClient((request) async {
        if (request.url.path == '/status/EPGVersionInfoGet') {
          return http.Response.bytes(versionTable, 200);
        }
        if (request.url.path == '/chEpg/EPGGet') {
          epgRequest = request;
          return http.Response.bytes(
              wrapEpgResponse(syntheticPlaintext()), 200);
        }
        if (request.url.path == '/chEpg/channelLogoDataGet') {
          return http.Response.bytes(syntheticLogoFile(), 200);
        }
        return http.Response('', 404);
      });
      final plain = WebApiTransport('192.0.2.1', client: client);
      final authed = WebApiTransport(
        '192.0.2.1',
        client: client,
        tokenProvider: const TokenProvider('58daf0'),
      );
      final service = WebApiEpgService(plain: plain, authed: authed);

      final guide = await service.getProgrammeGuide(2, const [_channel]);
      expect(guide.eventCount, 2);

      // The plan-24 request format: an 8-byte header (record
      // count u16 BE) and one 24-byte record for the version
      // table's service, both segment bitmaps all set;
      // application/binary, token over the raw body.
      expect(epgRequest.method, 'POST');
      expect(epgRequest.headers['content-type'], 'application/binary');
      expect(epgRequest.bodyBytes, [
        0, 0, 0, 0, 0, 1, 0, 0,
        0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0, 0,
        ...List.filled(16, 0xff),
      ]);
      expect(
        epgRequest.headers['x-dtvtoken'],
        TokenProvider.computeTokenBytes(
            '58daf0', '/chEpg/EPGGet', epgRequest.bodyBytes),
      );

      final logos = await service.getChannelLogos(2);
      expect(logos.keys, [0x3333]);
    });
  });

  group('programme guide screen', () {
    testWidgets('renders the channel column and event titles',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      final now = DateTime.now().toUtc();
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [
              EpgEvent(
                eventId: 1,
                start: now,
                duration: const Duration(minutes: 30),
                title: 'テスト番組',
                description: '説明テキスト',
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('テスト局'), findsOneWidget);
      expect(find.text('テスト番組'), findsOneWidget);
      expect(find.textContaining('今日'), findsOneWidget);
    });

    testWidgets('a short (5 min) event still renders its title',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      final now = DateTime.now().toUtc();
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [
              EpgEvent(
                eventId: 1,
                start: now.subtract(const Duration(minutes: 10)),
                duration: const Duration(minutes: 30),
                title: '長い番組',
              ),
              EpgEvent(
                eventId: 2,
                start: now,
                duration: const Duration(minutes: 5),
                title: '短い番組',
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The 5-minute tile is 11px tall: previously the title was
      // only rendered for tiles of 26px or more (plan 22).
      expect(find.text('短い番組'), findsOneWidget);
      expect(find.text('長い番組'), findsOneWidget);
    });

    testWidgets('horizontal scrolling settles on a column boundary',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      Channel channelN(int n) => Channel(
            broadcastingType: 2,
            networkId: 0x1111,
            transportStreamId: 0x2222 + n,
            serviceId: 0x3300 + n,
            serviceType: 1,
            channelNumber: n + 1,
            serviceName: '局$n',
          );
      final now = DateTime.now().toUtc();
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          for (var i = 0; i < 6; i++)
            EpgServiceGuide(
              channel: channelN(i),
              events: [
                EpgEvent(
                  eventId: 1,
                  start: now.subtract(const Duration(minutes: 10)),
                  duration: const Duration(minutes: 30),
                  title: '番組$i',
                ),
              ],
            ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final scv = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.horizontal);
      expect(scv, findsOneWidget);
      await tester.timedDrag(
          scv, const Offset(-260, 0), const Duration(milliseconds: 500));
      // Let the snap spring run to rest (bounded pumps instead of
      // pumpAndSettle, whose fake-time timeout interacts badly
      // with the timed drag's clock).
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final scrollable = tester.state<ScrollableState>(find.descendant(
          of: scv,
          matching: find.byWidgetPredicate((w) =>
              w is Scrollable && w.axisDirection == AxisDirection.right)));
      // The grid must come to rest exactly on a column boundary,
      // never mid-column (plan 22): the scroll moved, and the
      // settled offset is a whole number of columns.
      final pixels = scrollable.position.pixels;
      final colWidth = resolveEpgChannelWidth(
        scrollable.position.viewportDimension,
      );
      expect(pixels, greaterThan(0));
      expect(
        pixels % colWidth,
        anyOf(closeTo(0, 1.0), closeTo(colWidth, 1.0)),
      );
      // And the position must go idle: a snap simulation that is
      // re-created on completion loops forever and blocks all
      // further pointer input to the grid (plan 23).
      expect(scrollable.position.activity, isA<IdleScrollActivity>());
    });

    testWidgets('mouse drag scrolls the grid vertically', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      // A guide holding only tomorrow's programmes: the screen
      // opens on that day and the initial jump-to-now (which runs
      // for today only) stays out of the way, so the grid starts
      // at offset 0 whatever time of day the test runs at.
      final tomorrow = DateTime.now().toUtc().add(const Duration(days: 1));
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [
              EpgEvent(
                eventId: 1,
                start: tomorrow,
                duration: const Duration(minutes: 30),
                title: '明日の番組',
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final grid = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.vertical &&
          w.physics is! NeverScrollableScrollPhysics);
      expect(grid, findsOneWidget);
      final scrollable = tester.state<ScrollableState>(find.descendant(
          of: grid,
          matching: find.byWidgetPredicate((w) =>
              w is Scrollable && w.axisDirection == AxisDirection.down)));
      expect(scrollable.position.pixels, 0);

      // Grab the grid with the mouse and pull it upwards: the
      // guide must follow, like it follows a touch swipe.
      final gesture = await tester.startGesture(
        tester.getCenter(grid),
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(0, -75));
        await tester.pump();
      }
      await gesture.up();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(scrollable.position.pixels, greaterThan(100));
    });

    testWidgets(
        'mouse drag scrolls the grid horizontally and settles on a '
        'column boundary', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      Channel channelN(int n) => Channel(
            broadcastingType: 2,
            networkId: 0x1111,
            transportStreamId: 0x2222 + n,
            serviceId: 0x3300 + n,
            serviceType: 1,
            channelNumber: n + 1,
            serviceName: '局$n',
          );
      final now = DateTime.now().toUtc();
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          for (var i = 0; i < 6; i++)
            EpgServiceGuide(
              channel: channelN(i),
              events: [
                EpgEvent(
                  eventId: 1,
                  start: now.subtract(const Duration(minutes: 10)),
                  duration: const Duration(minutes: 30),
                  title: '番組$i',
                ),
              ],
            ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final scv = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.horizontal);
      expect(scv, findsOneWidget);
      // Grab the grid with the mouse and pull it sideways.
      final gesture = await tester.startGesture(
        tester.getCenter(scv),
        kind: PointerDeviceKind.mouse,
      );
      // A real drag arrives as a stream of small moves. The
      // first segment is spent winning the gesture arena from
      // the grid's vertical drag recogniser, so step the pull
      // instead of moving once.
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(-65, 0));
        await tester.pump();
      }
      await gesture.up();
      // Let the snap spring run to rest (bounded pumps, as in the
      // touch version of this test above).
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final scrollable = tester.state<ScrollableState>(find.descendant(
          of: scv,
          matching: find.byWidgetPredicate((w) =>
              w is Scrollable && w.axisDirection == AxisDirection.right)));
      final pixels = scrollable.position.pixels;
      final colWidth = resolveEpgChannelWidth(
        scrollable.position.viewportDimension,
      );
      expect(pixels, greaterThan(0));
      expect(
        pixels % colWidth,
        anyOf(closeTo(0, 1.0), closeTo(colWidth, 1.0)),
      );
      expect(scrollable.position.activity, isA<IdleScrollActivity>());
    });

    testWidgets('diagonal drags scroll the grid on both axes at once',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      Channel channelN(int n) => Channel(
            broadcastingType: 2,
            networkId: 0x1111,
            transportStreamId: 0x2222 + n,
            serviceId: 0x3300 + n,
            serviceType: 1,
            channelNumber: n + 1,
            serviceName: '局$n',
          );
      // A guide holding only tomorrow's programmes (JST), so the
      // initial jump-to-now stays out of the way and the grid
      // starts at offset 0 on both axes.
      final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
      final firstDay = DateTime.utc(jstNow.year, jstNow.month, jstNow.day)
          .add(const Duration(days: 1))
          .subtract(const Duration(hours: 9));
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          for (var s = 0; s < 8; s++)
            EpgServiceGuide(
              channel: channelN(s),
              events: [
                for (var i = 0; i < 48; i++)
                  EpgEvent(
                    eventId: i + 1,
                    start: firstDay.add(Duration(minutes: 30 * i)),
                    duration: const Duration(minutes: 30),
                    title: '番組$s-$i',
                  ),
              ],
            ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final scv = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.horizontal);
      expect(scv, findsOneWidget);
      ScrollPosition positionOf(AxisDirection axis) => tester
          .stateList<ScrollableState>(
              find.descendant(of: scv, matching: find.byType(Scrollable)))
          .map((s) => s.position)
          .firstWhere((p) => p.axisDirection == axis);
      final hPos = positionOf(AxisDirection.right);
      final vPos = positionOf(AxisDirection.down);
      expect(hPos.pixels, 0);
      expect(vPos.pixels, 0);

      // Phase 1 (mouse): pull the grid diagonally. With the two
      // scroll views' own drag recognisers, the gesture arena
      // locked the drag to whichever axis crossed the slop
      // first; through the grid's single pan recogniser both
      // axes must follow the same drag.
      final mouse = await tester.startGesture(
        tester.getCenter(scv),
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 6; i++) {
        await mouse.moveBy(const Offset(-40, -40));
        await tester.pump();
      }
      expect(hPos.pixels, greaterThan(100));
      expect(vPos.pixels, greaterThan(100));
      await mouse.up();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The channel axis still settles on a column boundary and
      // both positions come fully to rest.
      final colWidth = resolveEpgChannelWidth(hPos.viewportDimension);
      expect(
        hPos.pixels % colWidth,
        anyOf(closeTo(0, 1.0), closeTo(colWidth, 1.0)),
      );
      expect(hPos.activity, isA<IdleScrollActivity>());
      expect(vPos.activity, isA<IdleScrollActivity>());

      // Phase 2 (touch): drag back diagonally; both axes must
      // follow again, by roughly the dragged amount.
      final hBefore = hPos.pixels;
      final vBefore = vPos.pixels;
      final touch = await tester.startGesture(tester.getCenter(scv));
      for (var i = 0; i < 3; i++) {
        await touch.moveBy(const Offset(40, 40));
        await tester.pump();
      }
      expect(hPos.pixels, lessThan(hBefore - 40));
      expect(vPos.pixels, lessThan(vBefore - 40));
      await touch.up();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        hPos.pixels % colWidth,
        anyOf(closeTo(0, 1.0), closeTo(colWidth, 1.0)),
      );
      expect(hPos.activity, isA<IdleScrollActivity>());
      expect(vPos.activity, isA<IdleScrollActivity>());
    });

    testWidgets('mouse click on an event tile still opens the detail',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      final now = DateTime.now().toUtc();
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [
              EpgEvent(
                eventId: 1,
                start: now.subtract(const Duration(minutes: 30)),
                duration: const Duration(minutes: 60),
                title: 'テスト番組',
                description: '説明テキスト',
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // A plain mouse click (no drag) must still select the
      // programme: enabling mouse drags must not eat tile taps.
      await tester.tap(find.text('テスト番組'),
          kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(EpgEventDetailDialog), findsOneWidget);
    });

    testWidgets(
        'after a horizontal scroll the grid still scrolls vertically '
        'and tiles still respond (plan 23)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      Channel channelN(int n) => Channel(
            broadcastingType: 2,
            networkId: 0x1111,
            transportStreamId: 0x2222 + n,
            serviceId: 0x3300 + n,
            serviceType: 1,
            channelNumber: n + 1,
            serviceName: '局$n',
          );
      // Two full days starting tomorrow (JST), so the initial
      // jump-to-now never interferes at any time of day.
      final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
      final firstDay = DateTime.utc(jstNow.year, jstNow.month, jstNow.day)
          .add(const Duration(days: 1))
          .subtract(const Duration(hours: 9));
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          for (var s = 0; s < 6; s++)
            EpgServiceGuide(
              channel: channelN(s),
              events: [
                for (var d = 0; d < 2; d++)
                  for (var i = 0; i < 48; i++)
                    EpgEvent(
                      eventId: d * 100 + i + 1,
                      start: firstDay
                          .add(Duration(days: d, minutes: 30 * i)),
                      duration: const Duration(minutes: 30),
                      title: '番組$s-$d-$i',
                    ),
              ],
            ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider
                .overrideWithValue(InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final hScv = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.horizontal);
      expect(hScv, findsOneWidget);
      ScrollPosition positionOf(AxisDirection axis) => tester
          .stateList<ScrollableState>(
              find.descendant(of: hScv, matching: find.byType(Scrollable)))
          .map((s) => s.position)
          .firstWhere((p) => p.axisDirection == axis);
      final hPos = positionOf(AxisDirection.right);
      final vPos = positionOf(AxisDirection.down);

      // 1) Scroll sideways, like reaching for a later channel.
      await tester.timedDragFrom(const Offset(215, 500),
          const Offset(-260, 0), const Duration(milliseconds: 400));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(hPos.pixels, greaterThan(0));
      final colWidth = resolveEpgChannelWidth(hPos.viewportDimension);
      expect(
        hPos.pixels % colWidth,
        anyOf(closeTo(0, 1.0), closeTo(colWidth, 1.0)),
      );
      // The snap must come fully to rest (plan 23: a snap physics
      // that keeps re-creating its ballistic simulation leaves the
      // position scrolling forever and the grid stops accepting
      // drags and taps).
      expect(hPos.activity, isA<IdleScrollActivity>());

      // 2) Tiles still respond to taps (event detail dialog),
      // checked while the grid is at a known offset (v = 0, so
      // (215, 500) lands mid-tile).
      await tester.tapAt(const Offset(215, 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('閉じる'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);

      // 3) Vertical drags move the grid again.
      final before = vPos.pixels;
      await tester.timedDragFrom(const Offset(215, 500),
          const Offset(0, -400), const Duration(milliseconds: 400));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(vPos.pixels, greaterThan(before + 100));

      // 4) Switching days keeps vertical scrolling alive.
      await tester.tap(find.byType(ChoiceChip).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final beforeSwitch = vPos.pixels;
      await tester.timedDragFrom(const Offset(215, 500),
          const Offset(0, -400), const Duration(milliseconds: 400));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(vPos.pixels, greaterThan(beforeSwitch + 100));
    });

    testWidgets('initial jump-to-now stays inside the scroll range',
        (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
      final todayStart =
          DateTime.utc(jstNow.year, jstNow.month, jstNow.day)
              .subtract(const Duration(hours: 9));
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: const Channel(
              broadcastingType: 2,
              networkId: 0x1111,
              transportStreamId: 0x2222,
              serviceId: 0x3300,
              serviceType: 1,
              channelNumber: 1,
              serviceName: '局0',
            ),
            events: [
              for (var i = 0; i < 48; i++)
                EpgEvent(
                  eventId: i + 1,
                  start: todayStart.add(Duration(minutes: 30 * i)),
                  duration: const Duration(minutes: 30),
                  title: '番組$i',
                ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider
                .overrideWithValue(InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final gridScv = find.descendant(
        of: find.byWidgetPredicate((w) =>
            w is SingleChildScrollView &&
            w.scrollDirection == Axis.horizontal),
        matching: find.byWidgetPredicate((w) =>
            w is SingleChildScrollView &&
            w.scrollDirection == Axis.vertical),
      );
      final pos = tester
          .state<ScrollableState>(
              find.descendant(of: gridScv, matching: find.byType(Scrollable)))
          .position;
      // Late in the evening the raw (now - 1h) target passes the
      // end of the day grid; the jump must be clamped (plan 23).
      expect(pos.pixels, lessThanOrEqualTo(pos.maxScrollExtent + 0.5));
    });
  });

  group('hidden genres in the guide grid (plan 95)', () {
    Future<void> pumpGuide(
      WidgetTester tester, {
      InMemoryKeyValueStore? keyValues,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      final now = DateTime.now().toUtc();
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [
              EpgEvent(
                eventId: 1,
                start: now,
                duration: const Duration(minutes: 30),
                title: 'ニュース番組',
                genreLevel1: 0,
              ),
              EpgEvent(
                eventId: 2,
                start: now.add(const Duration(minutes: 30)),
                duration: const Duration(minutes: 30),
                title: 'ドラマ番組',
                genreLevel1: 3,
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
            keyValueStoreProvider
                .overrideWithValue(keyValues ?? InMemoryKeyValueStore()),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    testWidgets('a hidden genre paints blank, the others stay', (
      tester,
    ) async {
      final keyValues = InMemoryKeyValueStore();
      await keyValues.write('epg_hidden_genres', '3');
      await pumpGuide(tester, keyValues: keyValues);
      expect(find.text('ニュース番組'), findsOneWidget);
      expect(find.text('ドラマ番組'), findsNothing);
    });

    testWidgets('without the setting both genres show', (tester) async {
      await pumpGuide(tester);
      expect(find.text('ニュース番組'), findsOneWidget);
      expect(find.text('ドラマ番組'), findsOneWidget);
    });
  });

  group('watch from the guide (plan 95)', () {
    const reg = RegisteredNasne(
      host: '192.0.2.1',
      udn: 'uuid:test',
      friendlyName: 'nasne',
      macAddr: '00:11:22:33:44:55',
    );

    test('liveChannelForService matches the identity triple', () {
      const channel = LiveChannel(
        id: '0/video/LiveTuner/DTTB/ch?nid=1111&tsid=2222&svid=3333',
        bandId: '0/video/LiveTuner/DTTB',
        networkId: 0x1111,
        transportStreamId: 0x2222,
        serviceId: 0x3333,
        programTitle: 'ライブ番組',
      );
      const bands = [
        LiveBand(
          containerId: '0/video/LiveTuner/DTTB',
          title: '地上デジタル',
          channels: [channel],
        ),
      ];
      expect(
        liveChannelForService(
          bands,
          networkId: 0x1111,
          transportStreamId: 0x2222,
          serviceId: 0x3333,
        ),
        channel,
      );
      expect(
        liveChannelForService(
          bands,
          networkId: 0x1111,
          transportStreamId: 0x2222,
          serviceId: 0x4444,
        ),
        isNull,
      );
      expect(
        liveChannelForService(
          const [],
          networkId: 0x1111,
          transportStreamId: 0x2222,
          serviceId: 0x3333,
        ),
        isNull,
      );
    });

    Future<void> pumpDetailDialog(
      WidgetTester tester,
      EpgEvent event,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showEpgEventDetail(
                  context,
                  reg: reg,
                  channel: _channel,
                  channelName: 'テスト局',
                  event: event,
                  onWatch: () {},
                ),
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('the watch action shows only while on air', (tester) async {
      final now = DateTime.now().toUtc();
      await pumpDetailDialog(
        tester,
        EpgEvent(
          eventId: 1,
          start: now.subtract(const Duration(minutes: 10)),
          duration: const Duration(minutes: 60),
          title: '放送中の番組',
        ),
      );
      expect(find.text('試聴'), findsOneWidget);
      expect(find.text('録画予約'), findsOneWidget);
    });

    testWidgets('a future event offers a reservation, not watching', (
      tester,
    ) async {
      final now = DateTime.now().toUtc();
      await pumpDetailDialog(
        tester,
        EpgEvent(
          eventId: 2,
          start: now.add(const Duration(hours: 2)),
          duration: const Duration(minutes: 30),
          title: '未来の番組',
        ),
      );
      expect(find.text('試聴'), findsNothing);
      expect(find.text('録画予約'), findsOneWidget);
    });

    testWidgets('an ended event offers neither action', (tester) async {
      final now = DateTime.now().toUtc();
      await pumpDetailDialog(
        tester,
        EpgEvent(
          eventId: 3,
          start: now.subtract(const Duration(hours: 2)),
          duration: const Duration(minutes: 30),
          title: '終わった番組',
        ),
      );
      expect(find.text('試聴'), findsNothing);
      expect(find.text('録画予約'), findsNothing);
      expect(find.text('閉じる'), findsOneWidget);
    });

    testWidgets('an on-air tile leads to the live detail page', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final now = DateTime.now().toUtc();
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [
              EpgEvent(
                eventId: 1,
                start: now.subtract(const Duration(minutes: 10)),
                duration: const Duration(minutes: 60),
                title: '放送中の番組',
              ),
            ],
          ),
        ],
      );
      const liveBands = [
        LiveBand(
          containerId: '0/video/LiveTuner/DTTB',
          title: '地上デジタル',
          channels: [
            LiveChannel(
              id: '0/video/LiveTuner/DTTB/ch?nid=1111&tsid=2222&svid=3333',
              bandId: '0/video/LiveTuner/DTTB',
              networkId: 0x1111,
              transportStreamId: 0x2222,
              serviceId: 0x3333,
              channelName: 'テスト局',
              programTitle: 'ライブ番組',
            ),
          ],
        ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider
                .overrideWithValue(InMemoryRegistrationStore(const [reg])),
            epgGuideProvider.overrideWith((ref, r) async => guide),
            channelLogosProvider
                .overrideWith((ref, r) async => const <int, List<int>>{}),
            liveChannelsProvider.overrideWith((ref, r) async => liveBands),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('放送中の番組'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('試聴'), findsOneWidget);

      await tester.tap(find.text('試聴'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      // The live detail page for the guide's channel.
      expect(find.text('ライブ番組'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '視聴'), findsOneWidget);
    });
  });
}

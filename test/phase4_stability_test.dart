/// Regression tests for Phase 4 stability hardening:
/// - Scheduled recording paging (51+) & fetchAllListPages guards
/// - EPG zlib parse NasneError wrapping, ARIB undefined time/duration, continuation items
/// - EpgSearchScreen error/empty states
/// - CompositeDiscoveryService SSDP fallback & malformed SSDP Location tolerance
/// - ScheduleChannel parseServiceId, XSRS self-closing protect flag, JST DIDL dates, NaN duration
/// - SRM unsigned header rejection, corrupt hex handling, ARIB B24 G0 2-byte DRCS escape
/// - resolveLiveTimeshiftBarState programme-boundary fallback
/// - SoapTitleCatalogService progressive stream cancellation
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/bs_epg_providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/epg_search_screen.dart';
import 'package:tmhb/ui/player_multiplatform_controls.dart';
import 'package:tmhb/ui/player_screen.dart';
import 'package:tmhb/ui/widgets.dart';

class _ThrowingDiscovery implements DiscoveryService {
  _ThrowingDiscovery(this.error);
  final Object error;

  @override
  Future<List<NasneDevice>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) => Future<List<NasneDevice>>.error(error);

  @override
  Future<NasneDevice> describe(Uri location) => Future<NasneDevice>.error(error);
}

class _FixedDiscovery implements DiscoveryService {
  _FixedDiscovery(this.devices);
  final List<NasneDevice> devices;

  @override
  Future<List<NasneDevice>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async => devices;

  @override
  Future<NasneDevice> describe(Uri location) async => devices.first;
}

class _FakeSsdpTransport extends SsdpTransport {
  _FakeSsdpTransport(this.responses);
  final List<SsdpResponse> responses;

  @override
  Future<List<SsdpResponse>> search(
    String searchTarget, {
    Duration timeout = const Duration(seconds: 3),
  }) async => responses;
}

String _xsrsScheduleListEnvelope({
  required List<String> ids,
  required int totalMatches,
}) {
  final items = [
    for (final id in ids)
      '<item id="$id">'
          '<scheduledStartDateTime>2026-11-28T10:00:00+0900</scheduledStartDateTime>'
          '<scheduledDuration>1800</scheduledDuration>'
          '<recordConditionID>1</recordConditionID>'
          '<scheduledChannelID broadcastingType="2" channelType="2">0x0400</scheduledChannelID>'
          '<desiredQualityMode>100</desiredQualityMode>'
          '<desiredMatchingID matchingIDType="SI_EVENTID">0x7880,0x7880,0x0400,0x0001</desiredMatchingID>'
          '<reservationCreatorID>1</reservationCreatorID>'
          '<priorityFlag>0</priorityFlag>'
          '<recordDestinationID>0</recordDestinationID>'
          '<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">番組$id</dc:title>'
          '</item>',
  ].join();
  final escapedResult = const HtmlEscape().convert(
    '<?xml version="1.0"?><xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">$items</xsrs>',
  );
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body>'
      '<u:X_GetRecordScheduleListResponse xmlns:u="urn:schemas-xsrs-org:service:X_ScheduledRecording:2">'
      '<Result>$escapedResult</Result>'
      '<NumberReturned>${ids.length}</NumberReturned>'
      '<TotalMatches>$totalMatches</TotalMatches>'
      '</u:X_GetRecordScheduleListResponse>'
      '</s:Body>'
      '</s:Envelope>';
}

Uint8List _buildEitSection({
  required Channel channel,
  required List<Uint8List> eventsBytes,
}) {
  final bodyLen = eventsBytes.fold<int>(0, (sum, e) => sum + e.length);
  // section_length covers bytes after byte 2: 11 header bytes + body + 4 CRC bytes
  final sectionLen = 11 + bodyLen + 4;
  final out = BytesBuilder();
  out.addByte(0x50); // EIT schedule basic
  out.addByte(0x80 | ((sectionLen >> 8) & 0x0f));
  out.addByte(sectionLen & 0xff);
  out.addByte((channel.serviceId >> 8) & 0xff);
  out.addByte(channel.serviceId & 0xff);
  out.addByte(0xc1); // version/current_next
  out.addByte(0x00); // section_number
  out.addByte(0x00); // last_section_number
  out.addByte((channel.transportStreamId >> 8) & 0xff);
  out.addByte(channel.transportStreamId & 0xff);
  out.addByte((channel.networkId >> 8) & 0xff);
  out.addByte(channel.networkId & 0xff);
  out.addByte(0x00); // segment_last_section_number
  out.addByte(0x50); // last_table_id
  for (final eb in eventsBytes) {
    out.add(eb);
  }
  final withoutCrc = out.toBytes();
  final crc = crc32Mpeg(withoutCrc);
  out.addByte((crc >> 24) & 0xff);
  out.addByte((crc >> 16) & 0xff);
  out.addByte((crc >> 8) & 0xff);
  out.addByte(crc & 0xff);
  return out.toBytes();
}

Uint8List _extendedDescriptor({
  required int descriptorNumber,
  required List<({List<int> labelBytes, List<int> valueBytes})> items,
}) {
  final itemsBuilder = BytesBuilder();
  for (final item in items) {
    itemsBuilder.addByte(item.labelBytes.length);
    itemsBuilder.add(item.labelBytes);
    itemsBuilder.addByte(item.valueBytes.length);
    itemsBuilder.add(item.valueBytes);
  }
  final itemsBytes = itemsBuilder.toBytes();
  final body = BytesBuilder();
  body.addByte(((descriptorNumber & 0x0f) << 4) | 0x0f);
  body.add([0x6a, 0x70, 0x6e]); // jpn
  body.addByte(itemsBytes.length);
  body.add(itemsBytes);
  body.addByte(0); // text_length = 0
  final bodyBytes = body.toBytes();
  return Uint8List.fromList([0x4e, bodyBytes.length, ...bodyBytes]);
}

void main() {
  group('Phase 4 paging & schedule fixes', () {
    test('SoapScheduleService.listSchedules paginates beyond 50 items', () async {
      final seenStarts = <int>[];
      final client = MockClient((req) async {
        final match = RegExp(r'<StartingIndex>(\d+)</StartingIndex>').firstMatch(req.body);
        final start = int.parse(match!.group(1)!);
        seenStarts.add(start);
        final ids = start == 0
            ? [for (var i = 1; i <= 50; i++) '$i']
            : [for (var i = 51; i <= 70; i++) '$i'];
        return http.Response(
          _xsrsScheduleListEnvelope(ids: ids, totalMatches: 70),
          200,
          headers: {'content-type': 'text/xml; charset=utf-8'},
        );
      });
      final service = SoapScheduleService(
        soap: SoapTransport(client: client),
        controlUrl: Uri.parse('http://192.0.2.1:64230/XSRS'),
      );
      final list = await service.listSchedules();
      expect(seenStarts, [0, 50]);
      expect(list.length, 70);
      expect(list.first.id, '1');
      expect(list.last.id, '70');
    });

    test('SoapTitleCatalogService.listTitlesProgressively stops paging on cancel', () async {
      var pageCalls = 0;
      final page2Gate = Completer<void>();
      final client = MockClient((req) async {
        if (req.body.contains('Browse')) {
          return http.Response(
            '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><Result>&lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"/&gt;</Result></u:BrowseResponse></s:Body></s:Envelope>',
            200,
            headers: {'content-type': 'text/xml; charset=utf-8'},
          );
        }
        pageCalls++;
        if (pageCalls >= 2) {
          await page2Gate.future;
        }
        final item = const HtmlEscape().convert(
          '<?xml version="1.0"?><xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">'
          '<item id="$pageCalls">'
          '<scheduledStartDateTime>2026-11-28T10:00:00+0900</scheduledStartDateTime>'
          '<scheduledDuration>1800</scheduledDuration>'
          '<scheduledChannelID broadcastingType="2" channelType="2">0x0400</scheduledChannelID>'
          '<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">録画$pageCalls</dc:title>'
          '</item></xsrs>',
        );
        return http.Response(
          '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:X_GetTitleListResponse xmlns:u="urn:schemas-xsrs-org:service:X_ScheduledRecording:2"><Result>$item</Result><NumberReturned>1</NumberReturned><TotalMatches>5</TotalMatches></u:X_GetTitleListResponse></s:Body></s:Envelope>',
          200,
          headers: {'content-type': 'text/xml; charset=utf-8'},
        );
      });

      final soap = SoapTransport(client: client);
      final svc = SoapTitleCatalogService(
        soap: soap,
        xsrsControlUrl: Uri.parse('http://192.0.2.1:64230/XSRS'),
        webApi: WebApiTransport('192.0.2.1', client: client),
        metadata: CompositeMetadataService(
          dlna: DlnaMetadataService(
            soap: soap,
            controlUrl: Uri.parse('http://192.0.2.1:58888/cds'),
          ),
          epg: WebApiEpgService(
            plain: WebApiTransport('192.0.2.1', client: client),
            authed: WebApiTransport('192.0.2.1', client: client),
          ),
        ),
      );
      final events = <TitleListProgress>[];
      late StreamSubscription<TitleListProgress> sub;
      final firstGot = Completer<void>();
      sub = svc.listTitlesProgressively().listen((p) {
        events.add(p);
        if (!firstGot.isCompleted) firstGot.complete();
      });
      await firstGot.future;
      await sub.cancel();
      page2Gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pageCalls, lessThanOrEqualTo(2));
      expect(events.length, 1);
    });
  });

  group('Phase 4 EPG parser & search fixes', () {
    test('inflateEpgResponse wraps corrupt data as NasneError.parse', () {
      expect(
        () => inflateEpgResponse(const [1, 2, 3, 4]),
        throwsA(isA<NasneError>().having((e) => e.category, 'category', NasneErrorCategory.parse)),
      );
    });

    test('parseEpgGuide skips undefined ARIB time, clamps undefined duration, and merges continuation extended items', () {
      const ch = Channel(
        broadcastingType: 2,
        networkId: 0x7880,
        transportStreamId: 0x7880,
        serviceId: 0x0400,
        serviceType: 1,
        channelNumber: 1,
        serviceName: 'テスト局',
      );
      // Event 1: undefined start (MJD=0xFFFF, time=0xFFFFFF) -> must be skipped.
      final invalidStartEvent = Uint8List.fromList([
        0x00, 0x01, // eventId
        0xff, 0xff, 0xff, 0xff, 0xff, // undefined start
        0x00, 0x30, 0x00, // duration 30m
        0x00, 0x00, // descriptors len = 0
      ]);

      // Event 2: valid start (MJD=61360 -> 2026-11-16 approx, 12:00:00 BCD), undefined duration 0xFFFFFF
      // + extended descriptors #0 ("詳細": "AB") and #1 ("": "CD").
      final d0 = _extendedDescriptor(
        descriptorNumber: 0,
        items: [
          (
            labelBytes: [0x1b, 0x28, 0x4a, 0x41, 0x42, 0x43], // ESC(J + ABC
            valueBytes: [0x1b, 0x28, 0x4a, 0x31, 0x32], // ESC(J + 12
          ),
        ],
      );
      final d1 = _extendedDescriptor(
        descriptorNumber: 1,
        items: [
          (
            labelBytes: const [],
            valueBytes: [0x1b, 0x28, 0x4a, 0x33, 0x34], // ESC(J + 34
          ),
        ],
      );
      final descLen = d0.length + d1.length;
      final validEvent = Uint8List.fromList([
        0x00, 0x02,
        0xef, 0xb0, // valid MJD
        0x12, 0x00, 0x00, // 12:00:00 JST
        0xff, 0xff, 0xff, // undefined duration -> clamped to 0
        (descLen >> 8) & 0x0f,
        descLen & 0xff,
        ...d0,
        ...d1,
      ]);

      final plain = _buildEitSection(
        channel: ch,
        eventsBytes: [invalidStartEvent, validEvent],
      );
      final guide = parseEpgGuide(plain, [ch], broadcastingType: 2);
      expect(guide.services, hasLength(1));
      final ev = guide.services.single.events.single;
      expect(ev.eventId, 2);
      expect(ev.duration, Duration.zero);
      expect(ev.extendedItems, hasLength(1));
      expect(ev.extendedItems.single.label, 'ＡＢＣ');
      expect(ev.extendedItems.single.value, '１２３４');
    });

    testWidgets('EpgSearchScreen shows ErrorView when both terrestrial and BS guides fail', (tester) async {
      const reg = RegisteredNasne(
        host: '192.0.2.2',
        udn: 'uuid:search-err',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            epgGuideProvider(reg).overrideWith(
              (ref) => Future<EpgGuide>.error(NasneError.unreachable('epg')),
            ),
            bsEpgGuideProvider(reg).overrideWith(
              (ref) => Future<EpgGuide>.error(NasneError.unreachable('epg_bs')),
            ),
            schedulesProvider(reg).overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: EpgSearchScreen(reg: reg)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.byType(LoadingView), findsNothing);
    });
  });

  group('Phase 4 discovery, parser, SRM, and ARIB fixes', () {
    test('CompositeDiscoveryService falls back when SSDP throws and SsdpDiscoveryService skips invalid LOCATION', () async {
      final fallbackDevice = NasneDevice.direct('192.0.2.55');
      final composite = CompositeDiscoveryService([
        _ThrowingDiscovery(NasneError.unreachable('ssdp:search')),
        _FixedDiscovery([fallbackDevice]),
      ]);
      final found = await composite.discover();
      expect(found, hasLength(1));
      expect(found.single.host, '192.0.2.55');

      final ssdp = SsdpDiscoveryService(
        ssdp: _FakeSsdpTransport([
          SsdpResponse(
            from: InternetAddress('192.0.2.10'),
            headers: const {'LOCATION': 'http://:invalid uri'},
          ),
        ]),
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(await ssdp.discover(), isEmpty);
    });

    test('ScheduleChannel, XSRS self-closing flag, JST DIDL dates, and NaN duration safety', () {
      expect(
        () => ScheduleChannel.parseServiceId('not-a-num'),
        throwsA(isA<NasneError>().having((e) => e.category, 'category', NasneErrorCategory.parse)),
      );

      final updated = buildTitleProtectElements(
        '<item id="1"><titleProtectFlag attr="x"/></item>',
        protect: true,
      );
      expect(updated, contains('<titleProtectFlag>1</titleProtectFlag>'));
      expect(updated, isNot(contains('<titleProtectFlag attr="x"/>')));

      final parsedJst = parseDidlDate('2026-11-28T10:00:00');
      expect(parsedJst, DateTime.parse('2026-11-28T10:00:00+09:00'));

      final doc = parseDidl(
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="ch1" parentID="0" restricted="1">'
        '<upnp:scheduledStartTime>2026-11-28T12:00:00</upnp:scheduledStartTime>'
        '<res duration="00:00:NaN" protocolInfo="http-get:*:video/mpeg:*">http://192.0.2.1/1</res>'
        '</item></DIDL-Lite>',
        'test',
      );
      final liveCh = liveChannelFromDidl(doc.items.single);
      expect(liveCh.programStart, DateTime.parse('2026-11-28T12:00:00+09:00'));
      expect(liveCh.res.single.duration, isNull);
    });

    test('Srm.parse rejects unsigned 4-byte blob and KeyValueSrmStore ignores corrupt hex', () async {
      expect(
        () => Srm.parse(const [0, 0, 0, 1]),
        throwsA(isA<NasneError>().having((e) => e.category, 'category', NasneErrorCategory.parse)),
      );

      final kv = InMemoryKeyValueStore();
      await kv.write(KeyValueSrmStore.storageKey, 'ZZZZ_NOT_HEX');
      final store = KeyValueSrmStore(kv);
      expect(await store.load(), isNull);
    });

    test('decodeAribB24 consumes G0 2-byte DRCS escape ESC \$ 0x20 F cleanly', () {
      // ESC $ 0x20 'A' followed by 'B' (ASCII after invoking G0/DRCS; wait: G0 is blank2 now,
      // then switch back to alphanumeric ESC ( B and output 'OK').
      final bytes = [
        0x1b, 0x24, 0x20, 0x41, // G0 = 2-byte DRCS (consuming F=0x41)
        0x21, 0x21, // 1 2-byte DRCS glyph -> ignored
        0x1b, 0x28, 0x4a, // G0 = alnum JIS
        0x4f, 0x4b, // OK
      ];
      expect(decodeAribB24(bytes), 'ＯＫ');
    });

    test('resolveLiveTimeshiftTargetSeconds inverts programme timeline accurately across boundary overshoot', () {
      final wallNow = DateTime.utc(2026, 11, 25, 12, 17, 0);
      final progStart = DateTime.utc(2026, 11, 25, 12, 0, 0);
      final progEnd = DateTime.utc(2026, 11, 25, 12, 15, 0);
      final info = LiveOsdProgramInfo(
        currentTitle: '前の番組',
        currentStart: progStart,
        currentEnd: progEnd,
        nextTitle: null,
        nextStart: null,
        nextEnd: null,
        currentEvent: null,
      );
      final bar = resolveLiveTimeshiftBarState(
        info: info,
        now: wallNow,
        cacheStartSeconds: 60.0,
        cacheEndSeconds: 540.0,
        effectivePosSeconds: 240.0, // 300s behind -> 12:12:00
        liveDelayedByPause: true,
      );
      expect(bar.usesProgramTimeline, isTrue);
      expect(bar.liveEdgeFraction, 1.0);
      expect(bar.playbackFraction, closeTo(0.80, 0.001));

      final targetSec = resolveLiveTimeshiftTargetSeconds(
        fraction: bar.playbackFraction,
        liveEdgeFraction: bar.liveEdgeFraction,
        playableStartFraction: bar.playableStartFraction,
        usesProgramTimeline: bar.usesProgramTimeline,
        programStart: info.currentStart,
        programEnd: info.currentEnd,
        now: wallNow,
        cacheStartSeconds: 60.0,
        cacheEndSeconds: 540.0,
      );
      expect(targetSec, closeTo(240.0, 0.5));
    });
  });
}

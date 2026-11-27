/// Phase 5 (DTCP-IP) tests: known-answer vectors generated with the
/// pydtcpip reference implementation (test/dtcp_kat.dart), the
/// reference's published content-key values, credential validation,
/// the AKE state machine against a fake source, PCP decryption, and
/// the subchannel classification (plan 25/26).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/epg_screen.dart';

import 'dtcp_kat.dart';

Uint8List hex(String s) => hexToBytes(s);

void main() {
  final testAuthority = [hex(katAuthPub)];
  final sinkCert = hex(katSinkCert);
  final sinkPriv = hex(katSinkPriv);
  final srcCert = hex(katSrcCert);
  final srcPriv = hex(katSrcPriv);

  group('DTCP curve + ECDSA known answers', () {
    test('generator multiples match the reference', () {
      final authPub = DtcpCurve.generator * bytesToBigInt(hex(katAuthPriv));
      expect(bytesToHex(authPub.toBytes()), katAuthPub);
      final ephA = DtcpCurve.generator * bytesToBigInt(hex(katEphA));
      expect(bytesToHex(ephA.toBytes()), katEphAPub);
    });

    test('certificate verification with the test authority', () {
      final pub = verifyCertificate(sinkCert, authorityKeys: testAuthority);
      expect(bytesToHex(pub.toBytes()), katSinkCert.substring(16, 16 + 80));
      expect(deviceIdOf(sinkCert), katSinkId);
      // The real DTLA keys must NOT verify the test certificate.
      expect(() => verifyCertificate(sinkCert), throwsA(isA<NasneError>()));
    });

    test('deterministic signatures match the reference byte for byte', () {
      final sig = ecdsaSignDeterministic(
        bytesToBigInt(sinkPriv),
        Uint8List.fromList([...hex(katSrcNonce), ...hex(katResponseData)]),
      );
      expect(bytesToHex(sig), katResponseSig);
      final pub = verifyCertificate(sinkCert, authorityKeys: testAuthority);
      expect(
        ecdsaVerify(
          pub,
          Uint8List.fromList([...hex(katSrcNonce), ...hex(katResponseData)]),
          sig,
        ),
        isTrue,
      );
    });

    test('ECDH shared secret and authentication key', () {
      final peer = EcPoint.fromBytes(hex(katEphBPub))!;
      final shared = ecdhSharedSecret(bytesToBigInt(hex(katEphA)), peer);
      expect(bytesToHex(shared), katSharedSecret);
      expect(bytesToHex(shared.sublist(8)), katAuthKey);
    });
  });

  group('content key derivation (reference published values)', () {
    final expected = <int, String>{
      0x2: '49cab6fb54b954f726cb09dbe1462e0aa5a4aa2f3f98e71af8f8287fecaeb98a',
      0x4: 'e5110b3440d24f5d3355eee3d0dad360b4610f63105289524d339d212f8ea3f7',
      0x6: 'be59c30062fb6e6f99307e076d990cacda84cd388fa6f92c4322a1c66a3c45b7',
      0x8: '3c2f018f0ae58945a523d6a30aa3202aca0d8636060299087a08f77d30cb073f',
      0xA: 'e5ef555cb40826c4fffbd9987c20fa4840a8153b77da41f27ca8a9fcb8bd3121',
      0xC: '16ecd1ea4ea71f1e63d57f70d4e1e75ff413b4df4e28df70570809fab0bd941b',
    };
    for (final entry in expected.entries) {
      test('E-EMI 0x${entry.key.toRadixString(16)}', () {
        final derived = deriveContentKey(
          Uint8List.fromList(List.generate(12, (i) => i)),
          entry.key,
          Uint8List.fromList(List.generate(8, (i) => 0x80 + i)),
        );
        expect(bytesToHex([...derived.key, ...derived.iv]), entry.value);
      });
    }
  });

  group('credential validation', () {
    test('a genuine pair passes', () {
      final creds = DeviceCredentials(
        certificate: sinkCert,
        privateKey: sinkPriv,
        authorityKeys: testAuthority,
      );
      expect(creds.deviceId, katSinkId);
      expect(creds.maxSrmGeneration, 1);
    });

    test('wrong lengths are rejected', () {
      expect(
        () => DeviceCredentials(
          certificate: sinkCert.sublist(0, 87),
          privateKey: sinkPriv,
          authorityKeys: testAuthority,
        ),
        throwsA(isA<NasneError>()),
      );
      expect(
        () => DeviceCredentials(
          certificate: sinkCert,
          privateKey: sinkPriv.sublist(0, 19),
          authorityKeys: testAuthority,
        ),
        throwsA(isA<NasneError>()),
      );
    });

    test('out-of-range private keys are rejected', () {
      expect(
        () => DeviceCredentials(
          certificate: sinkCert,
          privateKey: Uint8List(20),
          authorityKeys: testAuthority,
        ),
        throwsA(isA<NasneError>()),
      );
      expect(
        () => DeviceCredentials(
          certificate: sinkCert,
          privateKey: bigIntToBytes(DtcpCurve.order, 20),
          authorityKeys: testAuthority,
        ),
        throwsA(isA<NasneError>()),
      );
    });

    test('a mismatched pair is rejected', () {
      expect(
        () => DeviceCredentials(
          certificate: sinkCert,
          privateKey: srcPriv,
          authorityKeys: testAuthority,
        ),
        throwsA(isA<NasneError>()),
      );
    });

    test('a tampered certificate is rejected', () {
      final tampered = Uint8List.fromList(sinkCert);
      tampered[20] ^= 0x01;
      expect(
        () => DeviceCredentials(
          certificate: tampered,
          privateKey: sinkPriv,
          authorityKeys: testAuthority,
        ),
        throwsA(isA<NasneError>()),
      );
    });
  });

  group('credential store (in-memory)', () {
    test('save / load / delete round trip', () async {
      final store = InMemoryCredentialStore(authorityKeys: testAuthority);
      expect(await store.hasCredentials, isFalse);
      expect(await store.load(), isNull);
      await store.save(certificate: sinkCert, privateKey: sinkPriv);
      expect(await store.hasCredentials, isTrue);
      final loaded = await store.load();
      expect(loaded!.deviceId, katSinkId);
      await store.delete();
      expect(await store.hasCredentials, isFalse);
    });

    test('an invalid pair is not stored', () async {
      final store = InMemoryCredentialStore(authorityKeys: testAuthority);
      await expectLater(
        store.save(certificate: sinkCert, privateKey: srcPriv),
        throwsA(isA<NasneError>()),
      );
      expect(await store.hasCredentials, isFalse);
    });
  });

  group('SRM', () {
    test('parse + revocation checks', () {
      final srm = Srm.parse(hex(katSrmData), authorityKeys: testAuthority);
      expect(srm.version, 9);
      expect(srm.generation, 1);
      expect(srm.isRevoked(katSrcId), isTrue);
      expect(srm.isRevoked(0x1122334455), isTrue);
      expect(srm.isRevoked(0x2000000080), isTrue);
      expect(srm.isRevoked(katSinkId), isFalse);
      expect(srm.isRevoked(0x2000000100), isFalse);
    });

    test('a tampered SRM is rejected', () {
      final tampered = Uint8List.fromList(hex(katSrmData));
      tampered[10] ^= 0x01;
      expect(
        () => Srm.parse(tampered, authorityKeys: testAuthority),
        throwsA(isA<NasneError>()),
      );
    });
  });

  group('PCP decryption', () {
    test('the reference packet decrypts to the reference content', () async {
      final decryptor = PcpDecryptor(
        keyForLabel: (label) async {
          expect(label, 0x2A);
          return hex(katPcpExchangeKey);
        },
      );
      final wire = hex(katPcpWire);
      // Feed in uneven chunks to exercise the buffering.
      // Plan 30: decryption is streaming, so the plaintext comes
      // back as several pieces; their concatenation is the packet
      // content.
      final out = <Uint8List>[];
      out.addAll(await decryptor.add(wire.sublist(0, 5)));
      out.addAll(await decryptor.add(wire.sublist(5, 100)));
      out.addAll(await decryptor.add(wire.sublist(100)));
      final joined = Uint8List.fromList([for (final piece in out) ...piece]);
      expect(bytesToHex(joined), katPcpContent);
    });
  });

  group('AKE against a fake source', () {
    test('full authentication, RTT, exchange key and SRM update', () async {
      final srmStore = _TestSrmStore(testAuthority);
      final clientWire = <Uint8List>[];
      final sourceWire = <Uint8List>[];
      late _FakeConnection clientConn;
      late _FakeConnection sourceConn;
      clientConn = _FakeConnection(
        (bytes) => sourceConn.deliver(bytes),
        clientWire.add,
      );
      sourceConn = _FakeConnection(
        (bytes) => clientConn.deliver(bytes),
        sourceWire.add,
      );

      final credentials = DeviceCredentials(
        certificate: sinkCert,
        privateKey: sinkPriv,
        authorityKeys: testAuthority,
      );
      final client = AkeClient(
        credentials: credentials,
        srmStore: srmStore,
        connectionFactory: (host, port) async => clientConn,
        randomBytes: (n) => hex(katSinkNonce),
        ephemeralScalar: () => bytesToBigInt(hex(katEphA)),
        authorityKeys: testAuthority,
      );

      final fake = _runFakeSource(
        sourceConn,
        srcCert: srcCert,
        srcPriv: srcPriv,
        testAuthority: testAuthority,
      );
      final session = await client.connect('192.0.2.1', 58293);
      // Playback start now waits for the first exchange key inside
      // the start path (plan 28).
      expect(
        await session.waitFirstExchangeKey(
          timeout: const Duration(seconds: 10),
        ),
        0x2A,
      );
      final key = await session.waitExchangeKey(
        0x2A,
        timeout: const Duration(seconds: 10),
      );
      expect(bytesToHex(key), katPcpExchangeKey);
      await fake.timeout(const Duration(seconds: 10));
      expect(srmStore.savedRaw, isNotNull);
      expect(bytesToHex(srmStore.savedRaw!), katSrmUpdateData);
      await session.close();

      // Wire format (plan 28): the client's frames must match the
      // reference implementation byte for byte in the header.
      final clientFrames = _parseWireFrames(clientWire);
      final sourceFrames = _parseWireFrames(sourceWire);
      // Requests: role byte 0x01 (sink), status byte 0x0F.
      for (final i in [0, 3, 5]) {
        expect(clientFrames[i][8], 0x01, reason: 'client frame $i role byte');
        expect(clientFrames[i][10], 0x0F, reason: 'client frame $i status');
        expect(clientFrames[i][3], 0x00, reason: 'client frame $i ctype');
      }
      // Accepted responses copy the received frame's header
      // (bytes 3..10 compared, length bytes excluded): ctype
      // becomes 0x09 and the status nibble clears; procedure, key
      // type, role byte and label are inherited. Client frame 1
      // answers source frame 1 (the source CHALLENGE, role byte
      // 0x00), client frame 9 answers source frame 9
      // (EXCHANGE_KEY).
      for (final (clientIdx, sourceIdx) in [(1, 1), (9, 9)]) {
        final accepted = clientFrames[clientIdx];
        final original = sourceFrames[sourceIdx];
        expect(accepted[3], 0x09);
        expect(accepted[10], 0x00);
        for (final b in [4, 5, 6, 7, 8, 9]) {
          expect(
            accepted[b],
            original[b],
            reason: 'accepted header byte $b must be copied',
          );
        }
      }
    });

    test(
      'a source close after authentication is a normal end (plan 29)',
      () async {
        final lines = <String>[];
        final diag = DiagLog(
          (category, message) => lines.add('[${category.name}] $message'),
          (_) => true,
        );
        final srmStore = _TestSrmStore(testAuthority);
        late _FakeConnection clientConn;
        late _FakeConnection sourceConn;
        clientConn = _FakeConnection((bytes) => sourceConn.deliver(bytes));
        sourceConn = _FakeConnection((bytes) => clientConn.deliver(bytes));
        final credentials = DeviceCredentials(
          certificate: sinkCert,
          privateKey: sinkPriv,
          authorityKeys: testAuthority,
        );
        final client = AkeClient(
          credentials: credentials,
          srmStore: srmStore,
          connectionFactory: (host, port) async => clientConn,
          randomBytes: (n) => hex(katSinkNonce),
          ephemeralScalar: () => bytesToBigInt(hex(katEphA)),
          authorityKeys: testAuthority,
          diag: diag,
        );
        final fake = _runFakeSource(
          sourceConn,
          srcCert: srcCert,
          srcPriv: srcPriv,
          testAuthority: testAuthority,
        );
        final session = await client.connect('192.0.2.1', 58293);
        expect(
          await session.waitFirstExchangeKey(
            timeout: const Duration(seconds: 10),
          ),
          0x2A,
        );
        await fake.timeout(const Duration(seconds: 10));

        // The real nasne closes the AKE connection right after
        // authentication (plan 29, measured): simulate the EOF.
        await clientConn.close();
        // Let the message loop observe the close.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // A delivered key stays available on the ended session...
        final key = await session.waitExchangeKey(
          0x2A,
          timeout: const Duration(seconds: 5),
        );
        expect(bytesToHex(key), katPcpExchangeKey);
        // ...while a label that never arrived fails fast with the
        // close signal, so the caller can re-authenticate instead
        // of waiting out a timeout on a dead connection.
        await expectLater(
          session.waitExchangeKey(0x77, timeout: const Duration(seconds: 5)),
          throwsA(isA<AkeConnectionClosed>()),
        );
        // The close is logged as the normal lifecycle, not as a
        // connection failure or a loop error.
        expect(
          lines.any((line) => line.contains('closed by the source')),
          isTrue,
        );
        expect(
          lines.any((line) => line.contains('connection failed')),
          isFalse,
        );
        expect(
          lines.any((line) => line.contains('message loop ended')),
          isFalse,
        );
      },
    );

    test('diagnostics record stages but never key material', () async {
      final lines = <String>[];
      final diag = DiagLog(
        (category, message) => lines.add('[${category.name}] $message'),
        (_) => true,
      );
      final srmStore = _TestSrmStore(testAuthority);
      late _FakeConnection clientConn;
      late _FakeConnection sourceConn;
      clientConn = _FakeConnection((bytes) => sourceConn.deliver(bytes));
      sourceConn = _FakeConnection((bytes) => clientConn.deliver(bytes));
      final client = AkeClient(
        credentials: DeviceCredentials(
          certificate: sinkCert,
          privateKey: sinkPriv,
          authorityKeys: testAuthority,
        ),
        srmStore: srmStore,
        connectionFactory: (host, port) async => clientConn,
        randomBytes: (n) => hex(katSinkNonce),
        ephemeralScalar: () => bytesToBigInt(hex(katEphA)),
        authorityKeys: testAuthority,
        diag: diag,
      );
      final fake = _runFakeSource(
        sourceConn,
        srcCert: srcCert,
        srcPriv: srcPriv,
        testAuthority: testAuthority,
      );
      final session = await client.connect('192.0.2.1', 58293);
      await session.waitExchangeKey(0x2A, timeout: const Duration(seconds: 10));
      await fake.timeout(const Duration(seconds: 10));
      await session.close();

      // Stage transitions and frame headers ARE recorded.
      expect(lines.any((l) => l.contains('stage: challenge accepted')), isTrue);
      expect(lines.any((l) => l.contains('stage: response accepted')), isTrue);
      expect(
        lines.any((l) => l.contains('exchange key received, label 42')),
        isTrue,
      );
      expect(lines.any((l) => l.contains('rx cmd=0x01')), isTrue);
      // Key material is NOT: not the auth key, the exchange key,
      // the private key, either nonce, or the shared secret — in
      // hex or base64.
      final secrets = <String>[
        katAuthKey,
        katPcpExchangeKey,
        katSinkPriv,
        katSinkNonce,
        katSrcNonce,
        katSharedSecret,
        base64Encode(hex(katAuthKey)),
        base64Encode(hex(katPcpExchangeKey)),
      ];
      for (final line in lines) {
        for (final secret in secrets) {
          expect(
            line.contains(secret),
            isFalse,
            reason: 'log line must not contain key material: $line',
          );
        }
      }
    });

    test('a revoked source is rejected at CHALLENGE', () async {
      final srmStore = _TestSrmStore(testAuthority)..seed(hex(katSrmData));
      late _FakeConnection clientConn;
      late _FakeConnection sourceConn;
      clientConn = _FakeConnection((bytes) => sourceConn.deliver(bytes));
      sourceConn = _FakeConnection((bytes) => clientConn.deliver(bytes));
      final client = AkeClient(
        credentials: DeviceCredentials(
          certificate: sinkCert,
          privateKey: sinkPriv,
          authorityKeys: testAuthority,
        ),
        srmStore: srmStore,
        connectionFactory: (host, port) async => clientConn,
        randomBytes: (n) => hex(katSinkNonce),
        ephemeralScalar: () => bytesToBigInt(hex(katEphA)),
        authorityKeys: testAuthority,
      );
      // Minimal fake: accept the CHALLENGE, send its own, then the
      // client must abort (the stored SRM revokes the source).
      final fake = () async {
        final reader = _TestFrameReader(sourceConn);
        await reader.next(); // client CHALLENGE
        sourceConn.send(
          ControlFrame(
            command: AkeCommands.challenge,
            payload: Uint8List(0),
            isResponse: true,
          ).encode(),
        );
        sourceConn.send(
          ControlFrame(
            command: AkeCommands.challenge,
            payload: Uint8List.fromList([...hex(katSrcNonce), ...srcCert]),
          ).encode(),
        );
      }();
      await expectLater(
        client.connect('192.0.2.1', 58293),
        throwsA(isA<NasneError>()),
      );
      await fake;
    });

    test('ControlFrame.tryParse rejects totalLength < 8 instead of hanging', () {
      final bogus = Uint8List.fromList([
        0x01,
        0x00,
        0x04, // totalLength = 4 (< 8)
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      expect(
        () => ControlFrame.tryParse(bogus),
        throwsA(
          isA<NasneError>().having(
            (e) => e.category,
            'category',
            NasneErrorCategory.parse,
          ),
        ),
      );
    });
  });

  group('playback engine gating', () {
    test('without credentials, start throws a validation error', () async {
      final engine = DtcpPlaybackEngine(
        credentialStore: InMemoryCredentialStore(authorityKeys: testAuthority),
        srmStore: _TestSrmStore(testAuthority),
      );
      expect(engine.isSupported, isTrue);
      await expectLater(
        engine.startPlayback(
          const RecordedTitle(id: '1', title: 't'),
          const TitleRes(url: 'http://192.0.2.1/x', protocolInfo: ''),
        ),
        throwsA(
          isA<NasneError>().having(
            (e) => e.category,
            'category',
            NasneErrorCategory.validation,
          ),
        ),
      );
    });
  });

  group('subchannel display (plan 25)', () {
    testWidgets('hidden by default, shown when the setting is on', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      Channel ch(int serviceId, String name) => Channel(
        broadcastingType: 2,
        networkId: 0x1111,
        transportStreamId: 0x2222,
        serviceId: serviceId,
        serviceType: 1,
        channelNumber: serviceId,
        serviceName: name,
      );
      final now = DateTime.now().toUtc();
      EpgServiceGuide svc(Channel channel, String title) => EpgServiceGuide(
        channel: channel,
        events: [
          EpgEvent(
            eventId: 1,
            start: now,
            duration: const Duration(minutes: 30),
            title: title,
          ),
        ],
      );
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [svc(ch(100, 'メイン局'), 'メイン番組'), svc(ch(101, 'サブ局'), 'サブ番組')],
      );
      final container = ProviderContainer(
        overrides: [
          registrationStoreProvider.overrideWithValue(
            InMemoryRegistrationStore(const [reg]),
          ),
          epgGuideProvider.overrideWith((ref, r) async => guide),
          channelLogosProvider.overrideWith(
            (ref, r) async => const <int, List<int>>{},
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('メイン局'), findsOneWidget);
      expect(find.text('サブ局'), findsNothing);

      await container.read(showSubchannelsProvider.notifier).set(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('サブ局'), findsOneWidget);
    });
  });

  group('subchannel classification (plan 25)', () {
    test('the measured channel fixture', () {
      final file = File(
        'test/fixtures/webapi/status_channelListGet_broadcastingType2.json',
      );
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final channels = [
        for (final entry in json['channel'] as List<dynamic>)
          Channel.fromJson(entry as Map<String, dynamic>, broadcastingType: 2),
      ];
      expect(channels, hasLength(24));
      expect(subchannelServiceIds(channels), {
        56833,
        56841,
        56842,
        56337,
        56345,
        56353,
        56361,
        56369,
        56425,
        56441,
        56442,
      });
    });
  });
}

/// In-memory SRM store for tests.
class _TestSrmStore implements SrmStore {
  _TestSrmStore(this._authorityKeys);

  final List<Uint8List> _authorityKeys;
  Uint8List? savedRaw;

  void seed(Uint8List raw) => savedRaw = raw;

  @override
  Future<Srm?> load() async {
    final raw = savedRaw;
    if (raw == null) return null;
    return Srm.parse(raw, authorityKeys: _authorityKeys);
  }

  @override
  Future<Uint8List?> loadRaw() async => savedRaw;

  @override
  Future<void> save(Uint8List raw, Srm srm) async {
    savedRaw = raw;
  }
}

/// One end of an in-memory AKE transport pair.
class _FakeConnection implements AkeConnection {
  _FakeConnection(this._sendTo, [this._onSend]);

  final void Function(Uint8List) _sendTo;
  final void Function(Uint8List)? _onSend;
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();

  void deliver(Uint8List bytes) => _controller.add(bytes);

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  @override
  void send(Uint8List bytes) {
    _onSend?.call(bytes);
    _sendTo(bytes);
  }

  @override
  Future<void> close() async {
    await _controller.close();
  }
}

/// Splits recorded wire chunks into raw frames (header + payload)
/// for byte-level assertions.
List<Uint8List> _parseWireFrames(List<Uint8List> chunks) {
  final all = Uint8List.fromList([for (final c in chunks) ...c]);
  final frames = <Uint8List>[];
  var offset = 0;
  while (offset < all.length) {
    final parsed = ControlFrame.tryParse(all.sublist(offset));
    if (parsed == null) break;
    final (_, consumed) = parsed;
    frames.add(Uint8List.fromList(all.sublist(offset, offset + consumed)));
    offset += consumed;
  }
  return frames;
}

class _TestFrameReader {
  _TestFrameReader(_FakeConnection connection) {
    connection.incoming.listen((chunk) {
      _buffer.addAll(chunk);
      _drain();
    });
  }

  final List<int> _buffer = [];
  final List<Completer<ControlFrame>> _waiters = [];
  final List<ControlFrame> _frames = [];

  void _drain() {
    while (true) {
      final parsed = ControlFrame.tryParse(Uint8List.fromList(_buffer));
      if (parsed == null) return;
      final (frame, consumed) = parsed;
      _buffer.removeRange(0, consumed);
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(frame);
      } else {
        _frames.add(frame);
      }
    }
  }

  Future<ControlFrame> next() {
    if (_frames.isNotEmpty) return Future.value(_frames.removeAt(0));
    final completer = Completer<ControlFrame>();
    _waiters.add(completer);
    return completer.future;
  }
}

/// A fake DTCP-IP source performing the server side of Full
/// Authentication, ported from pydtcpip's tests/fakes.py.
Future<void> _runFakeSource(
  _FakeConnection connection, {
  required Uint8List srcCert,
  required Uint8List srcPriv,
  required List<Uint8List> testAuthority,
}) async {
  final reader = _TestFrameReader(connection);
  void send(ControlFrame frame) => connection.send(frame.encode());

  // Client CHALLENGE.
  var frame = await reader.next();
  assert(frame.command == AkeCommands.challenge && !frame.isResponse);
  final sinkNonce = frame.payload.sublist(0, 16);
  final sinkCertBytes = frame.payload.sublist(16);
  final sinkPublic = verifyCertificate(
    sinkCertBytes,
    authorityKeys: testAuthority,
  );
  // ACCEPTED: a copy of the received header (reference behaviour).
  send(frame.accepted());

  // Source CHALLENGE (source frames carry role byte 0x00).
  final srcNonce = hex(katSrcNonce);
  send(
    ControlFrame(
      command: AkeCommands.challenge,
      payload: Uint8List.fromList([...srcNonce, ...srcCert]),
      roleByte: 0,
    ),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.challenge);

  // Source RESPONSE (ephemeral B).
  final ephB = bytesToBigInt(hex(katEphB));
  final ephBPub = DtcpCurve.generator * ephB;
  final responseData = Uint8List.fromList([...ephBPub.toBytes(), 0, 0, 0]);
  final sig = ecdsaSignDeterministic(
    bytesToBigInt(srcPriv),
    Uint8List.fromList([...sinkNonce, ...responseData]),
  );
  send(
    ControlFrame(
      command: AkeCommands.response,
      payload: Uint8List.fromList([...responseData, ...sig]),
      roleByte: 0,
    ),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.response);

  // Client RESPONSE: verify its signature, derive the auth key.
  frame = await reader.next();
  assert(!frame.isResponse && frame.command == AkeCommands.response);
  assert(frame.payload.length == 83);
  final clientEph = EcPoint.fromBytes(frame.payload.sublist(0, 40))!;
  final clientSig = frame.payload.sublist(43);
  assert(
    ecdsaVerify(
      sinkPublic,
      Uint8List.fromList([...srcNonce, ...frame.payload.sublist(0, 43)]),
      clientSig,
    ),
  );
  send(frame.accepted());
  final shared = ecdhSharedSecret(ephB, clientEph);
  final authKey = shared.sublist(8);

  // RTT: ready exchange, setup with the KAT counter, test, verify.
  send(
    ControlFrame(
      command: AkeCommands.rttReady,
      payload: Uint8List(0),
      roleByte: 0,
    ),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.rttReady);
  frame = await reader.next();
  assert(!frame.isResponse && frame.command == AkeCommands.rttReady);
  send(frame.accepted());

  const counter = 0x1234;
  send(
    ControlFrame(
      command: AkeCommands.rttSetup,
      payload: Uint8List.fromList([counter >> 8, counter & 0xFF]),
      roleByte: 0,
    ),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.rttSetup);
  final base = bytesToBigInt(sha1Bytes([...authKey, ...authKey]));
  final digest = sha1Bytes(
    bigIntToBytes((base + BigInt.from(counter)) % (BigInt.one << 160), 20),
  );
  final expected = digest.sublist(0, 10);
  final responseMac = digest.sublist(10);
  final verifyDigest = sha1Bytes(
    bigIntToBytes(
      (base + BigInt.from(counter) + BigInt.one) % (BigInt.one << 160),
      20,
    ),
  );
  final verifyMac = verifyDigest.sublist(0, 10);

  send(
    ControlFrame(command: AkeCommands.rttTest, payload: expected, roleByte: 0),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.rttTest);
  assert(bytesToHex(frame.payload) == bytesToHex(responseMac));

  send(
    ControlFrame(
      command: AkeCommands.rttVerify,
      payload: verifyMac,
      roleByte: 0,
    ),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.rttVerify);
  assert(bytesToHex(frame.payload) == bytesToHex(verifyMac));

  // EXCHANGE_KEY (the KAT exchange key, masked with the auth key).
  final exchangeKey = hex(katPcpExchangeKey);
  final masked = Uint8List(12);
  for (var i = 0; i < 12; i++) {
    masked[i] = exchangeKey[i] ^ authKey[i];
  }
  send(
    ControlFrame(
      command: AkeCommands.exchangeKey,
      payload: Uint8List.fromList([0x2A, 0, ...masked]),
      roleByte: 0,
    ),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.exchangeKey);
  // Copy semantics (plan 28): the accepted frame inherits the
  // SOURCE frame's header, whose label byte is 0 — the key label
  // lives in the request payload, not the header.
  assert(frame.label == 0);

  // SRM_UPDATE with a newer SRM (version 10) that revokes neither
  // party. (The KAT SRM revokes this source; receiving it as an
  // update would legitimately end the session at the check.)
  send(
    ControlFrame(
      command: AkeCommands.srmUpdate,
      payload: hex(katSrmUpdateData),
      roleByte: 0,
    ),
  );
  frame = await reader.next();
  assert(frame.isResponse && frame.command == AkeCommands.srmUpdate);
}

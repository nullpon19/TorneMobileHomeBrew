/// Regression tests for Phase 3 stability hardening:
/// - Jikkyo models, channel mapper, overlay ticker/cache lifecycle, playback controller
/// - PipController shared broadcast subscription across pushReplacement listeners
/// - RegisteredNasne value equality, Riverpod async hydration ref.mounted/_dirty guards
/// - Registration & key-value store corruption quarantine and Isolate round-trip
/// - invalidateDeviceData invalidating terrestrial + BS + CS providers & logo caches
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/bs_epg_providers.dart';
import 'package:tmhb/app/pip_controller.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/jikkyo_overlay.dart';
import 'package:tmhb/ui/player_cache_policy.dart';

class _EmptyTitlesNotifier extends TitlesNotifier {
  _EmptyTitlesNotifier(super.reg);

  @override
  Stream<TitleListProgress> build() =>
      Stream.value(const TitleListProgress([], complete: true));
}

class _DelayedKeyValueStore extends InMemoryKeyValueStore {
  _DelayedKeyValueStore(this.gate);

  final Completer<void> gate;

  @override
  Future<String?> read(String key) async {
    await gate.future;
    return super.read(key);
  }
}

class _ProgrammableJikkyoClient implements JikkyoClient {
  _ProgrammableJikkyoClient({
    required this.onFetchKakolog,
  });

  final Future<List<JikkyoComment>> Function({
    required String jkId,
    required DateTime startTime,
    required DateTime endTime,
  })
  onFetchKakolog;

  @override
  Future<Map<String, JikkyoChannelLiveInfo>> fetchChannelsInfo({
    bool forceRefresh = false,
  }) async => const {};

  @override
  Future<List<JikkyoComment>> fetchKakolog({
    required String jkId,
    required DateTime startTime,
    required DateTime endTime,
  }) => onFetchKakolog(jkId: jkId, startTime: startTime, endTime: endTime);

  @override
  JikkyoLiveConnection connectLive({
    required String jkId,
    required void Function(JikkyoComment comment) onComment,
    void Function(bool connected)? onConnectionChanged,
  }) => _NoopLiveConn();

  @override
  void dispose() {}
}

class _NoopLiveConn implements JikkyoLiveConnection {
  @override
  bool get isConnected => false;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 3 Jikkyo hardening', () {
    test('JikkyoChannelLiveInfo.fromJson tolerates non-Map program fields', () {
      final info = JikkyoChannelLiveInfo.fromJson(<String, dynamic>{
        'id': 'jk4',
        'name': 'テスト局',
        'program_present': <dynamic>[],
        'program_following': 'none',
        'threads': <dynamic>[
          <String, dynamic>{'status': 'ACTIVE', 'jikkyo_force': 42},
        ],
      });
      expect(info, isNotNull);
      expect(info!.id, 'jk4');
      expect(info.programPresent, isNull);
      expect(info.programFollowing, isNull);
      expect(info.jikkyoForce, 42);
    });

    test('resolveJikkyoChannel maps BS10スターチャンネル to jk201 and reports name overrideKey', () {
      const settings = JikkyoSettings(
        channelOverrides: <String, String>{'name:テストhdtv': 'jk4'},
      );
      final star = resolveJikkyoChannel(
        settings: settings,
        broadcastingType: bsBroadcastingType,
        channelName: 'BS10スターチャンネル',
      );
      expect(star.jkId, 'jk201');

      final bs10 = resolveJikkyoChannel(
        settings: settings,
        broadcastingType: bsBroadcastingType,
        channelName: 'BS10',
      );
      expect(bs10.jkId, 'jk200');

      final byNameOverride = resolveJikkyoChannel(
        settings: settings,
        serviceId: 9999,
        channelName: 'テストHDTV',
      );
      expect(byNameOverride.jkId, 'jk4');
      expect(byNameOverride.source, JikkyoMatchSource.manual);
      expect(byNameOverride.overrideKey, 'name:テストhdtv');
    });

    test('JikkyoPlaybackController enforces session gen, keepBody promotion, unloaded cursor, retry backoff, and boundary dedup', () async {
      final base = DateTime.utc(2026, 11, 25, 12, 0, 0);
      final staleChunk0 = Completer<List<JikkyoComment>>();
      final retryChunk0Completer = Completer<List<JikkyoComment>>();
      final chunk1Completer = Completer<List<JikkyoComment>>();
      var chunk0Attempts = 0;

      final boundaryComment = JikkyoComment(
        no: 50,
        timestampMs: base.millisecondsSinceEpoch + 1200 * 1000,
        text: '境界コメント',
      );

      final client = _ProgrammableJikkyoClient(
        onFetchKakolog: ({
          required String jkId,
          required DateTime startTime,
          required DateTime endTime,
        }) {
          final relStartSec = startTime.difference(base).inSeconds;
          if (jkId == 'jk1') {
            return staleChunk0.future;
          }
          if (relStartSec == 0) {
            chunk0Attempts++;
            if (chunk0Attempts == 1) {
              return Future<List<JikkyoComment>>.error(
                const JikkyoFetchException('HTTP 503', statusCode: 503),
              );
            }
            return retryChunk0Completer.future;
          }
          return chunk1Completer.future;
        },
      );

      final ctrl = JikkyoPlaybackController(
        client: client,
        retryBackoff: const Duration(milliseconds: 10),
      );
      addTearDown(ctrl.dispose);

      // Session 1 starts and stalls on jk1 chunk 0; Session 2 supersedes it.
      ctrl.startRecorded(
        jkId: 'jk1',
        scheduledStart: base,
        duration: const Duration(minutes: 40),
      );
      ctrl.startRecorded(
        jkId: 'jk4',
        scheduledStart: base,
        duration: const Duration(minutes: 40),
      );

      // Complete stale jk1 chunk after session switch — must not count into jk4.
      staleChunk0.complete([
        JikkyoComment(
          no: 1,
          timestampMs: base.millisecondsSinceEpoch + 5000,
          text: '古いセッション',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ctrl.totalCommentCount, 0);
      expect(ctrl.recordedLoadedAny, isFalse);

      // Transient HTTP 503 on chunk 0 was NOT cached as empty; wait past retryBackoff
      // and poll at t=4s (sets initial cursor while chunk 0 retries), then t=5s.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(
        ctrl.pollRecordedComments(position: const Duration(seconds: 4)),
        isEmpty,
      );
      expect(
        ctrl.pollRecordedComments(position: const Duration(seconds: 5)),
        isEmpty,
      );
      // Also request chunk 1 playback body while chunk1Completer (started by
      // momentum prefetch with keepBody: false) is still in flight -> promotion!
      expect(
        ctrl.pollRecordedComments(position: const Duration(seconds: 1205)),
        isEmpty,
      );
      // Reset cursor back near t=4s for chunk 0 arrival check after promoting chunk 1.
      expect(
        ctrl.pollRecordedComments(position: const Duration(seconds: 4)),
        isEmpty,
      );
      expect(
        ctrl.pollRecordedComments(position: const Duration(seconds: 5)),
        isEmpty,
      );

      retryChunk0Completer.complete([
        JikkyoComment(
          no: 10,
          timestampMs: base.millisecondsSinceEpoch + 4500,
          text: '復帰1',
        ),
        JikkyoComment(
          no: 11,
          timestampMs: base.millisecondsSinceEpoch + 5500,
          text: '復帰2',
        ),
        boundaryComment,
      ]);
      chunk1Completer.complete([
        boundaryComment,
        JikkyoComment(
          no: 51,
          timestampMs: base.millisecondsSinceEpoch + 1206 * 1000,
          text: '昇格チャンク',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Cursor did NOT skip past 4s while chunk 0 was loading, so 4.5s & 5.5s emit now.
      final recovered = ctrl.pollRecordedComments(
        position: const Duration(seconds: 6),
      );
      expect(recovered.map((e) => e.text).toList(), ['復帰1', '復帰2']);

      // Boundary comment at 1200s must be counted ONCE across chunk 0 + chunk 1
      // (`復帰1`, `復帰2`, `境界コメント`, `昇格チャンク` => 4 total).
      expect(ctrl.totalCommentCount, 4);

      // Promoted chunk 1 body is cached and emits comments without re-fetching.
      final beforeChunk1Calls = chunk0Attempts;
      ctrl.pollRecordedComments(position: const Duration(seconds: 1199));
      final atBoundary = ctrl.pollRecordedComments(
        position: const Duration(seconds: 1201),
      );
      expect(atBoundary.map((e) => e.text).toList(), ['境界コメント']);
      expect(
        ctrl
            .pollRecordedComments(position: const Duration(seconds: 1204))
            .isEmpty,
        isTrue,
      );
      final promoted = ctrl.pollRecordedComments(
        position: const Duration(seconds: 1207),
      );
      expect(promoted.map((e) => e.text).toList(), ['昇格チャンク']);
      expect(chunk0Attempts, beforeChunk1Calls);
    });

    testWidgets('JikkyoDanmakuOverlay stops idle ticker when active list is empty', (tester) async {
      final controller = JikkyoDanmakuController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 450,
            child: JikkyoDanmakuOverlay(
              settings: JikkyoSettings.defaults,
              controller: controller,
              isPlaying: true,
            ),
          ),
        ),
      );

      // Idle ticker is stopped, so pumpAndSettle completes immediately instead of timing out.
      await tester.pumpAndSettle();

      controller.enqueue([
        const JikkyoComment(no: 1, timestampMs: 1000, text: '弾幕テスト'),
      ]);
      await tester.pump();
      // Comment finishes scrolling within ~5s and stops ticker again.
      await tester.pumpAndSettle();
    });

    testWidgets('JikkyoDanmakuOverlay updates opacity and DPR cleanly with pre-rendered sprites', (tester) async {
      final controller = JikkyoDanmakuController();
      addTearDown(controller.dispose);

      Widget buildFor(int opacityPercent, double dpr) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: const Size(800, 450), devicePixelRatio: dpr),
          child: SizedBox(
            width: 800,
            height: 450,
            child: JikkyoDanmakuOverlay(
              settings: JikkyoSettings(opacityPercent: opacityPercent),
              controller: controller,
              isPlaying: true,
            ),
          ),
        ),
      );

      await tester.pumpWidget(buildFor(30, 1.0));
      controller.enqueue([
        const JikkyoComment(no: 1, timestampMs: 1000, text: '半透明テスト'),
      ]);
      await tester.pump(const Duration(milliseconds: 250));

      await tester.pumpWidget(buildFor(50, 1.0));
      await tester.pump(const Duration(milliseconds: 250));

      await tester.pumpWidget(buildFor(100, 2.0));
      await tester.pumpAndSettle();
    });
  });

  group('Phase 3 PiP shared broadcast stream', () {
    test('retains native EventChannel sink while overlapping listeners remain subscribed', () async {
      const methodChannel = MethodChannel('com.markun.tmhb/pip_shared_test');
      const eventChannel = EventChannel('com.markun.tmhb/pip_events_shared_test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      var listenCount = 0;
      var cancelCount = 0;
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) {
            listenCount++;
          },
          onCancel: (arguments) {
            cancelCount++;
          },
        ),
      );
      addTearDown(() => messenger.setMockStreamHandler(eventChannel, null));

      final pip = PipController(
        channel: methodChannel,
        eventChannel: eventChannel,
        isSupportedOverride: true,
      );

      final eventsA = <bool>[];
      final eventsB = <bool>[];
      final subA = pip.onPipModeChanged.listen(eventsA.add);
      final subB = pip.onPipModeChanged.listen(eventsB.add);
      await Future<void>.delayed(Duration.zero);
      expect(listenCount, 1);
      expect(cancelCount, 0);

      // Cancelling A while B (e.g. pushReplacement) is subscribed must NOT cancel native sink.
      await subA.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(cancelCount, 0);

      await subB.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(cancelCount, 1);
    });
  });

  group('Phase 3 Riverpod equality, async hydration, and invalidation', () {
    test('RegisteredNasne value equality shares Riverpod family bucket across deserialization', () {
      final a = RegisteredNasne.fromJson(const {
        'host': '192.0.2.10',
        'udn': 'uuid:test-1',
        'friendlyName': 'nasne-A',
        'macAddr': '00:11:22:33:44:55',
        'registeredAt': '2026-11-25T10:00:00.000Z',
      });
      final b = RegisteredNasne.fromJson(const {
        'host': '192.0.2.10',
        'udn': 'uuid:test-1',
        'friendlyName': 'nasne-A',
        'macAddr': '00:11:22:33:44:55',
        'registeredAt': '2026-11-25T10:00:00.000Z',
      });
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('Notifiers guard ref.mounted on dispose and _dirty on concurrent edits', () async {
      // 1. Dispose before delayed read completes -> no StateError.
      final gate1 = Completer<void>();
      final store1 = _DelayedKeyValueStore(gate1);
      await store1.write('epg_show_subchannels', 'true');
      await store1.write('epg_hidden_genres', '1,2');
      await store1.write('firetv_recorded_buffer_seconds', '600');
      await store1.write('firetv_live_buffer_seconds', '120');
      await store1.write('debug_mode_enabled', 'true');
      await store1.write('selected_host', '192.0.2.5');

      final disposedContainer = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(store1)],
      );
      disposedContainer.read(showSubchannelsProvider);
      disposedContainer.read(hiddenEpgGenresProvider);
      disposedContainer.read(recordedBufferSecondsProvider);
      disposedContainer.read(liveBufferSecondsProvider);
      disposedContainer.read(debugSettingsProvider);
      disposedContainer.read(selectedHostProvider);
      disposedContainer.dispose();
      gate1.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 2. Concurrent user write before slow read finishes -> disk value does NOT clobber state.
      final gate2 = Completer<void>();
      final store2 = _DelayedKeyValueStore(gate2);
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(store2)],
      );
      addTearDown(container.dispose);

      // Seed stale disk values directly into backing map before gate releases.
      await store2.write('epg_show_subchannels', 'true');
      await store2.write('firetv_recorded_buffer_seconds', '600');
      await store2.write('firetv_live_buffer_seconds', '120');
      await store2.write('selected_host', '192.0.2.99');

      expect(container.read(showSubchannelsProvider), isFalse);
      expect(container.read(recordedBufferSecondsProvider), defaultRecordedBufferSeconds);
      expect(container.read(liveBufferSecondsProvider), defaultLiveBufferSeconds);
      expect(container.read(selectedHostProvider), isNull);

      await container.read(showSubchannelsProvider.notifier).set(false);
      await container
          .read(recordedBufferSecondsProvider.notifier)
          .set(recordedBufferOptionsSeconds.first);
      await container
          .read(liveBufferSecondsProvider.notifier)
          .set(liveBufferOptionsSeconds.first);
      await container.read(selectedHostProvider.notifier).select('192.0.2.42');

      gate2.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(showSubchannelsProvider), isFalse);
      expect(
        container.read(recordedBufferSecondsProvider),
        recordedBufferOptionsSeconds.first,
      );
      expect(
        container.read(liveBufferSecondsProvider),
        liveBufferOptionsSeconds.first,
      );
      expect(container.read(selectedHostProvider), '192.0.2.42');
    });

    testWidgets('invalidateDeviceData invalidates terrestrial, BS, and CS providers', (tester) async {
      const reg = RegisteredNasne(
        host: '192.0.2.15',
        udn: 'uuid:inv-1',
        friendlyName: 'nasne-inv',
        macAddr: '00:11:22:33:44:55',
      );
      var bsChCount = 0;
      var csChCount = 0;
      var bsLogoCount = 0;
      var csLogoCount = 0;
      final fakePng = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

      final container = ProviderContainer(
        overrides: [
          deviceInfoProvider(reg).overrideWith((ref) async => const DeviceInfo(name: 'n', softwareVersion: '2.60')),
          hddDetailsProvider(reg).overrideWith((ref) async => const []),
          liveStatusProvider(reg).overrideWith((ref) async => const LiveStatus(sections: {}, raw: {})),
          recNgProvider(reg).overrideWith((ref) async => const []),
          networkInfoProvider(reg).overrideWith((ref) async => const NetworkInfo(macAddr: '00:11:22:33:44:55', ipv4Addr: '192.0.2.15')),
          bcasInfoProvider(reg).overrideWith((ref) async => const BcasInfo(cardId: '1')),
          channelsProvider(reg).overrideWith((ref) async => const []),
          bsChannelsProvider(reg).overrideWith((ref) async {
            bsChCount++;
            return const [];
          }),
          csChannelsProvider(reg).overrideWith((ref) async {
            csChCount++;
            return const [];
          }),
          epgGuideProvider(reg).overrideWith((ref) async => EpgGuide(broadcastingType: 2, fetchedAt: DateTime.utc(2026), services: const [])),
          bsEpgGuideProvider(reg).overrideWith((ref) async => EpgGuide(broadcastingType: 3, fetchedAt: DateTime.utc(2026), services: const [])),
          channelLogosProvider(reg).overrideWith((ref) async => {1: fakePng}),
          bsChannelLogosProvider(reg).overrideWith((ref) async {
            bsLogoCount++;
            return {101: fakePng};
          }),
          csChannelLogosProvider(reg).overrideWith((ref) async {
            csLogoCount++;
            return {333: fakePng};
          }),
          schedulesProvider(reg).overrideWith((ref) async => const []),
          titlesProvider(reg).overrideWith(() => _EmptyTitlesNotifier(reg)),
          titleCountsProvider(reg).overrideWith((ref) async => const TitleCounts(0, 3000)),
          liveChannelsProvider(reg).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);

      late WidgetRef capturedRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                ref.watch(bsChannelsProvider(reg));
                ref.watch(csChannelsProvider(reg));
                ref.watch(bsChannelLogosProvider(reg));
                ref.watch(csChannelLogosProvider(reg));
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(bsChCount, 1);
      expect(csChCount, 1);
      expect(bsLogoCount, 1);
      expect(csLogoCount, 1);

      invalidateDeviceData(capturedRef, reg);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(bsChCount, greaterThanOrEqualTo(2));
      expect(csChCount, greaterThanOrEqualTo(2));
      expect(bsLogoCount, greaterThanOrEqualTo(2));
      expect(csLogoCount, greaterThanOrEqualTo(2));
    });
  });

  group('Phase 3 store corruption quarantine & Isolate threshold', () {
    test('JsonFileRegistrationStore quarantines schema-invalid entries into .corrupt', () async {
      final dir = await Directory.systemTemp.createTemp('tmhb_phase3_reg_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/registrations.json');
      await file.writeAsString(jsonEncode([{'host': '192.0.2.1'}])); // missing macAddr

      final store = JsonFileRegistrationStore(file);
      expect(await store.loadAll(), isEmpty);
      expect(await File('${file.path}.corrupt').exists(), isTrue);
    });

    test('JsonFileKeyValueStore round-trips >64KB payload via Isolate and EpgGuideCache tolerates bad event', () async {
      final dir = await Directory.systemTemp.createTemp('tmhb_phase3_kv_');
      addTearDown(() => dir.delete(recursive: true));
      final kv = JsonFileKeyValueStore(File('${dir.path}/kv.json'));
      final bigValue = 'A' * 70000;
      await kv.write('big', bigValue);
      expect(await kv.read('big'), bigValue);

      await kv.write(
        '${EpgGuideCache.keyPrefix}192.0.2.1:2',
        jsonEncode({
          'services': [
            {
              'serviceId': 1024,
              'events': [
                {'eventId': 'not-a-num'},
              ],
            },
          ],
        }),
      );
      final epgCache = EpgGuideCache(kv);
      expect(await epgCache.load('192.0.2.1', 2), isEmpty);
    });
  });
}

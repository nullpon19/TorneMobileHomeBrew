/// Tests for Fire TV provisional modifications:
/// - DtcpCredentialScreen 2-column inputs, top action buttons, in-app picker
/// - TitleDetailView 1/4 thumbnail + 3/4 title header, top play button, omitted long info
/// - TailscaleGuard startup volume max & VPN/Tailscale prompt
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/firetv_helper.dart';
import 'package:tmhb/app/firetv_preset.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/main.dart';
import 'package:tmhb/ui/dtcp_credential_screen.dart';
import 'package:tmhb/ui/player_cache_policy.dart';
import 'package:tmhb/ui/player_screen.dart';
import 'package:tmhb/ui/settings_screen.dart';
import 'package:tmhb/ui/tailscale_guard.dart';
import 'package:tmhb/ui/titles_screen.dart';

import 'dtcp_kat.dart';

class _FakeFireTvHelper extends FireTvHelper {
  _FakeFireTvHelper({
    this.reachable = true,
    this.vpnActive = false,
    this.tailscaleInstalled = true,
    this.connectSucceeds = false,
    this.candidates = const [],
    this.fileBytesMap = const {},
  }) : super(isAndroidOverride: true);

  bool reachable;
  bool vpnActive;
  bool tailscaleInstalled;
  bool connectSucceeds;
  List<CredentialCandidateFile> candidates;
  Map<String, Uint8List> fileBytesMap;

  int volumeMaxCalls = 0;
  int tryConnectCalls = 0;
  int launchCalls = 0;

  @override
  Future<bool> setMediaVolumeMax() async {
    volumeMaxCalls++;
    return true;
  }

  @override
  Future<bool> isNasneReachable(
    String host, {
    Duration timeout = const Duration(milliseconds: 1800),
  }) async => reachable;

  @override
  Future<bool> isVpnActive() async => vpnActive;

  @override
  Future<bool> isTailscaleInstalled() async => tailscaleInstalled;

  @override
  Future<bool> tryConnectTailscale() async {
    tryConnectCalls++;
    if (connectSucceeds) vpnActive = true;
    return true;
  }

  @override
  Future<bool> launchTailscale() async {
    launchCalls++;
    return true;
  }

  @override
  Future<bool> hasStoragePermission() async => true;

  @override
  Future<String?> getAppFilesDirPath() async =>
      '/sdcard/Android/data/com.markun.tmhb.firetv/files';

  @override
  Future<List<CredentialCandidateFile>> listCredentialCandidateFiles() async =>
      candidates;

  @override
  Future<Uint8List?> readFileBytes(String path) async => fileBytesMap[path];
}

void main() {
  group('DtcpCredentialScreen Fire TV layout & file picker', () {
    testWidgets('buttons sit above 2-column side-by-side text fields', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = InMemoryCredentialStore(
        authorityKeys: [hexToBytes(katAuthPub)],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            credentialStoreProvider.overrideWithValue(store),
            fireTvHelperProvider.overrideWithValue(_FakeFireTvHelper()),
          ],
          child: const MaterialApp(home: DtcpCredentialScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      final certRect = tester.getRect(fields.first);
      final keyRect = tester.getRect(fields.last);
      // Side by side in 2 columns.
      expect(certRect.left, lessThan(keyRect.left));
      expect((certRect.top - keyRect.top).abs(), lessThan(4));

      // Action buttons sit above the inputs.
      final envBtnRect = tester.getRect(
        find.text('ファイルから読み込む (credentials.env)'),
      );
      final saveBtnRect = tester.getRect(find.text('検証して保存'));
      expect(envBtnRect.bottom, lessThan(certRect.top));
      expect(saveBtnRect.bottom, lessThan(certRect.top));
    });

    testWidgets('in-app Fire TV file picker imports credentials.env', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const filePath = '/sdcard/Download/credentials.1.env';
      final envContent = utf8.encode(
        'PYDTCPIP_CERTIFICATE=$katSinkCert\n'
        'PYDTCPIP_PRIVATE_KEY=$katSinkPriv\n',
      );
      final helper = _FakeFireTvHelper(
        candidates: const [
          CredentialCandidateFile(
            path: filePath,
            name: 'credentials.1.env',
            folder: 'Download',
            size: 260,
          ),
        ],
        fileBytesMap: {filePath: Uint8List.fromList(envContent)},
      );
      final store = InMemoryCredentialStore(
        authorityKeys: [hexToBytes(katAuthPub)],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            credentialStoreProvider.overrideWithValue(store),
            fireTvHelperProvider.overrideWithValue(helper),
          ],
          child: const MaterialApp(home: DtcpCredentialScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('ファイルから読み込む (credentials.env)'));
      await tester.pumpAndSettle();

      expect(find.text('資格情報ファイルを選択'), findsOneWidget);
      expect(find.text('credentials.1.env'), findsOneWidget);

      await tester.tap(find.text('credentials.1.env'));
      await tester.pumpAndSettle();

      expect(await store.hasCredentials, isTrue);
      expect(find.text('インポート済み'), findsOneWidget);
    });
  });

  group('TitleDetailView Fire TV compact header', () {
    testWidgets('renders 1/4 thumbnail + 3/4 title with play button on top', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      final title = RecordedTitle(
        id: '10',
        title: 'とても長いタイトルのテスト番組です',
        channelName: 'テスト局',
        scheduledStart: DateTime.parse('2026-11-22T20:00:00+09:00'),
        scheduledDurationSeconds: 3600,
        description: '短い概要テキスト',
        longDescription: '省略されるべき非常に長い詳細テキスト',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            channelsProvider.overrideWith((ref, r) async => const []),
            titleThumbnailProvider.overrideWith((ref, k) async => null),
            credentialSummaryProvider.overrideWith((ref) async => null),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TitleDetailView(reg: reg, title: title),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final thumbBox = tester.getSize(find.byType(AspectRatio));
      final titleRect = tester.getRect(find.text('とても長いタイトルのテスト番組です'));
      final playRect = tester.getRect(find.text('再生'));
      final descRect = tester.getRect(find.text('短い概要テキスト'));

      // 1/4 thumbnail (~228px on 960px width minus padding/gap) vs 3/4 title.
      expect(thumbBox.width, lessThan(260));
      expect(titleRect.left, greaterThan(thumbBox.width));
      // Play button stays visible above description, longDescription is omitted.
      expect(playRect.bottom, lessThan(descRect.top));
      expect(playRect.bottom, lessThan(540));
      expect(find.text('省略されるべき非常に長い詳細テキスト'), findsNothing);
    });
  });

  group('TailscaleGuard', () {
    const reg = RegisteredNasne(
      host: '192.0.2.1',
      udn: 'uuid:test',
      friendlyName: 'nasne',
      macAddr: '00:11:22:33:44:55',
    );

    testWidgets('shows dialog when unreachable and VPN off; launches Tailscale', (
      tester,
    ) async {
      final helper = _FakeFireTvHelper(
        reachable: false,
        vpnActive: false,
        tailscaleInstalled: true,
        connectSucceeds: false,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [reg]),
            ),
            fireTvHelperProvider.overrideWithValue(helper),
          ],
          child: const MaterialApp(
            home: TailscaleGuard(child: Scaffold(body: Text('home'))),
          ),
        ),
      );
      // Let startup + 6x500ms connect polling finish.
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      expect(helper.volumeMaxCalls, greaterThanOrEqualTo(1));
      expect(helper.tryConnectCalls, 1);
      expect(find.text('Tailscale が起動していません'), findsOneWidget);

      await tester.tap(find.text('Tailscale を開く'));
      await tester.pumpAndSettle();
      expect(helper.launchCalls, 1);
    });

    testWidgets('stays silent when nasne is reachable', (tester) async {
      final helper = _FakeFireTvHelper(reachable: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [reg]),
            ),
            fireTvHelperProvider.overrideWithValue(helper),
          ],
          child: const MaterialApp(
            home: TailscaleGuard(child: Scaffold(body: Text('home'))),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(helper.volumeMaxCalls, greaterThanOrEqualTo(1));
      expect(helper.tryConnectCalls, 0);
      expect(find.text('Tailscale が起動していません'), findsNothing);
    });
  });

  group('FireTvPreset seeding', () {
    const samplePreset = FireTvPreset(
      certHex: katSinkCert,
      keyHex: katSinkPriv,
      nasneHost: '192.168.10.171',
      nasneUdn: 'uuid:test-nasne',
      nasneName: 'nasne',
      nasneMac: '00:25:dc:5a:4d:e5',
    );

    test('seeds credentials and nasne once and respects later deletion', () async {
      final kv = InMemoryKeyValueStore();
      final credStore = InMemoryCredentialStore(
        authorityKeys: [hexToBytes(katAuthPub)],
      );
      final regStore = InMemoryRegistrationStore();

      // First launch applies both presets.
      await applyFireTvPresetsIfNeeded(
        keyValues: kv,
        credentialStore: credStore,
        registrationStore: regStore,
        preset: samplePreset,
      );
      expect(await credStore.hasCredentials, isTrue);
      final regs1 = await regStore.loadAll();
      expect(regs1.map((r) => r.host), ['192.168.10.171']);
      expect(await kv.read(presetCredAppliedKey), 'true');
      expect(await kv.read(presetNasneAppliedKey), 'true');

      // User deletes both on a later launch; presets must not re-apply.
      await credStore.delete();
      await regStore.remove('192.168.10.171');
      await applyFireTvPresetsIfNeeded(
        keyValues: kv,
        credentialStore: credStore,
        registrationStore: regStore,
        preset: samplePreset,
      );
      expect(await credStore.hasCredentials, isFalse);
      expect(await regStore.loadAll(), isEmpty);
    });

    test('does not overwrite already-configured stores', () async {
      final kv = InMemoryKeyValueStore();
      final credStore = InMemoryCredentialStore(
        authorityKeys: [hexToBytes(katAuthPub)],
      );
      await credStore.save(
        certificate: hexToBytes(katSinkCert),
        privateKey: hexToBytes(katSinkPriv),
      );
      const existingReg = RegisteredNasne(
        host: '10.0.0.5',
        udn: 'uuid:custom',
        friendlyName: 'custom-nasne',
        macAddr: '00:11:22:33:44:55',
      );
      final regStore = InMemoryRegistrationStore([existingReg]);

      await applyFireTvPresetsIfNeeded(
        keyValues: kv,
        credentialStore: credStore,
        registrationStore: regStore,
        preset: samplePreset,
      );
      final regs = await regStore.loadAll();
      expect(regs.map((r) => r.host), ['10.0.0.5']);
    });

    testWidgets('preset restore button appears and saves credentials', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = InMemoryCredentialStore(
        authorityKeys: [hexToBytes(katAuthPub)],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            credentialStoreProvider.overrideWithValue(store),
            fireTvHelperProvider.overrideWithValue(_FakeFireTvHelper()),
            fireTvPresetProvider.overrideWithValue(samplePreset),
          ],
          child: const MaterialApp(home: DtcpCredentialScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('内蔵プリセットを読み込む'), findsOneWidget);
      await tester.tap(find.text('内蔵プリセットを読み込む'));
      await tester.pumpAndSettle();

      expect(await store.hasCredentials, isTrue);
      expect(find.text('インポート済み'), findsOneWidget);
    });
  });

  group('PlayerScreen loading indicator & Android cache sizing', () {
    test('playerLoadingLabel shows loading until first video frame arrives', () {
      expect(
        playerLoadingLabel(
          interrupted: false,
          hasVideoFrame: false,
          playingStarted: false,
          playingNow: false,
          buffering: true,
        ),
        '読み込み中…',
      );
      expect(
        playerLoadingLabel(
          interrupted: false,
          hasVideoFrame: false,
          playingStarted: true,
          playingNow: true,
          buffering: false,
        ),
        '読み込み中…',
      );
      expect(
        playerLoadingLabel(
          interrupted: false,
          hasVideoFrame: true,
          playingStarted: true,
          playingNow: true,
          buffering: false,
        ),
        isNull,
      );
      expect(
        playerLoadingLabel(
          interrupted: false,
          hasVideoFrame: true,
          playingStarted: true,
          playingNow: true,
          buffering: true,
        ),
        'バッファリング中…',
      );
      expect(
        playerLoadingLabel(
          interrupted: false,
          hasVideoFrame: true,
          playingStarted: true,
          playingNow: false,
          buffering: true,
        ),
        isNull,
      );
      expect(
        playerLoadingLabel(
          interrupted: true,
          hasVideoFrame: false,
          playingStarted: true,
          playingNow: false,
          buffering: true,
        ),
        isNull,
      );
    });

    test('effectiveRecordingDemuxerMaxBytes uses compact Android limits', () {
      expect(
        effectiveRecordingDemuxerMaxBytes(isAndroid: true),
        androidRecordingDemuxerMaxBytes,
      );
      expect(
        effectiveRecordingDemuxerMaxBackBytes(isAndroid: true),
        androidRecordingDemuxerMaxBackBytes,
      );
      expect(
        effectiveRecordingDemuxerMaxBytes(isAndroid: false),
        recordingDemuxerMaxBytes,
      );
      expect(
        effectiveRecordingDemuxerMaxBackBytes(isAndroid: false),
        recordingDemuxerMaxBackBytes,
      );
      expect(
        androidRecordingDemuxerMaxBytes,
        lessThan(recordingDemuxerMaxBytes),
      );
      expect(
        androidProxyWindowCapBytes,
        lessThan(DtcpProxy.windowCapBytes),
      );
    });
  });

  group('computeMpvBufferPlan & Settings buffer UI', () {
    test('plans recorded RAM and disk cache up to 60 min safely', () {
      final off = computeMpvBufferPlan(
        live: false,
        bufferSeconds: 0,
        isAndroid: true,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(off.useCache, isTrue);
      expect(off.useDiskCache, isFalse);
      expect(off.demuxerMaxBytes, androidRecordingDemuxerMaxBytes);
      expect(off.cachePauseInitial, isFalse);

      final fiveMin = computeMpvBufferPlan(
        live: false,
        bufferSeconds: 300,
        isAndroid: true,
        availableDiskBytes: 6 * 1024 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(fiveMin.useDiskCache, isTrue);
      expect(fiveMin.cacheDirPath, '/tmp/mpv_cache');
      expect(fiveMin.cachePauseInitial, isTrue);
      expect(fiveMin.cachePauseWaitSeconds, 5);
      expect(fiveMin.demuxerMaxBytes, 105 * 1024 * 1024);

      final hour = computeMpvBufferPlan(
        live: false,
        bufferSeconds: 3600,
        isAndroid: true,
        availableDiskBytes: 6 * 1024 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(hour.useDiskCache, isTrue);
      expect(hour.demuxerMaxBytes, maxDiskCacheBytes);
      expect(hour.demuxerMaxBackBytes, maxDiskBackCacheBytes);
      expect(hour.networkTimeoutSeconds, 600);

      // Clamps when available disk is tight, leaving >= 512 MiB free.
      final tight = computeMpvBufferPlan(
        live: false,
        bufferSeconds: 3600,
        isAndroid: true,
        availableDiskBytes: 800 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(tight.useDiskCache, isTrue);
      expect(tight.demuxerMaxBytes, 288 * 1024 * 1024);

      // Falls back to RAM when free storage is below reserve + 16 MiB.
      final tiny = computeMpvBufferPlan(
        live: false,
        bufferSeconds: 3600,
        isAndroid: true,
        availableDiskBytes: 400 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(tiny.useDiskCache, isFalse);
      expect(tiny.demuxerMaxBytes, lessThanOrEqualTo(24 * 1024 * 1024));
    });

    test('plans live radiko-style initial buffering and timeouts', () {
      final liveOff = computeMpvBufferPlan(
        live: true,
        bufferSeconds: 0,
        isAndroid: true,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(liveOff.useCache, isFalse);
      expect(liveOff.cachePauseInitial, isFalse);

      final liveThreeMin = computeMpvBufferPlan(
        live: true,
        bufferSeconds: 180,
        isAndroid: true,
        availableDiskBytes: 4 * 1024 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(liveThreeMin.useCache, isTrue);
      expect(liveThreeMin.useDiskCache, isTrue);
      expect(liveThreeMin.cachePauseInitial, isTrue);
      expect(liveThreeMin.cachePauseWaitSeconds, 180);
      expect(liveThreeMin.networkTimeoutSeconds, 210);
      expect(liveThreeMin.startTimeoutSeconds, 225);
    });

    testWidgets('TmhbApp forces ja-JP locale to avoid Chinese glyph fallback', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const ProviderScope(child: TmhbApp()));
      await tester.pumpAndSettle();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.locale, const Locale('ja', 'JP'));
      expect(app.supportedLocales, contains(const Locale('ja', 'JP')));
    });

    testWidgets('SettingsScreen updates and persists recorded & live buffers', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final kv = InMemoryKeyValueStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [keyValueStoreProvider.overrideWithValue(kv)],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('録画のバッファ時間（先読み）'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('5分'), findsOneWidget);
      await tester.tap(find.text('録画のバッファ時間（先読み）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('60分'));
      await tester.pumpAndSettle();
      expect(await kv.read('firetv_recorded_buffer_seconds'), '3600');

      await tester.scrollUntilVisible(
        find.text('Live のバッファ時間（遅延再生）'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Live のバッファ時間（遅延再生）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3分'));
      await tester.pumpAndSettle();
      expect(await kv.read('firetv_live_buffer_seconds'), '180');
    });
  });
}

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
import 'package:tmhb/ui/app_shell.dart';
import 'package:tmhb/ui/dtcp_credential_screen.dart';
import 'package:tmhb/ui/epg_screen.dart';
import 'package:tmhb/ui/player_cache_policy.dart';
import 'package:tmhb/ui/player_error_policy.dart';
import 'package:tmhb/ui/player_screen.dart';
import 'package:tmhb/ui/settings_screen.dart';
import 'package:tmhb/ui/tailscale_guard.dart';
import 'package:tmhb/ui/title_list_filter.dart';
import 'package:tmhb/ui/titles_screen.dart';
import 'package:tmhb/ui/widgets.dart';

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

      // Raw TextField must not be exposed directly so FireTVIME never traps D-pad.
      expect(find.byType(TextField), findsNothing);
      final fields = find.byType(FireTvTextInputField);
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

      // Explicit tap opens the input dialog and saves back on 決定.
      await tester.tap(fields.first);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'deadbeef');
      await tester.tap(find.text('決定'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('deadbeef'), findsOneWidget);
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

    testWidgets(
      'TmhbApp forces ja-JP locale and switches ThemeMode with nightModeProvider',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final kv = InMemoryKeyValueStore();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [keyValueStoreProvider.overrideWithValue(kv)],
            child: const TmhbApp(),
          ),
        );
        await tester.pumpAndSettle();

        var app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.locale, const Locale('ja', 'JP'));
        expect(app.supportedLocales, contains(const Locale('ja', 'JP')));
        expect(app.themeMode, ThemeMode.light);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp)),
        );
        await container.read(nightModeProvider.notifier).set(true);
        await tester.pumpAndSettle();

        app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.themeMode, ThemeMode.dark);
        expect(await kv.read('firetv_night_mode'), 'true');
      },
    );

    testWidgets(
      'SettingsScreen hides raw TextField, toggles night mode, and puts Live '
      'buffer above Recorded without extra promo copy',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
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

        // Raw TextField stays hidden until manual IP field is tapped.
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(FireTvTextInputField), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('ナイトモード'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('ナイトモード'));
        await tester.pumpAndSettle();
        expect(await kv.read('firetv_night_mode'), 'true');

        await tester.scrollUntilVisible(
          find.text('録画のバッファ時間（先読み）'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        final liveRect = tester.getRect(find.text('Live のバッファ時間（遅延再生）'));
        final recRect = tester.getRect(find.text('録画のバッファ時間（先読み）'));
        expect(liveRect.top, lessThan(recRect.top));
        expect(find.textContaining('ギガ消費'), findsNothing);

        expect(find.text('5分'), findsOneWidget);
        await tester.tap(find.text('録画のバッファ時間（先読み）'));
        await tester.pumpAndSettle();
        expect(find.textContaining('車載おすすめ'), findsNothing);
        await tester.tap(find.text('60分'));
        await tester.pumpAndSettle();
        expect(await kv.read('firetv_recorded_buffer_seconds'), '3600');

        await tester.scrollUntilVisible(
          find.text('Live のバッファ時間（遅延再生）'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Live のバッファ時間（遅延再生）'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('3分'));
        await tester.pumpAndSettle();
        expect(await kv.read('firetv_live_buffer_seconds'), '180');
      },
    );

    test('PlayerScreen D-pad seek steps are both 10 seconds', () {
      expect(PlayerScreen.rewindStep, const Duration(seconds: -10));
      expect(PlayerScreen.forwardStep, const Duration(seconds: 10));
    });

    testWidgets(
      'EpgScreen event tile shows a crisp foreground focus border without tinting '
      'the background',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.1',
          udn: 'uuid:epg-focus-test',
          friendlyName: 'nasne',
          macAddr: '00:11:22:33:44:55',
        );
        const channel = Channel(
          broadcastingType: 2,
          networkId: 0x1111,
          transportStreamId: 0x2222,
          serviceId: 0x3333,
          serviceType: 1,
          channelNumber: 1,
          serviceName: 'テスト放送',
        );
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            EpgServiceGuide(
              channel: channel,
              events: [
                EpgEvent(
                  eventId: 42,
                  start: DateTime.now().toUtc(),
                  duration: const Duration(hours: 2),
                  title: 'フォーカス確認番組',
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
                InMemoryRegistrationStore(const [reg]),
              ),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: EpgScreen()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final tileInkWellFinder = find.ancestor(
          of: find.text('フォーカス確認番組'),
          matching: find.byType(InkWell),
        );
        expect(tileInkWellFinder, findsOneWidget);
        final inkWell = tester.widget<InkWell>(tileInkWellFinder);
        expect(inkWell.focusColor, Colors.transparent);

        final decoratedFinder = find.ancestor(
          of: tileInkWellFinder,
          matching: find.byType(DecoratedBox),
        );
        expect(decoratedFinder, findsWidgets);
        // Trigger focus on the tile InkWell.
        inkWell.onFocusChange?.call(true);
        await tester.pump();

        final decorated = tester.widget<DecoratedBox>(decoratedFinder.first);
        expect(decorated.position, DecorationPosition.foreground);
        final box = decorated.decoration as BoxDecoration;
        expect(box.border, isNotNull);
        expect(box.border!.top.width, 3);
        expect(box.border!.top.color, const Color(0xFFD32F2F));
      },
    );
  });

  group('Recorded title series grouping', () {
    RecordedTitle title({
      required String id,
      required String titleText,
      String? startJst,
      bool protectFlag = false,
      bool newFlag = false,
    }) => RecordedTitle(
      id: id,
      title: titleText,
      scheduledStart: startJst != null ? DateTime.parse(startJst) : null,
      protectFlag: protectFlag,
      newFlag: newFlag,
    );

    test('groups normalized episodes and protects distinct singletons', () {
      final items = [
        title(
          id: '1',
          titleText: '[新]わんだふるぷりきゅあ! #36 特別なワンダフル![デ][字]',
          startJst: '2024-10-06T08:30:00+09:00',
          newFlag: true,
        ),
        title(
          id: '2',
          titleText: 'わんだふるぷりきゅあ! #37 みんなで初デート!?[デ][字]',
          startJst: '2024-10-13T08:29:00+09:00',
        ),
        title(
          id: '3',
          titleText: '爆上戦隊ブンブンジャー バクアゲ36 夢へと走る道[デ][字]',
          startJst: '2024-11-10T09:30:00+09:00',
          protectFlag: true,
        ),
        title(
          id: '4',
          titleText: '爆上戦隊ブンブンジャー バクアゲ37 秘密のテスト[終][字]',
          startJst: '2024-11-17T09:30:00+09:00',
          protectFlag: true,
        ),
        title(
          id: '4b',
          titleText: '爆上戦隊ブンブンジャー バクアゲ38 テスト回[字]',
          startJst: '2024-11-24T09:30:00+09:00',
          protectFlag: true,
        ),
        title(
          id: '5',
          titleText: '明治安田J2リーグ 秋田×山形',
          startJst: '2024-06-23T14:00:00+09:00',
        ),
        title(
          id: '6',
          titleText: '明治安田J2リーグ 秋田×仙台',
          startJst: '2024-09-29T14:00:00+09:00',
        ),
        title(
          id: '7',
          titleText: 'ヨルタモリ',
          startJst: '2015-04-26T23:15:00+09:00',
        ),
        title(
          id: '8',
          titleText: 'ヨルタモリ 特別編[字]',
          startJst: '2015-09-13T23:15:00+09:00',
        ),
        title(
          id: '9',
          titleText: '296ももクロ団 #7',
          startJst: '2012-12-08T00:30:00+09:00',
        ),
        title(
          id: '10',
          titleText: '298ももクロ式見学ガイド もも見!! #20',
          startJst: '2012-11-18T23:50:00+09:00',
        ),
        title(
          id: '11',
          titleText: '録画タイトルA',
          startJst: '2026-11-15T11:34:46+09:00',
        ),
        title(
          id: '12',
          titleText: '録画タイトルB',
          startJst: '2026-11-15T12:00:00+09:00',
        ),
        title(
          id: '13',
          titleText: '081モヤモヤさまぁ〜ず2',
          startJst: '2017-05-06T14:00:00+09:00',
        ),
      ];

      final groups = groupRecordedTitles(
        items,
        sort: TitleSortOrder.recordedNewest,
      );
      final folders = groups.where((g) => g.isFolder).toList();
      final singles = groups.where((g) => !g.isFolder).toList();

      expect(folders.map((g) => g.label).toSet(), {
        'わんだふるぷりきゅあ!',
        '爆上戦隊ブンブンジャー バクアゲ',
        '明治安田J2リーグ',
        'ヨルタモリ',
      });
      expect(singles.map((g) => g.titles.single.id).toSet(), {
        '9',
        '10',
        '11',
        '12',
        '13',
      });

      final precure = folders.firstWhere((g) => g.label == 'わんだふるぷりきゅあ!');
      expect(precure.hasUnwatched, isTrue);
      expect(precure.allProtected, isFalse);
      expect(precure.titles.map((t) => t.id), ['2', '1']);

      final boon = folders.firstWhere((g) => g.label == '爆上戦隊ブンブンジャー バクアゲ');
      expect(boon.label, '爆上戦隊ブンブンジャー バクアゲ');
      expect(boon.titles.length, 3);
      expect(boon.allProtected, isTrue);
      expect(boon.hasUnwatched, isFalse);
    });

    test('outer folders and expanded episodes match selected TitleSortOrder', () {
      final items = [
        title(
          id: 'p1',
          titleText: 'わんだふるぷりきゅあ! #36',
          startJst: '2024-10-06T08:30:00+09:00',
        ),
        title(
          id: 'p2',
          titleText: 'わんだふるぷりきゅあ! #37',
          startJst: '2024-10-13T08:30:00+09:00',
        ),
        title(
          id: 'b1',
          titleText: 'あいうえお番組 #1',
          startJst: '2024-09-01T10:00:00+09:00',
        ),
        title(
          id: 'b2',
          titleText: 'あいうえお番組 #2',
          startJst: '2024-09-08T10:00:00+09:00',
        ),
      ];

      final newest = groupRecordedTitles(
        items,
        sort: TitleSortOrder.recordedNewest,
      );
      expect(newest.map((g) => g.label), ['わんだふるぷりきゅあ!', 'あいうえお番組']);
      expect(newest.first.titles.map((t) => t.id), ['p2', 'p1']);

      final oldest = groupRecordedTitles(
        items,
        sort: TitleSortOrder.recordedOldest,
      );
      expect(oldest.map((g) => g.label), ['あいうえお番組', 'わんだふるぷりきゅあ!']);
      expect(oldest.last.titles.map((t) => t.id), ['p1', 'p2']);

      final byTitle = groupRecordedTitles(
        items,
        sort: TitleSortOrder.titleAsc,
      );
      expect(byTitle.map((g) => g.label), ['あいうえお番組', 'わんだふるぷりきゅあ!']);
      expect(byTitle.last.titles.map((t) => t.id), ['p1', 'p2']);
    });
  });

  group('TitlesScreen collapsible series folders & chip', () {
    testWidgets('collapses series by default, expands inline, and toggles chip', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.50',
        udn: 'uuid:titles-group-test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:66',
      );
      final items = [
        RecordedTitle(
          id: 'e36',
          title: 'わんだふるぷりきゅあ! #36 特別なワンダフル![デ][字]',
          scheduledStart: DateTime.parse('2024-10-06T08:30:00+09:00'),
          newFlag: true,
        ),
        RecordedTitle(
          id: 'e37',
          title: 'わんだふるぷりきゅあ! #37 みんなで初デート!?[デ][字]',
          scheduledStart: DateTime.parse('2024-10-13T08:30:00+09:00'),
        ),
        RecordedTitle(
          id: 'solo',
          title: '081モヤモヤさまぁ〜ず2',
          scheduledStart: DateTime.parse('2017-05-06T14:00:00+09:00'),
        ),
      ];
      final kv = InMemoryKeyValueStore();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [reg]),
            ),
            keyValueStoreProvider.overrideWithValue(kv),
            titlesProvider(reg).overrideWith(
              () => _FixedTitlesNotifier(reg, items),
            ),
            titleCountsProvider.overrideWith(
              (ref, r) async => TitleCounts(items.length, 3000),
            ),
            titleThumbnailProvider.overrideWith((ref, k) async => null),
            channelsProvider.overrideWith((ref, r) async => const []),
          ],
          child: const MaterialApp(home: TitlesScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Collapsed folder row is shown while individual episodes remain hidden.
      expect(find.text('わんだふるぷりきゅあ!'), findsOneWidget);
      expect(find.text('全 2 本'), findsOneWidget);
      expect(find.text('2024/10/06 〜 2024/10/13'), findsOneWidget);
      expect(find.text('081モヤモヤさまぁ〜ず2'), findsOneWidget);
      expect(
        find.text('わんだふるぷりきゅあ! #36 特別なワンダフル![デ][字]'),
        findsNothing,
      );

      // Tap folder to expand inline underneath.
      await tester.tap(find.text('わんだふるぷりきゅあ!'));
      await tester.pumpAndSettle();
      expect(
        find.text('わんだふるぷりきゅあ! #37 みんなで初デート!?[デ][字]'),
        findsOneWidget,
      );
      expect(
        find.text('わんだふるぷりきゅあ! #36 特別なワンダフル![デ][字]'),
        findsOneWidget,
      );

      // Toggle grouping OFF via FilterChip and verify persistence.
      await tester.tap(find.text('番組まとめ'));
      await tester.pumpAndSettle();
      expect(find.text('全 2 本'), findsNothing);
      expect(
        find.text('わんだふるぷりきゅあ! #36 特別なワンダフル![デ][字]'),
        findsOneWidget,
      );
      expect(await kv.read('firetv_group_titles'), 'false');
    });
  });

  group('AppShell Back-key exit confirmation', () {
    testWidgets('shows confirmation dialog on root Back and cancels cleanly', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const []),
            ),
            keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
            fireTvHelperProvider.overrideWithValue(
              _FakeFireTvHelper(reachable: true),
            ),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('アプリを終了しますか？'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('アプリを終了しますか？'), findsOneWidget);
      expect(find.text('終了する'), findsOneWidget);
      final cancelButton = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('キャンセル'),
          matching: find.byType(TextButton),
        ),
      );
      expect(cancelButton.autofocus, isTrue);

      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(find.text('アプリを終了しますか？'), findsNothing);

      // Confirm guard resets so Back opens the confirmation again.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('アプリを終了しますか？'), findsOneWidget);
    });
  });

  group('Recorded end-of-programme guard policy', () {
    test('treats near-end stops as completion only for non-live recordings', () {
      const thirtyMin = Duration(minutes: 30);
      expect(
        isNearRecordedEnd(
          live: false,
          position: const Duration(minutes: 29, seconds: 53),
          duration: thirtyMin,
        ),
        isTrue,
      );
      expect(
        isNearRecordedEnd(
          live: false,
          position: const Duration(minutes: 29, seconds: 50),
          duration: thirtyMin,
        ),
        isFalse,
      );
      expect(
        isNearRecordedEnd(
          live: false,
          position: Duration.zero,
          duration: thirtyMin,
        ),
        isFalse,
      );
      expect(
        isNearRecordedEnd(
          live: true,
          position: const Duration(minutes: 29, seconds: 59),
          duration: thirtyMin,
        ),
        isFalse,
      );

      // Short clips use a tightened 2s tolerance window.
      const twentySec = Duration(seconds: 20);
      expect(
        isNearRecordedEnd(
          live: false,
          position: const Duration(seconds: 19),
          duration: twentySec,
        ),
        isTrue,
      );
      expect(
        isNearRecordedEnd(
          live: false,
          position: const Duration(seconds: 15),
          duration: twentySec,
        ),
        isFalse,
      );
      expect(
        isNearRecordedEnd(
          live: false,
          position: Duration.zero,
          duration: twentySec,
        ),
        isFalse,
      );
    });
  });
}

class _FixedTitlesNotifier extends TitlesNotifier {
  _FixedTitlesNotifier(super.reg, this._items);
  final List<RecordedTitle> _items;

  @override
  Stream<TitleListProgress> build() =>
      Stream.value(TitleListProgress(_items, complete: true));
}

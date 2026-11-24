/// Tests for Fire TV provisional modifications:
/// - DtcpCredentialScreen 2-column inputs, top action buttons, in-app picker
/// - TitleDetailView 1/4 thumbnail + 3/4 title header, top play button, omitted long info
/// - TailscaleGuard startup volume max & VPN/Tailscale prompt
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/bs_epg_providers.dart';
import 'package:tmhb/app/firetv_helper.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/core/dtcp/arib_ts_caption_tap.dart';
import 'package:tmhb/main.dart';
import 'package:tmhb/ui/app_shell.dart';
import 'package:tmhb/ui/dtcp_credential_screen.dart';
import 'package:tmhb/ui/epg_screen.dart';
import 'package:tmhb/ui/format.dart';
import 'package:tmhb/ui/home_screen.dart';
import 'package:tmhb/ui/live_channel_switch_policy.dart';
import 'package:tmhb/ui/live_recording_policy.dart';
import 'package:tmhb/ui/live_screen.dart';
import 'package:tmhb/ui/multi_nasne_policy.dart';
import 'package:tmhb/ui/player_cache_policy.dart';
import 'package:tmhb/ui/player_error_policy.dart';
import 'package:tmhb/ui/player_screen.dart';
import 'package:tmhb/ui/schedule_form.dart';
import 'package:tmhb/ui/schedules_screen.dart';
import 'package:tmhb/ui/settings_screen.dart';
import 'package:tmhb/ui/subtitle_overlay.dart';
import 'package:tmhb/ui/subtitle_settings_screen.dart';
import 'package:tmhb/ui/subtitle_style_policy.dart';
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

      // Action buttons sit above the inputs, and removed built-in preset button stays absent.
      final envBtnRect = tester.getRect(
        find.text('ファイルから読み込む (credentials.env)'),
      );
      final saveBtnRect = tester.getRect(find.text('検証して保存'));
      expect(envBtnRect.bottom, lessThan(certRect.top));
      expect(saveBtnRect.bottom, lessThan(certRect.top));
      expect(find.text('内蔵プリセットを読み込む'), findsNothing);

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

    test('plans live initial buffering and timeouts', () {
      final liveOff = computeMpvBufferPlan(
        live: true,
        bufferSeconds: 0,
        isAndroid: true,
        availableDiskBytes: 2 * 1024 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
      );
      expect(liveOff.useCache, isTrue);
      expect(liveOff.useDiskCache, isTrue);
      expect(liveOff.cachePauseInitial, isFalse);
      expect(liveOff.cachePause, isFalse);
      expect(liveOff.cachePauseWaitSeconds, 0);
      expect(liveOff.readaheadSeconds, livePauseTimeshiftSeconds);
      expect(liveOff.demuxerMaxBytes, 105 * 1024 * 1024);

      final liveDrTight = computeMpvBufferPlan(
        live: true,
        bufferSeconds: 0,
        isAndroid: true,
        availableDiskBytes: 800 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
        liveUseMobile: false,
      );
      expect(liveDrTight.useCache, isTrue);
      expect(liveDrTight.useDiskCache, isTrue);
      expect(liveDrTight.cachePauseInitial, isFalse);
      expect(liveDrTight.cachePause, isFalse);
      expect(liveDrTight.demuxerMaxBytes, 288 * 1024 * 1024);

      final liveDrTiny = computeMpvBufferPlan(
        live: true,
        bufferSeconds: 0,
        isAndroid: true,
        availableDiskBytes: 400 * 1024 * 1024,
        cacheDirPath: '/tmp/mpv_cache',
        liveUseMobile: false,
      );
      expect(liveDrTiny.useCache, isTrue);
      expect(liveDrTiny.useDiskCache, isFalse);
      expect(liveDrTiny.demuxerMaxBytes, lessThanOrEqualTo(24 * 1024 * 1024));

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
      expect(liveThreeMin.cachePause, isTrue);
      expect(liveThreeMin.cachePauseWaitSeconds, 180);
      expect(liveThreeMin.readaheadSeconds, livePauseTimeshiftSeconds);
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
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
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
        expect(box.border!.top.color, Colors.black);
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
    testWidgets('moves focus to rail first on Back, then shows exit confirmation', (
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

      // Startup focus begins in NavigationRail on 'ホーム'; enter right pane first.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // 1st Back from right pane focuses active 'ホーム' item in NavigationRail.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('アプリを終了しますか？'), findsNothing);
      final railFocused = FocusManager.instance.primaryFocus?.context;
      expect(railFocused, isNotNull);
      expect(
        find.ancestor(
          of: find.byWidget(railFocused!.widget),
          matching: find.byType(NavigationRail),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byWidget(railFocused.widget),
          matching: find.text('ホーム'),
        ),
        findsOneWidget,
      );

      // 2nd Back while focus is in NavigationRail shows exit confirmation.
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

      // Confirm guard resets and focus remains in NavigationRail so Back opens it again.
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

  group('OSD program detail overlay & formatting', () {
    test('formatProgramDetailBody combines descriptions without duplication', () {
      expect(formatProgramDetailBody(), isNull);
      expect(
        formatProgramDetailBody(description: '  ', longDescription: '\n'),
        isNull,
      );
      expect(
        formatProgramDetailBody(description: '番組概要のみ'),
        '番組概要のみ',
      );
      expect(
        formatProgramDetailBody(longDescription: '詳細本文のみ'),
        '詳細本文のみ',
      );
      expect(
        formatProgramDetailBody(
          description: '短い導入文',
          longDescription: '短い導入文\n出演者: テスト太郎',
        ),
        '短い導入文\n出演者: テスト太郎',
      );
      expect(
        formatProgramDetailBody(
          description: '冒頭の紹介文。',
          longDescription: '詳細な解説やゲスト情報など。',
        ),
        '冒頭の紹介文。\n\n詳細な解説やゲスト情報など。',
      );
    });

    testWidgets(
      'ProgramDetailOverlayPanel fits within half screen height, scrolls on Up/Down, and closes on Back/Select',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final scrollController = ScrollController();
        final focusNode = FocusNode();
        addTearDown(scrollController.dispose);
        addTearDown(focusNode.dispose);

        var closeCount = 0;
        final longBody = List.generate(
          30,
          (i) => '番組詳細テスト行 ${i + 1}: 出演者や見どころ・あらすじなどを長文で表示します。',
        ).join('\n');

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    top: 20,
                    left: 28,
                    right: 28,
                    child: ProgramDetailOverlayPanel(
                      title: '詳細表示テスト番組タイトル',
                      meta: '2026/11/23 (月) 13:00 ・ 30分 ・ テスト放送 ・ アニメ',
                      body: longBody,
                      scrollController: scrollController,
                      focusNode: focusNode,
                      onClose: () => closeCount++,
                      onScrollDelta: (delta) {
                        if (!scrollController.hasClients) return;
                        final pos = scrollController.position;
                        final next = (pos.pixels + delta)
                            .clamp(pos.minScrollExtent, pos.maxScrollExtent)
                            .toDouble();
                        scrollController.jumpTo(next);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final panelSize = tester.getSize(
          find.byKey(const ValueKey('player_program_detail_panel')),
        );
        expect(panelSize.height, lessThanOrEqualTo(720 / 2));
        expect(scrollController.position.maxScrollExtent, greaterThan(0));
        expect(scrollController.offset, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        final afterDown = scrollController.offset;
        expect(afterDown, greaterThan(0));

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(scrollController.offset, lessThan(afterDown));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(closeCount, 1);

        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(closeCount, 2);

        await tester.tap(find.text('閉じる'));
        await tester.pumpAndSettle();
        expect(closeCount, 3);
      },
    );
  });

  group('EPG reservation matching, red border & edit button', () {
    test('parseScheduleEventId & findMatchingSchedule match eventId or manual time window', () {
      expect(parseScheduleEventId(',,0x1111,0x002a'), 42);
      expect(parseScheduleEventId('0x7880,0x7880,0xDE00,0x0000'), isNull);
      expect(parseScheduleEventId(''), isNull);

      const channel = Channel(
        broadcastingType: 2,
        networkId: 0x1111,
        transportStreamId: 0x2222,
        serviceId: 0x3333,
        serviceType: 1,
        channelNumber: 1,
        serviceName: 'テスト放送',
      );
      const otherChannel = Channel(
        broadcastingType: 2,
        networkId: 0x1111,
        transportStreamId: 0x2222,
        serviceId: 0x4444,
        serviceType: 1,
        channelNumber: 2,
        serviceName: '別チャンネル',
      );
      final baseStart = DateTime.parse('2026-11-23T14:00:00+09:00');
      final event = EpgEvent(
        eventId: 42,
        start: baseStart,
        duration: const Duration(minutes: 30),
        title: 'アニメ番組',
      );
      final manualEvent = EpgEvent(
        eventId: 99,
        start: baseStart.add(const Duration(hours: 2)),
        duration: const Duration(minutes: 30),
        title: '手動予約番組',
      );
      final epgSched = RecordSchedule(
        id: 's1',
        start: baseStart,
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 0x3333,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: ',,0x1111,0x002a',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
      );
      final wrongDaySched = RecordSchedule(
        id: 's_day',
        start: baseStart.add(const Duration(days: 7)),
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 0x3333,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: ',,0x1111,0x002a',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
      );
      final manualSched = RecordSchedule(
        id: 's_manual',
        start: manualEvent.start,
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 0x3333,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: '0x1111,0x2222,0x3333,0x0000',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
      );

      expect(
        findMatchingSchedule([wrongDaySched, epgSched], channel, event)?.id,
        's1',
      );
      expect(
        findMatchingSchedule([wrongDaySched], channel, event),
        isNull,
      );
      expect(
        findMatchingSchedule([epgSched], otherChannel, event),
        isNull,
      );
      expect(
        findMatchingSchedule([manualSched], channel, manualEvent)?.id,
        's_manual',
      );
    });

    testWidgets(
      'EpgScreen renders solid red fill by default, switches to red border when configured, and opens edit button',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.1',
          udn: 'uuid:epg-reserved-test',
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
        final reservedStart = DateTime.now().toUtc();
        final openStart = reservedStart.add(const Duration(minutes: 25));
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            EpgServiceGuide(
              channel: channel,
              events: [
                EpgEvent(
                  eventId: 42,
                  start: reservedStart,
                  duration: const Duration(minutes: 20),
                  title: '予約済み番組テスト',
                  genreLevel1: 3,
                ),
                EpgEvent(
                  eventId: 43,
                  start: openStart,
                  duration: const Duration(minutes: 20),
                  title: '未予約番組テスト',
                  genreLevel1: 3,
                ),
              ],
            ),
          ],
        );
        final sched = RecordSchedule(
          id: 'sched-42',
          start: reservedStart,
          durationSeconds: 1200,
          conditionId: '1',
          channel: const ScheduleChannel(
            broadcastingType: 2,
            channelType: 2,
            serviceId: 0x3333,
          ),
          desiredQualityMode: 100,
          desiredMatchingId: ',,0x1111,0x002a',
          reservationCreatorId: '2000',
          priorityFlag: 0,
          recordDestinationId: 'HDD',
          title: '予約済み番組テスト',
        );

        // 1) Default fill style (in dark theme too: #C62828 fill + white text).
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              schedulesProvider.overrideWith((ref, r) async => [sched]),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: const EpgScreen(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final reservedMaterialFinder = find.ancestor(
          of: find.text('予約済み番組テスト'),
          matching: find.byType(Material),
        );
        expect(
          tester.widget<Material>(reservedMaterialFinder.first).color,
          epgReservedFillColor,
        );
        expect(
          tester.widget<Text>(find.text('予約済み番組テスト')).style?.color,
          Colors.white,
        );
        final reservedInkWellFill = find.ancestor(
          of: find.text('予約済み番組テスト'),
          matching: find.byType(InkWell),
        );
        final outerDecoratedFill = find.ancestor(
          of: reservedInkWellFill,
          matching: find.byType(DecoratedBox),
        );
        expect(
          (tester.widget<DecoratedBox>(outerDecoratedFill.first).decoration
                  as BoxDecoration)
              .border,
          isNull,
        );

        // 2) Switch to border style via persisted preference.
        final borderKv = InMemoryKeyValueStore();
        await borderKv.write('firetv_epg_reserved_style', 'border');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              keyValueStoreProvider.overrideWithValue(borderKv),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              schedulesProvider.overrideWith((ref, r) async => [sched]),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: EpgScreen()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final reservedInkWell = find.ancestor(
          of: find.text('予約済み番組テスト'),
          matching: find.byType(InkWell),
        );
        final reservedMaterialBorder = find.ancestor(
          of: find.text('予約済み番組テスト'),
          matching: find.byType(Material),
        );
        expect(
          tester.widget<Material>(reservedMaterialBorder.first).color,
          isNot(epgReservedFillColor),
        );
        final outerDecoratedFinder = find.ancestor(
          of: reservedInkWell,
          matching: find.byType(DecoratedBox),
        );
        final unfocusedDecorated = tester.widget<DecoratedBox>(
          outerDecoratedFinder.first,
        );
        final unfocusedBox = unfocusedDecorated.decoration as BoxDecoration;
        expect(unfocusedBox.border, isNotNull);
        expect(unfocusedBox.border!.top.color, const Color(0xFFD32F2F));
        expect(unfocusedBox.border!.top.width, 2.5);

        // Focusing the reserved tile puts black focus border outside + inner red frame.
        tester.widget<InkWell>(reservedInkWell).onFocusChange?.call(true);
        await tester.pump();
        final focusedDecorated = tester.widget<DecoratedBox>(
          outerDecoratedFinder.first,
        );
        final focusedBox = focusedDecorated.decoration as BoxDecoration;
        expect(focusedBox.border!.top.color, Colors.black);
        expect(focusedBox.border!.top.width, 3);
        expect(
          find.descendant(
            of: reservedInkWell,
            matching: find.byIcon(Icons.fiber_manual_record),
          ),
          findsOneWidget,
        );

        // Tapping reserved programme offers '予約を編集' instead of '録画予約'.
        await tester.tap(find.text('予約済み番組テスト'));
        await tester.pumpAndSettle();
        expect(find.text('録画予約済み'), findsOneWidget);
        expect(find.text('予約を編集'), findsOneWidget);
        expect(find.text('録画予約'), findsNothing);

        await tester.tap(find.text('閉じる'));
        await tester.pumpAndSettle();

        // Tapping unreserved future programme still offers '録画予約'.
        await tester.tap(find.text('未予約番組テスト'));
        await tester.pumpAndSettle();
        expect(find.text('録画予約'), findsOneWidget);
        expect(find.text('予約を編集'), findsNothing);
      },
    );
  });

  group('PlayerOsdButtonBar cyclic focus & highlight style', () {
    test('osdButtonStyle uses high-contrast amber/black when focused', () {
      final style = osdButtonStyle();
      expect(
        style.backgroundColor?.resolve({WidgetState.focused}),
        Colors.amberAccent,
      );
      expect(
        style.foregroundColor?.resolve({WidgetState.focused}),
        Colors.black,
      );
      expect(
        style.side?.resolve({WidgetState.focused})?.color,
        Colors.white,
      );
      expect(style.backgroundColor?.resolve(const {}), Colors.white12);
      expect(style.foregroundColor?.resolve(const {}), Colors.white);
    });

    testWidgets(
      'arrow keys cycle between ends and keep focus inside OSD button bar',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final scope = FocusScopeNode(debugLabel: 'testOsdScope');
        final f0 = FocusNode(debugLabel: 'b0');
        final f1 = FocusNode(debugLabel: 'b1');
        final f2 = FocusNode(debugLabel: 'b2');
        addTearDown(scope.dispose);
        addTearDown(f0.dispose);
        addTearDown(f1.dispose);
        addTearDown(f2.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlayerOsdButtonBar(
                focusScopeNode: scope,
                onClose: () {},
                children: [
                  OutlinedButton.icon(
                    focusNode: f0,
                    autofocus: true,
                    style: osdButtonStyle(),
                    onPressed: () {},
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('再生'),
                  ),
                  OutlinedButton.icon(
                    focusNode: f1,
                    style: osdButtonStyle(),
                    onPressed: () {},
                    icon: const Icon(Icons.info_outline),
                    label: const Text('番組詳細'),
                  ),
                  OutlinedButton.icon(
                    focusNode: f2,
                    style: osdButtonStyle(),
                    onPressed: () {},
                    icon: const Icon(Icons.close),
                    label: const Text('閉じる'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(f0.hasPrimaryFocus, isTrue);

        // Right across all buttons loops back from rightmost (f2) -> leftmost (f0).
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(f1.hasPrimaryFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(f2.hasPrimaryFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(f0.hasPrimaryFocus, isTrue);

        // Left from leftmost (f0) loops back to rightmost (f2).
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(f2.hasPrimaryFocus, isTrue);

        // Up/Down stay trapped inside the OSD bar.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(f2.hasPrimaryFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(f2.hasPrimaryFocus, isTrue);
      },
    );
  });

  group('HomeScreen 2-column layout and Fire TV D-pad scrolling', () {
    Widget buildHomeTestApp({
      Brightness brightness = Brightness.light,
      List<RecNgItem> recNgItems = const [],
    }) {
      const reg = RegisteredNasne(
        host: '192.0.2.10',
        udn: 'uuid:home-test',
        friendlyName: 'テストnasne',
        macAddr: '00:11:22:33:44:55',
      );
      return ProviderScope(
        overrides: [
          registrationStoreProvider.overrideWithValue(
            InMemoryRegistrationStore(const [reg]),
          ),
          deviceInfoProvider.overrideWith(
            (ref, r) async => const DeviceInfo(
              name: 'テストnasne',
              softwareVersion: '0260',
              currDate: '2026-11-23T14:00:00+09:00',
              pref: '東京都',
              updateExists: true,
            ),
          ),
          hddDetailsProvider.overrideWith(
            (ref, r) async => const [
              HddDetail(
                HddEntry(
                  id: 0,
                  internal: true,
                  mounted: true,
                  registered: true,
                ),
                HddInfo(
                  id: 0,
                  internal: true,
                  format: 'xfs',
                  name: 'hdd0',
                  usedBytes: 300000000000,
                  freeBytes: 200000000000,
                  totalBytes: 500000000000,
                ),
              ),
            ],
          ),
          liveStatusProvider.overrideWith(
            (ref, r) async => const LiveStatus(sections: {}, raw: {}),
          ),
          recNgProvider.overrideWith((ref, r) async => recNgItems),
          networkInfoProvider.overrideWith(
            (ref, r) async => const NetworkInfo(
              macAddr: '00:11:22:33:44:55',
              ipv4Addr: '192.0.2.10',
              gateway: '192.0.2.1',
              dhcpEnabled: true,
            ),
          ),
          bcasInfoProvider.overrideWith(
            (ref, r) async =>
                const BcasInfo(cardId: '0000123456789999', status: 'OK'),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const HomeScreen(),
        ),
      );
    }

    Finder cardForSection(String title, {bool skipOffstage = false}) =>
        find.ancestor(
          of: find.text(title, skipOffstage: skipOffstage),
          matching: find.byType(Card, skipOffstage: skipOffstage),
        );

    testWidgets(
      'wide screen lays out paired cards side-by-side with equal heights',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(buildHomeTestApp());
        await tester.pumpAndSettle();

        final deviceRect = tester.getRect(cardForSection('本体情報'));
        final hddRect = tester.getRect(cardForSection('HDD'));
        final networkRect = tester.getRect(cardForSection('ネットワーク'));
        final bcasRect = tester.getRect(cardForSection('B-CAS'));

        expect(hddRect.left, greaterThan(deviceRect.left));
        expect(deviceRect.top, hddRect.top);
        expect((deviceRect.height - hddRect.height).abs(), lessThan(0.01));
        expect((deviceRect.width - hddRect.width).abs(), lessThan(1.0));

        expect(bcasRect.left, greaterThan(networkRect.left));
        expect(networkRect.top, bcasRect.top);
        expect((networkRect.height - bcasRect.height).abs(), lessThan(0.01));
        expect((networkRect.width - bcasRect.width).abs(), lessThan(1.0));
      },
    );

    testWidgets(
      'Fire TV D-pad scrolls all the way down to B-CAS and shows focus border',
      (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final recNgItems = List<RecNgItem>.generate(
          6,
          (i) => RecNgItem(id: 'ng-$i', title: '録画失敗テスト $i', raw: const {}),
        );

        await tester.pumpWidget(buildHomeTestApp(recNgItems: recNgItems));
        await tester.pumpAndSettle();

        final listView = tester.widget<ListView>(find.byType(ListView));
        final controller = listView.controller!;
        expect(controller.position.maxScrollExtent, greaterThan(0));
        expect(controller.offset, 0);

        final deviceCard = cardForSection('本体情報');
        final hddCard = cardForSection('HDD');
        final networkCard = cardForSection('ネットワーク');
        final bcasCard = cardForSection('B-CAS');

        expect(tester.getRect(networkCard).bottom, greaterThan(540));
        expect(tester.getRect(bcasCard).bottom, greaterThan(540));

        // Focus top-left card ('本体情報') and check light-mode black border.
        final deviceFocus = tester.widget<Focus>(
          find.ancestor(of: deviceCard, matching: find.byType(Focus)).first,
        );
        deviceFocus.focusNode!.requestFocus();
        await tester.pumpAndSettle();

        final focusedDeviceShape =
            tester.widget<Card>(deviceCard).shape as RoundedRectangleBorder?;
        expect(focusedDeviceShape?.side.color, Colors.black);
        expect(focusedDeviceShape?.side.width, 3);

        // Right moves focus to paired 'HDD' card; Left moves back.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        final focusedHddShape =
            tester.widget<Card>(hddCard).shape as RoundedRectangleBorder?;
        expect(focusedHddShape?.side.color, Colors.black);
        expect(focusedHddShape?.side.width, 3);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();

        // Down across cards scrolls all the way down to the bottom row.
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }

        expect(controller.offset, greaterThan(0));
        expect(FocusManager.instance.primaryFocus, isNotNull);
        final onstageNetworkCard = cardForSection('ネットワーク', skipOffstage: true);
        final onstageBcasCard = cardForSection('B-CAS', skipOffstage: true);
        expect(onstageNetworkCard, findsOneWidget);
        expect(onstageBcasCard, findsOneWidget);
        expect(tester.getRect(onstageNetworkCard).bottom, lessThanOrEqualTo(540.5));
        expect(tester.getRect(onstageBcasCard).bottom, lessThanOrEqualTo(540.5));
        expect(tester.getRect(onstageNetworkCard).top, greaterThanOrEqualTo(0));
        expect(tester.getRect(onstageBcasCard).top, greaterThanOrEqualTo(0));

        // Dark mode uses amberAccent focus border on Home cards.
        await tester.pumpWidget(buildHomeTestApp(brightness: Brightness.dark));
        await tester.pumpAndSettle();
        final darkDeviceFocus = tester.widget<Focus>(
          find.ancestor(of: deviceCard, matching: find.byType(Focus)).first,
        );
        darkDeviceFocus.focusNode!.requestFocus();
        await tester.pumpAndSettle();
        final darkDeviceShape =
            tester.widget<Card>(deviceCard).shape as RoundedRectangleBorder?;
        expect(darkDeviceShape?.side.color, Colors.amberAccent);
        expect(darkDeviceShape?.side.width, 3);
      },
    );

    testWidgets('narrow phone width stacks paired cards vertically', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildHomeTestApp());
      await tester.pumpAndSettle();

      final deviceRect = tester.getRect(cardForSection('本体情報'));
      final hddRect = tester.getRect(cardForSection('HDD'));
      final networkRect = tester.getRect(cardForSection('ネットワーク'));
      final bcasRect = tester.getRect(cardForSection('B-CAS'));

      expect(hddRect.top, greaterThanOrEqualTo(deviceRect.bottom));
      expect(bcasRect.top, greaterThanOrEqualTo(networkRect.bottom));
    });
  });

  group('Phase 14: OSD Back key, SegmentedButton focus, EPG top bar jump', () {
    test('resolvePlayerBackOutcome enforces detail -> OSD -> pop sequence & suppress guard', () {
      expect(playerOsdCloseMenuLabel, 'メニューを閉じる');

      final now = DateTime.utc(2026, 11, 23, 5, 0, 0);
      final activeSuppress = now.add(const Duration(milliseconds: 300));
      final expiredSuppress = now.subtract(const Duration(milliseconds: 10));

      // Duplicate popRoute right after KeyDown closed detail or OSD must be suppressed.
      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: true,
          suppressUntil: activeSuppress,
          now: now,
        ),
        PlayerBackOutcome.suppressed,
      );
      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: false,
          suppressUntil: activeSuppress,
          now: now,
        ),
        PlayerBackOutcome.suppressed,
      );

      // Without suppression: detail closes before OSD, OSD closes before confirmExit,
      // while error screen pops immediately and open exit dialog suppresses duplicate Back.
      expect(
        resolvePlayerBackOutcome(
          detailOpen: true,
          osdOpen: true,
          suppressUntil: expiredSuppress,
          now: now,
        ),
        PlayerBackOutcome.closeDetail,
      );
      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: true,
          suppressUntil: expiredSuppress,
          now: now,
        ),
        PlayerBackOutcome.closeOsd,
      );
      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: false,
          suppressUntil: expiredSuppress,
          now: now,
        ),
        PlayerBackOutcome.confirmExit,
      );
      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: false,
          errorOpen: true,
          suppressUntil: expiredSuppress,
          now: now,
        ),
        PlayerBackOutcome.popPlayer,
      );
      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: false,
          exitConfirmOpen: true,
          suppressUntil: expiredSuppress,
          now: now,
        ),
        PlayerBackOutcome.suppressed,
      );
    });

    testWidgets(
      'PlayerOsdButtonBar closes on Back key without popping ancestor PopScope',
      (tester) async {
        var osdOpen = true;
        var rootPopped = false;
        DateTime? suppressUntil;
        final scope = FocusScopeNode(debugLabel: 'testOsdBackScope');
        final firstBtn = FocusNode(debugLabel: 'osdPlay');
        addTearDown(scope.dispose);
        addTearDown(firstBtn.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                final outcome = resolvePlayerBackOutcome(
                  detailOpen: false,
                  osdOpen: osdOpen,
                  suppressUntil: suppressUntil,
                );
                if (outcome == PlayerBackOutcome.closeOsd) {
                  osdOpen = false;
                  suppressUntil = DateTime.now().add(
                    const Duration(milliseconds: 450),
                  );
                } else if (outcome == PlayerBackOutcome.confirmExit ||
                    outcome == PlayerBackOutcome.popPlayer) {
                  rootPopped = true;
                }
              },
              child: Scaffold(
                body: PlayerOsdButtonBar(
                  focusScopeNode: scope,
                  onClose: () {
                    osdOpen = false;
                    suppressUntil = DateTime.now().add(
                      const Duration(milliseconds: 450),
                    );
                  },
                  children: [
                    OutlinedButton.icon(
                      focusNode: firstBtn,
                      autofocus: true,
                      style: osdButtonStyle(),
                      onPressed: () {},
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('再生'),
                    ),
                    OutlinedButton.icon(
                      style: osdButtonStyle(),
                      onPressed: () {},
                      icon: const Icon(Icons.close),
                      label: const Text(playerOsdCloseMenuLabel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('メニューを閉じる'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(osdOpen, isFalse);
        expect(rootPopped, isFalse);

        // Simulated platform popRoute firing on the same Back press stays suppressed.
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(rootPopped, isFalse);

        // Direct platform Back (without KeyDown) closes OSD first, then pops once expired.
        osdOpen = true;
        suppressUntil = null;
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(osdOpen, isFalse);
        expect(rootPopped, isFalse);

        suppressUntil = DateTime.now().subtract(const Duration(seconds: 1));
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(rootPopped, isTrue);
      },
    );

    testWidgets(
      'segmentedButtonTheme highlights only the focused segment without outer focus border',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
            ],
            child: const TmhbApp(),
          ),
        );
        await tester.pumpAndSettle();

        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        for (final theme in [app.theme!, app.darkTheme!]) {
          final isDark = theme.brightness == Brightness.dark;
          final style = theme.segmentedButtonTheme.style!;
          expect(
            style.side?.resolve({WidgetState.focused})?.color,
            theme.colorScheme.outline,
          );
          expect(style.side?.resolve({WidgetState.focused})?.width, isNot(3.0));
          expect(
            style.backgroundColor?.resolve({WidgetState.focused}),
            isDark ? Colors.amberAccent : Colors.amber,
          );
          expect(
            style.foregroundColor?.resolve({WidgetState.focused}),
            Colors.black,
          );
          expect(
            style.iconColor?.resolve({WidgetState.focused}),
            Colors.black,
          );
        }
      },
    );

    testWidgets(
      'EpgScreen puts band selector inline in AppBar on wide screen and jumps from grid via Menu/Back',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:epg-topbar',
          friendlyName: 'テストnasne',
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
        final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
        final noonUtc = DateTime.utc(jstNow.year, jstNow.month, jstNow.day, 3);
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            EpgServiceGuide(
              channel: channel,
              events: [
                EpgEvent(
                  eventId: 10,
                  start: noonUtc,
                  duration: const Duration(minutes: 60),
                  title: '昼テスト番組',
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
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: EpgScreen()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Band selector lives inside AppBar on the same row as Search & Refresh.
        final appBarFinder = find.byType(AppBar);
        expect(
          find.descendant(
            of: appBarFinder,
            matching: find.byType(SegmentedButton<int>),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: appBarFinder,
            matching: find.byIcon(Icons.search),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: appBarFinder,
            matching: find.byIcon(Icons.refresh),
          ),
          findsOneWidget,
        );
        expect(find.text('戻る / メニューで上部へ'), findsOneWidget);

        // Scroll grid to noon so the tile is onstage, focus it, and press Menu.
        final tileText = find.text('昼テスト番組', skipOffstage: false);
        await tester.ensureVisible(tileText);
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.text('昼テスト番組'))).requestFocus();
        await tester.pump();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(EpgScreen)),
        );
        final backHandler = container.read(tabBackHandlersProvider)[AppTabs.epg];
        expect(backHandler, isNotNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pump();

        // Focus jumped out of the grid into the top bar ('地デジ' segment).
        final segFinder = find.byType(SegmentedButton<int>);
        final primaryContext = FocusManager.instance.primaryFocus?.context;
        expect(primaryContext, isNotNull);
        expect(
          find.ancestor(
            of: find.byWidget(primaryContext!.widget),
            matching: segFinder,
          ),
          findsOneWidget,
        );
        expect(backHandler!(), isFalse);

        // Focus tile again and invoke Back handler directly -> jumps back up.
        Focus.of(tester.element(find.text('昼テスト番組'))).requestFocus();
        await tester.pump();
        expect(backHandler(), isTrue);
        await tester.pump();
        final afterBackContext = FocusManager.instance.primaryFocus?.context;
        expect(afterBackContext, isNotNull);
        expect(
          find.ancestor(
            of: find.byWidget(afterBackContext!.widget),
            matching: segFinder,
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('Phase 15: EPG NavigationRail left escape & pre-buffer progress', () {
    test('computePreBufferSeconds tracks percentage, buffer delta, and duration', () {
      expect(
        computePreBufferSeconds(
          targetSeconds: 0,
          demuxerCacheDuration: 12,
          bufferingPercentage: 50,
          bufferDeltaSeconds: 10,
        ),
        0,
      );
      expect(
        computePreBufferSeconds(
          targetSeconds: 30,
          demuxerCacheDuration: 0,
          bufferingPercentage: 0,
          bufferDeltaSeconds: 0,
        ),
        0,
      );
      expect(
        computePreBufferSeconds(
          targetSeconds: 30,
          demuxerCacheDuration: double.nan,
          bufferingPercentage: 50,
          bufferDeltaSeconds: 0,
        ),
        15,
      );
      expect(
        computePreBufferSeconds(
          targetSeconds: 30,
          demuxerCacheDuration: 0,
          bufferingPercentage: 100,
          bufferDeltaSeconds: 0,
        ),
        30,
      );
      expect(
        computePreBufferSeconds(
          targetSeconds: 30,
          demuxerCacheDuration: 0,
          bufferingPercentage: 10,
          bufferDeltaSeconds: 22.8,
        ),
        22,
      );
      expect(
        computePreBufferSeconds(
          targetSeconds: 30,
          demuxerCacheDuration: 45,
          bufferingPercentage: 20,
          bufferDeltaSeconds: 10,
        ),
        30,
      );
    });

    testWidgets(
      'AppShell EpgScreen lets Left move from grid, day chips, and top bar back to NavigationRail',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:epg-rail-escape',
          friendlyName: 'テストnasne',
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
        final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
        final noonUtc = DateTime.utc(jstNow.year, jstNow.month, jstNow.day, 3);
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            EpgServiceGuide(
              channel: channel,
              events: [
                EpgEvent(
                  eventId: 10,
                  start: noonUtc,
                  duration: const Duration(minutes: 60),
                  title: '昼テスト番組',
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
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'テストnasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const <LiveBand>[],
              ),
              channelsProvider.overrideWith((ref, r) async => const [channel]),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        container.read(tabIndexProvider.notifier).select(AppTabs.epg);
        await tester.pumpAndSettle();

        bool primaryIsInRail() {
          final primaryContext = FocusManager.instance.primaryFocus?.context;
          if (primaryContext == null) return false;
          return find
              .ancestor(
                of: find.byWidget(primaryContext.widget),
                matching: find.byType(NavigationRail),
              )
              .evaluate()
              .isNotEmpty;
        }

        // 1) Left from leftmost EPG event tile moves to NavigationRail.
        final tileText = find.text('昼テスト番組', skipOffstage: false);
        await tester.ensureVisible(tileText);
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.text('昼テスト番組'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(primaryIsInRail(), isTrue);

        // 2) Left from first day chip moves to NavigationRail.
        final firstChip = find.byType(ChoiceChip).first;
        Focus.of(tester.element(firstChip)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(primaryIsInRail(), isTrue);

        // 3) Back/Menu jumps from grid to top bar ('地デジ'), and Left from '地デジ' reaches NavigationRail.
        Focus.of(tester.element(find.text('昼テスト番組'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pump();
        final topSegContext = FocusManager.instance.primaryFocus?.context;
        expect(topSegContext, isNotNull);
        expect(
          find.ancestor(
            of: find.byWidget(topSegContext!.widget),
            matching: find.byType(SegmentedButton<int>),
          ),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(primaryIsInRail(), isTrue);
      },
    );
  });

  group('Phase 16: Live pre-buffer fallback & initial playback latch', () {
    test('parseDemuxerCacheStateDuration parses valid cache-duration values', () {
      expect(parseDemuxerCacheStateDuration(''), isNull);
      expect(parseDemuxerCacheStateDuration('not-json'), isNull);
      expect(parseDemuxerCacheStateDuration('[]'), isNull);
      expect(parseDemuxerCacheStateDuration('{"fw-bytes":1234}'), isNull);
      expect(
        parseDemuxerCacheStateDuration('{"cache-duration":-1.5}'),
        isNull,
      );
      expect(
        parseDemuxerCacheStateDuration('{"cache-duration": 7}'),
        7.0,
      );
      expect(
        parseDemuxerCacheStateDuration('{"cache-duration": 12.34, "fw-bytes": 99}'),
        closeTo(12.34, 1e-6),
      );
      expect(
        parseDemuxerCacheStateDuration('{"cache-duration": "4.5"}'),
        closeTo(4.5, 1e-6),
      );
    });

    test('computePreBufferSeconds uses liveTransferSeconds only as zero-signal fallback', () {
      expect(
        computePreBufferSeconds(
          targetSeconds: 15,
          demuxerCacheDuration: 0,
          bufferingPercentage: 0,
          bufferDeltaSeconds: 0,
          liveTransferSeconds: 6.4,
        ),
        6,
      );
      // Real mpv signals strictly override liveTransferSeconds fallback.
      expect(
        computePreBufferSeconds(
          targetSeconds: 15,
          demuxerCacheDuration: 3.2,
          bufferingPercentage: 0,
          bufferDeltaSeconds: 0,
          liveTransferSeconds: 9.0,
        ),
        3,
      );
      expect(
        computePreBufferSeconds(
          targetSeconds: 15,
          demuxerCacheDuration: 0,
          bufferingPercentage: 0,
          bufferDeltaSeconds: 0,
          liveTransferSeconds: 22.0,
        ),
        15,
      );
    });

    test('advanceLiveTransferSeconds tracks flowing bytes and freezes during stalls', () {
      final t0 = DateTime.utc(2026, 11, 23, 6, 0, 0);
      // Before any byte is served to the player, stays at 0.
      var state = advanceLiveTransferSeconds(
        currentAccumulatedSeconds: 0.0,
        previousServedBytes: 0,
        previousTickAt: null,
        servedBytes: 0,
        firstByteServedAt: null,
        lastByteServedAt: null,
        now: t0,
      );
      expect(state.accumulatedSeconds, 0.0);
      expect(state.lastTickAt, isNull);

      // First chunk served at t0, polled 500ms later.
      final t1 = t0.add(const Duration(milliseconds: 500));
      state = advanceLiveTransferSeconds(
        currentAccumulatedSeconds: state.accumulatedSeconds,
        previousServedBytes: state.lastServedBytes,
        previousTickAt: state.lastTickAt,
        servedBytes: 65536,
        firstByteServedAt: t0,
        lastByteServedAt: t1,
        now: t1,
      );
      expect(state.accumulatedSeconds, closeTo(0.5, 1e-6));

      // Continuous flow for another 500ms -> 1.0s.
      final t2 = t1.add(const Duration(milliseconds: 500));
      state = advanceLiveTransferSeconds(
        currentAccumulatedSeconds: state.accumulatedSeconds,
        previousServedBytes: state.lastServedBytes,
        previousTickAt: state.lastTickAt,
        servedBytes: 131072,
        firstByteServedAt: t0,
        lastByteServedAt: t2,
        now: t2,
      );
      expect(state.accumulatedSeconds, closeTo(1.0, 1e-6));

      // Upstream stalls for 4 seconds with no new bytes -> stays frozen at 1.0s.
      final t3 = t2.add(const Duration(seconds: 4));
      state = advanceLiveTransferSeconds(
        currentAccumulatedSeconds: state.accumulatedSeconds,
        previousServedBytes: state.lastServedBytes,
        previousTickAt: state.lastTickAt,
        servedBytes: 131072,
        firstByteServedAt: t0,
        lastByteServedAt: t2,
        now: t3,
      );
      expect(state.accumulatedSeconds, closeTo(1.0, 1e-6));

      // Stream resumes 500ms later -> advances only by 0.5s, never across stall gap.
      final t4 = t3.add(const Duration(milliseconds: 500));
      state = advanceLiveTransferSeconds(
        currentAccumulatedSeconds: state.accumulatedSeconds,
        previousServedBytes: state.lastServedBytes,
        previousTickAt: state.lastTickAt,
        servedBytes: 196608,
        firstByteServedAt: t0,
        lastByteServedAt: t4,
        now: t4,
      );
      expect(state.accumulatedSeconds, closeTo(1.5, 1e-6));
    });

    test('shouldLatchInitialPlaybackStarted holds during pre-buffer pause even after width arrives', () {
      expect(
        shouldLatchInitialPlaybackStarted(
          hasVideoFrame: false,
          playingNow: true,
          buffering: false,
        ),
        isFalse,
      );
      // Key regression case: first video frame dimensions arrive while mpv is
      // still in cache-pause-initial (buffering=true, pos unchanged).
      expect(
        shouldLatchInitialPlaybackStarted(
          hasVideoFrame: true,
          playingNow: true,
          buffering: true,
          positionAtFirstFrame: Duration.zero,
          currentPosition: Duration.zero,
        ),
        isFalse,
      );
      // Once buffering clears while playing and video frame is ready -> true.
      expect(
        shouldLatchInitialPlaybackStarted(
          hasVideoFrame: true,
          playingNow: true,
          buffering: false,
          positionAtFirstFrame: Duration.zero,
          currentPosition: Duration.zero,
        ),
        isTrue,
      );
      // Safety net: if playback position advances >= 1s even if buffering stays sticky.
      expect(
        shouldLatchInitialPlaybackStarted(
          hasVideoFrame: true,
          playingNow: true,
          buffering: true,
          positionAtFirstFrame: const Duration(milliseconds: 200),
          currentPosition: const Duration(milliseconds: 1200),
        ),
        isTrue,
      );
    });
  });

  group('Phase 17: Right-pane Back to NavigationRail & Player Back confirmation', () {
    testWidgets(
      'Back from right pane focuses current NavigationRail destination and pops pushed routes first',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:back-to-rail',
          friendlyName: 'テストnasne',
          macAddr: '00:11:22:33:44:55',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'テストnasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const <LiveBand>[],
              ),
              channelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );

        void expectFocusedRailLabel(String label) {
          final ctx = FocusManager.instance.primaryFocus?.context;
          expect(ctx, isNotNull);
          expect(
            find.ancestor(
              of: find.byWidget(ctx!.widget),
              matching: find.byType(NavigationRail),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byWidget(ctx.widget),
              matching: find.text(label),
            ),
            findsOneWidget,
          );
        }

        // Switch to '録画済み' and focus a control in the right pane.
        container.read(tabIndexProvider.notifier).select(AppTabs.titles);
        await tester.pumpAndSettle();
        final refreshBtn = find
            .descendant(
              of: find.byType(TitlesScreen),
              matching: find.byIcon(Icons.refresh),
            )
            .first;
        Focus.of(tester.element(refreshBtn)).requestFocus();
        await tester.pump();

        // Back moves focus directly to '録画済み' in NavigationRail (no exit dialog).
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('アプリを終了しますか？'), findsNothing);
        expectFocusedRailLabel('録画済み');

        // Switch to '設定', scroll down to '見ないジャンル' tile, then test pushed route & Back.
        container.read(tabIndexProvider.notifier).select(AppTabs.settings);
        await tester.pumpAndSettle();
        final settingsScrollable = find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        );
        final hiddenGenresTile = find.text('見ないジャンル');
        await tester.scrollUntilVisible(
          hiddenGenresTile,
          300,
          scrollable: settingsScrollable,
        );
        await tester.pumpAndSettle();
        Focus.of(tester.element(hiddenGenresTile)).requestFocus();
        await tester.pump();

        // Push deep screen ('見ないジャンル'), then Back pops ONLY that deep screen.
        await tester.tap(hiddenGenresTile);
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('アプリを終了しますか？'), findsNothing);
        expect(find.byType(BackButton), findsNothing);
        expect(find.text('見ないジャンル'), findsOneWidget);

        // Back from right pane on SettingsScreen focuses '設定' in NavigationRail.
        Focus.of(tester.element(find.text('見ないジャンル'))).requestFocus();
        await tester.pump();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('アプリを終了しますか？'), findsNothing);
        expectFocusedRailLabel('設定');
      },
    );

    testWidgets(
      'AppShell EpgScreen uses 2-step Back: grid -> top bar -> NavigationRail -> exit dialog',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:epg-two-step-back',
          friendlyName: 'テストnasne',
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
        final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
        final noonUtc = DateTime.utc(jstNow.year, jstNow.month, jstNow.day, 3);
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            EpgServiceGuide(
              channel: channel,
              events: [
                EpgEvent(
                  eventId: 10,
                  start: noonUtc,
                  duration: const Duration(minutes: 60),
                  title: '昼テスト番組',
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
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'テストnasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const <LiveBand>[],
              ),
              channelsProvider.overrideWith((ref, r) async => const [channel]),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        container.read(tabIndexProvider.notifier).select(AppTabs.epg);
        await tester.pumpAndSettle();

        // Start focused inside EPG grid.
        final tileText = find.text('昼テスト番組', skipOffstage: false);
        await tester.ensureVisible(tileText);
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.text('昼テスト番組'))).requestFocus();
        await tester.pump();

        // 1st Back from grid jumps to EPG top bar (SegmentedButton).
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('アプリを終了しますか？'), findsNothing);
        final topCtx = FocusManager.instance.primaryFocus?.context;
        expect(topCtx, isNotNull);
        expect(
          find.ancestor(
            of: find.byWidget(topCtx!.widget),
            matching: find.byType(SegmentedButton<int>),
          ),
          findsOneWidget,
        );

        // 2nd Back from EPG top bar focuses '番組表' in NavigationRail.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('アプリを終了しますか？'), findsNothing);
        final railCtx = FocusManager.instance.primaryFocus?.context;
        expect(railCtx, isNotNull);
        expect(
          find.ancestor(
            of: find.byWidget(railCtx!.widget),
            matching: find.byType(NavigationRail),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byWidget(railCtx.widget),
            matching: find.text('番組表'),
          ),
          findsOneWidget,
        );

        // 3rd Back while on NavigationRail opens exit confirmation dialog.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('アプリを終了しますか？'), findsOneWidget);
      },
    );

    testWidgets(
      'showPlayerExitConfirmDialog defaults focus to continue and confirms only on finish',
      (tester) async {
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showPlayerExitConfirmDialog(context);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

        // Dismiss via Back -> returns false.
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('再生を終了しますか？'), findsOneWidget);
        final continueBtn = tester.widget<TextButton>(
          find.ancestor(
            of: find.text('再生を続ける'),
            matching: find.byType(TextButton),
          ),
        );
        expect(continueBtn.autofocus, isTrue);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(result, isFalse);

        // Tap '再生を続ける' -> returns false.
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('再生を続ける'));
        await tester.pumpAndSettle();
        expect(result, isFalse);

        // Tap '終了する' -> returns true.
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('終了する'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
      },
    );
  });

  group('Phase 19: EPG integer-column fitting & right-edge snap', () {
    test('resolveEpgChannelWidth fits integer columns cleanly without overflow', () {
      final fireTvWidth = resolveEpgChannelWidth(838.0);
      expect(fireTvWidth, closeTo(167.6, 0.01));
      expect(fireTvWidth * 5, lessThanOrEqualTo(838.0));

      final largeWidth = resolveEpgChannelWidth(1158.0);
      expect(largeWidth * 7, lessThanOrEqualTo(1158.0));
      expect(largeWidth, inInclusiveRange(156.0, 210.0));

      // Narrow or invalid viewports fall back to default 172dp.
      expect(resolveEpgChannelWidth(279.0), 172.0);
      expect(resolveEpgChannelWidth(0), 172.0);
      expect(resolveEpgChannelWidth(-50), 172.0);
      expect(resolveEpgChannelWidth(double.nan), 172.0);
      expect(resolveEpgChannelWidth(double.infinity), 172.0);
    });

    test('resolveEpgSnapTarget stops at maxScrollExtent instead of bouncing left', () {
      // Previously 22dp overshoot with 172dp column width snapped back to 0.
      expect(
        resolveEpgSnapTarget(
          pixels: 22.0,
          channelWidth: 172.0,
          minScrollExtent: 0.0,
          maxScrollExtent: 22.0,
        ),
        22.0,
      );
      // Multi-column remainder near right end snaps to maxScrollExtent.
      expect(
        resolveEpgSnapTarget(
          pixels: 1735.0,
          channelWidth: 167.6,
          minScrollExtent: 0.0,
          maxScrollExtent: 1742.0,
        ),
        1742.0,
      );
      // Interior offset snaps normally to nearest column boundary.
      expect(
        resolveEpgSnapTarget(
          pixels: 160.0,
          channelWidth: 167.6,
          minScrollExtent: 0.0,
          maxScrollExtent: 1742.0,
        ),
        closeTo(167.6, 1e-6),
      );
    });

    testWidgets(
      '5 terrestrial channels on 960dp Fire TV fit without clipping or horizontal bounce',
      (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:epg-5ch-fit',
          friendlyName: 'テストnasne',
          macAddr: '00:11:22:33:44:55',
        );
        Channel makeCh(int idx, String name) => Channel(
          broadcastingType: 2,
          networkId: 0x1111,
          transportStreamId: 0x2220 + idx,
          serviceId: 0x3330 + idx,
          serviceType: 1,
          channelNumber: idx + 1,
          serviceName: name,
        );
        final channels = [
          makeCh(0, 'NHK総合1・秋田'),
          makeCh(1, 'NHKEテレ1秋田'),
          makeCh(2, 'ABS秋田放送1'),
          makeCh(3, 'AKT秋田テレビ1'),
          makeCh(4, '秋田朝日放送'),
        ];

        final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
        final dayStart = DateTime.utc(
          jstNow.year,
          jstNow.month,
          jstNow.day + 1,
        ).subtract(const Duration(hours: 9));
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            for (var i = 0; i < channels.length; i++)
              EpgServiceGuide(
                channel: channels[i],
                events: i < 4
                    ? [
                        EpgEvent(
                          eventId: 100 + i,
                          start: dayStart.add(const Duration(minutes: 30)),
                          duration: const Duration(minutes: 60),
                          title: '局$i番組',
                          genreLevel1: 3,
                        ),
                      ]
                    : [
                        EpgEvent(
                          eventId: 501,
                          start: dayStart.add(const Duration(minutes: 30)),
                          duration: const Duration(minutes: 60),
                          title: '５局目番組Ａ',
                          genreLevel1: 3,
                        ),
                        EpgEvent(
                          eventId: 502,
                          start: dayStart.add(const Duration(minutes: 90)),
                          duration: const Duration(minutes: 60),
                          title: '５局目番組Ｂ',
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
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'テストnasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const <LiveBand>[],
              ),
              channelsProvider.overrideWith((ref, r) async => channels),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        container.read(tabIndexProvider.notifier).select(AppTabs.epg);
        await tester.pumpAndSettle();

        final horizontalScrollable = tester
            .stateList<ScrollableState>(
              find.descendant(
                of: find.byType(EpgScreen),
                matching: find.byType(Scrollable),
              ),
            )
            .firstWhere((s) => s.widget.axisDirection == AxisDirection.right);
        expect(horizontalScrollable.position.maxScrollExtent, 0.0);

        final tileAFinder = find
            .ancestor(
              of: find.text('５局目番組Ａ'),
              matching: find.byType(InkWell),
            )
            .first;
        final rectA = tester.getRect(tileAFinder);
        expect(rectA.right, lessThanOrEqualTo(960.0 + 0.5));

        Focus.of(tester.element(find.text('５局目番組Ａ'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();

        expect(horizontalScrollable.position.pixels, 0.0);
        final tileBFinder = find
            .ancestor(
              of: find.text('５局目番組Ｂ'),
              matching: find.byType(InkWell),
            )
            .first;
        final rectB = tester.getRect(tileBFinder);
        expect(rectB.right, lessThanOrEqualTo(960.0 + 0.5));
        final focusedCtx = FocusManager.instance.primaryFocus?.context;
        expect(focusedCtx, isNotNull);
        expect(
          find.descendant(
            of: find.byWidget(focusedCtx!.widget),
            matching: find.text('５局目番組Ｂ'),
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('Phase 20: Title unification, EPG reserved settings & ruler bars', () {
    testWidgets(
      'SettingsScreen displays torne HB FireTV footer and persists EPG reserved style',
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

        await tester.scrollUntilVisible(
          find.text('録画予約済みの表示'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        final segFinder = find.byType(SegmentedButton<EpgReservedStyle>);
        expect(segFinder, findsOneWidget);
        expect(
          tester.widget<SegmentedButton<EpgReservedStyle>>(segFinder).selected,
          {EpgReservedStyle.fill},
        );

        await tester.tap(find.text('赤枠'));
        await tester.pumpAndSettle();
        expect(await kv.read('firetv_epg_reserved_style'), 'border');

        await tester.tap(find.text('赤塗りつぶし'));
        await tester.pumpAndSettle();
        expect(await kv.read('firetv_epg_reserved_style'), 'fill');

        await tester.scrollUntilVisible(
          find.textContaining('torne HB FireTV'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining('torne HB FireTV'), findsOneWidget);
      },
    );

    test(
      'buildEpgRulerReservedSpans clips cross-midnight ranges and merges all bands + recording titles',
      () {
        final dayStart = DateTime.utc(2026, 11, 22, 15, 0); // JST 2026-11-23 00:00
        final dayEnd = dayStart.add(const Duration(days: 1));
        RecordSchedule mkSched({
          required String id,
          required int band,
          required DateTime start,
          required int durationSec,
        }) => RecordSchedule(
          id: id,
          start: start,
          durationSeconds: durationSec,
          conditionId: '1',
          channel: ScheduleChannel(
            broadcastingType: band,
            channelType: band,
            serviceId: 100,
          ),
          desiredQualityMode: 100,
          desiredMatchingId: ',,0x0001,0x0001',
          reservationCreatorId: '2000',
          priorityFlag: 0,
          recordDestinationId: 'HDD',
        );

        final spans = buildEpgRulerReservedSpans(
          dayStart: dayStart,
          dayEnd: dayEnd,
          schedules: [
            // Cross-midnight from previous day: 23:30..00:30 JST -> 0..30 min
            mkSched(
              id: 'prev',
              band: 2,
              start: dayStart.subtract(const Duration(minutes: 30)),
              durationSec: 3600,
            ),
            // Terrestrial 02:00..03:00 (120..180)
            mkSched(
              id: 'dttb',
              band: 2,
              start: dayStart.add(const Duration(hours: 2)),
              durationSec: 3600,
            ),
            // Overlapping BS 02:30..03:30 (150..210) -> merges to 120..210
            mkSched(
              id: 'bs',
              band: 3,
              start: dayStart.add(const Duration(minutes: 150)),
              durationSec: 3600,
            ),
          ],
          recordingTitles: [
            RecordedTitle(
              id: 'rec-live',
              title: '録画中テスト',
              scheduledStart: dayStart.add(const Duration(hours: 6)),
              scheduledDurationSeconds: 1800,
              recordingFlag: true,
            ),
            RecordedTitle(
              id: 'rec-done',
              title: '録画完了テスト',
              scheduledStart: dayStart.add(const Duration(hours: 8)),
              scheduledDurationSeconds: 1800,
              recordingFlag: false,
            ),
          ],
        );

        expect(spans, hasLength(3));
        expect(spans[0].startMin, 0.0);
        expect(spans[0].endMin, 30.0);
        expect(spans[1].startMin, 120.0);
        expect(spans[1].endMin, 210.0);
        expect(spans[2].startMin, 360.0);
        expect(spans[2].endMin, 390.0);
      },
    );

    testWidgets(
      'EpgScreen time ruler draws red bars for cross-band reservations',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.1',
          udn: 'uuid:epg-ruler-test',
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
          serviceName: 'テスト局',
        );
        final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
        final dayStartUtc = DateTime.utc(jstNow.year, jstNow.month, jstNow.day)
            .subtract(const Duration(hours: 9));
        final schedStart = dayStartUtc.add(const Duration(hours: 1));
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            EpgServiceGuide(
              channel: channel,
              events: [
                EpgEvent(
                  eventId: 10,
                  start: schedStart,
                  duration: const Duration(minutes: 60),
                  title: '昼前テスト',
                ),
              ],
            ),
          ],
        );
        final bsSchedule = RecordSchedule(
          id: 'bs-1',
          start: schedStart,
          durationSeconds: 3600,
          conditionId: '1',
          channel: const ScheduleChannel(
            broadcastingType: 3,
            channelType: 3,
            serviceId: 101,
          ),
          desiredQualityMode: 100,
          desiredMatchingId: ',,0x0004,0x0010',
          reservationCreatorId: '2000',
          priorityFlag: 0,
          recordDestinationId: 'HDD',
          title: 'BS 録画予約',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              schedulesProvider.overrideWith((ref, r) async => [bsSchedule]),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: EpgScreen()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final rulerBars = find.byWidgetPredicate((w) {
          if (w is! DecoratedBox) return false;
          final d = w.decoration;
          if (d is! BoxDecoration) return false;
          return d.color == const Color(0xFFD32F2F);
        });
        expect(rulerBars, findsOneWidget);
        expect(tester.getSize(rulerBars).width, 4);
      },
    );
  });

  group('Phase 20: AppShell home initial focus stays on NavigationRail', () {
    testWidgets(
      'Home initial startup & async registration completion keep focus in NavigationRail until ArrowRight',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:home-focus-lock',
          friendlyName: 'テストnasne',
          macAddr: '00:11:22:33:44:55',
        );
        final storeCompleter = Completer<List<RegisteredNasne>>();
        final regStore = _DeferredRegistrationStore(storeCompleter);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(regStore),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'テストnasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const <LiveBand>[],
              ),
              channelsProvider.overrideWith((ref, r) async => const <Channel>[]),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        bool primaryIsInRail() {
          final primaryCtx = FocusManager.instance.primaryFocus?.context;
          if (primaryCtx == null) return false;
          return find
              .ancestor(
                of: find.byWidget(primaryCtx.widget),
                matching: find.byType(NavigationRail),
              )
              .evaluate()
              .isNotEmpty;
        }

        expect(primaryIsInRail(), isTrue);

        // Complete registrations load so HomeScreen builds its refresh button & cards.
        storeCompleter.complete(const [reg]);
        await tester.pumpAndSettle();
        expect(find.text('torne HB FireTV'), findsOneWidget);
        expect(find.text('本体情報'), findsOneWidget);
        expect(primaryIsInRail(), isTrue);

        // Pressing ArrowDown moves within NavigationRail, NOT into Home pane.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(primaryIsInRail(), isTrue);

        // Return to ホーム, then press ArrowRight to enter Home pane explicitly.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(primaryIsInRail(), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(primaryIsInRail(), isFalse);
      },
    );
  });

  group('Phase 20: Live recording conflict, badges & corner notices', () {
    const ch1 = LiveChannel(
      id: '0/video/LiveTuner/DTTB/ch1',
      bandId: '0/video/LiveTuner/DTTB',
      networkId: 0x7880,
      transportStreamId: 0x7880,
      serviceId: 0x0400,
      channelName: 'NHK総合1',
      programTitle: 'テスト番組1',
      res: [
        TitleRes(
          url: 'http://192.0.2.1/ch1_dr',
          protocolInfo: 'http-get:*:application/x-dtcp1:*',
          quality: 'dr',
        ),
      ],
    );
    const ch2 = LiveChannel(
      id: '0/video/LiveTuner/DTTB/ch2',
      bandId: '0/video/LiveTuner/DTTB',
      networkId: 0x7881,
      transportStreamId: 0x7881,
      serviceId: 0x0408,
      channelName: 'Eテレ1',
      programTitle: 'テスト番組2',
      res: [
        TitleRes(
          url: 'http://192.0.2.1/ch2_dr',
          protocolInfo: 'http-get:*:application/x-dtcp1:*',
          quality: 'dr',
        ),
        TitleRes(
          url: 'http://192.0.2.1/ch2_mob',
          protocolInfo: 'http-get:*:application/x-dtcp1:*',
          quality: 'mobile',
        ),
      ],
    );

    test('policy helpers detect other-channel conflict, lead margin, and corner transitions', () {
      final now = DateTime.utc(2026, 11, 23, 9, 0, 0);
      final recCh2 = RecordSchedule(
        id: 's-ch2',
        start: now.subtract(const Duration(minutes: 5)),
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 0x0408,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: ',,0x7881,0x0010',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
        title: 'Eテレ録画番組',
      );
      final leadCh2 = RecordSchedule(
        id: 's-ch2-lead',
        start: now.add(const Duration(seconds: 60)),
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 0x0408,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: ',,0x7881,0x0011',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
        title: '開始直前番組',
      );

      expect(broadcastingTypeForLiveBandId('0/video/LiveTuner/DTTB'), 2);
      expect(broadcastingTypeForLiveBandId('0/video/LiveTuner/BS'), 3);
      expect(broadcastingTypeForLiveBandId('0/video/LiveTuner/CS'), 4);

      // Watching ch1 while ch2 is recording -> conflict!
      expect(
        findActiveOtherChannelRecording([recCh2], currentChannel: ch1, now: now),
        recCh2,
      );
      // Watching ch2 while ch2 is recording -> same channel, NO conflict.
      expect(
        findActiveOtherChannelRecording([recCh2], currentChannel: ch2, now: now),
        isNull,
      );
      expect(
        findActiveSameChannelRecording([recCh2], currentChannel: ch2, now: now),
        recCh2,
      );
      // Within 90s lead margin before start -> conflict detected.
      expect(
        findActiveOtherChannelRecording([leadCh2], currentChannel: ch1, now: now),
        leadCh2,
      );
      // LiveChannel lookup across bands.
      final found = findLiveChannelForSchedule(
        [
          const LiveBand(
            containerId: '0/video/LiveTuner/DTTB',
            title: '地上デジタル',
            channels: [ch1, ch2],
          ),
        ],
        recCh2,
      );
      expect(found, ch2);

      // Corner notice transitions.
      expect(
        resolveLiveRecordingCornerNotice(
          previousRecording: null,
          currentRecording: false,
        ),
        isNull,
      );
      expect(
        resolveLiveRecordingCornerNotice(
          previousRecording: null,
          currentRecording: true,
        ),
        LiveRecordingCornerNotice.recording,
      );
      expect(
        resolveLiveRecordingCornerNotice(
          previousRecording: false,
          currentRecording: true,
        ),
        LiveRecordingCornerNotice.recording,
      );
      expect(
        resolveLiveRecordingCornerNotice(
          previousRecording: true,
          currentRecording: false,
        ),
        LiveRecordingCornerNotice.ended,
      );
      expect(
        resolveLiveRecordingCornerNotice(
          previousRecording: true,
          currentRecording: true,
        ),
        isNull,
      );
    });

    testWidgets(
      'showLiveRecordingConflictDialog highlights switch action and returns choice',
      (tester) async {
        bool? dialogResult;
        final conflict = LiveRecordingConflict(
          schedule: RecordSchedule(
            id: 's-ch2',
            start: DateTime.now().toUtc(),
            durationSeconds: 1800,
            conditionId: '1',
            channel: const ScheduleChannel(
              broadcastingType: 2,
              channelType: 2,
              serviceId: 0x0408,
            ),
            desiredQualityMode: 100,
            desiredMatchingId: ',,0x7881,0x0010',
            reservationCreatorId: '2000',
            priorityFlag: 0,
            recordDestinationId: 'HDD',
            title: '録画対象番組',
          ),
          displayTitle: '録画対象番組',
          channelName: 'Eテレ1',
          liveChannel: ch2,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    dialogResult = await showLiveRecordingConflictDialog(
                      context,
                      conflict: conflict,
                      midStream: true,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('他チャンネルの録画が開始されました'), findsOneWidget);
        expect(find.textContaining('Eテレ1「録画対象番組」'), findsOneWidget);
        expect(find.text('録画中のチャンネルに切り替える'), findsOneWidget);

        await tester.tap(find.text('録画中のチャンネルに切り替える'));
        await tester.pumpAndSettle();
        expect(dialogResult, isTrue);
      },
    );

    testWidgets(
      'LiveScreen shows recording badge, warns on conflicting channel start, and switches with quality fallback',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.20',
          udn: 'uuid:live-rec-test',
          friendlyName: 'nasne',
          macAddr: '00:11:22:33:44:55',
        );
        final activeRec = RecordSchedule(
          id: 's-rec-ch2',
          start: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
          durationSeconds: 3600,
          conditionId: '1',
          channel: const ScheduleChannel(
            broadcastingType: 2,
            channelType: 2,
            serviceId: 0x0408,
          ),
          desiredQualityMode: 100,
          desiredMatchingId: ',,0x7881,0x0010',
          reservationCreatorId: '2000',
          priorityFlag: 0,
          recordDestinationId: 'HDD',
          title: '録画中ドラマ',
        );
        final fakeEngine = _RecordingFallbackLiveEngine();
        final kv = InMemoryKeyValueStore();
        await kv.write('firetv_default_use_mobile', 'true');

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              keyValueStoreProvider.overrideWithValue(kv),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const [
                  LiveBand(
                    containerId: '0/video/LiveTuner/DTTB',
                    title: '地上デジタル',
                    channels: [ch1, ch2],
                  ),
                ],
              ),
              schedulesProvider.overrideWith((ref, r) async => [activeRec]),
              deviceServicesProvider(reg).overrideWithValue(
                DeviceServices(
                  deviceInfo: _StubDeviceInfo(),
                  settings: _StubSettings(),
                  schedules: _FixedScheduleService([activeRec]),
                  titles: _StubTitleCatalog(),
                  metadata: _StubMetadata(),
                  live: _StubLiveCatalog(),
                  playback: fakeEngine,
                ),
              ),
            ],
            child: const MaterialApp(home: LiveScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // List row for ch2 renders '録画中' badge.
        expect(find.text('録画中'), findsOneWidget);

        // Select ch1 (not recording) and press Watch -> pre-start conflict dialog opens.
        await tester.tap(find.text('NHK総合1'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('視聴'));
        await tester.pumpAndSettle();

        expect(find.text('他チャンネルで録画中です'), findsOneWidget);
        expect(find.textContaining('Eテレ1「録画中ドラマ」'), findsOneWidget);

        // Choose '録画中のチャンネルを視聴' -> tries mobile (503 fails) then falls back to dr.
        await tester.tap(find.text('録画中のチャンネルを視聴'));
        await tester.pumpAndSettle();
        expect(fakeEngine.attempts, ['ch2:mobile', 'ch2:dr']);
      },
    );

    test(
      'shouldSuppressPlayerInterruption suppresses background banners after recording conflict',
      () {
        expect(
          shouldSuppressPlayerInterruption(
            completed: false,
            conflictHandled: false,
            switchingChannel: false,
          ),
          isFalse,
        );
        expect(
          shouldSuppressPlayerInterruption(
            completed: false,
            conflictHandled: true,
            switchingChannel: false,
          ),
          isTrue,
        );
        expect(
          shouldSuppressPlayerInterruption(
            completed: false,
            conflictHandled: false,
            switchingChannel: true,
          ),
          isTrue,
        );
        expect(
          shouldSuppressPlayerInterruption(
            completed: true,
            conflictHandled: false,
            switchingChannel: false,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'showLiveRecordingConflictDialog holds D-pad focus and responds to ArrowLeft + Select over background buttons',
      (tester) async {
        bool? dialogResult;
        final conflict = LiveRecordingConflict(
          schedule: RecordSchedule(
            id: 's-ch2-focus',
            start: DateTime.now().toUtc(),
            durationSeconds: 1800,
            conditionId: '1',
            channel: const ScheduleChannel(
              broadcastingType: 2,
              channelType: 2,
              serviceId: 0x0408,
            ),
            desiredQualityMode: 100,
            desiredMatchingId: ',,0x7881,0x0010',
            reservationCreatorId: '2000',
            priorityFlag: 0,
            recordDestinationId: 'HDD',
            title: '番組テスト',
          ),
          displayTitle: '番組テスト',
          channelName: 'Eテレ1',
          liveChannel: ch2,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Row(
                  children: [
                    ElevatedButton(
                      autofocus: true,
                      onPressed: () async {
                        dialogResult = await showLiveRecordingConflictDialog(
                          context,
                          conflict: conflict,
                          midStream: true,
                        );
                      },
                      child: const Text('今すぐ再開'),
                    ),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('閉じる'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('今すぐ再開'));
        await tester.pumpAndSettle();

        // Focus must stay inside the dialog on '録画中のチャンネルに切り替える', never behind it.
        final primaryCtx = FocusManager.instance.primaryFocus?.context;
        expect(primaryCtx, isNotNull);
        expect(
          find.ancestor(
            of: find.byWidget(primaryCtx!.widget),
            matching: find.byType(AlertDialog),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byWidget(primaryCtx.widget),
            matching: find.text('録画中のチャンネルに切り替える'),
          ),
          findsOneWidget,
        );

        // ArrowLeft + Select chooses '視聴を終了する' (false) cleanly via keyboard.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        final exitCtx = FocusManager.instance.primaryFocus?.context;
        expect(
          find.descendant(
            of: find.byWidget(exitCtx!.widget),
            matching: find.text('視聴を終了する'),
          ),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(dialogResult, isFalse);
      },
    );

    test(
      'computeEpgNowOffset calculates fractional minutes and clips outside [dayStart, dayEnd)',
      () {
        final dayStart = DateTime.utc(2026, 11, 22, 15, 0);
        final dayEnd = dayStart.add(const Duration(days: 1));
        expect(
          computeEpgNowOffset(
            now: dayStart.subtract(const Duration(seconds: 1)),
            dayStart: dayStart,
            dayEnd: dayEnd,
          ),
          isNull,
        );
        expect(
          computeEpgNowOffset(
            now: dayStart,
            dayStart: dayStart,
            dayEnd: dayEnd,
          ),
          0.0,
        );
        expect(
          computeEpgNowOffset(
            now: dayStart.add(const Duration(minutes: 10, seconds: 30)),
            dayStart: dayStart,
            dayEnd: dayEnd,
          ),
          closeTo(10.5 * 2.4, 1e-6),
        );
        expect(
          computeEpgNowOffset(
            now: dayEnd,
            dayStart: dayStart,
            dayEnd: dayEnd,
          ),
          isNull,
        );
      },
    );

    testWidgets(
      'EpgNowIndicatorLine updates position periodically and hides after dayEnd',
      (tester) async {
        final dayStart = DateTime.utc(2026, 11, 22, 15, 0);
        final dayEnd = dayStart.add(const Duration(days: 1));
        var current = dayStart.add(const Duration(minutes: 20));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 200,
                height: 24 * 60 * 2.4,
                child: EpgNowIndicatorLine(
                  dayStart: dayStart,
                  dayEnd: dayEnd,
                  dayHeight: 24 * 60 * 2.4,
                  tickInterval: const Duration(seconds: 15),
                  nowProvider: () => current,
                ),
              ),
            ),
          ),
        );

        Positioned positionedLine() =>
            tester.widget<Positioned>(find.byType(Positioned));

        expect(positionedLine().top, closeTo(20 * 2.4, 1e-6));

        // Advance clock by 10 minutes and trigger periodic tick.
        current = current.add(const Duration(minutes: 10));
        await tester.pump(const Duration(seconds: 15));
        expect(positionedLine().top, closeTo(30 * 2.4, 1e-6));

        // Advance past dayEnd and confirm the red line disappears.
        current = dayEnd.add(const Duration(minutes: 1));
        await tester.pump(const Duration(seconds: 15));
        expect(find.byType(Positioned), findsNothing);
      },
    );
  });

  group('Phase 21: Remote focus audit, Live/EPG auto-refresh & multi-nasne', () {
    test('multi-nasne policies select free tuner, failover, and largest-free-space auto schedule', () {
      const regA = RegisteredNasne(
        host: '192.0.2.10',
        udn: 'uuid:a',
        friendlyName: 'リビングnasne',
        macAddr: '00:11:22:33:44:55',
      );
      const regB = RegisteredNasne(
        host: '192.0.2.11',
        udn: 'uuid:b',
        friendlyName: '書斎nasne',
        macAddr: '00:11:22:33:44:66',
      );
      const chNhkA = LiveChannel(
        id: '0/video/LiveTuner/DTTB/a1',
        bandId: '0/video/LiveTuner/DTTB',
        networkId: 100,
        transportStreamId: 200,
        serviceId: 1024,
        channelName: 'NHK総合',
        programTitle: '番組A',
      );
      const chNhkB = LiveChannel(
        id: '0/video/LiveTuner/DTTB/b1',
        bandId: '0/video/LiveTuner/DTTB',
        networkId: 100,
        transportStreamId: 200,
        serviceId: 1024,
        channelName: 'NHK総合',
        programTitle: '番組B',
      );
      const bandA = [
        LiveBand(
          containerId: '0/video/LiveTuner/DTTB',
          title: '地上デジタル',
          channels: [chNhkA],
        ),
      ];
      const bandB = [
        LiveBand(
          containerId: '0/video/LiveTuner/DTTB',
          title: '地上デジタル',
          channels: [chNhkB],
        ),
      ];

      final mergedBands = mergeLiveBands(
        [(reg: regA, bands: bandA), (reg: regB, bands: bandB)],
        preferredReg: regA,
      );
      expect(mergedBands, hasLength(1));
      expect(mergedBands.first.channels, hasLength(1));
      expect(mergedBands.first.channels.first.candidates, hasLength(2));

      final now = DateTime.utc(2026, 11, 23, 10, 0);
      final busyOther = RecordSchedule(
        id: 's1',
        start: now.subtract(const Duration(minutes: 10)),
        durationSeconds: 3600,
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 9999,
        ),
        desiredQualityMode: 100,
        priorityFlag: 0,
        conditionId: '',
        desiredMatchingId: '',
        reservationCreatorId: '',
        recordDestinationId: 'HDD',
      );
      final busySame = RecordSchedule(
        id: 's2',
        start: now.subtract(const Duration(minutes: 10)),
        durationSeconds: 3600,
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 1024,
        ),
        desiredQualityMode: 100,
        priorityFlag: 0,
        conditionId: '',
        desiredMatchingId: '',
        reservationCreatorId: '',
        recordDestinationId: 'HDD',
      );

      // regA busy with another channel, regB idle -> selects regB.
      final pickIdle = selectLiveTunerCandidate(
        candidates: mergedBands.first.channels.first.candidates,
        schedulesByHost: {
          regA.host: [busyOther],
          regB.host: const [],
        },
        now: now,
        preferredReg: regA,
      );
      expect(pickIdle?.target.reg.host, regB.host);
      expect(pickIdle?.sameChannelRecording, isFalse);

      // regA busy other, regB recording same channel -> selects regB with sameChannelRecording=true.
      final pickSame = selectLiveTunerCandidate(
        candidates: mergedBands.first.channels.first.candidates,
        schedulesByHost: {
          regA.host: [busyOther],
          regB.host: [busySame],
        },
        now: now,
        preferredReg: regA,
      );
      expect(pickSame?.target.reg.host, regB.host);
      expect(pickSame?.sameChannelRecording, isTrue);

      // Both busy with other channels -> null.
      final pickNone = selectLiveTunerCandidate(
        candidates: mergedBands.first.channels.first.candidates,
        schedulesByHost: {
          regA.host: [busyOther],
          regB.host: [busyOther],
        },
        now: now,
      );
      expect(pickNone, isNull);

      // Auto schedule picks conflict-free unit with largest free HDD space.
      final autoPicked = selectAutoScheduleNasne(
        candidates: const [regA, regB],
        hasConflictByHost: {regA.host: false, regB.host: false},
        freeBytesByHost: {
          regA.host: 100 * 1024 * 1024,
          regB.host: 500 * 1024 * 1024,
        },
        preferredReg: regA,
      );
      expect(autoPicked?.host, regB.host);

      final autoAvoidConflict = selectAutoScheduleNasne(
        candidates: const [regA, regB],
        hasConflictByHost: {regA.host: true, regB.host: false},
        freeBytesByHost: {
          regA.host: 900 * 1024 * 1024,
          regB.host: 100 * 1024 * 1024,
        },
      );
      expect(autoAvoidConflict?.host, regB.host);
    });

    testWidgets(
      'EpgScreen 960x540 AppBar Search & Refresh are reachable via D-pad despite scrolled tiles',
      (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:epg-960',
          friendlyName: 'メインnasne',
          macAddr: '00:11:22:33:44:55',
        );
        final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
        final dayStartUtc = DateTime.utc(
          jstNow.year,
          jstNow.month,
          jstNow.day,
        ).subtract(const Duration(hours: 9));
        final guide = EpgGuide(
          broadcastingType: 2,
          services: [
            for (var c = 1; c <= 6; c++)
              EpgServiceGuide(
                channel: Channel(
                  broadcastingType: 2,
                  networkId: 0x1000 + c,
                  transportStreamId: 0x2000 + c,
                  serviceId: 0x3000 + c,
                  serviceType: 1,
                  channelNumber: c,
                  serviceName: 'テスト局$c',
                ),
                events: [
                  for (var h = 0; h < 24; h++)
                    EpgEvent(
                      eventId: c * 100 + h,
                      start: dayStartUtc.add(Duration(hours: h)),
                      duration: const Duration(hours: 1),
                      title: '番組$c-$h',
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
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'メインnasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const <LiveBand>[],
              ),
              channelsProvider.overrideWith(
                (ref, r) async => [for (final s in guide.services) s.channel],
              ),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
              epgGuideProvider.overrideWith((ref, r) async => guide),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        container.read(tabIndexProvider.notifier).select(AppTabs.epg);
        await tester.pumpAndSettle();

        // Scroll grid far down so upper events overlap AppBar vertically.
        final lateTile = find.text('番組5-20', skipOffstage: false);
        await tester.ensureVisible(lateTile);
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.text('番組5-20'))).requestFocus();
        await tester.pump();

        // Jump to top bar -> starts at '地デジ' in SegmentedButton.
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pump();
        expect(
          find.ancestor(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byType(SegmentedButton<int>),
          ),
          findsOneWidget,
        );

        // ArrowRight steps: '地デジ' -> 'BS' -> Search -> Refresh.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
          find.ancestor(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byType(SegmentedButton<int>),
          ),
          findsOneWidget,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
          find.descendant(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byIcon(Icons.search),
          ),
          findsOneWidget,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
          find.descendant(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byIcon(Icons.refresh),
          ),
          findsOneWidget,
        );

        // ArrowDown from top bar goes to ChoiceChip, ArrowUp returns to AppBar,
        // and ArrowDown from ChoiceChip enters a visible grid tile.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
          find.ancestor(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byType(ChoiceChip),
          ),
          findsOneWidget,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        final gridFocusCtx = FocusManager.instance.primaryFocus?.context;
        expect(gridFocusCtx, isNotNull);
        expect(
          find.ancestor(
            of: find.byWidget(gridFocusCtx!.widget),
            matching: find.byType(ChoiceChip),
          ),
          findsNothing,
        );

        // Jump back to top bar, ArrowLeft from '地デジ' returns to NavigationRail.
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(
          find.ancestor(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byType(NavigationRail),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'AppShell right-pane ArrowUp reaches AppBar refresh from Home and Live',
      (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:right-up',
          friendlyName: 'テストnasne',
          macAddr: '00:11:22:33:44:55',
        );
        const liveBands = [
          LiveBand(
            containerId: '0/video/LiveTuner/DTTB',
            title: '地上デジタル',
            channels: [
              LiveChannel(
                id: 'ch1',
                bandId: '0/video/LiveTuner/DTTB',
                channelName: '総合テレビ',
                programTitle: 'テスト放送',
              ),
            ],
          ),
          LiveBand(
            containerId: '0/video/LiveTuner/BS',
            title: 'BS',
            channels: [
              LiveChannel(
                id: 'ch2',
                bandId: '0/video/LiveTuner/BS',
                channelName: 'BS1',
                programTitle: 'BS放送',
              ),
            ],
          ),
        ];

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'テストnasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith((ref, r) async => liveBands),
              channelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
              epgGuideProvider.overrideWith(
                (ref, r) async => const EpgGuide(broadcastingType: 2, services: []),
              ),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();

        // Home: move into right pane ('本体情報'), press ArrowUp -> reaches Refresh IconButton.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(
          find.ancestor(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byType(AppBar),
          ),
          findsOneWidget,
        );

        // Live: switch tab, focus '地デジ', press ArrowUp -> reaches Refresh IconButton.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        container.read(tabIndexProvider.notifier).select(AppTabs.live);
        await tester.pumpAndSettle();

        final bsSeg = find.text('地デジ');
        Focus.of(tester.element(bsSeg)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(
          find.descendant(
            of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
            matching: find.byIcon(Icons.refresh),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'SchedulesScreen places 新規予約 in AppBar without FAB and FireTvTimePickerDialog steps cleanly',
      (tester) async {
        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:sched',
          friendlyName: 'nasne-1',
          macAddr: '00:11:22:33:44:55',
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              channelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
            ],
            child: const MaterialApp(home: SchedulesScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(FloatingActionButton), findsNothing);
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('新規予約'),
          ),
          findsOneWidget,
        );

        TimeOfDay? pickedTime;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    pickedTime = await showDialog<TimeOfDay>(
                      context: context,
                      builder: (_) => const FireTvTimePickerDialog(
                        initialTime: TimeOfDay(hour: 10, minute: 30),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        // '+1時間' has autofocus.
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        expect(find.text('11:30'), findsOneWidget);
        await tester.tap(find.text('+10分'));
        await tester.pump();
        expect(find.text('11:40'), findsOneWidget);
        await tester.tap(find.text('決定'));
        await tester.pumpAndSettle();
        expect(pickedTime, const TimeOfDay(hour: 11, minute: 40));
      },
    );

    testWidgets(
      'SettingsScreen registered nasne tap menu switches host & buffer options move cleanly per ArrowDown',
      (tester) async {
        const reg1 = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:1',
          friendlyName: 'リビング',
          macAddr: '00:11:22:33:44:55',
        );
        const reg2 = RegisteredNasne(
          host: '192.0.2.11',
          udn: 'uuid:2',
          friendlyName: '書斎',
          macAddr: '00:11:22:33:44:66',
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg1, reg2]),
              ),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              credentialSummaryProvider.overrideWith((ref) async => null),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('書斎'));
        await tester.pumpAndSettle();
        expect(find.text('この nasne を使う'), findsOneWidget);
        await tester.tap(find.text('この nasne を使う'));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(SettingsScreen)),
        );
        expect(container.read(selectedHostProvider), reg2.host);

        // Scroll to Live buffer setting and verify 1 ArrowDown moves 1 option.
        final liveBufFinder = find.text('Live のバッファ時間（遅延再生）');
        await tester.scrollUntilVisible(
          liveBufFinder,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(liveBufFinder);
        await tester.pumpAndSettle();

        final initialCtx = FocusManager.instance.primaryFocus!.context!;
        expect(
          find.ancestor(
            of: find.byWidget(initialCtx.widget),
            matching: find.byType(SimpleDialog),
          ),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        final nextCtx = FocusManager.instance.primaryFocus!.context!;
        expect(nextCtx, isNot(same(initialCtx)));
      },
    );

    testWidgets(
      'TitleDetailView protection row is single-focus reachable via ArrowUp and confirmDialog focuses cancel',
      (tester) async {
        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:prot',
          friendlyName: 'nasne',
          macAddr: '00:11:22:33:44:55',
        );
        const title = RecordedTitle(
          id: '10',
          title: '保護テスト番組',
          protectFlag: false,
        );
        var protectCalled = false;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              deviceServicesProvider.overrideWith(
                (ref, r) => DeviceServices(
                  deviceInfo: _StubDeviceInfo(),
                  settings: _StubSettings(),
                  schedules: _FixedScheduleService(const []),
                  titles: _FakeProtectTitleCatalog(
                    onProtect: (_) => protectCalled = true,
                  ),
                  metadata: _StubMetadata(),
                  live: _StubLiveCatalog(),
                  playback: _RecordingFallbackLiveEngine(),
                ),
              ),
              channelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: TitleDetailView(
                  reg: reg,
                  title: title,
                  autofocusPlay: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // ArrowUp from autofocused '再生' reaches ProtectionRow; Select toggles it.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(protectCalled, isTrue);

        // confirmDialog puts autofocus on 'キャンセル'.
        bool? confirmResult;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  confirmResult = await confirmDialog(
                    context,
                    title: '確認',
                    message: '削除しますか？',
                  );
                },
                child: const Text('confirm'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('confirm'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(confirmResult, isFalse);
      },
    );

    testWidgets(
      'AppShell auto-refreshes Live and EPG on tab revisit without flashing LoadingView',
      (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:autorefresh',
          friendlyName: 'nasne',
          macAddr: '00:11:22:33:44:55',
        );
        var liveFetches = 0;
        var epgFetches = 0;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async =>
                    const DeviceInfo(name: 'nasne', softwareVersion: '0260'),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => const NetworkInfo(
                  macAddr: '00:11:22:33:44:55',
                  ipv4Addr: '192.0.2.10',
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith((ref, r) async {
                liveFetches++;
                return [
                  LiveBand(
                    containerId: '0/video/LiveTuner/DTTB',
                    title: '地上デジタル',
                    channels: [
                      LiveChannel(
                        id: 'ch1',
                        bandId: '0/video/LiveTuner/DTTB',
                        channelName: 'NHK総合',
                        programTitle: 'Live節目#$liveFetches',
                      ),
                    ],
                  ),
                ];
              }),
              channelsProvider.overrideWith(
                (ref, r) async => const [
                  Channel(
                    broadcastingType: 2,
                    networkId: 1,
                    transportStreamId: 1,
                    serviceId: 1,
                    serviceType: 1,
                    channelNumber: 1,
                    serviceName: 'NHK総合',
                  ),
                ],
              ),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              titlesProvider(reg).overrideWith(
                () => _FixedTitlesNotifier(reg, const []),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(0, 1000),
              ),
              epgGuideProvider.overrideWith((ref, r) async {
                epgFetches++;
                final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
                final noonUtc = DateTime.utc(jstNow.year, jstNow.month, jstNow.day, 3);
                return EpgGuide(
                  broadcastingType: 2,
                  services: [
                    EpgServiceGuide(
                      channel: const Channel(
                        broadcastingType: 2,
                        networkId: 1,
                        transportStreamId: 1,
                        serviceId: 1,
                        serviceType: 1,
                        channelNumber: 1,
                        serviceName: 'NHK総合',
                      ),
                      events: [
                        EpgEvent(
                          eventId: epgFetches,
                          start: noonUtc,
                          duration: const Duration(hours: 1),
                          title: 'EPG番組#$epgFetches',
                          genreLevel1: 3,
                        ),
                      ],
                    ),
                  ],
                );
              }),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();
        expect(liveFetches, 1);
        expect(epgFetches, 1);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        container.read(tabIndexProvider.notifier).select(AppTabs.live);
        await tester.pumpAndSettle();
        expect(liveFetches, 2);
        expect(find.textContaining('Live節目#2'), findsOneWidget);

        container.read(tabIndexProvider.notifier).select(AppTabs.epg);
        await tester.pumpAndSettle();
        expect(epgFetches, 2);
      },
    );

    testWidgets(
      'Multi-nasne UI merges Schedules & colliding-ID Titles while 1-nasne keeps zero multi-nasne chrome',
      (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const reg1 = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:m1',
          friendlyName: 'nasne-1',
          macAddr: '00:11:22:33:44:55',
        );
        const reg2 = RegisteredNasne(
          host: '192.0.2.11',
          udn: 'uuid:m2',
          friendlyName: 'nasne-2',
          macAddr: '00:11:22:33:44:66',
        );
        const titleOn1 = RecordedTitle(id: '1', title: '番組A(1号機)');
        const titleOn2 = RecordedTitle(id: '1', title: '番組B(2号機)');
        final start1 = DateTime.utc(2026, 11, 24, 1, 0);
        final start2 = DateTime.utc(2026, 11, 24, 2, 0);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg1, reg2]),
              ),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              fireTvHelperProvider.overrideWithValue(
                _FakeFireTvHelper(reachable: true),
              ),
              credentialSummaryProvider.overrideWith((ref) async => null),
              deviceInfoProvider.overrideWith(
                (ref, r) async => DeviceInfo(
                  name: r.friendlyName,
                  softwareVersion: '0260',
                ),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => NetworkInfo(
                  macAddr: r.macAddr,
                  ipv4Addr: r.host,
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
              liveChannelsProvider.overrideWith(
                (ref, r) async => const <LiveBand>[],
              ),
              channelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => [
                  RecordSchedule(
                    id: '10',
                    start: r.host == reg1.host ? start1 : start2,
                    durationSeconds: 1800,
                    channel: const ScheduleChannel(
                      broadcastingType: 2,
                      channelType: 2,
                      serviceId: 1,
                    ),
                    desiredQualityMode: 100,
                    priorityFlag: 0,
                    conditionId: '',
                    desiredMatchingId: '',
                    reservationCreatorId: '',
                    recordDestinationId: 'HDD',
                    title: r.host == reg1.host ? '予約X(1号機)' : '予約Y(2号機)',
                  ),
                ],
              ),
              titlesProvider(reg1).overrideWith(
                () => _FixedTitlesNotifier(reg1, const [titleOn1]),
              ),
              titlesProvider(reg2).overrideWith(
                () => _FixedTitlesNotifier(reg2, const [titleOn2]),
              ),
              titleCountsProvider.overrideWith(
                (ref, r) async => const TitleCounts(1, 1000),
              ),
              epgGuideProvider.overrideWith(
                (ref, r) async => const EpgGuide(broadcastingType: 2, services: []),
              ),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: AppShell()),
          ),
        );
        await tester.pumpAndSettle();

        // Multi-nasne Home shows nasne switcher bar.
        expect(
          find.descendant(
            of: find.byType(HomeScreen),
            matching: find.byType(SegmentedButton<String>),
          ),
          findsOneWidget,
        );

        // Schedules merges both nasnes' reservations with owner tags.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        container.read(tabIndexProvider.notifier).select(AppTabs.schedules);
        await tester.pumpAndSettle();
        expect(find.textContaining('予約X(1号機)'), findsOneWidget);
        expect(find.textContaining('予約Y(2号機)'), findsOneWidget);
        expect(find.textContaining('[nasne-1]'), findsOneWidget);
        expect(find.textContaining('[nasne-2]'), findsOneWidget);

        // Titles merges colliding id '1' from both nasnes and shows nasne filter.
        container.read(tabIndexProvider.notifier).select(AppTabs.titles);
        await tester.pumpAndSettle();
        expect(find.text('全 2 件（2台合計・上限 2000 件）'), findsOneWidget);
        expect(find.text('全 nasne'), findsOneWidget);
        expect(find.text('番組A(1号機)'), findsOneWidget);
        expect(find.text('番組B(2号機)'), findsOneWidget);
        await tester.tap(find.text('番組B(2号機)'));
        await tester.pumpAndSettle();
        expect(find.textContaining('nasne-2'), findsWidgets);

        // Single-nasne mode shows zero multi-nasne switcher chrome.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg1]),
              ),
              deviceInfoProvider.overrideWith(
                (ref, r) async => const DeviceInfo(
                  name: 'nasne-1',
                  softwareVersion: '0260',
                ),
              ),
              hddDetailsProvider.overrideWith(
                (ref, r) async => const <HddDetail>[],
              ),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              recNgProvider.overrideWith(
                (ref, r) async => const <RecNgItem>[],
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async => NetworkInfo(
                  macAddr: reg1.macAddr,
                  ipv4Addr: reg1.host,
                  dhcpEnabled: true,
                ),
              ),
              bcasInfoProvider.overrideWith(
                (ref, r) async => const BcasInfo(),
              ),
            ],
            child: const MaterialApp(home: HomeScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SegmentedButton<String>), findsNothing);
      },
    );

    test(
      'resolveLiveRecordingConflictOrFailover picks free nasne or falls back to conflict with nasneName',
      () async {
        const reg1 = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:f1',
          friendlyName: 'リビングnasne',
          macAddr: '00:11:22:33:44:55',
        );
        const reg2 = RegisteredNasne(
          host: '192.0.2.11',
          udn: 'uuid:f2',
          friendlyName: '書斎nasne',
          macAddr: '00:11:22:33:44:66',
        );
        const ch = LiveChannel(
          id: 'ch1',
          bandId: '0/video/LiveTuner/DTTB',
          networkId: 100,
          transportStreamId: 200,
          serviceId: 1024,
          channelName: 'NHK総合',
          programTitle: '本番組',
        );
        const chOther = LiveChannel(
          id: 'ch2',
          bandId: '0/video/LiveTuner/DTTB',
          networkId: 100,
          transportStreamId: 200,
          serviceId: 9999,
          channelName: 'Eテレ',
          programTitle: '裏番組録画',
        );
        final now = DateTime.now();
        final activeOtherSched = RecordSchedule(
          id: 'r1',
          start: now.subtract(const Duration(minutes: 5)),
          durationSeconds: 3600,
          channel: const ScheduleChannel(
            broadcastingType: 2,
            channelType: 2,
            serviceId: 9999,
          ),
          desiredQualityMode: 100,
          priorityFlag: 0,
          conditionId: '',
          desiredMatchingId: '',
          reservationCreatorId: '',
          recordDestinationId: 'HDD',
          title: '裏番組録画',
        );

        // Case 1: reg1 busy on Eテレ, reg2 idle -> automatic failover to reg2.
        final c1 = ProviderContainer(
          overrides: [
            deviceServicesProvider.overrideWith(
              (ref, r) => DeviceServices(
                deviceInfo: _StubDeviceInfo(),
                settings: _StubSettings(),
                schedules: _FixedScheduleService(
                  r.host == reg1.host ? [activeOtherSched] : const [],
                ),
                titles: _StubTitleCatalog(),
                metadata: _StubMetadata(),
                live: _FixedLiveCatalog([
                  const LiveBand(
                    containerId: '0/video/LiveTuner/DTTB',
                    title: '地上デジタル',
                    channels: [ch, chOther],
                  ),
                ]),
                playback: _RecordingFallbackLiveEngine(),
              ),
            ),
          ],
        );
        addTearDown(c1.dispose);

        final res1 = await resolveLiveRecordingConflictOrFailover(
          c1,
          reg1,
          ch,
          multiNasneRegs: const [reg1, reg2],
        );
        expect(res1, isNotNull);
        expect(res1!.nasneName, 'リビングnasne');
        expect(res1.failoverRegistration?.host, reg2.host);
        expect(
          buildLiveFailoverNotice(
            fromNasneName: res1.nasneName,
            toRegistration: res1.failoverRegistration!,
          ),
          'リビングnasne で録画開始のため 書斎nasne へ切替',
        );

        // Case 2: both reg1 & reg2 busy on another channel -> no failover, dialog info populated.
        final c2 = ProviderContainer(
          overrides: [
            deviceServicesProvider.overrideWith(
              (ref, r) => DeviceServices(
                deviceInfo: _StubDeviceInfo(),
                settings: _StubSettings(),
                schedules: _FixedScheduleService([activeOtherSched]),
                titles: _StubTitleCatalog(),
                metadata: _StubMetadata(),
                live: _FixedLiveCatalog([
                  const LiveBand(
                    containerId: '0/video/LiveTuner/DTTB',
                    title: '地上デジタル',
                    channels: [ch, chOther],
                  ),
                ]),
                playback: _RecordingFallbackLiveEngine(),
              ),
            ),
          ],
        );
        addTearDown(c2.dispose);

        final res2 = await resolveLiveRecordingConflictOrFailover(
          c2,
          reg1,
          ch,
          multiNasneRegs: const [reg1, reg2],
        );
        expect(res2, isNotNull);
        expect(res2!.nasneName, 'リビングnasne');
        expect(res2.failoverRegistration, isNull);
        expect(res2.channelName, 'Eテレ');
      },
    );

    testWidgets(
      'EpgScreen aggregates reservations across nasnes and ScheduleFormPage auto-selects largest free HDD unit',
      (tester) async {
        const reg1 = RegisteredNasne(
          host: '192.0.2.10',
          udn: 'uuid:e1',
          friendlyName: 'nasne-1',
          macAddr: '00:11:22:33:44:55',
        );
        const reg2 = RegisteredNasne(
          host: '192.0.2.11',
          udn: 'uuid:e2',
          friendlyName: 'nasne-2',
          macAddr: '00:11:22:33:44:66',
        );
        const ch = Channel(
          broadcastingType: 2,
          networkId: 100,
          transportStreamId: 200,
          serviceId: 0x3333,
          serviceType: 1,
          channelNumber: 1,
          serviceName: 'テスト局',
        );
        final jstNow = DateTime.now().toUtc().add(const Duration(hours: 9));
        final noonUtc = DateTime.utc(jstNow.year, jstNow.month, jstNow.day, 3);
        final eventOn2 = EpgEvent(
          eventId: 42,
          start: noonUtc,
          duration: const Duration(hours: 1),
          title: '2号機で予約済みの番組',
          genreLevel1: 3,
        );
        final schedOn2 = RecordSchedule(
          id: 's-on-2',
          start: noonUtc,
          durationSeconds: 3600,
          channel: const ScheduleChannel(
            broadcastingType: 2,
            channelType: 2,
            serviceId: 0x3333,
          ),
          desiredQualityMode: 100,
          priorityFlag: 0,
          conditionId: '',
          desiredMatchingId: ',,0x1111,0x002a',
          reservationCreatorId: '',
          recordDestinationId: 'HDD',
          title: '2号機で予約済みの番組',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg1, reg2]),
              ),
              keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
              epgGuideProvider.overrideWith(
                (ref, r) async => EpgGuide(
                  broadcastingType: 2,
                  services: [
                    EpgServiceGuide(channel: ch, events: [eventOn2]),
                  ],
                ),
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => r.host == reg2.host ? [schedOn2] : const [],
              ),
              channelLogosProvider.overrideWith(
                (ref, r) async => const <int, List<int>>{},
              ),
            ],
            child: const MaterialApp(home: EpgScreen()),
          ),
        );
        await tester.pumpAndSettle();

        final tile = find.text('2号機で予約済みの番組', skipOffstage: false);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        await tester.tap(tile);
        await tester.pumpAndSettle();

        expect(find.text('録画予約済み（nasne-2）'), findsOneWidget);
        await tester.tap(find.text('閉じる'));
        await tester.pumpAndSettle();

        // ScheduleFormPage auto-select routes to conflict-free reg2 with larger free HDD.
        String? createdOnHost;
        final schedSvc1 = _RecordingScheduleService(
          onCreate: () => createdOnHost = reg1.host,
        );
        final schedSvc2 = _RecordingScheduleService(
          onCreate: () => createdOnHost = reg2.host,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg1, reg2]),
              ),
              channelsProvider.overrideWith((ref, r) async => const [ch]),
              hddDetailsProvider.overrideWith(
                (ref, r) async => [
                  HddDetail(
                    const HddEntry(
                      id: 0,
                      internal: false,
                      mounted: true,
                      registered: true,
                    ),
                    HddInfo(
                      id: 0,
                      internal: false,
                      format: 'ext4',
                      name: '内蔵',
                      freeBytes: r.host == reg2.host
                          ? 900 * 1024 * 1024
                          : 100 * 1024 * 1024,
                      totalBytes: 1000 * 1024 * 1024,
                      usedBytes: 100 * 1024 * 1024,
                    ),
                  ),
                ],
              ),
              deviceServicesProvider.overrideWith(
                (ref, r) => DeviceServices(
                  deviceInfo: _StubDeviceInfo(),
                  settings: _StubSettings(),
                  schedules: r.host == reg1.host ? schedSvc1 : schedSvc2,
                  titles: _StubTitleCatalog(),
                  metadata: _StubMetadata(),
                  live: _StubLiveCatalog(),
                  playback: _RecordingFallbackLiveEngine(),
                ),
              ),
            ],
            child: MaterialApp(home: ScheduleFormPage.create(reg1)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('録画する nasne'), findsOneWidget);
        await tester.ensureVisible(find.text('予約を作成'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('予約を作成'));
        await tester.pumpAndSettle();
        expect(createdOnHost, reg2.host);
      },
    );
  });

  group('Phase 22 enhancements', () {
    test('30s live corner notice constant and immediate schedule builder', () {
      expect(
        liveRecordingCornerNoticeDuration,
        const Duration(seconds: 30),
      );
      final now = DateTime.utc(2026, 11, 24, 3, 15);
      const ch = Channel(
        broadcastingType: 2,
        networkId: 30848,
        transportStreamId: 30848,
        serviceId: 56832,
        serviceType: 1,
        channelNumber: 1,
        serviceName: 'ＮＨＫ総合',
      );
      const liveCh = LiveChannel(
        id: '0/video/LiveTuner/DTTB/ch?nid=7880&tsid=7880&svid=de00',
        bandId: '0/video/LiveTuner/DTTB',
        networkId: 30848,
        transportStreamId: 30848,
        serviceId: 56832,
        programTitle: '生放送テスト',
      );
      final ev = EpgEvent(
        eventId: 0x1234,
        start: DateTime.utc(2026, 11, 24, 3, 0),
        duration: const Duration(minutes: 45),
        title: '生放送テスト',
      );

      final withEpg = buildImmediateLiveRecordingSchedule(
        channel: liveCh,
        now: now,
        desiredQualityMode: recordingQualityX3,
        matchingEpgEvent: ev,
        matchingChannel: ch,
      )!;
      expect(withEpg.eventId, 0x1234);
      expect(withEpg.start, ev.start);
      expect(withEpg.durationSeconds, 2700);
      expect(withEpg.desiredQualityMode, 230);
      expect(withEpg.channel.serviceId, 56832);
      expect(withEpg.networkId, 30848);

      final withoutEpg = buildImmediateLiveRecordingSchedule(
        channel: LiveChannel(
          id: liveCh.id,
          bandId: liveCh.bandId,
          networkId: 30848,
          serviceId: 56832,
          programTitle: '手動枠',
          programEnd: now.add(const Duration(minutes: 20)),
        ),
        now: now,
        desiredQualityMode: recordingQualityDr,
      )!;
      expect(withoutEpg.eventId, 0);
      expect(withoutEpg.start, now);
      expect(withoutEpg.durationSeconds, 1200);
      expect(withoutEpg.desiredQualityMode, 100);

      final active = RecordSchedule(
        id: 'r1',
        start: now.subtract(const Duration(minutes: 5)),
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 56832,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: ',,0x7880,0x1234',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
      );
      expect(isScheduleCurrentlyRecording(active, now: now), isTrue);
      expect(
        isScheduleCurrentlyRecording(
          active,
          now: now.add(const Duration(minutes: 30)),
        ),
        isFalse,
      );
    });

    testWidgets('OSD 録画中 and LIVE badges use identical box shape and height', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildPlayerOsdStatusBadge(
                  label: '録画中',
                  color: const Color(0xFFC62828),
                  icon: Icons.fiber_manual_record,
                ),
                const SizedBox(width: 8),
                buildPlayerOsdStatusBadge(
                  label: 'LIVE',
                  color: Colors.redAccent,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final recBox = tester.getRect(
        find.ancestor(
          of: find.text('録画中'),
          matching: find.byType(Container),
        ),
      );
      final liveBox = tester.getRect(
        find.ancestor(
          of: find.text('LIVE'),
          matching: find.byType(Container),
        ),
      );
      expect((recBox.height - liveBox.height).abs(), lessThan(0.1));

      final containers = tester.widgetList<Container>(find.byType(Container));
      for (final c in containers) {
        final dec = c.decoration as BoxDecoration?;
        expect(dec?.borderRadius, BorderRadius.circular(4));
      }
    });

    testWidgets(
      'Default recording quality persists in Settings and seeds new ScheduleFormPage',
      (tester) async {
        final kvStore = InMemoryKeyValueStore();
        const reg = RegisteredNasne(
          host: '192.0.2.20',
          udn: 'uuid:q1',
          friendlyName: 'nasne-q',
          macAddr: '00:11:22:33:44:55',
        );
        const ch = Channel(
          broadcastingType: 2,
          networkId: 100,
          transportStreamId: 200,
          serviceId: 0x1111,
          serviceType: 1,
          channelNumber: 1,
          serviceName: 'テスト局',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(kvStore),
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              debugLogSharerProvider.overrideWithValue(null),
              debugLogFolderOpenerProvider.overrideWithValue(null),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.text('デフォルト録画画質'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('3倍'));
        await tester.pumpAndSettle();
        expect(await kvStore.read('firetv_default_recording_quality'), '230');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(kvStore),
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              channelsProvider.overrideWith((ref, r) async => const [ch]),
              hddDetailsProvider.overrideWith((ref, r) async => const []),
            ],
            child: MaterialApp(home: ScheduleFormPage.create(reg)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('3倍'), findsOneWidget);
      },
    );

    testWidgets(
      'EpgEventDetailDialog offers 録画を停止 only while actively recording and calls deleteSchedule',
      (tester) async {
        final deletedIds = <String>[];
        const reg = RegisteredNasne(
          host: '192.0.2.30',
          udn: 'uuid:epg-stop',
          friendlyName: 'nasne-epg',
          macAddr: '00:11:22:33:44:55',
        );
        const ch = Channel(
          broadcastingType: 2,
          networkId: 100,
          transportStreamId: 200,
          serviceId: 0x2222,
          serviceType: 1,
          channelNumber: 1,
          serviceName: 'テスト局',
        );
        final now = DateTime.now();
        final activeEvent = EpgEvent(
          eventId: 77,
          start: now.subtract(const Duration(minutes: 10)),
          duration: const Duration(minutes: 40),
          title: '放送中録画番組',
        );
        final activeSchedule = RecordSchedule(
          id: 'sched-active-77',
          start: activeEvent.start,
          durationSeconds: 2400,
          conditionId: '1',
          channel: const ScheduleChannel(
            broadcastingType: 2,
            channelType: 2,
            serviceId: 0x2222,
          ),
          desiredQualityMode: 100,
          desiredMatchingId: ',,0x0064,0x004d',
          reservationCreatorId: '2000',
          priorityFlag: 0,
          recordDestinationId: 'HDD',
          title: '放送中録画番組',
        );
        final futureEvent = EpgEvent(
          eventId: 78,
          start: now.add(const Duration(hours: 2)),
          duration: const Duration(minutes: 30),
          title: '未来の予約番組',
        );
        final futureSchedule = RecordSchedule(
          id: 'sched-future-78',
          start: futureEvent.start,
          durationSeconds: 1800,
          conditionId: '1',
          channel: activeSchedule.channel,
          desiredQualityMode: 100,
          desiredMatchingId: ',,0x0064,0x004e',
          reservationCreatorId: '2000',
          priorityFlag: 0,
          recordDestinationId: 'HDD',
          title: '未来の予約番組',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              deviceServicesProvider.overrideWith(
                (ref, r) => DeviceServices(
                  deviceInfo: _StubDeviceInfo(),
                  settings: _StubSettings(),
                  schedules: _DeletableScheduleService(
                    onDelete: deletedIds.add,
                  ),
                  titles: _StubTitleCatalog(),
                  metadata: _StubMetadata(),
                  live: _StubLiveCatalog(),
                  playback: _RecordingFallbackLiveEngine(),
                ),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Column(
                    children: [
                      ElevatedButton(
                        onPressed: () => showEpgEventDetail(
                          context,
                          reg: reg,
                          channel: ch,
                          channelName: ch.serviceName,
                          event: futureEvent,
                          existingSchedule: futureSchedule,
                        ),
                        child: const Text('open_future'),
                      ),
                      ElevatedButton(
                        onPressed: () => showEpgEventDetail(
                          context,
                          reg: reg,
                          channel: ch,
                          channelName: ch.serviceName,
                          event: activeEvent,
                          existingSchedule: activeSchedule,
                        ),
                        child: const Text('open_active'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Future reservation shows edit only, not stop.
        await tester.tap(find.text('open_future'));
        await tester.pumpAndSettle();
        expect(find.text('録画を停止'), findsNothing);
        expect(find.text('予約を編集'), findsOneWidget);
        await tester.tap(find.text('閉じる'));
        await tester.pumpAndSettle();

        // Active recording shows 録画を停止 -> confirm -> deleteSchedule.
        await tester.tap(find.text('open_active'));
        await tester.pumpAndSettle();
        expect(find.text('録画中'), findsOneWidget);
        await tester.tap(find.text('録画を停止'));
        await tester.pumpAndSettle();
        expect(find.text('録画を停止しますか？'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '録画を停止'));
        await tester.pumpAndSettle();

        expect(deletedIds, ['sched-active-77']);
      },
    );

    testWidgets(
      'SchedulesScreen failure management & HomeScreen sync filter dismissed recNg items',
      (tester) async {
        const reg = RegisteredNasne(
          host: '192.0.2.40',
          udn: 'uuid:recng',
          friendlyName: 'nasne-ng',
          macAddr: '00:11:22:33:44:55',
        );
        final item1 = RecNgItem.fromJson({
          'id': '10000000000000000009',
          'title': '失敗番組A',
          'scheduledStartDateTime': '2026-11-11T20:30:00+09:00',
          'scheduledDuration': 900,
          'scheduledChannelID': 56840,
          'broadcastingType': 2,
          'desiredQualityMode': 101,
          'ngID': 3,
        });
        final item2 = RecNgItem.fromJson({
          'id': '10000000000000000009',
          'title': '失敗番組B',
          'scheduledStartDateTime': '2026-11-15T18:45:00+09:00',
          'scheduledDuration': 1800,
          'scheduledChannelID': 56832,
          'broadcastingType': 2,
          'desiredQualityMode': 100,
          'ngID': 5,
        });
        expect(item1.desiredQualityMode, 101);
        expect(item1.ngId, 3);
        expect(recNgQualityModeLabel(101), '3倍');
        expect(recNgQualityModeLabel(100), 'DR');
        expect(
          recNgDismissKey(reg, item1),
          isNot(recNgDismissKey(reg, item2)),
        );

        final kvStore = InMemoryKeyValueStore();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(kvStore),
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              channelsProvider.overrideWith((ref, r) async => const <Channel>[]),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              recNgProvider.overrideWith((ref, r) async => [item1, item2]),
            ],
            child: const MaterialApp(home: SchedulesScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('録画失敗 (2)'), findsOneWidget);
        await tester.tap(find.text('録画失敗 (2)'));
        await tester.pumpAndSettle();

        // Newest failure first ('失敗番組B').
        expect(find.text('失敗番組B'), findsOneWidget);
        expect(find.text('失敗番組A'), findsOneWidget);
        expect(find.text('すべて削除'), findsOneWidget);

        // Dismiss single failure via detail page.
        await tester.tap(find.text('失敗番組B'));
        await tester.pumpAndSettle();
        expect(find.text('ngID=5'), findsOneWidget);
        await tester.tap(find.text('この履歴を削除'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '削除'));
        await tester.pumpAndSettle();

        expect(find.text('失敗番組B'), findsNothing);
        expect(find.text('失敗番組A'), findsOneWidget);
        expect(find.text('録画失敗 (1)'), findsOneWidget);

        // Verify HomeScreen stays synchronized with dismissed item.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(kvStore),
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              deviceInfoProvider.overrideWith(
                (ref, r) async => const DeviceInfo(
                  name: 'nasne-ng',
                  softwareVersion: '0260',
                ),
              ),
              hddDetailsProvider.overrideWith((ref, r) async => const []),
              liveStatusProvider.overrideWith(
                (ref, r) async => const LiveStatus(sections: {}, raw: {}),
              ),
              networkInfoProvider.overrideWith(
                (ref, r) async =>
                    const NetworkInfo(macAddr: '00:11:22:33:44:55', ipv4Addr: '192.0.2.40'),
              ),
              bcasInfoProvider.overrideWith((ref, r) async => const BcasInfo()),
              recNgProvider.overrideWith((ref, r) async => [item1, item2]),
            ],
            child: const MaterialApp(home: HomeScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('失敗番組B'), findsNothing);
        expect(find.textContaining('失敗番組A'), findsOneWidget);

        // Verify 'すべて削除' clears remaining entries.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(kvStore),
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
              schedulesProvider.overrideWith(
                (ref, r) async => const <RecordSchedule>[],
              ),
              channelsProvider.overrideWith((ref, r) async => const <Channel>[]),
              bsChannelsProvider.overrideWith(
                (ref, r) async => const <Channel>[],
              ),
              recNgProvider.overrideWith((ref, r) async => [item1, item2]),
            ],
            child: const MaterialApp(home: SchedulesScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('録画失敗 (1)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('すべて削除'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'すべて削除'));
        await tester.pumpAndSettle();
        expect(find.text('録画失敗はありません'), findsOneWidget);
      },
    );
  });

  group('Phase 24: live startup speed, buffer badge, stop sync, catch-up & Left/Right switch', () {
    test('live demuxer probe limits and schedule/channel switch helpers behave accurately', () {
      expect(liveDemuxerAnalyzeDurationSeconds, 1.5);
      expect(liveDemuxerProbeSizeBytes(useMobile: true), 512 * 1024);
      expect(liveDemuxerProbeSizeBytes(useMobile: false), 2 * 1024 * 1024);

      expect(
        adjacentLiveChannelIndex(
          currentIndex: 0,
          count: 1,
          direction: ChannelSwitchDirection.next,
        ),
        -1,
      );
      expect(
        adjacentLiveChannelIndex(
          currentIndex: 0,
          count: 3,
          direction: ChannelSwitchDirection.previous,
        ),
        2,
      );
      expect(
        adjacentLiveChannelIndex(
          currentIndex: 2,
          count: 3,
          direction: ChannelSwitchDirection.next,
        ),
        0,
      );

      final s1 = RecordSchedule(
        id: '101',
        start: DateTime.utc(2026, 11, 24, 1, 0),
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 0x0400,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: ',,0x7880,0x0001',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
      );
      final s2 = RecordSchedule(
        id: '102',
        start: DateTime.utc(2026, 11, 24, 2, 0),
        durationSeconds: 1800,
        conditionId: '1',
        channel: const ScheduleChannel(
          broadcastingType: 2,
          channelType: 2,
          serviceId: 0x0408,
        ),
        desiredQualityMode: 100,
        desiredMatchingId: ',,0x7881,0x0002',
        reservationCreatorId: '2000',
        priorityFlag: 0,
        recordDestinationId: 'HDD',
      );
      expect(schedulesWithoutId([s1, s2], '101').map((s) => s.id), ['102']);
      expect(
        schedulesExcludingIds([s1, s2], {'102'}).map((s) => s.id),
        ['101'],
      );
      expect(ensureSchedulePresent([s1], s2).map((s) => s.id), ['101', '102']);
      expect(ensureSchedulePresent([s1, s2], s2).length, 2);

      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: false,
          channelPreviewOpen: true,
        ),
        PlayerBackOutcome.closeChannelPreview,
      );
      expect(
        resolvePlayerBackOutcome(
          detailOpen: false,
          osdOpen: true,
          channelPreviewOpen: true,
        ),
        PlayerBackOutcome.closeOsd,
      );
    });

    testWidgets(
      'PlayerOsdStatusBadge dark translucent style matches LIVE badge geometry',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  buildPlayerOsdStatusBadge(
                    label: 'バッファ: 15秒',
                    color: const Color(0xB3000000),
                    border: Border.all(color: Colors.white24),
                  ),
                  const SizedBox(width: 8),
                  buildPlayerOsdStatusBadge(
                    label: 'LIVE',
                    color: Colors.redAccent,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final bufFinder = find.ancestor(
          of: find.text('バッファ: 15秒'),
          matching: find.byType(Container),
        );
        final liveFinder = find.ancestor(
          of: find.text('LIVE'),
          matching: find.byType(Container),
        );
        final bufRect = tester.getRect(bufFinder);
        final liveRect = tester.getRect(liveFinder);
        expect((bufRect.height - liveRect.height).abs(), lessThanOrEqualTo(2.1));

        final bufDec = tester.widget<Container>(bufFinder).decoration
            as BoxDecoration;
        expect(bufDec.color, const Color(0xB3000000));
        expect(bufDec.borderRadius, BorderRadius.circular(4));

        final bufText = tester.widget<Text>(find.text('バッファ: 15秒'));
        expect(bufText.style?.color, Colors.white);
        expect(bufText.style?.fontSize, 12);
        expect(bufText.style?.height, 1.2);
      },
    );

    test(
      'reconcileLiveRecordingSchedules suppresses stale stopped ids and canSeekWithinLiveCache enforces hybrid catch-up bounds',
      () {
        final now = DateTime.now();
        final active = RecordSchedule(
          id: 'sched-stale-9',
          start: now.subtract(const Duration(minutes: 5)),
          durationSeconds: 3600,
          conditionId: '1',
          channel: const ScheduleChannel(
            broadcastingType: 2,
            channelType: 2,
            serviceId: 0x0408,
          ),
          desiredQualityMode: 100,
          desiredMatchingId: ',,0x7fe1,0x0009',
          reservationCreatorId: '2000',
          priorityFlag: 0,
          recordDestinationId: 'HDD',
          title: '現在の番組',
        );
        final chCur = LiveChannel(
          id: '0/video/LiveTuner/DTTB/2',
          bandId: '0/video/LiveTuner/DTTB',
          channelName: 'Eテレ',
          programTitle: '現在の番組',
          serviceId: 0x0408,
          networkId: 0x7FE1,
          res: const [
            TitleRes(
              url: 'http://127.0.0.1:1/cur',
              protocolInfo: 'http-get:*:video/vnd.dlna.mpeg-tts:*',
              quality: 'mobile',
            ),
          ],
        );

        // Stop succeeded, even if nasne immediately returns the stale schedule -> stays hidden.
        final afterStop = reconcileLiveRecordingSchedules(
          currentSchedules: [active],
          currentStoppedIds: const {},
          isStopAction: true,
          actionSucceeded: true,
          targetScheduleId: active.id,
          updatedSchedules: [active],
        );
        expect(afterStop.stoppedIds, {'sched-stale-9'});
        expect(afterStop.schedules, isEmpty);
        expect(
          findActiveSameChannelRecording(
            afterStop.schedules,
            currentChannel: chCur,
            now: now,
          ),
          isNull,
        );

        // Even if background polling returns [active] again, schedulesExcludingIds hides it.
        expect(
          schedulesExcludingIds([active], afterStop.stoppedIds),
          isEmpty,
        );

        // Starting a fresh schedule clears the id guard when it appears in updatedSchedules.
        final afterRestart = reconcileLiveRecordingSchedules(
          currentSchedules: afterStop.schedules,
          currentStoppedIds: afterStop.stoppedIds,
          isStopAction: false,
          actionSucceeded: true,
          updatedSchedules: [active],
        );
        expect(afterRestart.stoppedIds, isEmpty);
        expect(afterRestart.schedules, [active]);

        // Hybrid catch-up: buffer=0 -> always resets upstream via proxy.
        expect(
          canSeekWithinLiveCache(
            useCache: false,
            configuredBufferSeconds: 0,
            totalPauseLagSeconds: 5,
            cacheDurationSeconds: 10,
            cacheTimeSeconds: 20,
            timePosSeconds: 10,
          ),
          isFalse,
        );
        // Short pause within 60s buffer -> seamless cache seek!
        expect(
          canSeekWithinLiveCache(
            useCache: true,
            configuredBufferSeconds: 60,
            totalPauseLagSeconds: 12,
            cacheDurationSeconds: 15,
            cacheTimeSeconds: 45,
            timePosSeconds: 30,
          ),
          isTrue,
        );
        // Long pause exceeding configured buffer -> falls back to proxy live-edge reset.
        expect(
          canSeekWithinLiveCache(
            useCache: true,
            configuredBufferSeconds: 30,
            totalPauseLagSeconds: 45,
            cacheDurationSeconds: 15,
            cacheTimeSeconds: 45,
            timePosSeconds: 30,
          ),
          isFalse,
        );
      },
    );

    testWidgets(
      'PlayerCornerNotice and shouldShowPlayerCornerNotice display custom notices even when recordingNotice is null',
      (tester) async {
        expect(
          shouldShowPlayerCornerNotice(
            cornerRecordingNotice: null,
            customCornerNoticeText: 'フェイルオーバー通知',
            osdOpen: false,
            detailOpen: false,
            interrupted: false,
            error: null,
            switchingChannel: false,
          ),
          isTrue,
        );
        expect(
          shouldShowPlayerCornerNotice(
            cornerRecordingNotice: LiveRecordingCornerNotice.recording,
            customCornerNoticeText: null,
            osdOpen: true,
            detailOpen: false,
            interrupted: false,
            error: null,
            switchingChannel: false,
          ),
          isFalse,
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  PlayerCornerNotice(
                    customText: 'フェイルオーバー通知',
                    recordingNotice: null,
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.text('フェイルオーバー通知'), findsOneWidget);

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  PlayerCornerNotice(
                    customText: null,
                    recordingNotice: LiveRecordingCornerNotice.ended,
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.text('録画終了'), findsOneWidget);
      },
    );

    testWidgets(
      'LiveChannelSwitchPreviewCard slides from left/right edges, displays programme info, and triggers switch on tap',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const reg = RegisteredNasne(
          host: '192.0.2.55',
          udn: 'uuid:p24',
          friendlyName: 'nasne-p24',
          macAddr: '00:11:22:33:44:55',
        );
        final prevStart = DateTime(2026, 11, 24, 11, 0);
        final prevEnd = DateTime(2026, 11, 24, 12, 0);
        final start = DateTime(2026, 11, 24, 12, 0);
        final end = DateTime(2026, 11, 24, 13, 0);
        final chPrev = LiveChannel(
          id: '0/video/LiveTuner/DTTB/1',
          bandId: '0/video/LiveTuner/DTTB',
          channelName: 'NHK総合',
          programTitle: '前の番組',
          programStart: prevStart,
          programEnd: prevEnd,
          serviceId: 0x0400,
          networkId: 0x7FE0,
          res: const [
            TitleRes(
              url: 'http://127.0.0.1:1/prev',
              protocolInfo: 'http-get:*:video/vnd.dlna.mpeg-tts:*',
              quality: 'mobile',
            ),
          ],
        );
        final chNext = LiveChannel(
          id: '0/video/LiveTuner/DTTB/3',
          bandId: '0/video/LiveTuner/DTTB',
          channelName: '日本テレビ',
          programTitle: '次のニュース番組',
          programStart: start,
          programEnd: end,
          serviceId: 0x0410,
          networkId: 0x7FE8,
          res: const [
            TitleRes(
              url: 'http://127.0.0.1:1/next',
              protocolInfo: 'http-get:*:video/vnd.dlna.mpeg-tts:*',
              quality: 'mobile',
            ),
          ],
        );
        final prevEntry = LiveChannelSwitchEntry(
          channel: chPrev,
          primaryReg: reg,
          candidates: [OwnedLiveChannel(reg: reg, channel: chPrev)],
        );
        final nextEntry = LiveChannelSwitchEntry(
          channel: chNext,
          primaryReg: reg,
          candidates: [OwnedLiveChannel(reg: reg, channel: chNext)],
        );

        final tapped = <String>[];
        Widget buildHarness(
          ChannelSwitchDirection? activeDir, {
          Brightness brightness = Brightness.dark,
        }) => MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: Stack(
              children: [
                LiveChannelSwitchPreviewCard(
                  direction: ChannelSwitchDirection.previous,
                  visible: activeDir == ChannelSwitchDirection.previous,
                  entry: prevEntry,
                  onTap: () => tapped.add(prevEntry.displayChannelName),
                ),
                LiveChannelSwitchPreviewCard(
                  direction: ChannelSwitchDirection.next,
                  visible: activeDir == ChannelSwitchDirection.next,
                  entry: nextEntry,
                  onTap: () => tapped.add(nextEntry.displayChannelName),
                ),
              ],
            ),
          ),
        );

        // Next card visible flush at right edge in Dark mode without border.
        await tester.pumpWidget(buildHarness(ChannelSwitchDirection.next));
        await tester.pump(const Duration(milliseconds: 250));
        final nextFinder = find.byKey(
          const ValueKey('live_channel_preview_next'),
        );
        final prevFinder = find.byKey(
          const ValueKey('live_channel_preview_previous'),
        );
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: nextFinder,
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity,
          1.0,
        );
        expect(
          tester
              .widget<AnimatedSlide>(
                find.ancestor(
                  of: nextFinder,
                  matching: find.byType(AnimatedSlide),
                ),
              )
              .offset,
          Offset.zero,
        );
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: prevFinder,
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity,
          0.0,
        );
        final nextDarkDeco =
            tester.widget<Container>(nextFinder).decoration! as BoxDecoration;
        expect(nextDarkDeco.border, isNull);
        expect(nextDarkDeco.color, const Color(0xD90D1117));
        expect(
          nextDarkDeco.borderRadius,
          const BorderRadius.only(
            topLeft: Radius.circular(14),
            bottomLeft: Radius.circular(14),
          ),
        );
        expect(find.text('次のチャンネル'), findsOneWidget);
        expect(find.text('日本テレビ'), findsOneWidget);
        expect(find.text('次のニュース番組'), findsOneWidget);
        expect(find.text(nextEntry.broadcastTimeRange!), findsOneWidget);
        expect(tester.getRect(nextFinder).right, closeTo(1280.0, 0.01));

        // Tapping next card triggers switch.
        await tester.tap(nextFinder);
        expect(tapped, ['日本テレビ']);

        // Switch to Previous card visible flush at left edge in Light mode.
        await tester.pumpWidget(
          buildHarness(
            ChannelSwitchDirection.previous,
            brightness: Brightness.light,
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: prevFinder,
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity,
          1.0,
        );
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: nextFinder,
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity,
          0.0,
        );
        final prevLightDeco =
            tester.widget<Container>(prevFinder).decoration! as BoxDecoration;
        expect(prevLightDeco.border, isNull);
        expect(prevLightDeco.color, const Color(0xF5FFFFFF));
        expect(
          prevLightDeco.borderRadius,
          const BorderRadius.only(
            topRight: Radius.circular(14),
            bottomRight: Radius.circular(14),
          ),
        );
        expect(tester.getRect(prevFinder).left, closeTo(0.0, 0.01));

        // Dismiss both cards.
        await tester.pumpWidget(buildHarness(null));
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: prevFinder,
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity,
          0.0,
        );
      },
    );
  });

  group('Phase 25: borderless channel card, OSD quality switch, and chase catch-up', () {
    test(
      'liveCatchUpSpeedForLagSeconds, osdLiveStatusBadgeSpec, and osdQualityButtonLabel follow Phase 25 policy',
      () {
        expect(liveCatchUpSpeedForLagSeconds(0.0), 1.0);
        expect(liveCatchUpSpeedForLagSeconds(1.5), 1.0);
        expect(liveCatchUpSpeedForLagSeconds(2.0), 1.25);
        expect(liveCatchUpSpeedForLagSeconds(15.0), 1.25);
        expect(liveCatchUpSpeedForLagSeconds(30.0), 1.25);
        expect(liveCatchUpSpeedForLagSeconds(30.1), 1.5);
        expect(liveCatchUpSpeedForLagSeconds(60.0), 1.5);
        expect(liveCatchUpSpeedForLagSeconds(120.0), 1.5);
        expect(liveCatchUpSpeedForLagSeconds(180.0), 2.0);

        // Downward hysteresis avoids speed chattering near thresholds.
        expect(liveCatchUpSpeedForLagSeconds(118.0, currentRate: 2.0), 2.0);
        expect(liveCatchUpSpeedForLagSeconds(114.0, currentRate: 2.0), 1.5);
        expect(liveCatchUpSpeedForLagSeconds(28.0, currentRate: 1.5), 1.5);
        expect(liveCatchUpSpeedForLagSeconds(24.0, currentRate: 1.5), 1.25);
        expect(liveCatchUpSpeedForLagSeconds(1.4, currentRate: 1.25), 1.0);

        final realtimeBadge = osdLiveStatusBadgeSpec(
          liveDelayedByPause: false,
          liveCatchUpRate: 1.0,
        );
        expect(realtimeBadge.label, 'LIVE');
        expect(realtimeBadge.color, Colors.redAccent);

        final delayedPausedBadge = osdLiveStatusBadgeSpec(
          liveDelayedByPause: true,
          liveCatchUpRate: 1.5,
          isPaused: true,
        );
        expect(delayedPausedBadge.label, '一時停止');
        expect(delayedPausedBadge.color, const Color(0xFFEF6C00));

        final delayedNormalBadge = osdLiveStatusBadgeSpec(
          liveDelayedByPause: true,
          liveCatchUpRate: 1.0,
        );
        expect(delayedNormalBadge.label, '追いかけ再生');
        expect(delayedNormalBadge.color, const Color(0xFFEF6C00));

        final delayedFastBadge = osdLiveStatusBadgeSpec(
          liveDelayedByPause: true,
          liveCatchUpRate: 1.5,
        );
        expect(delayedFastBadge.label, '追いかけ再生 1.5倍');
        expect(delayedFastBadge.color, const Color(0xFFEF6C00));

        final delayedDoubleBadge = osdLiveStatusBadgeSpec(
          liveDelayedByPause: true,
          liveCatchUpRate: 2.0,
        );
        expect(delayedDoubleBadge.label, '追いかけ再生 2倍');
        expect(delayedDoubleBadge.color, const Color(0xFFEF6C00));

        expect(osdQualityButtonLabel(useMobile: false), '画質: 元画質');
        expect(osdQualityButtonLabel(useMobile: true), '画質: モバイル');
      },
    );
  });

  group(
    'Phase 26: TV-sized subtitle customization, ARIB symbols/ASS parser, and clear timing',
    () {
      test(
        'SubtitleSettings defaults, JSON persistence fallback, size, and edge helpers',
        () {
          const defaults = SubtitleSettings.defaults;
          expect(defaults.size, SubtitleSizePreset.medium);
          expect(defaults.font, SubtitleFontFamily.gothicBold);
          expect(defaults.edge, SubtitleEdgeStyle.thin);
          expect(defaults.backgroundColor, SubtitleBackgroundColorPreset.black);
          expect(defaults.backgroundOpacityPercent, 65);
          expect(
            defaults.effectiveBackgroundColor.a,
            closeTo(0.65, 0.01),
          );

          const transparent = SubtitleSettings(
            backgroundColor: SubtitleBackgroundColorPreset.navy,
            backgroundOpacityPercent: 0,
          );
          expect(transparent.effectiveBackgroundColor, Colors.transparent);

          final custom = const SubtitleSettings(
            size: SubtitleSizePreset.large,
            font: SubtitleFontFamily.lineSeedJp,
            edge: SubtitleEdgeStyle.thick,
            backgroundColor: SubtitleBackgroundColorPreset.darkGray,
            backgroundOpacityPercent: 85,
          );
          final roundtripped = SubtitleSettings.fromJsonString(
            custom.toJsonString(),
          );
          expect(roundtripped, custom);

          expect(SubtitleSettings.fromJsonString(null), defaults);
          expect(SubtitleSettings.fromJsonString('not-json'), defaults);
          expect(
            SubtitleSettings.fromJsonString(
              '{"size":"unknown","bgOpacity":33,"font":"kosugiMaru"}',
            ),
            const SubtitleSettings(font: SubtitleFontFamily.kosugiMaru),
          );

          // 540dp Fire TV viewport yields TV-sized glyphs across 3 presets.
          expect(
            resolveSubtitleFontSize(SubtitleSizePreset.small, 540),
            closeTo(22.68, 0.05),
          );
          expect(
            resolveSubtitleFontSize(SubtitleSizePreset.medium, 540),
            closeTo(28.08, 0.05),
          );
          expect(
            resolveSubtitleFontSize(SubtitleSizePreset.large, 540),
            closeTo(34.56, 0.05),
          );
          expect(
            resolveSubtitleFontSize(
              SubtitleSizePreset.small,
              200,
              minSize: 16.0,
            ),
            16.0,
          );

          expect(resolveSubtitleEdgeWidth(SubtitleEdgeStyle.none, 36), 0.0);
          expect(
            resolveSubtitleEdgeWidth(SubtitleEdgeStyle.dropShadow, 36),
            0.0,
          );
          expect(
            resolveSubtitleEdgeWidth(SubtitleEdgeStyle.thickShadow, 36),
            0.0,
          );
          expect(
            resolveSubtitleEdgeWidth(SubtitleEdgeStyle.thin, 36),
            closeTo(3.96, 0.01),
          );
          expect(
            resolveSubtitleEdgeWidth(SubtitleEdgeStyle.thick, 36),
            closeTo(6.48, 0.01),
          );
          expect(
            resolveSubtitleTextShadows(SubtitleEdgeStyle.none, 36),
            isEmpty,
          );
          expect(
            resolveSubtitleTextShadows(SubtitleEdgeStyle.dropShadow, 36),
            hasLength(2),
          );
          final thickShadows = resolveSubtitleTextShadows(
            SubtitleEdgeStyle.thickShadow,
            36,
          );
          expect(thickShadows, hasLength(3));
          expect(
            thickShadows.every((s) => s.offset == Offset.zero),
            isTrue,
          );
          expect(subtitleBackgroundOpacityLabel(0), 'なし (0%)');
          expect(subtitleBackgroundOpacityLabel(65), '標準 (65%)');
          expect(SubtitleFontFamily.lineSeedJp.fontFamily, 'LINESeedJP');
          expect(SubtitleFontFamily.lineSeedJpBold.fontFamily, 'LINESeedJP');
          expect(SubtitleFontFamily.lineSeedJpBold.fontWeight, FontWeight.w700);
          expect(SubtitleFontFamily.kosugiMaru.fontFamily, 'KosugiMaru');
          expect(SubtitleFontFamily.kosugiMaru.label, '丸ゴシック');
        },
      );

      test(
        'normalizeAribSubtitleSymbols maps enclosed symbols/arrows and strips replacement chars',
        () {
          expect(
            normalizeAribSubtitleSymbols(
              '♪\u{1F211} ニュース \u{1F214} \u{1F14A} \u{1F240} 続けます\u27A1',
            ),
            '♪[字] ニュース [二] [HV] 〔本〕 続けます→',
          );
          expect(
            normalizeAribSubtitleSymbols(
              '\u2B05左 \u2B06上 \u2B07下 バックヤー\uFFFD\uFE0F\u200B',
            ),
            '←左 ↑上 ↓下 バックヤー',
          );
          expect(
            normalizeAribSubtitleSymbols('外字\uE001と\uE123'),
            '外字〓と〓',
          );
        },
      );

      test(
        'parseAssPlayRes and parseAribAssSubtitle extract coordinates, colors, and strip vector drawings',
        () {
          final defaultRes = parseAssPlayRes(null);
          expect(defaultRes.width, 960.0);
          expect(defaultRes.height, 540.0);

          final customRes = parseAssPlayRes(
            '[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n',
          );
          expect(customRes.width, 1920.0);
          expect(customRes.height, 1080.0);

          final parsed = parseAribAssSubtitle(
            'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,'
            '{\\an1\\pos(192,432)\\1c&H00FFFF&}こんにちは{\\c&HFFFFFF&}\\Nお元気ですか\n'
            'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,'
            '{\\p1}m 0 0 l 100 0 100 20{\\p0}通常字幕',
            playResWidth: 960.0,
            playResHeight: 540.0,
          );
          expect(parsed, hasLength(2));
          expect(parsed[0].alignment, 1);
          expect(parsed[0].normalizedX, closeTo(0.2, 0.001));
          expect(parsed[0].normalizedY, closeTo(0.8, 0.001));
          expect(parsed[0].spans, hasLength(2));
          expect(parsed[0].spans[0].text, 'こんにちは');
          expect(parsed[0].spans[0].color, const Color(0xFFFFFF00));
          expect(parsed[0].spans[1].text, '\nお元気ですか');
          expect(parsed[0].spans[1].color, Colors.white);
          expect(parsed[1].plainText, '通常字幕');

          // Same-Y segments placed separately along X merge left-to-right.
          final merged = parseAribAssSubtitle(
            'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,{\\pos(600,450)\\c&H00FF00&}後半\n'
            'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,{\\pos(200,450)\\c&HFFFF00&}前半',
            playResWidth: 960.0,
            playResHeight: 540.0,
          );
          expect(merged, hasLength(1));
          expect(merged.single.spans.map((s) => s.text).toList(), ['前半', '後半']);
          expect(merged.single.spans[0].color, const Color(0xFF00FFFF));
          expect(merged.single.spans[1].color, const Color(0xFF00FF00));
          expect(merged.single.normalizedX, closeTo(200 / 960.0, 0.001));
        },
      );

      test(
        'resolveRawSubtitleCues pairs matching ASS markup and falls back safely on mismatch or clear',
        () {
          final matched = resolveRawSubtitleCues(
            rawAss: '{\\an7\\pos(120,70)\\c&H00FF00&}ニュース\u{1F211}',
            plainLines: const ['ニュース\u{1F211}'],
            playResWidth: 960.0,
            playResHeight: 540.0,
          );
          expect(matched, hasLength(1));
          expect(matched.single.alignment, 7);
          expect(matched.single.plainText, 'ニュース[字]');
          expect(matched.single.spans.single.color, const Color(0xFF00FF00));

          final mismatched = resolveRawSubtitleCues(
            rawAss: '{\\pos(120,70)}古い字幕',
            plainLines: const ['新しい字幕\u27A1'],
          );
          expect(mismatched, hasLength(1));
          expect(mismatched.single.normalizedY, isNull);
          expect(mismatched.single.plainText, '新しい字幕→');

          expect(
            resolveRawSubtitleCues(
              rawAss: '{\\pos(120,70)}残骸',
              plainLines: const [],
            ),
            isEmpty,
          );
        },
      );

      test(
        'SubtitleActiveWindowTracker prevents 7-line lingering, handles bursts/prefix/upgrade, and clears on playback clock',
        () {
          SubtitleCue cue(String text, {double? y}) => SubtitleCue(
            spans: [SubtitleStyledSpan(text: text)],
            normalizedY: y,
          );

          final tracker = SubtitleActiveWindowTracker();

          // Initial attach with >2 accumulated lines keeps only last 2.
          final initial = tracker.update(
            [cue('行1'), cue('行2'), cue('行3'), cue('行4')],
            const Duration(seconds: 1),
          );
          expect(initial.map((c) => c.plainText).toList(), ['行3', '行4']);

          // Subsequent 7-line mpv accumulation (>900ms spacing) shows only newest line.
          tracker.reset();
          var lines = <SubtitleCue>[];
          for (var i = 1; i <= 7; i++) {
            lines = [...lines, cue('発話$i')];
            final shown = tracker.update(
              lines,
              Duration(seconds: i * 2),
            );
            expect(shown.map((c) => c.plainText).toList(), ['発話$i']);
          }

          // Two-line burst within <=900ms merges both lines.
          tracker.reset();
          expect(
            tracker
                .update([cue('1行目')], const Duration(milliseconds: 1000))
                .map((c) => c.plainText)
                .toList(),
            ['1行目'],
          );
          expect(
            tracker
                .update(
                  [cue('1行目'), cue('2行目')],
                  const Duration(milliseconds: 1400),
                )
                .map((c) => c.plainText)
                .toList(),
            ['1行目', '2行目'],
          );

          // Progressive prefix line and plain->ASS upgrade within <=900ms do not duplicate.
          tracker.reset();
          tracker.update([cue('バック')], const Duration(milliseconds: 1000));
          final expanded = tracker.update(
            [cue('バックヤード')],
            const Duration(milliseconds: 1300),
          );
          expect(expanded.map((c) => c.plainText).toList(), ['バックヤード']);

          tracker.reset();
          tracker.update([cue('おはよう')], const Duration(milliseconds: 1000));
          final upgraded = tracker.update(
            [cue('おはよう', y: 0.8)],
            const Duration(milliseconds: 1200),
          );
          expect(upgraded, hasLength(1));
          expect(upgraded.single.normalizedY, 0.8);

          // Frozen playback clock (paused) preserves subtitle; advancing past expiry clears it.
          final pausedCues = [cue('一時停止中の字幕')];
          final clearAt = computeSubtitleAutoClearDuration(pausedCues);
          expect(clearAt, const Duration(milliseconds: 5500));
          expect(
            tracker.update(pausedCues, const Duration(seconds: 20)),
            hasLength(1),
          );
          for (var i = 0; i < 5; i++) {
            expect(
              tracker.update(pausedCues, const Duration(seconds: 20)),
              hasLength(1),
            );
          }
          expect(
            tracker.update(
              pausedCues,
              const Duration(seconds: 20) + clearAt,
            ),
            isEmpty,
          );

          // Empty packet clears immediately.
          tracker.update([cue('即消去テスト')], const Duration(seconds: 30));
          expect(tracker.update(const [], const Duration(seconds: 31)), isEmpty);
        },
      );

      test(
        'SubtitleSettingsNotifier restores stored preferences, persists updates, and resets defaults',
        () async {
          final kv = InMemoryKeyValueStore();
          await kv.write(
            'firetv_subtitle_settings',
            const SubtitleSettings(
              size: SubtitleSizePreset.large,
              font: SubtitleFontFamily.kosugiMaru,
              edge: SubtitleEdgeStyle.none,
              backgroundColor: SubtitleBackgroundColorPreset.navy,
              backgroundOpacityPercent: 85,
            ).toJsonString(),
          );

          final container = ProviderContainer(
            overrides: [keyValueStoreProvider.overrideWithValue(kv)],
          );
          addTearDown(container.dispose);

          // Trigger provider build, then let microtask restore stored settings.
          container.read(subtitleSettingsProvider);
          await Future<void>.delayed(Duration.zero);
          final restored = container.read(subtitleSettingsProvider);
          expect(restored.size, SubtitleSizePreset.large);
          expect(restored.font, SubtitleFontFamily.kosugiMaru);
          expect(restored.edge, SubtitleEdgeStyle.none);
          expect(restored.backgroundColor, SubtitleBackgroundColorPreset.navy);
          expect(restored.backgroundOpacityPercent, 85);

          await container
              .read(subtitleSettingsProvider.notifier)
              .setFont(SubtitleFontFamily.lineSeedJp);
          final savedRaw = await kv.read('firetv_subtitle_settings');
          expect(
            SubtitleSettings.fromJsonString(savedRaw).font,
            SubtitleFontFamily.lineSeedJp,
          );

          await container.read(subtitleSettingsProvider.notifier).resetDefaults();
          expect(
            container.read(subtitleSettingsProvider),
            SubtitleSettings.defaults,
          );
        },
      );

      testWidgets(
        'SettingsScreen opens SubtitleSettingsScreen and SubtitleSettingsScreen edits & resets live settings',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final kv = InMemoryKeyValueStore();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                keyValueStoreProvider.overrideWithValue(kv),
                registrationStoreProvider.overrideWithValue(
                  InMemoryRegistrationStore(const []),
                ),
                debugLogSharerProvider.overrideWithValue(null),
                debugLogFolderOpenerProvider.overrideWithValue(null),
              ],
              child: const MaterialApp(home: SettingsScreen()),
            ),
          );
          await tester.pumpAndSettle();

          await tester.scrollUntilVisible(
            find.text('字幕表示設定'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(
            find.textContaining('中（標準）・太字ゴシック'),
            findsOneWidget,
          );

          await tester.tap(find.text('字幕表示設定'));
          await tester.pumpAndSettle();
          expect(find.byType(SubtitleSettingsScreen), findsOneWidget);
          expect(find.text('プレビュー (16:9)'), findsOneWidget);
          expect(
            tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
            closeTo(16 / 9, 0.001),
          );
          expect(
            find.textContaining('テレビ並みに見やすい字幕 →'),
            findsAtLeastNWidgets(1),
          );

          await tester.tap(find.text('LINE Seed JP'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('丸ゴシック'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('大'),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('大'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('縁取り（太め）'),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('縁取り（太め）'));
          await tester.pumpAndSettle();

          await tester.scrollUntilVisible(
            find.text('なし (0%)'),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('濃紺'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('なし (0%)'));
          await tester.pumpAndSettle();

          final edited = SubtitleSettings.fromJsonString(
            await kv.read('firetv_subtitle_settings'),
          );
          expect(edited.font, SubtitleFontFamily.kosugiMaru);
          expect(edited.size, SubtitleSizePreset.large);
          expect(edited.edge, SubtitleEdgeStyle.thick);
          expect(edited.backgroundColor, SubtitleBackgroundColorPreset.navy);
          expect(edited.backgroundOpacityPercent, 0);

          await tester.tap(find.text('初期設定に戻す'));
          await tester.pumpAndSettle();
          final reset = SubtitleSettings.fromJsonString(
            await kv.read('firetv_subtitle_settings'),
          );
          expect(reset, SubtitleSettings.defaults);
        },
      );

      testWidgets(
        'PlayerSubtitleOverlay positions ARIB cues cleanly without ragged TextStyle backgroundColor steps',
        (tester) async {
          Future<void> pumpOverlay(SubtitleSettings settings, List<SubtitleCue> cues) async {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 960,
                      height: 540,
                      child: PlayerSubtitleOverlay(
                        settings: settings,
                        cues: cues,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
          }

          const cues = [
            SubtitleCue(
              normalizedX: 0.14,
              normalizedY: 0.14,
              alignment: 7,
              spans: [SubtitleStyledSpan(text: '左上字幕')],
            ),
            SubtitleCue(
              normalizedX: 0.50,
              normalizedY: 0.88,
              alignment: 2,
              spans: [SubtitleStyledSpan(text: '下中央字幕')],
            ),
            SubtitleCue(
              normalizedX: 0.86,
              normalizedY: 0.50,
              alignment: 6,
              spans: [SubtitleStyledSpan(text: '右中央字幕')],
            ),
          ];

          // Default thin edge: 2 RichText layers per cue (stroke + fill), step-free StrutStyle.
          await pumpOverlay(SubtitleSettings.defaults, cues);
          final richWithEdge = tester.widgetList<RichText>(find.byType(RichText)).toList();
          expect(richWithEdge, hasLength(6));
          for (final rt in richWithEdge) {
            expect(rt.strutStyle?.forceStrutHeight, isTrue);
            rt.text.visitChildren((span) {
              if (span is TextSpan) {
                expect(span.style?.backgroundColor, isNull);
              }
              return true;
            });
          }

          final topLeftRect = tester.getRect(find.text('左上字幕').first);
          final bottomCenterRect = tester.getRect(find.text('下中央字幕').first);
          final midRightRect = tester.getRect(find.text('右中央字幕').first);
          expect(topLeftRect.top, lessThan(midRightRect.top));
          expect(midRightRect.top, lessThan(bottomCenterRect.top));
          expect(topLeftRect.left, lessThan(bottomCenterRect.center.dx));
          expect(midRightRect.right, greaterThan(bottomCenterRect.center.dx));

          // Zero edge & zero opacity omits stroke layer and background container.
          await pumpOverlay(
            const SubtitleSettings(
              edge: SubtitleEdgeStyle.none,
              backgroundOpacityPercent: 0,
            ),
            const [
              SubtitleCue(
                normalizedX: 0.50,
                normalizedY: 0.88,
                alignment: 2,
                spans: [SubtitleStyledSpan(text: '縁なし透明')],
              ),
            ],
          );
          expect(tester.widgetList<RichText>(find.byType(RichText)), hasLength(1));
          final containers = tester.widgetList<Container>(find.byType(Container));
          for (final c in containers) {
            final dec = c.decoration;
            if (dec is BoxDecoration) {
              expect(dec.color, isNot(Colors.black.withValues(alpha: 0.65)));
            }
          }

          // Multi-line subtitles use left alignment and per-line snug background pills.
          await pumpOverlay(
            const SubtitleSettings(
              edge: SubtitleEdgeStyle.none,
              backgroundOpacityPercent: 65,
            ),
            const [
              SubtitleCue(
                spans: [SubtitleStyledSpan(text: '長い1行目の字幕テストテキストです\n短い行')],
              ),
            ],
          );
          final richLines = tester.widgetList<RichText>(find.byType(RichText)).toList();
          expect(richLines, hasLength(2));
          for (final rt in richLines) {
            expect(rt.textAlign, TextAlign.left);
          }
          final linePills = tester
              .widgetList<Container>(find.byType(Container))
              .where((c) => c.decoration is BoxDecoration)
              .toList();
          expect(linePills, hasLength(2));
          final longPillRect = tester.getRect(find.byWidget(linePills[0]));
          final shortPillRect = tester.getRect(find.byWidget(linePills[1]));
          expect(longPillRect.width, greaterThan(shortPillRect.width + 80));
          expect((longPillRect.left - shortPillRect.left).abs(), lessThan(2.0));
        },
      );
    },
  );

  group(
    'Phase 27: ARIB TS position/clear tap, decoder reset guard, persisted toggle, unified live buffering, and rail focus handoff',
    () {
      Uint8List wrapTsPacket({
        required int pid,
        required bool pusi,
        required List<int> payload,
        int packetStride = 192,
      }) {
        final pkt = Uint8List(packetStride);
        final off = packetStride == 192 ? 4 : 0;
        pkt[off] = 0x47;
        pkt[off + 1] = ((pusi ? 0x40 : 0x00) | ((pid >> 8) & 0x1F));
        pkt[off + 2] = pid & 0xFF;
        pkt[off + 3] = 0x10;
        final copyLen = payload.length < 184 ? payload.length : 184;
        pkt.setRange(off + 4, off + 4 + copyLen, payload);
        for (var i = off + 4 + copyLen; i < off + 188; i++) {
          pkt[i] = 0xFF;
        }
        return pkt;
      }

      List<int> encodePts(double seconds) {
        final pts = (seconds * 90000.0).round();
        return [
          0x21 | (((pts >> 30) & 0x07) << 1),
          (pts >> 22) & 0xFF,
          0x01 | (((pts >> 15) & 0x7F) << 1),
          (pts >> 7) & 0xFF,
          0x01 | ((pts & 0x7F) << 1),
        ];
      }

      List<int> buildPat({required int pmtPid}) {
        return [
          0x00, // pointer_field
          0x00, // table_id
          0xB0, 0x0D, // section_length = 13
          0x00, 0x01, 0xC1, 0x00, 0x00,
          0x00, 0x01, 0xE0 | ((pmtPid >> 8) & 0x1F), pmtPid & 0xFF,
          0x00, 0x00, 0x00, 0x00, // dummy CRC
        ];
      }

      List<int> buildPmt({required int videoPid, required int captionPid}) {
        return [
          0x00, // pointer_field
          0x02, // table_id
          0xB0, 0x1E, // section_length = 30
          0x00, 0x01, 0xC1, 0x00, 0x00,
          0xE0 | ((videoPid >> 8) & 0x1F), videoPid & 0xFF,
          0xF0, 0x00, // program_info_length = 0
          // Video stream (0x02)
          0x02, 0xE0 | ((videoPid >> 8) & 0x1F), videoPid & 0xFF, 0xF0, 0x00,
          // ARIB caption stream (0x06) with 0x52(0x30) + 0xFD(0x0008)
          0x06, 0xE0 | ((captionPid >> 8) & 0x1F), captionPid & 0xFF, 0xF0, 0x07,
          0x52, 0x01, 0x30,
          0xFD, 0x02, 0x00, 0x08,
          0x00, 0x00, 0x00, 0x00, // dummy CRC
        ];
      }

      List<int> buildAribCaptionPesPayload({
        required double ptsSeconds,
        required List<int> statementBody,
        int dataGroupId = 1,
      }) {
        final unitLen = statementBody.length;
        final dataGroupHeader = [
          (dataGroupId & 0x3F) << 2, // data_group_id + version 0
          0x00, // link
          0x00, // last_link
          ((6 + 5 + unitLen) >> 8) & 0xFF,
          (6 + 5 + unitLen) & 0xFF,
          0x00, // TMD = 0
          (5 + unitLen) >> 16,
          ((5 + unitLen) >> 8) & 0xFF,
          (5 + unitLen) & 0xFF,
          0x1F, // unit_separator
          0x20, // statement body
          (unitLen >> 16) & 0xFF,
          (unitLen >> 8) & 0xFF,
          unitLen & 0xFF,
          ...statementBody,
        ];
        final aribPes = [0x80, 0xFF, 0x00, ...dataGroupHeader];
        final pesPacketLen = 8 + aribPes.length;
        return [
          0x00, 0x00, 0x01, 0xBD,
          (pesPacketLen >> 8) & 0xFF,
          pesPacketLen & 0xFF,
          0x80, 0x80, 0x05,
          ...encodePts(ptsSeconds),
          ...aribPes,
        ];
      }

      test(
        'AribTsCaptionTap extracts top/bottom station coordinates and clear timing from TTS and TS streams',
        () {
          List<int> asciiDigits(String s) => s.codeUnits;

          final bodyWithTwoPositionsAndTimedClear = <int>[
            0x0C, // CS
            // SWF 7 (960x540)
            0x9B, ...asciiDigits('7'), 0x20, 0x53,
            // ACPS(170;90) -> top telop-avoidance line
            0x9B, ...asciiDigits('170;90'), 0x61,
            0x30, 0x21, 0x30, 0x22, // 2 kanji
            // ACPS(220;460) -> bottom line
            0x9B, ...asciiDigits('220;460'), 0x61,
            0x30, 0x23, 0x30, 0x24, 0x30, 0x25, // 3 kanji
            // TIME wait 4.0s (0x40 + 40 = 0x68) then CS clear
            0x9D, 0x20, 0x68, 0x0C,
          ];

          for (final stride in [192, 188]) {
            final streamBytes = BytesBuilder()
              ..add(
                wrapTsPacket(
                  pid: 0x0000,
                  pusi: true,
                  payload: buildPat(pmtPid: 0x0100),
                  packetStride: stride,
                ),
              )
              ..add(
                wrapTsPacket(
                  pid: 0x0100,
                  pusi: true,
                  payload: buildPmt(videoPid: 0x0101, captionPid: 0x0130),
                  packetStride: stride,
                ),
              )
              ..add(
                wrapTsPacket(
                  pid: 0x0101,
                  pusi: true,
                  payload: [
                    0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05,
                    ...encodePts(100.0),
                  ],
                  packetStride: stride,
                ),
              )
              ..add(
                wrapTsPacket(
                  pid: 0x0130,
                  pusi: true,
                  payload: buildAribCaptionPesPayload(
                    ptsSeconds: 105.0,
                    statementBody: bodyWithTwoPositionsAndTimedClear,
                  ),
                  packetStride: stride,
                ),
              )
              ..add(
                wrapTsPacket(
                  pid: 0x0130,
                  pusi: true,
                  payload: buildAribCaptionPesPayload(
                    ptsSeconds: 110.0,
                    statementBody: const [0x0C], // Standalone clear
                  ),
                  packetStride: stride,
                ),
              );

            final raw = streamBytes.toBytes();
            final tap = AribTsCaptionTap();
            // Feed in arbitrary misaligned chunk splits across packet boundaries.
            tap.feed(Uint8List.sublistView(raw, 0, 111));
            tap.feed(Uint8List.sublistView(raw, 111, 417));
            tap.feed(Uint8List.sublistView(raw, 417));

            expect(tap.captionPid, 0x0130);
            expect(tap.firstStreamPtsSeconds, closeTo(100.0, 0.001));
            expect(tap.events, hasLength(2));

            final cueEv = tap.events[0];
            expect(cueEv.isClearOnly, isFalse);
            expect(cueEv.ptsSeconds, closeTo(105.0, 0.001));
            expect(cueEv.clearAfterSeconds, closeTo(4.0, 0.01));
            expect(cueEv.lines, hasLength(2));
            expect(cueEv.lines[0].normalizedX, closeTo(170 / 960.0, 0.01));
            expect(cueEv.lines[0].normalizedY, closeTo((90 - 18) / 540.0, 0.01));
            expect(cueEv.lines[1].normalizedX, closeTo(220 / 960.0, 0.01));
            expect(cueEv.lines[1].normalizedY, closeTo((460 - 18) / 540.0, 0.01));

            final clearEv = tap.events[1];
            expect(clearEv.isClearOnly, isTrue);
            expect(clearEv.lines, isEmpty);
            expect(clearEv.ptsSeconds, closeTo(110.0, 0.001));

            tap.resetFraming();
            expect(tap.events, hasLength(2));
            tap.resetAll();
            expect(tap.events, isEmpty);
            expect(tap.captionPid, isNull);

            // Verify CS + SDP + SS3 default macro (0x60) avoids phantom top-left glyphs
            // and secondary language data_group_id=2 (0x08) is ignored.
            final hardenedStream = BytesBuilder()
              ..add(
                wrapTsPacket(
                  pid: 0x0000,
                  pusi: true,
                  payload: buildPat(pmtPid: 0x0100),
                  packetStride: stride,
                ),
              )
              ..add(
                wrapTsPacket(
                  pid: 0x0100,
                  pusi: true,
                  payload: buildPmt(videoPid: 0x0101, captionPid: 0x0130),
                  packetStride: stride,
                ),
              )
              ..add(
                wrapTsPacket(
                  pid: 0x0130,
                  pusi: true,
                  payload: buildAribCaptionPesPayload(
                    ptsSeconds: 120.0,
                    dataGroupId: 2,
                    statementBody: const [0x0C, 0x30, 0x21, 0x30, 0x22],
                  ),
                  packetStride: stride,
                ),
              )
              ..add(
                wrapTsPacket(
                  pid: 0x0130,
                  pusi: true,
                  payload: buildAribCaptionPesPayload(
                    ptsSeconds: 121.0,
                    statementBody: [
                      0x0C, // CS
                      // SDP(170;390)
                      0x9B, ...asciiDigits('170;390'), 0x5F,
                      0x1D, 0x60, // SS3 + ARIB default macro 0x60 (zero-width)
                      0x30, 0x21, 0x30, 0x22, // 2 kanji
                    ],
                  ),
                  packetStride: stride,
                ),
              );
            tap.feed(hardenedStream.toBytes());
            expect(tap.events, hasLength(1));
            expect(tap.events.single.ptsSeconds, closeTo(121.0, 0.001));
            expect(tap.events.single.lines, hasLength(1));
            expect(
              tap.events.single.lines.single.normalizedX,
              closeTo(170 / 960.0, 0.01),
            );
            expect(
              tap.events.single.lines.single.normalizedY,
              closeTo((390 + 60 - 1 - 18) / 540.0, 0.01),
            );
          }
        },
      );

      test(
        'ARIB PTS matching, wraparound clear detection, decoder leak reset, and truncated ASS cleanup',
        () {
          const events = [
            AribCaptionLayoutEvent(
              ptsSeconds: 105.0,
              planeWidth: 960.0,
              planeHeight: 540.0,
              lines: [
                AribCaptionLinePlacement(
                  normalizedX: 0.18,
                  normalizedY: 0.13,
                  endNormalizedX: 0.50,
                  charCount: 8,
                ),
                AribCaptionLinePlacement(
                  normalizedX: 0.22,
                  normalizedY: 0.85,
                  endNormalizedX: 0.60,
                  charCount: 10,
                ),
              ],
              isClearOnly: false,
              clearAfterSeconds: 4.5,
            ),
            AribCaptionLayoutEvent(
              ptsSeconds: 110.0,
              planeWidth: 960.0,
              planeHeight: 540.0,
              lines: [],
              isClearOnly: true,
            ),
          ];

          final offset = resolveAribPtsOffset(
            events: events,
            mpvSubStartSeconds: 5.05,
            firstStreamPtsSeconds: 100.0,
          );
          expect(offset, closeTo(-100.0, 0.01));

          final matched = findMatchingAribLayoutEvent(
            events: events,
            mpvSubStartSeconds: 5.05,
            ptsOffset: offset!,
          );
          expect(matched, isNotNull);

          final applied = applyAribLayoutToCues(
            cues: const [
              SubtitleCue(spans: [SubtitleStyledSpan(text: '上行\n下行')]),
            ],
            layout: matched!,
          );
          expect(applied, hasLength(2));
          expect(applied[0].plainText, '上行');
          expect(applied[0].normalizedY, closeTo(0.13, 0.01));
          expect(applied[1].plainText, '下行');
          expect(applied[1].normalizedY, closeTo(0.85, 0.01));

          expect(
            hasAribClearSinceCaption(
              events: events,
              activeCaptionMpvPts: 5.05,
              currentPlaybackMpvPts: 8.5,
              ptsOffset: offset,
              activeClearAfterSeconds: 4.5,
            ),
            isFalse,
          );
          expect(
            hasAribClearSinceCaption(
              events: events,
              activeCaptionMpvPts: 5.05,
              currentPlaybackMpvPts: 10.1,
              ptsOffset: offset,
              activeClearAfterSeconds: null,
            ),
            isTrue,
          );
          // 90kHz 33-bit wraparound delta stays small across wrap boundary.
          expect(
            wrapAwareAribPtsDelta(1.0, AribTsCaptionTap.ptsWrapSeconds - 2.0),
            closeTo(3.0, 0.001),
          );

          // Decoder reset guard catches aribb24 i_control_time accumulation & 500-byte cliff.
          expect(
            shouldResetAribSubtitleDecoder(
              subStartSeconds: 10.0,
              subEndSeconds: 15.0,
              playbackTimeSeconds: 12.0,
              plainUtf8Bytes: 40,
              assUtf8Bytes: 80,
            ),
            isFalse,
          );
          expect(
            shouldResetAribSubtitleDecoder(
              subStartSeconds: 10.0,
              subEndSeconds: 2147483.0, // mpv UNKNOWN_DURATION
              playbackTimeSeconds: 12.0,
              plainUtf8Bytes: 40,
              assUtf8Bytes: 80,
            ),
            isFalse,
          );
          expect(
            shouldResetAribSubtitleDecoder(
              subStartSeconds: 10.0,
              subEndSeconds: 28.0, // leaked i_control_time = 18s
              playbackTimeSeconds: 12.0,
              plainUtf8Bytes: 40,
              assUtf8Bytes: 80,
            ),
            isTrue,
          );
          expect(
            shouldResetAribSubtitleDecoder(
              subStartSeconds: 10.0,
              subEndSeconds: 15.0,
              playbackTimeSeconds: 12.0,
              plainUtf8Bytes: 340,
              assUtf8Bytes: 390,
            ),
            isTrue,
          );
          expect(
            shouldResetAribSubtitleDecoder(
              subStartSeconds: 10.0,
              subEndSeconds: 15.0,
              playbackTimeSeconds: 26.0,
              plainUtf8Bytes: 40,
              assUtf8Bytes: 80,
            ),
            isTrue,
          );

          // Truncated ASS override tag tail from mpv's 500-byte cut is stripped cleanly.
          final truncatedAss = parseAribAssSubtitle(
            '{\\1c&H00ffff&}テスト文字{\\1c&H00ff',
          );
          expect(truncatedAss, hasLength(1));
          expect(truncatedAss.single.plainText, 'テスト文字');
          expect(truncatedAss.single.spans.single.color, const Color(0xFFFFFF00));
        },
      );

      test(
        'SubtitlesEnabledNotifier persists and restores firetv_subtitles_enabled',
        () async {
          final kv = InMemoryKeyValueStore();
          await kv.write('firetv_subtitles_enabled', 'true');

          final container = ProviderContainer(
            overrides: [keyValueStoreProvider.overrideWithValue(kv)],
          );
          addTearDown(container.dispose);

          container.read(subtitlesEnabledProvider);
          await Future<void>.delayed(Duration.zero);
          expect(container.read(subtitlesEnabledProvider), isTrue);

          await container.read(subtitlesEnabledProvider.notifier).set(false);
          expect(await kv.read('firetv_subtitles_enabled'), 'false');
        },
      );

      testWidgets(
        'SubtitleSettingsScreen edits persisted subtitle default toggle',
        (tester) async {
          final kv = InMemoryKeyValueStore();
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            ProviderScope(
              overrides: [keyValueStoreProvider.overrideWithValue(kv)],
              child: const MaterialApp(home: SubtitleSettingsScreen()),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('字幕表示（再生時の既定）'));
          await tester.pumpAndSettle();
          expect(await kv.read('firetv_subtitles_enabled'), 'true');
        },
      );

      test(
        'Live loading overlay stays unified with seconds + progress bar and prevents early latch',
        () {
          // Do not latch pre-buffering prematurely while target seconds remain unfilled.
          expect(
            shouldLatchInitialPlaybackStarted(
              hasVideoFrame: true,
              playingNow: true,
              buffering: false,
              preBufferTargetSeconds: 10,
              preBufferCurrentSeconds: 4.0,
            ),
            isFalse,
          );
          expect(
            shouldLatchInitialPlaybackStarted(
              hasVideoFrame: true,
              playingNow: true,
              buffering: false,
              preBufferTargetSeconds: 10,
              preBufferCurrentSeconds: 9.6,
            ),
            isTrue,
          );
          expect(
            shouldLatchInitialPlaybackStarted(
              hasVideoFrame: true,
              playingNow: true,
              buffering: true,
              positionAtFirstFrame: const Duration(seconds: 2),
              currentPosition: const Duration(seconds: 3),
              preBufferTargetSeconds: 10,
              preBufferCurrentSeconds: 2.0,
            ),
            isTrue,
          );

          final targetSpec = liveLoadingOverlaySpec(
            isLive: true,
            isPreBuffering: true,
            targetSeconds: 10,
            currentSeconds: 4,
            bufferingPercentage: 40,
            fallbackLabel: '読み込み中…',
          );
          expect(targetSpec.showProgressBar, isTrue);
          expect(targetSpec.progress, closeTo(0.4, 0.01));
          expect(targetSpec.caption, 'バッファ蓄積中… 4秒 / 10秒');

          final zeroTargetLiveSpec = liveLoadingOverlaySpec(
            isLive: true,
            isPreBuffering: false,
            targetSeconds: 0,
            currentSeconds: 2,
            bufferingPercentage: 55,
            fallbackLabel: 'バッファリング中…',
          );
          expect(zeroTargetLiveSpec.showProgressBar, isFalse);
          expect(zeroTargetLiveSpec.progress, isNull);
          expect(zeroTargetLiveSpec.caption, '読み込み中…');

          final rebufferingLiveSpec = liveLoadingOverlaySpec(
            isLive: true,
            isPreBuffering: false,
            targetSeconds: 10,
            currentSeconds: 3,
            bufferingPercentage: 55,
            fallbackLabel: 'バッファリング中…',
          );
          expect(rebufferingLiveSpec.showProgressBar, isTrue);
          expect(rebufferingLiveSpec.progress, closeTo(0.3, 0.01));
          expect(rebufferingLiveSpec.caption, 'バッファ蓄積中… 3秒 / 10秒');
        },
      );

      testWidgets(
        'AppShell NavigationRail selection automatically moves focus into right pane while keeping startup rail focus',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          const reg = RegisteredNasne(
            host: '192.0.2.10',
            udn: 'uuid:rail-handoff',
            friendlyName: 'nasne-1',
            macAddr: '00:11:22:33:44:55',
          );

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
                registrationStoreProvider.overrideWithValue(
                  InMemoryRegistrationStore(const [reg]),
                ),
                fireTvHelperProvider.overrideWithValue(
                  _FakeFireTvHelper(reachable: true),
                ),
                credentialSummaryProvider.overrideWith((ref) async => null),
                deviceInfoProvider.overrideWith(
                  (ref, r) async =>
                      const DeviceInfo(name: 'nasne-1', softwareVersion: '0260'),
                ),
                hddDetailsProvider.overrideWith(
                  (ref, r) async => const <HddDetail>[],
                ),
                liveStatusProvider.overrideWith(
                  (ref, r) async => const LiveStatus(sections: {}, raw: {}),
                ),
                recNgProvider.overrideWith((ref, r) async => const <RecNgItem>[]),
                debugLogSharerProvider.overrideWithValue(null),
                debugLogFolderOpenerProvider.overrideWithValue(null),
                titlesProvider(reg).overrideWith(
                  () => _FixedTitlesNotifier(reg, const []),
                ),
                titleCountsProvider.overrideWith(
                  (ref, r) async => const TitleCounts(0, 1000),
                ),
                liveChannelsProvider.overrideWith(
                  (ref, r) async => const <LiveBand>[],
                ),
                channelsProvider.overrideWith(
                  (ref, r) async => const <Channel>[],
                ),
                bsChannelsProvider.overrideWith(
                  (ref, r) async => const <Channel>[],
                ),
                schedulesProvider.overrideWith(
                  (ref, r) async => const <RecordSchedule>[],
                ),
              ],
              child: const MaterialApp(home: AppShell()),
            ),
          );
          await tester.pumpAndSettle();

          bool primaryInRail() {
            final ctx = FocusManager.instance.primaryFocus?.context;
            if (ctx == null) return false;
            return find
                .ancestor(
                  of: find.byWidget(ctx.widget),
                  matching: find.byType(NavigationRail),
                )
                .evaluate()
                .isNotEmpty;
          }

          // Initial app launch stays on NavigationRail 'ホーム'.
          expect(primaryInRail(), isTrue);

          // Selecting '設定' in NavigationRail switches tab and hands focus to right pane.
          await tester.tap(
            find.descendant(
              of: find.byType(NavigationRail),
              matching: find.text('設定'),
            ),
          );
          await tester.pumpAndSettle();
          expect(primaryInRail(), isFalse);
          expect(
            find.ancestor(
              of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
              matching: find.byType(SettingsScreen),
            ),
            findsOneWidget,
          );

          // Back returns to NavigationRail on '設定'.
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(primaryInRail(), isTrue);

          // Selecting 'ホーム' in NavigationRail enters Home right pane too.
          await tester.tap(
            find.descendant(
              of: find.byType(NavigationRail),
              matching: find.text('ホーム'),
            ),
          );
          await tester.pumpAndSettle();
          expect(primaryInRail(), isFalse);
        },
      );
    },
  );

  group(
    'Phase 28: ARIB color preservation, speaker separation, shadows, 16:9 proportional preview, and TV-style Live OSD',
    () {
      test(
        'SubtitleActiveWindowTracker upgrades white plain cues to colored ASS in place & findMatchingAribLayoutEvent avoids buffered future events',
        () {
          final tracker = SubtitleActiveWindowTracker();
          final initialWhite = tracker.update(
            const [
              SubtitleCue(
                spans: [SubtitleStyledSpan(text: 'ぜったいにわからない。')],
              ),
            ],
            Duration.zero,
            mpvSubStartSeconds: 10.0,
          );
          expect(initialWhite, hasLength(1));
          expect(initialWhite.single.spans.single.color, Colors.white);

          // Colored ASS arrives shortly after for identical key/text.
          final upgradedColored = tracker.update(
            const [
              SubtitleCue(
                spans: [
                  SubtitleStyledSpan(
                    text: 'ぜったいにわからない。',
                    color: Color(0xFFFFFF00),
                  ),
                ],
              ),
            ],
            const Duration(milliseconds: 50),
            mpvSubStartSeconds: 10.0,
          );
          expect(upgradedColored, hasLength(1));
          expect(
            upgradedColored.single.spans.single.color,
            const Color(0xFFFFFF00),
          );

          expect(
            subtitleTextMatchesAss(
              rawAss: r'{\1c&H80ffff&}あっ\Nそうだ。',
              plainLines: const ['あっそうだ。'],
            ),
            isTrue,
          );
          expect(
            subtitleTextMatchesAss(
              rawAss: r'{\1c&H80ffff&}全然別の字幕',
              plainLines: const ['ぜったいにわからない。'],
            ),
            isFalse,
          );

          final atomicColored = resolveRawSubtitleCues(
            rawAss: r'{\1c&H00ffff&}話者A「そろそろおやつ」',
            plainLines: const ['話者A そろそろおやつ'],
            atomicSnapshot: true,
          );
          expect(atomicColored, hasLength(1));
          expect(atomicColored.single.spans.single.color, const Color(0xFFFFFF00));

          const tsEvents = [
            AribCaptionLayoutEvent(
              ptsSeconds: 100.0,
              planeWidth: 960.0,
              planeHeight: 540.0,
              lines: [
                AribCaptionLinePlacement(
                  normalizedX: 0.14,
                  normalizedY: 0.14,
                  endNormalizedX: 0.50,
                  charCount: 6,
                ),
              ],
              isClearOnly: false,
            ),
            AribCaptionLayoutEvent(
              ptsSeconds: 101.1,
              planeWidth: 960.0,
              planeHeight: 540.0,
              lines: [
                AribCaptionLinePlacement(
                  normalizedX: 0.50,
                  normalizedY: 0.85,
                  endNormalizedX: 0.85,
                  charCount: 8,
                ),
              ],
              isClearOnly: false,
            ),
          ];
          final picked = findMatchingAribLayoutEvent(
            events: tsEvents,
            mpvSubStartSeconds: 0.15,
            ptsOffset: -100.0,
          );
          expect(picked, isNotNull);
          expect(picked!.ptsSeconds, closeTo(100.0, 0.001));
        },
      );

      testWidgets(
        'PlayerSubtitleOverlay separates horizontal speakers, applies dropShadow/thickShadow, and SubtitleSettingsScreen scales preview sizes in 16:9',
        (tester) async {
          tester.view.physicalSize = const Size(960, 540);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            const MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 960,
                  height: 540,
                  child: PlayerSubtitleOverlay(
                    settings: SubtitleSettings(edge: SubtitleEdgeStyle.dropShadow),
                    cues: [
                      SubtitleCue(
                        normalizedX: 0.12,
                        normalizedY: 0.72,
                        spans: [
                          SubtitleStyledSpan(
                            text: '左の話者',
                            color: Color(0xFF80FFFF),
                          ),
                        ],
                      ),
                      SubtitleCue(
                        normalizedX: 0.58,
                        normalizedY: 0.75,
                        spans: [
                          SubtitleStyledSpan(
                            text: '右の話者',
                            color: Color(0xFFFFFF00),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final leftDx = tester.getTopLeft(find.text('左の話者')).dx;
          final rightDx = tester.getTopLeft(find.text('右の話者')).dx;
          expect(leftDx, lessThan(220));
          expect(rightDx, greaterThan(480));

          TextStyle? firstStyledRun(InlineSpan span) {
            if (span is TextSpan) {
              if (span.text != null &&
                  span.text!.isNotEmpty &&
                  span.style != null) {
                return span.style;
              }
              for (final child in span.children ?? const <InlineSpan>[]) {
                final found = firstStyledRun(child);
                if (found != null) return found;
              }
            }
            return null;
          }

          final dropRichText = tester.widget<RichText>(
            find.descendant(
              of: find.byType(PlayerSubtitleOverlay),
              matching: find.byWidgetPredicate(
                (w) => w is RichText && w.text.toPlainText().contains('左の話者'),
              ),
            ),
          );
          final dropStyle = firstStyledRun(dropRichText.text)!;
          expect(dropStyle.shadows, hasLength(2));
          expect(dropStyle.shadows!.first.offset.dx, greaterThan(1.0));
          expect(dropStyle.shadows!.first.offset.dy, greaterThan(1.0));

          await tester.pumpWidget(
            const MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 960,
                  height: 540,
                  child: PlayerSubtitleOverlay(
                    settings: SubtitleSettings(
                      edge: SubtitleEdgeStyle.thickShadow,
                    ),
                    cues: [
                      SubtitleCue(
                        spans: [SubtitleStyledSpan(text: 'ズレなし厚影')],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final haloRichText = tester.widget<RichText>(
            find.descendant(
              of: find.byType(PlayerSubtitleOverlay),
              matching: find.byType(RichText),
            ),
          );
          final haloStyle = firstStyledRun(haloRichText.text)!;
          expect(haloStyle.shadows, hasLength(3));
          expect(haloStyle.shadows!.every((s) => s.offset == Offset.zero), isTrue);

          // Verify 16:9 preview strictly scales rendered font sizes across 小 / 中 / 大.
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1.0;

          final kv = InMemoryKeyValueStore();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [keyValueStoreProvider.overrideWithValue(kv)],
              child: const MaterialApp(home: SubtitleSettingsScreen()),
            ),
          );
          await tester.pumpAndSettle();

          double readPreviewSampleFontSize() {
            final rt = tester.widgetList<RichText>(
              find.descendant(
                of: find.byType(PlayerSubtitleOverlay),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is RichText &&
                      w.text.toPlainText().contains('テレビ並みに見やすい字幕'),
                ),
              ),
            ).last;
            return firstStyledRun(rt.text)!.fontSize!;
          }

          final mediumSize = readPreviewSampleFontSize();
          await tester.tap(find.text('小'));
          await tester.pumpAndSettle();
          final smallSize = readPreviewSampleFontSize();
          await tester.tap(find.text('大'));
          await tester.pumpAndSettle();
          final largeSize = readPreviewSampleFontSize();

          expect(smallSize, lessThan(mediumSize));
          expect(mediumSize, lessThan(largeSize));
        },
      );

      testWidgets(
        'resolveLiveOsdProgramInfo, LiveOsdProgramSection, and PlayerOsdClockOverlay render TV-style live programme progress and clock',
        (tester) async {
          DateTime jst(int h, int m) => DateTime.utc(2026, 11, 24, h, m).subtract(
            const Duration(hours: 9),
          );

          final channel = LiveChannel(
            id: '0/video/LiveTuner/DTTB/ch?nid=7880&tsid=7880&svid=de00',
            bandId: '0/video/LiveTuner/DTTB',
            serviceId: 0xde00,
            channelName: 'ＮＨＫＥテレ',
            programTitle: '古い番組情報',
            programStart: jst(15, 30),
            programEnd: jst(16, 0),
          );
          final events = [
            EpgEvent(
              eventId: 101,
              start: jst(16, 0),
              duration: const Duration(minutes: 30),
              title: 'サイエンスZERO',
            ),
            EpgEvent(
              eventId: 102,
              start: jst(16, 30),
              duration: const Duration(minutes: 30),
              title: '次のテレビ番組',
            ),
          ];

          final at1620 = resolveLiveOsdProgramInfo(
            channel: channel,
            guideEvents: events,
            now: jst(16, 20),
          );
          expect(at1620.currentTitle, 'サイエンスZERO');
          expect(at1620.currentTimeRange, '16:00–16:30');
          expect(at1620.progress, closeTo(2 / 3, 0.01));
          expect(at1620.remainingMinutes, 10);
          expect(at1620.nextTitle, '次のテレビ番組');
          expect(at1620.nextTimeRange, '16:30–17:00');

          final rolled = resolveLiveOsdProgramInfo(
            channel: channel,
            guideEvents: events,
            now: jst(16, 31),
          );
          expect(rolled.currentTitle, '次のテレビ番組');
          expect(rolled.nextTitle, isNull);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                backgroundColor: Colors.black,
                body: SizedBox(
                  width: 960,
                  height: 540,
                  child: Stack(
                    children: [
                      PlayerOsdClockOverlay(now: jst(16, 20)),
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: 24,
                        child: LiveOsdProgramSection(info: at1620),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.text('16:20'), findsOneWidget);
          expect(find.text('サイエンスZERO'), findsOneWidget);
          expect(find.text('16:00–16:30（残り 10分）'), findsOneWidget);
          expect(find.text('次'), findsOneWidget);
          expect(find.text('16:30–17:00'), findsOneWidget);
          expect(find.text('次のテレビ番組'), findsOneWidget);
        },
      );
    },
  );
}

class _DeletableScheduleService implements ScheduleService {
  _DeletableScheduleService({required this.onDelete});
  final void Function(String id) onDelete;

  @override
  Future<void> deleteSchedule(String id) async {
    onDelete(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProtectTitleCatalog implements TitleCatalogService {
  _FakeProtectTitleCatalog({required this.onProtect});
  final void Function(bool protect) onProtect;

  @override
  Future<void> setTitleProtection(
    RecordedTitle title, {
    required bool protect,
  }) async {
    onProtect(protect);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedLiveCatalog implements LiveCatalogService {
  _FixedLiveCatalog(this._bands);
  final List<LiveBand> _bands;

  @override
  Future<List<LiveBand>> listLiveChannels() async => _bands;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingScheduleService implements ScheduleService {
  _RecordingScheduleService({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Future<List<RecordSchedule>> listSchedules({
    int startingIndex = 0,
    int requestedCount = 50,
  }) async => const [];

  @override
  Future<List<RecordSchedule>> checkConflicts(
    NewRecordSchedule candidate,
  ) async => const [];

  @override
  Future<String> createSchedule(NewRecordSchedule candidate) async {
    onCreate();
    return 'new-1';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeferredRegistrationStore implements RegistrationStore {
  _DeferredRegistrationStore(this._completer);
  final Completer<List<RegisteredNasne>> _completer;
  final Map<String, RegisteredNasne> _byHost = {};

  @override
  Future<List<RegisteredNasne>> loadAll() =>
      _byHost.isNotEmpty ? Future.value([..._byHost.values]) : _completer.future;

  @override
  Future<void> save(RegisteredNasne device) async {
    _byHost[device.host] = device;
  }

  @override
  Future<void> remove(String host) async {
    _byHost.remove(host);
  }
}

class _FixedScheduleService implements ScheduleService {
  _FixedScheduleService(this._items);
  final List<RecordSchedule> _items;

  @override
  Future<List<RecordSchedule>> listSchedules({
    int startingIndex = 0,
    int requestedCount = 50,
  }) async => _items;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingFallbackLiveEngine implements PlaybackEngine {
  final List<String> attempts = [];

  @override
  bool get isSupported => true;

  @override
  Future<PlaybackSession> startLivePlayback(
    LiveChannel channel,
    TitleRes res,
  ) async {
    final tag = '${channel.id.split('/').last}:${res.quality}';
    attempts.add(tag);
    if (res.quality == 'mobile') {
      throw NasneError.http(503, 'test:encoder-busy');
    }
    throw NasneError.validation('test:stop-before-mpv', 'テスト停止');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubDeviceInfo implements DeviceInfoService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSettings implements SettingsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubTitleCatalog implements TitleCatalogService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubMetadata implements MetadataService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubLiveCatalog implements LiveCatalogService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedTitlesNotifier extends TitlesNotifier {
  _FixedTitlesNotifier(super.reg, this._items);
  final List<RecordedTitle> _items;

  @override
  Stream<TitleListProgress> build() =>
      Stream.value(TitleListProgress(_items, complete: true));
}

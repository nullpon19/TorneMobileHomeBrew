/// Tests for Fire TV provisional modifications:
/// - DtcpCredentialScreen 2-column inputs, top action buttons, in-app picker
/// - TitleDetailView 1/4 thumbnail + 3/4 title header, top play button, omitted long info
/// - TailscaleGuard startup volume max & VPN/Tailscale prompt
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/bs_epg_providers.dart';
import 'package:tmhb/app/firetv_helper.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/main.dart';
import 'package:tmhb/ui/app_shell.dart';
import 'package:tmhb/ui/dtcp_credential_screen.dart';
import 'package:tmhb/ui/epg_screen.dart';
import 'package:tmhb/ui/home_screen.dart';
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
      'EpgScreen renders red border on reserved tile and opens edit button instead of reserve',
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

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              registrationStoreProvider.overrideWithValue(
                InMemoryRegistrationStore(const [reg]),
              ),
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
}

class _FixedTitlesNotifier extends TitlesNotifier {
  _FixedTitlesNotifier(super.reg, this._items);
  final List<RecordedTitle> _items;

  @override
  Stream<TitleListProgress> build() =>
      Stream.value(TitleListProgress(_items, complete: true));
}

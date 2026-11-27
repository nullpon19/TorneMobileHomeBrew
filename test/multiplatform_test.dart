import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/arib_sound.dart';
import 'package:tmhb/app/desktop_window.dart';
import 'package:tmhb/app/firetv_helper.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/app/ui_control_mode.dart';
import 'package:tmhb/core/arib_chime_wav.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/channel_badge.dart';
import 'package:tmhb/ui/epg_screen.dart';
import 'package:tmhb/ui/live_channel_switch_policy.dart';
import 'package:tmhb/ui/player_multiplatform_controls.dart';
import 'package:tmhb/ui/player_screen.dart';
import 'package:tmhb/ui/settings_screen.dart';
import 'package:tmhb/ui/widgets.dart';

class _FakeFireTvSoundHelper extends FireTvHelper {
  _FakeFireTvSoundHelper() : super(isAndroidOverride: true, isTvOverride: true);

  final List<({int soundId, bool urgent})> calls = [];

  @override
  Future<bool> playAribBuiltinSound(int soundId, {bool urgent = false}) async {
    calls.add((soundId: soundId, urgent: urgent));
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UiControlMode resolution', () {
    test('auto mode resolves Android TV vs phone vs iOS vs desktop', () {
      expect(
        resolveUiControlMode(
          preference: UiControlModePreference.auto,
          isAndroid: true,
          isAndroidTv: true,
          isIOS: false,
          isDesktop: false,
        ),
        UiControlMode.tv,
      );
      expect(
        resolveUiControlMode(
          preference: UiControlModePreference.auto,
          isAndroid: true,
          isAndroidTv: false,
          isIOS: false,
          isDesktop: false,
        ),
        UiControlMode.touch,
      );
      expect(
        resolveUiControlMode(
          preference: UiControlModePreference.auto,
          isAndroid: false,
          isAndroidTv: false,
          isIOS: true,
          isDesktop: false,
        ),
        UiControlMode.touch,
      );
      expect(
        resolveUiControlMode(
          preference: UiControlModePreference.auto,
          isAndroid: false,
          isAndroidTv: false,
          isIOS: false,
          isDesktop: true,
        ),
        UiControlMode.desktop,
      );
    });

    test('manual preference overrides platform default', () {
      expect(
        resolveUiControlMode(
          preference: UiControlModePreference.desktop,
          isAndroid: false,
          isAndroidTv: false,
          isIOS: true,
          isDesktop: false,
        ),
        UiControlMode.desktop,
      );
      expect(
        resolveUiControlMode(
          preference: UiControlModePreference.touch,
          isAndroid: true,
          isAndroidTv: true,
          isIOS: false,
          isDesktop: false,
        ),
        UiControlMode.touch,
      );
    });
  });

  group('ARIB chime WAV synthesis & native channels', () {
    test('synthesizeAribBuiltinSoundWav generates valid non-silent PCM WAV', () {
      for (final testCase in const [
        (id: 4, urgent: true, minBytes: 400000),
        (id: 0, urgent: false, minBytes: 150000),
        (id: 13, urgent: false, minBytes: 60000),
        (id: 99, urgent: false, minBytes: 10000),
      ]) {
        final wav = synthesizeAribBuiltinSoundWav(
          testCase.id,
          urgent: testCase.urgent,
        );
        expect(wav.length, greaterThan(testCase.minBytes));
        expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
        expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
        expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
        final bd = ByteData.sublistView(wav);
        expect(bd.getUint16(20, Endian.little), 1); // PCM
        expect(bd.getUint16(22, Endian.little), 1); // Mono
        expect(bd.getUint32(24, Endian.little), 44100);
        expect(bd.getUint16(34, Endian.little), 16);
        final payload = wav.sublist(44);
        expect(payload.any((b) => b != 0), isTrue);
      }
    });

    test('AribSoundPlayer routes Android vs iOS/macOS/Windows channels', () async {
      final androidHelper = _FakeFireTvSoundHelper();
      final androidPlayer = AribSoundPlayer(fireTvHelper: androidHelper);
      expect(await androidPlayer.playAribBuiltinSound(4, urgent: true), isTrue);
      expect(androidHelper.calls, [(soundId: 4, urgent: true)]);

      const channel = MethodChannel('test/arib_sound');
      final recordedCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            recordedCalls.add(call);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final desktopPlayer = AribSoundPlayer(
        fireTvHelper: FireTvHelper(isAndroidOverride: false),
        channel: channel,
        isAndroidOverride: false,
        isNativeWavSupportedOverride: true,
      );
      expect(await desktopPlayer.playAribBuiltinSound(0), isTrue);
      expect(recordedCalls, hasLength(1));
      expect(recordedCalls.single.method, 'playWav');
      final args = Map<Object?, Object?>.from(
        recordedCalls.single.arguments as Map,
      );
      expect(args['wav'], isA<Uint8List>());
    });

    test('DesktopWindowController toggles fullscreen via MethodChannel', () async {
      const channel = MethodChannel('test/window_control');
      var fullscreen = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'isFullscreen':
                return fullscreen;
              case 'toggleFullscreen':
                fullscreen = !fullscreen;
                return fullscreen;
              case 'setFullscreen':
                final args = Map<Object?, Object?>.from(call.arguments as Map);
                fullscreen = args['fullscreen'] == true;
                return fullscreen;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final desktop = DesktopWindowController(
        channel: channel,
        isDesktopOverride: true,
      );
      expect(await desktop.isFullscreen(), isFalse);
      expect(await desktop.toggleFullscreen(), isTrue);
      expect(await desktop.setFullscreen(false), isFalse);

      final mobile = DesktopWindowController(
        channel: channel,
        isDesktopOverride: false,
      );
      expect(await mobile.toggleFullscreen(), isFalse);
    });
  });

  group('Providers persistence', () {
    test('playerVolumeProvider & playerMutedProvider persist and restore', () async {
      final kv = InMemoryKeyValueStore();
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);

      expect(container.read(playerVolumeProvider), 100.0);
      expect(container.read(playerMutedProvider), isFalse);

      await container.read(playerVolumeProvider.notifier).set(42.5);
      await container.read(playerMutedProvider.notifier).set(true);
      expect(await kv.read('player_volume'), '42.5');
      expect(await kv.read('player_muted'), 'true');

      final restored = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(restored.dispose);
      restored.read(playerVolumeProvider);
      restored.read(playerMutedProvider);
      await Future<void>.delayed(Duration.zero);
      expect(restored.read(playerVolumeProvider), 42.5);
      expect(restored.read(playerMutedProvider), isTrue);
    });
  });

  group('Touch & PC input/settings UI', () {
    testWidgets(
      'FireTvTextInputField uses dialog on TV and inline TextField on touch/desktop',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              defaultTargetUiControlModeProvider.overrideWithValue(
                UiControlMode.tv,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: FireTvTextInputField(
                  controller: controller,
                  labelText: 'テスト入力',
                ),
              ),
            ),
          ),
        );
        expect(find.byType(TextField), findsNothing);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              defaultTargetUiControlModeProvider.overrideWithValue(
                UiControlMode.desktop,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: FireTvTextInputField(
                  controller: controller,
                  labelText: 'テスト入力',
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), '192.168.1.50');
        expect(controller.text, '192.168.1.50');
      },
    );

    testWidgets('SettingsScreen persists UI control mode preference', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 960);
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
        find.textContaining('操作モード'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('PC'));
      await tester.pumpAndSettle();
      expect(await kv.read('ui_control_mode_preference'), 'desktop');

      await tester.tap(find.text('タッチ'));
      await tester.pumpAndSettle();
      expect(await kv.read('ui_control_mode_preference'), 'touch');
    });
  });

  group('Multiplatform player controls & scrubbing math', () {
    test('scrubFractionToDuration clamps and maps fraction linearly', () {
      expect(
        scrubFractionToDuration(0.5, const Duration(minutes: 30)),
        const Duration(minutes: 15),
      );
      expect(
        scrubFractionToDuration(-0.2, const Duration(minutes: 30)),
        Duration.zero,
      );
      expect(
        scrubFractionToDuration(1.5, const Duration(minutes: 30)),
        const Duration(minutes: 30),
      );
    });

    test('resolveLiveTimeshiftTargetSeconds maps timeline and fallback', () {
      final start = DateTime.utc(2026, 11, 25, 12, 0);
      final end = DateTime.utc(2026, 11, 25, 13, 0);
      final target = resolveLiveTimeshiftTargetSeconds(
        fraction: 0.45,
        liveEdgeFraction: 0.5,
        playableStartFraction: 0.4,
        usesProgramTimeline: true,
        programStart: start,
        programEnd: end,
        cacheStartSeconds: 100.0,
        cacheEndSeconds: 460.0,
      );
      expect(target, closeTo(280.0, 0.5));

      final fallback = resolveLiveTimeshiftTargetSeconds(
        fraction: 0.5,
        liveEdgeFraction: 1.0,
        playableStartFraction: 0.0,
        usesProgramTimeline: false,
        cacheStartSeconds: 200.0,
        cacheEndSeconds: 300.0,
      );
      expect(fallback, closeTo(250.0, 0.5));
    });

    test('resolveTouchHorizontalSwipeDirection resolves edge swipes', () {
      expect(
        resolveTouchHorizontalSwipeDirection(
          dragDeltaX: 60.0,
          startX: 30.0,
          viewportWidth: 800.0,
        ),
        ChannelSwitchDirection.previous,
      );
      expect(
        resolveTouchHorizontalSwipeDirection(
          dragDeltaX: -60.0,
          startX: 760.0,
          viewportWidth: 800.0,
        ),
        ChannelSwitchDirection.next,
      );
      expect(
        resolveTouchHorizontalSwipeDirection(
          dragDeltaX: 10.0,
          startX: 30.0,
          viewportWidth: 800.0,
        ),
        isNull,
      );
    });

    testWidgets(
      'PlayerCenterTransportOverlay & PlayerVolumeControl invoke callbacks',
      (tester) async {
        var rewound = 0;
        var toggled = 0;
        var forwarded = 0;
        var muted = false;
        double latestVol = 80.0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: Column(
                children: [
                  Expanded(
                    child: PlayerCenterTransportOverlay(
                      visible: true,
                      isPlaying: true,
                      canSeekBackward: true,
                      canSeekForward: true,
                      onRewind: () => rewound++,
                      onTogglePlayPause: () => toggled++,
                      onForward: () => forwarded++,
                    ),
                  ),
                  PlayerVolumeControl(
                    volume: latestVol,
                    muted: muted,
                    onToggleMute: () => muted = !muted,
                    onVolumeChanged: (v) => latestVol = v,
                  ),
                ],
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('player_center_rewind')));
        await tester.tap(
          find.byKey(const ValueKey('player_center_play_pause')),
        );
        await tester.tap(find.byKey(const ValueKey('player_center_forward')));
        await tester.tap(find.byKey(const ValueKey('player_mute_button')));
        await tester.pump();

        expect(rewound, 1);
        expect(toggled, 1);
        expect(forwarded, 1);
        expect(muted, isTrue);
      },
    );

    testWidgets(
      'LiveChannelSwitchPreviewCard supports peeking edge tap vs full tap',
      (tester) async {
        const reg = RegisteredNasne(
          host: '192.0.2.1',
          udn: 'uuid:test',
          friendlyName: 'nasne',
          macAddr: '00:11:22:33:44:55',
        );
        const entry = LiveChannelSwitchEntry(
          channel: LiveChannel(
            id: '0/video/LiveTuner/DTTB/ch?nid=1&tsid=1&svid=101',
            bandId: 'DTTB',
            networkId: 1,
            transportStreamId: 1,
            serviceId: 101,
            channelName: 'NHK総合',
            programTitle: 'ニュース',
          ),
          primaryReg: reg,
        );
        var peekTapped = 0;
        var fullTapped = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  LiveChannelSwitchPreviewCard(
                    direction: ChannelSwitchDirection.next,
                    visible: false,
                    peeking: true,
                    entry: entry,
                    onPeekTap: () => peekTapped++,
                    onTap: () => fullTapped++,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final slide = tester.widget<AnimatedSlide>(find.byType(AnimatedSlide));
        expect(slide.offset, const Offset(0.84, 0));

        final cardFinder = find.byKey(
          const ValueKey('live_channel_preview_next'),
        );
        final cardRect = tester.getRect(cardFinder);
        // AnimatedSlide shifts the peeking card to the right edge of the 800px
        // test viewport; tap the visible left edge inside [0, 800].
        await tester.tapAt(
          Offset(
            (cardRect.left + 12).clamp(0.0, 795.0),
            cardRect.center.dy,
          ),
        );
        await tester.pump();
        expect(peekTapped, 1, reason: 'cardRect=$cardRect');
        expect(fullTapped, 0);
      },
    );

    testWidgets('DesktopChannelEdgeZones triggers click callbacks', (
      tester,
    ) async {
      ChannelSwitchDirection? clicked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                DesktopChannelEdgeZones(
                  enabled: true,
                  hasPrevious: true,
                  hasNext: true,
                  onHoverDirection: (_) {},
                  onClickDirection: (dir) => clicked = dir,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('desktop_edge_previous')));
      expect(clicked, ChannelSwitchDirection.previous);
      await tester.tap(find.byKey(const ValueKey('desktop_edge_next')));
      expect(clicked, ChannelSwitchDirection.next);
    });

    testWidgets('LiveProgramProgressBar scrubs interactively when enabled', (
      tester,
    ) async {
      double? scrubbedEnd;
      const state = LiveTimeshiftBarState(
        liveEdgeFraction: 0.8,
        playableStartFraction: 0.2,
        playbackFraction: 0.8,
        rewindableSeconds: 180,
        lagSeconds: 0,
        isTimeshifting: true,
        usesProgramTimeline: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: SizedBox(
                width: 400,
                child: LiveProgramProgressBar(
                  state: state,
                  interactive: true,
                  onScrubFractionEnd: (f) => scrubbedEnd = f,
                ),
              ),
            ),
          ),
        ),
      );

      final barRect = tester.getRect(find.byType(LiveProgramProgressBar));
      await tester.tapAt(Offset(barRect.left + 200, barRect.center.dy));
      await tester.pump();
      expect(scrubbedEnd, isNotNull);
      expect(scrubbedEnd!, closeTo(0.5, 0.05));
    });
  });

  group('Device-specific wording & hover behavior', () {
    test('sanitizeNonTvInputHint removes remote-only phrasing', () {
      expect(
        sanitizeNonTvInputHint('決定キーで入力（内容を貼り付け）'),
        '内容を貼り付け',
      );
      expect(sanitizeNonTvInputHint('決定キーで入力'), '入力');
      expect(sanitizeNonTvInputHint('例: 192.168.1.10'), '例: 192.168.1.10');
      expect(sanitizeNonTvInputHint(null), isNull);
    });

    testWidgets(
      'LiveChannelSwitchPreviewCard renders mode-specific hints and hover callbacks',
      (tester) async {
        const reg = RegisteredNasne(
          host: '192.0.2.1',
          udn: 'uuid:test',
          friendlyName: 'nasne',
          macAddr: '00:11:22:33:44:55',
        );
        const entry = LiveChannelSwitchEntry(
          channel: LiveChannel(
            id: '0/video/LiveTuner/DTTB/ch?nid=1&tsid=1&svid=101',
            bandId: 'DTTB',
            networkId: 1,
            transportStreamId: 1,
            serviceId: 101,
            channelName: 'NHK総合',
            programTitle: 'ニュース',
          ),
          primaryReg: reg,
        );

        var entered = 0;
        var exited = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  LiveChannelSwitchPreviewCard(
                    direction: ChannelSwitchDirection.next,
                    visible: true,
                    uiMode: UiControlMode.desktop,
                    entry: entry,
                    onHoverEnter: () => entered++,
                    onHoverExit: () => exited++,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('クリックで切替'), findsOneWidget);

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await tester.pump();
        final cardCenter = tester.getCenter(
          find.byKey(const ValueKey('live_channel_preview_next')),
        );
        await gesture.moveTo(cardCenter);
        await tester.pump();
        expect(entered, 1);
        await gesture.moveTo(const Offset(10, 10));
        await tester.pump();
        expect(exited, 1);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  LiveChannelSwitchPreviewCard(
                    direction: ChannelSwitchDirection.next,
                    visible: true,
                    uiMode: UiControlMode.touch,
                    entry: entry,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('タップまたはもう一度スワイプで切替'), findsOneWidget);
      },
    );

    testWidgets(
      'ProgramDetailOverlayPanel renders mode-specific scroll/close hint',
      (tester) async {
        final scrollCtrl = ScrollController();
        final focusNode = FocusNode();
        addTearDown(() {
          scrollCtrl.dispose();
          focusNode.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProgramDetailOverlayPanel(
                title: '番組タイトル',
                body: '本文テスト',
                scrollController: scrollCtrl,
                focusNode: focusNode,
                uiMode: UiControlMode.desktop,
                onClose: () {},
                onScrollDelta: (_) {},
              ),
            ),
          ),
        );
        expect(find.text('ホイールでスクロール ／ Escで閉じる'), findsOneWidget);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProgramDetailOverlayPanel(
                title: '番組タイトル',
                body: '本文テスト',
                scrollController: scrollCtrl,
                focusNode: focusNode,
                uiMode: UiControlMode.touch,
                onClose: () {},
                onScrollDelta: (_) {},
              ),
            ),
          ),
        );
        expect(find.text('スワイプでスクロール'), findsOneWidget);
      },
    );

    testWidgets('EpgScreen hides remote-only top-jump hint in non-TV mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
        friendlyName: 'nasne',
        macAddr: '00:11:22:33:44:55',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            defaultTargetUiControlModeProvider.overrideWithValue(
              UiControlMode.desktop,
            ),
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [reg]),
            ),
            epgGuideProvider.overrideWith(
              (ref, r) async =>
                  const EpgGuide(broadcastingType: 2, services: []),
            ),
            channelLogosProvider.overrideWith(
              (ref, r) async => const <int, List<int>>{},
            ),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('番組表'), findsOneWidget);
      expect(find.text('戻る / メニューで上部へ'), findsNothing);
    });
  });

  group('Touch responsive & recorded metadata fixes', () {
    test('computeTouchLandscapeHorizontalInset respects 16:9 and safe padding', () {
      // Wide notched 21:9-ish phone (915x412, safe left 48, right 48):
      // 16:9 width for h=412 is ~732.4 -> letterbox side ~91.3 > 48
      final inset21by9 = computeTouchLandscapeHorizontalInset(
        viewportSize: const Size(915, 412),
        safePadding: const EdgeInsets.only(left: 48, right: 48),
      );
      expect(inset21by9, closeTo((915 - 412 * 16 / 9) / 2, 0.2));

      // Standard notched phone (852x393, safe left 59, right 0):
      // letterbox side ~76.7 > safe 59 -> symmetric 76.7 on both sides
      final insetNotch = computeTouchLandscapeHorizontalInset(
        viewportSize: const Size(852, 393),
        safePadding: const EdgeInsets.only(left: 59),
      );
      expect(insetNotch, closeTo((852 - 393 * 16 / 9) / 2, 0.2));

      // 16:9-exact panel with safe inset (e.g., 800x450, safe right 44):
      final insetSafeOnly = computeTouchLandscapeHorizontalInset(
        viewportSize: const Size(800, 450),
        safePadding: const EdgeInsets.only(right: 44),
      );
      expect(insetSafeOnly, 44.0);
    });

    test('resolveTouchChannelSwipeAction handles 2-step swipe transitions', () {
      expect(
        resolveTouchChannelSwipeAction(
          swipeDirection: ChannelSwitchDirection.next,
          currentPreviewDirection: null,
        ),
        TouchChannelSwipeAction.showPreview,
      );
      expect(
        resolveTouchChannelSwipeAction(
          swipeDirection: ChannelSwitchDirection.next,
          currentPreviewDirection: ChannelSwitchDirection.next,
        ),
        TouchChannelSwipeAction.switchChannel,
      );
      expect(
        resolveTouchChannelSwipeAction(
          swipeDirection: ChannelSwitchDirection.previous,
          currentPreviewDirection: ChannelSwitchDirection.next,
        ),
        TouchChannelSwipeAction.dismissPreview,
      );
      // Center-origin swipe is also accepted.
      expect(
        resolveTouchHorizontalSwipeDirection(
          dragDeltaX: -55,
          startX: 400,
          viewportWidth: 800,
        ),
        ChannelSwitchDirection.next,
      );
    });

    test('resolveRecordedChannelNumberLabel and logo resolve by id and name', () {
      const channels = [
        Channel(
          networkId: 32736,
          transportStreamId: 32736,
          serviceId: 1024,
          serviceType: 1,
          broadcastingType: 2,
          channelNumber: 11,
          serviceName: 'ＮＨＫ総合１・東京',
        ),
        Channel(
          networkId: 4,
          transportStreamId: 16625,
          serviceId: 101,
          serviceType: 1,
          broadcastingType: 3,
          channelNumber: 101,
          serviceName: 'ＮＨＫ　ＢＳ',
        ),
      ];
      final fakeLogo = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ]);
      final logos = <int, List<int>>{1024: fakeLogo, 101: fakeLogo};

      expect(
        resolveRecordedChannelNumberLabel(
          serviceId: 1024,
          channelName: 'NHK総合1',
          channels: channels,
        ),
        '011',
      );
      expect(
        resolveRecordedChannelNumberLabel(
          serviceId: null,
          channelName: 'ＮＨＫ ＢＳ',
          channels: channels,
        ),
        '101',
      );
      expect(
        resolveRecordedChannelLogoBytes(
          serviceId: null,
          channelName: 'ＮＨＫ総合１・東京',
          channels: channels,
          logos: logos,
        ),
        isNotNull,
      );
    });

    testWidgets(
      'Compact-width LiveOsdProgramSection and RecordedOsdProgramSection wrap without overflow',
      (tester) async {
        final liveInfo = LiveOsdProgramInfo(
          currentTitle: 'とても長い番組タイトルが狭いスマホ画面でも省略されすぎずに複数行で読めるテスト',
          currentStart: DateTime.utc(2026, 11, 25, 23, 15),
          currentEnd: DateTime.utc(2026, 11, 26, 0, 55),
          remainingMinutes: 37,
          progress: 0.6,
          nextTitle: '次の番組タイトル',
          nextStart: DateTime.utc(2026, 11, 26, 0, 55),
          nextEnd: DateTime.utc(2026, 11, 26, 1, 0),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: SizedBox(
                width: 340,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LiveOsdProgramSection(
                      info: liveInfo,
                      compactWidth: true,
                    ),
                    const SizedBox(height: 12),
                    const RecordedOsdProgramSection(
                      programTitle: '録画番組のとても長いタイトルが2行で表示されるかテスト',
                      broadcastTimeRange: '11/26(木) 08:15–09:55',
                      compactWidth: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('08:15–09:55（残り 37分）'), findsOneWidget);
        expect(find.text('11/26(木) 08:15–09:55'), findsOneWidget);
      },
    );

    testWidgets('PlayerOsdClockOverlay places custom top below back button', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                PlayerOsdClockOverlay(
                  now: DateTime.utc(2026, 11, 26, 0, 36),
                  top: 76,
                  left: 18,
                  fontSize: 40,
                ),
              ],
            ),
          ),
        ),
      );
      final pos = tester.widget<Positioned>(find.byType(Positioned));
      expect(pos.top, 76);
      expect(pos.left, 18);
      final text = tester.widget<Text>(find.text('09:36'));
      expect(text.style?.fontSize, 40);
    });

    test('resolveEffectiveThemeMode follows OS only on non-TV devices', () {
      expect(
        resolveEffectiveThemeMode(
          preference: AppThemePreference.system,
          isTv: false,
        ),
        ThemeMode.system,
      );
      expect(
        resolveEffectiveThemeMode(
          preference: AppThemePreference.system,
          isTv: true,
        ),
        ThemeMode.light,
      );
      expect(
        resolveEffectiveThemeMode(
          preference: AppThemePreference.dark,
          isTv: true,
        ),
        ThemeMode.dark,
      );
      expect(
        resolveEffectiveThemeMode(
          preference: AppThemePreference.light,
          isTv: false,
        ),
        ThemeMode.light,
      );
    });

    test(
      'appThemePreferenceProvider migrates legacy key and syncs nightModeProvider',
      () async {
        final kv = InMemoryKeyValueStore();
        await kv.write('firetv_night_mode', 'true');
        final container = ProviderContainer(
          overrides: [keyValueStoreProvider.overrideWithValue(kv)],
        );
        addTearDown(container.dispose);

        container.read(appThemePreferenceProvider);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(appThemePreferenceProvider), AppThemePreference.dark);
        expect(container.read(nightModeProvider), isTrue);

        await container
            .read(appThemePreferenceProvider.notifier)
            .set(AppThemePreference.system);
        expect(container.read(appThemePreferenceProvider), AppThemePreference.system);
        expect(container.read(nightModeProvider), isFalse);
        expect(await kv.read('app_theme_mode'), 'system');
        expect(await kv.read('firetv_night_mode'), isNull);
      },
    );

    testWidgets(
      'SettingsScreen shows auto/light/dark theme for non-TV and ダークモード switch for TV',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 960);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final kv = InMemoryKeyValueStore();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(kv),
              defaultTargetUiControlModeProvider.overrideWithValue(
                UiControlMode.touch,
              ),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('外観テーマ'), findsOneWidget);
        expect(find.text('ダークモード'), findsNothing);
        expect(find.text('ダーク'), findsOneWidget);
        await tester.tap(find.text('ダーク'));
        await tester.pumpAndSettle();
        expect(await kv.read('app_theme_mode'), 'dark');

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyValueStoreProvider.overrideWithValue(kv),
              defaultTargetUiControlModeProvider.overrideWithValue(
                UiControlMode.tv,
              ),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('ダークモード'), findsOneWidget);
        expect(find.text('外観テーマ'), findsNothing);
      },
    );

    test('PlayerSessionFullscreenHandoff preserves and resets state cleanly', () {
      PlayerSessionFullscreenHandoff.reset();
      addTearDown(PlayerSessionFullscreenHandoff.reset);

      PlayerSessionFullscreenHandoff.touchFullscreenOverride = true;
      PlayerSessionFullscreenHandoff.touchLandscapeLocked = true;
      PlayerSessionFullscreenHandoff.desktopFullscreen = true;

      expect(PlayerSessionFullscreenHandoff.touchFullscreenOverride, isTrue);
      expect(PlayerSessionFullscreenHandoff.touchLandscapeLocked, isTrue);
      expect(PlayerSessionFullscreenHandoff.desktopFullscreen, isTrue);

      PlayerSessionFullscreenHandoff.reset();
      expect(PlayerSessionFullscreenHandoff.touchFullscreenOverride, isNull);
      expect(PlayerSessionFullscreenHandoff.touchLandscapeLocked, isFalse);
      expect(PlayerSessionFullscreenHandoff.desktopFullscreen, isFalse);
    });
  });
}

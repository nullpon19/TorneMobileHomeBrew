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
        expect(find.text('タップで切替'), findsOneWidget);
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
}

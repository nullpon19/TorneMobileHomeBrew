/// Tests for the Home 3D Easter egg assistant ("ナスカ"):
/// - 5 rapid Home taps toggle & persist across restarts (all platforms)
/// - Slow taps (> 2.5s) do not trigger activation
/// - TV mode stays focus-excluded and keeps focus on Home NavigationRail on reselect
/// - Non-TV Office balloon auto-types & locks "お前を消す方法",
///   Options shows only "さようなら", Search/さようなら triggers exit -> hidden
/// - Scroll near bottom lifts the character smoothly
/// - Nasuka3dPainter & "ゲス" comment generator cover all states without error
library;

import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/firetv_helper.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/app/ui_control_mode.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/app_shell.dart';
import 'package:tmhb/ui/home_assistant_3d.dart';
import 'package:tmhb/ui/home_assistant_overlay.dart';

const RegisteredNasne _testReg = RegisteredNasne(
  host: '192.0.2.10',
  udn: 'uuid:nasuka-test',
  friendlyName: 'テストnasne',
  macAddr: '00:11:22:33:44:55',
);

List<Override> _homeOverrides(
  KeyValueStore kv, {
  UiControlMode uiMode = UiControlMode.touch,
  bool tvMode = false,
}) => [
  registrationStoreProvider.overrideWithValue(
    InMemoryRegistrationStore(const [_testReg]),
  ),
  keyValueStoreProvider.overrideWithValue(kv),
  selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
  fireTvHelperProvider.overrideWithValue(
    FireTvHelper(isAndroidOverride: false, isTvOverride: tvMode),
  ),
  defaultTargetUiControlModeProvider.overrideWithValue(uiMode),
  deviceInfoProvider(_testReg).overrideWith(
    (ref) async => const DeviceInfo(
      name: 'テストnasne',
      softwareVersion: '0260',
    ),
  ),
  hddDetailsProvider(_testReg).overrideWith((ref) async => const []),
  liveStatusProvider(_testReg).overrideWith(
    (ref) async => const LiveStatus(sections: {}, raw: {}),
  ),
  recNgProvider(_testReg).overrideWith((ref) async => const []),
  networkInfoProvider(_testReg).overrideWith(
    (ref) async => const NetworkInfo(
      macAddr: '00:11:22:33:44:55',
      ipv4Addr: '192.0.2.10',
    ),
  ),
  bcasInfoProvider(_testReg).overrideWith(
    (ref) async => const BcasInfo(status: 'OK'),
  ),
];

void main() {
  group('HomeAssistantNotifier persistence & rapid-tap toggle', () {
    test('defaults to hidden and restores enabled state from storage', () async {
      final kv = InMemoryKeyValueStore();
      final emptyContainer = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(emptyContainer.dispose);
      expect(
        emptyContainer.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        emptyContainer.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );

      await kv.write(HomeAssistantNotifier.storageKey, 'true');
      final restoredContainer = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(restoredContainer.dispose);
      expect(
        restoredContainer.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        restoredContainer.read(homeAssistantProvider).stage,
        HomeAssistantStage.entering,
      );
      expect(restoredContainer.read(homeAssistantProvider).enabled, isTrue);
    });

    testWidgets('5 rapid taps on Home toggles Nasuka and slow taps do not', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final kv = InMemoryKeyValueStore();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: _homeOverrides(kv, uiMode: UiControlMode.touch),
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: AppShell());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final homeTabFinder = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('ホーム'),
      );

      // 4 taps + > 2.5s pause resets window and stays hidden.
      for (var i = 0; i < 4; i++) {
        await tester.tap(homeTabFinder);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );
      await tester.pump(const Duration(milliseconds: 2600));
      await tester.tap(homeTabFinder);
      await tester.pump();
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );

      // 4 more rapid taps within 2.5s reaches 5 total -> activates Nasuka.
      for (var i = 0; i < 4; i++) {
        await tester.tap(homeTabFinder);
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.entering,
      );
      expect(await kv.read(HomeAssistantNotifier.storageKey), 'true');
      expect(find.byKey(const ValueKey('nasukaCharacterTapTarget')), findsOneWidget);

      // Advance through entry animation to idle (0.5s steps because ticker clamps dt <= 1s).
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.idle,
      );

      // 5 more rapid taps dismisses Nasuka with exit animation -> hidden.
      for (var i = 0; i < 5; i++) {
        await tester.tap(homeTabFinder);
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.exiting,
      );
      expect(await kv.read(HomeAssistantNotifier.storageKey), 'false');

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );
    });
  });

  group('TV mode focus isolation', () {
    testWidgets('TV mode allows 5-tap toggle while keeping rail focus and excluding character focus', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final kv = InMemoryKeyValueStore();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: _homeOverrides(
            kv,
            uiMode: UiControlMode.tv,
            tvMode: true,
          ),
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: AppShell());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final homeRailFinder = find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('ホーム'),
      );

      // 5 rapid taps on Home in NavigationRail keeps focus on rail & spawns Nasuka.
      for (var i = 0; i < 5; i++) {
        await tester.tap(homeRailFinder);
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.entering,
      );
      // In TV mode, tap target is NOT interactive and focus stays in NavigationRail.
      expect(find.byKey(const ValueKey('nasukaCharacterTapTarget')), findsNothing);
      final focusCtx = FocusManager.instance.primaryFocus?.context;
      expect(focusCtx, isNotNull);
      expect(
        find.ancestor(
          of: find.byWidget(focusCtx!.widget),
          matching: find.byType(NavigationRail),
        ),
        findsOneWidget,
      );

      // Advance past entry + entry speech hide timer cleanly.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
    });

    testWidgets(
      'TV mode 5-tap dismissal auto-plays Office balloon -> お前を消す方法 -> Search -> exiting -> hidden without stealing focus',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final kv = InMemoryKeyValueStore();
        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: _homeOverrides(
              kv,
              uiMode: UiControlMode.tv,
              tvMode: true,
            ),
            child: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const MaterialApp(home: AppShell());
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final homeRailFinder = find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('ホーム'),
        );

        void expectFocusOnRail() {
          final focusCtx = FocusManager.instance.primaryFocus?.context;
          expect(focusCtx, isNotNull);
          expect(
            find.ancestor(
              of: find.byWidget(focusCtx!.widget),
              matching: find.byType(NavigationRail),
            ),
            findsOneWidget,
          );
        }

        // Spawn Nasuka and advance to idle.
        for (var i = 0; i < 5; i++) {
          await tester.tap(homeRailFinder);
          await tester.pump(const Duration(milliseconds: 80));
        }
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(
          container.read(homeAssistantProvider).stage,
          HomeAssistantStage.idle,
        );

        // 5 rapid taps in TV mode starts dismissingAuto choreography.
        for (var i = 0; i < 5; i++) {
          await tester.tap(homeRailFinder);
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(
          container.read(homeAssistantProvider).stage,
          HomeAssistantStage.dismissingAuto,
        );
        expect(await kv.read(HomeAssistantNotifier.storageKey), 'false');
        expect(find.text('何について調べますか？'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expectFocusOnRail();

        // Advance through auto-delay (350ms) + 7 chars * 130ms (~1260ms).
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        final inputText = tester.widget<Text>(
          find.byKey(const ValueKey('nasukaAutoDismissInputText')),
        );
        expect(inputText.data, startsWith(nasukaDismissQuery));
        expectFocusOnRail();

        // Advance past auto search press (~1940ms total, before ~2360ms submit).
        await tester.pump(const Duration(milliseconds: 550));
        final searchContainer = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(const ValueKey('nasukaOfficeSearchButton')),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          (searchContainer.decoration! as BoxDecoration).color,
          const Color(0xFFDDDCD0),
        );

        // Advance past submit -> transitions to exiting with bubble ring & sad eyes.
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('何について調べますか？'), findsNothing);
        expect(
          container.read(homeAssistantProvider).stage,
          HomeAssistantStage.exiting,
        );
        expectFocusOnRail();

        // Finish exit animation -> hidden.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(
          container.read(homeAssistantProvider).stage,
          HomeAssistantStage.hidden,
        );
        expectFocusOnRail();
      },
    );
  });

  group('Non-TV Office balloon & dismissal', () {
    testWidgets('tap opens Office balloon, locks text to お前を消す方法, Options->さようなら & Search dismiss', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final kv = InMemoryKeyValueStore()..write(HomeAssistantNotifier.storageKey, 'true');
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: _homeOverrides(kv, uiMode: UiControlMode.touch),
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: AppShell());
            },
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.idle,
      );

      await tester.tap(find.byKey(const ValueKey('nasukaCharacterTapTarget')));
      await tester.pump();

      expect(find.text('何について調べますか？'), findsOneWidget);
      // Let typewriter finish "お前を消す方法" (7 chars * 75ms).
      await tester.pump(const Duration(milliseconds: 700));
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('nasukaOfficeInput')),
      );
      expect(field.controller?.text, nasukaDismissQuery);

      // Attempt to overwrite input -> locked formatter keeps "お前を消す方法".
      await tester.enterText(
        find.byKey(const ValueKey('nasukaOfficeInput')),
        '別の検索ワード',
      );
      await tester.pump();
      expect(field.controller?.text, nasukaDismissQuery);

      // Options button shows only "さようなら".
      await tester.tap(find.byKey(const ValueKey('nasukaOfficeOptionsButton')));
      await tester.pump();
      expect(find.text('さようなら'), findsOneWidget);

      // Tapping "さようなら" triggers wistful exit -> hidden & persisted false.
      await tester.tap(find.byKey(const ValueKey('nasukaOfficeSayonaraItem')));
      await tester.pump();
      expect(find.text('何について調べますか？'), findsNothing);
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.exiting,
      );
      expect(await kv.read(HomeAssistantNotifier.storageKey), 'false');

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );

      // Re-activate via notifier and test Search(S) button dismissal path.
      await container.read(homeAssistantProvider.notifier).activate();
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(find.byKey(const ValueKey('nasukaCharacterTapTarget')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      await tester.tap(find.byKey(const ValueKey('nasukaOfficeSearchButton')));
      await tester.pump();
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.exiting,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        container.read(homeAssistantProvider).stage,
        HomeAssistantStage.hidden,
      );
    });
  });

  group('Bottom avoidance, 3D painter, and ゲス comments', () {
    testWidgets('shifts upward when avoidBottomListenable switches to true', (
      tester,
    ) async {
      final avoidBottom = ValueNotifier<bool>(false);
      addTearDown(avoidBottom.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeAssistantProvider.overrideWith(
              () => _FixedAssistantNotifier(
                const HomeAssistantState(
                  enabled: true,
                  stage: HomeAssistantStage.idle,
                  triggerSeq: 1,
                ),
              ),
            ),
            defaultTargetUiControlModeProvider.overrideWithValue(
              UiControlMode.touch,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  HomeAssistantOverlay(
                    reg: _testReg,
                    avoidBottomListenable: avoidBottom,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      AnimatedPositioned posWidget() => tester.widget<AnimatedPositioned>(
        find.byKey(const ValueKey('nasukaOverlayPosition')),
      );
      expect(posWidget().bottom, 12);

      avoidBottom.value = true;
      await tester.pump();
      expect(posWidget().bottom, 124);
    });

    test('Nasuka3dPainter paints all lifecycle stages & actions without error', () {
      final poses = <Nasuka3dPose>[
        const Nasuka3dPose(
          stage: HomeAssistantStage.entering,
          stageProgress: 0.25,
          idleTime: 0.5,
          action: NasukaAction.float,
          actionProgress: 0.0,
        ),
        const Nasuka3dPose(
          stage: HomeAssistantStage.entering,
          stageProgress: 0.55,
          idleTime: 1.0,
          action: NasukaAction.float,
          actionProgress: 0.0,
        ),
        for (final action in NasukaAction.values)
          Nasuka3dPose(
            stage: HomeAssistantStage.idle,
            stageProgress: 0.0,
            idleTime: 2.3,
            action: action,
            actionProgress: 0.5,
            speaking: true,
          ),
        const Nasuka3dPose(
          stage: HomeAssistantStage.dismissingAuto,
          stageProgress: 0.0,
          idleTime: 2.5,
          action: NasukaAction.float,
          actionProgress: 0.0,
          sad: false,
        ),
        const Nasuka3dPose(
          stage: HomeAssistantStage.dismissingAuto,
          stageProgress: 0.0,
          idleTime: 2.8,
          action: NasukaAction.float,
          actionProgress: 0.0,
          sad: true,
        ),
        const Nasuka3dPose(
          stage: HomeAssistantStage.exiting,
          stageProgress: 0.45,
          idleTime: 3.1,
          action: NasukaAction.float,
          actionProgress: 0.0,
          sad: true,
        ),
        const Nasuka3dPose(
          stage: HomeAssistantStage.exiting,
          stageProgress: 0.85,
          idleTime: 4.0,
          action: NasukaAction.float,
          actionProgress: 0.0,
          sad: true,
        ),
      ];

      for (final pose in poses) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        Nasuka3dPainter(pose: pose).paint(canvas, const Size(128, 112));
        recorder.endRecording().dispose();
      }
    });

    test('buildNasukaComment includes live/HDD/RecNg lines in ゲス tone', () {
      const hddEntry = HddEntry(
        id: 0,
        internal: true,
        mounted: true,
        registered: true,
      );
      const lowHdd = [
        HddDetail(
          hddEntry,
          HddInfo(
            id: 0,
            internal: true,
            format: 'xfs',
            name: 'hdd0',
            usedBytes: 900,
            freeBytes: 100,
            totalBytes: 1000,
          ),
        ),
      ];
      final lowComment = buildNasukaComment(
        now: DateTime(2026, 11, 27, 9),
        hdds: lowHdd,
        seed: 0,
      );
      expect(lowComment, contains('ゲス'));
      expect(lowComment, contains('ピンチ'));

      final ngComment = buildNasukaComment(
        now: DateTime(2026, 11, 27, 9),
        recNg: [
          RecNgItem(
            id: 'ng1',
            title: '失敗番組',
            startTime: DateTime.utc(2026, 11, 27),
            raw: const {},
          ),
        ],
        reg: _testReg,
        seed: 0,
      );
      expect(ngComment, contains('録画失敗が 1 件'));
      expect(ngComment, contains('ゲス'));
    });
  });
}

class _FixedHostNotifier extends SelectedHostNotifier {
  _FixedHostNotifier(this._host);
  final String _host;

  @override
  String? build() => _host;
}

class _FixedAssistantNotifier extends HomeAssistantNotifier {
  _FixedAssistantNotifier(this._fixed);
  final HomeAssistantState _fixed;

  @override
  HomeAssistantState build() => _fixed;
}

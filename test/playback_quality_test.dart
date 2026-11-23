/// Fire TV unlocked playback quality tests:
/// - Defaults to original quality (`元画質`, false)
/// - Ignores legacy `playback_use_mobile` and persists `firetv_default_use_mobile`
/// - Settings updates the saved default via `SegmentedButton<bool>`
/// - Detail screens allow per-visit override without overwriting the default
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/live_screen.dart';
import 'package:tmhb/ui/settings_screen.dart';

/// Lets the notifier's asynchronous restore / write-back settle.
Future<void> flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

const _reg = RegisteredNasne(
  host: '192.0.2.1',
  udn: 'uuid:test',
  friendlyName: 'nasne',
  macAddr: '00:11:22:33:44:55',
);

void main() {
  group('PlaybackQualityNotifier default & persistence', () {
    late InMemoryKeyValueStore keyValues;

    setUp(() {
      keyValues = InMemoryKeyValueStore();
    });

    ProviderContainer makeContainer() {
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(keyValues)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('nothing stored defaults to original quality (false)', () async {
      final container = makeContainer();
      expect(container.read(playbackQualityProvider), isFalse);
      await flush();
      expect(container.read(playbackQualityProvider), isFalse);
    });

    test('legacy playback_use_mobile=true resets once to original (false)', () async {
      await keyValues.write('playback_use_mobile', 'true');
      final container = makeContainer();
      container.read(playbackQualityProvider);
      await flush();
      expect(container.read(playbackQualityProvider), isFalse);
    });

    test('set updates and persists firetv_default_use_mobile', () async {
      final container = makeContainer();
      final notifier = container.read(playbackQualityProvider.notifier);
      await notifier.set(true);
      expect(container.read(playbackQualityProvider), isTrue);
      expect(await keyValues.read('firetv_default_use_mobile'), 'true');

      final container2 = makeContainer();
      container2.read(playbackQualityProvider);
      await flush();
      expect(container2.read(playbackQualityProvider), isTrue);
    });
  });

  group('settings screen playback quality', () {
    Future<void> pumpSettings(
      WidgetTester tester,
      InMemoryKeyValueStore keyValues,
    ) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const []),
            ),
            keyValueStoreProvider.overrideWithValue(keyValues),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('デフォルト再生画質'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
    }

    testWidgets('settings shows quality selector and persists toggle', (
      tester,
    ) async {
      final keyValues = InMemoryKeyValueStore();
      await pumpSettings(tester, keyValues);
      expect(find.text('デフォルト再生画質'), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsOneWidget);

      await tester.tap(find.text('モバイル'));
      await tester.pumpAndSettle();
      expect(await keyValues.read('firetv_default_use_mobile'), 'true');
    });
  });

  group('live detail playback quality', () {
    const channel = LiveChannel(
      id: '0/video/LiveTuner/DTTB/ch?nid=1&tsid=1&svid=1',
      bandId: '0/video/LiveTuner/DTTB',
      channelName: 'テスト放送',
      programTitle: 'テスト番組',
      res: [
        TitleRes(
          url: 'http://192.0.2.10:58890/web/video/ch?quality=dr',
          protocolInfo: 'http-get:*:application/x-dtcp1:*',
          cleartextSize: 200000000,
          quality: 'dr',
        ),
        TitleRes(
          url: 'http://192.0.2.10:58890/web/video/ch?quality=mobile',
          protocolInfo: 'http-get:*:application/x-dtcp1:*',
          cleartextSize: 20000000,
          quality: 'mobile',
        ),
      ],
    );

    testWidgets('per-visit selector does not overwrite saved default', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final kv = InMemoryKeyValueStore();
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: LiveChannelDetailView(reg: _reg, channel: channel),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SegmentedButton<bool>), findsOneWidget);
      expect(container.read(playbackQualityProvider), isFalse);

      await tester.tap(find.text('モバイル'));
      await tester.pumpAndSettle();
      // Per-visit UI updates without persisting back to global default.
      final button = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(button.selected, {true});
      expect(container.read(playbackQualityProvider), isFalse);
      expect(await kv.read('firetv_default_use_mobile'), isNull);
    });
  });
}

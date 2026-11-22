/// Fire TV provisional build: playback quality is fixed to mobile (true).
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
  group('PlaybackQualityNotifier Fire TV mobile-fixed', () {
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

    test('nothing stored defaults to mobile (true)', () async {
      final container = makeContainer();
      expect(container.read(playbackQualityProvider), isTrue);
      await flush();
      expect(container.read(playbackQualityProvider), isTrue);
      expect(await keyValues.read('playback_use_mobile'), 'true');
    });

    test('a stored false is overridden to mobile (true)', () async {
      await keyValues.write('playback_use_mobile', 'false');
      final container = makeContainer();
      container.read(playbackQualityProvider);
      await flush();
      expect(container.read(playbackQualityProvider), isTrue);
      expect(await keyValues.read('playback_use_mobile'), 'true');
    });

    test('set keeps quality fixed to mobile (true)', () async {
      final container = makeContainer();
      final notifier = container.read(playbackQualityProvider.notifier);
      await notifier.set(false);
      expect(container.read(playbackQualityProvider), isTrue);
      expect(await keyValues.read('playback_use_mobile'), 'true');
    });
  });

  group('settings screen playback quality', () {
    Future<void> pumpSettings(
      WidgetTester tester,
      InMemoryKeyValueStore keyValues,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(find.text('再生画質: モバイル固定'));
      await tester.pump();
    }

    testWidgets('settings shows mobile-fixed indicator without selector', (
      tester,
    ) async {
      final keyValues = InMemoryKeyValueStore();
      await pumpSettings(tester, keyValues);
      expect(find.text('再生画質: モバイル固定'), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
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

    Future<void> pumpDetail(
      WidgetTester tester,
      InMemoryKeyValueStore keyValues,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [keyValueStoreProvider.overrideWithValue(keyValues)],
          child: const MaterialApp(
            home: Scaffold(
              body: LiveChannelDetailView(reg: _reg, channel: channel),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    testWidgets('shows mobile-fixed text and no quality segmented button', (
      tester,
    ) async {
      await pumpDetail(tester, InMemoryKeyValueStore());
      expect(find.text('画質: モバイル固定'), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
    });
  });
}

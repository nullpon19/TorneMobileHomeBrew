/// Programme search tests (plan 86, plan 85 item 8): the
/// pure search over the held EPG dataset, and the search
/// screen (keyword entry, genre filter, result -> detail
/// dialog, and the guide screen's entry point).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/bs_epg_providers.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/epg_screen.dart';
import 'package:tmhb/ui/epg_search.dart';
import 'package:tmhb/ui/epg_search_screen.dart';
import 'package:tmhb/ui/widgets.dart';

const _reg = RegisteredNasne(
  host: '192.0.2.1',
  udn: 'uuid:test',
  friendlyName: 'nasne',
  macAddr: '00:11:22:33:44:55',
);

Channel _channel(int serviceId, String name) => Channel(
  broadcastingType: 2,
  networkId: 1,
  transportStreamId: 1,
  serviceId: serviceId,
  serviceType: 1,
  channelNumber: serviceId,
  serviceName: name,
);

EpgEvent _event(
  int id,
  DateTime start, {
  String? title,
  String? shortText,
  String? description,
  String? cast,
  int? genre,
}) => EpgEvent(
  eventId: id,
  start: start,
  duration: const Duration(minutes: 30),
  title: title,
  shortText: shortText,
  description: description,
  cast: cast,
  genreLevel1: genre,
);

final _t0 = DateTime.utc(2026, 11, 21, 1); // 10:00 JST

EpgGuide _guide() => EpgGuide(
  broadcastingType: 2,
  services: [
    EpgServiceGuide(
      channel: _channel(1, 'テスト局'),
      events: [
        _event(1, _t0, title: '朝のニュース', genre: 0),
        _event(
          2,
          _t0.add(const Duration(hours: 1)),
          title: '連続ドラマ「海」',
          description: '海辺の町の物語',
          cast: '山田花子',
          genre: 3,
        ),
        _event(3, _t0.add(const Duration(hours: 2)), title: 'News English'),
      ],
    ),
    EpgServiceGuide(
      channel: _channel(2, '映画チャンネル'),
      events: [
        _event(
          4,
          _t0.add(const Duration(minutes: 30)),
          title: '名画座',
          shortText: '海が舞台の名作',
          genre: 6,
        ),
      ],
    ),
  ],
);

List<int> _ids(List<EpgSearchHit> hits) => [
  for (final hit in hits) hit.event.eventId,
];

void main() {
  group('searchEpgProgrammes', () {
    test('matches the title', () {
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: 'ニュース')), [1]);
    });

    test('matches description, cast and short text', () {
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: '物語')), [2]);
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: '山田')), [2]);
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: '名作')), [4]);
    });

    test('matches the channel name', () {
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: '映画チャンネル')), [
        4,
      ]);
    });

    test('is case-insensitive', () {
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: 'news')), [3]);
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: 'NEWS')), [3]);
    });

    test('returns hits in start order across channels', () {
      expect(_ids(searchEpgProgrammes(guides: [_guide()], query: '海')), [4, 2]);
    });

    test('genre filter alone, and combined with a keyword', () {
      expect(_ids(searchEpgProgrammes(guides: [_guide()], genreLevel1: 0)), [
        1,
      ]);
      expect(
        _ids(
          searchEpgProgrammes(guides: [_guide()], query: '海', genreLevel1: 3),
        ),
        [2],
      );
      expect(
        _ids(
          searchEpgProgrammes(guides: [_guide()], query: '海', genreLevel1: 6),
        ),
        [4],
      );
    });

    test('empty query without a genre returns everything in order', () {
      expect(_ids(searchEpgProgrammes(guides: [_guide()])), [1, 4, 2, 3]);
    });

    test('no match returns an empty list', () {
      expect(searchEpgProgrammes(guides: [_guide()], query: '存在しない'), isEmpty);
    });
  });

  group('EpgSearchIndex (plan 98)', () {
    test('agrees with the direct search on every case', () {
      final guides = [_guide()];
      final index = EpgSearchIndex.fromGuides(guides);
      for (final (query, genre) in <(String, int?)>[
        ('ニュース', null),
        ('物語', null),
        ('山田', null),
        ('名作', null),
        ('映画チャンネル', null),
        ('news', null),
        ('NEWS', null),
        ('海', null),
        ('海', 3),
        ('海', 6),
        ('', 0),
        ('', null),
        ('存在しない', null),
      ]) {
        expect(
          _ids(index.search(query: query, genreLevel1: genre)),
          _ids(
            searchEpgProgrammes(
              guides: guides,
              query: query,
              genreLevel1: genre,
            ),
          ),
          reason: 'query=$query genre=$genre',
        );
      }
    });

    test('collects the genre values and the event count once', () {
      final index = EpgSearchIndex.fromGuides([_guide()]);
      expect(index.genreValues, [0, 3, 6]);
      expect(index.eventCount, 4);
    });
  });

  group('epgSearchGenreValues / epgSearchGenreLabel', () {
    test('values are the genres present, ascending and unique', () {
      expect(epgSearchGenreValues([_guide()]), [0, 3, 6]);
    });

    test('labels name the ARIB level-1 genres', () {
      expect(epgSearchGenreLabel(0), 'ニュース・報道');
      expect(epgSearchGenreLabel(3), 'ドラマ');
      expect(epgSearchGenreLabel(15), 'その他');
      expect(epgSearchGenreLabel(99), 'ジャンル 99');
    });
  });

  group('EpgSearchScreen', () {
    EpgGuide futureGuide() {
      final start = DateTime.now().toUtc().add(const Duration(days: 1));
      return EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: _channel(1, 'テスト局'),
            events: [
              _event(1, start, title: '明日のドラマ', genre: 3),
              _event(
                2,
                start.add(const Duration(hours: 1)),
                title: '明日の映画',
                genre: 6,
              ),
            ],
          ),
        ],
      );
    }

    Widget host(Widget child, {EpgGuide? guide}) {
      return ProviderScope(
        overrides: [
          epgGuideProvider.overrideWith((ref, r) async => guide ?? _guide()),
          bsEpgGuideProvider.overrideWith(
            (ref, r) async => const EpgGuide(broadcastingType: 3, services: []),
          ),
        ],
        child: MaterialApp(home: child),
      );
    }

    testWidgets('shows the hint before any input', (tester) async {
      await tester.pumpWidget(host(const EpgSearchScreen(reg: _reg)));
      await tester.pump();
      expect(find.textContaining('キーワードを入力するか'), findsOneWidget);
    });

    testWidgets('keyword search lists hits and opens the detail dialog', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const EpgSearchScreen(reg: _reg), guide: futureGuide()),
      );
      await tester.pump();
      await tester.tap(find.byType(FireTvTextInputField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ドラマ');
      await tester.tap(find.text('決定'));
      await tester.pumpAndSettle();
      // The query applies after the debounce settles (plan 98).
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('明日のドラマ'), findsOneWidget);
      expect(find.text('明日の映画'), findsNothing);
      await tester.tap(find.text('明日のドラマ'));
      await tester.pumpAndSettle();
      // The shared detail dialog, with the reservation action
      // for an event that has not ended.
      expect(find.text('録画予約'), findsOneWidget);
    });

    testWidgets('typing is debounced before it searches (plan 98)', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const EpgSearchScreen(reg: _reg), guide: futureGuide()),
      );
      await tester.pump();
      await tester.tap(find.byType(FireTvTextInputField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ドラマ');
      await tester.tap(find.text('決定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Before debounce elapses, the search has not applied yet.
      expect(find.text('明日のドラマ'), findsNothing);
      expect(find.textContaining('キーワードを入力するか'), findsOneWidget);
      // Once the debounce settles, the search runs.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('明日のドラマ'), findsOneWidget);
    });

    testWidgets('genre dropdown filters the results', (tester) async {
      await tester.pumpWidget(
        host(const EpgSearchScreen(reg: _reg), guide: futureGuide()),
      );
      await tester.pump();
      await tester.tap(find.byType(DropdownButton<int?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('映画').last);
      await tester.pumpAndSettle();
      expect(find.text('明日の映画'), findsOneWidget);
      expect(find.text('明日のドラマ'), findsNothing);
    });

    testWidgets('the guide screen has a search entry point', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_reg]),
            ),
            epgGuideProvider.overrideWith((ref, r) async => futureGuide()),
            bsEpgGuideProvider.overrideWith(
              (ref, r) async =>
                  const EpgGuide(broadcastingType: 3, services: []),
            ),
            channelLogosProvider.overrideWith(
              (ref, r) async => const <int, List<int>>{},
            ),
          ],
          child: const MaterialApp(home: EpgScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      expect(find.byType(EpgSearchScreen), findsOneWidget);
    });
  });
}

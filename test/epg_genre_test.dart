/// Genre table tests (plan 86, plan 85 item 10): labels and
/// colours of the ARIB level-1 genres, the tile tint, the
/// search label's delegation to the shared table, and the
/// guide grid painting genred tiles differently (with the
/// genre named in the detail dialog).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/epg_genre.dart';
import 'package:tmhb/ui/epg_screen.dart';
import 'package:tmhb/ui/epg_search.dart';

void main() {
  group('epgGenreLabel', () {
    test('names the viewer-facing genres', () {
      expect(epgGenreLabel(0), 'ニュース・報道');
      expect(epgGenreLabel(3), 'ドラマ');
      expect(epgGenreLabel(7), 'アニメ・特撮');
      expect(epgGenreLabel(15), 'その他');
    });

    test('reserved, extension, unknown and absent genres are unnamed', () {
      expect(epgGenreLabel(12), isNull);
      expect(epgGenreLabel(13), isNull);
      expect(epgGenreLabel(14), isNull);
      expect(epgGenreLabel(99), isNull);
      expect(epgGenreLabel(null), isNull);
    });
  });

  group('epgGenreColor', () {
    test('every named genre has a colour, and they are all distinct', () {
      final colours = <Color>{};
      for (var genre = 0; genre <= 15; genre++) {
        if (epgGenreLabel(genre) == null) continue;
        final colour = epgGenreColor(genre);
        expect(colour, isNotNull, reason: 'genre $genre');
        colours.add(colour!);
      }
      expect(colours.length, 13);
    });

    test('unnamed genres have no colour', () {
      expect(epgGenreColor(12), isNull);
      expect(epgGenreColor(null), isNull);
    });
  });

  group('epgGenreTileColor', () {
    const surface = Color(0xFFFFFFFF);
    const fallback = Color(0xFFEEEEEE);

    test('an ungenred tile keeps the fallback', () {
      expect(
        epgGenreTileColor(
          genreLevel1: null,
          surface: surface,
          fallback: fallback,
        ),
        fallback,
      );
      expect(
        epgGenreTileColor(
          genreLevel1: 12,
          surface: surface,
          fallback: fallback,
        ),
        fallback,
      );
    });

    test('a genred tile is the genre colour blended over the surface', () {
      final expected = Color.alphaBlend(
        epgGenreColor(3)!.withAlpha((epgGenreTintStrength * 255).round()),
        surface,
      );
      final actual = epgGenreTileColor(
        genreLevel1: 3,
        surface: surface,
        fallback: fallback,
      );
      expect(actual, expected);
      expect(actual, isNot(fallback));
      expect(actual, isNot(epgGenreColor(3)));
    });

    test('different genres tint differently', () {
      expect(
        epgGenreTileColor(genreLevel1: 0, surface: surface, fallback: fallback),
        isNot(
          epgGenreTileColor(
            genreLevel1: 3,
            surface: surface,
            fallback: fallback,
          ),
        ),
      );
    });
  });

  group('epgSearchGenreLabel delegates to the shared table', () {
    test('named genres share the name; others fall back to a number', () {
      expect(epgSearchGenreLabel(3), epgGenreLabel(3));
      expect(epgSearchGenreLabel(12), 'ジャンル 12');
    });
  });

  group('guide grid', () {
    testWidgets('a genred tile is tinted; the detail dialog names the genre', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const reg = RegisteredNasne(
        host: '192.0.2.1',
        udn: 'uuid:test',
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
      final now = DateTime.now().toUtc();
      final jstHour = now.add(const Duration(hours: 9)).hour;
      final secondStart = jstHour >= 23
          ? now.subtract(const Duration(hours: 1))
          : now.add(const Duration(hours: 1));
      final guide = EpgGuide(
        broadcastingType: 2,
        services: [
          EpgServiceGuide(
            channel: channel,
            events: [
              EpgEvent(
                eventId: 1,
                start: now,
                duration: const Duration(minutes: 30),
                title: 'ドラマ番組',
                genreLevel1: 3,
              ),
              EpgEvent(
                eventId: 2,
                start: secondStart,
                duration: const Duration(minutes: 30),
                title: '通常番組',
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
      await tester.pump(const Duration(milliseconds: 100));

      Material tileOf(String title) => tester.widget<Material>(
        find
            .ancestor(of: find.text(title), matching: find.byType(Material))
            .first,
      );
      expect(tileOf('ドラマ番組').color, isNot(tileOf('通常番組').color));

      await tester.tap(find.text('ドラマ番組'));
      await tester.pumpAndSettle();
      expect(find.text('ジャンル: ドラマ'), findsOneWidget);
    });
  });
}

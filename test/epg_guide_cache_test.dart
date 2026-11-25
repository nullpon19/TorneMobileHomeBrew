/// Programme-guide accumulation (plan 23): merging a fresh guide
/// with the persistent cache, and the cache's own round-trip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tmhb/core/core.dart';

const _channel = Channel(
  broadcastingType: 2,
  networkId: 0x1111,
  transportStreamId: 0x2222,
  serviceId: 0x3333,
  serviceType: 1,
  channelNumber: 1,
  serviceName: 'テスト局',
);

final _day = DateTime.utc(2026, 11, 20);

EpgEvent _event(
  int id,
  int hour, {
  String? title,
  String? description,
  int minutes = 30,
}) =>
    EpgEvent(
      eventId: id,
      start: _day.add(Duration(hours: hour)),
      duration: Duration(minutes: minutes),
      title: title,
      description: description,
    );

EpgGuide _guide(List<EpgEvent> events) => EpgGuide(
      broadcastingType: 2,
      services: [EpgServiceGuide(channel: _channel, events: events)],
    );

void main() {
  group('mergeEpgGuideWithCache', () {
    test('fills fields the fresh copy lacks from the cached twin', () {
      final fresh = _guide([_event(1, 10, description: '内容')]);
      final merged = mergeEpgGuideWithCache(fresh, {
        0x3333: [_event(1, 10, title: 'タイトル', description: '古い内容')],
      });
      final e = merged.services.single.events.single;
      expect(e.title, 'タイトル');
      // Fresh values always win where both copies carry them.
      expect(e.description, '内容');
    });

    test('carries over cached events the fresh guide no longer has',
        () {
      final fresh = _guide([_event(2, 12, title: '新しい番組')]);
      final merged = mergeEpgGuideWithCache(fresh, {
        0x3333: [_event(1, 10, title: '前の取得で残った番組')],
      });
      final events = merged.services.single.events;
      expect(events.map((e) => e.eventId), [1, 2]);
      expect(events.first.title, '前の取得で残った番組');
    });

    test('prunes cached events that ended over a day before the '
        'fresh guide starts', () {
      final fresh = _guide([_event(2, 12, title: '新しい番組')]);
      final stale = EpgEvent(
        eventId: 9,
        start: _day.subtract(const Duration(days: 3)),
        duration: const Duration(minutes: 30),
        title: '古すぎる番組',
      );
      final merged = mergeEpgGuideWithCache(fresh, {
        0x3333: [stale],
      });
      expect(
          merged.services.single.events.map((e) => e.eventId), [2]);
    });

    test('ignores cache entries for services absent from the fresh '
        'guide', () {
      final fresh = _guide([_event(1, 10, title: '番組')]);
      final merged = mergeEpgGuideWithCache(fresh, {
        0x9999: [_event(5, 10, title: '別局の番組')],
      });
      expect(merged.services.length, 1);
      expect(merged.services.single.events.length, 1);
    });

    test('empty cache returns the fresh guide untouched', () {
      final fresh = _guide([_event(1, 10)]);
      expect(identical(mergeEpgGuideWithCache(fresh, const {}), fresh),
          isTrue);
    });

    test('drops cached event replaced by emergency news overlap', () {
      final t1200 = _day.add(const Duration(hours: 12));
      final t1230 = _day.add(const Duration(minutes: 12 * 60 + 30));
      final cachedOldA = EpgEvent(
        eventId: 100,
        start: t1200,
        duration: const Duration(hours: 1),
        title: '通常番組A',
      );
      final freshNews = EpgEvent(
        eventId: 999,
        start: t1200,
        duration: const Duration(minutes: 30),
        title: '緊急ニュース',
      );
      final freshDelayedA = EpgEvent(
        eventId: 100,
        start: t1230,
        duration: const Duration(hours: 1),
        title: '通常番組A',
      );
      final merged = mergeEpgGuideWithCache(
        _guide([freshNews, freshDelayedA]),
        {
          0x3333: [cachedOldA],
        },
      );
      final events = merged.services.single.events;
      expect(events.map((e) => e.eventId), [999, 100]);
      expect(events.map((e) => e.start), [t1200, t1230]);
    });

    test('drops shifted same-eventId cached event within 24h even without overlap', () {
      final t1200 = _day.add(const Duration(hours: 12));
      final t1300 = _day.add(const Duration(hours: 13));
      final cachedOldA = EpgEvent(
        eventId: 100,
        start: t1200,
        duration: const Duration(hours: 1),
        title: '通常番組A',
      );
      final freshMovedA = EpgEvent(
        eventId: 100,
        start: t1300,
        duration: const Duration(hours: 1),
        title: '通常番組A',
      );
      final merged = mergeEpgGuideWithCache(
        _guide([freshMovedA]),
        {
          0x3333: [cachedOldA],
        },
      );
      final events = merged.services.single.events;
      expect(events.length, 1);
      expect(events.single.start, t1300);
    });

    test('retains non-overlapping past event for playback rewind', () {
      final pastEvent = _event(50, 10, title: '直前の番組');
      final freshCurrent = _event(51, 12, title: '今の番組');
      final merged = mergeEpgGuideWithCache(
        _guide([freshCurrent]),
        {
          0x3333: [pastEvent],
        },
      );
      final events = merged.services.single.events;
      expect(events.map((e) => e.eventId), [50, 51]);
    });
  });

  group('shouldRefreshStaleEpgGuide', () {
    test('returns true when missing, expired, or older than maxAge', () {
      final now = _day.add(const Duration(hours: 12, minutes: 20));
      expect(shouldRefreshStaleEpgGuide(null, now), isTrue);

      final freshGuide = EpgGuide(
        broadcastingType: 2,
        fetchedAt: now.subtract(const Duration(minutes: 10)),
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [_event(1, 12, minutes: 60)],
          ),
        ],
      );
      expect(shouldRefreshStaleEpgGuide(freshGuide, now), isFalse);

      final agedGuide = EpgGuide(
        broadcastingType: 2,
        fetchedAt: now.subtract(const Duration(minutes: 15)),
        services: freshGuide.services,
      );
      expect(shouldRefreshStaleEpgGuide(agedGuide, now), isTrue);

      final expiredGuide = EpgGuide(
        broadcastingType: 2,
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        services: [
          EpgServiceGuide(
            channel: _channel,
            events: [_event(1, 11, minutes: 60)],
          ),
        ],
      );
      expect(shouldRefreshStaleEpgGuide(expiredGuide, now), isTrue);
    });
  });

  group('EpgGuideCache', () {
    test('round-trips events through the key-value store', () async {
      final cache = EpgGuideCache(InMemoryKeyValueStore());
      final guide = _guide([
        _event(1, 10, title: 'タイトル', description: '内容'),
        _event(2, 11),
      ]);
      await cache.save('192.0.2.1', 2, guide);
      final loaded = await cache.load('192.0.2.1', 2);
      expect(loaded.keys, [0x3333]);
      final events = loaded[0x3333]!;
      expect(events.length, 2);
      expect(events[0].eventId, 1);
      expect(events[0].start, _day.add(const Duration(hours: 10)));
      expect(events[0].duration, const Duration(minutes: 30));
      expect(events[0].title, 'タイトル');
      expect(events[0].description, '内容');
      expect(events[1].title, isNull);
    });

    test('missing key and other hosts load as empty', () async {
      final cache = EpgGuideCache(InMemoryKeyValueStore());
      expect(await cache.load('192.0.2.99', 2), isEmpty);
      await cache.save('192.0.2.1', 2, _guide([_event(1, 10)]));
      expect(await cache.load('192.0.2.2', 2), isEmpty);
      expect(await cache.load('192.0.2.1', 3), isEmpty);
    });
  });
}

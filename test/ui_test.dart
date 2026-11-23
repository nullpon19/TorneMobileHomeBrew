/// Widget tests for the v1 screens (plan 5.6), driven entirely by
/// fake implementations of the domain interfaces — the same swap the
/// composition root allows in production (plan 5.0 / 12.7). No
/// network or device is involved.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/main.dart';
import 'package:tmhb/ui/titles_screen.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

const testReg = RegisteredNasne(
  host: '192.0.2.10',
  udn: 'uuid:test',
  friendlyName: 'nasne',
  macAddr: '00:11:22:33:44:55',
);

const testChannel = Channel(
  broadcastingType: 2,
  networkId: 30848,
  transportStreamId: 1,
  serviceId: 56832,
  serviceType: 1,
  channelNumber: 1,
  serviceName: 'テスト放送',
);

RecordSchedule sampleSchedule({
  String id = '101',
  int priorityFlag = 0,
  int durationSeconds = 1800,
}) {
  return RecordSchedule(
    id: id,
    start: DateTime.parse('2026-11-20T04:00:00+09:00'),
    durationSeconds: durationSeconds,
    conditionId: '1',
    channel: const ScheduleChannel(
      broadcastingType: 2,
      channelType: 2,
      serviceId: 56832,
    ),
    desiredQualityMode: 100,
    desiredMatchingId: '0x7880,0x7880,0xDE00,0x0000',
    reservationCreatorId: '2000',
    priorityFlag: priorityFlag,
    recordDestinationId: 'HDD',
    title: '既存の予約番組',
  );
}

class FakeDeviceInfo implements DeviceInfoService {
  FakeDeviceInfo({List<HddEntry>? hddEntries, Map<int, HddInfo>? hddInfos})
    : hddEntries =
          hddEntries ??
          const [
            HddEntry(id: 0, internal: true, mounted: true, registered: true),
          ],
      hddInfos =
          hddInfos ??
          const {
            0: HddInfo(
              id: 0,
              internal: true,
              format: 'xfs',
              name: '内蔵HDD',
              usedBytes: 300000000000,
              freeBytes: 200000000000,
              totalBytes: 500000000000,
            ),
          };

  final List<HddEntry> hddEntries;
  final Map<int, HddInfo> hddInfos;

  /// Ids passed to [getHddInfo], in call order.
  final List<int> hddInfoCalls = [];

  @override
  Future<DeviceInfo> getDeviceInfo() async => const DeviceInfo(
    name: 'テストnasne',
    softwareVersion: '0260',
    currDate: '2026-11-16T15:00:00+09:00',
    pref: '東京都',
  );

  @override
  Future<List<HddEntry>> listHdds() async => hddEntries;

  @override
  Future<HddInfo> getHddInfo(int id) async {
    hddInfoCalls.add(id);
    final info = hddInfos[id];
    if (info == null) {
      throw NasneError.http(404, 'fake:/status/HDDInfoGet');
    }
    return info;
  }

  @override
  Future<NetworkInfo> getNetworkInfo() async => const NetworkInfo(
    macAddr: '00:11:22:33:44:55',
    ipv4Addr: '192.0.2.10',
    gateway: '192.0.2.1',
    dhcpEnabled: true,
  );

  @override
  Future<BcasInfo> getBcasInfo() async =>
      const BcasInfo(cardId: '0000123456789999', status: 'OK');

  @override
  Future<List<Channel>> listChannels(int broadcastingType) async => const [
    testChannel,
  ];

  @override
  Future<LiveStatus> getLiveStatus() async =>
      const LiveStatus(sections: {}, raw: {});

  @override
  Future<List<RecNgItem>> listRecNg() async => const [];

  @override
  Future<ClientInfo> getClientInfo() async => const ClientInfo();
}

class FakeSchedules implements ScheduleService {
  FakeSchedules([List<RecordSchedule>? initial])
    : items = [
        ...initial ?? [sampleSchedule()],
      ];

  final List<RecordSchedule> items;
  List<RecordSchedule> conflictsToReturn = const [];
  ScheduleUpdate? lastUpdate;
  NewRecordSchedule? lastCreated;
  int _nextId = 200;

  @override
  Future<List<RecordSchedule>> listSchedules({
    int startingIndex = 0,
    int requestedCount = 50,
  }) async => [...items];

  @override
  Future<String> createSchedule(NewRecordSchedule schedule) async {
    lastCreated = schedule;
    final id = '${_nextId++}';
    items.add(
      RecordSchedule(
        id: id,
        start: schedule.start,
        durationSeconds: schedule.durationSeconds,
        conditionId: '1',
        channel: schedule.channel,
        desiredQualityMode: schedule.desiredQualityMode,
        desiredMatchingId: schedule.desiredMatchingId,
        reservationCreatorId: schedule.reservationCreatorId,
        priorityFlag: schedule.priorityFlag,
        recordDestinationId: schedule.recordDestinationId,
      ),
    );
    return id;
  }

  @override
  Future<void> updateSchedule(ScheduleUpdate update) async {
    lastUpdate = update;
    final i = items.indexWhere((s) => s.id == update.id);
    if (i < 0) return;
    final old = items[i];
    items[i] = RecordSchedule(
      id: old.id,
      start: old.start,
      durationSeconds: old.durationSeconds,
      conditionId: update.conditionId ?? old.conditionId,
      channel: old.channel,
      desiredQualityMode: update.desiredQualityMode ?? old.desiredQualityMode,
      desiredMatchingId: old.desiredMatchingId,
      reservationCreatorId: old.reservationCreatorId,
      priorityFlag: update.priorityFlag,
      recordDestinationId:
          update.recordDestinationId ?? old.recordDestinationId,
      title: old.title,
    );
  }

  @override
  Future<void> deleteSchedule(String id) async {
    items.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<RecordSchedule>> checkConflicts(
    NewRecordSchedule candidate,
  ) async => conflictsToReturn;
}

class FakeTitles implements TitleCatalogService {
  FakeTitles({
    List<RecordedTitle>? items,
    Map<String, List<int>>? thumbnails,
    this.deleteRefusesAsProtected = false,
    this.protectionListLags = false,
    this.protectionUpdateFails = false,
    this.resumeReportFails = false,
    this.progressive = false,
  }) : items = List.of(items ?? defaultItems),
       thumbnails = thumbnails ?? const {};

  final List<RecordedTitle> items;
  final Map<String, List<int>> thumbnails;
  final List<String> deletedIds = [];
  final List<(String, bool)> protectionChanges = [];

  /// How many times a (progressive) list load was started. A
  /// protection toggle must not start another one (plan 103).
  int listLoadCount = 0;

  /// When true, deleteTitle answers the way the unit answers
  /// for a title protected after the list was fetched (UPnP
  /// error 877, plan 86.3).
  final bool deleteRefusesAsProtected;

  /// When true, a protection update is accepted (and recorded)
  /// but the listed items keep the pre-update flag — the way
  /// the unit's title list can lag its own update, so the
  /// refetch right after the update still carries the old flag
  /// (device-observed after plan 98).
  final bool protectionListLags;

  /// When true, a protection update fails with a SOAP fault.
  final bool protectionUpdateFails;

  /// When true, a resume position report fails the way the
  /// unit refuses one (a WebAPI errorcode, plan 102), so the
  /// displayed position must keep the pre-report value
  /// (plan 104 follow-up).
  final bool resumeReportFails;

  static final defaultItems = [
    RecordedTitle(
      id: '201',
      title: '録画タイトルA',
      scheduledStart: DateTime.parse('2026-11-15T11:34:46+09:00'),
      scheduledDurationSeconds: 1800,
      channelName: 'テスト放送',
      copyCountRemaining: 10,
      protectFlag: true,
      description: '番組Aの概要',
      res: const [
        TitleRes(
          url: 'http://192.0.2.10:58890/web/video/pvr?id=201&quality=dr',
          protocolInfo: 'http-get:*:application/x-dtcp1:*',
          cleartextSize: 100000000,
          quality: 'dr',
        ),
      ],
    ),
    RecordedTitle(
      id: '202',
      title: '録画タイトルB',
      scheduledStart: DateTime.parse('2026-11-15T12:00:00+09:00'),
      scheduledDurationSeconds: 3600,
      channelName: 'テスト放送',
      copyCountRemaining: 3,
      newFlag: true,
    ),
  ];

  @override
  Future<List<RecordedTitle>> listTitles({bool withMetadata = true}) async =>
      items;

  /// When true, the progressive load is driven by the test
  /// through [progressController] instead of completing at
  /// once (plan 100).
  final bool progressive;

  /// Stages the test feeds to a progressive load.
  final StreamController<TitleListProgress> progressController =
      StreamController<TitleListProgress>();

  @override
  Stream<TitleListProgress> listTitlesProgressively({
    bool withMetadata = true,
  }) {
    listLoadCount++;
    if (progressive) return progressController.stream;
    return Stream.value(TitleListProgress(List.of(items), complete: true));
  }

  @override
  Future<int> countTitles() async => items.length;

  @override
  Future<int> maxTitles() async => 3000;

  @override
  Future<void> deleteTitle(String id) async {
    if (deleteRefusesAsProtected) {
      throw NasneError.soapFault(
        errorCode: '877',
        errorDescription: 'Action X_DeleteTitle failed',
        source: 'soap:X_DeleteTitle',
      );
    }
    deletedIds.add(id);
    items.removeWhere((t) => t.id == id);
  }

  @override
  Future<void> setTitleProtection(
    RecordedTitle title, {
    required bool protect,
  }) async {
    if (protectionUpdateFails) {
      throw NasneError.soapFault(
        errorCode: '500',
        errorDescription: 'Action X_UpdateTitle failed',
        source: 'soap:X_UpdateTitle',
      );
    }
    protectionChanges.add((title.id, protect));
    if (protectionListLags) return;
    final i = items.indexWhere((t) => t.id == title.id);
    if (i >= 0) items[i] = items[i].withProtectFlag(protect);
  }

  @override
  Future<Uint8List?> fetchThumbnail(String id) async {
    final bytes = thumbnails[id];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  /// Resume positions reported by a closing player (plan 102).
  final List<(String, Duration)> resumePositions = [];

  @override
  Future<void> setResumePosition(String id, Duration position) async {
    if (resumeReportFails) {
      throw NasneError.webapi(803, 'test:recordedContentResumePositionSet');
    }
    resumePositions.add((id, position));
  }

  /// Chapter points [fetchChapters] answers per title id
  /// (plan 112); a title absent from the map has none.
  final Map<String, List<Duration>> chaptersByTitle = {};

  @override
  Future<List<Duration>> fetchChapters(
    String id, {
    required int durationSeconds,
  }) async => chaptersByTitle[id] ?? const [];
}

/// Records the res it was asked to play, then fails with a
/// validation error so the detail view shows the credential
/// guidance dialog instead of navigating to the player screen
/// (plan 33).
class RecordingPlaybackEngine implements PlaybackEngine {
  RecordedTitle? lastTitle;
  TitleRes? lastRes;
  int startCalls = 0;
  LiveChannel? lastLiveChannel;
  TitleRes? lastLiveRes;
  int liveStartCalls = 0;

  /// When set, startPlayback waits on this gate before failing,
  /// simulating a start that is still in flight (plan 35).
  Completer<void>? startGate;

  @override
  bool get isSupported => true;

  @override
  Future<PlaybackSession> startPlayback(
    RecordedTitle title,
    TitleRes res,
  ) async {
    startCalls++;
    lastTitle = title;
    lastRes = res;
    final gate = startGate;
    if (gate != null) await gate.future;
    throw NasneError.validation('test:playback', 'テスト用の検証エラー');
  }

  @override
  Future<PlaybackSession> startLivePlayback(
    LiveChannel channel,
    TitleRes res,
  ) async {
    liveStartCalls++;
    lastLiveChannel = channel;
    lastLiveRes = res;
    final gate = startGate;
    if (gate != null) await gate.future;
    throw NasneError.validation('test:playback', 'テスト用の検証エラー');
  }
}

/// Two terrestrial live channels (plan 39): the first offers a
/// mobile resource alongside the original, the second does not.
/// They sit on different transport streams, so neither is the
/// other's subchannel (plan 95: the guide's subchannel switch
/// applies to this list, and these tests are about the detail
/// view, not about subchannel hiding).
class FakeLiveCatalog implements LiveCatalogService {
  static TitleRes liveRes(String svid, String quality) => TitleRes(
    url:
        'http://192.0.2.10:58890/web/video/ch?nid=7880&tsid=7880'
        '&svid=$svid&quality=$quality',
    protocolInfo: 'http-get:*:application/x-dtcp1:*',
    quality: quality,
  );

  static final bands = [
    LiveBand(
      containerId: '0/video/LiveTuner/DTTB',
      title: '地上デジタル',
      channels: [
        LiveChannel(
          id: '0/video/LiveTuner/DTTB/ch?nid=7880&tsid=7880&svid=de00',
          bandId: '0/video/LiveTuner/DTTB',
          networkId: 0x7880,
          transportStreamId: 0x7880,
          serviceId: 0xde00,
          channelName: 'テスト放送１',
          genre: 'ニュース／報道',
          programTitle: 'ライブ番組A',
          description: 'ライブ概要A',
          programStart: DateTime.parse('2026-11-17T14:05:00+09:00'),
          programEnd: DateTime.parse('2026-11-17T14:50:00+09:00'),
          res: [liveRes('de00', 'dr'), liveRes('de00', 'mobile')],
        ),
        LiveChannel(
          id: '0/video/LiveTuner/DTTB/ch?nid=7880&tsid=7881&svid=de08',
          bandId: '0/video/LiveTuner/DTTB',
          networkId: 0x7880,
          transportStreamId: 0x7881,
          serviceId: 0xde08,
          channelName: 'テスト放送２',
          programTitle: 'ライブ番組B',
          res: [liveRes('de08', 'dr')],
        ),
      ],
    ),
  ];

  @override
  Future<List<LiveBand>> listLiveChannels() async => bands;
}

class FakeSettings implements SettingsService {
  @override
  Future<String> getBoxName() async => 'テストnasne';

  @override
  Future<int> getMobileBitrate() async => 0;

  @override
  Future<void> setBoxName(String name) async {}

  @override
  Future<void> setMobileBitrate(int bitrateInfo) async {}
}

class FakeMetadata implements MetadataService {
  @override
  Future<DidlDocument> browse(String objectId) async =>
      const DidlDocument(containers: [], items: []);

  @override
  Future<EpgGuide> getProgrammeGuide(
    int broadcastingType,
    List<Channel> channels,
  ) async => EpgGuide(broadcastingType: broadcastingType, services: const []);

  @override
  Future<Map<int, List<int>>> getChannelLogos(int broadcastingType) async =>
      const {};
}

class FakeDiscovery implements DiscoveryService {
  @override
  Future<List<NasneDevice>> discover({Duration? timeout}) async => [
    NasneDevice.direct('192.0.2.20'),
  ];

  @override
  Future<NasneDevice> describe(Uri location) async =>
      NasneDevice.direct(location.host);
}

class FakeRegistration implements RegistrationService {
  @override
  Future<RegisteredNasne> register(NasneDevice device) async => RegisteredNasne(
    host: device.host,
    udn: 'uuid:new',
    friendlyName: 'nasne',
    macAddr: '00:11:22:33:44:55',
  );

  @override
  Future<bool> verify(RegisteredNasne registration) async => true;
}

/// One title carrying a resume point (plan 104 follow-up):
/// the unit recorded six minutes watched, so the detail
/// shows the position and offers a resume.
List<RecordedTitle> resumeTitles() => [
  RecordedTitle(
    id: '201',
    title: '録画タイトルA',
    scheduledStart: DateTime.parse('2026-11-15T11:34:46+09:00'),
    scheduledDurationSeconds: 1800,
    channelName: 'テスト放送',
    copyCountRemaining: 10,
    lastPlaybackTime: DateTime.parse('2026-11-21T21:00:00+09:00'),
    resumePointSeconds: 360,
  ),
];

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class Fixture {
  Fixture({
    List<RegisteredNasne>? registrations,
    FakeSchedules? schedules,
    FakeDeviceInfo? deviceInfo,
    this.titles,
    this.playback,
    this.thumbnails,
    this.titlesDeleteRefusesAsProtected = false,
    this.titlesProtectionListLags = false,
    this.titlesProtectionUpdateFails = false,
    this.titlesResumeReportFails = false,
    this.titlesProgressive = false,
  }) : schedules = schedules ?? FakeSchedules(),
       deviceInfo = deviceInfo ?? FakeDeviceInfo(),
       store = InMemoryRegistrationStore(registrations ?? [testReg]),
       titlesService = FakeTitles(
         items: titles,
         thumbnails: thumbnails,
         deleteRefusesAsProtected: titlesDeleteRefusesAsProtected,
         protectionListLags: titlesProtectionListLags,
         protectionUpdateFails: titlesProtectionUpdateFails,
         resumeReportFails: titlesResumeReportFails,
         progressive: titlesProgressive,
       );

  final FakeSchedules schedules;
  final FakeDeviceInfo deviceInfo;
  final InMemoryRegistrationStore store;

  /// The app's key-value store, exposed so tests can seed and
  /// inspect persisted settings (e.g. the saved playback quality).
  final InMemoryKeyValueStore keyValues = InMemoryKeyValueStore();
  final List<RecordedTitle>? titles;
  final PlaybackEngine? playback;
  final Map<String, List<int>>? thumbnails;
  final bool titlesDeleteRefusesAsProtected;
  final bool titlesProtectionListLags;
  final bool titlesProtectionUpdateFails;
  final bool titlesResumeReportFails;
  final bool titlesProgressive;
  final FakeTitles titlesService;

  Widget app() {
    final bundle = DeviceServices(
      deviceInfo: deviceInfo,
      settings: FakeSettings(),
      schedules: schedules,
      titles: titlesService,
      metadata: FakeMetadata(),
      live: FakeLiveCatalog(),
      playback: playback ?? const UnsupportedPlaybackEngine(),
    );
    return ProviderScope(
      overrides: [
        registrationStoreProvider.overrideWithValue(store),
        keyValueStoreProvider.overrideWithValue(keyValues),
        deviceServicesProvider.overrideWith((ref, reg) => bundle),
        discoveryServiceProvider.overrideWithValue(FakeDiscovery()),
        registrationServiceProvider.overrideWithValue(FakeRegistration()),
      ],
      child: const TmhbApp(),
    );
  }
}

void usePhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void useTabletSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1180, 820);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Pumps a few frames without waiting on snackbar timers.
Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

void main() {
  testWidgets('home shows device summary, HDD usage and no messages', (
    tester,
  ) async {
    usePhoneSize(tester);
    await tester.pumpWidget(Fixture().app());
    await tester.pumpAndSettle();

    expect(find.text('テストnasne'), findsOneWidget);
    expect(find.textContaining('空き'), findsOneWidget);
    expect(find.text('メッセージはありません'), findsOneWidget);
    expect(find.text('録画失敗はありません'), findsOneWidget);
  });

  testWidgets('home labels the internal HDD by id, not the inverted flag', (
    tester,
  ) async {
    usePhoneSize(tester);
    // The measured HDDListGet shape (plan 89.8/116): the internal
    // drive (id 0) reports internalFlag 0 and its detail name is
    // 'hdd0'. The label must still be the internal one.
    final deviceInfo = FakeDeviceInfo(
      hddEntries: const [
        HddEntry(id: 0, internal: false, mounted: true, registered: true),
      ],
      hddInfos: const {
        0: HddInfo(
          id: 0,
          internal: false,
          format: 'xfs',
          name: 'hdd0',
          usedBytes: 448000000000,
          freeBytes: 16600000000,
          totalBytes: 464600000000,
        ),
      },
    );
    await tester.pumpWidget(Fixture(deviceInfo: deviceInfo).app());
    await tester.pumpAndSettle();

    expect(find.text('内蔵 HDD: hdd0'), findsOneWidget);
    expect(find.text('外付け HDD: hdd0'), findsNothing);
  });

  testWidgets('home shows an unconnected external HDD as not connected', (
    tester,
  ) async {
    usePhoneSize(tester);
    // Internal drive plus an external entry with nothing
    // connected (plan 116): the external entry must render as
    // not connected, not as a failed "internal" detail fetch,
    // and its detail must not be queried at all.
    final deviceInfo = FakeDeviceInfo(
      hddEntries: const [
        HddEntry(id: 0, internal: false, mounted: true, registered: true),
        HddEntry(id: 1, internal: true, mounted: false, registered: false),
      ],
      hddInfos: const {
        0: HddInfo(
          id: 0,
          internal: false,
          format: 'xfs',
          name: 'hdd0',
          usedBytes: 448000000000,
          freeBytes: 16600000000,
          totalBytes: 464600000000,
        ),
      },
    );
    await tester.pumpWidget(Fixture(deviceInfo: deviceInfo).app());
    await tester.pumpAndSettle();

    expect(find.text('内蔵 HDD: hdd0'), findsOneWidget);
    expect(find.text('外付け HDD (未接続)'), findsOneWidget);
    expect(find.text('内蔵 HDD (詳細を取得できませんでした)'), findsNothing);
    expect(deviceInfo.hddInfoCalls, [0]);
  });

  testWidgets('schedules list shows the existing reservation', (tester) async {
    usePhoneSize(tester);
    await tester.pumpWidget(Fixture().app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('予約'));
    await tester.pumpAndSettle();

    expect(find.textContaining('既存の予約番組'), findsOneWidget);
    expect(find.textContaining('テスト放送'), findsWidgets);
  });

  testWidgets('create flow adds a reservation', (tester) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('予約'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新規予約'));
    await tester.pumpAndSettle();

    expect(find.text('新規予約'), findsWidgets);
    await tester.tap(find.text('予約を作成'));
    await pumpFrames(tester);

    expect(fixture.schedules.items, hasLength(2));
    expect(fixture.schedules.lastCreated, isNotNull);
    // Back on the list, both reservations are shown.
    expect(find.byType(ListTile), findsNWidgets(2));
  });

  testWidgets('conflict warning can be accepted', (tester) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    fixture.schedules.conflictsToReturn = [sampleSchedule(id: '101')];
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('予約'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新規予約'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('予約を作成'));
    await pumpFrames(tester);

    expect(find.text('競合する予約があります'), findsOneWidget);
    expect(fixture.schedules.items, hasLength(1));

    await tester.tap(find.text('このまま作成'));
    await pumpFrames(tester);
    expect(fixture.schedules.items, hasLength(2));
  });

  testWidgets('delete flow removes the reservation', (tester) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('予約'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('既存の予約番組'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    expect(find.text('予約を削除'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('削除')),
    );
    await pumpFrames(tester);

    expect(fixture.schedules.items, isEmpty);
    expect(find.text('予約はありません'), findsOneWidget);
  });

  testWidgets('edit flow sends a sparse update with priorityFlag', (
    tester,
  ) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('予約'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('既存の予約番組'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('優先フラグ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新する'));
    await pumpFrames(tester);

    expect(fixture.schedules.lastUpdate, isNotNull);
    expect(fixture.schedules.lastUpdate!.id, '101');
    expect(fixture.schedules.lastUpdate!.priorityFlag, 1);
    expect(fixture.schedules.lastUpdate!.hasChangeField, isTrue);
  });

  testWidgets('time change replaces the reservation (delete + create)', (
    tester,
  ) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('予約'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('既存の予約番組'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('時刻を変更'));
    await tester.pumpAndSettle();

    // Change the duration from 30 to 45 minutes.
    await tester.enterText(find.byType(TextField), '45');
    await tester.tap(find.text('予約を作成'));
    await pumpFrames(tester);

    expect(fixture.schedules.items, hasLength(1));
    expect(fixture.schedules.items.single.id, isNot('101'));
    expect(fixture.schedules.items.single.durationSeconds, 2700);
  });

  testWidgets('titles list shows copy counts; playback shows the notice', (
    tester,
  ) async {
    usePhoneSize(tester);
    await tester.pumpWidget(Fixture().app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();

    expect(find.text('録画タイトルA'), findsOneWidget);
    expect(find.text('残り 10 回'), findsOneWidget);
    expect(find.textContaining('全 2 件'), findsOneWidget);

    await tester.tap(find.text('録画タイトルA'));
    await tester.pumpAndSettle();
    expect(find.text('番組Aの概要'), findsOneWidget);

    await tester.tap(find.text('再生'));
    await tester.pumpAndSettle();
    expect(find.text('再生は未実装です'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets('title rows show thumbnails when provided (plan 86.6)', (
    tester,
  ) async {
    usePhoneSize(tester);
    // A 1x1 transparent PNG.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
      'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    final fixture = Fixture(thumbnails: {'201': png});
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();

    // Title A (201) has a thumbnail image; title B keeps the icon.
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
  });

  testWidgets('title list search and unwatched filter (plan 86.5)', (
    tester,
  ) async {
    usePhoneSize(tester);
    final fixture = Fixture(
      titles: [
        RecordedTitle(
          id: '301',
          title: 'ニュース番組',
          scheduledStart: DateTime.parse('2026-11-15T11:00:00+09:00'),
          channelName: 'テスト放送',
          genre: 'ニュース／報道',
        ),
        RecordedTitle(
          id: '302',
          title: 'アニメ番組',
          scheduledStart: DateTime.parse('2026-11-15T12:00:00+09:00'),
          channelName: '別放送',
          genre: 'アニメ／特撮',
          newFlag: true,
        ),
      ],
    );
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    expect(find.text('ニュース番組'), findsOneWidget);
    expect(find.text('アニメ番組'), findsOneWidget);

    // Search narrows the list to the matching title.
    await tester.enterText(find.byType(TextField), 'アニメ');
    await tester.pumpAndSettle();
    expect(find.text('ニュース番組'), findsNothing);
    expect(find.text('アニメ番組'), findsOneWidget);
    expect(find.text('条件に合うのは 1 件'), findsOneWidget);

    // Clearing the conditions restores both titles.
    await tester.tap(find.text('条件をクリア'));
    await tester.pumpAndSettle();
    expect(find.text('ニュース番組'), findsOneWidget);
    expect(find.text('アニメ番組'), findsOneWidget);

    // The unwatched-only chip keeps only the new-flagged title.
    await tester.tap(find.text('未視聴のみ'));
    await tester.pumpAndSettle();
    expect(find.text('ニュース番組'), findsNothing);
    expect(find.text('アニメ番組'), findsOneWidget);
  });

  testWidgets('title list shows the first chunk while the rest '
      'is still loading (plan 100)', (tester) async {
    usePhoneSize(tester);
    final fixture = Fixture(titlesProgressive: true);
    // No pumpAndSettle anywhere in this test: the shell keeps
    // every tab built, so the titles spinner is animating from
    // the start and the test drives frames by hand.
    await tester.pumpWidget(fixture.app());
    await pumpFrames(tester);

    await tester.tap(find.text('録画済み'));
    await tester.pump();

    // Nothing has arrived yet: no rows.
    expect(find.text('録画タイトルA'), findsNothing);
    expect(find.text('録画タイトルB'), findsNothing);

    // The first chunk arrives: its row shows at once, and the
    // header says the load is still going.
    fixture.titlesService.progressController.add(
      TitleListProgress([FakeTitles.defaultItems.first], complete: false),
    );
    await tester.pump();
    expect(find.text('録画タイトルA'), findsOneWidget);
    expect(find.text('録画タイトルB'), findsNothing);
    expect(find.textContaining('読み込み中'), findsWidgets);

    // The complete stage lands: every row, and the loading
    // note is gone.
    fixture.titlesService.progressController.add(
      TitleListProgress(FakeTitles.defaultItems, complete: true),
    );
    await tester.pump();
    expect(find.text('録画タイトルA'), findsOneWidget);
    expect(find.text('録画タイトルB'), findsOneWidget);
    expect(find.textContaining('読み込み中'), findsNothing);
  });

  testWidgets('a search with no hit yet shows as still loading, '
      'not as no match (plan 100)', (tester) async {
    usePhoneSize(tester);
    final fixture = Fixture(titlesProgressive: true);
    await tester.pumpWidget(fixture.app());
    await pumpFrames(tester);

    await tester.tap(find.text('録画済み'));
    await tester.pump();
    fixture.titlesService.progressController.add(
      TitleListProgress([FakeTitles.defaultItems.first], complete: false),
    );
    await tester.pump();
    expect(find.text('録画タイトルA'), findsOneWidget);

    // Search for the title that has not arrived yet: while
    // the load is incomplete this must not settle as "no
    // match". (The row is found through its ListTile — the
    // search field itself also carries the query text.)
    await tester.enterText(find.byType(TextField), '録画タイトルB');
    await tester.pump();
    expect(find.text('条件に合うタイトルがありません'), findsNothing);
    expect(find.textContaining('読み込み中'), findsWidgets);

    // Once the complete stage arrives, the hit shows and the
    // count is stated as final.
    fixture.titlesService.progressController.add(
      TitleListProgress(FakeTitles.defaultItems, complete: true),
    );
    await tester.pump();
    expect(
      find.widgetWithText(ListTile, '録画タイトルB'),
      findsOneWidget,
    );
    expect(find.text('条件に合うのは 1 件'), findsOneWidget);
    expect(find.textContaining('読み込み中'), findsNothing);
  });

  testWidgets('a protected title cannot be deleted (plan 86.3)', (
    tester,
  ) async {
    usePhoneSize(tester);
    await tester.pumpWidget(Fixture().app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('録画タイトルA'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('このタイトルを削除'));
    await tester.pumpAndSettle();

    expect(find.text('削除できません'), findsOneWidget);
    expect(find.text('このタイトルは保護されているため削除できません。'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets('an unprotected title is deleted after confirmation '
      '(plan 86.3)', (tester) async {
    usePhoneSize(tester);
    await tester.pumpWidget(Fixture().app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('録画タイトルB'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('このタイトルを削除'));
    await tester.pumpAndSettle();

    expect(find.text('タイトルを削除'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.pumpAndSettle();

    // Back on the list, with the title gone and the count updated.
    expect(find.text('録画タイトルB'), findsNothing);
    expect(find.text('録画タイトルA'), findsOneWidget);
    expect(find.textContaining('全 1 件'), findsOneWidget);
  });

  testWidgets('protection can be switched on from the detail (plan 98)', (
    tester,
  ) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('録画タイトルB'));
    await tester.pumpAndSettle();

    expect(find.text('なし'), findsOneWidget);
    final loadsBefore = fixture.titlesService.listLoadCount;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(fixture.titlesService.protectionChanges, [('202', true)]);
    // The detail reflects the flag rewritten in the loaded list
    // (plan 103) — no new list load was started for it.
    expect(fixture.titlesService.listLoadCount, loadsBefore);
    expect(find.text('保護あり'), findsOneWidget);
    expect(find.text('保護しました'), findsOneWidget);
  });

  testWidgets('protection can be switched off from the detail (plan 98)', (
    tester,
  ) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('録画タイトルA'));
    await tester.pumpAndSettle();

    expect(find.text('保護あり'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(fixture.titlesService.protectionChanges, [('201', false)]);
    expect(find.text('なし'), findsOneWidget);
    expect(find.text('保護を解除しました'), findsOneWidget);
  });

  testWidgets(
    'the protection switch settles at once even while the '
    'unit list still carries the old flag (plan 98 follow-up, '
    'plan 103)',
    (tester) async {
      usePhoneSize(tester);
      // The unit accepted the update, but its title list keeps
      // answering with the pre-update flag for a while. The
      // toggle no longer refetches at all (plan 103): the flag
      // is rewritten in the loaded list, so nothing the unit
      // answers afterwards can unsettle the switch.
      final fixture = Fixture(titlesProtectionListLags: true);
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('録画済み'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('録画タイトルB'));
      await tester.pumpAndSettle();

      expect(find.text('なし'), findsOneWidget);
      final loadsBefore = fixture.titlesService.listLoadCount;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(fixture.titlesService.protectionChanges, [('202', true)]);
      expect(fixture.titlesService.listLoadCount, loadsBefore);
      // The switch and its label reflect the successful update
      // immediately, without waiting for the list to catch up.
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('保護あり'), findsOneWidget);
      expect(find.text('保護しました'), findsOneWidget);
    },
  );

  testWidgets(
    'toggling protection updates the list row lock at once, '
    'without reloading the list (plan 103)',
    (tester) async {
      usePhoneSize(tester);
      final fixture = Fixture();
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('録画済み'));
      await tester.pumpAndSettle();
      // Only title A is protected: one lock in the list.
      expect(find.byIcon(Icons.lock), findsOneWidget);
      final loadsBefore = fixture.titlesService.listLoadCount;

      await tester.tap(find.text('録画タイトルB'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(fixture.titlesService.protectionChanges, [('202', true)]);

      // Back on the list, B's row carries the lock too — and
      // the list was never reloaded to learn it.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock), findsNWidgets(2));
      expect(fixture.titlesService.listLoadCount, loadsBefore);

      // Unprotecting removes the row's lock the same way.
      await tester.tap(find.text('録画タイトルB'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(fixture.titlesService.protectionChanges, [
        ('202', true),
        ('202', false),
      ]);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock), findsOneWidget);
      expect(fixture.titlesService.listLoadCount, loadsBefore);
    },
  );

  testWidgets(
    'a failed protection update leaves the switch unchanged '
    '(plan 98 follow-up)',
    (tester) async {
      usePhoneSize(tester);
      final fixture = Fixture(titlesProtectionUpdateFails: true);
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('録画済み'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('録画タイトルB'));
      await tester.pumpAndSettle();

      expect(find.text('なし'), findsOneWidget);
      final loadsBefore = fixture.titlesService.listLoadCount;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(fixture.titlesService.protectionChanges, isEmpty);
      expect(fixture.titlesService.listLoadCount, loadsBefore);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.text('なし'), findsOneWidget);
      expect(find.text('操作に失敗しました。'), findsOneWidget);
    },
  );

  testWidgets(
    'a resume report rewrites the detail position at once, '
    'without reloading the list (plan 104 follow-up)',
    (tester) async {
      usePhoneSize(tester);
      final fixture = Fixture(titles: resumeTitles());
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('録画済み'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('録画タイトルA'));
      await tester.pumpAndSettle();
      expect(find.text('再開位置'), findsOneWidget);
      expect(find.text('6分'), findsOneWidget);
      final loadsBefore = fixture.titlesService.listLoadCount;

      // What a closing player does (plan 102): the report
      // reaches the unit and the loaded list follows it, so
      // the detail the viewer returns to shows the position
      // that was just recorded.
      final ref =
          tester.element(find.byType(TitlesScreen, skipOffstage: false))
              as WidgetRef;
      await reportResumePosition(
        ref: ref,
        reg: testReg,
        titleId: '201',
        position: const Duration(minutes: 5),
      );
      await tester.pump();

      expect(fixture.titlesService.resumePositions, [
        ('201', const Duration(minutes: 5)),
      ]);
      expect(find.text('5分'), findsOneWidget);
      expect(find.text('6分'), findsNothing);
      expect(fixture.titlesService.listLoadCount, loadsBefore);
    },
  );

  testWidgets(
    'a completed viewing clears the detail resume position '
    '(plan 104 follow-up)',
    (tester) async {
      usePhoneSize(tester);
      final fixture = Fixture(titles: resumeTitles());
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('録画済み'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('録画タイトルA'));
      await tester.pumpAndSettle();
      expect(find.text('再開位置'), findsOneWidget);
      final loadsBefore = fixture.titlesService.listLoadCount;

      // A viewing that ran to the end reports zero, and the
      // detail stops offering a position.
      final ref =
          tester.element(find.byType(TitlesScreen, skipOffstage: false))
              as WidgetRef;
      await reportResumePosition(
        ref: ref,
        reg: testReg,
        titleId: '201',
        position: Duration.zero,
      );
      await tester.pump();

      expect(fixture.titlesService.resumePositions, [('201', Duration.zero)]);
      expect(find.text('再開位置'), findsNothing);
      expect(fixture.titlesService.listLoadCount, loadsBefore);
    },
  );

  testWidgets(
    'a failed resume report leaves the displayed position '
    'alone (plan 104 follow-up)',
    (tester) async {
      usePhoneSize(tester);
      final fixture = Fixture(
        titles: resumeTitles(),
        titlesResumeReportFails: true,
      );
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('録画済み'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('録画タイトルA'));
      await tester.pumpAndSettle();
      expect(find.text('6分'), findsOneWidget);
      final loadsBefore = fixture.titlesService.listLoadCount;

      final ref =
          tester.element(find.byType(TitlesScreen, skipOffstage: false))
              as WidgetRef;
      await expectLater(
        reportResumePosition(
          ref: ref,
          reg: testReg,
          titleId: '201',
          position: const Duration(minutes: 5),
        ),
        throwsA(isA<NasneError>()),
      );
      await tester.pump();

      expect(fixture.titlesService.resumePositions, isEmpty);
      expect(find.text('6分'), findsOneWidget);
      expect(fixture.titlesService.listLoadCount, loadsBefore);
    },
  );

  testWidgets('a delete the unit refuses with 877 is explained as protection '
      '(plan 98)', (tester) async {
    usePhoneSize(tester);
    final fixture = Fixture(titlesDeleteRefusesAsProtected: true);
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('録画タイトルB'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('このタイトルを削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.pumpAndSettle();

    expect(find.text('削除できません'), findsOneWidget);
    expect(find.text('このタイトルは保護されているため削除できません。'), findsOneWidget);
    expect(fixture.titlesService.deletedIds, isEmpty);
  });

  testWidgets('title detail with a mobile res always uses mobile quality '
      '(Fire TV fixed)', (tester) async {
    usePhoneSize(tester);
    final engine = RecordingPlaybackEngine();
    final fixture = Fixture(
      titles: [
        RecordedTitle(
          id: '301',
          title: 'モバイル付きタイトル',
          scheduledStart: DateTime.parse('2026-11-15T13:00:00+09:00'),
          scheduledDurationSeconds: 1800,
          channelName: 'テスト放送',
          copyCountRemaining: 10,
          res: const [
            TitleRes(
              url: 'http://192.0.2.10:58890/web/video/pvr?id=301&quality=dr',
              protocolInfo: 'http-get:*:application/x-dtcp1:*',
              cleartextSize: 200000000,
              quality: 'dr',
            ),
            TitleRes(
              url:
                  'http://192.0.2.10:58890/web/video/pvr?id=301&quality=mobile',
              protocolInfo: 'http-get:*:application/x-dtcp1:*',
              cleartextSize: 20000000,
              quality: 'mobile',
            ),
          ],
        ),
      ],
      playback: engine,
    );
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('モバイル付きタイトル'));
    await tester.pumpAndSettle();

    expect(find.text('画質: モバイル固定'), findsOneWidget);
    expect(find.byType(SegmentedButton<bool>), findsNothing);

    // Fire TV build always selects mobile when available.
    await tester.tap(find.text('再生'));
    await tester.pumpAndSettle();
    expect(engine.lastRes?.quality, 'mobile');
    expect(find.text('資格情報が必要です'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'title detail picks mobile even if stored quality was false',
    (tester) async {
      usePhoneSize(tester);
      final engine = RecordingPlaybackEngine();
      final fixture = Fixture(
        titles: [
          RecordedTitle(
            id: '301',
            title: 'モバイル付きタイトル',
            scheduledStart: DateTime.parse('2026-11-15T13:00:00+09:00'),
            scheduledDurationSeconds: 1800,
            channelName: 'テスト放送',
            copyCountRemaining: 10,
            res: const [
              TitleRes(
                url: 'http://192.0.2.10:58890/web/video/pvr?id=301&quality=dr',
                protocolInfo: 'http-get:*:application/x-dtcp1:*',
                cleartextSize: 200000000,
                quality: 'dr',
              ),
              TitleRes(
                url:
                    'http://192.0.2.10:58890/web/video/pvr?id=301&quality=mobile',
                protocolInfo: 'http-get:*:application/x-dtcp1:*',
                cleartextSize: 20000000,
                quality: 'mobile',
              ),
            ],
          ),
        ],
        playback: engine,
      );
      await fixture.keyValues.write('playback_use_mobile', 'false');
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('録画済み'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('モバイル付きタイトル'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('再生'));
      await tester.pumpAndSettle();
      expect(engine.lastRes?.quality, 'mobile');
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('title detail without a mobile res shows no quality choice '
      '(plan 33)', (tester) async {
    usePhoneSize(tester);
    final engine = RecordingPlaybackEngine();
    final fixture = Fixture(playback: engine);
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('録画タイトルA'));
    await tester.pumpAndSettle();

    expect(find.text('再生画質'), findsNothing);
    expect(find.text('モバイル'), findsNothing);

    await tester.tap(find.text('再生'));
    await tester.pumpAndSettle();
    expect(engine.lastRes?.quality, 'dr');
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets('a second tap while a start is in flight does not '
      'start playback twice (plan 35)', (tester) async {
    usePhoneSize(tester);
    final engine = RecordingPlaybackEngine()..startGate = Completer<void>();
    final fixture = Fixture(playback: engine);
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('録画済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('録画タイトルA'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('再生'));
    await tester.pump();
    expect(engine.startCalls, 1);

    // While the start is in flight the button is disabled, and
    // even a tap that lands starts nothing new.
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '再生'),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.text('再生'), warnIfMissed: false);
    await tester.pump();
    expect(engine.startCalls, 1);

    engine.startGate!.complete();
    await tester.pumpAndSettle();
    expect(engine.startCalls, 1);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets('settings discovery registers a found device', (tester) async {
    usePhoneSize(tester);
    final fixture = Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LAN 内の nasne を探す'));
    await tester.pumpAndSettle();

    expect(find.text('192.0.2.20'), findsOneWidget);
    final foundTile = find.ancestor(
      of: find.text('192.0.2.20'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(of: foundTile, matching: find.text('登録')));
    await pumpFrames(tester);

    expect(find.textContaining('192.0.2.20'), findsWidgets);
    final stored = await fixture.store.loadAll();
    expect(stored.map((r) => r.host), contains('192.0.2.20'));
  });

  testWidgets('wide layout uses a rail and a two-pane schedule detail', (
    tester,
  ) async {
    useTabletSize(tester);
    await tester.pumpWidget(Fixture().app());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.text('予約'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('既存の予約番組'));
    await tester.pumpAndSettle();

    // List and detail are both visible (no page push).
    expect(find.textContaining('既存の予約番組'), findsWidgets);
    expect(find.text('編集'), findsOneWidget);
    expect(find.text('時刻を変更'), findsOneWidget);
  });

  testWidgets('live tab lists bands and channels with the current '
      'programme (plan 39)', (tester) async {
    usePhoneSize(tester);
    await tester.pumpWidget(Fixture().app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('TV視聴'));
    await tester.pumpAndSettle();

    // One band only: no band heading and no tab bar (plan 95).
    expect(find.text('地上デジタル'), findsNothing);
    expect(find.text('テスト放送１'), findsOneWidget);
    expect(find.text('テスト放送２'), findsOneWidget);
    // The on-air programme and its time range ride in the subtitle.
    expect(find.textContaining('ライブ番組A'), findsOneWidget);
    expect(find.textContaining('14:05–14:50'), findsOneWidget);
  });

  testWidgets('live detail always uses mobile quality when available '
      '(Fire TV fixed)', (tester) async {
    usePhoneSize(tester);
    final engine = RecordingPlaybackEngine();
    final fixture = Fixture(playback: engine);
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('TV視聴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト放送１'));
    await tester.pumpAndSettle();

    expect(find.text('ライブ番組A'), findsWidgets);
    expect(find.text('画質: モバイル固定'), findsOneWidget);
    expect(find.byType(SegmentedButton<bool>), findsNothing);

    await tester.tap(find.text('視聴'));
    await tester.pumpAndSettle();
    expect(engine.liveStartCalls, 1);
    expect(engine.lastLiveChannel?.serviceId, 0xde00);
    expect(engine.lastLiveRes?.quality, 'mobile');
    expect(find.text('資格情報が必要です'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets('live detail without a mobile res shows no quality '
      'choice (plan 39)', (tester) async {
    usePhoneSize(tester);
    final engine = RecordingPlaybackEngine();
    final fixture = Fixture(playback: engine);
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('TV視聴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト放送２'));
    await tester.pumpAndSettle();

    expect(find.text('再生画質'), findsNothing);
    expect(find.text('モバイル'), findsNothing);

    await tester.tap(find.text('視聴'));
    await tester.pumpAndSettle();
    expect(engine.lastLiveRes?.quality, 'dr');
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });
}

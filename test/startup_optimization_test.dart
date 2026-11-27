/// Tests for startup optimization:
/// - Parallel device info reads & non-blocking /status/updateCheck isolation
/// - Isolate offload for heavy XSRS / DIDL XML parsing & AES thumbnail decoding
/// - Concurrent thumbnail fetch semaphore bound (<= 3)
/// - Startup tab preference persistence, pre-runApp preload, and Settings UI
/// - AppShell lazy tab mounting & Fire TV initial rail focus on custom startup tab
/// - Sequential post-startup prefetch gated after initial tab completion,
///   aborted on initial-tab error, and stopped when navigating away (e.g. player)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pointycastle/export.dart' hide Padding;
import 'package:tmhb/app/bootstrap.dart';
import 'package:tmhb/app/firetv_helper.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/app/state.dart';
import 'package:tmhb/app/ui_control_mode.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/core/parsing/thumbnail.dart';
import 'package:tmhb/ui/app_shell.dart';
import 'package:tmhb/ui/home_screen.dart';
import 'package:tmhb/ui/settings_screen.dart';

const RegisteredNasne _testReg = RegisteredNasne(
  host: '192.0.2.10',
  udn: 'uuid:startup-test',
  friendlyName: 'テストnasne',
  macAddr: '00:11:22:33:44:55',
);

const List<int> _testThumbnailKey = [
  0x33, 0xa4, 0x9d, 0x7b, 0x3d, 0x0f, 0x35, 0x84, //
  0x70, 0x27, 0x91, 0x7d, 0x64, 0x17, 0xdb, 0x54,
];

Uint8List _encryptTestThumbnailPayload(Uint8List plainUyvy) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV(
        KeyParameter(Uint8List.fromList(_testThumbnailKey)),
        Uint8List(16),
      ),
    );
  final encrypted = Uint8List(plainUyvy.length);
  for (var off = 0; off < plainUyvy.length; off += 16) {
    cipher.processBlock(plainUyvy, off, encrypted, off);
  }
  return encrypted;
}

String _soapListEnvelope({
  required String action,
  required String namespace,
  required String innerXml,
  required int numberReturned,
  required int totalMatches,
}) {
  final escaped = const HtmlEscape().convert(innerXml);
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body>'
      '<u:${action}Response xmlns:u="$namespace">'
      '<Result>$escaped</Result>'
      '<NumberReturned>$numberReturned</NumberReturned>'
      '<TotalMatches>$totalMatches</TotalMatches>'
      '</u:${action}Response>'
      '</s:Body>'
      '</s:Envelope>';
}

class _SpyMetadataService implements MetadataService {
  @override
  Future<DidlDocument> browse(String objectId) async =>
      const DidlDocument(containers: [], items: []);

  @override
  Future<Map<int, List<int>>> getChannelLogos(int broadcastingType) async =>
      const {};

  @override
  Future<EpgGuide> getProgrammeGuide(
    int broadcastingType,
    List<Channel> channels,
  ) async => EpgGuide(broadcastingType: broadcastingType, services: const []);
}

void main() {
  group('DeviceInfoService parallelization & updateCheck isolation', () {
    test('getDeviceInfo runs base 5 requests in parallel and skips updateCheck', () async {
      final seenPaths = <String>[];
      final barriers = <String, Completer<void>>{
        '/status/boxNameGet': Completer<void>(),
        '/status/softwareVersionGet': Completer<void>(),
        '/status/currDateGet': Completer<void>(),
        '/status/areaInfoGet': Completer<void>(),
        '/status/isFinishSetup': Completer<void>(),
      };
      var activeCount = 0;
      var maxConcurrent = 0;

      final client = MockClient((request) async {
        final path = request.url.path;
        seenPaths.add(path);
        activeCount++;
        maxConcurrent = math.max(maxConcurrent, activeCount);
        try {
          final gate = barriers[path];
          if (gate != null) {
            await gate.future;
          }
          final body = switch (path) {
            '/status/boxNameGet' => '{"errorcode":0,"name":"テストnasne"}',
            '/status/softwareVersionGet' =>
              '{"errorcode":0,"softwareVersion":"0260"}',
            '/status/currDateGet' =>
              '{"errorcode":0,"currDate":"2026-11-27T16:00:00+09:00"}',
            '/status/areaInfoGet' => '{"errorcode":0,"pref":"東京都"}',
            '/status/isFinishSetup' => '{"errorcode":0,"finishSetUpFlag":1}',
            _ => throw StateError('Unexpected path $path'),
          };
          return http.Response(
            body,
            200,
            headers: {'content-type': 'application/json'},
          );
        } finally {
          activeCount--;
        }
      });

      final service = WebApiDeviceInfoService(
        WebApiTransport(_testReg.host, client: client),
      );
      final future = service.getDeviceInfo();

      // Let all parallel requests enter the MockClient handler before completing any.
      await Future<void>.delayed(Duration.zero);
      expect(maxConcurrent, 5);
      expect(seenPaths, isNot(contains('/status/updateCheck')));

      for (final c in barriers.values) {
        c.complete();
      }
      final info = await future;
      expect(info.name, 'テストnasne');
      expect(info.softwareVersion, '0260');
      expect(info.pref, '東京都');
      expect(info.finishSetup, isTrue);
      expect(info.updateExists, isNull);
    });

    test('checkSoftwareUpdate returns true/false and returns null without retry on failure', () async {
      var attempts = 0;
      var mode = 'true';
      final client = MockClient((request) async {
        expect(request.url.path, '/status/updateCheck');
        attempts++;
        if (mode == 'true') {
          return http.Response('{"errorcode":0,"existFlag":1}', 200);
        }
        if (mode == 'false') {
          return http.Response('{"errorcode":0,"existFlag":0}', 200);
        }
        return http.Response('error', 503);
      });

      final service = WebApiDeviceInfoService(
        WebApiTransport(_testReg.host, client: client),
      );
      expect(await service.checkSoftwareUpdate(), isTrue);
      mode = 'false';
      expect(await service.checkSoftwareUpdate(), isFalse);
      mode = 'fail';
      attempts = 0;
      expect(await service.checkSoftwareUpdate(), isNull);
      expect(attempts, 1);
    });
  });

  group('HomeScreen non-blocking update check', () {
    testWidgets('shows device info immediately and appends update notice when update check completes', (
      tester,
    ) async {
      final updateCompleter = Completer<bool?>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
            deviceInfoProvider(_testReg).overrideWith(
              (ref) async => const DeviceInfo(
                name: 'テストnasne',
                softwareVersion: '0260',
                pref: '東京都',
              ),
            ),
            softwareUpdateAvailableProvider(_testReg).overrideWith(
              (ref) => updateCompleter.future,
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
          ],
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('テストnasne'), findsOneWidget);
      expect(find.text('ソフトウェア更新があります'), findsNothing);

      updateCompleter.complete(true);
      await tester.pump();
      await tester.pump();
      expect(find.text('ソフトウェア更新があります'), findsOneWidget);
    });

    testWidgets('does not fail device info card when update check returns null', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
            deviceInfoProvider(_testReg).overrideWith(
              (ref) async => const DeviceInfo(
                name: 'テストnasne',
                softwareVersion: '0260',
              ),
            ),
            softwareUpdateAvailableProvider(_testReg).overrideWith(
              (ref) async => null,
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
          ],
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('テストnasne'), findsOneWidget);
      expect(find.text('ソフトウェア更新があります'), findsNothing);
    });
  });

  group('Isolate offload & thumbnail concurrency bound', () {
    test('fetchThumbnail decrypts encrypted payload via Isolate and caps concurrency at 3', () async {
      final mapBytes = Uint8List(8);
      ByteData.sublistView(mapBytes).setUint32(0, 1, Endian.big);
      final plainUyvy = Uint8List(thumbnailPayloadSize);
      for (var i = 0; i < plainUyvy.length; i += 4) {
        plainUyvy[i] = 0x80;
        plainUyvy[i + 1] = 0xeb;
        plainUyvy[i + 2] = 0x80;
        plainUyvy[i + 3] = 0xeb;
      }
      final encryptedPayload = _encryptTestThumbnailPayload(plainUyvy);
      expect(decodeThumbnailPayload(encryptedPayload), isNotNull);

      var active = 0;
      var maxObserved = 0;
      final barriers = <Completer<void>>[];

      final client = MockClient((request) async {
        if (request.url.path == WebApiEndpoints.thumbnailMapGet.path) {
          active++;
          maxObserved = math.max(maxObserved, active);
          final gate = Completer<void>();
          barriers.add(gate);
          await gate.future;
          return http.Response.bytes(mapBytes, 200);
        }
        if (request.url.path ==
            WebApiEndpoints.recordedContentThumbnailGet.path) {
          try {
            return http.Response.bytes(encryptedPayload, 200);
          } finally {
            active--;
          }
        }
        throw StateError('Unexpected path: ${request.url.path}');
      });

      final webApi = WebApiTransport(_testReg.host, client: client);
      final catalog = SoapTitleCatalogService(
        soap: SoapTransport(client: client),
        xsrsControlUrl: Uri.parse('http://192.0.2.10:64230/XSRS'),
        webApi: webApi,
        metadata: _SpyMetadataService(),
      );

      final futures = [
        for (var i = 0; i < 8; i++) catalog.fetchThumbnail('t$i'),
      ];

      while (barriers.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(maxObserved, 3);
      expect(barriers.length, 3);

      // Drain batches without spinning forever.
      var released = 0;
      while (released < 8) {
        while (released >= barriers.length) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        barriers[released].complete();
        released++;
        await Future<void>.delayed(Duration.zero);
      }

      final results = await Future.wait(futures);
      expect(maxObserved, 3);
      expect(results.length, 8);
      for (final bmp in results) {
        expect(bmp, isNotNull);
        expect(bmp!.length, 54 + thumbnailWidth * thumbnailHeight * 3);
        expect(bmp[0], 0x42);
        expect(bmp[1], 0x4D);
      }
    });

    test('parses >= 16KB XSRS title XML and DIDL Browse XML via Isolate', () async {
      final xsrsItemsXml = [
        for (var i = 0; i < 80; i++)
          '<item id="title-$i">'
              '<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">テスト録画タイトル $i ${'あ' * 40}</dc:title>'
              '<scheduledStartDateTime>2026-11-27T10:00:00+09:00</scheduledStartDateTime>'
              '<scheduledDuration>1800</scheduledDuration>'
              '</item>',
      ].join();
      final xsrsDoc =
          '<?xml version="1.0"?><xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">$xsrsItemsXml</xsrs>';
      expect(xsrsDoc.length, greaterThanOrEqualTo(16384));

      final didlItemsXml = [
        for (var i = 0; i < 80; i++)
          '<item id="didl-$i" parentID="0/video/all" restricted="1">'
              '<dc:title>テスト録画タイトル $i ${'い' * 40}</dc:title>'
              '<upnp:channelName>テスト局</upnp:channelName>'
              '<res protocolInfo="http-get:*:video/mpeg:*">http://192.0.2.10:58888/item/$i</res>'
              '</item>',
      ].join();
      final didlDoc =
          '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" '
          'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">$didlItemsXml</DIDL-Lite>';
      expect(didlDoc.length, greaterThanOrEqualTo(16384));

      final client = MockClient((request) async {
        final action = request.headers['soapaction'] ?? '';
        if (action.contains('X_GetTitleList')) {
          return http.Response.bytes(
            utf8.encode(
              _soapListEnvelope(
                action: 'X_GetTitleList',
                namespace: 'urn:schemas-xsrs-org:service:X_ScheduledRecording:2',
                innerXml: xsrsDoc,
                numberReturned: 80,
                totalMatches: 80,
              ),
            ),
            200,
            headers: {'content-type': 'text/xml; charset=utf-8'},
          );
        }
        if (action.contains('Browse')) {
          return http.Response.bytes(
            utf8.encode(
              _soapListEnvelope(
                action: 'Browse',
                namespace: 'urn:schemas-upnp-org:service:ContentDirectory:1',
                innerXml: didlDoc,
                numberReturned: 80,
                totalMatches: 80,
              ),
            ),
            200,
            headers: {'content-type': 'text/xml; charset=utf-8'},
          );
        }
        throw StateError('Unexpected SOAP action: $action');
      });

      final soap = SoapTransport(client: client);
      final dlna = DlnaMetadataService(
        soap: soap,
        controlUrl: Uri.parse(
          'http://192.0.2.10:58888/MediaServer_ContentDirectory/control',
        ),
      );
      final browseDoc = await dlna.browse('0/video/all');
      expect(browseDoc.items.length, 80);

      final catalog = SoapTitleCatalogService(
        soap: soap,
        xsrsControlUrl: Uri.parse('http://192.0.2.10:64230/XSRS'),
        webApi: WebApiTransport(_testReg.host, client: client),
        metadata: _SpyMetadataService(),
      );
      final titles = await catalog.listTitles(withMetadata: false);
      expect(titles.length, 80);
      expect(titles.first.id, 'title-0');
    });
  });

  group('StartupTabPreference & Settings UI', () {
    test('tabIndex matches AppTabs and loadInitialStartupTab handles file/missing/invalid', () async {
      expect(StartupTabPreference.home.tabIndex, AppTabs.home);
      expect(StartupTabPreference.live.tabIndex, AppTabs.live);
      expect(StartupTabPreference.schedules.tabIndex, AppTabs.schedules);
      expect(StartupTabPreference.titles.tabIndex, AppTabs.titles);
      expect(StartupTabPreference.epg.tabIndex, AppTabs.epg);

      final tmpDir = await Directory.systemTemp.createTemp('tmhb_startup_test_');
      try {
        expect(await loadInitialStartupTab(tmpDir), StartupTabPreference.home);

        final kvFile = File('${tmpDir.path}/$keyValueFileName');
        await kvFile.writeAsString(
          jsonEncode({StartupTabPreferenceNotifier.storageKey: 'live'}),
        );
        expect(await loadInitialStartupTab(tmpDir), StartupTabPreference.live);

        await kvFile.writeAsString(
          jsonEncode({StartupTabPreferenceNotifier.storageKey: 'unknown_value'}),
        );
        expect(await loadInitialStartupTab(tmpDir), StartupTabPreference.home);
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    testWidgets('SettingsScreen updates startupTabPreferenceProvider without switching current tab', (
      tester,
    ) async {
      final kv = InMemoryKeyValueStore();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            keyValueStoreProvider.overrideWithValue(kv),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: SettingsScreen());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('起動時に開く画面'), 200);
      expect(find.text('起動時に開く画面'), findsOneWidget);
      await tester.tap(find.text('起動時に開く画面'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('TV視聴'));
      await tester.pumpAndSettle();

      expect(
        container.read(startupTabPreferenceProvider),
        StartupTabPreference.live,
      );
      expect(
        await kv.read(StartupTabPreferenceNotifier.storageKey),
        'live',
      );
      expect(container.read(tabIndexProvider), AppTabs.home);
    });
  });

  group('AppShell lazy mounting & sequential prefetch', () {
    testWidgets('home boot mounts only Home initially and preserves visited tabs across switches', (
      tester,
    ) async {
      var deviceInfoCalls = 0;
      var liveCalls = 0;
      var scheduleCalls = 0;
      var titleCalls = 0;
      var epgCalls = 0;

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
            fireTvHelperProvider.overrideWithValue(
              FireTvHelper(isAndroidOverride: false, isTvOverride: false),
            ),
            deviceInfoProvider(_testReg).overrideWith((ref) async {
              deviceInfoCalls++;
              return const DeviceInfo(
                name: 'テストnasne',
                softwareVersion: '0260',
              );
            }),
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
            liveChannelsProvider(_testReg).overrideWith((ref) async {
              liveCalls++;
              return const <LiveBand>[];
            }),
            schedulesProvider(_testReg).overrideWith((ref) async {
              scheduleCalls++;
              return const <RecordSchedule>[];
            }),
            titlesProvider(_testReg).overrideWith(() {
              titleCalls++;
              return _CountingTitlesNotifier(_testReg);
            }),
            epgGuideProvider(_testReg).overrideWith((ref) async {
              epgCalls++;
              return const EpgGuide(broadcastingType: 2, services: []);
            }),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: AppShell());
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(deviceInfoCalls, 1);
      expect(liveCalls, 0);
      expect(scheduleCalls, 0);
      expect(titleCalls, 0);
      expect(epgCalls, 0);

      // Switch to Live tab -> Live loads, others remain unmounted.
      container.read(tabIndexProvider.notifier).select(AppTabs.live);
      await tester.pump();
      await tester.pump();
      expect(liveCalls, 1);
      expect(scheduleCalls, 1); // Live watches schedulesProvider for recording badges
      expect(titleCalls, 0);
      expect(epgCalls, 0);

      // Return to Home and back to Live -> stays mounted, no duplicate refetch.
      container.read(tabIndexProvider.notifier).select(AppTabs.home);
      await tester.pump();
      container.read(tabIndexProvider.notifier).select(AppTabs.live);
      await tester.pump();
      expect(deviceInfoCalls, 1);
    });

    testWidgets('boots directly on Live tab without touching Home and focuses Live in TV rail', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var deviceInfoCalls = 0;
      var liveCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialStartupTabProvider.overrideWithValue(
              StartupTabPreference.live,
            ),
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
            fireTvHelperProvider.overrideWithValue(
              FireTvHelper(isAndroidOverride: false, isTvOverride: true),
            ),
            defaultTargetUiControlModeProvider.overrideWithValue(
              UiControlMode.tv,
            ),
            deviceInfoProvider(_testReg).overrideWith((ref) async {
              deviceInfoCalls++;
              return const DeviceInfo(
                name: 'テストnasne',
                softwareVersion: '0260',
              );
            }),
            liveChannelsProvider(_testReg).overrideWith((ref) async {
              liveCalls++;
              return const <LiveBand>[];
            }),
            schedulesProvider(_testReg).overrideWith(
              (ref) async => const <RecordSchedule>[],
            ),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      expect(liveCalls, 1);
      expect(deviceInfoCalls, 0);

      final railFocused = FocusManager.instance.primaryFocus?.context;
      expect(railFocused, isNotNull);
      expect(
        find.descendant(
          of: find.byWidget(railFocused!.widget),
          matching: find.text('TV視聴'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('prefetcher waits for initial tab then fetches remaining tabs sequentially', (
      tester,
    ) async {
      final liveGate = Completer<List<LiveBand>>();
      final callOrder = <String>[];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialStartupTabProvider.overrideWithValue(
              StartupTabPreference.live,
            ),
            startupPrefetchEnabledProvider.overrideWithValue(true),
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
            fireTvHelperProvider.overrideWithValue(
              FireTvHelper(isAndroidOverride: false, isTvOverride: false),
            ),
            liveChannelsProvider(_testReg).overrideWith((ref) {
              callOrder.add('live');
              return liveGate.future;
            }),
            schedulesProvider(_testReg).overrideWith((ref) async {
              callOrder.add('schedules');
              return const <RecordSchedule>[];
            }),
            recNgProvider(_testReg).overrideWith((ref) async {
              callOrder.add('recNg');
              return const <RecNgItem>[];
            }),
            channelsProvider(_testReg).overrideWith((ref) async {
              callOrder.add('channels');
              return const <Channel>[];
            }),
            epgGuideProvider(_testReg).overrideWith((ref) async {
              callOrder.add('epg');
              return const EpgGuide(broadcastingType: 2, services: []);
            }),
            channelLogosProvider(_testReg).overrideWith((ref) async {
              callOrder.add('logos');
              return const <int, List<int>>{};
            }),
            titleCountsProvider(_testReg).overrideWith((ref) async {
              callOrder.add('titleCounts');
              return const TitleCounts(0, 100);
            }),
            titlesProvider(_testReg).overrideWith(() {
              callOrder.add('titles');
              return _CountingTitlesNotifier(_testReg);
            }),
            deviceInfoProvider(_testReg).overrideWith((ref) async {
              callOrder.add('deviceInfo');
              return const DeviceInfo(
                name: 'テストnasne',
                softwareVersion: '0260',
              );
            }),
            hddDetailsProvider(_testReg).overrideWith((ref) async {
              callOrder.add('hdd');
              return const <HddDetail>[];
            }),
            liveStatusProvider(_testReg).overrideWith((ref) async {
              callOrder.add('liveStatus');
              return const LiveStatus(sections: {}, raw: {});
            }),
            networkInfoProvider(_testReg).overrideWith((ref) async {
              callOrder.add('network');
              return const NetworkInfo(
                macAddr: '00:11:22:33:44:55',
                ipv4Addr: '192.0.2.10',
              );
            }),
            bcasInfoProvider(_testReg).overrideWith((ref) async {
              callOrder.add('bcas');
              return const BcasInfo(status: 'OK');
            }),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pump();
      await tester.pump();

      // While Live initial fetch is pending, prefetcher does NOT fire EPG/titles/deviceInfo.
      expect(callOrder, isNot(contains('epg')));
      expect(callOrder, isNot(contains('titles')));
      expect(callOrder, isNot(contains('deviceInfo')));

      // Resolve initial Live fetch and advance timers through sequential steps.
      liveGate.complete(const <LiveBand>[]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(callOrder, containsAll(['live', 'schedules', 'epg', 'titles', 'deviceInfo']));
      expect(
        callOrder.indexOf('schedules') < callOrder.indexOf('epg'),
        isTrue,
      );
      expect(
        callOrder.indexOf('epg') < callOrder.indexOf('titles'),
        isTrue,
      );
      expect(
        callOrder.indexOf('titles') < callOrder.indexOf('deviceInfo'),
        isTrue,
      );
    });

    testWidgets('prefetcher aborts when initial tab fails (offline nasne)', (
      tester,
    ) async {
      var epgCalls = 0;
      var titlesCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialStartupTabProvider.overrideWithValue(
              StartupTabPreference.home,
            ),
            startupPrefetchEnabledProvider.overrideWithValue(true),
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
            fireTvHelperProvider.overrideWithValue(
              FireTvHelper(isAndroidOverride: false, isTvOverride: false),
            ),
            deviceInfoProvider(_testReg).overrideWith(
              (ref) => Future<DeviceInfo>.error(
                NasneError.unreachable('webapi:/status/boxNameGet'),
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
            epgGuideProvider(_testReg).overrideWith((ref) async {
              epgCalls++;
              return const EpgGuide(broadcastingType: 2, services: []);
            }),
            titlesProvider(_testReg).overrideWith(() {
              titlesCalls++;
              return _CountingTitlesNotifier(_testReg);
            }),
          ],
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(epgCalls, 0);
      expect(titlesCalls, 0);
    });

    testWidgets('prefetcher stops remaining tabs when pushing a route (e.g. player)', (
      tester,
    ) async {
      final schedulesGate = Completer<List<RecordSchedule>>();
      var epgCalls = 0;
      late BuildContext shellContext;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialStartupTabProvider.overrideWithValue(
              StartupTabPreference.live,
            ),
            startupPrefetchEnabledProvider.overrideWithValue(true),
            registrationStoreProvider.overrideWithValue(
              InMemoryRegistrationStore(const [_testReg]),
            ),
            selectedHostProvider.overrideWith(() => _FixedHostNotifier(_testReg.host)),
            fireTvHelperProvider.overrideWithValue(
              FireTvHelper(isAndroidOverride: false, isTvOverride: false),
            ),
            liveChannelsProvider(_testReg).overrideWith(
              (ref) async => const <LiveBand>[],
            ),
            schedulesProvider(_testReg).overrideWith(
              (ref) => schedulesGate.future,
            ),
            epgGuideProvider(_testReg).overrideWith((ref) async {
              epgCalls++;
              return const EpgGuide(broadcastingType: 2, services: []);
            }),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                shellContext = context;
                return const AppShell();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Push a route simulating opening playback while schedules prefetch is mid-flight.
      unawaited(
        Navigator.of(shellContext).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('再生画面')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      schedulesGate.complete(const <RecordSchedule>[]);
      await tester.pump(const Duration(milliseconds: 200));

      expect(epgCalls, 0);
    });
  });
}

class _FixedHostNotifier extends SelectedHostNotifier {
  _FixedHostNotifier(this._host);
  final String _host;

  @override
  String? build() => _host;
}

class _CountingTitlesNotifier extends TitlesNotifier {
  _CountingTitlesNotifier(super.reg);

  @override
  Stream<TitleListProgress> build() => Stream.value(
    const TitleListProgress(<RecordedTitle>[], complete: true),
  );
}

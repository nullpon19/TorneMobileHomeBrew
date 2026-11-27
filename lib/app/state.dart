/// App-level state (plan 12.7): the registration list, the selected
/// device, the current tab, and the per-device data providers.
///
/// Everything UI-facing goes through the domain interfaces assembled
/// by the composition root (app/providers.dart); these providers only
/// add caching, selection, and refresh semantics on top. Tests can
/// substitute fakes by overriding the composition-root providers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core.dart';
import 'providers.dart';

/// Tab indices of the app shell (plan 5.6; live viewing added
/// in plan 39).
abstract final class AppTabs {
  static const int home = 0;
  static const int live = 1;
  static const int schedules = 2;
  static const int titles = 3;
  static const int epg = 4;
  static const int settings = 5;
}

/// The WebAPI broadcasting type of terrestrial digital (measured,
/// plan 11.4: 0/1 are rejected with 400 on FW 2.60).
const int terrestrialBroadcastingType = 2;

/// The persisted registration list, loaded from the store.
class RegistrationsNotifier extends AsyncNotifier<List<RegisteredNasne>> {
  @override
  Future<List<RegisteredNasne>> build() =>
      ref.watch(registrationStoreProvider).loadAll();

  Future<void> add(RegisteredNasne registration) async {
    await ref.read(registrationStoreProvider).save(registration);
    ref.invalidateSelf();
    await future;
  }

  Future<void> remove(String host) async {
    await ref.read(registrationStoreProvider).remove(host);
    ref.invalidateSelf();
    await future;
  }

  Future<void> reload() async {
    ref.invalidateSelf();
    await future;
  }
}

final registrationsProvider =
    AsyncNotifierProvider<RegistrationsNotifier, List<RegisteredNasne>>(
      RegistrationsNotifier.new,
    );

/// Host of the device the user explicitly selected; null means
/// "the first registered device" (the v1 UI is single-device,
/// plan 9 item 5c). The selection is persisted in the key-value
/// store so it survives restarts when several devices are
/// registered; without it a restart always fell back to the
/// first registered device.
class SelectedHostNotifier extends Notifier<String?> {
  static const _key = 'selected_host';

  @override
  String? build() {
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final value = await store.read(_key);
      if (value != null && state == null) state = value;
    });
    return null;
  }

  Future<void> select(String? host) async {
    state = host;
    final store = ref.read(keyValueStoreProvider);
    if (host == null) {
      await store.delete(_key);
    } else {
      await store.write(_key, host);
    }
  }
}

final selectedHostProvider = NotifierProvider<SelectedHostNotifier, String?>(
  SelectedHostNotifier.new,
);

/// The registration the UI currently operates on.
final selectedRegistrationProvider = Provider<RegisteredNasne?>((ref) {
  final registrations = ref.watch(registrationsProvider).value;
  if (registrations == null || registrations.isEmpty) return null;
  final host = ref.watch(selectedHostProvider);
  for (final r in registrations) {
    if (r.host == host) return r;
  }
  return registrations.first;
});

/// The current tab of the app shell; screens may request a switch
/// (e.g. the home screen's "go register" prompt).
class TabIndexNotifier extends Notifier<int> {
  @override
  int build() => AppTabs.home;

  void select(int index) => state = index;
}

final tabIndexProvider = NotifierProvider<TabIndexNotifier, int>(
  TabIndexNotifier.new,
);

// ---------------------------------------------------------------------------
// Per-device data providers. The device is the truth; these are
// display fetches with manual refresh via ref.invalidate (plan 12.7).
// ---------------------------------------------------------------------------

final deviceInfoProvider = FutureProvider.family<DeviceInfo, RegisteredNasne>(
  (ref, reg) =>
      ref.watch(deviceServicesProvider(reg)).deviceInfo.getDeviceInfo(),
);

/// One HDD list entry together with its detail (null when the
/// entry is not mounted/registered or the detail fetch failed;
/// the entry alone still renders).
class HddDetail {
  const HddDetail(this.entry, this.info);

  final HddEntry entry;
  final HddInfo? info;
}

final hddDetailsProvider =
    FutureProvider.family<List<HddDetail>, RegisteredNasne>((ref, reg) async {
      final service = ref.watch(deviceServicesProvider(reg)).deviceInfo;
      final entries = await service.listHdds();
      final details = <HddDetail>[];
      for (final entry in entries) {
        HddInfo? info;
        // An entry that is not mounted or not registered has no
        // detail to fetch (the endpoint fails for it, plan 116);
        // the tile renders such an external entry as not
        // connected instead of as a fetch failure.
        if (entry.mounted && entry.registered) {
          try {
            info = await service.getHddInfo(entry.id);
          } on NasneError {
            info = null;
          }
        }
        details.add(HddDetail(entry, info));
      }
      return details;
    });

final liveStatusProvider = FutureProvider.family<LiveStatus, RegisteredNasne>(
  (ref, reg) =>
      ref.watch(deviceServicesProvider(reg)).deviceInfo.getLiveStatus(),
);

final recNgProvider = FutureProvider.family<List<RecNgItem>, RegisteredNasne>(
  (ref, reg) => ref.watch(deviceServicesProvider(reg)).deviceInfo.listRecNg(),
);

final networkInfoProvider = FutureProvider.family<NetworkInfo, RegisteredNasne>(
  (ref, reg) =>
      ref.watch(deviceServicesProvider(reg)).deviceInfo.getNetworkInfo(),
);

final bcasInfoProvider = FutureProvider.family<BcasInfo, RegisteredNasne>(
  (ref, reg) => ref.watch(deviceServicesProvider(reg)).deviceInfo.getBcasInfo(),
);

/// Terrestrial channel list, persisted through the channel cache.
/// A network failure falls back to the cached list when one exists.
final channelsProvider = FutureProvider.family<List<Channel>, RegisteredNasne>((
  ref,
  reg,
) async {
  final service = ref.watch(deviceServicesProvider(reg)).deviceInfo;
  final cache = ref.watch(channelCacheProvider);
  try {
    final channels = await service.listChannels(terrestrialBroadcastingType);
    await cache.save(reg.host, terrestrialBroadcastingType, channels);
    return channels;
  } on NasneError {
    final cached = await cache.load(reg.host, terrestrialBroadcastingType);
    if (cached != null) return cached;
    rethrow;
  }
});

/// The full programme guide (terrestrial), anchored on the channel
/// list (plan 21). Fetched as one dataset (8 days on the measured
/// unit); the screen slices it by day.
final epgGuideProvider = FutureProvider.family<EpgGuide, RegisteredNasne>((
  ref,
  reg,
) async {
  final channels = await ref.watch(channelsProvider(reg).future);
  return ref
      .watch(deviceServicesProvider(reg))
      .metadata
      .getProgrammeGuide(terrestrialBroadcastingType, channels);
});

/// Loads persisted station logos from disk cache or fetches them from nasne
/// when expired ([channelLogoCacheMaxAge]) or when the channel lineup signature
/// changes, saving refreshed logos to [channelLogoCacheProvider]. Falls back to
/// any cached logos on [NasneError] so offline browsing retains existing icons.
Future<Map<int, List<int>>> loadCachedOrFetchChannelLogos(
  Ref ref,
  RegisteredNasne reg,
  int broadcastingType, {
  List<Channel> channels = const [],
}) async {
  final cache = ref.watch(channelLogoCacheProvider);
  final sig = buildChannelLogoSignature(channels);
  final expectedSig = sig.isNotEmpty ? sig : null;
  final cached = await cache.load(
    reg.host,
    broadcastingType,
    maxAge: channelLogoCacheMaxAge,
    expectedChannelsSignature: expectedSig,
  );
  if (cached != null && cached.isNotEmpty) {
    return cached;
  }
  try {
    final raw = await ref
        .watch(deviceServicesProvider(reg))
        .metadata
        .getChannelLogos(broadcastingType);
    final normalized = <int, Uint8List>{
      for (final entry in raw.entries)
        if (entry.value.isNotEmpty)
          entry.key: entry.value is Uint8List
              ? entry.value as Uint8List
              : Uint8List.fromList(entry.value),
    };
    if (normalized.isNotEmpty) {
      try {
        await cache.save(
          reg.host,
          broadcastingType,
          normalized,
          channelsSignature: expectedSig,
        );
      } catch (_) {
        // Cache persistence is best-effort; never fail logo rendering.
      }
    }
    return normalized;
  } on NasneError {
    final staleCached = await cache.load(reg.host, broadcastingType);
    return staleCached ?? const <int, List<int>>{};
  }
}

/// Clears disk-cached station logos for [reg] so the next provider read
/// re-fetches fresh images from the nasne unit.
Future<void> clearChannelLogoCache(
  WidgetRef ref,
  RegisteredNasne reg, {
  int? broadcastingType,
}) async {
  final cache = ref.read(channelLogoCacheProvider);
  final types = broadcastingType != null ? [broadcastingType] : const [2, 3, 4];
  await Future.wait([for (final t in types) cache.delete(reg.host, t)]);
}

/// Channel logos (terrestrial): serviceId -> PNG bytes (plan 21), backed by
/// [channelLogoCacheProvider].
final channelLogosProvider =
    FutureProvider.family<Map<int, List<int>>, RegisteredNasne>(
      (ref, reg) =>
          loadCachedOrFetchChannelLogos(ref, reg, terrestrialBroadcastingType),
    );

/// Reservations in chronological order (the device returns them in
/// its own order; the UI contract is time order, plan 5.6).
final schedulesProvider =
    FutureProvider.family<List<RecordSchedule>, RegisteredNasne>((
      ref,
      reg,
    ) async {
      final list = await ref
          .watch(deviceServicesProvider(reg))
          .schedules
          .listSchedules();
      return [...list]..sort((a, b) => a.start.compareTo(b.start));
    });

/// Recorded titles, loaded progressively (plan 100): the stream
/// emits the titles fetched so far — a first chunk, then page by
/// page — and a final stage marked complete once every page is
/// in and the DIDL complement is merged. Only the complete
/// stage is the whole list; consumers that search, filter or
/// sort (whole-set operations) must treat an incomplete stage
/// as provisional.
///
/// A notifier rather than a plain stream provider so a
/// successful protection update can rewrite the one title's
/// flag in the loaded list (plan 103, [TitlesNotifier.applyProtection])
/// and a successful resume report can rewrite the one title's
/// resume point (plan 104, [TitlesNotifier.applyResumePoint]),
/// instead of refetching the whole list: the refetch cost grows
/// with the library, and the unit's own list can lag the update
/// anyway.
class TitlesNotifier extends StreamNotifier<TitleListProgress> {
  TitlesNotifier(this.reg);

  final RegisteredNasne reg;

  @override
  Stream<TitleListProgress> build() => ref
      .watch(deviceServicesProvider(reg))
      .titles
      .listTitlesProgressively();

  /// Rewrites the protection flag of the loaded title [titleId]
  /// in place, after the unit accepted the update (plan 103).
  ///
  /// The list the UI holds becomes the up-to-date one at once:
  /// the row's lock icon and the detail's switch both read this
  /// state, so neither waits for — or is clobbered by — a
  /// refetch. A later stream stage or an explicit refresh still
  /// replaces the state with what the unit answers; that is the
  /// unit's list catching up, not a state this patch defends.
  /// Does nothing while no stage has loaded, or when the title
  /// is not in the loaded stage.
  void applyProtection(String titleId, bool protect) {
    final stage = state.value;
    if (stage == null) return;
    final i = stage.titles.indexWhere((t) => t.id == titleId);
    if (i < 0 || stage.titles[i].protectFlag == protect) return;
    final titles = [...stage.titles];
    titles[i] = titles[i].withProtectFlag(protect);
    state = AsyncData(
      TitleListProgress(titles, complete: stage.complete),
    );
  }

  /// Rewrites the resume point of the loaded title [titleId]
  /// in place, after the unit accepted the resume report a
  /// closing player made (plan 104 follow-up).
  ///
  /// The detail's resume row and the resume choice at the
  /// next play both read this state, so they follow the
  /// viewing that just ended instead of the snapshot from
  /// before it: without the patch, a position the unit
  /// already held looked unrecorded until a manual refresh.
  /// A reported zero (the viewing ran to the end) clears
  /// the point. The stamp moves with the point — the unit
  /// re-stamps lastPlaybackTime on every accepted report
  /// (plan 102). Does nothing while no stage has loaded, or
  /// when the title is not in the loaded stage.
  void applyResumePoint(String titleId, int resumePointSeconds) {
    final stage = state.value;
    if (stage == null) return;
    final i = stage.titles.indexWhere((t) => t.id == titleId);
    if (i < 0 || stage.titles[i].resumePointSeconds == resumePointSeconds) {
      return;
    }
    final titles = [...stage.titles];
    titles[i] = titles[i].withResumePoint(resumePointSeconds, DateTime.now());
    state = AsyncData(
      TitleListProgress(titles, complete: stage.complete),
    );
  }
}

final titlesProvider =
    StreamNotifierProvider.family<
      TitlesNotifier,
      TitleListProgress,
      RegisteredNasne
    >(TitlesNotifier.new);

/// A recorded title's thumbnail image (plan 86.6), fetched
/// lazily per title when its row or detail is shown; null when
/// the unit offers none. Keyed by a record so the family cache
/// is per (device, title).
final titleThumbnailProvider =
    FutureProvider.family<Uint8List?, ({RegisteredNasne reg, String titleId})>(
      (ref, key) => ref
          .watch(deviceServicesProvider(key.reg))
          .titles
          .fetchThumbnail(key.titleId),
    );

/// Live bands and channels with the programme currently on air
/// (plan 39). The programme information is a snapshot of the
/// fetch moment; the screen's refresh action re-fetches it.
final liveChannelsProvider =
    FutureProvider.family<List<LiveBand>, RegisteredNasne>(
      (ref, reg) =>
          ref.watch(deviceServicesProvider(reg)).live.listLiveChannels(),
    );

/// Recorded-title counts (current / maximum).
class TitleCounts {
  const TitleCounts(this.count, this.max);

  final int count;
  final int max;
}

final titleCountsProvider = FutureProvider.family<TitleCounts, RegisteredNasne>(
  (ref, reg) async {
    final service = ref.watch(deviceServicesProvider(reg)).titles;
    return TitleCounts(await service.countTitles(), await service.maxTitles());
  },
);

/// Invalidates every per-device data provider for [reg]; used by the
/// refresh actions. The device stays the source of truth.
void invalidateDeviceData(
  WidgetRef ref,
  RegisteredNasne reg, {
  bool clearLogos = true,
}) {
  ref.invalidate(deviceInfoProvider(reg));
  ref.invalidate(hddDetailsProvider(reg));
  ref.invalidate(liveStatusProvider(reg));
  ref.invalidate(recNgProvider(reg));
  ref.invalidate(networkInfoProvider(reg));
  ref.invalidate(bcasInfoProvider(reg));
  ref.invalidate(channelsProvider(reg));
  ref.invalidate(epgGuideProvider(reg));
  if (clearLogos) {
    unawaited(clearChannelLogoCache(ref, reg));
    ref.invalidate(channelLogosProvider(reg));
  }
  ref.invalidate(schedulesProvider(reg));
  ref.invalidate(titlesProvider(reg));
  ref.invalidate(titleCountsProvider(reg));
  ref.invalidate(liveChannelsProvider(reg));
}

/// Closes pooled pre-VPN/stale HTTP connections and refreshes all registered
/// nasne units. Invalidating [httpClientProvider] cascades through
/// [deviceServicesProvider] to every per-device provider automatically.
void resetNetworkAndInvalidateDevices(
  WidgetRef ref,
  Iterable<RegisteredNasne> regs,
) {
  ref.invalidate(httpClientProvider);
  for (final r in regs) {
    invalidateDeviceData(ref, r, clearLogos: false);
  }
}

/// Persisted list of registered generic DLNA / DTCP-IP MediaServers
/// (`keyValueStoreProvider` under key `dlna_servers_v1`).
class DlnaServersNotifier extends Notifier<List<RegisteredDlnaServer>> {
  static const _key = 'dlna_servers_v1';
  bool _dirty = false;

  @override
  List<RegisteredDlnaServer> build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (_dirty || raw == null || raw.isEmpty) return;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return;
        final list = [
          for (final item in decoded)
            if (item is Map)
              RegisteredDlnaServer.fromJson(item.cast<String, dynamic>()),
        ];
        if (!_dirty) {
          state = list;
        }
      } catch (_) {}
    });
    return const [];
  }

  Future<void> addOrReplace(RegisteredDlnaServer server) async {
    _dirty = true;
    final next = [
      for (final existing in state)
        if (existing.id != server.id) existing,
      server,
    ];
    state = next;
    await _persist(next);
  }

  Future<void> remove(String id) async {
    _dirty = true;
    final next = [
      for (final existing in state)
        if (existing.id != id) existing,
    ];
    state = next;
    await _persist(next);
  }

  Future<void> _persist(List<RegisteredDlnaServer> list) {
    return ref.read(keyValueStoreProvider).write(
      _key,
      jsonEncode([for (final s in list) s.toJson()]),
    );
  }
}

final dlnaServersProvider =
    NotifierProvider<DlnaServersNotifier, List<RegisteredDlnaServer>>(
      DlnaServersNotifier.new,
    );

/// ContentDirectory:1 Browse response for a generic DLNA server container.
final dlnaBrowseProvider = FutureProvider.family<
  DidlDocument,
  ({String controlUrl, String objectId})
>((ref, req) {
  final service = DlnaMetadataService(
    soap: SoapTransport(client: ref.watch(httpClientProvider)),
    controlUrl: Uri.parse(req.controlUrl),
  );
  return service.browse(req.objectId);
});

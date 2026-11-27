/// BS / CS EPG & channel providers, preserving the existing terrestrial path.
/// Terrestrial providers remain unchanged, including their cache keys.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core.dart';
import 'providers.dart';
import 'state.dart';

/// Measured nasne WebAPI broadcastingType for BS digital television.
const int bsBroadcastingType = 3;

/// nasne WebAPI broadcastingType for 110° CS digital television.
const int csBroadcastingType = 4;

final bsChannelsProvider = FutureProvider.family<List<Channel>, RegisteredNasne>(
  (ref, reg) async {
    final service = ref.watch(deviceServicesProvider(reg)).deviceInfo;
    final cache = ref.watch(channelCacheProvider);
    try {
      final channels = await service.listChannels(bsBroadcastingType);
      await cache.save(reg.host, bsBroadcastingType, channels);
      return channels;
    } on NasneError {
      final cached = await cache.load(reg.host, bsBroadcastingType);
      if (cached != null) return cached;
      rethrow;
    }
  },
);

final bsEpgGuideProvider = FutureProvider.family<EpgGuide, RegisteredNasne>(
  (ref, reg) async {
    final channels = await ref.watch(bsChannelsProvider(reg).future);
    return ref
        .watch(deviceServicesProvider(reg))
        .metadata
        .getProgrammeGuide(bsBroadcastingType, channels);
  },
);

final bsChannelLogosProvider =
    FutureProvider.family<Map<int, List<int>>, RegisteredNasne>((ref, reg) {
      final sig = ref.watch(
        bsChannelsProvider(reg).select(
          (v) => buildChannelLogoSignature(v.value ?? const <Channel>[]),
        ),
      );
      return loadCachedOrFetchChannelLogos(
        ref,
        reg,
        bsBroadcastingType,
        channelsSignature: sig,
      );
    });

/// CS channel list, persisted through [channelCacheProvider]. Falls back to an
/// empty list on unsupported firmware or fetch error so CS browsing degrades
/// cleanly without breaking live playback.
final csChannelsProvider = FutureProvider.family<List<Channel>, RegisteredNasne>(
  (ref, reg) async {
    final service = ref.watch(deviceServicesProvider(reg)).deviceInfo;
    final cache = ref.watch(channelCacheProvider);
    try {
      final channels = await service.listChannels(csBroadcastingType);
      await cache.save(reg.host, csBroadcastingType, channels);
      return channels;
    } on NasneError {
      return await cache.load(reg.host, csBroadcastingType) ??
          const <Channel>[];
    }
  },
);

/// Station logos for CS (best-effort; degrades to an empty map if unsupported).
final csChannelLogosProvider =
    FutureProvider.family<Map<int, List<int>>, RegisteredNasne>((ref, reg) {
      final sig = ref.watch(
        csChannelsProvider(reg).select(
          (v) => buildChannelLogoSignature(v.value ?? const <Channel>[]),
        ),
      );
      return loadCachedOrFetchChannelLogos(
        ref,
        reg,
        csBroadcastingType,
        channelsSignature: sig,
      );
    });

/// Clears persisted station logos for [reg] and awaits deletion before
/// invalidating the corresponding Riverpod logo providers (all bands when
/// [broadcastingType] is omitted) so stale disk logos are never re-read.
Future<void> invalidateChannelLogosWithCacheReset(
  WidgetRef ref,
  RegisteredNasne reg, {
  int? broadcastingType,
}) async {
  await clearChannelLogoCache(ref, reg, broadcastingType: broadcastingType);
  if (!ref.context.mounted) return;
  if (broadcastingType == null ||
      broadcastingType == terrestrialBroadcastingType) {
    ref.invalidate(channelLogosProvider(reg));
  }
  if (broadcastingType == null || broadcastingType == bsBroadcastingType) {
    ref.invalidate(bsChannelLogosProvider(reg));
  }
  if (broadcastingType == null || broadcastingType == csBroadcastingType) {
    ref.invalidate(csChannelLogosProvider(reg));
  }
}

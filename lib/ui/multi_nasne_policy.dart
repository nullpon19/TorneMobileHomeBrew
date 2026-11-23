/// Pure helper policies for unified multi-nasne operation while preserving
/// single-nasne behavior identically when only one device is registered.
library;

import '../app/state.dart';
import '../core/core.dart';
import 'epg_subchannel_visibility.dart';
import 'live_recording_policy.dart';

/// Composite identifier isolating record/title IDs per registered nasne host.
String ownedItemKey(RegisteredNasne reg, String id) => '${reg.host}\u0000$id';

/// Human-readable display label for a registered nasne.
String nasneDisplayLabel(RegisteredNasne reg) =>
    reg.friendlyName.trim().isNotEmpty ? reg.friendlyName.trim() : reg.host;

/// Stable broadcast-channel key deduplicating identical channels across nasnes.
String liveServiceKey(LiveChannel channel) {
  final nid = channel.networkId;
  final tsid = channel.transportStreamId;
  final svid = channel.serviceId;
  if (nid != null && tsid != null && svid != null) {
    return '$nid:$tsid:$svid';
  }
  return channel.id;
}

/// Scheduled reservation paired with its owning nasne.
class OwnedRecordSchedule {
  const OwnedRecordSchedule({required this.reg, required this.schedule});

  final RegisteredNasne reg;
  final RecordSchedule schedule;

  String get compositeKey => ownedItemKey(reg, schedule.id);
}

/// Recorded title paired with its owning nasne.
class OwnedRecordedTitle {
  const OwnedRecordedTitle({required this.reg, required this.title});

  final RegisteredNasne reg;
  final RecordedTitle title;

  String get compositeKey => ownedItemKey(reg, title.id);
}

/// Live channel entry paired with the nasne that serves it.
class OwnedLiveChannel {
  const OwnedLiveChannel({required this.reg, required this.channel});

  final RegisteredNasne reg;
  final LiveChannel channel;
}

/// Merged live channel across one or more nasnes serving the same broadcast.
class MergedLiveChannel {
  const MergedLiveChannel({
    required this.primary,
    required this.primaryReg,
    required this.candidates,
  });

  final LiveChannel primary;
  final RegisteredNasne primaryReg;
  final List<OwnedLiveChannel> candidates;

  String get serviceKey => liveServiceKey(primary);
}

/// Merged live broadcasting band containing deduplicated channels.
class MergedLiveBand {
  const MergedLiveBand({
    required this.kind,
    required this.title,
    required this.containerId,
    required this.channels,
  });

  final LiveBandKind kind;
  final String title;
  final String containerId;
  final List<MergedLiveChannel> channels;
}

/// Result of selecting a nasne tuner for live viewing.
class LiveTunerSelection {
  const LiveTunerSelection({
    required this.target,
    required this.sameChannelRecording,
  });

  final OwnedLiveChannel target;
  final bool sameChannelRecording;
}

List<T> _orderWithPreferred<T>(
  List<T> items,
  RegisteredNasne Function(T item) regOf,
  RegisteredNasne? preferredReg,
) {
  if (preferredReg == null) return items;
  final preferred = <T>[];
  final others = <T>[];
  for (final item in items) {
    if (regOf(item).host == preferredReg.host) {
      preferred.add(item);
    } else {
      others.add(item);
    }
  }
  return [...preferred, ...others];
}

/// Merges live channel bands across multiple nasnes, prioritizing
/// [preferredReg] when choosing primary metadata while preserving all candidate
/// tuners for each service.
List<MergedLiveBand> mergeLiveBands(
  List<({RegisteredNasne reg, List<LiveBand> bands})> sources, {
  RegisteredNasne? preferredReg,
}) {
  final orderedSources = _orderWithPreferred(
    sources,
    (s) => s.reg,
    preferredReg,
  );
  final bandAccumulators =
      <
        String,
        ({
          LiveBandKind kind,
          String title,
          String containerId,
          Map<String, _ChannelBucket> channels,
          List<String> channelOrder,
        })
      >{};
  final bandOrder = <String>[];

  for (final src in orderedSources) {
    for (final band in src.bands) {
      final kind = liveBandKind(band);
      final bandKey = kind == LiveBandKind.other
          ? 'other:${band.containerId}'
          : 'kind:${kind.name}';
      final acc = bandAccumulators.putIfAbsent(bandKey, () {
        bandOrder.add(bandKey);
        return (
          kind: kind,
          title: band.title,
          containerId: band.containerId,
          channels: <String, _ChannelBucket>{},
          channelOrder: <String>[],
        );
      });
      for (final ch in band.channels) {
        final key = liveServiceKey(ch);
        var bucket = acc.channels[key];
        if (bucket == null) {
          bucket = _ChannelBucket(
            primary: ch,
            primaryReg: src.reg,
            candidates: <OwnedLiveChannel>[],
            seenHosts: <String>{},
          );
          acc.channels[key] = bucket;
          acc.channelOrder.add(key);
        }
        if (bucket.seenHosts.add(src.reg.host)) {
          bucket.candidates.add(OwnedLiveChannel(reg: src.reg, channel: ch));
        }
      }
    }
  }

  return [
    for (final key in bandOrder)
      () {
        final acc = bandAccumulators[key]!;
        return MergedLiveBand(
          kind: acc.kind,
          title: acc.title,
          containerId: acc.containerId,
          channels: [
            for (final chKey in acc.channelOrder)
              () {
                final b = acc.channels[chKey]!;
                return MergedLiveChannel(
                  primary: b.primary,
                  primaryReg: b.primaryReg,
                  candidates: List<OwnedLiveChannel>.unmodifiable(b.candidates),
                );
              }(),
          ],
        );
      }(),
  ];
}

class _ChannelBucket {
  _ChannelBucket({
    required this.primary,
    required this.primaryReg,
    required this.candidates,
    required this.seenHosts,
  });

  final LiveChannel primary;
  final RegisteredNasne primaryReg;
  final List<OwnedLiveChannel> candidates;
  final Set<String> seenHosts;
}

/// Chooses the best tuner among [candidates] using nasne hardware rules:
/// 1) any nasne with an idle tuner (no active/leading recording on any channel),
/// 2) else a nasne already recording the exact same channel (so viewing can share it),
/// 3) else `null` when every candidate tuner is busy recording another channel.
LiveTunerSelection? selectLiveTunerCandidate({
  required List<OwnedLiveChannel> candidates,
  required Map<String, List<RecordSchedule>> schedulesByHost,
  required DateTime now,
  RegisteredNasne? preferredReg,
  String? excludeHost,
  Duration leadMargin = liveRecordingLeadMargin,
}) {
  final filtered = [
    for (final c in candidates)
      if (excludeHost == null || c.reg.host != excludeHost) c,
  ];
  if (filtered.isEmpty) return null;
  final ordered = _orderWithPreferred(filtered, (c) => c.reg, preferredReg);

  for (final candidate in ordered) {
    final schedules =
        schedulesByHost[candidate.reg.host] ?? const <RecordSchedule>[];
    final activeAny = findActiveRecordingSchedule(
      schedules,
      now: now,
      leadMargin: leadMargin,
    );
    if (activeAny == null) {
      return LiveTunerSelection(
        target: candidate,
        sameChannelRecording: false,
      );
    }
  }

  for (final candidate in ordered) {
    final schedules =
        schedulesByHost[candidate.reg.host] ?? const <RecordSchedule>[];
    final sameChannel = findActiveSameChannelRecording(
      schedules,
      currentChannel: candidate.channel,
      now: now,
    );
    if (sameChannel == null) continue;
    final otherChannel = findActiveOtherChannelRecording(
      schedules,
      currentChannel: candidate.channel,
      now: now,
      leadMargin: leadMargin,
    );
    if (otherChannel == null) {
      return LiveTunerSelection(target: candidate, sameChannelRecording: true);
    }
  }

  return null;
}

/// Merges schedules across multiple nasnes in chronological start order.
List<OwnedRecordSchedule> mergeOwnedSchedules(
  List<({RegisteredNasne reg, List<RecordSchedule> schedules})> sources,
) {
  final merged = <OwnedRecordSchedule>[
    for (final src in sources)
      for (final s in src.schedules)
        OwnedRecordSchedule(reg: src.reg, schedule: s),
  ];
  merged.sort((a, b) {
    final timeCmp = a.schedule.start.compareTo(b.schedule.start);
    if (timeCmp != 0) return timeCmp;
    final hostCmp = a.reg.host.compareTo(b.reg.host);
    if (hostCmp != 0) return hostCmp;
    return a.schedule.id.compareTo(b.schedule.id);
  });
  return merged;
}

/// Computes representative free HDD bytes for auto-balancing reservations
/// (internal HDD `id == 0` preferred, falling back to maximum mounted drive
/// free bytes, or `-1` if unknown).
int totalFreeBytesForHdds(List<HddDetail>? details) {
  if (details == null || details.isEmpty) return -1;
  var best = -1;
  for (final detail in details) {
    final info = detail.info;
    if (info == null || !detail.entry.mounted || !detail.entry.registered) {
      continue;
    }
    if (detail.entry.id == 0) {
      return info.freeBytes;
    }
    if (info.freeBytes > best) {
      best = info.freeBytes;
    }
  }
  return best;
}

/// Selects the optimal nasne for a new reservation in auto mode:
/// picks conflict-free units first, choosing the one with the largest free
/// HDD space (tie-breaking on [preferredReg], then registration order).
/// Returns `null` when every candidate conflicts.
RegisteredNasne? selectAutoScheduleNasne({
  required List<RegisteredNasne> candidates,
  required Map<String, bool> hasConflictByHost,
  required Map<String, int> freeBytesByHost,
  RegisteredNasne? preferredReg,
}) {
  final indexed = <(int index, RegisteredNasne reg)>[];
  for (var i = 0; i < candidates.length; i++) {
    final r = candidates[i];
    if (hasConflictByHost[r.host] == false) {
      indexed.add((i, r));
    }
  }
  if (indexed.isEmpty) return null;
  indexed.sort((a, b) {
    final freeA = freeBytesByHost[a.$2.host] ?? -1;
    final freeB = freeBytesByHost[b.$2.host] ?? -1;
    final freeCmp = freeB.compareTo(freeA);
    if (freeCmp != 0) return freeCmp;
    final prefA = preferredReg != null && a.$2.host == preferredReg.host;
    final prefB = preferredReg != null && b.$2.host == preferredReg.host;
    if (prefA != prefB) return prefA ? -1 : 1;
    return a.$1.compareTo(b.$1);
  });
  return indexed.first.$2;
}

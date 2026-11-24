/// Pure policies and models for two-step D-pad Left/Right channel switching
/// during live TV playback on Fire TV.
library;

import '../core/core.dart';
import 'format.dart';
import 'multi_nasne_policy.dart';

/// Direction of the preview card shown along the horizontal screen edge.
enum ChannelSwitchDirection { previous, next }

/// Channel candidate inside the active live broadcast band along with all
/// matching nasne tuner endpoints (for multi-nasne failover/selection).
class LiveChannelSwitchEntry {
  const LiveChannelSwitchEntry({
    required this.channel,
    required this.primaryReg,
    this.candidates = const [],
  });

  final LiveChannel channel;
  final RegisteredNasne primaryReg;
  final List<OwnedLiveChannel> candidates;

  String get displayChannelName {
    final name = channel.channelName;
    if (name != null && name.isNotEmpty) return name;
    return channel.programTitle;
  }

  String get programTitle => channel.programTitle;

  String? get broadcastTimeRange {
    final start = channel.programStart;
    final end = channel.programEnd;
    if (start == null || end == null) return null;
    return '${formatTimeJst(start)}–${formatTimeJst(end)}';
  }
}

/// Resolved programme title and broadcast time range for a live channel switch
/// preview card at a specific instant.
class ResolvedLiveSwitchProgram {
  const ResolvedLiveSwitchProgram({
    required this.programTitle,
    this.broadcastTimeRange,
    required this.isStale,
  });

  final String programTitle;
  final String? broadcastTimeRange;
  final bool isStale;
}

/// Sorts a copy of [guideEvents] chronologically by start instant.
List<EpgEvent> sortEpgEventsByStart(List<EpgEvent> guideEvents) =>
    [for (final ev in guideEvents) ev]
      ..sort((a, b) => a.start.compareTo(b.start));

/// Picks the active broadcast event at [now] from chronologically sorted
/// [sortedEvents], preferring titled events over filler entries.
EpgEvent? findActiveEpgEvent(List<EpgEvent> sortedEvents, DateTime now) {
  EpgEvent? currentEv;
  for (final ev in sortedEvents) {
    if (!now.isBefore(ev.start) && ev.end.isAfter(now)) {
      if ((ev.title ?? '').trim().isNotEmpty || currentEv == null) {
        currentEv = ev;
        if ((ev.title ?? '').trim().isNotEmpty) break;
      }
    }
  }
  return currentEv;
}

/// Resolves the live switch card's programme info from [guideEvents] at [now],
/// falling back to [entry]'s initial snapshot and reporting [isStale] when the
/// snapshot has already ended without a matching EPG event.
ResolvedLiveSwitchProgram resolveLiveSwitchEntryProgram({
  required LiveChannelSwitchEntry entry,
  required List<EpgEvent> guideEvents,
  required DateTime now,
}) {
  final sorted = sortEpgEventsByStart(guideEvents);
  final currentEv = findActiveEpgEvent(sorted, now);

  if (currentEv != null && (currentEv.title ?? '').trim().isNotEmpty) {
    return ResolvedLiveSwitchProgram(
      programTitle: currentEv.title!.trim(),
      broadcastTimeRange:
          '${formatTimeJst(currentEv.start)}–${formatTimeJst(currentEv.end)}',
      isStale: false,
    );
  }

  final end = entry.channel.programEnd;
  return ResolvedLiveSwitchProgram(
    programTitle: entry.programTitle,
    broadcastTimeRange: entry.broadcastTimeRange,
    isStale: end == null || !end.isAfter(now),
  );
}

/// Computes the wrapped adjacent channel index inside a band of [count]
/// channels, returning `-1` when switching is unavailable.
int adjacentLiveChannelIndex({
  required int currentIndex,
  required int count,
  required ChannelSwitchDirection direction,
}) {
  if (count <= 1 || currentIndex < 0 || currentIndex >= count) return -1;
  final delta = direction == ChannelSwitchDirection.next ? 1 : -1;
  return (currentIndex + delta + count) % count;
}

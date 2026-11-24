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

/// Programme guide (EPG) models (plan 21).
///
/// Built from the `chEpg/EPGGet` payload: per-service lists of
/// events with ARIB STD-B24 text already decoded and normalised
/// (broadcast_text.dart). Times are absolute instants; rendering
/// converts to JST wall clock (ui/format.dart), as everywhere else.
library;

import 'channel.dart';

/// One broadcast event (one programme) in the guide.
class EpgEvent {
  const EpgEvent({
    required this.eventId,
    required this.start,
    required this.duration,
    this.title,
    this.shortText,
    this.description,
    this.cast,
    this.extendedItems = const [],
    this.extendedText,
    this.genreLevel1,
    this.genreLevel2,
  });

  final int eventId;

  /// Start instant (the broadcast wall time is JST).
  final DateTime start;
  final Duration duration;
  DateTime get end => start.add(duration);

  /// Short-event name (descriptor 0x4D); null when the event
  /// carries no title (filler / no-information events exist).
  final String? title;

  /// Short-event text (descriptor 0x4D, the part after the name).
  final String? shortText;

  /// Extended-event item labelled 番組内容 (descriptor 0x4E).
  final String? description;

  /// Extended-event item labelled 出演者 (descriptor 0x4E).
  final String? cast;

  /// Remaining extended-event items, in broadcast order.
  final List<EpgExtendedItem> extendedItems;

  /// Extended-event free text (descriptor 0x4E trailing part).
  final String? extendedText;

  /// Content descriptor (0x54) genre nibbles, when present.
  final int? genreLevel1;
  final int? genreLevel2;
}

/// One labelled item of an extended event descriptor.
class EpgExtendedItem {
  const EpgExtendedItem({required this.label, required this.value});

  final String label;
  final String value;
}

/// The guide of one service (channel).
class EpgServiceGuide {
  const EpgServiceGuide({required this.channel, required this.events});

  final Channel channel;
  final List<EpgEvent> events;
}

/// The whole programme guide for one broadcasting type.
class EpgGuide {
  const EpgGuide({
    required this.broadcastingType,
    required this.services,
    this.fetchedAt,
  });

  final int broadcastingType;
  final List<EpgServiceGuide> services;
  final DateTime? fetchedAt;

  /// Earliest event start across all services (null when empty).
  DateTime? get from {
    DateTime? best;
    for (final s in services) {
      for (final e in s.events) {
        if (best == null || e.start.isBefore(best)) best = e.start;
      }
    }
    return best;
  }

  /// Latest event end across all services (null when empty).
  DateTime? get to {
    DateTime? best;
    for (final s in services) {
      for (final e in s.events) {
        if (best == null || e.end.isAfter(best)) best = e.end;
      }
    }
    return best;
  }

  int get eventCount =>
      services.fold(0, (sum, s) => sum + s.events.length);
}

/// The set of subchannel serviceIds (plan 25): within a
/// (networkId, transportStreamId) group, among video services
/// (serviceType 1) the lowest serviceId is the main channel and the
/// rest are subchannels. `branchNumber` is 0 for every service of
/// the measured fixture and name suffixes are unreliable (the J:COM
/// main and subchannels share one name), hence this structural rule.
Set<int> subchannelServiceIds(List<Channel> channels) {
  final groups = <(int, int), List<Channel>>{};
  for (final channel in channels) {
    if (channel.serviceType != 1) continue;
    groups
        .putIfAbsent(
            (channel.networkId, channel.transportStreamId), () => [])
        .add(channel);
  }
  final subchannels = <int>{};
  for (final group in groups.values) {
    if (group.length < 2) continue;
    var mainId = group.first.serviceId;
    for (final channel in group) {
      if (channel.serviceId < mainId) mainId = channel.serviceId;
    }
    for (final channel in group) {
      if (channel.serviceId != mainId) subchannels.add(channel.serviceId);
    }
  }
  return subchannels;
}

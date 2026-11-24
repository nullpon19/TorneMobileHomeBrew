/// Policies for detecting active scheduled recordings during live TV browsing
/// and playback (single-tuner conflict handling, TV-list indicators, and
/// same-channel player recording badges/notices).
library;

import '../app/bs_epg_providers.dart';
import '../app/state.dart';
import '../core/core.dart';

/// CS broadcastingType value in WebAPI / XSRS schedules (DTTB=2, BS=3, CS=4).
const int csBroadcastingType = 4;

/// Lead time before reservation start when nasne claims the tuner.
const Duration liveRecordingLeadMargin = Duration(seconds: 90);

/// Maps a LiveTuner DIDL band container id (`.../DTTB`, `.../BS`, `.../CS`)
/// to nasne's `broadcastingType`, or `null` when unknown.
int? broadcastingTypeForLiveBandId(String bandId) =>
    switch (bandId.split('/').last) {
      'DTTB' => terrestrialBroadcastingType,
      'BS' => bsBroadcastingType,
      'CS' => csBroadcastingType,
      _ => null,
    };

/// Whether [schedule] targets the same broadcast channel as [channel].
bool scheduleMatchesLiveChannel(RecordSchedule schedule, LiveChannel channel) {
  final serviceId = channel.serviceId;
  if (serviceId == null || schedule.channel.serviceId != serviceId) {
    return false;
  }
  final bandType = broadcastingTypeForLiveBandId(channel.bandId);
  if (bandType != null && schedule.channel.broadcastingType != bandType) {
    return false;
  }
  return true;
}

/// Resolves the matching [LiveChannel] inside [bands] for [schedule], if any.
LiveChannel? findLiveChannelForSchedule(
  List<LiveBand> bands,
  RecordSchedule schedule,
) {
  for (final band in bands) {
    final bandType = broadcastingTypeForLiveBandId(band.containerId);
    if (bandType != null && bandType != schedule.channel.broadcastingType) {
      continue;
    }
    for (final ch in band.channels) {
      if (ch.serviceId == schedule.channel.serviceId) {
        return ch;
      }
    }
  }
  return null;
}

/// Returns the schedule currently active at [now] (preferring a schedule whose
/// window `[start, end)` contains [now], or within [leadMargin] before start).
RecordSchedule? findActiveRecordingSchedule(
  List<RecordSchedule> schedules, {
  required DateTime now,
  Duration leadMargin = Duration.zero,
}) {
  RecordSchedule? leading;
  for (final s in schedules) {
    if (s.durationSeconds <= 0) continue;
    final end = s.end;
    if (!now.isBefore(end)) continue;
    if (!now.isBefore(s.start)) return s;
    if (leadMargin > Duration.zero &&
        !now.isBefore(s.start.subtract(leadMargin))) {
      leading ??= s;
    }
  }
  return leading;
}

/// Returns an active or imminent reservation on a DIFFERENT channel from
/// [currentChannel] at [now], or `null` if [currentChannel] itself is recording
/// or no other channel owns the tuner.
RecordSchedule? findActiveOtherChannelRecording(
  List<RecordSchedule> schedules, {
  required LiveChannel currentChannel,
  required DateTime now,
  Duration leadMargin = liveRecordingLeadMargin,
}) {
  if (findActiveSameChannelRecording(
        schedules,
        currentChannel: currentChannel,
        now: now,
      ) !=
      null) {
    return null;
  }
  RecordSchedule? leadingOther;
  for (final s in schedules) {
    if (s.durationSeconds <= 0) continue;
    if (scheduleMatchesLiveChannel(s, currentChannel)) continue;
    if (!now.isBefore(s.end)) continue;
    if (!now.isBefore(s.start)) return s;
    if (leadMargin > Duration.zero &&
        !now.isBefore(s.start.subtract(leadMargin))) {
      leadingOther ??= s;
    }
  }
  return leadingOther;
}

/// Returns the active schedule on [currentChannel] when `[start, end)` contains
/// [now].
RecordSchedule? findActiveSameChannelRecording(
  List<RecordSchedule> schedules, {
  required LiveChannel currentChannel,
  required DateTime now,
}) {
  for (final s in schedules) {
    if (s.durationSeconds <= 0) continue;
    if (!scheduleMatchesLiveChannel(s, currentChannel)) continue;
    if (!now.isBefore(s.start) && now.isBefore(s.end)) {
      return s;
    }
  }
  return null;
}

/// Details of another channel's recording that preempted live TV playback.
class LiveRecordingConflict {
  const LiveRecordingConflict({
    required this.schedule,
    required this.displayTitle,
    this.channelName,
    this.liveChannel,
    this.nasneName,
    this.sourceRegistration,
    this.failoverRegistration,
    this.failoverChannel,
  });

  final RecordSchedule schedule;
  final String displayTitle;
  final String? channelName;
  final LiveChannel? liveChannel;
  final String? nasneName;
  final RegisteredNasne? sourceRegistration;
  final RegisteredNasne? failoverRegistration;
  final LiveChannel? failoverChannel;
}

/// Duration for which the top-right live recording status badge stays visible.
const Duration liveRecordingCornerNoticeDuration = Duration(seconds: 30);

/// Short corner notification emitted when the viewed channel starts/ends
/// recording while live playback is running.
enum LiveRecordingCornerNotice { recording, ended }

/// Resolves whether a state change `[previousRecording] -> [currentRecording]`
/// should display the corner notice.
LiveRecordingCornerNotice? resolveLiveRecordingCornerNotice({
  required bool? previousRecording,
  required bool currentRecording,
}) {
  if (previousRecording == null) {
    return currentRecording ? LiveRecordingCornerNotice.recording : null;
  }
  if (!previousRecording && currentRecording) {
    return LiveRecordingCornerNotice.recording;
  }
  if (previousRecording && !currentRecording) {
    return LiveRecordingCornerNotice.ended;
  }
  return null;
}

/// Returns whether [schedule] is actively recording at [now] (`[start, end)`).
bool isScheduleCurrentlyRecording(RecordSchedule schedule, {DateTime? now}) {
  if (schedule.durationSeconds <= 0) return false;
  final current = now ?? DateTime.now();
  return !current.isBefore(schedule.start) && current.isBefore(schedule.end);
}

/// Returns [schedules] with any entry matching [excludedId] removed.
List<RecordSchedule> schedulesWithoutId(
  List<RecordSchedule> schedules,
  String excludedId,
) => [
  for (final s in schedules)
    if (s.id != excludedId) s,
];

/// Returns [schedules] with any entry whose id is in [excludedIds] removed.
List<RecordSchedule> schedulesExcludingIds(
  List<RecordSchedule> schedules,
  Set<String> excludedIds,
) {
  if (excludedIds.isEmpty) return schedules;
  return [
    for (final s in schedules)
      if (!excludedIds.contains(s.id)) s,
  ];
}

/// Ensures [fallback] is present in [schedules] if no item with the same `id`
/// exists yet (compensating for slow nasne schedule-list visibility right after
/// creation).
List<RecordSchedule> ensureSchedulePresent(
  List<RecordSchedule> schedules,
  RecordSchedule fallback,
) {
  if (schedules.any((s) => s.id == fallback.id)) return schedules;
  return [...schedules, fallback];
}

/// Outcome returned by live-OSD recording start/stop callbacks.
class LiveRecordingActionResult {
  const LiveRecordingActionResult({
    required this.success,
    required this.message,
    this.updatedSchedules,
  });

  final bool success;
  final String message;
  final List<RecordSchedule>? updatedSchedules;
}

/// Builds a [NewRecordSchedule] to immediately record the live programme
/// currently airing on [channel], returning `null` if required broadcast IDs are
/// missing.
NewRecordSchedule? buildImmediateLiveRecordingSchedule({
  required LiveChannel channel,
  required DateTime now,
  required int desiredQualityMode,
  EpgEvent? matchingEpgEvent,
  Channel? matchingChannel,
  String recordDestinationId = 'HDD',
}) {
  final broadcastingType =
      matchingChannel?.broadcastingType ??
      broadcastingTypeForLiveBandId(channel.bandId) ??
      terrestrialBroadcastingType;
  final serviceId = matchingChannel?.serviceId ?? channel.serviceId;
  final networkId = matchingChannel?.networkId ?? channel.networkId;
  final channelType = broadcastingType;
  if (serviceId == null || networkId == null) return null;

  final DateTime start;
  final int durationSeconds;
  final int eventId;
  if (matchingEpgEvent != null &&
      matchingEpgEvent.end.isAfter(now) &&
      matchingEpgEvent.duration.inSeconds > 0) {
    start = matchingEpgEvent.start;
    durationSeconds = matchingEpgEvent.duration.inSeconds;
    eventId = matchingEpgEvent.eventId;
  } else {
    eventId = 0;
    start = now;
    final programEnd = channel.programEnd;
    durationSeconds = (programEnd != null && programEnd.isAfter(now))
        ? programEnd.difference(now).inSeconds.clamp(60, 12 * 3600)
        : 3600;
  }

  return NewRecordSchedule(
    start: start,
    durationSeconds: durationSeconds,
    channel: ScheduleChannel(
      broadcastingType: broadcastingType,
      channelType: channelType,
      serviceId: serviceId,
    ),
    networkId: networkId,
    eventId: eventId,
    desiredQualityMode: desiredQualityMode,
    recordDestinationId: recordDestinationId,
  );
}

/// Returns whether an active [activeSchedule] on the channel corresponds to a
/// programme spanning `[programStart, programEnd)` at [now], preventing an
/// already-ended programme (such as a stale A-programme snapshot) from
/// displaying a false "録画中" badge when a subsequent programme starts recording.
bool isProgramMatchingActiveRecording({
  required RecordSchedule? activeSchedule,
  DateTime? programStart,
  DateTime? programEnd,
  required DateTime now,
}) {
  if (activeSchedule == null ||
      !isScheduleCurrentlyRecording(activeSchedule, now: now)) {
    return false;
  }
  if (programEnd != null && !programEnd.isAfter(now)) {
    return false;
  }
  if (programStart != null &&
      programStart.isAfter(now.add(const Duration(minutes: 2)))) {
    return false;
  }
  if (programStart != null && programEnd != null) {
    if (!activeSchedule.start.isBefore(programEnd) ||
        !activeSchedule.end.isAfter(programStart)) {
      return false;
    }
  }
  return true;
}

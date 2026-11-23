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

/// Short corner notification emitted when the viewed channel starts/ends
/// recording while live playback is running.
enum LiveRecordingCornerNotice { recording, ended }

/// Resolves whether a state change `[previousRecording] -> [currentRecording]`
/// should display the 5-second corner notice.
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

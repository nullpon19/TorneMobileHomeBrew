/// Playback screen (Phase 5, plan 26): plays the decrypted TS
/// stream from the DTCP-IP session's loopback proxy via media_kit
/// (mpv). AVPlayer cannot decode MPEG-2 TS on iOS, hence media_kit.
///
/// Plan 29: the player's state streams are mirrored into the
/// playback diagnostics category (playing / buffering transitions
/// and mpv errors), mpv errors are surfaced on screen instead of
/// an eternal spinner, and a start watchdog turns "nothing ever
/// plays" into a classified timeout error.
///
/// Plan 30: mpv's network timeout is raised from its 5 s default
/// to 30 s before opening. In the build-8 field test the player
/// failed with "Failed to open" about 5 s after the content GET
/// while the (then packet-at-a-time) proxy had not delivered a
/// single byte yet; the proxy now streams and prefetches, and the
/// longer timeout keeps a slow path from tripping mpv first.
///
/// Plan 32: while the player reports playing, a wakelock keeps
/// the device from idle-sleeping (the build-10 iPad field test
/// had the device try to sleep about five minutes into playback).
/// The lock follows the playing stream exactly and is released
/// on pause, stop, error and when this screen is disposed.
///
/// Plan 35: the screen no longer owns a private controller — it
/// opens a session on the app-wide [PlaybackWakelock], so two
/// overlapping player screens cannot drop the OS lock from under
/// each other (build-13 field log).
///
/// Plan 39: live viewing reuses this screen unchanged. Nothing
/// here seeks, resumes, or assumes a stream length (recordings
/// also arrive as an unbounded chunked stream), so an endless
/// broadcast needs no special case; leaving the screen stops
/// the session in dispose, which is what a channel switch is.
/// The wakelock follows the playing stream exactly as it does
/// for recordings.
///
/// Plan 42: for live viewing, mpv's "Cannot seek in this
/// stream." complaint no longer fails the start. mpv queues an
/// initial seek for streams whose timestamps do not start at
/// zero (observed with DR broadcasts on Android) and reports
/// the refusal at error level even though playback itself is
/// unaffected; the live stream is unseekable by design, so the
/// complaint is logged and ignored (see player_error_policy).
/// Recorded playback keeps the previous behaviour.
///
/// Plan 53: subtitle (caption) and sub-audio controls. Every
/// stream kind carries its ARIB caption as a separate subtitle
/// track (measured; see player_track_policy), so the caption
/// toggle is mpv's subtitle track selection — and because mpv
/// may auto-select a caption track matching the device
/// language, the default-off state is forced (sid=no before
/// open, re-applied when the track list settles) until the
/// user turns captions on. Dual-audio programmes carry a
/// second audio track; when two or more audio tracks exist an
/// audio switcher （主音声 / 副音声） is offered. Both selections
/// live only in this screen's state and nothing is persisted —
/// unlike the quality choice, which the detail screens keep
/// in the saved playback quality.
///
/// Plan 54 corrections, driven by the owner's build-20 device
/// log and desktop-mpv measurements on the same streams:
/// (1) media_kit's synthetic 'auto'/'no' list entries are no
/// longer counted as tracks — plan 53's menu sent "副音声" on
/// a single-audio stream to aid=no (silence). Real tracks
/// only; see player_track_policy.
/// (2) mpv's demuxer cache stalls audio track switching on
/// unseekable streams indefinitely (measured: still no audio
/// decode 30 s after a switch; the same switch from a file
/// settles in ~0.15 s, and with cache=no in ~2 s), so the
/// player disables mpv's cache before open. Jitter buffering
/// is the proxy prefetch queue's job, not mpv's cache.
/// (3) The caption toggle's selection is correct, but the
/// bundled ffmpeg builds carry no ARIB caption decoder
/// (plan 54; see player_track_policy), so captions cannot
/// render until the libmpv builds gain one.
///
/// Plan 86: a recording can open at the resume position the
/// nasne holds for it ([PlayerScreen.initialStart]); the title
/// detail asks whether to continue from there or start over.
/// Before this the position was fetched and displayed but never
/// used, so every viewing of a long programme restarted at the
/// beginning (plan 85 item 1).
///
/// Plan 102: the other half of that pair — leaving this screen
/// reports where the viewing stopped ([PlayerScreen
/// .onResumePosition]), because the unit does not learn a
/// position from being streamed to: its points stayed zero
/// through every HB playback until this write existed, so
/// "continue" could never be offered for them. The terms of
/// the report (nothing when playback never started, zero —
/// a cleared point — when it ran to the end) are
/// player_resume_policy's.
///
/// Plan 104: leaving the screen could fail to stop the
/// audio. The plan-102 report ran first in dispose and read
/// the diagnostics log through ref; Riverpod 3 forbids ref
/// once the widget is deactivating, so the read threw a
/// StateError that aborted dispose before the player was
/// disposed and the session stopped — the screen went back
/// to the list and mpv kept playing (field report). Live
/// viewing escaped only because it has no report to send.
/// Dispose now decides the report from the state's own
/// fields, reads no provider (the log is captured in a
/// field at initState), and runs every teardown step —
/// player stop and dispose, session stop, the report last —
/// unconditionally through player_teardown_policy, each
/// guarded so one failure cannot starve the rest.
///
/// Plan 86 (plan 85 item 7): recorded playback gains a speed
/// control in the app bar (1.0 / 1.25 / 1.5 / 2.0, applied via
/// mpv's rate with pitch-corrected audio). Live viewing is
/// excluded — a live stream has nothing to catch up from
/// (see player_speed_policy).
///
/// Plan 86 (plan 85 item 9): the start-failure view leads
/// with a plain explanation and what to do next; the raw
/// player error moves into a collapsed detail section,
/// matching the playback error dialog (playback_launcher).
///
/// Plan 80: the seek-freeze fixes. Recorded playback now
/// runs with mpv's cache on (see player_cache_policy) so
/// the demuxer's re-reads stop round-tripping the proxy.
/// And a playback that had started and then dies mid-stream
/// — a fatal error after the start, or the silent stall of
/// plan 78, where mpv stopped on the last frame with no
/// error at all — is surfaced as an interruption over the
/// frozen frame, with a resume action that re-opens the
/// same session stream in place, instead of the screen
/// failing wholesale as if the start had been bad.
///
/// Player UI follow-up (after 1.4.0), from the owner's
/// device feedback: the recorded screen's transport row
/// gains ±10 s skip buttons, and the seek bar gains a
/// taller touch target. The buttons follow mpv's own
/// `seekable` property and stay disabled while the stream
/// is not seekable — with the loopback proxy's chunked,
/// range-less responses that is today's steady state (see
/// player_seek_policy). The seek bar's stock Material
/// theme leaves it flush with the bottom edge outside
/// fullscreen (zero margin, and the controls take no
/// safe-area padding there), under the iPhone home
/// indicator where a thumb cannot reach it; the themes
/// below raise its container height and thumb size and
/// lift the non-fullscreen bar off the edge.
///
/// The fixed lift alone did not clear the indicator on
/// the owner's devices (plan 105): the bottom margins
/// of the seek bar and of the bottom button bar sharing
/// its stack now grow by the device's actual bottom
/// view padding, so the whole touch target and the
/// button row sit above the gesture area, and the
/// interruption banner pads itself the same way (see
/// player_safe_area_policy).
///
/// Plan 112: chapter skip for recordings. The points
/// are the unit's own silence-cut chapters, fetched
/// once as the screen opens ([PlayerScreen.loadChapters])
/// and validated on the way in (see the core chapter
/// parsing) — a title whose data is absent or broken
/// simply has no chapter controls, and no interval
/// fallback stands in for them. The transport rows
/// gain previous / next chapter buttons beside the
/// ±10 s skips, following the same seekable signal,
/// and the seek bar gains a tick at each point: the
/// bar is media_kit's, built inside its controls with
/// no slot for markers, so the ticks are an overlay
/// aligned to the bar from the same theme values the
/// controls lay it out with (see player_chapter_policy
/// and _ChapterTicksOverlay). Live viewing has no
/// chapters and is untouched.
library;

import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' show Directory, Platform;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app/firetv_helper.dart';
import '../app/mpv_compat.dart';
import 'channel_badge.dart';
import '../app/providers.dart';
import '../core/core.dart';
import '../core/dtcp/arib_ts_caption_tap.dart';
import 'epg_genre.dart';
import 'format.dart';
import 'live_channel_switch_policy.dart';
import 'live_recording_policy.dart';
import 'multi_nasne_policy.dart';
import 'widgets.dart';
import 'player_cache_policy.dart';
import 'player_chapter_policy.dart';
import 'player_error_policy.dart';
import 'player_resume_policy.dart';
import 'player_seek_policy.dart';
import 'player_speed_policy.dart';
import 'player_teardown_policy.dart';
import 'player_track_policy.dart';
import 'subtitle_overlay.dart';
import 'subtitle_style_policy.dart';

/// Returns the overlay spinner caption while waiting for initial video frames
/// or recovering from mid-stream buffering, or `null` once ready/paused.
String? playerLoadingLabel({
  required bool interrupted,
  required bool hasVideoFrame,
  required bool playingStarted,
  required bool playingNow,
  required bool buffering,
}) {
  if (interrupted) return null;
  if (!hasVideoFrame || !playingStarted) return '読み込み中…';
  if (buffering && playingNow) return 'バッファリング中…';
  return null;
}

/// Returns `true` only once actual playback frames are flowing, so a
/// premature `playing=true` emission before the first decoded video frame never
/// disarms the startup timeout watchdog.
bool shouldCancelStartWatchdog({
  required bool hasVideoFrame,
  required bool playingNow,
  required bool buffering,
  required bool initialPlaybackStarted,
}) => initialPlaybackStarted || (hasVideoFrame && playingNow && !buffering);

/// Returns `true` only when at least one frame has been rendered (or initial
/// playback latched); pre-frame stops belong to the startup failure/watchdog
/// path rather than the frozen-frame mid-stream interruption banner.
bool shouldSurfacePreFrameStopAsInterruption({
  required bool hasVideoFrame,
  required bool initialPlaybackStarted,
}) => hasVideoFrame || initialPlaybackStarted;

/// Formats an upstream error into a secret-free classification string for
/// release diagnostics (never includes URLs, keys, credentials, or IPs).
String describeStreamErrorSafely(Object? error) {
  if (error == null) return 'none';
  if (error is NasneError) {
    final code = error.code;
    return code != null && code.isNotEmpty
        ? '${error.category.name}($code)'
        : error.category.name;
  }
  return error.runtimeType.toString();
}

/// Combines [description] and [longDescription] for the in-player OSD detail
/// viewer, deduplicating identical or prefix-contained text.
String? formatProgramDetailBody({
  String? description,
  String? longDescription,
}) {
  final short = description?.trim() ?? '';
  final long = longDescription?.trim() ?? '';
  if (short.isEmpty && long.isEmpty) return null;
  if (short.isEmpty) return long;
  if (long.isEmpty) return short;
  if (long == short || long.startsWith(short)) return long;
  if (short.startsWith(long)) return short;
  return '$short\n\n$long';
}

/// Unified rectangular status badge used in the player OSD header so `録画中`,
/// `バッファ`, and `LIVE` share matching corner radius, padding, height, and font size.
Widget buildPlayerOsdStatusBadge({
  required String label,
  required Color color,
  IconData? icon,
  Color textColor = Colors.white,
  Border? border,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(4),
      border: border,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 10, color: textColor),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            height: 1.2,
          ),
        ),
      ],
    ),
  );
}

/// Returns the primary OSD header live status badge label and color for
/// real-time vs paused / delayed chase / playback after pausing.
({String label, Color color}) osdLiveStatusBadgeSpec({
  required bool liveDelayedByPause,
  required double liveCatchUpRate,
  bool isPaused = false,
  bool isRewoundPlayback = false,
}) {
  if (!liveDelayedByPause) {
    return (label: 'LIVE', color: Colors.redAccent);
  }
  if (isPaused) {
    return (label: '一時停止', color: const Color(0xFF2E7D32));
  }
  if (liveCatchUpRate > 1.0) {
    return (
      label: '追いかけ再生 ${playbackSpeedLabel(liveCatchUpRate)}',
      color: const Color(0xFFEF6C00),
    );
  }
  if (isRewoundPlayback) {
    return (label: 'プレイバック', color: const Color(0xFF0277BD));
  }
  return (label: '追いかけ再生', color: const Color(0xFFEF6C00));
}

/// Returns the ordered status badges and matching progress-bar accent color
/// for both the live OSD menu and the bottom seek HUD.
({
  List<({String label, Color color})> badges,
  Color barColor,
}) liveStatusPresentation({
  required bool liveDelayedByPause,
  required double liveCatchUpRate,
  bool isPaused = false,
  bool isRewoundPlayback = false,
}) {
  if (!liveDelayedByPause) {
    return (
      badges: const [(label: 'LIVE', color: Colors.redAccent)],
      barColor: Colors.redAccent,
    );
  }
  if (isPaused && isRewoundPlayback) {
    return (
      badges: const [
        (label: 'プレイバック', color: Color(0xFF0277BD)),
        (label: '一時停止', color: Color(0xFF2E7D32)),
      ],
      barColor: Colors.lightBlueAccent,
    );
  }
  if (isPaused) {
    return (
      badges: const [(label: '一時停止', color: Color(0xFF2E7D32))],
      barColor: const Color(0xFF66BB6A),
    );
  }
  if (isRewoundPlayback) {
    return (
      badges: const [(label: 'プレイバック', color: Color(0xFF0277BD))],
      barColor: Colors.lightBlueAccent,
    );
  }
  return (
    badges: [
      (
        label: liveCatchUpRate > 1.0
            ? '追いかけ再生 ${playbackSpeedLabel(liveCatchUpRate)}'
            : '追いかけ再生',
        color: const Color(0xFFEF6C00),
      ),
    ],
    barColor: Colors.orangeAccent,
  );
}

/// Returns whether D-pad left/right keys during live playback should switch
/// TV channels (true only while playing live at the real-time edge).
bool canSwitchLiveChannelOnDirectionKey({
  required bool live,
  required bool liveDelayedByPause,
  required bool playingNow,
}) =>
    live && !liveDelayedByPause && playingNow;

/// Signed relative seek delta (seconds) for D-pad left/right during live
/// pause/playback/chase mode.
double liveDirectionKeySeekDeltaSeconds({required bool forward}) => forward
    ? PlayerScreen.forwardStep.inSeconds.toDouble()
    : PlayerScreen.rewindStep.inSeconds.toDouble();

/// Builds the live recording confirmation dialog body text, appending a notice
/// when the viewer is currently paused or playing behind the live edge.
String buildLiveRecordingConfirmContent({
  required String titleText,
  required String qualityLabel,
  required bool liveDelayedByPause,
}) {
  final base = '番組: $titleText\n録画画質: $qualityLabel';
  if (!liveDelayedByPause) return base;
  return '$base\n\n※録画は現在の放送位置から開始されます（巻き戻し位置からは録画できません）';
}

/// Returns the OSD button label for toggling playback stream quality.
String osdQualityButtonLabel({required bool useMobile}) =>
    useMobile ? '画質: モバイル' : '画質: 元画質';

/// Returns the resolution-neutral OSD button icon for playback quality switch.
IconData osdQualityButtonIcon({required bool useMobile}) =>
    Icons.video_settings;

/// Returns whether the top-right corner notice overlay should be visible.
bool shouldShowPlayerCornerNotice({
  required LiveRecordingCornerNotice? cornerRecordingNotice,
  required String? customCornerNoticeText,
  required bool osdOpen,
  required bool detailOpen,
  required bool interrupted,
  required String? error,
  required bool switchingChannel,
}) =>
    (cornerRecordingNotice != null || customCornerNoticeText != null) &&
    !osdOpen &&
    !detailOpen &&
    !interrupted &&
    error == null &&
    !switchingChannel;

/// Reconciles the player's local reservation snapshot and stopped-id guard
/// after a live-OSD start or stop action so delayed nasne XSRS deletes never
/// resurrect stale active-recording badges.
({List<RecordSchedule> schedules, Set<String> stoppedIds})
reconcileLiveRecordingSchedules({
  required List<RecordSchedule> currentSchedules,
  required Set<String> currentStoppedIds,
  required bool isStopAction,
  required bool actionSucceeded,
  String? targetScheduleId,
  List<RecordSchedule>? updatedSchedules,
}) {
  final nextStopped = Set<String>.of(currentStoppedIds);
  if (isStopAction) {
    if (actionSucceeded && targetScheduleId != null) {
      nextStopped.add(targetScheduleId);
    }
    final nextList = schedulesExcludingIds(
      updatedSchedules ?? currentSchedules,
      nextStopped,
    );
    return (schedules: nextList, stoppedIds: nextStopped);
  }
  if (actionSucceeded && updatedSchedules != null) {
    for (final s in updatedSchedules) {
      nextStopped.remove(s.id);
    }
  }
  final nextList = updatedSchedules == null
      ? schedulesExcludingIds(currentSchedules, nextStopped)
      : schedulesExcludingIds(updatedSchedules, nextStopped);
  return (schedules: nextList, stoppedIds: nextStopped);
}

/// Returns whether a paused live stream can catch up to live edge seamlessly
/// within mpv's in-memory/disk demuxer cache without dropping to proxy reset.
bool canSeekWithinLiveCache({
  required bool useCache,
  required int configuredBufferSeconds,
  required double totalPauseLagSeconds,
  required double cacheDurationSeconds,
  required double cacheTimeSeconds,
  required double timePosSeconds,
}) {
  if (!useCache || configuredBufferSeconds <= 0) return false;
  if (!cacheDurationSeconds.isFinite ||
      !cacheTimeSeconds.isFinite ||
      !timePosSeconds.isFinite) {
    return false;
  }
  return cacheDurationSeconds >= 1.5 &&
      cacheTimeSeconds > timePosSeconds + 1.0 &&
      totalPauseLagSeconds <= configuredBufferSeconds;
}

/// Top-right overlay notice for custom live messages or recording start/end.
class PlayerCornerNotice extends StatelessWidget {
  const PlayerCornerNotice({
    super.key,
    this.customText,
    this.recordingNotice,
  });

  final String? customText;
  final LiveRecordingCornerNotice? recordingNotice;

  @override
  Widget build(BuildContext context) {
    if (customText != null) {
      return Positioned(
        top: 16,
        right: 20,
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xCC1E3A5F),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.swap_horiz, size: 14, color: Colors.white),
                const SizedBox(width: 4),
                Text(
                  customText!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final notice = recordingNotice;
    if (notice == null) return const SizedBox.shrink();
    final ended = notice == LiveRecordingCornerNotice.ended;
    return Positioned(
      top: 16,
      right: 20,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: ended ? const Color(0xCC263238) : const Color(0xFFC62828),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ended ? Icons.stop : Icons.fiber_manual_record,
                size: 13,
                color: Colors.white,
              ),
              const SizedBox(width: 4),
              Text(
                ended ? '録画終了' : '録画中',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slide-in borderless card anchored flush to the left or right screen edge for
/// two-step D-pad channel switching during live TV playback.
class LiveChannelSwitchPreviewCard extends StatelessWidget {
  const LiveChannelSwitchPreviewCard({
    super.key,
    required this.direction,
    required this.visible,
    required this.entry,
    this.resolvedProgram,
    this.channelNumber,
    this.channelLogoBytes,
    required this.onTap,
  });

  final ChannelSwitchDirection direction;
  final bool visible;
  final LiveChannelSwitchEntry? entry;
  final ResolvedLiveSwitchProgram? resolvedProgram;
  final String? channelNumber;
  final Uint8List? channelLogoBytes;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isNext = direction == ChannelSwitchDirection.next;
    final alignment = isNext ? Alignment.centerRight : Alignment.centerLeft;
    final hiddenOffset = isNext ? const Offset(1.05, 0) : const Offset(-1.05, 0);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xD90D1117) : const Color(0xF5FFFFFF);
    final accentColor = isDark ? Colors.amberAccent : const Color(0xFF3949AB);
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final metaColor = isDark ? Colors.white70 : const Color(0xFF4B5563);
    final hintColor = isDark ? Colors.white60 : const Color(0xFF6B7280);
    final shadowColor = isDark ? Colors.black54 : Colors.black26;
    final cardRadius = isNext
        ? const BorderRadius.only(
            topLeft: Radius.circular(14),
            bottomLeft: Radius.circular(14),
          )
        : const BorderRadius.only(
            topRight: Radius.circular(14),
            bottomRight: Radius.circular(14),
          );
    final innerPadding = isNext
        ? const EdgeInsets.fromLTRB(18, 14, 22, 14)
        : const EdgeInsets.fromLTRB(22, 14, 18, 14);
    final cardKey = ValueKey(
      isNext ? 'live_channel_preview_next' : 'live_channel_preview_previous',
    );
    final data = entry;
    final timeRange = resolvedProgram != null
        ? resolvedProgram!.broadcastTimeRange
        : data?.broadcastTimeRange;
    final programTitle = resolvedProgram?.programTitle ?? data?.programTitle;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: Align(
          alignment: alignment,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : hiddenOffset,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: visible && data != null ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 180),
              child: data == null
                  ? const SizedBox.shrink()
                  : ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 260,
                        maxWidth: 340,
                      ),
                      child: GestureDetector(
                        onTap: onTap,
                        child: Container(
                          key: cardKey,
                          padding: innerPadding,
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: cardRadius,
                            boxShadow: [
                              BoxShadow(
                                color: shadowColor,
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!isNext) ...[
                                    Icon(
                                      Icons.chevron_left,
                                      size: 16,
                                      color: accentColor,
                                    ),
                                    const SizedBox(width: 2),
                                  ],
                                  Text(
                                    isNext ? '次のチャンネル' : '前のチャンネル',
                                    style: TextStyle(
                                      color: accentColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (isNext) ...[
                                    const SizedBox(width: 2),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 16,
                                      color: accentColor,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  if (channelLogoBytes != null) ...[
                                    ChannelLogoPlate(
                                      bytes: channelLogoBytes!,
                                      width: 38,
                                      height: 22,
                                      darkSurface: isDark,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  if (channelNumber != null) ...[
                                    ChannelNumberBadge(
                                      label: channelNumber!,
                                      darkSurface: isDark,
                                      compact: true,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      data.displayChannelName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                programTitle ?? data.programTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: titleColor,
                                  fontSize: 14,
                                  height: 1.3,
                                ),
                              ),
                              if (timeRange != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  timeRange,
                                  style: TextStyle(
                                    color: metaColor,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'もう一度 ',
                                    style: TextStyle(
                                      color: hintColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                  if (isNext)
                                    Icon(
                                      Icons.play_arrow,
                                      size: 12,
                                      color: hintColor,
                                    )
                                  else
                                    Transform.flip(
                                      flipX: true,
                                      child: Icon(
                                        Icons.play_arrow,
                                        size: 12,
                                        color: hintColor,
                                      ),
                                    ),
                                  Text(
                                    ' / 決定 で切替',
                                    style: TextStyle(
                                      color: hintColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// High-contrast button style for [PlayerOsdButtonBar] items so D-pad focus is
/// immediately visible over video playback.
ButtonStyle osdButtonStyle() {
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return Colors.amberAccent;
      }
      return Colors.white12;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return Colors.black;
      }
      return Colors.white;
    }),
    iconColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return Colors.black;
      }
      return Colors.white;
    }),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: Colors.white, width: 2.5);
      }
      return const BorderSide(color: Colors.white38);
    }),
    elevation: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused) ? 4 : 0,
    ),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) return Colors.white24;
      return Colors.transparent;
    }),
  );
}

/// Label for the OSD button that dismisses only the OSD menu bar.
const String playerOsdCloseMenuLabel = 'メニューを閉じる';

/// Seekable demuxer cache bounds reported by mpv `demuxer-cache-state`.
class LiveDemuxerCacheRange {
  const LiveDemuxerCacheRange({
    required this.startSeconds,
    required this.endSeconds,
    this.cacheDurationSeconds,
    this.liveEdgeSeconds,
    this.earliestStartSeconds,
  });

  final double startSeconds;
  final double endSeconds;
  final double? cacheDurationSeconds;
  final double? liveEdgeSeconds;
  final double? earliestStartSeconds;

  double get spanSeconds => math.max(0.0, endSeconds - startSeconds);
}

double? _jsonFiniteDouble(Object? raw) {
  final double? value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw);
  } else {
    value = null;
  }
  return (value != null && value.isFinite) ? value : null;
}

/// Extracts `cache-duration` (in seconds) from mpv's JSON `demuxer-cache-state`
/// property, or returns `null` when unavailable or unparseable.
double? parseDemuxerCacheStateDuration(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final value = _jsonFiniteDouble(decoded['cache-duration']);
    if (value == null || value < 0) return null;
    return value;
  } catch (_) {
    return null;
  }
}

/// Extracts active `seekable-ranges` `[startSeconds, endSeconds]` and optional
/// `cache-duration` from mpv's JSON `demuxer-cache-state`.
LiveDemuxerCacheRange? parseDemuxerCacheStateRange(
  String raw, {
  double? currentPosSeconds,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final rawCacheDur = _jsonFiniteDouble(decoded['cache-duration']);
    final cacheDur =
        (rawCacheDur != null && rawCacheDur >= 0) ? rawCacheDur : null;
    final rawRanges = decoded['seekable-ranges'];
    if (rawRanges is! List || rawRanges.isEmpty) return null;
    final ranges = <({double start, double end})>[];
    for (final item in rawRanges) {
      if (item is! Map) continue;
      final start = _jsonFiniteDouble(item['start']);
      final end = _jsonFiniteDouble(item['end']);
      if (start == null || end == null || end < start) continue;
      ranges.add((start: start, end: end));
    }
    if (ranges.isEmpty) return null;
    var earliestStart = ranges.first.start;
    var latestEnd = ranges.first.end;
    for (final r in ranges) {
      if (r.start < earliestStart) earliestStart = r.start;
      if (r.end > latestEnd) latestEnd = r.end;
    }
    if (currentPosSeconds != null && currentPosSeconds.isFinite) {
      for (final r in ranges) {
        if (currentPosSeconds >= r.start - 1.0 &&
            currentPosSeconds <= r.end + 1.0) {
          return LiveDemuxerCacheRange(
            startSeconds: r.start,
            endSeconds: r.end,
            cacheDurationSeconds: cacheDur,
            liveEdgeSeconds: latestEnd,
            earliestStartSeconds: earliestStart,
          );
        }
      }
    }
    final chosen = ranges.last;
    return LiveDemuxerCacheRange(
      startSeconds: chosen.start,
      endSeconds: chosen.end,
      cacheDurationSeconds: cacheDur,
      liveEdgeSeconds: latestEnd,
      earliestStartSeconds: earliestStart,
    );
  } catch (_) {
    return null;
  }
}

/// Computes a clamped timeshift seek target inside the buffered live cache
/// `[cacheStartSeconds, cacheEndSeconds]` and reports whether the target hits
/// the cache head or reaches the live edge.
({double targetSeconds, bool hitStart, bool reachedLiveEdge})
resolveLiveTimeshiftSeekTarget({
  required double currentPosSeconds,
  required double deltaSeconds,
  required double cacheStartSeconds,
  required double cacheEndSeconds,
  double startMarginSeconds = 0.5,
  double liveEdgeMarginSeconds = 0.5,
  double liveEdgeSnapThresholdSeconds = 1.5,
}) {
  final minTarget = math.min(
    cacheEndSeconds,
    cacheStartSeconds + startMarginSeconds,
  );
  final maxTarget = math.max(
    minTarget,
    cacheEndSeconds - liveEdgeMarginSeconds,
  );
  final desired = currentPosSeconds + deltaSeconds;
  final target = desired.clamp(minTarget, maxTarget).toDouble();
  final hitStart = deltaSeconds < 0 && desired <= minTarget + 0.05;
  final reachedLiveEdge =
      deltaSeconds > 0 &&
      (cacheEndSeconds - target) <= liveEdgeSnapThresholdSeconds;
  return (
    targetSeconds: target,
    hitStart: hitStart,
    reachedLiveEdge: reachedLiveEdge,
  );
}

/// Resolves the live playback position inside mpv's `seekable-ranges` coordinate
/// space, preferring `playback-time` when `demuxer-start-time` shifts PTS away
/// from `0`, and falling back to `time-pos` or [fallbackSeconds].
double resolveLiveCacheCoordinatePos({
  required double? playbackTimeSeconds,
  required double? timePosSeconds,
  required double cacheStartSeconds,
  required double cacheEndSeconds,
  required double fallbackSeconds,
}) {
  bool inRange(double? v) =>
      v != null &&
      v.isFinite &&
      v >= cacheStartSeconds - 5.0 &&
      v <= cacheEndSeconds + 5.0;
  if (inRange(playbackTimeSeconds)) return playbackTimeSeconds!;
  if (inRange(timePosSeconds)) return timePosSeconds!;
  if (playbackTimeSeconds != null && playbackTimeSeconds.isFinite) {
    return playbackTimeSeconds;
  }
  if (timePosSeconds != null && timePosSeconds.isFinite) {
    return timePosSeconds;
  }
  return fallbackSeconds;
}

/// Immediately clamps an accumulated D-pad rewind/forward delta against the
/// currently buffered `[cacheStartSeconds, cacheEndSeconds]` window so rapid or
/// long-held presses never run past playable cache bounds.
({double clampedDelta, bool hitStart, bool hitEnd, bool hasCache})
clampLivePendingSeekDelta({
  required double basePosSeconds,
  required double desiredDeltaSeconds,
  required double? cacheStartSeconds,
  required double? cacheEndSeconds,
  double startMarginSeconds = 1.0,
  double liveEdgeMarginSeconds = 0.5,
}) {
  if (cacheStartSeconds == null ||
      cacheEndSeconds == null ||
      !cacheStartSeconds.isFinite ||
      !cacheEndSeconds.isFinite ||
      (cacheEndSeconds - cacheStartSeconds) <
          (startMarginSeconds + liveEdgeMarginSeconds + 0.5)) {
    return (
      clampedDelta: 0.0,
      hitStart: desiredDeltaSeconds < 0,
      hitEnd: desiredDeltaSeconds > 0,
      hasCache: false,
    );
  }
  final minTarget = cacheStartSeconds + startMarginSeconds;
  final maxTarget = math.max(minTarget, cacheEndSeconds - liveEdgeMarginSeconds);
  final desiredTarget = basePosSeconds + desiredDeltaSeconds;
  final clampedTarget = desiredTarget.clamp(minTarget, maxTarget).toDouble();
  return (
    clampedDelta: clampedTarget - basePosSeconds,
    hitStart: desiredDeltaSeconds < 0 && desiredTarget <= minTarget + 0.05,
    hitEnd: desiredDeltaSeconds > 0 && desiredTarget >= maxTarget - 0.05,
    hasCache: true,
  );
}

/// Returns whether the 1-second OSD clock timer should poll mpv cache bounds.
bool shouldPollLiveCacheOnOsdTick({
  required bool live,
  required bool osdOpen,
  required bool switchingChannel,
  required bool conflictHandled,
  required bool catchUpMonitorActive,
  bool initialPlaybackStarted = true,
  bool buffering = false,
}) =>
    live &&
    osdOpen &&
    initialPlaybackStarted &&
    !buffering &&
    !switchingChannel &&
    !conflictHandled &&
    !catchUpMonitorActive;

/// Merges [primary] EPG events with non-overlapping [fallback] history
/// entries so programme metadata observed earlier stays available on rewind.
List<EpgEvent> mergeLiveProgramEventLists(
  List<EpgEvent> primary,
  List<EpgEvent> fallback,
) {
  if (fallback.isEmpty) return primary;
  if (primary.isEmpty) return fallback;
  final merged = List<EpgEvent>.of(primary);
  for (final fb in fallback) {
    final overlaps = primary.any(
      (p) => fb.start.isBefore(p.end) && fb.end.isAfter(p.start),
    );
    if (!overlaps) {
      merged.add(fb);
    }
  }
  merged.sort((a, b) => a.start.compareTo(b.start));
  return merged;
}

int? _roundedCacheSpanSeconds(double? start, double? end) {
  if (start == null || end == null || !start.isFinite || !end.isFinite) {
    return null;
  }
  return math.max(0.0, end - start).round();
}

/// Returns whether any displayed live cache bound, playback position,
/// rewindable duration, or lag readout changed enough to warrant a rebuild.
bool hasLiveCacheRangeDisplayChanged({
  double? prevStart,
  double? prevEnd,
  double? prevPos,
  double? nextStart,
  double? nextEnd,
  double? nextPos,
}) {
  if (prevStart?.floor() != nextStart?.floor() ||
      prevEnd?.floor() != nextEnd?.floor() ||
      prevPos?.floor() != nextPos?.floor()) {
    return true;
  }
  if (_roundedCacheSpanSeconds(prevStart, prevEnd) !=
      _roundedCacheSpanSeconds(nextStart, nextEnd)) {
    return true;
  }
  if (_roundedCacheSpanSeconds(prevPos, prevEnd) !=
      _roundedCacheSpanSeconds(nextPos, nextEnd)) {
    return true;
  }
  return false;
}

/// Computes the active live playback delay (in seconds behind the live edge).
///
/// When [streamEpoch] and [now] are provided alongside a finite
/// [effectivePosSeconds], delay is measured directly against the fixed stream
/// epoch so paused playback stays locked on the paused programme even if mpv's
/// cache end stalls at buffer capacity or EOS.
double resolveLivePlaybackLagSeconds({
  required bool liveDelayedByPause,
  double? cacheStartSeconds,
  double? cacheEndSeconds,
  double? liveEdgeSeconds,
  double? effectivePosSeconds,
  double fallbackLagSeconds = 0.0,
  DateTime? streamEpoch,
  DateTime? now,
  double? bufferedAheadSeconds,
  bool isScrubbing = false,
}) {
  if (!liveDelayedByPause) return 0.0;
  if (streamEpoch != null &&
      now != null &&
      effectivePosSeconds != null &&
      effectivePosSeconds.isFinite) {
    final fromEpoch = streamEpoch.add(
      Duration(milliseconds: (effectivePosSeconds * 1000).round()),
    );
    final diff = now.difference(fromEpoch);
    if (diff >= const Duration(seconds: -10) &&
        diff <= const Duration(hours: 12)) {
      return math.max(0.0, diff.inMilliseconds / 1000.0);
    }
  }
  final effectiveLiveEdge = liveEdgeSeconds ?? cacheEndSeconds;
  final rewindableRaw =
      (cacheStartSeconds != null &&
          effectiveLiveEdge != null &&
          cacheStartSeconds.isFinite &&
          effectiveLiveEdge.isFinite &&
          effectiveLiveEdge > cacheStartSeconds)
      ? (effectiveLiveEdge - cacheStartSeconds)
      : 0.0;
  if (effectiveLiveEdge != null &&
      effectivePosSeconds != null &&
      effectiveLiveEdge.isFinite &&
      effectivePosSeconds.isFinite &&
      effectivePosSeconds <= effectiveLiveEdge + 5.0 &&
      (cacheStartSeconds == null ||
          !cacheStartSeconds.isFinite ||
          effectivePosSeconds >= cacheStartSeconds - 5.0)) {
    final rangeLag = (effectiveLiveEdge - effectivePosSeconds)
        .clamp(0.0, rewindableRaw > 0 ? rewindableRaw : double.infinity)
        .toDouble();
    if (!isScrubbing &&
        bufferedAheadSeconds != null &&
        bufferedAheadSeconds.isFinite &&
        bufferedAheadSeconds > rangeLag) {
      return math.max(rangeLag, bufferedAheadSeconds);
    }
    return rangeLag;
  }
  return math.max(0.0, fallbackLagSeconds);
}

/// Maps wall clock [now] and playback [lagSeconds] to the broadcast timestamp
/// of the video frame currently playing.
DateTime resolveLivePlaybackClock({
  required DateTime now,
  required double lagSeconds,
  DateTime? streamEpoch,
  double? effectivePosSeconds,
  bool liveDelayedByPause = true,
}) {
  if (!liveDelayedByPause) return now;
  if (streamEpoch != null &&
      effectivePosSeconds != null &&
      effectivePosSeconds.isFinite) {
    final fromEpoch = streamEpoch.add(
      Duration(milliseconds: (effectivePosSeconds * 1000).round()),
    );
    final diff = now.difference(fromEpoch);
    if (diff >= const Duration(seconds: -10) &&
        diff <= const Duration(hours: 12)) {
      return fromEpoch.isAfter(now) ? now : fromEpoch;
    }
  }
  if (!lagSeconds.isFinite || lagSeconds <= 0.5) return now;
  return now.subtract(Duration(milliseconds: (lagSeconds * 1000).round()));
}

/// Returns `true` when cached live EPG data in the player has exceeded [maxAge]
/// and should be silently refreshed on OSD open.
bool shouldRefreshPlayerLiveGuide({
  required DateTime? lastUpdatedAt,
  required DateTime now,
  Duration maxAge = const Duration(minutes: 10),
}) =>
    lastUpdatedAt != null && now.difference(lastUpdatedAt) >= maxAge;

/// Combined state for the single programme-total progress / timeshift bar,
/// mapping the real-time live edge, earliest rewindable cache position, and
/// active playback/seek cursor onto `[0.0, 1.0]`.
class LiveTimeshiftBarState {
  const LiveTimeshiftBarState({
    required this.liveEdgeFraction,
    required this.playableStartFraction,
    required this.playbackFraction,
    required this.rewindableSeconds,
    required this.lagSeconds,
    required this.isTimeshifting,
    required this.usesProgramTimeline,
  });

  final double liveEdgeFraction;
  final double playableStartFraction;
  final double playbackFraction;
  final int rewindableSeconds;
  final int lagSeconds;
  final bool isTimeshifting;
  final bool usesProgramTimeline;
}

/// Maps [info], cache bounds `[cacheStartSeconds, cacheEndSeconds]`, and
/// [effectivePosSeconds] at [now] onto a single unified [LiveTimeshiftBarState].
LiveTimeshiftBarState resolveLiveTimeshiftBarState({
  required LiveOsdProgramInfo? info,
  required DateTime now,
  double? cacheStartSeconds,
  double? cacheEndSeconds,
  double? liveEdgeSeconds,
  double? effectivePosSeconds,
  double fallbackLagSeconds = 0.0,
  required bool liveDelayedByPause,
  DateTime? streamEpoch,
  double? bufferedAheadSeconds,
  bool isScrubbing = false,
}) {
  final effectiveLiveEdge = liveEdgeSeconds ?? cacheEndSeconds;
  final rewindableRaw =
      (cacheStartSeconds != null &&
          effectiveLiveEdge != null &&
          cacheStartSeconds.isFinite &&
          effectiveLiveEdge.isFinite &&
          effectiveLiveEdge > cacheStartSeconds)
      ? (effectiveLiveEdge - cacheStartSeconds)
      : 0.0;
  final rawLag = resolveLivePlaybackLagSeconds(
    liveDelayedByPause: liveDelayedByPause,
    cacheStartSeconds: cacheStartSeconds,
    cacheEndSeconds: cacheEndSeconds,
    liveEdgeSeconds: liveEdgeSeconds,
    effectivePosSeconds: effectivePosSeconds,
    fallbackLagSeconds: fallbackLagSeconds,
    streamEpoch: streamEpoch,
    now: now,
    bufferedAheadSeconds: bufferedAheadSeconds,
    isScrubbing: isScrubbing,
  );

  final start = info?.currentStart;
  final end = info?.currentEnd;
  final double liveEdgeFrac;
  final double playableStartFrac;
  final double playbackFrac;
  final bool usesProgramTimeline;

  if (start != null && end != null && end.isAfter(start)) {
    final totalSec = end.difference(start).inMilliseconds / 1000.0;
    final elapsedSec = now.difference(start).inMilliseconds / 1000.0;
    liveEdgeFrac = (elapsedSec / totalSec).clamp(0.0, 1.0).toDouble();
    final effectiveWindow = math.max(rewindableRaw, rawLag);
    playableStartFrac = ((elapsedSec - effectiveWindow) / totalSec)
        .clamp(0.0, liveEdgeFrac)
        .toDouble();
    playbackFrac = ((elapsedSec - rawLag) / totalSec)
        .clamp(playableStartFrac, liveEdgeFrac)
        .toDouble();
    usesProgramTimeline = true;
  } else {
    liveEdgeFrac = 1.0;
    playableStartFrac = 0.0;
    final denom = math.max(rewindableRaw, rawLag);
    playbackFrac = denom > 0.5
        ? (1.0 - (rawLag / denom)).clamp(0.0, 1.0).toDouble()
        : 1.0;
    usesProgramTimeline = false;
  }

  return LiveTimeshiftBarState(
    liveEdgeFraction: liveEdgeFrac,
    playableStartFraction: playableStartFrac,
    playbackFraction: playbackFrac,
    rewindableSeconds: math.max(0, rewindableRaw.round()),
    lagSeconds: math.max(0, rawLag.round()),
    isTimeshifting: liveDelayedByPause,
    usesProgramTimeline: usesProgramTimeline,
  );
}

/// Returns `true` only once the initial playback has genuinely started and
/// exited mpv's initial pre-buffer pause.
bool shouldLatchInitialPlaybackStarted({
  required bool hasVideoFrame,
  required bool playingNow,
  required bool buffering,
  Duration? positionAtFirstFrame,
  Duration currentPosition = Duration.zero,
  int preBufferTargetSeconds = 0,
  double preBufferCurrentSeconds = 0.0,
}) {
  if (!hasVideoFrame || !playingNow) return false;
  if (preBufferTargetSeconds > 0) {
    final posAdvanced =
        positionAtFirstFrame != null &&
        currentPosition - positionAtFirstFrame >= const Duration(seconds: 1);
    if (posAdvanced) return true;
    return !buffering &&
        preBufferCurrentSeconds >= (preBufferTargetSeconds - 0.5);
  }
  if (!buffering) return true;
  if (positionAtFirstFrame != null &&
      currentPosition - positionAtFirstFrame >= const Duration(seconds: 1)) {
    return true;
  }
  return false;
}

String _formatOverlaySeconds(int seconds) {
  if (seconds <= 0) return '0秒';
  final min = seconds ~/ 60;
  final sec = seconds % 60;
  if (min > 0 && sec > 0) return '$min分$sec秒';
  if (min > 0) return '$min分';
  return '$sec秒';
}

/// Live programme progress and next-programme summary rendered inside the OSD.
class LiveOsdProgramInfo {
  const LiveOsdProgramInfo({
    required this.currentTitle,
    this.currentStart,
    this.currentEnd,
    this.progress,
    this.remainingMinutes,
    this.nextTitle,
    this.nextStart,
    this.nextEnd,
    this.currentEvent,
  });

  final String currentTitle;
  final DateTime? currentStart;
  final DateTime? currentEnd;
  final double? progress;
  final int? remainingMinutes;
  final String? nextTitle;
  final DateTime? nextStart;
  final DateTime? nextEnd;
  final EpgEvent? currentEvent;

  String? get currentTimeRange => (currentStart != null && currentEnd != null)
      ? '${formatTimeJst(currentStart!)}–${formatTimeJst(currentEnd!)}'
      : null;

  String? get nextTimeRange => (nextStart != null && nextEnd != null)
      ? '${formatTimeJst(nextStart!)}–${formatTimeJst(nextEnd!)}'
      : null;
}

/// Resolves the active live programme, its broadcast-time progress ratio, and
/// the upcoming programme from cached/loaded EPG events for [now].
LiveOsdProgramInfo resolveLiveOsdProgramInfo({
  required LiveChannel channel,
  required List<EpgEvent> guideEvents,
  required DateTime now,
}) {
  final sorted = sortEpgEventsByStart(guideEvents);
  final currentEv = findActiveEpgEvent(sorted, now);

  final fallbackTitle = channel.programTitle.trim().isNotEmpty
      ? channel.programTitle.trim()
      : (channel.channelName?.trim() ?? '');
  final currentTitle = (currentEv?.title?.trim().isNotEmpty == true)
      ? currentEv!.title!.trim()
      : fallbackTitle;
  final currentStart = currentEv?.start ?? channel.programStart;
  final currentEnd = currentEv?.end ?? channel.programEnd;

  double? progress;
  int? remainingMinutes;
  if (currentStart != null &&
      currentEnd != null &&
      currentEnd.isAfter(currentStart)) {
    final totalMs = currentEnd.difference(currentStart).inMilliseconds;
    final elapsedMs = now.difference(currentStart).inMilliseconds;
    progress = (elapsedMs / totalMs).clamp(0.0, 1.0).toDouble();
    final remSec = currentEnd.difference(now).inSeconds;
    remainingMinutes = remSec <= 0 ? 0 : ((remSec + 59) ~/ 60);
  }

  EpgEvent? nextEv;
  final anchorEnd = currentEnd;
  for (final ev in sorted) {
    final evTitle = ev.title?.trim() ?? '';
    if (evTitle.isEmpty || !ev.end.isAfter(now)) continue;
    if (currentEv != null &&
        ev.eventId == currentEv.eventId &&
        ev.start == currentEv.start) {
      continue;
    }
    if (currentEv != null) {
      if (!ev.start.isBefore(
        currentEv.end.subtract(const Duration(minutes: 1)),
      )) {
        nextEv = ev;
        break;
      }
    } else if (anchorEnd != null) {
      if (!ev.start.isBefore(
        anchorEnd.subtract(const Duration(minutes: 1)),
      )) {
        nextEv = ev;
        break;
      }
    } else if (ev.start.isAfter(now)) {
      nextEv = ev;
      break;
    }
  }

  return LiveOsdProgramInfo(
    currentTitle: currentTitle,
    currentStart: currentStart,
    currentEnd: currentEnd,
    progress: progress,
    remainingMinutes: remainingMinutes,
    nextTitle: nextEv?.title?.trim(),
    nextStart: nextEv?.start,
    nextEnd: nextEv?.end,
    currentEvent: currentEv,
  );
}

/// On-demand resolved content for the in-player OSD programme detail overlay.
class ResolvedProgramDetail {
  const ResolvedProgramDetail({
    required this.title,
    this.meta,
    this.body,
    this.programEnd,
    this.identityKey,
  });

  final String title;
  final String? meta;
  final String? body;
  final DateTime? programEnd;
  final String? identityKey;

  bool get hasBody => body != null && body!.trim().isNotEmpty;
}

/// Formats full programme detail text from an [EpgEvent] for the OSD viewer.
String? formatEpgEventDetailBody(EpgEvent event) {
  final sections = <String>[];
  final short = event.shortText?.trim() ?? '';
  final desc = event.description?.trim() ?? '';
  if (short.isNotEmpty &&
      (desc.isEmpty || (desc != short && !desc.startsWith(short)))) {
    sections.add(short);
  }
  if (desc.isNotEmpty) {
    sections.add('【番組内容】\n$desc');
  }
  final cast = event.cast?.trim() ?? '';
  if (cast.isNotEmpty) {
    sections.add('【出演者】\n$cast');
  }
  for (final item in event.extendedItems) {
    final val = item.value.trim();
    if (val.isEmpty) continue;
    final label = item.label.trim();
    sections.add(label.isNotEmpty ? '【$label】\n$val' : val);
  }
  final ext = event.extendedText?.trim() ?? '';
  if (ext.isNotEmpty) {
    sections.add(ext);
  }
  return sections.isEmpty ? null : sections.join('\n\n');
}

/// Formats single-line detail metadata (channel, broadcast range, genre) for
/// a [LiveChannel] snapshot.
String? formatLiveChannelDetailMeta(LiveChannel channel) {
  final parts = <String>[];
  final channelName = channel.channelName?.trim() ?? '';
  if (channelName.isNotEmpty) parts.add(channelName);
  final start = channel.programStart;
  final end = channel.programEnd;
  if (start != null && end != null) {
    parts.add('${formatDateTimeWithWeekdayJst(start)}–${formatTimeJst(end)}');
  }
  final genre = channel.genre?.trim() ?? '';
  if (genre.isNotEmpty) parts.add(genre);
  return parts.isEmpty ? null : parts.join(' ・ ');
}

/// Resolves programme detail metadata and body for a live broadcast at [now] on
/// demand, using the active EPG event when available and never leaking an
/// earlier programme's [fallbackBody] into a new event that lacks descriptions.
ResolvedProgramDetail resolveLiveProgramDetail({
  required LiveChannel channel,
  required List<EpgEvent> guideEvents,
  required DateTime now,
  String? fallbackTitle,
  String? fallbackMeta,
  String? fallbackBody,
}) {
  final info = resolveLiveOsdProgramInfo(
    channel: channel,
    guideEvents: guideEvents,
    now: now,
  );
  final currentEv = info.currentEvent;
  if (currentEv != null) {
    final evTitle = (currentEv.title ?? '').trim();
    final title = evTitle.isNotEmpty
        ? evTitle
        : (info.currentTitle.isNotEmpty
            ? info.currentTitle
            : (fallbackTitle ?? ''));
    final sameAsChannel =
        channel.programStart != null &&
        channel.programEnd != null &&
        channel.programStart!.isAtSameMomentAs(currentEv.start) &&
        channel.programEnd!.isAtSameMomentAs(currentEv.end);
    final channelName = channel.channelName?.trim() ?? '';
    final genre =
        epgGenreLabel(currentEv.genreLevel1) ??
        (sameAsChannel ? channel.genre?.trim() : null) ??
        '';
    final metaParts = <String>[
      if (channelName.isNotEmpty) channelName,
      '${formatDateTimeWithWeekdayJst(currentEv.start)}–'
          '${formatTimeJst(currentEv.end)}',
      if (genre.isNotEmpty) genre,
    ];
    final epgBody = formatEpgEventDetailBody(currentEv);
    final channelBody = formatProgramDetailBody(
      description: channel.description,
      longDescription: channel.longDescription,
    );
    final body =
        epgBody ?? (sameAsChannel ? (channelBody ?? fallbackBody) : null);
    return ResolvedProgramDetail(
      title: title,
      meta: metaParts.isEmpty ? null : metaParts.join(' ・ '),
      body: body,
      programEnd: currentEv.end,
      identityKey:
          'epg:${currentEv.eventId}:${currentEv.start.millisecondsSinceEpoch}',
    );
  }

  final channelBody = formatProgramDetailBody(
    description: channel.description,
    longDescription: channel.longDescription,
  );
  final channelMeta = formatLiveChannelDetailMeta(channel);
  final chTitle = channel.programTitle.trim();
  final chName = channel.channelName?.trim() ?? '';
  final resolvedTitle = chTitle.isNotEmpty
      ? chTitle
      : ((fallbackTitle?.trim().isNotEmpty ?? false)
          ? fallbackTitle!.trim()
          : chName);
  final chEnd = channel.programEnd;
  return ResolvedProgramDetail(
    title: resolvedTitle,
    meta: channelMeta ?? fallbackMeta,
    body: channelBody ?? fallbackBody,
    programEnd: (chEnd != null && chEnd.isAfter(now)) ? chEnd : null,
    identityKey:
        'ch:${channel.programStart?.millisecondsSinceEpoch ?? 0}:'
        '${channel.programEnd?.millisecondsSinceEpoch ?? 0}:'
        '${channel.programTitle}',
  );
}

/// Returns whether an open live programme detail panel has crossed a programme
/// boundary and should auto-close so reopening loads the new programme.
bool shouldCloseLiveDetailOnBoundary({
  required DateTime now,
  DateTime? openedProgramEnd,
  String? openedIdentityKey,
  required LiveOsdProgramInfo currentInfo,
}) {
  if (openedProgramEnd != null && !now.isBefore(openedProgramEnd)) {
    return true;
  }
  if (openedIdentityKey != null &&
      openedIdentityKey.startsWith('epg:') &&
      currentInfo.currentEvent != null) {
    final ev = currentInfo.currentEvent!;
    final curKey = 'epg:${ev.eventId}:${ev.start.millisecondsSinceEpoch}';
    if (curKey != openedIdentityKey) return true;
  }
  return false;
}

/// Minimum interval between OSD buffer-badge text refreshes while the OSD is open.
const Duration playerOsdBufferBadgeRefreshInterval = Duration(seconds: 3);

/// Returns whether the OSD buffer badge display should snapshot a new value.
bool shouldRefreshOsdBufferBadge({
  required DateTime? lastUpdatedAt,
  required DateTime now,
  required int displayedSeconds,
  required int actualSeconds,
}) {
  if (lastUpdatedAt == null) return true;
  if (displayedSeconds <= 0 && actualSeconds > 0) return true;
  return now.difference(lastUpdatedAt) >= playerOsdBufferBadgeRefreshInterval;
}

/// Computes soft wide centered shadows for [PlayerOsdClockOverlay], tuned lighter
/// and broader than subtitle [SubtitleEdgeStyle.thickShadow].
List<Shadow> resolveOsdClockTextShadows(double fontSize) {
  return [
    Shadow(
      color: const Color(0xCC000000),
      offset: Offset.zero,
      blurRadius: (fontSize * 0.16).clamp(4.0, 9.0).toDouble(),
    ),
    Shadow(
      color: const Color(0xA6000000),
      offset: Offset.zero,
      blurRadius: (fontSize * 0.34).clamp(8.0, 18.0).toDouble(),
    ),
    Shadow(
      color: const Color(0x80000000),
      offset: Offset.zero,
      blurRadius: (fontSize * 0.58).clamp(14.0, 30.0).toDouble(),
    ),
  ];
}

/// Top-left TV-style clock shown while the OSD is open without details.
class PlayerOsdClockOverlay extends StatelessWidget {
  const PlayerOsdClockOverlay({
    super.key,
    required this.now,
    this.opacity,
  });

  final DateTime now;
  final Animation<double>? opacity;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      formatTimeJst(now),
      style: TextStyle(
        fontFamily: 'GoogleSans',
        color: Colors.white,
        fontSize: 44,
        fontWeight: FontWeight.w500,
        height: 1.0,
        fontFeatures: const [FontFeature.tabularFigures()],
        shadows: resolveOsdClockTextShadows(44),
      ),
    );
    return Positioned(
      top: 22,
      left: 28,
      child: IgnorePointer(
        child: opacity != null
            ? FadeTransition(opacity: opacity!, child: text)
            : text,
      ),
    );
  }
}

/// Single unified progress bar for Live playback and timeshift/playback seek,
/// showing programme total timeline, earliest rewindable boundary, real-time
/// live edge (red marker), and active playback position (white circle thumb).
class LiveProgramProgressBar extends StatelessWidget {
  const LiveProgramProgressBar({
    super.key,
    required this.state,
    this.showDetailsRow = false,
    this.barHeight = 6.0,
    this.accentColor = Colors.lightBlueAccent,
  });

  final LiveTimeshiftBarState state;
  final bool showDetailsRow;
  final double barHeight;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final showTimeshiftOverlay =
        state.rewindableSeconds >= 2 || state.isTimeshifting;
    final thumbDiameter = barHeight + 6.0;
    final trackHeight = thumbDiameter + 4.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: trackHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final liveFrac = state.liveEdgeFraction.clamp(0.0, 1.0);
              final playableStartFrac = state.playableStartFraction.clamp(
                0.0,
                liveFrac,
              );
              final playbackFrac = state.playbackFraction.clamp(
                playableStartFrac,
                liveFrac,
              );
              final playableStartX = width * playableStartFrac;
              final liveX = width * liveFrac;
              final thumbLeft = (width * playbackFrac - (thumbDiameter / 2))
                  .clamp(0.0, math.max(0.0, width - thumbDiameter))
                  .toDouble();
              final tickLeft = (playableStartX - 1.0)
                  .clamp(0.0, math.max(0.0, width - 2.0))
                  .toDouble();
              final liveMarkerLeft = (liveX - 1.5)
                  .clamp(0.0, math.max(0.0, width - 3.0))
                  .toDouble();
              final watchedWidth = math.max(
                0.0,
                width * (playbackFrac - playableStartFrac),
              );

              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(barHeight / 2),
                    child: Container(
                      height: barHeight,
                      width: width,
                      color: Colors.white24,
                    ),
                  ),
                  if (showTimeshiftOverlay) ...[
                    if (playableStartX > 0)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(barHeight / 2),
                        child: Container(
                          height: barHeight,
                          width: playableStartX,
                          color: accentColor.withValues(alpha: 0.32),
                        ),
                      ),
                    if (liveX > playableStartX)
                      Positioned(
                        left: playableStartX,
                        width: liveX - playableStartX,
                        height: barHeight,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(barHeight / 2),
                          child: Container(color: Colors.white54),
                        ),
                      ),
                    if (watchedWidth > 0)
                      Positioned(
                        left: playableStartX,
                        width: watchedWidth,
                        height: barHeight,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(barHeight / 2),
                          child: Container(color: accentColor),
                        ),
                      ),
                    Positioned(
                      left: tickLeft,
                      top: (trackHeight - (barHeight + 6)) / 2,
                      width: 2,
                      height: barHeight + 6,
                      child: const ColoredBox(color: Colors.white),
                    ),
                    Positioned(
                      left: liveMarkerLeft,
                      top: (trackHeight - (barHeight + 8)) / 2,
                      width: 3,
                      height: barHeight + 8,
                      child: const ColoredBox(color: Colors.redAccent),
                    ),
                  ] else
                    ClipRRect(
                      borderRadius: BorderRadius.circular(barHeight / 2),
                      child: Container(
                        height: barHeight,
                        width: liveX,
                        color: accentColor,
                      ),
                    ),
                  Positioned(
                    left: thumbLeft,
                    top: (trackHeight - thumbDiameter) / 2,
                    child: Container(
                      width: thumbDiameter,
                      height: thumbDiameter,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                          color: accentColor,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (showDetailsRow) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                state.rewindableSeconds >= 2
                    ? '戻れる範囲: 最大 -${_formatOverlaySeconds(state.rewindableSeconds)}'
                    : '戻れる範囲: キャッシュ蓄積中',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.redAccent,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                state.lagSeconds <= 1
                    ? '現在位置 (LIVE)'
                    : '現在位置から -${_formatOverlaySeconds(state.lagSeconds)}',
                style: TextStyle(
                  color: state.lagSeconds <= 1 ? Colors.redAccent : Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Live TV OSD panel displaying the current programme, broadcast-time progress
/// bar, remaining minutes, and the upcoming programme from EPG.
class LiveOsdProgramSection extends StatelessWidget {
  const LiveOsdProgramSection({
    super.key,
    required this.info,
    this.timeshift,
    this.accentColor = Colors.lightBlueAccent,
  });

  final LiveOsdProgramInfo info;
  final LiveTimeshiftBarState? timeshift;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final effectiveTimeshift =
        timeshift ??
        (info.progress != null
            ? LiveTimeshiftBarState(
                liveEdgeFraction: info.progress!.clamp(0.0, 1.0),
                playableStartFraction: info.progress!.clamp(0.0, 1.0),
                playbackFraction: info.progress!.clamp(0.0, 1.0),
                rewindableSeconds: 0,
                lagSeconds: 0,
                isTimeshifting: false,
                usesProgramTimeline: true,
              )
            : null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                info.currentTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (info.currentTimeRange != null) ...[
              const SizedBox(width: 12),
              Text(
                info.remainingMinutes != null
                    ? '${info.currentTimeRange}（残り ${info.remainingMinutes}分）'
                    : info.currentTimeRange!,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
        if (effectiveTimeshift != null) ...[
          const SizedBox(height: 6),
          LiveProgramProgressBar(
            state: effectiveTimeshift,
            showDetailsRow:
                effectiveTimeshift.isTimeshifting ||
                effectiveTimeshift.rewindableSeconds >= 2,
            barHeight: 6.0,
            accentColor: accentColor,
          ),
        ],
        if (info.nextTitle != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '次',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (info.nextTimeRange != null) ...[
                Text(
                  info.nextTimeRange!,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  info.nextTitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Recorded playback OSD row matching [LiveOsdProgramSection]'s header line,
/// showing the programme title and original broadcast date/time range.
class RecordedOsdProgramSection extends StatelessWidget {
  const RecordedOsdProgramSection({
    super.key,
    required this.programTitle,
    this.broadcastTimeRange,
  });

  final String programTitle;
  final String? broadcastTimeRange;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            programTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (broadcastTimeRange != null &&
            broadcastTimeRange!.trim().isNotEmpty) ...[
          const SizedBox(width: 12),
          Text(
            broadcastTimeRange!,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

/// Computes the spinner caption and progress bar state for the loading overlay.
/// When Live buffer is set (>= 5s), initial pre-buffering and mid-stream
/// rebuffering share `バッファ蓄積中… X秒 / Y秒` + progress bar; when Live buffer
/// is OFF (0s), it stays on a clean `読み込み中…` without seconds/bar.
({bool showProgressBar, double? progress, String caption})
liveLoadingOverlaySpec({
  required bool isLive,
  required bool isPreBuffering,
  required int targetSeconds,
  required int currentSeconds,
  required double bufferingPercentage,
  required String fallbackLabel,
}) {
  if (targetSeconds > 0 && (isPreBuffering || isLive)) {
    final progress = currentSeconds > 0
        ? (currentSeconds / targetSeconds).clamp(0.0, 1.0).toDouble()
        : (bufferingPercentage > 0
              ? (bufferingPercentage / 100.0).clamp(0.0, 1.0).toDouble()
              : 0.0);
    return (
      showProgressBar: true,
      progress: progress,
      caption:
          'バッファ蓄積中… ${_formatOverlaySeconds(currentSeconds)} / '
          '${_formatOverlaySeconds(targetSeconds)}',
    );
  }
  if (isLive) {
    return (showProgressBar: false, progress: null, caption: '読み込み中…');
  }
  return (showProgressBar: false, progress: null, caption: fallbackLabel);
}

double _clampedStepSeconds(DateTime from, DateTime to) {
  final raw = to.difference(from).inMilliseconds / 1000.0;
  if (!raw.isFinite || raw <= 0) return 0.0;
  return raw > 2.0 ? 2.0 : raw;
}

/// Advances the fallback pre-buffer elapsed counter for unseekable live TS
/// streams only while decrypted bytes are actively flowing from the proxy.
({double accumulatedSeconds, int lastServedBytes, DateTime? lastTickAt})
advanceLiveTransferSeconds({
  required double currentAccumulatedSeconds,
  required int previousServedBytes,
  required DateTime? previousTickAt,
  required int servedBytes,
  required DateTime? firstByteServedAt,
  required DateTime? lastByteServedAt,
  required DateTime now,
  Duration stallGrace = const Duration(milliseconds: 2500),
}) {
  if (firstByteServedAt == null || servedBytes <= 0) {
    return (
      accumulatedSeconds: currentAccumulatedSeconds,
      lastServedBytes: servedBytes,
      lastTickAt: null,
    );
  }
  final bytesGrew = servedBytes > previousServedBytes;
  final recentlyActive =
      lastByteServedAt != null && now.difference(lastByteServedAt) <= stallGrace;
  if (!bytesGrew && !recentlyActive) {
    return (
      accumulatedSeconds: currentAccumulatedSeconds,
      lastServedBytes: servedBytes,
      lastTickAt: now,
    );
  }
  final stepSec = previousTickAt == null
      ? _clampedStepSeconds(firstByteServedAt, now)
      : _clampedStepSeconds(previousTickAt, now);
  return (
    accumulatedSeconds: currentAccumulatedSeconds + stepSec,
    lastServedBytes: servedBytes,
    lastTickAt: now,
  );
}

/// Computes accumulated pre-buffer seconds (clamped to `[0, targetSeconds]`)
/// from all available mpv cache signals, falling back to [liveTransferSeconds]
/// when mpv leaves all cache properties at zero on unseekable live TS streams.
int computePreBufferSeconds({
  required int targetSeconds,
  required double demuxerCacheDuration,
  required double bufferingPercentage,
  required double bufferDeltaSeconds,
  double liveTransferSeconds = 0.0,
}) {
  if (targetSeconds <= 0) return 0;
  final fromDuration =
      demuxerCacheDuration.isFinite && demuxerCacheDuration > 0
      ? demuxerCacheDuration
      : 0.0;
  final fromPercent =
      bufferingPercentage.isFinite && bufferingPercentage > 0
      ? (bufferingPercentage.clamp(0.0, 100.0) / 100.0) * targetSeconds
      : 0.0;
  final fromDelta = bufferDeltaSeconds.isFinite && bufferDeltaSeconds > 0
      ? bufferDeltaSeconds
      : 0.0;
  final mpvBest = math.max(fromDuration, math.max(fromPercent, fromDelta));
  final fallback = liveTransferSeconds.isFinite && liveTransferSeconds > 0
      ? liveTransferSeconds
      : 0.0;
  final best = mpvBest > 0 ? mpvBest : fallback;
  return best.clamp(0.0, targetSeconds.toDouble()).floor();
}

/// Outcome for resolving a system Back (`PopScope`) while the player is open.
enum PlayerBackOutcome {
  suppressed,
  closeDetail,
  closeOsd,
  closeChannelPreview,
  confirmExit,
  popPlayer,
}

/// Resolves what a platform Back invocation should do for the current overlay,
/// error state, exit-dialog state, and debounce-suppression state.
PlayerBackOutcome resolvePlayerBackOutcome({
  required bool detailOpen,
  required bool osdOpen,
  bool channelPreviewOpen = false,
  bool errorOpen = false,
  bool exitConfirmOpen = false,
  DateTime? suppressUntil,
  DateTime? now,
}) {
  if (exitConfirmOpen) return PlayerBackOutcome.suppressed;
  final current = now ?? DateTime.now();
  if (suppressUntil != null && current.isBefore(suppressUntil)) {
    return PlayerBackOutcome.suppressed;
  }
  if (detailOpen) return PlayerBackOutcome.closeDetail;
  if (osdOpen) return PlayerBackOutcome.closeOsd;
  if (channelPreviewOpen) return PlayerBackOutcome.closeChannelPreview;
  if (errorOpen) return PlayerBackOutcome.popPlayer;
  return PlayerBackOutcome.confirmExit;
}

/// Returns whether player interruption notices, auto-resume scheduling, and
/// background error banners must be suppressed (on completion or active
/// recording-conflict preemption / channel switch).
bool shouldSuppressPlayerInterruption({
  required bool completed,
  required bool conflictHandled,
  required bool switchingChannel,
}) => completed || conflictHandled || switchingChannel;

/// Prompts for confirmation before stopping active playback via Back, with the
/// default focus placed on keeping playback running so accidental presses cancel.
Future<bool> showPlayerExitConfirmDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('再生を終了しますか？'),
      content: const Text('再生を終了して前の画面に戻ります。'),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('再生を続ける'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('終了する'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Formats the top-right 5-second notice shown after seamless live failover.
String buildLiveFailoverNotice({
  String? fromNasneName,
  required RegisteredNasne toRegistration,
}) =>
    '${fromNasneName ?? '他の nasne'} で録画開始のため ${nasneDisplayLabel(toRegistration)} へ切替';

/// Prompts when live TV playback cannot start or is interrupted because another
/// channel has claimed the single tuner for a scheduled recording. Returns
/// `true` to switch to the recording channel, or `false`/`null` to close/exit.
Future<bool?> showLiveRecordingConflictDialog(
  BuildContext context, {
  required LiveRecordingConflict conflict,
  required bool midStream,
}) {
  final targetCh = conflict.channelName;
  final baseDesc = (targetCh != null && targetCh.isNotEmpty)
      ? '$targetCh「${conflict.displayTitle}」'
      : '「${conflict.displayTitle}」';
  final targetDesc =
      (conflict.nasneName != null && conflict.nasneName!.isNotEmpty)
      ? '${conflict.nasneName}: $baseDesc'
      : baseDesc;
  final body = midStream
      ? '他チャンネルで録画（$targetDesc）が開始されたため、視聴が中断されました。'
      : '現在、他チャンネルで録画中（$targetDesc）のため、このチャンネルは視聴できません。';
  final hasSwitchTarget = conflict.liveChannel != null;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(midStream ? '他チャンネルの録画が開始されました' : '他チャンネルで録画中です'),
      content: Text(body),
      actions: [
        TextButton(
          autofocus: !hasSwitchTarget,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(midStream ? '視聴を終了する' : '閉じる'),
        ),
        if (hasSwitchTarget)
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(midStream ? '録画中のチャンネルに切り替える' : '録画中のチャンネルを視聴'),
          ),
      ],
    ),
  );
}

/// Traps D-pad directional focus within the OSD action bar and loops
/// horizontally between the first and last buttons so focus never escapes.
class PlayerOsdButtonBar extends StatelessWidget {
  const PlayerOsdButtonBar({
    super.key,
    required this.focusScopeNode,
    required this.children,
    required this.onClose,
    this.onInteraction,
  });

  final FocusScopeNode focusScopeNode;
  final List<Widget> children;
  final VoidCallback onClose;
  final VoidCallback? onInteraction;

  List<FocusNode> _buttons() => focusScopeNode.traversalDescendants
      .where((n) => n.canRequestFocus && !n.skipTraversal)
      .toList();

  FocusNode? _adjacentRowButton(
    List<FocusNode> buttons,
    FocusNode current, {
    required bool down,
  }) {
    final cur = current.rect.center;
    final candidates = buttons.where((b) {
      final cy = b.rect.center.dy;
      return down ? cy > cur.dy + 12 : cy < cur.dy - 12;
    }).toList();
    if (candidates.isEmpty) return null;
    final targetY = candidates
        .map((b) => b.rect.center.dy)
        .reduce(down ? math.min : math.max);
    final rowButtons = candidates
        .where((b) => (b.rect.center.dy - targetY).abs() <= 12)
        .toList();
    rowButtons.sort(
      (a, b) => (a.rect.center.dx - cur.dx).abs().compareTo(
        (b.rect.center.dx - cur.dx).abs(),
      ),
    );
    return rowButtons.first;
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      node: focusScopeNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        onInteraction?.call();
        if (event is KeyDownEvent &&
            (key == LogicalKeyboardKey.escape ||
                key == LogicalKeyboardKey.goBack)) {
          onClose();
          return KeyEventResult.handled;
        }
        final buttons = _buttons();
        if (buttons.isEmpty) return KeyEventResult.handled;
        final currentIdx = buttons.indexWhere(
          (n) => n.hasPrimaryFocus || n.hasFocus,
        );
        if (key == LogicalKeyboardKey.arrowRight) {
          final next = currentIdx < 0 ? 0 : (currentIdx + 1) % buttons.length;
          buttons[next].requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          final prev = currentIdx < 0
              ? buttons.length - 1
              : (currentIdx - 1 + buttons.length) % buttons.length;
          buttons[prev].requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp) {
          if (currentIdx < 0) {
            buttons.first.requestFocus();
            return KeyEventResult.handled;
          }
          final target = _adjacentRowButton(
            buttons,
            buttons[currentIdx],
            down: key == LogicalKeyboardKey.arrowDown,
          );
          (target ?? buttons[currentIdx]).requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Wrap(spacing: 10, runSpacing: 8, children: children),
    );
  }
}

/// Translucent upper-half overlay panel displaying full programme metadata and
/// descriptions during playback, with Fire TV D-pad scroll and close support.
class ProgramDetailOverlayPanel extends StatelessWidget {
  const ProgramDetailOverlayPanel({
    super.key,
    required this.title,
    this.meta,
    required this.body,
    required this.scrollController,
    required this.focusNode,
    required this.onClose,
    required this.onScrollDelta,
  });

  final String title;
  final String? meta;
  final String body;
  final ScrollController scrollController;
  final FocusNode focusNode;
  final VoidCallback onClose;
  final void Function(double delta) onScrollDelta;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.45;
    return GestureDetector(
      onTap: () {},
      child: Focus(
        focusNode: focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowDown) {
            onScrollDelta(88);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp) {
            onScrollDelta(-88);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.pageDown) {
            onScrollDelta(220);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.pageUp) {
            onScrollDelta(-220);
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent &&
              (key == LogicalKeyboardKey.escape ||
                  key == LogicalKeyboardKey.goBack ||
                  key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.gameButtonA)) {
            onClose();
            return KeyEventResult.handled;
          }
          return KeyEventResult.handled;
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Container(
            key: const ValueKey('player_program_detail_panel'),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.amberAccent.withValues(alpha: 0.85),
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (meta != null && meta!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              meta!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ExcludeFocus(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                        ),
                        onPressed: onClose,
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('閉じる'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '上下キーでスクロール ／ 決定・戻るキーで閉じる',
                  style: TextStyle(color: Colors.amberAccent, fontSize: 11),
                ),
                const Divider(color: Colors.white24, height: 14),
                Flexible(
                  child: Scrollbar(
                    controller: scrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: scrollController,
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        body,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.title,
    required this.session,
    this.live = false,
    this.initialStart,
    this.knownDuration,
    this.onResumePosition,
    this.loadChapters,
    this.programDetailTitle,
    this.programDetailMeta,
    this.programDetailBody,
    this.recordedChannelName,
    this.recordedBroadcastTimeRange,
    this.currentLiveChannel,
    this.initialRecordingSchedules = const [],
    this.liveUseMobile = false,
    this.initialLiveGuideEvents = const [],
    this.loadLiveGuideEvents,
    this.initialLiveBandGuideEvents = const {},
    this.loadLiveBandGuideEvents,
    this.onRefreshLiveChannels,
    this.liveSwitchChannels = const [],
    this.currentLiveSwitchIndex = -1,
    this.initialLiveChannelNumbers = const {},
    this.initialLiveChannelLogos = const {},
    this.loadLiveChannelMetadata,
    this.onSwitchLiveChannel,
    this.onCheckRecordingConflict,
    this.onBuildRecordingChannelPlayer,
    this.onBuildFailoverPlayer,
    this.onStartCurrentProgramRecording,
    this.onStopCurrentProgramRecording,
    this.canSwitchQuality = false,
    this.currentUseMobile = false,
    this.onSwitchQuality,
    this.onLivePlaybackFinished,
    this.initialCornerNotice,
    this.nowProvider,
  });

  /// Display heading: a recording's title, or a live channel's
  /// name (plan 39). The screen itself is source-agnostic — it
  /// plays the session's stream, finite or endless.
  final String title;
  final PlaybackSession session;

  /// Whether the session is a live broadcast (plan 43). A live
  /// stream is unseekable by design, so mpv's seek complaint is
  /// non-fatal there (see player_error_policy).
  final bool live;

  /// Where a recording starts playing (plan 86): the resume
  /// position the nasne recorded for the title, when the viewer
  /// chose to continue from it. Null (and always null for live)
  /// starts at the beginning. Handed to mpv as the open start,
  /// so the proxy's time-seek path establishes the stream at
  /// that position from the first byte.
  final Duration? initialStart;

  /// Total programme duration from nasne metadata, used as a fallback when
  /// mpv has not yet settled [PlayerState.duration] on stream start.
  final Duration? knownDuration;

  /// Where the position a recording was stopped at goes when
  /// this screen closes (plan 102): the unit is told, so its
  /// resume point — the value [initialStart] is later read
  /// from — follows the viewer. What is sent follows
  /// player_resume_policy: the stopped-at position, or zero
  /// (clearing the point) when playback ran to the end, and
  /// nothing at all when playback never started. Null (live
  /// viewing has no position to report) disables the report.
  ///
  /// The report is a notification to the unit, not local
  /// persistence: it is awaited inside its own task off the
  /// dispose path, and a failure is logged to the playback
  /// diagnostics and dropped — leaving the player must never
  /// fail or hang because a report did not land.
  ///
  /// Plan 104: the report is decided from the screen's own
  /// fields before teardown and sent as a guarded teardown
  /// step once the player's stop is under way; see
  /// player_teardown_policy for why dispose touches no ref
  /// and lets no step's failure starve the rest.
  final Future<void> Function(Duration position)? onResumePosition;

  /// Where this recording's chapter points come from
  /// (plan 112): called once as the screen opens and
  /// expected to answer the title's validated points.
  /// An empty answer — no chapters, or data that failed
  /// validation — simply leaves the screen without
  /// chapter controls. Null (live viewing has no
  /// chapters) disables the feature. The load runs
  /// beside the open, never before it, and a failure is
  /// logged and dropped: chapters decorate playback and
  /// must not delay or fail it.
  final Future<List<Duration>> Function()? loadChapters;

  /// Full programme heading shown in the OSD detail viewer (defaults to [title]).
  final String? programDetailTitle;

  /// Single-line metadata (broadcast time, channel, genre) shown above [programDetailBody].
  final String? programDetailMeta;

  /// Combined full programme description body shown when opening "番組詳細" in the OSD.
  final String? programDetailBody;

  /// Recorded channel label displayed in Row 1 of the recorded OSD header.
  final String? recordedChannelName;

  /// Formatted recorded broadcast date/time range displayed beside the programme title.
  final String? recordedBroadcastTimeRange;

  /// Channel metadata for live viewing so same-channel recording status and
  /// other-channel recording conflicts can be detected.
  final LiveChannel? currentLiveChannel;

  /// Snapshot of reservations captured when opening live playback.
  final List<RecordSchedule> initialRecordingSchedules;

  /// Whether live playback is using the lower-bitrate mobile transcode.
  final bool liveUseMobile;

  /// Pre-loaded EPG events for the active live channel (optional).
  final List<EpgEvent> initialLiveGuideEvents;

  /// Background EPG loader for the active live channel when not cached yet.
  final Future<List<EpgEvent>> Function()? loadLiveGuideEvents;

  /// Pre-loaded EPG events keyed by [liveServiceKey] across the active live band.
  final Map<String, List<EpgEvent>> initialLiveBandGuideEvents;

  /// Background EPG loader across the active live band when not cached yet.
  final Future<Map<String, List<EpgEvent>>> Function()? loadLiveBandGuideEvents;

  /// Refreshes the active band's [LiveChannelSwitchEntry] snapshots when EPG is
  /// unavailable (such as CS) or existing programme snapshots have expired.
  final Future<List<LiveChannelSwitchEntry>> Function()? onRefreshLiveChannels;

  /// Ordered live channel entries within the current band for D-pad switching.
  final List<LiveChannelSwitchEntry> liveSwitchChannels;

  /// Index of [currentLiveChannel] inside [liveSwitchChannels].
  final int currentLiveSwitchIndex;

  /// Pre-loaded 3-digit channel numbers keyed by [liveServiceKey].
  final Map<String, String> initialLiveChannelNumbers;

  /// Pre-loaded channel logo PNG bytes keyed by [liveServiceKey].
  final Map<String, Uint8List> initialLiveChannelLogos;

  /// Optional background loader for channel numbers and logos when not cached.
  final Future<({Map<String, String> numbers, Map<String, Uint8List> logos})>
  Function()?
  loadLiveChannelMetadata;

  /// Called when live playback actually exits (skipping `pushReplacement` hops
  /// such as channel/quality switches or failover), passing the last active channel.
  final void Function(LiveChannel? lastChannel)? onLivePlaybackFinished;

  /// Switches to another live channel, calling [stopCurrentSession] only after
  /// any conflict prompt is accepted so cancelled switches keep playing cleanly.
  final Future<Widget?> Function(
    BuildContext context,
    LiveChannelSwitchEntry target,
    Future<void> Function() stopCurrentSession,
  )?
  onSwitchLiveChannel;

  /// Called when live playback stalls/reconnects repeatedly to detect whether a
  /// scheduled recording on another channel claimed the single tuner.
  final Future<LiveRecordingConflict?> Function()? onCheckRecordingConflict;

  /// Builds the replacement [PlayerScreen] when switching to a recording channel.
  final Future<Widget> Function(LiveChannel target)?
      onBuildRecordingChannelPlayer;

  /// Builds the replacement [PlayerScreen] when automatically failing over to
  /// another registered nasne whose tuner is still free.
  final Future<Widget> Function(
    RegisteredNasne targetReg,
    LiveChannel targetChannel,
    String? notice,
  )?
  onBuildFailoverPlayer;

  /// Starts recording the programme currently playing in live mode.
  final Future<LiveRecordingActionResult> Function()?
  onStartCurrentProgramRecording;

  /// Stops an active live-channel recording reservation.
  final Future<LiveRecordingActionResult> Function(
    RecordSchedule activeSchedule,
  )?
  onStopCurrentProgramRecording;

  /// Optional 5-second top-right notice shown right after opening (e.g. after a
  /// multi-nasne auto-failover switch).
  final String? initialCornerNotice;

  /// Whether another quality tier (original <-> mobile) can be switched to
  /// directly from the OSD menu.
  final bool canSwitchQuality;

  /// Current quality tier of the playing stream (`true` for mobile transcode).
  final bool currentUseMobile;

  /// Switches playback stream quality in place, invoking [stopCurrentSession]
  /// before opening the replacement stream at [currentPosition].
  final Future<Widget?> Function(
    BuildContext context,
    bool nextUseMobile,
    Duration currentPosition,
    Future<void> Function() stopCurrentSession,
  )?
  onSwitchQuality;

  /// Injectable clock for testing same-channel recording notices.
  final DateTime Function()? nowProvider;

  static const Duration rewindStep = Duration(seconds: -10);
  static const Duration forwardStep = Duration(seconds: 10);

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with TickerProviderStateMixin {
  late final Player _player;
  late final VideoController _videoController;
  late final WakelockSession _wakelockSession;
  late final int? _androidSdkInt;
  late final bool _useLegacySyncMpvInit;
  late final VideoHwdecMode _hwdecMode;
  bool _decodeStatusLogged = false;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _watchdog;
  Timer? _startupTraceTimer;
  bool _startTraceCompleted = false;
  bool _playing = false;
  bool _buffering = true;
  bool _hasVideoFrame = false;
  String? _error;

  /// Interruption state (plan 80): playback that had started
  /// stopped mid-stream — a fatal player error after the
  /// start, or the silent stall of plan 78 — and the notice
  /// with its resume action is showing over the frozen frame.
  bool _interrupted = false;
  String? _interruptDetail;
  Timer? _stallTimer;
  Timer? _autoResumeTimer;
  Timer? _resumeWatchdogTimer;
  int _autoResumeAttempts = 0;
  int _autoResumeCountdown = 0;
  bool _autoResumeDisabled = false;

  /// Live recording tracking (same-channel OSD/corner notice and other-channel
  /// tuner conflict preemption).
  late List<RecordSchedule> _recordingSchedules;
  final Set<String> _stoppedScheduleIds = <String>{};
  RecordSchedule? _activeSameChannelSchedule;
  bool _recordingActionBusy = false;
  bool _sameChannelRecording = false;
  bool? _lastSameChannelRecording;
  LiveRecordingCornerNotice? _cornerRecordingNotice;
  String? _customCornerNoticeText;
  Timer? _recordingStatusTimer;
  Timer? _cornerNoticeTimer;
  Timer? _customCornerNoticeTimer;
  bool _checkingConflict = false;
  bool _conflictHandled = false;
  bool _switchingChannel = false;
  String? _switchingChannelLabel;
  Timer? _liveConflictPollTimer;
  DateTime? _livePausedAt;
  bool _liveDelayedByPause = false;
  bool _liveAutoCatchUpEnabled = true;
  bool _liveRewoundByUser = false;
  double _liveCatchUpRate = 1.0;
  double _liveEstimatedLagSeconds = 0.0;
  double? _liveCacheStartSec;
  double? _liveCacheEndSec;
  double? _liveCacheLiveEdgeSec;
  double? _liveTimePosSec;
  DateTime? _liveStreamEpoch;
  double? _liveMaxAdvancingCacheEndSec;
  double? _livePendingSeekBaseSec;
  double _livePendingSeekDeltaSec = 0.0;
  Timer? _liveSeekDebounceTimer;
  double? _liveCommittedSeekSec;
  Timer? _liveCommittedSeekHoldTimer;
  Timer? _liveCatchUpTimer;
  bool _suppressResumeReportOnDispose = false;
  bool _catchingUpLive = false;
  int _liveEdgeSeq = 0;
  ChannelSwitchDirection? _channelPreviewDirection;
  Timer? _channelPreviewTimer;
  Stopwatch? _openStartedAt;

  /// The latest value of the playing stream (unlike
  /// [_playing], which latches once playback has started),
  /// and the signals the interruption policy reads: mpv's
  /// end-of-stream flag, whether buffering was the last
  /// observed state while playing, and the last position a
  /// resume should return to.
  bool _playingNow = false;
  bool _completed = false;
  bool _autoPoppedOnComplete = false;
  bool _bufferingSincePlaying = false;
  Duration _lastPosition = Duration.zero;

  /// How long a mid-stream stop may last before it is
  /// surfaced as an interruption (plan 80): long enough for
  /// mpv's own recovery and a passing stall, short enough
  /// that a dead playback does not sit silent.
  static const Duration stallTimeout = Duration(seconds: 10);

  /// Tracks the demuxer currently reports, and the selection
  /// mpv currently holds (plan 53). Both start empty/'auto'
  /// and settle once the stream is being demuxed.
  Tracks _tracks = const Tracks();
  Track _selectedTrack = const Track();

  /// The demuxer's real audio tracks, without media_kit's
  /// synthetic 'auto'/'no' entries (plan 54).
  List<AudioTrack> get _realAudioTracks => [
    for (final track in _tracks.audio)
      if (isRealTrackId(track.id)) track,
  ];

  /// The demuxer's real subtitle tracks (plan 54).
  List<SubtitleTrack> get _realSubtitleTracks => [
    for (final track in _tracks.subtitle)
      if (isRealTrackId(track.id)) track,
  ];

  /// The caption toggle (persisted via [subtitlesEnabledProvider] across
  /// channel switches, recordings, and restarts).
  bool _subtitlesOn = false;
  final SubtitleActiveWindowTracker _subtitleTracker =
      SubtitleActiveWindowTracker();
  List<SubtitleCue> _visibleSubtitleCues = const [];
  List<String> _plainSubtitleLines = const [];
  String _rawAssSubtitle = '';
  double _assPlayResWidth = 960.0;
  double _assPlayResHeight = 540.0;
  bool _assExtradataLoaded = false;
  bool _loggedAssSample = false;
  Timer? _subtitleSyncTimer;
  Timer? _subtitleRetryTimer;
  bool _pollingSubtitleSync = false;
  bool _pendingImmediateSubtitleSync = false;
  int _subtitleMismatchRetries = 0;
  String _lastRenderedPlainCompact = '';
  String? _suppressedCaptionSignature;
  double? _lastSeenSubStartSeconds;
  Duration _subtitlePlaybackClock = Duration.zero;
  double? _aribPtsOffset;
  double? _demuxerStartTimeSeconds;
  bool _usingDirectAribCaptions = false;
  double? _activeSubStartSeconds;
  double? _lastPlaybackTimeSeconds;
  double? _activeClearAfterSeconds;
  DateTime? _lastAribDecoderResetAt;
  bool _resettingAribDecoder = false;
  List<EpgEvent> _liveGuideEvents = const [];
  Map<String, List<EpgEvent>> _liveBandGuideEvents = const {};
  final Map<String, List<EpgEvent>> _liveChannelProgramHistory = {};
  LiveChannel? _currentLiveChannel;
  List<LiveChannelSwitchEntry> _liveSwitchChannels = const [];
  int _currentLiveSwitchIndex = -1;
  Map<String, String> _liveChannelNumbers = const {};
  Map<String, Uint8List> _liveChannelLogos = const {};
  bool _liveChannelMetaLoading = false;
  bool _liveGuideLoading = false;
  DateTime? _lastLiveGuideAttemptAt;
  bool _liveChannelsRefreshing = false;
  DateTime? _lastLiveChannelsRefreshAt;
  ResolvedProgramDetail? _openedLiveDetail;
  bool _liveDetailLoading = false;
  int _liveDetailRequestSeq = 0;
  bool _replacedByNextPlayer = false;
  Timer? _osdClockTimer;

  /// The playback rate (plan 86, plan 85 item 7): 1.0 is
  /// normal speed. Offered for recordings only (see
  /// player_speed_policy); kept in this state only, like the
  /// caption and audio selections, and never persisted. mpv
  /// holds the rate on the player instance, so it carries
  /// over the in-place resume's re-open (plan 80) unchanged.
  double _playbackRate = 1.0;

  /// Whether mpv reports the current stream seekable,
  /// observed from its `seekable` property (player UI
  /// follow-up). Starts false — the skip buttons stay
  /// disabled until mpv gives a definite yes — and follows
  /// the property for the screen's lifetime. The buttons
  /// listen to this notifier directly, so no rebuild of
  /// this screen is involved when it flips. The property
  /// observation is registered on the player instance and
  /// dies with it; the notifier itself holds nothing that
  /// needs releasing.
  final ValueNotifier<bool> _seekable = ValueNotifier<bool>(false);

  /// The recording's chapter points (plan 112), loaded
  /// once as the screen opens (see [_loadChapters]).
  /// Empty — live viewing, a title without chapters, a
  /// load that failed — keeps the chapter buttons out
  /// of the transport rows and the ticks off the seek
  /// bar.
  List<Duration> _chapters = const [];

  /// How long playback may take to reach the playing state before
  /// the screen gives up with a timeout error (plan 29). Kept
  /// above mpv's network timeout (plan 30) so mpv's own classified
  /// error normally surfaces first and this stays a backstop.
  static const Duration startTimeout = Duration(seconds: 45);

  /// The diagnostics log and Fire TV helper, captured in [initState]
  /// (plan 104): dispose and the teardown it drives read no
  /// provider through ref — Riverpod 3 throws once the
  /// widget is deactivating, and a throw there aborts the
  /// teardown (see player_teardown_policy).
  late final DiagLog _diag;
  late final FireTvHelper _fireTvHelper;

  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'playerRoot');
  final FocusScopeNode _osdFocusScopeNode = FocusScopeNode(
    debugLabel: 'playerOsdScope',
  );
  final FocusNode _osdFirstFocusNode = FocusNode(debugLabel: 'playerOsdFirst');
  final FocusNode _osdDetailButtonFocusNode = FocusNode(
    debugLabel: 'playerOsdDetailButton',
  );
  final FocusNode _detailFocusNode = FocusNode(debugLabel: 'playerDetail');
  final FocusNode _resumeButtonFocusNode = FocusNode(
    debugLabel: 'playerResumeButton',
  );
  final FocusNode _closeBannerFocusNode = FocusNode(
    debugLabel: 'playerCloseBannerButton',
  );
  final FocusNode _errorBackFocusNode = FocusNode(
    debugLabel: 'playerErrorBack',
  );

  bool _osdOpen = false;
  Timer? _osdTimer;
  late final AnimationController _osdFadeController;
  late final Animation<double> _osdFadeAnimation;
  int _displayedBufferAheadSeconds = 0;
  DateTime? _lastBufferBadgeUpdatedAt;
  bool _detailOpen = false;
  bool _exitConfirmOpen = false;
  DateTime? _suppressBackPopUntil;
  final ScrollController _detailScrollController = ScrollController();

  IconData? _hudIcon;
  String? _hudText;
  Timer? _hudTimer;

  bool _seekHudVisible = false;
  IconData? _seekHudIcon;
  String? _seekHudActionLabel;
  Timer? _seekHudTimer;

  Timer? _seekDebounceTimer;
  Duration _pendingSeekOffset = Duration.zero;
  Duration? _seekBasePosition;
  Duration? _committedSeekTarget;
  Timer? _committedSeekHoldTimer;

  Duration _duration = Duration.zero;
  Duration _bufferEndPosition = Duration.zero;
  Duration? _initialBufferPosition;
  double _bufferedAheadSeconds = 0.0;
  double _bufferingPercentage = 0.0;
  MpvBufferPlan? _bufferPlan;
  Directory? _usedDiskCacheDir;
  Timer? _preBufferPollTimer;
  bool _pollingBufferProps = false;
  bool _initialPlaybackStarted = false;
  Duration? _positionAtFirstFrame;
  int _lastObservedServedBytes = 0;
  DateTime? _lastLiveTransferTickAt;
  double _liveTransferAccumulatedSeconds = 0.0;

  bool get _isPreBuffering {
    final plan = _bufferPlan;
    return plan != null &&
        plan.cachePauseInitial &&
        plan.cachePauseWaitSeconds > 0 &&
        !_initialPlaybackStarted;
  }

  bool _maybeLatchInitialPlaybackStarted() {
    if (_initialPlaybackStarted) return false;
    final targetSec = (_bufferPlan?.cachePauseInitial == true)
        ? (_bufferPlan?.cachePauseWaitSeconds ?? 0)
        : 0;
    final ready = shouldLatchInitialPlaybackStarted(
      hasVideoFrame: _hasVideoFrame,
      playingNow: _playingNow,
      buffering: _buffering,
      positionAtFirstFrame: _positionAtFirstFrame,
      currentPosition: _lastPosition,
      preBufferTargetSeconds: targetSec,
      preBufferCurrentSeconds: _effectivePreBufferSeconds.toDouble(),
    );
    if (!ready) return false;
    _initialPlaybackStarted = true;
    _maybeCancelStartWatchdog();
    _stopStartupTraceTimer();
    _startTraceCompleted = true;
    if (!_buffering) {
      _stopPreBufferPoller();
    }
    final startedAt = _openStartedAt;
    if (startedAt != null && startedAt.isRunning) {
      startedAt.stop();
      _diag(
        DiagCategory.playback,
        'player: initial playback started in ${startedAt.elapsedMilliseconds} ms '
        '(live=${widget.live}, mobile=${widget.liveUseMobile})',
      );
      _logPlaybackTrace(
        'started in ${startedAt.elapsedMilliseconds}ms (${_buildCompactDiagnosticsSummary()})',
      );
    }
    return true;
  }

  void _maybeCancelStartWatchdog() {
    if (shouldCancelStartWatchdog(
      hasVideoFrame: _hasVideoFrame,
      playingNow: _playingNow,
      buffering: _buffering,
      initialPlaybackStarted: _initialPlaybackStarted,
    )) {
      _watchdog?.cancel();
    }
  }

  void _logPlaybackTrace(String message) {
    debugPrint('[tmhb:play] $message');
  }

  void _startStartupTraceTimer() {
    _startupTraceTimer?.cancel();
    _startTraceCompleted = false;
    _startupTraceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _startTraceCompleted || _initialPlaybackStarted || _error != null) {
        _stopStartupTraceTimer();
        return;
      }
      final elapsedMs = _openStartedAt?.elapsedMilliseconds ?? 0;
      _logPlaybackTrace(
        'wait +${(elapsedMs / 1000).toStringAsFixed(1)}s ${_buildCompactDiagnosticsSummary()}',
      );
    });
  }

  void _stopStartupTraceTimer() {
    _startupTraceTimer?.cancel();
    _startupTraceTimer = null;
  }

  String _buildCompactDiagnosticsSummary() {
    var cipher = -1;
    var plain = -1;
    var served = -1;
    var reqs = -1;
    var reconnectErrs = 0;
    Object? rawUpstream;
    if (widget.session case final StreamTransferMetrics transfer) {
      served = transfer.servedBytes;
      reconnectErrs = transfer.consecutiveReconnectErrors;
    }
    if (widget.session case final StreamDiagnosticMetrics diagMetrics) {
      cipher = diagMetrics.cipherBytes;
      plain = diagMetrics.plaintextBytes;
      reqs = diagMetrics.downstreamRequestCount;
      rawUpstream = diagMetrics.lastUpstreamError;
    }
    final upstream = describeStreamErrorSafely(rawUpstream);
    return 'cipher=${cipher}B plain=${plain}B served=${served}B '
        'reqs=$reqs reconErr=$reconnectErrs up=$upstream '
        'playingNow=$_playingNow playing=$_playing buf=$_buffering frame=$_hasVideoFrame '
        'v=${_tracks.video.length} a=${_tracks.audio.length} s=${_tracks.subtitle.length}';
  }

  double get _bufferDeltaSeconds {
    if (_bufferEndPosition <= Duration.zero) return 0.0;
    final base = _lastPosition > Duration.zero
        ? _lastPosition
        : _initialBufferPosition;
    if (base == null) return 0.0;
    final diff = _bufferEndPosition - base;
    return diff > Duration.zero ? diff.inMilliseconds / 1000.0 : 0.0;
  }

  int get _effectivePreBufferSeconds => computePreBufferSeconds(
    targetSeconds: _bufferPlan?.cachePauseWaitSeconds ?? 0,
    demuxerCacheDuration: _bufferedAheadSeconds,
    bufferingPercentage: _bufferingPercentage,
    bufferDeltaSeconds: _bufferDeltaSeconds,
    liveTransferSeconds: widget.live ? _liveTransferAccumulatedSeconds : 0.0,
  );

  int get _effectiveLoadingCurrentSeconds {
    final target = _bufferPlan?.cachePauseWaitSeconds ?? 0;
    if (target > 0 && _isPreBuffering) {
      return _effectivePreBufferSeconds;
    }
    final best = math.max(
      _bufferedAheadSeconds,
      math.max(
        _bufferDeltaSeconds,
        widget.live ? _liveTransferAccumulatedSeconds : 0.0,
      ),
    );
    return best.isFinite && best > 0 ? best.floor() : 0;
  }

  bool get _shouldPollLiveBuffering =>
      _isPreBuffering ||
      (widget.live &&
          (_bufferPlan?.cachePauseWaitSeconds ?? 0) > 0 &&
          (!_initialPlaybackStarted || _buffering));

  void _startPreBufferPoller() {
    if (_preBufferPollTimer != null) return;
    _preBufferPollTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      if (!mounted || !_shouldPollLiveBuffering) {
        _stopPreBufferPoller();
        return;
      }
      unawaited(_pollMpvBufferProperties());
    });
    unawaited(_pollMpvBufferProperties());
  }

  void _stopPreBufferPoller() {
    _preBufferPollTimer?.cancel();
    _preBufferPollTimer = null;
  }

  Future<void> _pollMpvBufferProperties() async {
    if (_pollingBufferProps || !mounted) return;
    final platform = _player.platform;
    _pollingBufferProps = true;
    final prevLoadSec = _effectiveLoadingCurrentSeconds;
    final prevPct = _bufferingPercentage.round();
    final prevAheadFloor = _bufferedAheadSeconds.floor();
    final prevCacheStart = _liveCacheStartSec;
    final prevCacheEnd = _liveCacheLiveEdgeSec ?? _liveCacheEndSec;
    final prevPos = _liveTimePosSec;
    try {
      if (platform is NativePlayer) {
        var parsedCacheDuration = 0.0;
        try {
          final rawDur = await platform.getProperty('demuxer-cache-duration');
          final parsed = double.tryParse(rawDur);
          if (parsed != null && parsed.isFinite && parsed >= 0) {
            parsedCacheDuration = parsed;
            _bufferedAheadSeconds = parsed;
          }
        } catch (_) {}
        double? polledPlaybackTime;
        double? polledTimePos;
        if (widget.live &&
            (_liveDelayedByPause || !_playingNow || _seekHudVisible || _osdOpen)) {
          try {
            final posProps = await Future.wait<String>([
              _safeGetProp(platform, 'playback-time'),
              _safeGetProp(platform, 'time-pos'),
            ]);
            final pb = double.tryParse(posProps[0]);
            if (pb != null && pb.isFinite) polledPlaybackTime = pb;
            final tp = double.tryParse(posProps[1]);
            if (tp != null && tp.isFinite) polledTimePos = tp;
            if (polledPlaybackTime != null || polledTimePos != null) {
              _liveTimePosSec = polledPlaybackTime ?? polledTimePos;
            }
          } catch (_) {}
        }
        try {
          final rawState = await platform.getProperty('demuxer-cache-state');
          final range = parseDemuxerCacheStateRange(
            rawState,
            currentPosSeconds:
                polledPlaybackTime ?? polledTimePos ?? _liveTimePosSec,
          );
          if (range != null) {
            final earliestStart =
                range.earliestStartSeconds ?? range.startSeconds;
            final liveEdge = range.liveEdgeSeconds ?? range.endSeconds;
            _liveCacheStartSec = earliestStart;
            _liveCacheEndSec = range.endSeconds;
            _liveCacheLiveEdgeSec = liveEdge;
            _updateLiveStreamEpochFromLiveEdge(liveEdge, _now());
            if (polledPlaybackTime != null ||
                polledTimePos != null ||
                _liveTimePosSec != null) {
              _liveTimePosSec = resolveLiveCacheCoordinatePos(
                playbackTimeSeconds: polledPlaybackTime ?? _liveTimePosSec,
                timePosSeconds: polledTimePos,
                cacheStartSeconds: earliestStart,
                cacheEndSeconds: liveEdge,
                fallbackSeconds: liveEdge,
              );
            }
            final aheadFromRange = _liveTimePosSec != null
                ? math.max(0.0, liveEdge - _liveTimePosSec!)
                : null;
            final stateDur = range.cacheDurationSeconds;
            if (stateDur != null &&
                (stateDur > _bufferedAheadSeconds || parsedCacheDuration <= 0)) {
              _bufferedAheadSeconds = stateDur;
            } else if (aheadFromRange != null && parsedCacheDuration <= 0) {
              _bufferedAheadSeconds = aheadFromRange;
            }
          } else {
            final parsed = parseDemuxerCacheStateDuration(rawState);
            if (parsed != null &&
                (parsed > _bufferedAheadSeconds || parsedCacheDuration <= 0)) {
              _bufferedAheadSeconds = parsed;
            }
          }
        } catch (_) {}
        try {
          final rawPct = await platform.getProperty('cache-buffering-state');
          final parsed = double.tryParse(rawPct);
          if (parsed != null && parsed.isFinite) {
            _bufferingPercentage = parsed.clamp(0.0, 100.0).toDouble();
          }
        } catch (_) {}
      }
      if (widget.live && _shouldPollLiveBuffering) {
        if (widget.session case final StreamTransferMetrics metrics) {
          final next = advanceLiveTransferSeconds(
            currentAccumulatedSeconds: _liveTransferAccumulatedSeconds,
            previousServedBytes: _lastObservedServedBytes,
            previousTickAt: _lastLiveTransferTickAt,
            servedBytes: metrics.servedBytes,
            firstByteServedAt: metrics.firstByteServedAt,
            lastByteServedAt: metrics.lastByteServedAt,
            now: DateTime.now(),
          );
          _liveTransferAccumulatedSeconds = next.accumulatedSeconds;
          _lastObservedServedBytes = next.lastServedBytes;
          _lastLiveTransferTickAt = next.lastTickAt;
        }
      }
      if (!mounted) return;
      final latched = _maybeLatchInitialPlaybackStarted();
      final nextLoadSec = _effectiveLoadingCurrentSeconds;
      final nextPct = _bufferingPercentage.round();
      final liveRangeChanged = hasLiveCacheRangeDisplayChanged(
        prevStart: prevCacheStart,
        prevEnd: prevCacheEnd,
        prevPos: prevPos,
        nextStart: _liveCacheStartSec,
        nextEnd: _liveCacheLiveEdgeSec ?? _liveCacheEndSec,
        nextPos: _liveTimePosSec,
      );
      if (latched ||
          (_shouldPollLiveBuffering &&
              (nextLoadSec != prevLoadSec || nextPct != prevPct)) ||
          (_seekHudVisible &&
              (_bufferedAheadSeconds.floor() != prevAheadFloor ||
                  liveRangeChanged)) ||
          (_osdOpen && (_syncDisplayedBufferBadge() || liveRangeChanged))) {
        setState(() {});
      }
    } finally {
      _pollingBufferProps = false;
    }
  }

  static const Duration _rewindStep = PlayerScreen.rewindStep;
  static const Duration _forwardStep = PlayerScreen.forwardStep;
  static const List<int> _autoResumeBackoffSeconds = [3, 5, 8, 10];

  void _onVideoRectChanged() {
    final r = _videoController.rect.value;
    if (!_hasVideoFrame &&
        r != null &&
        r.width > 0 &&
        r.height > 0 &&
        mounted) {
      _logPlaybackTrace(
        'first frame rect=${r.width.toInt()}x${r.height.toInt()} at ${_openStartedAt?.elapsedMilliseconds ?? 0}ms',
      );
      setState(() {
        _hasVideoFrame = true;
        _positionAtFirstFrame ??= _lastPosition;
        _maybeLatchInitialPlaybackStarted();
      });
      _maybeCancelStartWatchdog();
    }
  }

  @override
  void initState() {
    super.initState();
    _osdFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 160),
    )..addStatusListener((status) {
      if ((status == AnimationStatus.dismissed ||
              status == AnimationStatus.completed) &&
          mounted) {
        setState(() {});
      }
    });
    _osdFadeAnimation = CurvedAnimation(
      parent: _osdFadeController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _diag = ref.read(diagLogProvider);
    _fireTvHelper = ref.read(fireTvHelperProvider);
    _androidSdkInt = ref.read(androidSdkIntProvider);
    _useLegacySyncMpvInit = shouldUseLegacySyncMpvInit(
      isAndroid: Platform.isAndroid,
      androidSdkInt: _androidSdkInt,
    );
    _hwdecMode = ref.read(videoHwdecModeProvider);
    _subtitlesOn = ref.read(subtitlesEnabledProvider);
    _currentLiveChannel = widget.currentLiveChannel;
    _liveSwitchChannels = List<LiveChannelSwitchEntry>.of(
      widget.liveSwitchChannels,
    );
    _currentLiveSwitchIndex = widget.currentLiveSwitchIndex;
    _liveChannelNumbers = Map<String, String>.of(
      widget.initialLiveChannelNumbers,
    );
    _liveChannelLogos = Map<String, Uint8List>.of(
      widget.initialLiveChannelLogos,
    );
    if (widget.live &&
        widget.loadLiveChannelMetadata != null &&
        (_liveChannelNumbers.isEmpty || _liveChannelLogos.isEmpty)) {
      unawaited(_loadLiveChannelMetadata());
    }
    _liveBandGuideEvents = {
      for (final entry in widget.initialLiveBandGuideEvents.entries)
        entry.key: List<EpgEvent>.of(entry.value),
    };
    _liveGuideEvents = List<EpgEvent>.of(widget.initialLiveGuideEvents);
    if (_liveGuideEvents.isEmpty && _currentLiveChannel != null) {
      final seeded = _liveBandGuideEvents[liveServiceKey(_currentLiveChannel!)];
      if (seeded != null && seeded.isNotEmpty) {
        _liveGuideEvents = List<EpgEvent>.of(seeded);
      }
    }
    _recordLiveChannelProgramSnapshot(_activeLiveChannel);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_fireTvHelper.setMediaVolumeMax());
    _player = _useLegacySyncMpvInit
        ? Player(configuration: const PlayerConfiguration(async: false))
        : Player();
    unawaited(_player.setVolume(100.0));
    _videoController = _hwdecMode == VideoHwdecMode.software
        ? VideoController(
            _player,
            configuration: const VideoControllerConfiguration(
              enableHardwareAcceleration: false,
            ),
          )
        : VideoController(_player);
    if (_useLegacySyncMpvInit) {
      unawaited(_kickLegacyMpvAfterInit());
    }
    _videoController.rect.addListener(_onVideoRectChanged);
    _wakelockSession = ref.read(playbackWakelockProvider).openSession();
    _watchdog = Timer(startTimeout, _onStartTimeout);
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (_conflictHandled || _switchingChannel) return;
        _diag(DiagCategory.playback, 'player: playing=$playing');
        if (!_initialPlaybackStarted) {
          _logPlaybackTrace(
            'mpv playing=$playing buf=$_buffering frame=$_hasVideoFrame +${_openStartedAt?.elapsedMilliseconds ?? 0}ms',
          );
        }
        _wakelockSession.setPlaying(playing);
        final wasPlaying = _playingNow;
        if (widget.live && _playing) {
          if (!playing) {
            if (!_buffering && !_interrupted && _initialPlaybackStarted) {
              _markLivePaused(notify: false);
            } else {
              _livePausedAt ??= _now();
            }
          } else {
            if (_livePausedAt != null) {
              final pauseDelta =
                  _now().difference(_livePausedAt!).inMilliseconds / 1000.0;
              if (pauseDelta > 0) {
                _liveEstimatedLagSeconds += pauseDelta;
              }
              _livePausedAt = null;
            }
          }
        }
        if (mounted) {
          setState(() {
            _playingNow = playing;
            if (playing) {
              _playing = true;
              _interrupted = false;
              _interruptDetail = null;
            }
            _maybeLatchInitialPlaybackStarted();
          });
        } else {
          _playingNow = playing;
          if (playing) _playing = true;
          _maybeLatchInitialPlaybackStarted();
        }
        if (playing) {
          _maybeCancelStartWatchdog();
          _resumeWatchdogTimer?.cancel();
          _autoResumeTimer?.cancel();
          _autoResumeCountdown = 0;
          _autoResumeDisabled = false;
          if (!_buffering) {
            _autoResumeAttempts = 0;
          }
          // A (re)start clears any interruption state
          // (plan 80): playback is running again, whether it
          // recovered on its own or the user resumed it.
          _stallTimer?.cancel();
          _bufferingSincePlaying = false;
          if (widget.live && _liveDelayedByPause) {
            unawaited(_updateLiveCatchUpSpeed(immediate: true));
          }
        } else if (wasPlaying) {
          _onPlaybackStopped();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        if (_conflictHandled || _switchingChannel) return;
        _diag(DiagCategory.playback, 'player: buffering=$buffering');
        if (!_initialPlaybackStarted) {
          _logPlaybackTrace(
            'mpv buffering=$buffering playingNow=$_playingNow frame=$_hasVideoFrame +${_openStartedAt?.elapsedMilliseconds ?? 0}ms',
          );
        }
        if (_playingNow) {
          // Buffering while mpv is trying to play is the
          // signature the plan-78 stalls left just before
          // mpv stopped (plan 80); buffering clearing again
          // while playing is a recovery and clears it.
          _bufferingSincePlaying = buffering;
        }
        if (!buffering && _playingNow) {
          _autoResumeAttempts = 0;
          if (!_decodeStatusLogged) {
            _decodeStatusLogged = true;
            unawaited(_logDecodeStatus());
          }
        }
        if (widget.live &&
            widget.onCheckRecordingConflict != null &&
            !_conflictHandled) {
          if (buffering) {
            _startLiveConflictPoller();
          } else {
            _stopLiveConflictPoller();
          }
        }
        final changed = _buffering != buffering;
        _buffering = buffering;
        if (_shouldPollLiveBuffering) {
          _startPreBufferPoller();
        }
        final latched = _maybeLatchInitialPlaybackStarted();
        _maybeCancelStartWatchdog();
        if (mounted && (changed || latched)) {
          setState(() {});
        }
      }),
    );
    _subscriptions.add(
      _player.stream.width.listen((width) {
        if (!_hasVideoFrame && width != null && width > 0 && mounted) {
          _logPlaybackTrace(
            'first frame width=$width at ${_openStartedAt?.elapsedMilliseconds ?? 0}ms',
          );
          setState(() {
            _hasVideoFrame = true;
            _positionAtFirstFrame ??= _lastPosition;
            _maybeLatchInitialPlaybackStarted();
          });
          _maybeCancelStartWatchdog();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        _diag(DiagCategory.playback, 'player: completed=$completed');
        _completed = completed;
        if (completed && !widget.live && _playing) {
          _handleRecordedCompletion('mpv completed');
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        _lastPosition = position;
        var shouldRebuild = false;
        if (!_initialPlaybackStarted &&
            _hasVideoFrame &&
            _maybeLatchInitialPlaybackStarted()) {
          shouldRebuild = true;
        }
        final committed = _committedSeekTarget;
        if (committed != null &&
            (position - committed).abs() <= const Duration(seconds: 2)) {
          _committedSeekTarget = null;
          _committedSeekHoldTimer?.cancel();
          if (_seekHudVisible) shouldRebuild = true;
        }
        if (shouldRebuild && mounted) setState(() {});
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((duration) {
        if (duration > Duration.zero && duration != _duration) {
          if (mounted) {
            setState(() => _duration = duration);
          } else {
            _duration = duration;
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.buffer.listen((bufferEnd) {
        final prevLoadSec = _effectiveLoadingCurrentSeconds;
        final prevDeltaFloor = _bufferDeltaSeconds.floor();
        if (bufferEnd > Duration.zero && _initialBufferPosition == null) {
          _initialBufferPosition = bufferEnd <= const Duration(seconds: 5)
              ? Duration.zero
              : bufferEnd;
        }
        if (bufferEnd != _bufferEndPosition) {
          _bufferEndPosition = bufferEnd;
          if (mounted &&
              ((_shouldPollLiveBuffering &&
                      _effectiveLoadingCurrentSeconds != prevLoadSec) ||
                  (_seekHudVisible &&
                      _bufferDeltaSeconds.floor() != prevDeltaFloor) ||
                  (_osdOpen && _syncDisplayedBufferBadge()))) {
            setState(() {});
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.bufferingPercentage.listen((pct) {
        if (!pct.isFinite) return;
        final clamped = pct.clamp(0.0, 100.0).toDouble();
        final prevLoadSec = _effectiveLoadingCurrentSeconds;
        final prevPct = _bufferingPercentage.round();
        _bufferingPercentage = clamped;
        if (mounted &&
            _shouldPollLiveBuffering &&
            (_effectiveLoadingCurrentSeconds != prevLoadSec ||
                clamped.round() != prevPct)) {
          setState(() {});
        }
      }),
    );
    _subscriptions.add(
      _player.stream.tracks.listen((tracks) {
        if (!_initialPlaybackStarted) {
          _logPlaybackTrace(
            'mpv tracks v=${tracks.video.length} a=${tracks.audio.length} '
            's=${tracks.subtitle.length} +${_openStartedAt?.elapsedMilliseconds ?? 0}ms',
          );
        }
        _diag(
          DiagCategory.playback,
          'player: tracks: video=${tracks.video.length} '
          'audio=${tracks.audio.length} subtitle=${tracks.subtitle.length} '
          '(real audio='
          '${realTrackIds([for (final t in tracks.audio) t.id]).length} '
          'real subtitle='
          '${realTrackIds([for (final t in tracks.subtitle) t.id]).length})',
        );
        for (final track in tracks.audio) {
          _diag(
            DiagCategory.playback,
            'player: audio track: id=${track.id} codec=${track.codec} '
            'channels=${track.channelscount} language=${track.language}',
          );
        }
        for (final track in tracks.subtitle) {
          _diag(
            DiagCategory.playback,
            'player: subtitle track: id=${track.id} codec=${track.codec} '
            'language=${track.language}',
          );
        }
        if (mounted) setState(() => _tracks = tracks);
        if (!_decodeStatusLogged &&
            (realTrackIds([for (final t in tracks.video) t.id]).isNotEmpty ||
                realTrackIds([
                  for (final t in tracks.audio) t.id,
                ]).isNotEmpty)) {
          _decodeStatusLogged = true;
          unawaited(_logDecodeStatus());
        }
        // Re-resolve the caption selection against the settled
        // track list: applies the forced-off default, or the
        // track the user asked for before the list arrived.
        _applySubtitleSelection();
      }),
    );
    _subscriptions.add(
      _player.stream.track.listen((track) {
        if (mounted) setState(() => _selectedTrack = track);
      }),
    );
    _subscriptions.add(
      _player.stream.subtitle.listen((lines) {
        if (_conflictHandled || _switchingChannel) return;
        final nonEmpty = [
          for (final line in lines)
            if (line.trim().isNotEmpty) line,
        ];
        if (nonEmpty.isEmpty) {
          if (_usingDirectAribCaptions && _subtitlesOn) {
            _requestImmediateSubtitleSync();
          } else {
            _clearDisplayedSubtitles();
          }
          return;
        }
        if (!_subtitlesOn) return;
        if (_player.platform is NativePlayer) {
          _requestImmediateSubtitleSync();
        } else {
          _plainSubtitleLines = nonEmpty;
          _recomputeVisibleSubtitles();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (_conflictHandled || _switchingChannel) return;
        _diag(DiagCategory.playback, 'player: error: $error');
        final fatal = playerErrorIsFatal(
          error,
          live: widget.live,
          alreadyPlaying: _playing,
        );
        _logPlaybackTrace(
          'mpv error fatal=$fatal hasFrame=$_hasVideoFrame playing=$_playing: $error',
        );
        if (!fatal) {
          // A seek complaint the policy classes as benign
          // (plan 43, extended after 1.4.0): live viewing,
          // where the stream is unseekable by design, or any
          // playback already under way, where the complaint
          // can only be answering a seek and mpv keeps
          // playing. Leave the watchdog running as the
          // arbiter of a start that never reaches playback.
          _diag(
            DiagCategory.playback,
            'player: ignoring the seek complaint '
            '(live=${widget.live}, alreadyPlaying=$_playing)',
          );
          return;
        }
        _wakelockSession.setPlaying(false);
        _watchdog?.cancel();
        _stopStartupTraceTimer();
        if (!mounted) return;
        final hasStartedFrames = shouldSurfacePreFrameStopAsInterruption(
          hasVideoFrame: _hasVideoFrame,
          initialPlaybackStarted: _initialPlaybackStarted,
        );
        if (hasStartedFrames && _playing) {
          if (!widget.live && _isEffectivelyCompleted) {
            _handleRecordedCompletion('trailing error near end: $error');
            return;
          }
          // The failure arrived after playback had started
          // (plan 80): an interruption, not a failed start.
          // Keep the frozen frame and offer the in-place
          // resume instead of replacing the screen with the
          // start-failure message.
          _enterInterruptedState(error);
        } else if (_error == null) {
          _setStartError('$error\n\n${_buildCompactDiagnosticsSummary()}');
        }
      }),
    );
    _observeSeekable();
    _observeCacheDuration();
    _observeAssSubtitle();
    _open();
    _loadChapters();
    if (widget.live &&
        ((_liveBandGuideEvents.isEmpty && widget.loadLiveBandGuideEvents != null) ||
            (_liveGuideEvents.isEmpty && widget.loadLiveGuideEvents != null))) {
      unawaited(_loadLiveGuideEvents(force: true));
    }
    _recordingSchedules = List<RecordSchedule>.of(
      widget.initialRecordingSchedules,
    );
    if (widget.initialCornerNotice != null &&
        widget.initialCornerNotice!.isNotEmpty) {
      _showCustomCornerNotice(widget.initialCornerNotice!);
    }
    if (widget.live && _activeLiveChannel != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateSameChannelRecordingStatus();
      });
      _recordingStatusTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _updateSameChannelRecordingStatus(),
      );
    }
  }

  bool get _isEffectivelyCompleted =>
      _completed ||
      isNearRecordedEnd(
        live: widget.live,
        position: _lastPosition,
        duration: _effectiveDuration,
      );

  void _handleRecordedCompletion(String reason) {
    if (widget.live || !_playing) return;
    _completed = true;
    _stallTimer?.cancel();
    _autoResumeTimer?.cancel();
    _resumeWatchdogTimer?.cancel();
    _clearDisplayedSubtitles(stopTimer: true);
    _resetSubtitleTrackTracking();
    _wakelockSession.setPlaying(false);
    _diag(DiagCategory.playback, 'player: recorded playback finished ($reason)');
    if (mounted && (_interrupted || _autoResumeCountdown != 0 || _buffering)) {
      setState(() {
        _interrupted = false;
        _autoResumeCountdown = 0;
        _buffering = false;
      });
    }
    if (_autoPoppedOnComplete) return;
    _autoPoppedOnComplete = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (_exitConfirmOpen) {
        if (nav.canPop()) nav.pop(true);
        return;
      }
      if (nav.canPop()) {
        nav.pop();
      }
    });
  }

  Future<void> _confirmExitPlayback() async {
    if (_exitConfirmOpen || !mounted) return;
    _exitConfirmOpen = true;
    var confirmed = false;
    try {
      confirmed = await showPlayerExitConfirmDialog(context);
    } finally {
      _exitConfirmOpen = false;
    }
    if (!mounted) return;
    if (confirmed) {
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
      return;
    }
    _suppressBackPopUntil = DateTime.now().add(
      const Duration(milliseconds: 300),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _interrupted ? _resumeButtonFocusNode : _rootFocusNode;
      if (target.canRequestFocus) {
        target.requestFocus();
      }
    });
  }

  void _setStartError(String error, {bool allowAfterConflict = false}) {
    _stopPreBufferPoller();
    _stopStartupTraceTimer();
    _logPlaybackTrace('start error: $error');
    if (!mounted) return;
    if (!allowAfterConflict && (_conflictHandled || _switchingChannel)) return;
    setState(() => _error = error);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _error != null &&
          (allowAfterConflict || (!_conflictHandled && !_switchingChannel)) &&
          _errorBackFocusNode.canRequestFocus) {
        _errorBackFocusNode.requestFocus();
      }
    });
  }

  void _enterInterruptedState(String? detail) {
    _stopPreBufferPoller();
    _stopStartupTraceTimer();
    _logPlaybackTrace(
      'interrupted detail=${detail ?? 'stall'} ${_buildCompactDiagnosticsSummary()}',
    );
    if (!mounted ||
        shouldSuppressPlayerInterruption(
          completed: _completed,
          conflictHandled: _conflictHandled,
          switchingChannel: _switchingChannel,
        )) {
      return;
    }
    if (widget.live && widget.onCheckRecordingConflict != null) {
      unawaited(_handlePossibleLiveRecordingConflict());
    }
    setState(() {
      _interrupted = true;
      if (detail != null) _interruptDetail = detail;
    });
    _scheduleAutoResume();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _interrupted &&
          !_conflictHandled &&
          !_switchingChannel &&
          _resumeButtonFocusNode.canRequestFocus) {
        _resumeButtonFocusNode.requestFocus();
      }
    });
  }

  void _scheduleAutoResume() {
    _autoResumeTimer?.cancel();
    if (_autoResumeDisabled ||
        !_interrupted ||
        _conflictHandled ||
        _switchingChannel ||
        !mounted) {
      return;
    }
    final delaySec = _autoResumeBackoffSeconds[
        math.min(_autoResumeAttempts, _autoResumeBackoffSeconds.length - 1)];
    _autoResumeAttempts++;
    setState(() => _autoResumeCountdown = delaySec);
    _diag(
      DiagCategory.playback,
      'player: scheduling auto-resume attempt $_autoResumeAttempts in ${delaySec}s',
    );
    _autoResumeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted ||
          !_interrupted ||
          _autoResumeDisabled ||
          _conflictHandled ||
          _switchingChannel) {
        timer.cancel();
        return;
      }
      if (_autoResumeCountdown <= 1) {
        timer.cancel();
        if (mounted) {
          setState(() => _autoResumeCountdown = 0);
        }
        unawaited(_resume());
      } else {
        setState(() => _autoResumeCountdown--);
      }
    });
  }

  void _onStartTimeout() {
    if (!mounted ||
        _playing ||
        _error != null ||
        _conflictHandled ||
        _switchingChannel) {
      return;
    }
    if (widget.live && widget.onCheckRecordingConflict != null) {
      unawaited(_handlePossibleLiveRecordingConflict());
    }
    final timeoutSec = _bufferPlan?.startTimeoutSeconds ?? startTimeout.inSeconds;
    final diagSummary = _buildCompactDiagnosticsSummary();
    _diag(
      DiagCategory.playback,
      'player: no playback within $timeoutSec seconds; '
      'showing a timeout error ($diagSummary)',
    );
    _logPlaybackTrace('start timeout (${timeoutSec}s): $diagSummary');
    _setStartError(
      '再生が開始できませんでした ($timeoutSec 秒以内に映像が届きませんでした)。\n\n$diagSummary',
    );
  }

  DateTime _now() => widget.nowProvider?.call() ?? DateTime.now();

  void _showCustomCornerNotice(
    String text, {
    Duration duration = const Duration(seconds: 5),
  }) {
    if (!mounted || text.isEmpty) return;
    _customCornerNoticeTimer?.cancel();
    setState(() => _customCornerNoticeText = text);
    _customCornerNoticeTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() => _customCornerNoticeText = null);
    });
  }

  LiveChannel? get _activeLiveChannel =>
      _currentLiveChannel ?? widget.currentLiveChannel;

  void _recordLiveChannelProgramSnapshot(LiveChannel? ch) {
    if (!widget.live || ch == null) return;
    final start = ch.programStart;
    final end = ch.programEnd;
    final title = ch.programTitle.trim();
    if (start == null || end == null || !end.isAfter(start) || title.isEmpty) {
      return;
    }
    final key = liveServiceKey(ch);
    final list = _liveChannelProgramHistory.putIfAbsent(key, () => []);
    final duplicate = list.any(
      (e) =>
          e.start.isAtSameMomentAs(start) &&
          e.end.isAtSameMomentAs(end) &&
          e.title == title,
    );
    if (duplicate) return;
    list.add(
      EpgEvent(
        eventId: 0,
        start: start,
        duration: end.difference(start),
        title: title,
        shortText: ch.description,
        description: ch.longDescription,
      ),
    );
    list.sort((a, b) => a.start.compareTo(b.start));
    if (list.length > 8) {
      list.removeRange(0, list.length - 8);
    }
  }

  List<EpgEvent> _guideEventsForChannel(LiveChannel channel) {
    final key = liveServiceKey(channel);
    final history = _liveChannelProgramHistory[key] ?? const <EpgEvent>[];
    final bandEvents = _liveBandGuideEvents[key];
    if (bandEvents != null && bandEvents.isNotEmpty) {
      return mergeLiveProgramEventLists(bandEvents, history);
    }
    final active = _activeLiveChannel;
    if (active != null &&
        liveServiceKey(active) == key &&
        _liveGuideEvents.isNotEmpty) {
      return mergeLiveProgramEventLists(_liveGuideEvents, history);
    }
    return history;
  }

  void _updateSameChannelRecordingStatus() {
    final channel = _activeLiveChannel;
    if (!mounted || !widget.live || channel == null) return;
    final effectiveSchedules = schedulesExcludingIds(
      _recordingSchedules,
      _stoppedScheduleIds,
    );
    final active = findActiveSameChannelRecording(
      effectiveSchedules,
      currentChannel: channel,
      now: _now(),
    );
    final recordingNow = active != null;
    final notice = resolveLiveRecordingCornerNotice(
      previousRecording: _lastSameChannelRecording,
      currentRecording: recordingNow,
    );
    _lastSameChannelRecording = recordingNow;
    _activeSameChannelSchedule = active;
    if (_sameChannelRecording != recordingNow || notice != null) {
      setState(() {
        _sameChannelRecording = recordingNow;
        if (notice != null) {
          _cornerRecordingNotice = notice;
        }
      });
    }
    if (notice != null) {
      _cornerNoticeTimer?.cancel();
      _cornerNoticeTimer = Timer(liveRecordingCornerNoticeDuration, () {
        if (!mounted) return;
        setState(() => _cornerRecordingNotice = null);
      });
    }
  }

  void _restoreFocusAfterDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _osdOpen ? _osdFirstFocusNode : _rootFocusNode;
      if (target.canRequestFocus) {
        target.requestFocus();
      }
    });
  }

  Future<void> _confirmAndStartLiveRecording() async {
    final startCallback = widget.onStartCurrentProgramRecording;
    if (startCallback == null ||
        _recordingActionBusy ||
        !mounted ||
        _conflictHandled) {
      return;
    }
    _osdTimer?.cancel();
    final quality = ref.read(defaultRecordingQualityProvider);
    final activeChannel = _activeLiveChannel;
    final resolvedTitle = activeChannel != null
        ? resolveLiveOsdProgramInfo(
            channel: activeChannel,
            guideEvents: _guideEventsForChannel(activeChannel),
            now: _now(),
          ).currentTitle
        : '';
    final titleText = resolvedTitle.isNotEmpty
        ? resolvedTitle
        : (widget.programDetailTitle ?? widget.title);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この番組を録画しますか？'),
        content: Text(
          buildLiveRecordingConfirmContent(
            titleText: titleText,
            qualityLabel: qualityModeLabel(quality),
            liveDelayedByPause: _liveDelayedByPause,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('録画を開始'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _suppressBackPopUntil = DateTime.now().add(
      const Duration(milliseconds: 300),
    );
    if (confirmed != true) {
      if (_osdOpen) _resetOsdTimer();
      _restoreFocusAfterDialog();
      return;
    }
    setState(() => _recordingActionBusy = true);
    LiveRecordingActionResult result;
    try {
      result = await startCallback();
    } catch (e) {
      result = LiveRecordingActionResult(
        success: false,
        message: '録画を開始できませんでした: $e',
      );
    } finally {
      if (mounted) setState(() => _recordingActionBusy = false);
    }
    if (!mounted) return;
    final reconciled = reconcileLiveRecordingSchedules(
      currentSchedules: _recordingSchedules,
      currentStoppedIds: _stoppedScheduleIds,
      isStopAction: false,
      actionSucceeded: result.success,
      updatedSchedules: result.updatedSchedules,
    );
    _stoppedScheduleIds
      ..clear()
      ..addAll(reconciled.stoppedIds);
    _recordingSchedules = reconciled.schedules;
    final before = _sameChannelRecording;
    _updateSameChannelRecordingStatus();
    if (!result.success || _sameChannelRecording == before) {
      _showCustomCornerNotice(result.message);
    }
    if (_osdOpen) _resetOsdTimer();
    _restoreFocusAfterDialog();
  }

  Future<void> _confirmAndStopLiveRecording() async {
    final stopCallback = widget.onStopCurrentProgramRecording;
    final active = _activeSameChannelSchedule;
    if (stopCallback == null ||
        active == null ||
        _recordingActionBusy ||
        !mounted ||
        _conflictHandled) {
      return;
    }
    _osdTimer?.cancel();
    final confirmed = await confirmDialog(
      context,
      title: '録画を停止しますか？',
      message: '現在の録画を停止します。ここまでに録画された内容は録画済み一覧に残ります。',
      confirmLabel: '録画を停止',
    );
    if (!mounted) return;
    _suppressBackPopUntil = DateTime.now().add(
      const Duration(milliseconds: 300),
    );
    if (!confirmed) {
      if (_osdOpen) _resetOsdTimer();
      _restoreFocusAfterDialog();
      return;
    }
    setState(() => _recordingActionBusy = true);
    LiveRecordingActionResult result;
    try {
      result = await stopCallback(active);
    } catch (e) {
      result = LiveRecordingActionResult(
        success: false,
        message: '録画を停止できませんでした: $e',
      );
    } finally {
      if (mounted) setState(() => _recordingActionBusy = false);
    }
    if (!mounted) return;
    final reconciled = reconcileLiveRecordingSchedules(
      currentSchedules: _recordingSchedules,
      currentStoppedIds: _stoppedScheduleIds,
      isStopAction: true,
      actionSucceeded: result.success,
      targetScheduleId: active.id,
      updatedSchedules: result.updatedSchedules,
    );
    _stoppedScheduleIds
      ..clear()
      ..addAll(reconciled.stoppedIds);
    _recordingSchedules = reconciled.schedules;
    final before = _sameChannelRecording;
    _updateSameChannelRecordingStatus();
    if (!result.success || _sameChannelRecording == before) {
      _showCustomCornerNotice(result.message);
    }
    if (_osdOpen) _resetOsdTimer();
    _restoreFocusAfterDialog();
  }

  void _startLiveConflictPoller() {
    if (_liveConflictPollTimer != null ||
        _conflictHandled ||
        !widget.live ||
        widget.onCheckRecordingConflict == null) {
      return;
    }
    _liveConflictPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _conflictHandled || !_buffering) {
        _stopLiveConflictPoller();
        return;
      }
      if (widget.session case final StreamTransferMetrics metrics) {
        if (metrics.consecutiveReconnectErrors >= 2) {
          unawaited(_handlePossibleLiveRecordingConflict());
        }
      }
    });
  }

  void _stopLiveConflictPoller() {
    _liveConflictPollTimer?.cancel();
    _liveConflictPollTimer = null;
  }

  Future<void> _handlePossibleLiveRecordingConflict() async {
    final check = widget.onCheckRecordingConflict;
    if (check == null ||
        _checkingConflict ||
        _conflictHandled ||
        !mounted ||
        !widget.live) {
      return;
    }
    _checkingConflict = true;
    LiveRecordingConflict? conflict;
    try {
      conflict = await check();
    } catch (e) {
      _diag(DiagCategory.playback, 'player: conflict check failed: $e');
    } finally {
      _checkingConflict = false;
    }
    if (conflict == null || _conflictHandled || !mounted) return;

    _conflictHandled = true;
    _autoResumeDisabled = true;
    _stopLiveConflictPoller();
    _stopPreBufferPoller();
    _stopStartupTraceTimer();
    _stopSubtitleSyncTimer();
    _watchdog?.cancel();
    _stallTimer?.cancel();
    _autoResumeTimer?.cancel();
    _resumeWatchdogTimer?.cancel();
    _clearDisplayedSubtitles(stopTimer: true);
    _resetSubtitleTrackTracking();
    _resetLiveCatchUpState(resetPlayerRate: false);
    _recordingStatusTimer?.cancel();
    _cornerNoticeTimer?.cancel();
    _customCornerNoticeTimer?.cancel();
    _osdTimer?.cancel();
    _osdClockTimer?.cancel();
    _osdClockTimer = null;
    _hudTimer?.cancel();
    _seekHudTimer?.cancel();
    _seekDebounceTimer?.cancel();
    _committedSeekHoldTimer?.cancel();
    _liveSeekDebounceTimer?.cancel();
    _liveCommittedSeekHoldTimer?.cancel();
    _livePendingSeekBaseSec = null;
    _livePendingSeekDeltaSec = 0.0;
    _liveCommittedSeekSec = null;

    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();

    setState(() {
      _interrupted = false;
      _interruptDetail = null;
      _autoResumeCountdown = 0;
      _osdOpen = false;
      _osdFadeController.value = 0.0;
      _detailOpen = false;
      _openedLiveDetail = null;
      _liveDetailLoading = false;
      _liveDetailRequestSeq++;
      _hudText = null;
      _cornerRecordingNotice = null;
      _customCornerNoticeText = null;
    });

    await _player.stop().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    ).catchError((_) {});
    await widget.session.stop().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    ).catchError((_) {});
    if (!mounted) return;

    final failoverReg = conflict.failoverRegistration;
    final failoverCh = conflict.failoverChannel;
    final buildFailover = widget.onBuildFailoverPlayer;
    if (failoverReg != null && failoverCh != null && buildFailover != null) {
      final notice = buildLiveFailoverNotice(
        fromNasneName: conflict.nasneName,
        toRegistration: failoverReg,
      );
      setState(() {
        _switchingChannel = true;
        _error = null;
      });
      try {
        final nextPlayer = await buildFailover(failoverReg, failoverCh, notice);
        if (!mounted) return;
        await _pushReplacementPlayer(nextPlayer);
        return;
      } catch (e) {
        _diag(
          DiagCategory.playback,
          'player: failover switch failed, falling back to conflict dialog: $e',
        );
        if (!mounted) return;
        setState(() => _switchingChannel = false);
      }
    }
    if (!mounted) return;

    final shouldSwitch = await showLiveRecordingConflictDialog(
      context,
      conflict: conflict,
      midStream: true,
    );
    if (!mounted) return;

    final target = conflict.liveChannel;
    final buildNext = widget.onBuildRecordingChannelPlayer;
    if (shouldSwitch == true && target != null && buildNext != null) {
      setState(() {
        _switchingChannel = true;
        _error = null;
      });
      try {
        final nextPlayer = await buildNext(target);
        if (!mounted) return;
        await _pushReplacementPlayer(nextPlayer);
      } catch (e) {
        _diag(
          DiagCategory.playback,
          'player: recording channel switch failed: $e',
        );
        if (!mounted) return;
        setState(() => _switchingChannel = false);
        _setStartError(
          '録画中のチャンネルへの切り替えに失敗しました。録画終了後に再度お試しください。',
          allowAfterConflict: true,
        );
      }
      return;
    }

    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  /// A playing→stopped transition (plan 80): when the
  /// policy classes it as a mid-stream death, give mpv a
  /// grace period to recover on its own before surfacing
  /// anything.
  void _onPlaybackStopped() {
    if (_conflictHandled || _switchingChannel) return;
    if (!shouldSurfacePreFrameStopAsInterruption(
      hasVideoFrame: _hasVideoFrame,
      initialPlaybackStarted: _initialPlaybackStarted,
    )) {
      var served = -1;
      Object? upstreamErr;
      if (widget.session case final StreamTransferMetrics transfer) {
        served = transfer.servedBytes;
      }
      if (widget.session case final StreamDiagnosticMetrics diagMetrics) {
        upstreamErr = diagMetrics.lastUpstreamError;
      }
      _logPlaybackTrace(
        'pre-frame stop: ${_buildCompactDiagnosticsSummary()}',
      );
      if (served == 0 && upstreamErr != null) {
        _watchdog?.cancel();
        _setStartError(
          'ストリームを受信できませんでした (${describeStreamErrorSafely(upstreamErr)})。\n\n'
          '${_buildCompactDiagnosticsSummary()}',
        );
      }
      return;
    }
    if (!playbackStoppedEarly(
      alreadyPlaying: _playing,
      completed: _completed,
      bufferedBeforeStop: _bufferingSincePlaying,
    )) {
      return;
    }
    if (!widget.live && _isEffectivelyCompleted) {
      _handleRecordedCompletion('stopped after buffering near end');
      return;
    }
    _diag(
      DiagCategory.playback,
      'player: playback stopped after buffering without '
      'completing; watching for a recovery for '
      '${stallTimeout.inSeconds} seconds (plan 80)',
    );
    _stallTimer?.cancel();
    _stallTimer = Timer(stallTimeout, _onStallTimeout);
  }

  void _onStallTimeout() {
    if (!mounted ||
        _playingNow ||
        _completed ||
        _error != null ||
        _conflictHandled ||
        _switchingChannel) {
      return;
    }
    if (!widget.live && _isEffectivelyCompleted) {
      _handleRecordedCompletion('stall timeout near end');
      return;
    }
    _diag(
      DiagCategory.playback,
      'player: playback did not recover; showing the '
      'interruption notice (plan 80)',
    );
    _enterInterruptedState(null);
  }

  Future<void> _resume() async {
    if (!mounted || _conflictHandled || _switchingChannel) return;
    _diag(
      DiagCategory.playback,
      'player: resuming after an interruption at '
      '${_lastPosition.inSeconds}s (live=${widget.live})',
    );
    _stallTimer?.cancel();
    _autoResumeTimer?.cancel();
    _resumeWatchdogTimer?.cancel();
    _clearDisplayedSubtitles(stopTimer: true);
    _resetSubtitleTrackTracking();
    if (widget.live) {
      _resetLiveCatchUpState(resetPlayerRate: true);
    }
    setState(() {
      _autoResumeDisabled = false;
      _autoResumeCountdown = 0;
      _interrupted = false;
      _interruptDetail = null;
      _buffering = true;
      _bufferingPercentage = 0.0;
      _bufferedAheadSeconds = 0.0;
      _bufferEndPosition = Duration.zero;
      _initialBufferPosition = null;
      _liveCacheStartSec = null;
      _liveCacheEndSec = null;
      _liveCacheLiveEdgeSec = null;
      _liveTimePosSec = null;
      _liveStreamEpoch = null;
      _liveMaxAdvancingCacheEndSec = null;
      _livePendingSeekBaseSec = null;
      _livePendingSeekDeltaSec = 0.0;
      _liveSeekDebounceTimer?.cancel();
      _liveCommittedSeekSec = null;
      _liveCommittedSeekHoldTimer?.cancel();
      _positionAtFirstFrame = null;
      _lastObservedServedBytes = 0;
      _lastLiveTransferTickAt = null;
      _liveTransferAccumulatedSeconds = 0.0;
    });
    if (_isPreBuffering) {
      _startPreBufferPoller();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_conflictHandled &&
          !_switchingChannel &&
          _rootFocusNode.canRequestFocus) {
        _rootFocusNode.requestFocus();
      }
    });
    _resumeWatchdogTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted ||
          _playingNow ||
          _completed ||
          _interrupted ||
          _error != null ||
          _conflictHandled ||
          _switchingChannel) {
        return;
      }
      if (!widget.live && _isEffectivelyCompleted) {
        _handleRecordedCompletion('resume watchdog near end');
        return;
      }
      _enterInterruptedState('再接続がタイムアウトしました。電波状況を確認して再試行します。');
    });
    try {
      await _player.setVolume(100.0);
      if (!mounted || _conflictHandled || _switchingChannel) return;
      await _player.open(
        Media(
          widget.session.mediaUri.toString(),
          start: (!widget.live && _lastPosition > Duration.zero)
              ? _lastPosition
              : null,
        ),
      );
      if (!mounted || _conflictHandled || _switchingChannel) return;
      await _player.setVolume(100.0);
      _diag(DiagCategory.playback, 'player: resume open completed');
    } catch (e) {
      if (!mounted || _conflictHandled || _switchingChannel) return;
      _diag(DiagCategory.playback, 'player: resume failed: $e');
      _resumeWatchdogTimer?.cancel();
      _enterInterruptedState('$e');
    }
  }

  void _stopSubtitleSyncTimer() {
    _subtitleSyncTimer?.cancel();
    _subtitleSyncTimer = null;
    _subtitleRetryTimer?.cancel();
    _subtitleRetryTimer = null;
  }

  void _startSubtitleSyncTimer() {
    if (_subtitleSyncTimer != null) return;
    _subtitleSyncTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_syncSubtitleTick()),
    );
  }

  void _requestImmediateSubtitleSync() {
    if (!mounted || !_subtitlesOn) return;
    if (_pollingSubtitleSync) {
      _pendingImmediateSubtitleSync = true;
      return;
    }
    unawaited(_syncSubtitleTick(advanceClock: false));
  }

  Future<String> _safeGetProp(NativePlayer platform, String name) async {
    try {
      return await platform.getProperty(name);
    } catch (_) {
      return '';
    }
  }

  void _resetSubtitleTrackTracking() {
    _aribPtsOffset = null;
    _demuxerStartTimeSeconds = null;
    _usingDirectAribCaptions = false;
    _suppressedCaptionSignature = null;
    _lastSeenSubStartSeconds = null;
  }

  void _clearDisplayedSubtitles({bool notify = true, bool stopTimer = false}) {
    if (stopTimer || !_subtitlesOn) {
      _stopSubtitleSyncTimer();
    } else {
      _subtitleRetryTimer?.cancel();
      _subtitleRetryTimer = null;
    }
    _subtitleTracker.reset();
    _plainSubtitleLines = const [];
    _rawAssSubtitle = '';
    _activeSubStartSeconds = null;
    _activeClearAfterSeconds = null;
    _subtitleMismatchRetries = 0;
    _lastRenderedPlainCompact = '';
    if (_visibleSubtitleCues.isEmpty) return;
    _visibleSubtitleCues = const [];
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _recomputeVisibleSubtitles({bool atomicSnapshot = false}) {
    if (!_subtitlesOn) {
      _clearDisplayedSubtitles(stopTimer: true);
      return;
    }
    final rawCues = resolveRawSubtitleCues(
      rawAss: _rawAssSubtitle,
      plainLines: _plainSubtitleLines,
      playResWidth: _assPlayResWidth,
      playResHeight: _assPlayResHeight,
      atomicSnapshot: atomicSnapshot,
    );
    var nextCues = _subtitleTracker.update(
      rawCues,
      _subtitlePlaybackClock,
      mpvSubStartSeconds: _activeSubStartSeconds,
    );
    if (nextCues.isNotEmpty) {
      _startSubtitleSyncTimer();
      final layoutSource = widget.session is AribCaptionLayoutSource
          ? widget.session as AribCaptionLayoutSource
          : null;
      final ptsRef = _activeSubStartSeconds ?? _lastPlaybackTimeSeconds;
      if (layoutSource != null && ptsRef != null) {
        final events = layoutSource.aribCaptionEvents;
        _aribPtsOffset = resolveAribPtsOffset(
          events: events,
          mpvSubStartSeconds: ptsRef,
          firstStreamPtsSeconds: layoutSource.firstStreamPtsSeconds,
          currentOffset: _aribPtsOffset,
        );
        if (_aribPtsOffset != null) {
          final matched = findMatchingAribLayoutEvent(
            events: events,
            mpvSubStartSeconds: ptsRef,
            ptsOffset: _aribPtsOffset!,
          );
          if (matched != null) {
            _activeClearAfterSeconds = matched.clearAfterSeconds;
            nextCues = applyAribLayoutToCues(cues: nextCues, layout: matched);
          }
        }
      }
    }
    final changed = !_cuesEqual(_visibleSubtitleCues, nextCues);
    _visibleSubtitleCues = nextCues;
    if (changed && mounted) {
      setState(() {});
    }
  }

  Future<void> _resetAribSubtitleDecoder(NativePlayer platform) async {
    if (_resettingAribDecoder || !mounted || !_subtitlesOn) return;
    _resettingAribDecoder = true;
    _lastAribDecoderResetAt = _now();
    _diag(
      DiagCategory.playback,
      'player: resetting libaribb24 decoder to clear accumulated timing buffer',
    );
    try {
      await platform.setProperty('sid', 'no');
      final id = subtitleTrackIdToSelect(
        subtitlesOn: _subtitlesOn,
        subtitleTrackIds: [for (final track in _realSubtitleTracks) track.id],
      );
      if (mounted && _subtitlesOn && id != null) {
        await platform.setProperty('sid', id);
      }
      if (mounted) {
        _resetSubtitleTrackTracking();
        _clearDisplayedSubtitles(stopTimer: false);
      }
    } catch (e) {
      _diag(DiagCategory.playback, 'player: arib decoder reset failed: $e');
    } finally {
      _resettingAribDecoder = false;
    }
  }

  bool _cuesEqual(List<SubtitleCue> a, List<SubtitleCue> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].dedupeKey != b[i].dedupeKey) return false;
      final sa = a[i].spans;
      final sb = b[i].spans;
      if (sa.length != sb.length) return false;
      for (var j = 0; j < sa.length; j++) {
        if (sa[j].text != sb[j].text ||
            sa[j].color != sb[j].color ||
            sa[j].scale != sb[j].scale ||
            sa[j].drcsGlyph != sb[j].drcsGlyph) {
          return false;
        }
      }
    }
    return true;
  }

  Future<void> _ensureAssExtradataLoaded(NativePlayer platform) async {
    if (_assExtradataLoaded) return;
    _assExtradataLoaded = true;
    try {
      final extradata = await platform.getProperty('sub-ass-extradata');
      final res = parseAssPlayRes(extradata);
      _assPlayResWidth = res.width;
      _assPlayResHeight = res.height;
    } catch (_) {}
  }

  Future<void> _observeAssSubtitle() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.observeProperty('sub-text-ass', (value) async {
        if (!mounted || _conflictHandled || _switchingChannel) return;
        await _ensureAssExtradataLoaded(platform);
        if (!_loggedAssSample && value.trim().isNotEmpty) {
          _loggedAssSample = true;
          _diag(
            DiagCategory.playback,
            'player: ass subtitle sample '
            '(${_assPlayResWidth.toInt()}x${_assPlayResHeight.toInt()}): '
            '${value.replaceAll('\n', ' | ')}',
          );
        }
        if (!_subtitlesOn) return;
        if (value.trim().isEmpty && _plainSubtitleLines.isEmpty) {
          if (_usingDirectAribCaptions) {
            _requestImmediateSubtitleSync();
          } else {
            _clearDisplayedSubtitles();
          }
          return;
        }
        _requestImmediateSubtitleSync();
      });
    } catch (e) {
      _diag(DiagCategory.playback, 'player: sub-text-ass observation failed: $e');
    }
  }

  Future<void> _syncSubtitleTick({bool advanceClock = true}) async {
    if (_pollingSubtitleSync) {
      if (!advanceClock) _pendingImmediateSubtitleSync = true;
      return;
    }
    if (!mounted || !_subtitlesOn) {
      if (!_subtitlesOn) _stopSubtitleSyncTimer();
      return;
    }
    _pollingSubtitleSync = true;
    try {
      if (advanceClock && _playingNow && !_buffering) {
        _subtitlePlaybackClock += const Duration(milliseconds: 250);
      }
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await _ensureAssExtradataLoaded(platform);
        final props = await Future.wait<String>([
          _safeGetProp(platform, 'sub-text'),
          _safeGetProp(platform, 'sub-text-ass'),
          _safeGetProp(platform, 'sub-start'),
          _safeGetProp(platform, 'sub-end'),
          _safeGetProp(platform, 'playback-time'),
          _safeGetProp(platform, 'demuxer-start-time'),
        ]);
        if (!mounted || !_subtitlesOn) return;
        final plainNow = props[0];
        final rawAssNow = props[1];
        final subStart = double.tryParse(props[2]);
        final subEnd = double.tryParse(props[3]);
        final playbackTime = double.tryParse(props[4]);
        final demuxStart = double.tryParse(props[5]);
        if (demuxStart != null && demuxStart.isFinite) {
          _demuxerStartTimeSeconds = demuxStart;
        }
        if (playbackTime != null && playbackTime.isFinite) {
          _lastPlaybackTimeSeconds = playbackTime;
        }
        if (!_loggedAssSample && rawAssNow.trim().isNotEmpty) {
          _loggedAssSample = true;
          _diag(
            DiagCategory.playback,
            'player: ass subtitle sample '
            '(${_assPlayResWidth.toInt()}x${_assPlayResHeight.toInt()}): '
            '${rawAssNow.replaceAll('\n', ' | ')}',
          );
        }

        final directSource = widget.session is AribCaptionLayoutSource
            ? widget.session as AribCaptionLayoutSource
            : null;
        if (directSource != null && playbackTime != null) {
          final prevOffset = _aribPtsOffset;
          _aribPtsOffset = resolveDirectAribPtsOffset(
            events: directSource.aribCaptionEvents,
            playbackTimeSeconds: playbackTime,
            mpvSubStartSeconds: subStart,
            demuxerStartTimeSeconds: _demuxerStartTimeSeconds,
            firstStreamPtsSeconds: directSource.firstStreamPtsSeconds,
            currentOffset: _aribPtsOffset,
          );
          if (_aribPtsOffset != null &&
              (prevOffset == null ||
                  (_aribPtsOffset! - prevOffset).abs() > 1.0)) {
            _diag(
              DiagCategory.playback,
              'player: direct ARIB offset=$_aribPtsOffset '
              't=$playbackTime demux=$_demuxerStartTimeSeconds '
              'firstPts=${directSource.firstStreamPtsSeconds} '
              'events=${directSource.aribCaptionEvents.length}',
            );
          }
          if (_aribPtsOffset != null) {
            final direct = resolveDirectAribTsSubtitleCues(
              events: directSource.aribCaptionEvents,
              currentPlaybackMpvPts: playbackTime,
              ptsOffset: _aribPtsOffset!,
            );
            if (direct.handled) {
              _usingDirectAribCaptions = true;
              _subtitleMismatchRetries = 0;
              _suppressedCaptionSignature = null;
              if (subStart != null) {
                _lastSeenSubStartSeconds = subStart;
              }
              final changed = !_cuesEqual(_visibleSubtitleCues, direct.cues);
              _visibleSubtitleCues = direct.cues;
              if (changed && mounted) {
                setState(() {});
              }
              return;
            }
          }
        }
        _usingDirectAribCaptions = false;

        final nextPlain = [
          for (final line in plainNow.split('\n'))
            if (line.trim().isNotEmpty) line,
        ];
        if (nextPlain.isEmpty && rawAssNow.trim().isEmpty) {
          _suppressedCaptionSignature = null;
          _clearDisplayedSubtitles(stopTimer: false);
          return;
        }

        if (canResetAribSubtitleDecoderSafely(
              live: widget.live,
              configuredLiveBufferSeconds: _bufferPlan?.configuredSeconds ?? 0,
              liveDelayedByPause: _liveDelayedByPause,
              bufferedAheadSeconds: _bufferedAheadSeconds,
            ) &&
            shouldResetAribSubtitleDecoder(
              subStartSeconds: subStart,
              subEndSeconds: subEnd,
              playbackTimeSeconds: playbackTime,
              plainUtf8Bytes: utf8.encode(plainNow).length,
              assUtf8Bytes: utf8.encode(rawAssNow).length,
            ) &&
            !_resettingAribDecoder &&
            (_lastAribDecoderResetAt == null ||
                _now().difference(_lastAribDecoderResetAt!) >=
                    const Duration(seconds: 8))) {
          await _resetAribSubtitleDecoder(platform);
          return;
        }

        final nextPlainCompact = normalizeAribSubtitleSymbols(
          nextPlain.join(),
        ).replaceAll(RegExp(r'[\s\u00A0]+'), '');
        final captionSig = subtitleCaptionSignature(
          subStartSeconds: subStart,
          plainCompact: nextPlainCompact,
        );
        if (shouldSuppressClearedSubtitle(
          suppressedSignature: _suppressedCaptionSignature,
          currentSignature: captionSig,
        )) {
          return;
        }
        _suppressedCaptionSignature = null;

        final assMatches = subtitleTextMatchesAss(
          rawAss: rawAssNow,
          plainLines: nextPlain,
          playResWidth: _assPlayResWidth,
          playResHeight: _assPlayResHeight,
        );
        final textChanged =
            nextPlainCompact != _lastRenderedPlainCompact &&
            nextPlainCompact.isNotEmpty;
        final subStartStale =
            textChanged &&
            subStart != null &&
            _lastSeenSubStartSeconds != null &&
            (subStart - _lastSeenSubStartSeconds!).abs() < 0.05;

        final layoutSource = widget.session is AribCaptionLayoutSource
            ? widget.session as AribCaptionLayoutSource
            : null;
        final ptsRef = subStart ?? playbackTime;
        AribCaptionLayoutEvent? matchedLayout;
        if (layoutSource != null && ptsRef != null) {
          _aribPtsOffset = resolveAribPtsOffset(
            events: layoutSource.aribCaptionEvents,
            mpvSubStartSeconds: ptsRef,
            firstStreamPtsSeconds: layoutSource.firstStreamPtsSeconds,
            currentOffset: _aribPtsOffset,
          );
          if (_aribPtsOffset != null) {
            matchedLayout = findMatchingAribLayoutEvent(
              events: layoutSource.aribCaptionEvents,
              mpvSubStartSeconds: ptsRef,
              ptsOffset: _aribPtsOffset!,
            );
          }
        }
        final waitingForTsLayout =
            layoutSource != null &&
            layoutSource.aribCaptionEvents.isNotEmpty &&
            matchedLayout == null;

        if (((rawAssNow.trim().isNotEmpty && !assMatches) ||
                (rawAssNow.trim().isEmpty && _subtitleMismatchRetries == 0) ||
                subStartStale ||
                waitingForTsLayout) &&
            _subtitleMismatchRetries < 3) {
          _subtitleMismatchRetries++;
          _subtitleRetryTimer?.cancel();
          _subtitleRetryTimer = Timer(
            const Duration(milliseconds: 45),
            _requestImmediateSubtitleSync,
          );
          return;
        }
        _subtitleMismatchRetries = 0;

        if (layoutSource != null &&
            _aribPtsOffset != null &&
            ptsRef != null &&
            playbackTime != null &&
            hasAribClearSinceCaption(
              events: layoutSource.aribCaptionEvents,
              activeCaptionMpvPts: ptsRef,
              currentPlaybackMpvPts: playbackTime,
              ptsOffset: _aribPtsOffset!,
              activeClearAfterSeconds:
                  matchedLayout?.clearAfterSeconds ?? _activeClearAfterSeconds,
            )) {
          _suppressedCaptionSignature = captionSig;
          _clearDisplayedSubtitles(stopTimer: false);
          return;
        }

        _lastRenderedPlainCompact = nextPlainCompact;
        if (subStart != null) {
          _lastSeenSubStartSeconds = subStart;
        }
        _activeSubStartSeconds = ptsRef;
        _plainSubtitleLines = nextPlain;
        _rawAssSubtitle = rawAssNow;
      }
      _recomputeVisibleSubtitles(atomicSnapshot: true);
    } finally {
      _pollingSubtitleSync = false;
      if (_pendingImmediateSubtitleSync && mounted && _subtitlesOn) {
        _pendingImmediateSubtitleSync = false;
        unawaited(_syncSubtitleTick(advanceClock: false));
      }
    }
  }

  /// Applies the caption selection for the current toggle
  /// state (plan 53): the first caption track when on, and
  /// mpv's no-track selection when off — the off case is what
  /// keeps mpv's language-based auto-selection from turning
  /// captions on by itself.
  Future<void> _applySubtitleSelection() async {
    final id = subtitleTrackIdToSelect(
      subtitlesOn: _subtitlesOn,
      subtitleTrackIds: [for (final track in _realSubtitleTracks) track.id],
    );
    final currentId = _selectedTrack.subtitle.id;
    try {
      if (id == null) {
        _clearDisplayedSubtitles(stopTimer: !_subtitlesOn);
        if (currentId != 'no') {
          await _player.setSubtitleTrack(SubtitleTrack.no());
        }
      } else {
        _startSubtitleSyncTimer();
        final alreadySelected =
            currentId == id ||
            (currentId == 'auto' &&
                _realSubtitleTracks.isNotEmpty &&
                _realSubtitleTracks.first.id == id);
        if (!alreadySelected) {
          _assExtradataLoaded = false;
          await _player.setSubtitleTrack(
            _realSubtitleTracks.firstWhere((track) => track.id == id),
          );
        }
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted && _subtitlesOn) {
            unawaited(_syncSubtitleTick());
          }
        });
      }
    } catch (e) {
      _diag(DiagCategory.playback, 'player: subtitle selection failed: $e');
    }
  }

  void _toggleSubtitles() {
    setState(() => _subtitlesOn = !_subtitlesOn);
    _diag(
      DiagCategory.playback,
      'player: subtitles ${_subtitlesOn ? 'on' : 'off'} (user toggle)',
    );
    unawaited(ref.read(subtitlesEnabledProvider.notifier).set(_subtitlesOn));
    if (!_subtitlesOn) {
      _resetSubtitleTrackTracking();
      _clearDisplayedSubtitles(stopTimer: true);
    }
    _applySubtitleSelection();
  }

  Future<void> _selectAudioTrack(int index) async {
    if (index < 0 || index >= _realAudioTracks.length) return;
    final track = _realAudioTracks[index];
    _diag(
      DiagCategory.playback,
      'player: audio track -> ${audioTrackLabel(index)} (id=${track.id})',
    );
    try {
      await _player.setAudioTrack(track);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: audio selection failed: $e');
    }
  }

  /// Applies a user-chosen playback rate (plan 86, plan 85
  /// item 7). mpv pitch-corrects the audio at these rates,
  /// so speech stays intelligible; the proxy and the stream
  /// are untouched — the demuxer just consumes faster.
  Future<void> _selectPlaybackRate(double rate) async {
    if (rate == _playbackRate) return;
    setState(() => _playbackRate = rate);
    _diag(
      DiagCategory.playback,
      'player: playback rate -> ${playbackSpeedLabel(rate)} '
      '(user selection)',
    );
    try {
      await _player.setRate(rate);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: rate change failed: $e');
    }
  }

  int get _selectedAudioIndex => selectedAudioIndex(
    selectedId: _selectedTrack.audio.id,
    trackIds: [for (final track in _realAudioTracks) track.id],
  );

  /// Follows mpv's `seekable` property into [_seekable]
  /// (player UI follow-up): the recorded screen's skip
  /// buttons' enable signal. mpv re-evaluates the property
  /// as the demuxer settles, so this is an observation,
  /// not a one-shot read.
  Future<void> _observeSeekable() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.observeProperty('seekable', (value) async {
        final seekable = isSeekablePropertyValue(value);
        if (seekable != _seekable.value) {
          _diag(
            DiagCategory.playback,
            'player: seekable=$value; skip buttons '
            '${seekable ? 'enabled' : 'disabled'}',
          );
          _seekable.value = seekable;
        }
      });
    } catch (e) {
      _diag(DiagCategory.playback, 'player: seekable observation failed: $e');
    }
  }

  Future<void> _observeCacheDuration() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.observeProperty('demuxer-cache-duration', (value) async {
        final parsed = double.tryParse(value);
        if (parsed == null || parsed.isNaN || parsed.isInfinite) return;
        final clamped = math.max(0.0, parsed);
        final prevPreSec = _effectivePreBufferSeconds;
        final prevFloor = _bufferedAheadSeconds.floor();
        _bufferedAheadSeconds = clamped;
        final waitingForInitial = _isPreBuffering;
        if (mounted &&
            ((waitingForInitial && _effectivePreBufferSeconds != prevPreSec) ||
                (_seekHudVisible && clamped.floor() != prevFloor) ||
                (_osdOpen && _syncDisplayedBufferBadge()))) {
          setState(() {});
        }
      });
    } catch (e) {
      _diag(
        DiagCategory.playback,
        'player: demuxer-cache-duration observation failed: $e',
      );
    }
  }

  Future<void> _loadLiveGuideEvents({bool force = false}) async {
    if (!widget.live || _liveGuideLoading) return;
    final bandLoader = widget.loadLiveBandGuideEvents;
    final singleLoader = widget.loadLiveGuideEvents;
    if (bandLoader == null && singleLoader == null) return;
    final now = _now();
    if (!force &&
        _lastLiveGuideAttemptAt != null &&
        now.difference(_lastLiveGuideAttemptAt!) <
            const Duration(seconds: 30)) {
      return;
    }
    _liveGuideLoading = true;
    _lastLiveGuideAttemptAt = now;
    try {
      if (bandLoader != null) {
        final map = await bandLoader();
        if (mounted && map.isNotEmpty) {
          final active = _activeLiveChannel;
          setState(() {
            final nextBand = <String, List<EpgEvent>>{
              for (final entry in _liveBandGuideEvents.entries)
                entry.key: List<EpgEvent>.of(entry.value),
            };
            for (final entry in map.entries) {
              nextBand[entry.key] = mergeLiveProgramEventLists(
                List<EpgEvent>.of(entry.value),
                nextBand[entry.key] ?? const [],
              );
            }
            _liveBandGuideEvents = nextBand;
            if (active != null) {
              final activeEvents = nextBand[liveServiceKey(active)];
              if (activeEvents != null && activeEvents.isNotEmpty) {
                _liveGuideEvents = mergeLiveProgramEventLists(
                  activeEvents,
                  _liveGuideEvents,
                );
              }
            }
          });
        }
      }
      if (singleLoader != null &&
          (_liveGuideEvents.isEmpty || (force && bandLoader == null))) {
        final events = await singleLoader();
        if (mounted && events.isNotEmpty) {
          final active = _activeLiveChannel;
          setState(() {
            final mergedSingle = mergeLiveProgramEventLists(
              List<EpgEvent>.of(events),
              _liveGuideEvents,
            );
            _liveGuideEvents = mergedSingle;
            if (active != null) {
              final key = liveServiceKey(active);
              _liveBandGuideEvents = {
                ..._liveBandGuideEvents,
                key: mergeLiveProgramEventLists(
                  mergedSingle,
                  _liveBandGuideEvents[key] ?? const [],
                ),
              };
            }
          });
        }
      }
    } catch (_) {
    } finally {
      _liveGuideLoading = false;
    }
  }

  Future<void> _loadLiveChannelMetadata() async {
    final loader = widget.loadLiveChannelMetadata;
    if (!widget.live || loader == null || _liveChannelMetaLoading) return;
    _liveChannelMetaLoading = true;
    try {
      final loaded = await loader();
      if (!mounted) return;
      if (loaded.numbers.isNotEmpty || loaded.logos.isNotEmpty) {
        setState(() {
          if (loaded.numbers.isNotEmpty) {
            _liveChannelNumbers = {
              ..._liveChannelNumbers,
              ...loaded.numbers,
            };
          }
          if (loaded.logos.isNotEmpty) {
            _liveChannelLogos = {
              ..._liveChannelLogos,
              ...loaded.logos,
            };
          }
        });
      }
    } catch (_) {
    } finally {
      _liveChannelMetaLoading = false;
    }
  }

  Future<void> _refreshLiveChannelSnapshots({bool force = false}) async {
    final refresher = widget.onRefreshLiveChannels;
    if (!widget.live || refresher == null || _liveChannelsRefreshing) return;
    final now = _now();
    if (!force &&
        _lastLiveChannelsRefreshAt != null &&
        now.difference(_lastLiveChannelsRefreshAt!) <
            const Duration(seconds: 20)) {
      return;
    }
    _liveChannelsRefreshing = true;
    _lastLiveChannelsRefreshAt = now;
    try {
      final refreshed = await refresher();
      if (!mounted || refreshed.isEmpty) return;
      final cur = _activeLiveChannel;
      final curKey = cur != null ? liveServiceKey(cur) : null;
      final nextIdx = cur == null
          ? -1
          : refreshed.indexWhere(
              (e) =>
                  liveServiceKey(e.channel) == curKey || e.channel.id == cur.id,
            );
      setState(() {
        _liveSwitchChannels = refreshed;
        if (nextIdx >= 0 && cur != null) {
          _currentLiveSwitchIndex = nextIdx;
          final entry = refreshed[nextIdx];
          var matched = entry.channel;
          for (final c in entry.candidates) {
            if (c.channel.id == cur.id) {
              matched = c.channel;
              break;
            }
          }
          _currentLiveChannel = matched;
          _recordLiveChannelProgramSnapshot(matched);
        }
      });
    } catch (_) {
    } finally {
      _liveChannelsRefreshing = false;
    }
  }

  /// Loads the recording's chapter points once (plan
  /// 112). Runs beside the open, not before it: playback
  /// starts without waiting, and the chapter controls
  /// join the transport rows when the points land. Any
  /// failure — including a synchronous throw from the
  /// loader resolving the unit's services through the
  /// caller's ref — is logged and dropped.
  Future<void> _loadChapters() async {
    final loader = widget.loadChapters;
    if (loader == null || widget.live) return;
    try {
      final chapters = await loader();
      _diag(
        DiagCategory.playback,
        'player: chapters: ${chapters.length} points loaded (plan 112)',
      );
      if (mounted && chapters.isNotEmpty) {
        setState(() => _chapters = chapters);
      }
    } catch (e) {
      _diag(DiagCategory.playback, 'player: chapter load failed: $e');
    }
  }

  /// Seeks to the next or previous chapter point (plan
  /// 112), chosen from the player's current position by
  /// player_chapter_policy. Reached only through the
  /// chapter buttons, which exist only when the title
  /// has points and follow the same seekable signal as
  /// the skip buttons; a side with no point is a no-op.
  Future<void> _seekToChapter({required bool forward}) async {
    final position = _player.state.position;
    final target = forward
        ? nextChapterTarget(chapters: _chapters, position: position)
        : previousChapterTarget(chapters: _chapters, position: position);
    if (target == null) {
      _diag(
        DiagCategory.playback,
        'player: chapter seek ${forward ? 'next' : 'previous'}: '
        'no point from ${position.inSeconds}s (plan 112)',
      );
      return;
    }
    _diag(
      DiagCategory.playback,
      'player: chapter seek ${forward ? 'next' : 'previous'} '
      'to ${target.inSeconds}s (plan 112)',
    );
    _committedSeekTarget = target;
    _committedSeekHoldTimer?.cancel();
    _committedSeekHoldTimer = Timer(const Duration(milliseconds: 700), () {
      _committedSeekTarget = null;
      if (_seekHudVisible && mounted) setState(() {});
    });
    _showSeekHud(
      forward ? Icons.fast_forward : Icons.fast_rewind,
      forward ? '次チャプター' : '前チャプター',
    );
    _clearDisplayedSubtitles();
    _resetSubtitleTrackTracking();
    try {
      await _player.seek(target);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: chapter seek failed: $e');
    }
  }

  Future<void> _kickLegacyMpvAfterInit() async {
    try {
      final handle = await _player.handle;
      if (!mounted) return;
      final kicked = kickMpvEventLoop(handle);
      _diag(
        DiagCategory.playback,
        'player: legacy mpv wakeup kick ok=$kicked (sdk=$_androidSdkInt)',
      );
    } catch (e) {
      _diag(DiagCategory.playback, 'player: legacy mpv wakeup kick failed: $e');
    }
  }

  Future<void> _logDecodeStatus() async {
    final platform = _player.platform;
    if (platform is! NativePlayer || !mounted) return;
    Future<String> safeProp(String key) async {
      try {
        final v = (await platform.getProperty(key)).trim();
        return v.isEmpty ? '(empty)' : v;
      } catch (_) {
        return '(err)';
      }
    }

    final hwdecCurrent = await safeProp('hwdec-current');
    if (!mounted) return;
    final videoCodec = await safeProp('video-codec');
    if (!mounted) return;
    final voConfigured = await safeProp('vo-configured');
    if (!mounted) return;
    _diag(
      DiagCategory.playback,
      'player: decode status: mode=${_hwdecMode.name} '
      'hwdec-current=$hwdecCurrent codec=$videoCodec vo=$voConfigured',
    );
  }

  Future<void> _open() async {
    _openStartedAt = Stopwatch()..start();
    _diag(DiagCategory.playback, 'player: opening ${widget.session.mediaUri}');
    try {
      final bufferSeconds = !widget.live
          ? ref.read(recordedBufferSecondsProvider)
          : ref.read(liveBufferSecondsProvider);
      final cacheDir = ref.read(mpvCacheDirectoryProvider);
      final availableDiskBytes =
          ((widget.live || bufferSeconds >= 60) && Platform.isAndroid)
          ? await _fireTvHelper.getCacheAvailableBytes()
          : null;
      final plan = computeMpvBufferPlan(
        live: widget.live,
        bufferSeconds: bufferSeconds,
        isAndroid: Platform.isAndroid,
        availableDiskBytes: availableDiskBytes,
        cacheDirPath: cacheDir?.path,
        liveUseMobile: widget.liveUseMobile,
      );
      if (!mounted) return;
      _logPlaybackTrace(
        'open live=${widget.live} mobile=${widget.liveUseMobile} '
        'bufSec=$bufferSeconds disk=${plan.useDiskCache} '
        'hwdec=${_hwdecMode.name} sdk=$_androidSdkInt legacySync=$_useLegacySyncMpvInit',
      );
      _startStartupTraceTimer();
      _bufferPlan = plan;
      _initialPlaybackStarted = false;
      _positionAtFirstFrame = null;
      _lastObservedServedBytes = 0;
      _lastLiveTransferTickAt = null;
      _liveTransferAccumulatedSeconds = 0.0;
      _bufferingPercentage = 0.0;
      _bufferedAheadSeconds = 0.0;
      _bufferEndPosition = Duration.zero;
      _initialBufferPosition = null;
      _liveCacheStartSec = null;
      _liveCacheEndSec = null;
      _liveCacheLiveEdgeSec = null;
      _liveTimePosSec = null;
      _liveStreamEpoch = null;
      _liveMaxAdvancingCacheEndSec = null;
      _livePendingSeekBaseSec = null;
      _livePendingSeekDeltaSec = 0.0;
      _liveSeekDebounceTimer?.cancel();
      _liveCommittedSeekSec = null;
      _liveCommittedSeekHoldTimer?.cancel();
      _usedDiskCacheDir = plan.useDiskCache ? cacheDir : null;
      _watchdog?.cancel();
      _watchdog = Timer(
        Duration(seconds: plan.startTimeoutSeconds),
        _onStartTimeout,
      );

      final platform = _player.platform;
      _decodeStatusLogged = false;
      if (platform is NativePlayer) {
        _diag(
          DiagCategory.playback,
          'player: awaiting mpv init (sdk=$_androidSdkInt, '
          'legacySync=$_useLegacySyncMpvInit, hwdec=${_hwdecMode.name})',
        );
        final initWatch = Stopwatch()..start();
        await platform.setProperty(
          'network-timeout',
          '${plan.networkTimeoutSeconds}',
        );
        _diag(
          DiagCategory.playback,
          'player: mpv init ready in ${initWatch.elapsedMilliseconds} ms',
        );
        _logPlaybackTrace(
          'mpv init ready in ${initWatch.elapsedMilliseconds}ms',
        );
        if (_useLegacySyncMpvInit) {
          try {
            final handle = await _player.handle;
            final kicked = kickMpvEventLoop(handle);
            _diag(
              DiagCategory.playback,
              'player: legacy pre-open wakeup kick=$kicked',
            );
          } catch (e) {
            _diag(
              DiagCategory.playback,
              'player: legacy pre-open wakeup kick failed: $e',
            );
          }
        }
        if (_hwdecMode == VideoHwdecMode.mpeg2Software) {
          await platform.setProperty('hwdec-codecs', mpeg2SoftwareHwdecCodecs);
          _diag(
            DiagCategory.playback,
            'player: hwdec-codecs=$mpeg2SoftwareHwdecCodecs',
          );
        } else if (_hwdecMode == VideoHwdecMode.software) {
          await platform.setProperty('hwdec', 'no');
          _diag(DiagCategory.playback, 'player: hwdec=no (software)');
        }
        await platform.setProperty('sid', _subtitlesOn ? 'auto' : 'no');
        await platform.setProperty('sub-ass', 'yes');
        await platform.setProperty('sub-visibility', 'no');
        await platform.setProperty('sub-fix-timing', 'no');
        await platform.setProperty('sub-clear-on-seek', 'yes');
        if (widget.live) {
          final probeSize = liveDemuxerProbeSizeBytes(
            useMobile: widget.liveUseMobile,
          );
          await platform.setProperty(
            'demuxer-lavf-analyzeduration',
            '$liveDemuxerAnalyzeDurationSeconds',
          );
          await platform.setProperty('demuxer-lavf-probesize', '$probeSize');
        }
        await platform.setProperty('cache', plan.useCache ? 'yes' : 'no');
        if (plan.useCache) {
          await platform.setProperty(
            'demuxer-max-bytes',
            '${plan.demuxerMaxBytes}',
          );
          await platform.setProperty(
            'demuxer-max-back-bytes',
            '${plan.demuxerMaxBackBytes}',
          );
          await platform.setProperty(
            'demuxer-readahead-secs',
            '${plan.readaheadSeconds}',
          );
          await platform.setProperty(
            'cache-pause',
            plan.cachePause ? 'yes' : 'no',
          );
          await platform.setProperty(
            'cache-pause-initial',
            plan.cachePauseInitial ? 'yes' : 'no',
          );
          if (plan.cachePauseWaitSeconds > 0) {
            await platform.setProperty(
              'cache-pause-wait',
              '${plan.cachePauseWaitSeconds}',
            );
          }
          if (widget.live) {
            await platform.setProperty('force-seekable', 'yes');
            await platform.setProperty('demuxer-seekable-cache', 'yes');
          }
          if (plan.useDiskCache && plan.cacheDirPath != null) {
            await platform.setProperty('cache-on-disk', 'yes');
            await platform.setProperty('demuxer-cache-dir', plan.cacheDirPath!);
          } else {
            await platform.setProperty('cache-on-disk', 'no');
          }
        }
        _diag(
          DiagCategory.playback,
          'player: mpv buffer plan: target=${plan.configuredSeconds}s '
          'cache=${plan.useCache} disk=${plan.useDiskCache} '
          'seekableCache=${widget.live} '
          'maxBytes=${plan.demuxerMaxBytes} back=${plan.demuxerMaxBackBytes} '
          'wait=${plan.cachePauseWaitSeconds}s netTimeout=${plan.networkTimeoutSeconds}s',
        );
      }
      if (mounted) {
        setState(() {});
        if (_shouldPollLiveBuffering) {
          _startPreBufferPoller();
        }
      }
      final start =
          (!widget.live &&
              widget.initialStart != null &&
              widget.initialStart! > Duration.zero)
          ? widget.initialStart
          : null;
      if (start != null) {
        _diag(
          DiagCategory.playback,
          'player: opening at the resume position ${start.inSeconds}s '
          '(plan 86)',
        );
      }
      await _player.setVolume(100.0);
      await _player.open(
        Media(widget.session.mediaUri.toString(), start: start),
      );
      await _player.setVolume(100.0);
      _diag(DiagCategory.playback, 'player: open completed');
      _logPlaybackTrace(
        'player.open completed at ${_openStartedAt?.elapsedMilliseconds ?? 0}ms',
      );
      await _applySubtitleSelection();
      if (_subtitlesOn && mounted) {
        _startSubtitleSyncTimer();
      }
    } catch (e) {
      _diag(DiagCategory.playback, 'player: open failed: $e');
      _logPlaybackTrace('player.open caught: $e');
      if (!playerErrorIsFatal('$e', live: widget.live)) {
        // Same seek complaint as the error-stream path, thrown
        // through open() instead (plan 43): not a failed start.
        _diag(
          DiagCategory.playback,
          'player: ignoring the seek complaint for live viewing',
        );
        return;
      }
      _watchdog?.cancel();
      _setStartError('$e');
    }
  }

  /// The position leaving this screen reports to the unit,
  /// or null when nothing is to be reported (plan 102; the
  /// terms are player_resume_policy's). Decided from this
  /// state's own fields — deliberately nothing through ref:
  /// dispose runs while the widget is deactivating, where
  /// Riverpod 3 forbids ref (plan 104).
  Duration? _resumePositionToReport() {
    if (_suppressResumeReportOnDispose || widget.onResumePosition == null) {
      return null;
    }
    return resumePositionToReport(
      started: _playing,
      completed: _completed,
      position: _lastPosition,
    );
  }

  /// Sends the resume report (plan 102) as the last teardown
  /// step: the player's stop is already under way, and
  /// nothing about leaving waits on the report landing. The
  /// sink invocation sits inside the try because the sink
  /// resolves the unit's services through the caller's ref
  /// before its future exists — a synchronous throw there is
  /// a failed report, not a failed teardown (plan 104).
  void _reportResumePosition(Duration position) {
    final sink = widget.onResumePosition;
    if (sink == null) return;
    _diag(
      DiagCategory.playback,
      'player: reporting the resume position '
      '${position.inSeconds}s to the unit (plan 102)',
    );
    try {
      unawaited(
        sink(position).then(
          (_) {},
          onError: (Object e) {
            _diag(
              DiagCategory.playback,
              'player: resume position report failed: $e',
            );
          },
        ),
      );
    } catch (e) {
      _diag(DiagCategory.playback, 'player: resume position report failed: $e');
    }
  }

  /// Stops the player and then disposes it (plan 104): the
  /// explicit stop silences mpv first, and the dispose runs
  /// even when the stop fails — media_kit's own dispose also
  /// stops internally, but leaving must not depend on a
  /// single call landing.
  Future<void> _stopAndDisposePlayer() async {
    try {
      await _player.stop();
    } catch (e) {
      _diag(DiagCategory.playback, 'player: stop on leaving failed: $e');
    }
    try {
      await _player.dispose();
    } catch (e) {
      _diag(DiagCategory.playback, 'player: dispose on leaving failed: $e');
    }
    final cacheDir = _usedDiskCacheDir;
    if (cacheDir != null) {
      try {
        if (await cacheDir.exists()) {
          await for (final entry in cacheDir.list()) {
            await entry.delete(recursive: true);
          }
        }
      } catch (_) {}
    }
  }

  /// Stops the playback session (plan 104): closes the
  /// loopback proxy and the DTCP session behind it. A
  /// failure is logged inside and dropped; the session's
  /// stop can never hold up the rest of the teardown.
  Future<void> _stopSession() async {
    try {
      await widget.session.stop();
    } catch (e) {
      _diag(
        DiagCategory.playback,
        'player: session stop on leaving failed: $e',
      );
    }
  }

  @override
  void dispose() {
    _logPlaybackTrace('dispose ${_buildCompactDiagnosticsSummary()}');
    // What leaving reports to the unit is decided first,
    // from plain fields, before anything is torn down
    // (plan 104).
    final resumePosition = _resumePositionToReport();
    // Every step runs unconditionally (plan 104; see
    // player_teardown_policy): a failure in one is logged
    // and dropped, so the rest — above all the player's
    // stop — always run, whichever exit path got here.
    runTeardownSteps(
      [
        (name: 'watchdog', run: () => _watchdog?.cancel()),
        (name: 'startup trace timer', run: () => _stopStartupTraceTimer()),
        (name: 'stall timer', run: () => _stallTimer?.cancel()),
        (name: 'auto resume timer', run: () => _autoResumeTimer?.cancel()),
        (name: 'resume watchdog', run: () => _resumeWatchdogTimer?.cancel()),
        (name: 'pre-buffer poller', run: () => _preBufferPollTimer?.cancel()),
        (
          name: 'recording status timer',
          run: () => _recordingStatusTimer?.cancel(),
        ),
        (name: 'corner notice timer', run: () => _cornerNoticeTimer?.cancel()),
        (
          name: 'custom corner notice timer',
          run: () => _customCornerNoticeTimer?.cancel(),
        ),
        (
          name: 'channel preview timer',
          run: () => _channelPreviewTimer?.cancel(),
        ),
        (
          name: 'live conflict poller',
          run: () => _liveConflictPollTimer?.cancel(),
        ),
        (
          name: 'live catch-up monitor',
          run: () => _liveCatchUpTimer?.cancel(),
        ),
        (
          name: 'subtitle sync timer',
          run: () => _stopSubtitleSyncTimer(),
        ),
        (name: 'osd timer', run: () => _osdTimer?.cancel()),
        (name: 'osd clock timer', run: () => _osdClockTimer?.cancel()),
        (name: 'hud timer', run: () => _hudTimer?.cancel()),
        (name: 'seek hud timer', run: () => _seekHudTimer?.cancel()),
        (name: 'seek debounce timer', run: () => _seekDebounceTimer?.cancel()),
        (
          name: 'seek hold timer',
          run: () => _committedSeekHoldTimer?.cancel(),
        ),
        (
          name: 'live seek debounce timer',
          run: () => _liveSeekDebounceTimer?.cancel(),
        ),
        (
          name: 'live seek hold timer',
          run: () => _liveCommittedSeekHoldTimer?.cancel(),
        ),
        (
          name: 'focus nodes',
          run: () {
            _rootFocusNode.dispose();
            _osdFocusScopeNode.dispose();
            _osdFirstFocusNode.dispose();
            _osdDetailButtonFocusNode.dispose();
            _detailFocusNode.dispose();
            _detailScrollController.dispose();
            _resumeButtonFocusNode.dispose();
            _closeBannerFocusNode.dispose();
            _errorBackFocusNode.dispose();
            _osdFadeController.dispose();
          },
        ),
        (
          name: 'system ui restore',
          run: () => unawaited(
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
          ),
        ),
        (name: 'wakelock', run: () => _wakelockSession.release()),
        (
          name: 'subscriptions',
          run: () {
            for (final subscription in _subscriptions) {
              subscription.cancel();
            }
          },
        ),
        (
          name: 'video rect listener',
          run: () => _videoController.rect.removeListener(_onVideoRectChanged),
        ),
        (name: 'player', run: () => unawaited(_stopAndDisposePlayer())),
        (name: 'session', run: () => unawaited(_stopSession())),
        if (resumePosition != null)
          (
            name: 'resume report',
            run: () => _reportResumePosition(resumePosition),
          ),
        (
          name: 'live finish callback',
          run: () {
            if (widget.live && !_replacedByNextPlayer) {
              widget.onLivePlaybackFinished?.call(_activeLiveChannel);
            }
          },
        ),
      ],
      onFailure: (name, error) {
        _diag(
          DiagCategory.playback,
          'player: leaving: the $name step failed: $error',
        );
      },
    );
    super.dispose();
  }

  String _formatClock(Duration d) {
    final total = d.isNegative ? 0 : d.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }

  void _showHudMessage(IconData icon, String text) {
    _hudTimer?.cancel();
    setState(() {
      _hudIcon = icon;
      _hudText = text;
    });
    _hudTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _hudIcon = null;
          _hudText = null;
        });
      }
    });
  }

  bool get _hasProgramDetail => widget.live
      ? (_activeLiveChannel != null ||
            (widget.programDetailBody?.trim().isNotEmpty ?? false))
      : (widget.programDetailBody?.trim().isNotEmpty ?? false);

  ResolvedProgramDetail _resolveLiveDetailSnapshot(
    LiveChannel ch,
    DateTime now,
  ) {
    final isInitialFresh =
        identical(ch, widget.currentLiveChannel) &&
        (ch.programEnd == null || ch.programEnd!.isAfter(now));
    return resolveLiveProgramDetail(
      channel: ch,
      guideEvents: _guideEventsForChannel(ch),
      now: now,
      fallbackTitle: widget.programDetailTitle ?? widget.title,
      fallbackMeta: isInitialFresh ? widget.programDetailMeta : null,
      fallbackBody: isInitialFresh ? widget.programDetailBody : null,
    );
  }

  void _openDetail() {
    if (!_hasProgramDetail) return;
    _osdTimer?.cancel();
    if (!widget.live) {
      setState(() => _detailOpen = true);
    } else {
      final reqSeq = ++_liveDetailRequestSeq;
      final ch = _activeLiveChannel;
      if (ch == null) {
        setState(() {
          _detailOpen = true;
          _openedLiveDetail = ResolvedProgramDetail(
            title: widget.programDetailTitle ?? widget.title,
            meta: widget.programDetailMeta,
            body: widget.programDetailBody,
          );
          _liveDetailLoading = false;
        });
      } else {
        final playbackNow = _effectiveLivePlaybackClock(_now());
        final guideEvents = _guideEventsForChannel(ch);
        final info = resolveLiveOsdProgramInfo(
          channel: ch,
          guideEvents: guideEvents,
          now: playbackNow,
        );
        final detail = _resolveLiveDetailSnapshot(ch, playbackNow);
        final hasRefresher =
            widget.loadLiveBandGuideEvents != null ||
            widget.loadLiveGuideEvents != null ||
            widget.onRefreshLiveChannels != null;
        final isSnapshotExpired =
            ch.programEnd != null && !ch.programEnd!.isAfter(playbackNow);
        final needsFetch =
            hasRefresher &&
            info.currentEvent == null &&
            (isSnapshotExpired || !detail.hasBody);
        final initialOpened = (needsFetch && isSnapshotExpired)
            ? ResolvedProgramDetail(
                title: detail.title,
                meta: detail.meta,
                body: null,
                programEnd: null,
                identityKey: detail.identityKey,
              )
            : detail;
        setState(() {
          _detailOpen = true;
          _openedLiveDetail = initialOpened;
          _liveDetailLoading = needsFetch;
        });
        if (needsFetch) {
          unawaited(_loadLiveDetailOnDemand(reqSeq));
        }
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_detailOpen) return;
      if (_detailScrollController.hasClients) {
        _detailScrollController.jumpTo(0);
      }
      if (_detailFocusNode.canRequestFocus) {
        _detailFocusNode.requestFocus();
      }
    });
  }

  Future<void> _loadLiveDetailOnDemand(int reqSeq) async {
    try {
      if (widget.loadLiveBandGuideEvents != null ||
          widget.loadLiveGuideEvents != null) {
        await _loadLiveGuideEvents(force: true);
      }
      if (!mounted || !_detailOpen || _liveDetailRequestSeq != reqSeq) return;
      final chAfterGuide = _activeLiveChannel;
      var stillMissingEvent = true;
      if (chAfterGuide != null) {
        final playbackNow = _effectiveLivePlaybackClock(_now());
        final infoAfterGuide = resolveLiveOsdProgramInfo(
          channel: chAfterGuide,
          guideEvents: _guideEventsForChannel(chAfterGuide),
          now: playbackNow,
        );
        stillMissingEvent = infoAfterGuide.currentEvent == null;
      }
      if (stillMissingEvent && widget.onRefreshLiveChannels != null) {
        await _refreshLiveChannelSnapshots(force: true);
      }
    } finally {
      if (mounted && _detailOpen && _liveDetailRequestSeq == reqSeq) {
        final ch = _activeLiveChannel;
        final updated = ch != null
            ? _resolveLiveDetailSnapshot(ch, _effectiveLivePlaybackClock(_now()))
            : _openedLiveDetail;
        setState(() {
          _openedLiveDetail = updated;
          _liveDetailLoading = false;
        });
      }
    }
  }

  void _closeDetail({bool fromBackKey = false}) {
    if (fromBackKey) {
      _suppressBackPopUntil = DateTime.now().add(
        const Duration(milliseconds: 450),
      );
    }
    if (!_detailOpen) return;
    _liveDetailRequestSeq++;
    setState(() {
      _detailOpen = false;
      _openedLiveDetail = null;
      _liveDetailLoading = false;
    });
    if (_osdOpen) {
      _resetOsdTimer();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_osdOpen) return;
        if (_osdDetailButtonFocusNode.canRequestFocus) {
          _osdDetailButtonFocusNode.requestFocus();
        } else if (_osdFirstFocusNode.canRequestFocus) {
          _osdFirstFocusNode.requestFocus();
        }
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _rootFocusNode.canRequestFocus) {
          _rootFocusNode.requestFocus();
        }
      });
    }
  }

  void _scrollDetailBy(double delta) {
    if (!_detailScrollController.hasClients) return;
    final pos = _detailScrollController.position;
    final target = (pos.pixels + delta)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();
    if (target == pos.pixels) return;
    unawaited(
      _detailScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
      ),
    );
  }

  bool _syncDisplayedBufferBadge({bool force = false}) {
    final actualSec = math
        .max(_bufferedAheadSeconds, _bufferDeltaSeconds)
        .floor();
    final now = _now();
    if (!force &&
        !shouldRefreshOsdBufferBadge(
          lastUpdatedAt: _lastBufferBadgeUpdatedAt,
          now: now,
          displayedSeconds: _displayedBufferAheadSeconds,
          actualSeconds: actualSec,
        )) {
      return false;
    }
    _displayedBufferAheadSeconds = actualSec;
    _lastBufferBadgeUpdatedAt = now;
    return true;
  }

  void _openOsd() {
    _channelPreviewTimer?.cancel();
    _syncDisplayedBufferBadge(force: true);
    setState(() {
      _channelPreviewDirection = null;
      _osdOpen = true;
    });
    if (widget.live && _activeLiveChannel != null) {
      final cur = _activeLiveChannel!;
      final now = _now();
      final playbackNow = _effectiveLivePlaybackClock(now);
      final info = resolveLiveOsdProgramInfo(
        channel: cur,
        guideEvents: _guideEventsForChannel(cur),
        now: playbackNow,
      );
      if (info.currentEvent == null) {
        unawaited(_loadLiveGuideEvents());
        if (cur.programEnd == null || !cur.programEnd!.isAfter(now)) {
          unawaited(_refreshLiveChannelSnapshots());
        }
      }
    }
    _osdFadeController.forward();
    _osdClockTimer?.cancel();
    _osdClockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_osdOpen) return;
      _syncDisplayedBufferBadge();
      if (shouldPollLiveCacheOnOsdTick(
        live: widget.live,
        osdOpen: _osdOpen,
        switchingChannel: _switchingChannel,
        conflictHandled: _conflictHandled,
        catchUpMonitorActive: _liveCatchUpTimer != null,
        initialPlaybackStarted: _initialPlaybackStarted,
        buffering: _buffering,
      )) {
        unawaited(_pollMpvBufferProperties());
      }
      if (widget.live && _activeLiveChannel != null) {
        final cur = _activeLiveChannel!;
        final now = _now();
        final playbackNow = _effectiveLivePlaybackClock(now);
        final info = resolveLiveOsdProgramInfo(
          channel: cur,
          guideEvents: _guideEventsForChannel(cur),
          now: playbackNow,
        );
        if (_detailOpen &&
            _openedLiveDetail != null &&
            shouldCloseLiveDetailOnBoundary(
              now: playbackNow,
              openedProgramEnd: _openedLiveDetail!.programEnd,
              openedIdentityKey: _openedLiveDetail!.identityKey,
              currentInfo: info,
            )) {
          _closeDetail();
          return;
        }
        if (info.currentEvent == null &&
            (cur.programEnd == null || !cur.programEnd!.isAfter(now))) {
          unawaited(_refreshLiveChannelSnapshots());
        }
      }
      setState(() {});
    });
    unawaited(_pollMpvBufferProperties());
    _resetOsdTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _osdFirstFocusNode.canRequestFocus) {
        _osdFirstFocusNode.requestFocus();
      }
    });
  }

  void _closeOsd({bool fromBackKey = false}) {
    if (fromBackKey) {
      _suppressBackPopUntil = DateTime.now().add(
        const Duration(milliseconds: 450),
      );
    }
    _osdTimer?.cancel();
    _osdClockTimer?.cancel();
    _osdClockTimer = null;
    if (!_osdOpen && !_detailOpen) return;
    _liveDetailRequestSeq++;
    setState(() {
      _osdOpen = false;
      _detailOpen = false;
      _openedLiveDetail = null;
      _liveDetailLoading = false;
    });
    _osdFadeController.reverse();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rootFocusNode.canRequestFocus) {
        _rootFocusNode.requestFocus();
      }
    });
  }

  void _toggleOsd() {
    if (_osdOpen) {
      _closeOsd();
    } else {
      _openOsd();
    }
  }

  void _resetOsdTimer() {
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _osdOpen && !_detailOpen) _closeOsd();
    });
  }

  Duration get _effectiveDuration =>
      _duration > Duration.zero ? _duration : (widget.knownDuration ?? Duration.zero);

  Duration? get _seekHudPositionOverride {
    if (_seekBasePosition != null) {
      return skipSeekTarget(
        position: _seekBasePosition!,
        offset: _pendingSeekOffset,
        duration: _effectiveDuration,
      );
    }
    return _committedSeekTarget;
  }

  String _formatSeekDelta(int totalSec) {
    final sign = totalSec >= 0 ? '+' : '-';
    final absSec = totalSec.abs();
    final min = absSec ~/ 60;
    final sec = absSec % 60;
    if (min > 0 && sec > 0) return '$sign$min分$sec秒';
    if (min > 0) return '$sign$min分';
    return '$sign$absSec秒';
  }

  void _showSeekHud(IconData icon, String actionLabel) {
    _seekHudTimer?.cancel();
    unawaited(_pollMpvBufferProperties());
    setState(() {
      _seekHudVisible = true;
      _seekHudIcon = icon;
      _seekHudActionLabel = actionLabel;
    });
    _seekHudTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _seekHudVisible = false;
          _seekHudIcon = null;
          _seekHudActionLabel = null;
        });
      }
    });
  }

  void _setLivePlaybackPaused(bool paused) {
    if (!widget.live) return;
    if (paused) {
      unawaited(_player.pause());
      _markLivePaused();
      unawaited(_pollMpvBufferProperties());
      _showSeekHud(Icons.pause, '一時停止');
      return;
    }
    unawaited(_resumeLivePlayback());
  }

  Future<void> _resumeLivePlayback() async {
    if (!mounted || !widget.live || _switchingChannel || _conflictHandled) {
      return;
    }
    if (_liveSeekDebounceTimer?.isActive == true ||
        _livePendingSeekDeltaSec != 0.0) {
      _liveSeekDebounceTimer?.cancel();
      await _commitPendingLiveSeek();
      if (!mounted || _switchingChannel || _conflictHandled) return;
    }
    final effectivePos = _liveCommittedSeekSec ?? _liveTimePosSec;
    final atLiveEdge =
        _liveCacheEndSec != null &&
        effectivePos != null &&
        (_liveCacheEndSec! - effectivePos) <= 1.5;
    await _player.play();
    if (!mounted) return;
    if (_liveDelayedByPause && atLiveEdge) {
      await _finishLiveCatchUp(showHud: true);
    } else if (_liveRewoundByUser) {
      _liveAutoCatchUpEnabled = false;
      _liveCatchUpRate = 1.0;
      await _player.setRate(1.0);
      if (mounted) _showSeekHud(Icons.play_arrow, 'プレイバック再生 (等速)');
    } else if (_liveDelayedByPause) {
      _showSeekHud(Icons.play_arrow, '追いかけ再生');
    } else {
      _showHudMessage(Icons.play_arrow, '再生');
    }
  }

  void _togglePlayPauseWithHud() {
    final willPlay = !_playingNow;
    if (widget.live) {
      _setLivePlaybackPaused(!willPlay);
    } else {
      unawaited(_player.playOrPause());
      _showSeekHud(
        willPlay ? Icons.play_arrow : Icons.pause,
        willPlay ? '再生' : '一時停止',
      );
    }
  }

  void _queueLiveRelativeSeek(double deltaSec) {
    if (!widget.live || _switchingChannel || _conflictHandled || _catchingUpLive) {
      return;
    }
    _liveDelayedByPause = true;
    _startLiveCatchUpMonitor();
    final effectiveLiveEdge = _liveCacheLiveEdgeSec ?? _liveCacheEndSec;
    final base =
        _livePendingSeekBaseSec ??
        _liveCommittedSeekSec ??
        _liveTimePosSec ??
        effectiveLiveEdge ??
        (_lastPosition.inMilliseconds / 1000.0);
    final clamped = clampLivePendingSeekDelta(
      basePosSeconds: base,
      desiredDeltaSeconds: _livePendingSeekDeltaSec + deltaSec,
      cacheStartSeconds: _liveCacheStartSec,
      cacheEndSeconds: effectiveLiveEdge,
    );
    if (!clamped.hasCache) {
      _livePendingSeekBaseSec = null;
      _livePendingSeekDeltaSec = 0.0;
      _liveSeekDebounceTimer?.cancel();
      unawaited(_pollMpvBufferProperties());
      _showSeekHud(Icons.info_outline, '戻れるキャッシュ蓄積中');
      return;
    }
    if (deltaSec < 0) {
      _liveRewoundByUser = true;
      _liveAutoCatchUpEnabled = false;
      if (_liveCatchUpRate != 1.0) {
        _liveCatchUpRate = 1.0;
        unawaited(_player.setRate(1.0));
      }
    }
    if (clamped.clampedDelta == 0.0) {
      _livePendingSeekBaseSec = null;
      _livePendingSeekDeltaSec = 0.0;
    } else {
      _livePendingSeekBaseSec = base;
      _livePendingSeekDeltaSec = clamped.clampedDelta;
    }
    if (deltaSec < 0 && clamped.hitStart) {
      final maxBack = effectiveLiveEdge != null
          ? math.max(
              0,
              (effectiveLiveEdge - (base + clamped.clampedDelta)).round(),
            )
          : 0;
      _showSeekHud(
        Icons.first_page,
        'これ以上戻れません (-${_formatOverlaySeconds(maxBack)})',
      );
    } else if (deltaSec > 0 && clamped.hitEnd) {
      _liveRewoundByUser = false;
      _showSeekHud(Icons.live_tv, '現在位置 (LIVE)');
    } else {
      _showSeekHud(
        _livePendingSeekDeltaSec < 0 ? Icons.replay_10 : Icons.forward_10,
        _formatSeekDelta(_livePendingSeekDeltaSec.round()),
      );
    }
    _liveSeekDebounceTimer?.cancel();
    if (_livePendingSeekDeltaSec != 0.0) {
      _liveSeekDebounceTimer = Timer(const Duration(milliseconds: 250), () {
        unawaited(_commitPendingLiveSeek());
      });
    }
  }

  Future<void> _commitPendingLiveSeek() async {
    final base = _livePendingSeekBaseSec;
    final offsetSec = _livePendingSeekDeltaSec;
    _livePendingSeekBaseSec = null;
    _livePendingSeekDeltaSec = 0.0;
    if (!mounted ||
        !widget.live ||
        base == null ||
        offsetSec == 0.0 ||
        _switchingChannel ||
        _conflictHandled) {
      return;
    }
    final platform = _player.platform;
    double? cacheStart = _liveCacheStartSec;
    double? cacheEnd = _liveCacheEndSec;
    double? currentPos = _liveTimePosSec;
    if (platform is NativePlayer) {
      try {
        final props = await Future.wait<String>([
          _safeGetProp(platform, 'demuxer-cache-state'),
          _safeGetProp(platform, 'demuxer-cache-time'),
          _safeGetProp(platform, 'playback-time'),
          _safeGetProp(platform, 'time-pos'),
          _safeGetProp(platform, 'demuxer-cache-duration'),
        ]);
        final playbackTime = double.tryParse(props[2]);
        final timePos = double.tryParse(props[3]);
        final cacheTime = double.tryParse(props[1]);
        final cacheDur = double.tryParse(props[4]);
        final range = parseDemuxerCacheStateRange(
          props[0],
          currentPosSeconds: playbackTime ?? timePos ?? _liveTimePosSec,
        );
        if (range != null) {
          cacheStart = range.earliestStartSeconds ?? range.startSeconds;
          cacheEnd = range.liveEdgeSeconds ?? range.endSeconds;
          currentPos = resolveLiveCacheCoordinatePos(
            playbackTimeSeconds: playbackTime,
            timePosSeconds: timePos,
            cacheStartSeconds: cacheStart,
            cacheEndSeconds: cacheEnd,
            fallbackSeconds: currentPos ?? cacheEnd,
          );
          _liveTimePosSec = currentPos;
        } else {
          if (playbackTime != null && playbackTime.isFinite) {
            currentPos = playbackTime;
          } else if (timePos != null && timePos.isFinite) {
            currentPos = timePos;
          }
          if (currentPos != null) _liveTimePosSec = currentPos;
          if (cacheTime != null &&
              cacheTime.isFinite &&
              cacheDur != null &&
              cacheDur.isFinite) {
            cacheStart ??= math.max(0.0, cacheTime - cacheDur);
            cacheEnd ??= cacheTime;
          }
        }
      } catch (e) {
        _diag(DiagCategory.playback, 'player: live seek probe failed: $e');
      }
    }
    if (!mounted) return;
    if (cacheStart == null || cacheEnd == null || (cacheEnd - cacheStart) < 1.5) {
      _showSeekHud(Icons.info_outline, '戻れるキャッシュ範囲がありません');
      return;
    }
    final resolvedCurrent = currentPos ?? base;
    final anchorPos =
        (base - resolvedCurrent).abs() > 30.0 ? resolvedCurrent : base;
    final res = resolveLiveTimeshiftSeekTarget(
      currentPosSeconds: anchorPos,
      deltaSeconds: offsetSec,
      cacheStartSeconds: cacheStart,
      cacheEndSeconds: cacheEnd,
      startMarginSeconds: 1.0,
      liveEdgeMarginSeconds: 0.5,
    );
    final actualDelta = res.targetSeconds - resolvedCurrent;
    _liveCacheStartSec = cacheStart;
    _liveCacheEndSec = cacheEnd;
    _liveCacheLiveEdgeSec = cacheEnd;
    _updateLiveStreamEpochFromLiveEdge(cacheEnd, _now());
    _liveCommittedSeekSec = res.targetSeconds;
    _liveTimePosSec = res.targetSeconds;
    _liveCommittedSeekHoldTimer?.cancel();
    _liveCommittedSeekHoldTimer = Timer(const Duration(milliseconds: 1500), () {
      _liveCommittedSeekSec = null;
      if ((_seekHudVisible || _osdOpen) && mounted) setState(() {});
    });
    final targetBufferFloor = (_bufferPlan?.configuredSeconds ?? 0).toDouble();
    final rawLag = math.max(0.0, cacheEnd - res.targetSeconds);
    _bufferedAheadSeconds = rawLag;
    _liveEstimatedLagSeconds = math.max(0.0, rawLag - targetBufferFloor);
    _diag(
      DiagCategory.playback,
      'player: live timeshift seek before=${resolvedCurrent.toStringAsFixed(2)} '
      'offset=${offsetSec.toStringAsFixed(1)} delta=${actualDelta.toStringAsFixed(2)} '
      'target=${res.targetSeconds.toStringAsFixed(2)} '
      'range=[${cacheStart.toStringAsFixed(1)}..${cacheEnd.toStringAsFixed(1)}]',
    );
    _clearDisplayedSubtitles();
    if (actualDelta.abs() >= 0.2) {
      try {
        if (platform is NativePlayer) {
          await platform.command([
            'seek',
            actualDelta.toStringAsFixed(3),
            'relative+keyframes',
          ]);
          final afterProps = await Future.wait<String>([
            _safeGetProp(platform, 'playback-time'),
            _safeGetProp(platform, 'time-pos'),
          ]);
          _diag(
            DiagCategory.playback,
            'player: live timeshift seek settled '
            'pb=${afterProps[0]} pos=${afterProps[1]}',
          );
        } else {
          await _player.seek(
            Duration(
              milliseconds: math.max(0, (res.targetSeconds * 1000).round()),
            ),
          );
        }
      } catch (e) {
        _diag(DiagCategory.playback, 'player: live timeshift seek failed: $e');
        return;
      }
    }
    if (!mounted) return;
    if (res.reachedLiveEdge && _playingNow) {
      await _finishLiveCatchUp(showHud: true);
    } else if (res.hitStart) {
      _showSeekHud(
        Icons.first_page,
        'これ以上戻れません (-${_formatOverlaySeconds((cacheEnd - res.targetSeconds).round())})',
      );
    } else if (res.reachedLiveEdge && !_playingNow) {
      _liveRewoundByUser = false;
      _showSeekHud(Icons.live_tv, '現在位置（再開で通常視聴）');
    } else {
      setState(() {});
    }
  }

  void _queueRelativeSeek(Duration delta) {
    if (widget.live) return;
    _seekBasePosition ??= _committedSeekTarget ?? _player.state.position;
    _pendingSeekOffset += delta;
    _showSeekHud(
      _pendingSeekOffset.isNegative ? Icons.replay_10 : Icons.forward_10,
      _formatSeekDelta(_pendingSeekOffset.inSeconds),
    );
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_commitPendingSeek());
    });
  }

  Future<void> _commitPendingSeek() async {
    final base = _seekBasePosition;
    final offset = _pendingSeekOffset;
    _seekBasePosition = null;
    _pendingSeekOffset = Duration.zero;
    if (base == null || offset == Duration.zero) return;
    final target = skipSeekTarget(
      position: base,
      offset: offset,
      duration: _effectiveDuration,
    );
    _committedSeekTarget = target;
    _committedSeekHoldTimer?.cancel();
    _committedSeekHoldTimer = Timer(const Duration(milliseconds: 700), () {
      _committedSeekTarget = null;
      if (_seekHudVisible && mounted) setState(() {});
    });
    _diag(
      DiagCategory.playback,
      'player: dpad seek by ${offset.inSeconds}s to ${target.inSeconds}s',
    );
    _clearDisplayedSubtitles();
    _resetSubtitleTrackTracking();
    try {
      await _player.seek(target);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: dpad seek failed: $e');
    }
  }

  bool get _canSwitchLiveChannel =>
      widget.live &&
      widget.onSwitchLiveChannel != null &&
      _liveSwitchChannels.length > 1 &&
      _currentLiveSwitchIndex >= 0 &&
      _currentLiveSwitchIndex < _liveSwitchChannels.length;

  LiveChannelSwitchEntry? _previewTargetFor(ChannelSwitchDirection? dir) {
    if (dir == null || !_canSwitchLiveChannel) return null;
    final idx = adjacentLiveChannelIndex(
      currentIndex: _currentLiveSwitchIndex,
      count: _liveSwitchChannels.length,
      direction: dir,
    );
    if (idx < 0 || idx >= _liveSwitchChannels.length) return null;
    return _liveSwitchChannels[idx];
  }

  void _showChannelPreview(ChannelSwitchDirection direction) {
    if (!_canSwitchLiveChannel) {
      _showHudMessage(Icons.live_tv, '切り替え可能なチャンネルがありません');
      return;
    }
    _channelPreviewTimer?.cancel();
    setState(() => _channelPreviewDirection = direction);
    final now = _now();
    final prevEntry = _previewTargetFor(ChannelSwitchDirection.previous);
    final nextEntry = _previewTargetFor(ChannelSwitchDirection.next);
    final prevResolved = prevEntry == null
        ? null
        : resolveLiveSwitchEntryProgram(
            entry: prevEntry,
            guideEvents: _guideEventsForChannel(prevEntry.channel),
            now: now,
          );
    final nextResolved = nextEntry == null
        ? null
        : resolveLiveSwitchEntryProgram(
            entry: nextEntry,
            guideEvents: _guideEventsForChannel(nextEntry.channel),
            now: now,
          );
    if (_liveBandGuideEvents.isEmpty && widget.loadLiveBandGuideEvents != null) {
      unawaited(_loadLiveGuideEvents());
    }
    if ((prevResolved?.isStale ?? false) || (nextResolved?.isStale ?? false)) {
      unawaited(_refreshLiveChannelSnapshots());
    }
    _channelPreviewTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _channelPreviewDirection != null) {
        setState(() => _channelPreviewDirection = null);
      }
    });
  }

  void _dismissChannelPreview({bool fromBackKey = false}) {
    if (fromBackKey) {
      _suppressBackPopUntil = DateTime.now().add(
        const Duration(milliseconds: 300),
      );
    }
    _channelPreviewTimer?.cancel();
    if (_channelPreviewDirection == null) return;
    setState(() => _channelPreviewDirection = null);
  }

  Future<void> _stopPlaybackForReplacement() async {
    _autoResumeDisabled = true;
    _stopLiveCatchUpMonitor();
    _stopLiveConflictPoller();
    _stopPreBufferPoller();
    _stopStartupTraceTimer();
    _watchdog?.cancel();
    _stallTimer?.cancel();
    _autoResumeTimer?.cancel();
    _resumeWatchdogTimer?.cancel();
    _clearDisplayedSubtitles(notify: false, stopTimer: true);
    _resetSubtitleTrackTracking();
    _recordingStatusTimer?.cancel();
    _cornerNoticeTimer?.cancel();
    _customCornerNoticeTimer?.cancel();
    _channelPreviewTimer?.cancel();
    _osdTimer?.cancel();
    _osdClockTimer?.cancel();
    _osdClockTimer = null;
    _hudTimer?.cancel();
    _seekHudTimer?.cancel();
    _seekDebounceTimer?.cancel();
    _committedSeekHoldTimer?.cancel();
    _liveSeekDebounceTimer?.cancel();
    _liveCommittedSeekHoldTimer?.cancel();
    _livePendingSeekBaseSec = null;
    _livePendingSeekDeltaSec = 0.0;
    _liveCommittedSeekSec = null;

    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();

    if (mounted) {
      setState(() {
        _switchingChannel = true;
        _error = null;
        _interrupted = false;
        _interruptDetail = null;
        _autoResumeCountdown = 0;
        _osdOpen = false;
        _osdFadeController.value = 0.0;
        _detailOpen = false;
        _openedLiveDetail = null;
        _liveDetailLoading = false;
        _liveDetailRequestSeq++;
        _hudText = null;
        _cornerRecordingNotice = null;
        _customCornerNoticeText = null;
      });
    }

    await _player.stop().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    ).catchError((_) {});
    await widget.session.stop().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    ).catchError((_) {});
  }

  Future<void> _pushReplacementPlayer(Widget nextPlayer) async {
    _replacedByNextPlayer = true;
    try {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => nextPlayer),
      );
    } catch (_) {
      _replacedByNextPlayer = false;
      rethrow;
    }
  }

  Future<void> _executeLiveChannelSwitch(LiveChannelSwitchEntry target) async {
    final switcher = widget.onSwitchLiveChannel;
    if (switcher == null || !mounted || _switchingChannel || _conflictHandled) {
      return;
    }
    _dismissChannelPreview();
    _switchingChannelLabel = target.displayChannelName;

    var sessionStopped = false;
    Future<void> stopCurrentSession() async {
      if (sessionStopped) return;
      sessionStopped = true;
      await _stopPlaybackForReplacement();
    }

    try {
      final nextPlayer = await switcher(context, target, stopCurrentSession);
      if (!mounted) return;
      if (nextPlayer == null) {
        _switchingChannelLabel = null;
        return;
      }
      await _pushReplacementPlayer(nextPlayer);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: live channel switch failed: $e');
      if (!mounted) return;
      if (sessionStopped) {
        setState(() => _switchingChannel = false);
        _setStartError(
          '${target.displayChannelName} への切り替えに失敗しました。',
          allowAfterConflict: true,
        );
      } else {
        _switchingChannelLabel = null;
        _showCustomCornerNotice('チャンネルを切り替えできませんでした');
      }
    }
  }

  Future<void> _executeQualitySwitch() async {
    final switcher = widget.onSwitchQuality;
    if (switcher == null || !mounted || _switchingChannel || _conflictHandled) {
      return;
    }
    _closeOsd();
    final nextUseMobile = !widget.currentUseMobile;
    final resumeFrom = _lastPosition > Duration.zero
        ? _lastPosition
        : (widget.initialStart ?? Duration.zero);
    _switchingChannelLabel = nextUseMobile ? 'モバイル画質' : '元画質';

    var sessionStopped = false;
    Future<void> stopCurrentSession() async {
      if (sessionStopped) return;
      sessionStopped = true;
      _suppressResumeReportOnDispose = true;
      await _stopPlaybackForReplacement();
    }

    try {
      final nextPlayer = await switcher(
        context,
        nextUseMobile,
        resumeFrom,
        stopCurrentSession,
      );
      if (!mounted) return;
      if (nextPlayer == null) {
        if (!sessionStopped) {
          _suppressResumeReportOnDispose = false;
          _switchingChannelLabel = null;
        }
        return;
      }
      await _pushReplacementPlayer(nextPlayer);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: quality switch failed: $e');
      if (!mounted) return;
      if (sessionStopped) {
        setState(() => _switchingChannel = false);
        _setStartError(
          '画質の切り替えに失敗しました。',
          allowAfterConflict: true,
        );
      } else {
        _suppressResumeReportOnDispose = false;
        _switchingChannelLabel = null;
        _showCustomCornerNotice('画質を切り替えできませんでした');
      }
    }
  }

  void _resetLiveCatchUpState({required bool resetPlayerRate}) {
    _stopLiveCatchUpMonitor();
    _liveSeekDebounceTimer?.cancel();
    _liveCommittedSeekHoldTimer?.cancel();
    _livePendingSeekBaseSec = null;
    _livePendingSeekDeltaSec = 0.0;
    _liveCommittedSeekSec = null;
    _livePausedAt = null;
    _liveEstimatedLagSeconds = 0.0;
    _liveDelayedByPause = false;
    _liveAutoCatchUpEnabled = true;
    _liveRewoundByUser = false;
    final prevRate = _liveCatchUpRate;
    _liveCatchUpRate = 1.0;
    _liveMaxAdvancingCacheEndSec = _liveCacheLiveEdgeSec ?? _liveCacheEndSec;
    if (resetPlayerRate && prevRate != 1.0) {
      unawaited(_player.setRate(1.0));
    }
  }

  void _updateLiveStreamEpochFromLiveEdge(double liveEdgeSec, DateTime now) {
    if (!widget.live || !liveEdgeSec.isFinite) return;
    if (_liveStreamEpoch == null) {
      _liveMaxAdvancingCacheEndSec = liveEdgeSec;
      _liveStreamEpoch = now.subtract(
        Duration(milliseconds: (liveEdgeSec * 1000).round()),
      );
      return;
    }
    if (liveEdgeSec >
        (_liveMaxAdvancingCacheEndSec ?? -double.infinity) + 0.5) {
      _liveMaxAdvancingCacheEndSec = liveEdgeSec;
      if (!_liveDelayedByPause) {
        _liveStreamEpoch = now.subtract(
          Duration(milliseconds: (liveEdgeSec * 1000).round()),
        );
      }
    }
  }

  void _markLivePaused({bool notify = true}) {
    if (!widget.live) return;
    final wasDelayed = _liveDelayedByPause;
    _channelPreviewTimer?.cancel();
    _channelPreviewDirection = null;
    if (_liveStreamEpoch == null) {
      final anchorPos =
          _liveTimePosSec ?? _liveCacheLiveEdgeSec ?? _liveCacheEndSec;
      if (anchorPos != null && anchorPos.isFinite) {
        _liveStreamEpoch = _now().subtract(
          Duration(milliseconds: (anchorPos * 1000).round()),
        );
        _liveMaxAdvancingCacheEndSec ??= anchorPos;
      } else {
        unawaited(_pollMpvBufferProperties());
      }
    }
    _livePausedAt ??= _now();
    _liveDelayedByPause = true;
    if (!wasDelayed) {
      _liveAutoCatchUpEnabled = true;
    }
    _startLiveCatchUpMonitor();
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _startLiveCatchUpMonitor() {
    if (_liveCatchUpTimer != null) return;
    _liveCatchUpTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (!mounted ||
            !widget.live ||
            !_liveDelayedByPause ||
            _switchingChannel ||
            _conflictHandled) {
          _stopLiveCatchUpMonitor();
          return;
        }
        unawaited(_pollMpvBufferProperties());
        if (_playingNow && !_buffering) {
          final reduction = math.max(0.0, (_liveCatchUpRate - 1.0) * 0.5);
          _liveEstimatedLagSeconds = math.max(
            0.0,
            _liveEstimatedLagSeconds - reduction,
          );
          unawaited(_updateLiveCatchUpSpeed(immediate: false));
        }
      },
    );
  }

  void _stopLiveCatchUpMonitor() {
    _liveCatchUpTimer?.cancel();
    _liveCatchUpTimer = null;
  }

  Future<void> _finishLiveCatchUp({required bool showHud}) async {
    _stopLiveCatchUpMonitor();
    _liveSeekDebounceTimer?.cancel();
    _liveCommittedSeekHoldTimer?.cancel();
    _livePendingSeekBaseSec = null;
    _livePendingSeekDeltaSec = 0.0;
    _liveCommittedSeekSec = null;
    _livePausedAt = null;
    _liveEstimatedLagSeconds = 0.0;
    final changed =
        _liveDelayedByPause || _liveCatchUpRate != 1.0 || _liveRewoundByUser;
    _liveDelayedByPause = false;
    _liveAutoCatchUpEnabled = true;
    _liveRewoundByUser = false;
    final prevRate = _liveCatchUpRate;
    _liveCatchUpRate = 1.0;
    _liveMaxAdvancingCacheEndSec = _liveCacheLiveEdgeSec ?? _liveCacheEndSec;
    if (prevRate != 1.0) {
      try {
        await _player.setRate(1.0);
      } catch (e) {
        _diag(DiagCategory.playback, 'player: reset catch-up rate failed: $e');
      }
    }
    if (mounted && changed) {
      setState(() {});
      if (_osdOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _osdOpen && _osdFirstFocusNode.canRequestFocus) {
            _osdFirstFocusNode.requestFocus();
          }
        });
      }
    }
    if (showHud && mounted) {
      _showHudMessage(Icons.live_tv, '現在位置に追いつきました');
    }
  }

  Future<void> _updateLiveCatchUpSpeed({required bool immediate}) async {
    if (!mounted ||
        !widget.live ||
        !_liveDelayedByPause ||
        _switchingChannel ||
        _conflictHandled ||
        _livePendingSeekDeltaSec != 0.0 ||
        _liveCommittedSeekSec != null ||
        !_liveAutoCatchUpEnabled) {
      return;
    }
    final targetBufferFloor = (_bufferPlan?.configuredSeconds ?? 0).toDouble();
    final measuredAhead =
        (_liveCacheEndSec != null && _liveTimePosSec != null)
        ? math.max(
            _bufferedAheadSeconds,
            math.max(0.0, _liveCacheEndSec! - _liveTimePosSec!),
          )
        : _bufferedAheadSeconds;
    final excessBuffered = math.max(
      0.0,
      measuredAhead - targetBufferFloor,
    );
    final effectiveLag = math.max(excessBuffered, _liveEstimatedLagSeconds);
    if (!immediate &&
        _playingNow &&
        !_buffering &&
        excessBuffered <= 1.5 &&
        _liveEstimatedLagSeconds <= 2.0) {
      await _finishLiveCatchUp(showHud: true);
      return;
    }
    if (!_playingNow) return;
    final nextRate = liveCatchUpSpeedForLagSeconds(
      effectiveLag,
      currentRate: immediate ? null : _liveCatchUpRate,
    );
    if (nextRate != _liveCatchUpRate) {
      final wasNormal = _liveCatchUpRate == 1.0;
      _liveCatchUpRate = nextRate;
      if (mounted) setState(() {});
      try {
        await _player.setRate(nextRate);
      } catch (e) {
        _diag(DiagCategory.playback, 'player: live catch-up rate failed: $e');
      }
      if ((immediate || wasNormal) && nextRate > 1.0 && mounted) {
        _showHudMessage(
          Icons.speed,
          '追いかけ再生 (${playbackSpeedLabel(nextRate)})',
        );
      }
    } else if (immediate && nextRate > 1.0 && mounted) {
      _showHudMessage(
        Icons.speed,
        '追いかけ再生 (${playbackSpeedLabel(nextRate)})',
      );
    }
  }

  void _toggleLiveAutoCatchUp() {
    if (!widget.live || !_liveDelayedByPause) return;
    _liveAutoCatchUpEnabled = !_liveAutoCatchUpEnabled;
    _resetOsdTimer();
    if (!_liveAutoCatchUpEnabled) {
      _liveCatchUpRate = 1.0;
      setState(() {});
      unawaited(_player.setRate(1.0));
      _showHudMessage(
        Icons.speed,
        _liveRewoundByUser ? '等速 (1.0x) でプレイバック' : '等速 (1.0x) で追いかけ再生',
      );
    } else {
      _liveRewoundByUser = false;
      setState(() {});
      unawaited(_updateLiveCatchUpSpeed(immediate: true));
      if (!_playingNow) {
        _showHudMessage(Icons.speed, '再開時に倍速で追いつきます');
      }
    }
  }

  Future<void> _catchUpToLiveEdge() async {
    if (!widget.live || !mounted || _catchingUpLive || _switchingChannel) return;
    _catchingUpLive = true;
    _clearDisplayedSubtitles();
    _closeOsd();
    _showHudMessage(Icons.skip_next, '現在位置へ移動しています…');
    try {
      if (_liveCatchUpRate != 1.0) {
        _liveCatchUpRate = 1.0;
        try {
          await _player.setRate(1.0);
        } catch (_) {}
      }
      final plan = _bufferPlan;
      final platform = _player.platform;
      final activePause = _livePausedAt == null
          ? 0.0
          : math.max(
              0.0,
              _now().difference(_livePausedAt!).inMilliseconds / 1000.0,
            );
      final totalLagSec = math.max(
        _liveEstimatedLagSeconds + activePause,
        _bufferedAheadSeconds,
      );
      if (plan != null && plan.useCache && platform is NativePlayer) {
        try {
          final rawDur = await platform.getProperty('demuxer-cache-duration');
          final rawCacheTime = await platform.getProperty('demuxer-cache-time');
          final rawPos = await platform.getProperty('time-pos');
          final cacheDur = double.tryParse(rawDur);
          final cacheTime = double.tryParse(rawCacheTime);
          final timePos = double.tryParse(rawPos);
          final effectiveWindowSeconds = plan.useDiskCache
              ? math.max(plan.configuredSeconds, plan.readaheadSeconds)
              : plan.configuredSeconds;
          if (cacheDur != null &&
              cacheTime != null &&
              timePos != null &&
              canSeekWithinLiveCache(
                useCache: plan.useCache,
                configuredBufferSeconds: effectiveWindowSeconds,
                totalPauseLagSeconds: totalLagSec,
                cacheDurationSeconds: cacheDur,
                cacheTimeSeconds: cacheTime,
                timePosSeconds: timePos,
              )) {
            final targetMs = math.max(0, ((cacheTime - 0.5) * 1000).round());
            await _player.play();
            await _player.seek(Duration(milliseconds: targetMs));
            await _finishLiveCatchUp(showHud: false);
            if (mounted) {
              _showHudMessage(Icons.skip_next, '現在位置へ移動しました');
            }
            return;
          }
        } catch (e) {
          _diag(
            DiagCategory.playback,
            'player: seamless live catch-up unavailable, falling back: $e',
          );
        }
      }

      if (widget.session case final LiveEdgeResettable resettable) {
        _resetSubtitleTrackTracking();
        await resettable.resetToLiveEdge();
      }
      await _finishLiveCatchUp(showHud: false);
      if (!mounted) return;
      setState(() {
        _buffering = true;
        _bufferingPercentage = 0.0;
        _bufferedAheadSeconds = 0.0;
        _bufferEndPosition = Duration.zero;
        _initialBufferPosition = null;
        _liveCacheStartSec = null;
        _liveCacheEndSec = null;
        _liveCacheLiveEdgeSec = null;
        _liveTimePosSec = null;
        _liveStreamEpoch = null;
        _liveMaxAdvancingCacheEndSec = null;
        _livePendingSeekBaseSec = null;
        _livePendingSeekDeltaSec = 0.0;
        _liveCommittedSeekSec = null;
        _positionAtFirstFrame = null;
        _lastObservedServedBytes = 0;
        _lastLiveTransferTickAt = null;
        _liveTransferAccumulatedSeconds = 0.0;
      });
      if (_isPreBuffering) {
        _startPreBufferPoller();
      }
      final uri = widget.session.mediaUri.replace(
        queryParameters: {'live_edge': '${++_liveEdgeSeq}'},
      );
      await _player.open(Media(uri.toString()));
      if (!mounted) return;
      await _player.setVolume(100.0);
      await _player.play();
      await _applySubtitleSelection();
      if (mounted) {
        _showHudMessage(Icons.skip_next, '現在位置へ移動しました');
      }
    } catch (e) {
      _diag(DiagCategory.playback, 'player: live catch-up failed: $e');
      if (mounted) {
        _showCustomCornerNotice('現在位置への移動に失敗しました');
      }
    } finally {
      _catchingUpLive = false;
    }
  }

  void _cyclePlaybackRate() {
    if (!canChangePlaybackSpeed(live: widget.live)) return;
    final idx = playbackSpeeds.indexOf(_playbackRate);
    final next = playbackSpeeds[(idx + 1) % playbackSpeeds.length];
    unawaited(_selectPlaybackRate(next));
    _resetOsdTimer();
  }

  void _cycleAudioTrack() {
    if (!canSwitchAudio(_realAudioTracks.length)) return;
    final next = (_selectedAudioIndex + 1) % _realAudioTracks.length;
    unawaited(_selectAudioTrack(next));
    _resetOsdTimer();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_interrupted) {
      if (event is KeyDownEvent &&
          (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.gameButtonA ||
              key == LogicalKeyboardKey.mediaPlayPause)) {
        if (!_closeBannerFocusNode.hasFocus) {
          unawaited(_resume());
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    if (_detailOpen) {
      if (event is KeyDownEvent &&
          (key == LogicalKeyboardKey.escape ||
              key == LogicalKeyboardKey.goBack)) {
        _closeDetail(fromBackKey: true);
      }
      return KeyEventResult.handled;
    }
    if (_osdOpen) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
        _closeOsd(fromBackKey: true);
        return KeyEventResult.handled;
      }
      _resetOsdTimer();
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        if (_osdFirstFocusNode.canRequestFocus) {
          _osdFirstFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final isRepeat = event is KeyRepeatEvent;
    if (_channelPreviewDirection != null &&
        !isRepeat &&
        (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack)) {
      _dismissChannelPreview(fromBackKey: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      if (widget.live) {
        if (canSwitchLiveChannelOnDirectionKey(
          live: widget.live,
          liveDelayedByPause: _liveDelayedByPause,
          playingNow: _playingNow,
        )) {
          if (!isRepeat) {
            if (_channelPreviewDirection == ChannelSwitchDirection.previous) {
              final target = _previewTargetFor(ChannelSwitchDirection.previous);
              if (target != null) unawaited(_executeLiveChannelSwitch(target));
            } else {
              _showChannelPreview(ChannelSwitchDirection.previous);
            }
          }
        } else {
          _dismissChannelPreview();
          _queueLiveRelativeSeek(liveDirectionKeySeekDeltaSeconds(forward: false));
        }
      } else {
        _queueRelativeSeek(_rewindStep);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      if (widget.live) {
        if (canSwitchLiveChannelOnDirectionKey(
          live: widget.live,
          liveDelayedByPause: _liveDelayedByPause,
          playingNow: _playingNow,
        )) {
          if (!isRepeat) {
            if (_channelPreviewDirection == ChannelSwitchDirection.next) {
              final target = _previewTargetFor(ChannelSwitchDirection.next);
              if (target != null) unawaited(_executeLiveChannelSwitch(target));
            } else {
              _showChannelPreview(ChannelSwitchDirection.next);
            }
          }
        } else {
          _dismissChannelPreview();
          _queueLiveRelativeSeek(liveDirectionKeySeekDeltaSeconds(forward: true));
        }
      } else {
        _queueRelativeSeek(_forwardStep);
      }
      return KeyEventResult.handled;
    }
    if (isRepeat) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (_channelPreviewDirection != null &&
          canSwitchLiveChannelOnDirectionKey(
            live: widget.live,
            liveDelayedByPause: _liveDelayedByPause,
            playingNow: _playingNow,
          ) &&
          key != LogicalKeyboardKey.space &&
          key != LogicalKeyboardKey.mediaPlayPause) {
        final target = _previewTargetFor(_channelPreviewDirection);
        if (target != null) {
          unawaited(_executeLiveChannelSwitch(target));
          return KeyEventResult.handled;
        }
      }
      _togglePlayPauseWithHud();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      if (widget.live) {
        _setLivePlaybackPaused(false);
      } else {
        unawaited(_player.play());
        _showSeekHud(Icons.play_arrow, '再生');
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      if (widget.live) {
        _setLivePlaybackPaused(true);
      } else {
        unawaited(_player.pause());
        _showSeekHud(Icons.pause, '一時停止');
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.info) {
      _openOsd();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final loadingLabel = playerLoadingLabel(
      interrupted: _interrupted,
      hasVideoFrame: _hasVideoFrame,
      playingStarted: _playing,
      playingNow: _playingNow,
      buffering: _buffering,
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        switch (resolvePlayerBackOutcome(
          detailOpen: _detailOpen,
          osdOpen: _osdOpen,
          channelPreviewOpen: _channelPreviewDirection != null,
          errorOpen: _error != null,
          exitConfirmOpen: _exitConfirmOpen,
          suppressUntil: _suppressBackPopUntil,
        )) {
          case PlayerBackOutcome.suppressed:
            return;
          case PlayerBackOutcome.closeDetail:
            _closeDetail(fromBackKey: true);
            return;
          case PlayerBackOutcome.closeOsd:
            _closeOsd(fromBackKey: true);
            return;
          case PlayerBackOutcome.closeChannelPreview:
            _dismissChannelPreview(fromBackKey: true);
            return;
          case PlayerBackOutcome.confirmExit:
            unawaited(_confirmExitPlayback());
            return;
          case PlayerBackOutcome.popPlayer:
            Navigator.of(context).pop();
            return;
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _switchingChannel
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      '${_switchingChannelLabel ?? '録画中のチャンネル'} に切り替えています…',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              )
            : _error != null
            ? Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.redAccent,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '再生を開始できませんでした。',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'nasne との接続やネットワークの状態を確認して、'
                          'もう一度お試しください。',
                          style: TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          focusNode: _errorBackFocusNode,
                          autofocus: true,
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('戻る'),
                        ),
                        const SizedBox(height: 16),
                        ExpansionTile(
                          collapsedTextColor: Colors.white70,
                          textColor: Colors.white,
                          iconColor: Colors.white70,
                          collapsedIconColor: Colors.white70,
                          title: const Text('詳細'),
                          children: [
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.white70),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : Focus(
                focusNode: _rootFocusNode,
                autofocus: true,
                onKeyEvent: _handleKeyEvent,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleOsd,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Video(
                        controller: _videoController,
                        controls: NoVideoControls,
                        subtitleViewConfiguration:
                            const SubtitleViewConfiguration(visible: false),
                      ),
                      if (_subtitlesOn &&
                          _visibleSubtitleCues.isNotEmpty &&
                          !_switchingChannel &&
                          _error == null)
                        PlayerSubtitleOverlay(
                          settings: ref.watch(subtitleSettingsProvider),
                          cues: _visibleSubtitleCues,
                          bottomSafePadding: _osdOpen
                              ? (widget.live ? 250.0 : 176.0)
                              : (_seekHudVisible ? 116.0 : 24.0),
                        ),
                      if (!_conflictHandled &&
                          (loadingLabel != null ||
                              (!_interrupted && _isPreBuffering)))
                        _buildLoadingOverlay(loadingLabel ?? '読み込み中…'),
                      if (_hudText != null && !_osdOpen) _buildStatusHud(),
                      if (shouldShowPlayerCornerNotice(
                        cornerRecordingNotice: _cornerRecordingNotice,
                        customCornerNoticeText: _customCornerNoticeText,
                        osdOpen: _osdOpen,
                        detailOpen: _detailOpen,
                        interrupted: _interrupted,
                        error: _error,
                        switchingChannel: _switchingChannel,
                      ))
                        PlayerCornerNotice(
                          customText: _customCornerNoticeText,
                          recordingNotice: _cornerRecordingNotice,
                        ),
                      if (widget.live &&
                          !_osdOpen &&
                          !_detailOpen &&
                          !_interrupted &&
                          _error == null &&
                          !_switchingChannel &&
                          _canSwitchLiveChannel &&
                          canSwitchLiveChannelOnDirectionKey(
                            live: widget.live,
                            liveDelayedByPause: _liveDelayedByPause,
                            playingNow: _playingNow,
                          ))
                        ..._buildChannelSwitchPreviewCards(),
                      if (_seekHudVisible && !_osdOpen) _buildSeekHud(),
                      if (_osdOpen ||
                          _osdFadeController.status != AnimationStatus.dismissed) ...[
                        if (!_detailOpen) _buildOsdClockOverlay(),
                        _buildRemoteOsd(),
                      ],
                      if (_detailOpen && _hasProgramDetail)
                        Positioned(
                          top: 20,
                          left: 28,
                          right: 28,
                          child: Builder(
                            builder: (_) {
                              if (!widget.live) {
                                return ProgramDetailOverlayPanel(
                                  title: widget.programDetailTitle ?? widget.title,
                                  meta: widget.programDetailMeta,
                                  body: widget.programDetailBody!,
                                  scrollController: _detailScrollController,
                                  focusNode: _detailFocusNode,
                                  onClose: () => _closeDetail(fromBackKey: true),
                                  onScrollDelta: _scrollDetailBy,
                                );
                              }
                              final opened = _openedLiveDetail;
                              final detailBody = (_liveDetailLoading &&
                                      !(opened?.hasBody ?? false))
                                  ? '番組詳細を読み込み中…'
                                  : ((opened?.hasBody ?? false)
                                      ? opened!.body!
                                      : '番組詳細情報はありません');
                              return ProgramDetailOverlayPanel(
                                title:
                                    opened?.title ??
                                    widget.programDetailTitle ??
                                    widget.title,
                                meta: opened != null
                                    ? opened.meta
                                    : widget.programDetailMeta,
                                body: detailBody,
                                scrollController: _detailScrollController,
                                focusNode: _detailFocusNode,
                                onClose: () => _closeDetail(fromBackKey: true),
                                onScrollDelta: _scrollDetailBy,
                              );
                            },
                          ),
                        ),
                      if (_interrupted && !_conflictHandled && !_switchingChannel)
                        _buildInterruptionBanner(),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  String _formatShortDurationSeconds(int seconds) {
    if (seconds <= 0) return '0秒';
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    if (min > 0 && sec > 0) return '$min分$sec秒';
    if (min > 0) return '$min分';
    return '$sec秒';
  }

  Widget _buildLoadingOverlay(String fallbackLabel) {
    final plan = _bufferPlan;
    final spec = liveLoadingOverlaySpec(
      isLive: widget.live,
      isPreBuffering: _isPreBuffering,
      targetSeconds: plan?.cachePauseWaitSeconds ?? 0,
      currentSeconds: _effectiveLoadingCurrentSeconds,
      bufferingPercentage: _bufferingPercentage,
      fallbackLabel: fallbackLabel,
    );
    return IgnorePointer(
      child: Center(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      spec.caption,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
                if (spec.showProgressBar) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: 220,
                    child: LinearProgressIndicator(
                      value: spec.progress,
                      backgroundColor: Colors.white24,
                      color: Colors.lightBlueAccent,
                      minHeight: 5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBufferBadge() {
    final plan = _bufferPlan;
    final aheadSec = _lastBufferBadgeUpdatedAt != null
        ? _displayedBufferAheadSeconds
        : math.max(_bufferedAheadSeconds, _bufferDeltaSeconds).floor();
    final targetSec = plan?.configuredSeconds ?? 0;
    if (aheadSec <= 0 && targetSec <= 0) return const SizedBox.shrink();
    final text = targetSec > 0
        ? 'バッファ: ${_formatShortDurationSeconds(aheadSec)} / 設定 ${_formatShortDurationSeconds(targetSec)}'
        : 'バッファ: ${_formatShortDurationSeconds(aheadSec)}';
    return buildPlayerOsdStatusBadge(
      label: text,
      color: const Color(0xB3000000),
      textColor: Colors.white,
    );
  }

  List<Widget> _buildChannelSwitchPreviewCards() {
    final now = _now();
    final prevEntry = _previewTargetFor(ChannelSwitchDirection.previous);
    final nextEntry = _previewTargetFor(ChannelSwitchDirection.next);
    final prevResolved = prevEntry == null
        ? null
        : resolveLiveSwitchEntryProgram(
            entry: prevEntry,
            guideEvents: _guideEventsForChannel(prevEntry.channel),
            now: now,
          );
    final nextResolved = nextEntry == null
        ? null
        : resolveLiveSwitchEntryProgram(
            entry: nextEntry,
            guideEvents: _guideEventsForChannel(nextEntry.channel),
            now: now,
          );
    final prevKey = prevEntry != null ? liveServiceKey(prevEntry.channel) : null;
    final nextKey = nextEntry != null ? liveServiceKey(nextEntry.channel) : null;
    return [
      LiveChannelSwitchPreviewCard(
        direction: ChannelSwitchDirection.previous,
        visible: _channelPreviewDirection == ChannelSwitchDirection.previous,
        entry: prevEntry,
        resolvedProgram: prevResolved,
        channelNumber: prevKey != null ? _liveChannelNumbers[prevKey] : null,
        channelLogoBytes: prevKey != null ? _liveChannelLogos[prevKey] : null,
        onTap: prevEntry == null
            ? null
            : () => unawaited(_executeLiveChannelSwitch(prevEntry)),
      ),
      LiveChannelSwitchPreviewCard(
        direction: ChannelSwitchDirection.next,
        visible: _channelPreviewDirection == ChannelSwitchDirection.next,
        entry: nextEntry,
        resolvedProgram: nextResolved,
        channelNumber: nextKey != null ? _liveChannelNumbers[nextKey] : null,
        channelLogoBytes: nextKey != null ? _liveChannelLogos[nextKey] : null,
        onTap: nextEntry == null
            ? null
            : () => unawaited(_executeLiveChannelSwitch(nextEntry)),
      ),
    ];
  }

  Widget _buildSeekProgressTrack({
    required double posFraction,
    double? bufferFraction,
    List<double> tickFractions = const [],
  }) {
    const barColor = Colors.lightBlueAccent;
    final clampedPos = posFraction.clamp(0.0, 1.0);
    final clampedBuf = bufferFraction?.clamp(clampedPos, 1.0);
    return SizedBox(
      height: 18,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final thumbLeft = (width * clampedPos - 7)
              .clamp(0.0, math.max(0.0, width - 14))
              .toDouble();
          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 8,
                  width: width,
                  color: Colors.white24,
                ),
              ),
              if (clampedBuf != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 8,
                    width: width * clampedBuf,
                    color: Colors.white54,
                  ),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 8,
                  width: width * clampedPos,
                  color: barColor,
                ),
              ),
              for (final tick in tickFractions)
                Positioned(
                  left: (width * tick - 1)
                      .clamp(0.0, math.max(0.0, width - 2))
                      .toDouble(),
                  top: 3,
                  width: 2,
                  height: 12,
                  child: const ColoredBox(color: Colors.white70),
                ),
              Positioned(
                left: thumbLeft,
                top: 2,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: barColor, width: 2.5),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSeekBarSection({required bool isSeekingPreview}) {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: _lastPosition,
      builder: (context, snapshot) {
        final dur = _effectiveDuration;
        final pos = _seekHudPositionOverride ?? (snapshot.data ?? _lastPosition);
        final clampedPos = dur > Duration.zero && pos > dur
            ? dur
            : (pos.isNegative ? Duration.zero : pos);
        final posFraction = dur > Duration.zero
            ? (clampedPos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;
        final aheadMillis =
            _lastPosition.inMilliseconds +
            (_bufferedAheadSeconds * 1000).round();
        final maxBufferMillis = math.max(
          _bufferEndPosition.inMilliseconds,
          aheadMillis,
        );
        final bufferFraction = dur > Duration.zero
            ? (maxBufferMillis / dur.inMilliseconds).clamp(posFraction, 1.0)
            : posFraction;
        final ticks = chapterTickFractions(chapters: _chapters, duration: dur);
        final remaining = dur > clampedPos ? dur - clampedPos : Duration.zero;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSeekProgressTrack(
              posFraction: posFraction,
              bufferFraction: bufferFraction,
              tickFractions: ticks,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  dur > Duration.zero
                      ? '${_formatClock(clampedPos)} / ${_formatClock(dur)}'
                      : _formatClock(clampedPos),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (dur > Duration.zero)
                  Text(
                    '残り -${_formatClock(remaining)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  ({double? effectivePos, double fallbackLag}) _currentLiveSeekInputs(
    DateTime now,
  ) {
    final activePause = _livePausedAt == null
        ? 0.0
        : math.max(
            0.0,
            now.difference(_livePausedAt!).inMilliseconds / 1000.0,
          );
    final fallbackLag = math.max(
      _liveEstimatedLagSeconds + activePause,
      _bufferedAheadSeconds,
    );
    final effectivePos = _livePendingSeekBaseSec != null
        ? (_livePendingSeekBaseSec! + _livePendingSeekDeltaSec)
        : (_liveCommittedSeekSec ?? _liveTimePosSec);
    return (effectivePos: effectivePos, fallbackLag: fallbackLag);
  }

  DateTime _effectiveLivePlaybackClock(DateTime now) {
    if (!widget.live) return now;
    final inputs = _currentLiveSeekInputs(now);
    final lagSeconds = resolveLivePlaybackLagSeconds(
      liveDelayedByPause: _liveDelayedByPause,
      cacheStartSeconds: _liveCacheStartSec,
      cacheEndSeconds: _liveCacheEndSec,
      liveEdgeSeconds: _liveCacheLiveEdgeSec,
      effectivePosSeconds: inputs.effectivePos,
      fallbackLagSeconds: inputs.fallbackLag,
      streamEpoch: _liveStreamEpoch,
      now: now,
      bufferedAheadSeconds: _bufferedAheadSeconds,
      isScrubbing: _livePendingSeekBaseSec != null,
    );
    return resolveLivePlaybackClock(
      now: now,
      lagSeconds: lagSeconds,
      streamEpoch: _liveStreamEpoch,
      effectivePosSeconds: inputs.effectivePos,
      liveDelayedByPause: _liveDelayedByPause,
    );
  }

  LiveTimeshiftBarState _currentLiveTimeshiftBarState(
    LiveOsdProgramInfo? info,
    DateTime now,
  ) {
    final inputs = _currentLiveSeekInputs(now);
    return resolveLiveTimeshiftBarState(
      info: info,
      now: now,
      cacheStartSeconds: _liveCacheStartSec,
      cacheEndSeconds: _liveCacheEndSec,
      liveEdgeSeconds: _liveCacheLiveEdgeSec,
      effectivePosSeconds: inputs.effectivePos,
      fallbackLagSeconds: inputs.fallbackLag,
      liveDelayedByPause: _liveDelayedByPause,
      streamEpoch: _liveStreamEpoch,
      bufferedAheadSeconds: _bufferedAheadSeconds,
      isScrubbing: _livePendingSeekBaseSec != null,
    );
  }

  Widget _buildSeekHud() {
    final now = _now();
    final playbackNow = _effectiveLivePlaybackClock(now);
    final activeChannel = widget.live ? _activeLiveChannel : null;
    final liveInfo = activeChannel != null
        ? resolveLiveOsdProgramInfo(
            channel: activeChannel,
            guideEvents: _guideEventsForChannel(activeChannel),
            now: playbackNow,
          )
        : null;
    final liveTimeshift = widget.live
        ? _currentLiveTimeshiftBarState(liveInfo, now)
        : null;
    final liveStatus = widget.live
        ? liveStatusPresentation(
            liveDelayedByPause: _liveDelayedByPause,
            liveCatchUpRate: _liveCatchUpRate,
            isPaused: !_playingNow || _livePausedAt != null,
            isRewoundPlayback: _liveRewoundByUser,
          )
        : null;
    final seekAccentColor = liveStatus?.barColor ?? Colors.lightBlueAccent;
    final headline = (liveInfo != null && liveInfo.currentTitle.isNotEmpty)
        ? liveInfo.currentTitle
        : widget.title;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black87, Colors.black],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: seekAccentColor),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_seekHudIcon != null) ...[
                          Icon(
                            _seekHudIcon,
                            color: seekAccentColor,
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          _seekHudActionLabel ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (liveInfo?.currentTimeRange != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      liveInfo!.remainingMinutes != null
                          ? '${liveInfo.currentTimeRange}（残り ${liveInfo.remainingMinutes}分）'
                          : liveInfo.currentTimeRange!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  _buildBufferBadge(),
                  if (liveStatus != null)
                    for (final badge in liveStatus.badges) ...[
                      const SizedBox(width: 8),
                      buildPlayerOsdStatusBadge(
                        label: badge.label,
                        color: badge.color,
                      ),
                    ],
                ],
              ),
              const SizedBox(height: 10),
              if (liveTimeshift != null)
                LiveProgramProgressBar(
                  state: liveTimeshift,
                  showDetailsRow: true,
                  barHeight: 8.0,
                  accentColor: seekAccentColor,
                )
              else
                _buildSeekBarSection(isSeekingPreview: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusHud() {
    return Positioned(
      top: 24,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_hudIcon != null) ...[
                  Icon(_hudIcon, color: Colors.white, size: 28),
                  const SizedBox(width: 12),
                ],
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _hudText ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOsdClockOverlay() =>
      PlayerOsdClockOverlay(now: _now(), opacity: _osdFadeAnimation);

  Widget _buildLiveOsdProgramSection({
    Color accentColor = Colors.lightBlueAccent,
  }) {
    final now = _now();
    final playbackNow = _effectiveLivePlaybackClock(now);
    final channel = _activeLiveChannel;
    if (channel == null) {
      if (!_liveDelayedByPause) return const SizedBox.shrink();
      return LiveProgramProgressBar(
        state: _currentLiveTimeshiftBarState(null, now),
        showDetailsRow: true,
        barHeight: 6.0,
        accentColor: accentColor,
      );
    }
    final info = resolveLiveOsdProgramInfo(
      channel: channel,
      guideEvents: _guideEventsForChannel(channel),
      now: playbackNow,
    );
    return LiveOsdProgramSection(
      info: info,
      timeshift: _currentLiveTimeshiftBarState(info, now),
      accentColor: accentColor,
    );
  }

  Widget _buildRemoteOsd() {
    final activeChannel = widget.live ? _activeLiveChannel : null;
    final activeServiceKey = activeChannel != null
        ? liveServiceKey(activeChannel)
        : null;
    final activeLogoBytes = activeServiceKey != null
        ? _liveChannelLogos[activeServiceKey]
        : null;
    final activeChannelNumber = activeServiceKey != null
        ? _liveChannelNumbers[activeServiceKey]
        : null;
    final liveStatus = widget.live
        ? liveStatusPresentation(
            liveDelayedByPause: _liveDelayedByPause,
            liveCatchUpRate: _liveCatchUpRate,
            isPaused: !_playingNow || _livePausedAt != null,
            isRewoundPlayback: _liveRewoundByUser,
          )
        : null;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_osdOpen,
        child: ExcludeFocus(
          excluding: !_osdOpen,
          child: FadeTransition(
            opacity: _osdFadeAnimation,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87, Colors.black],
                ),
              ),
              child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.live && activeLogoBytes != null) ...[
                  ChannelLogoPlate(
                    bytes: activeLogoBytes,
                    width: 42,
                    height: 24,
                    darkSurface: true,
                  ),
                  const SizedBox(width: 8),
                ],
                if (widget.live && activeChannelNumber != null) ...[
                  ChannelNumberBadge(
                    label: activeChannelNumber,
                    darkSurface: true,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    (!widget.live &&
                            widget.recordedChannelName != null &&
                            widget.recordedChannelName!.trim().isNotEmpty)
                        ? widget.recordedChannelName!.trim()
                        : widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _buildBufferBadge(),
                if (widget.live && _sameChannelRecording) ...[
                  const SizedBox(width: 8),
                  buildPlayerOsdStatusBadge(
                    label: '録画中',
                    color: const Color(0xFFC62828),
                    icon: Icons.fiber_manual_record,
                  ),
                ],
                if (liveStatus != null)
                  for (final badge in liveStatus.badges) ...[
                    const SizedBox(width: 8),
                    buildPlayerOsdStatusBadge(
                      label: badge.label,
                      color: badge.color,
                    ),
                  ],
              ],
            ),
            if (widget.live && (_activeLiveChannel != null || _liveDelayedByPause)) ...[
              const SizedBox(height: 6),
              _buildLiveOsdProgramSection(
                accentColor: liveStatus?.barColor ?? Colors.lightBlueAccent,
              ),
            ] else if (!widget.live) ...[
              if ((widget.recordedChannelName != null &&
                      widget.recordedChannelName!.trim().isNotEmpty) ||
                  (widget.recordedBroadcastTimeRange != null &&
                      widget.recordedBroadcastTimeRange!.trim().isNotEmpty)) ...[
                const SizedBox(height: 4),
                RecordedOsdProgramSection(
                  programTitle: widget.title,
                  broadcastTimeRange: widget.recordedBroadcastTimeRange,
                ),
              ],
              const SizedBox(height: 8),
              _buildSeekBarSection(isSeekingPreview: false),
            ],
            const SizedBox(height: 12),
            PlayerOsdButtonBar(
              focusScopeNode: _osdFocusScopeNode,
              onClose: () => _closeOsd(fromBackKey: true),
              onInteraction: _resetOsdTimer,
              children: [
                  _osdButton(
                    focusNode: _osdFirstFocusNode,
                    autofocus: true,
                    icon: _playingNow ? Icons.pause : Icons.play_arrow,
                    label: _playingNow ? '一時停止' : '再生',
                    onPressed: () {
                      _togglePlayPauseWithHud();
                      _resetOsdTimer();
                    },
                  ),
                  if (widget.live && _liveDelayedByPause) ...[
                    _osdButton(
                      icon: Icons.replay_10,
                      label: '-10秒',
                      onPressed: () {
                        _queueLiveRelativeSeek(
                          liveDirectionKeySeekDeltaSeconds(forward: false),
                        );
                        _resetOsdTimer();
                      },
                    ),
                    _osdButton(
                      icon: Icons.forward_10,
                      label: '+10秒',
                      onPressed: () {
                        _queueLiveRelativeSeek(
                          liveDirectionKeySeekDeltaSeconds(forward: true),
                        );
                        _resetOsdTimer();
                      },
                    ),
                    _osdButton(
                      icon: Icons.skip_next,
                      label: '現在位置へ',
                      onPressed: _catchingUpLive
                          ? null
                          : () => unawaited(_catchUpToLiveEdge()),
                    ),
                    _osdButton(
                      icon: Icons.speed,
                      label: _liveAutoCatchUpEnabled ? '等速に戻す' : '倍速追いかけ',
                      onPressed:
                          _catchingUpLive ? null : _toggleLiveAutoCatchUp,
                    ),
                  ],
                  if (!widget.live) ...[
                    _osdButton(
                      icon: Icons.replay_10,
                      label: '-10秒',
                      onPressed: () {
                        _queueRelativeSeek(_rewindStep);
                        _resetOsdTimer();
                      },
                    ),
                    _osdButton(
                      icon: Icons.forward_10,
                      label: '+10秒',
                      onPressed: () {
                        _queueRelativeSeek(_forwardStep);
                        _resetOsdTimer();
                      },
                    ),
                    if (_chapters.isNotEmpty) ...[
                      _osdButton(
                        icon: Icons.fast_rewind,
                        label: '前チャプター',
                        onPressed: () {
                          unawaited(_seekToChapter(forward: false));
                          _resetOsdTimer();
                        },
                      ),
                      _osdButton(
                        icon: Icons.fast_forward,
                        label: '次チャプター',
                        onPressed: () {
                          unawaited(_seekToChapter(forward: true));
                          _resetOsdTimer();
                        },
                      ),
                    ],
                  ],
                  if (canChangePlaybackSpeed(live: widget.live))
                    _osdButton(
                      icon: Icons.speed,
                      label: '速度 ${playbackSpeedLabel(_playbackRate)}',
                      onPressed: _cyclePlaybackRate,
                    ),
                  if (canSwitchAudio(_realAudioTracks.length))
                    _osdButton(
                      icon: Icons.audiotrack,
                      label: audioTrackLabel(_selectedAudioIndex),
                      onPressed: _cycleAudioTrack,
                    ),
                  if (canToggleSubtitles(_realSubtitleTracks.length))
                    _osdButton(
                      icon: _subtitlesOn
                          ? Icons.closed_caption
                          : Icons.closed_caption_off,
                      label: _subtitlesOn ? '字幕 ON' : '字幕 OFF',
                      onPressed: () {
                        _toggleSubtitles();
                        _resetOsdTimer();
                      },
                    ),
                  if (widget.canSwitchQuality && widget.onSwitchQuality != null)
                    _osdButton(
                      icon: osdQualityButtonIcon(
                        useMobile: widget.currentUseMobile,
                      ),
                      label: osdQualityButtonLabel(
                        useMobile: widget.currentUseMobile,
                      ),
                      onPressed: _switchingChannel
                          ? null
                          : () => unawaited(_executeQualitySwitch()),
                    ),
                  if (widget.live &&
                      _sameChannelRecording &&
                      _activeSameChannelSchedule != null &&
                      widget.onStopCurrentProgramRecording != null)
                    _osdButton(
                      icon: Icons.stop_circle_outlined,
                      label: '録画を停止',
                      onPressed: _recordingActionBusy
                          ? null
                          : () => unawaited(_confirmAndStopLiveRecording()),
                    )
                  else if (widget.live &&
                      !_sameChannelRecording &&
                      widget.onStartCurrentProgramRecording != null)
                    _osdButton(
                      icon: Icons.fiber_manual_record,
                      label: 'この番組を録画',
                      onPressed: _recordingActionBusy
                          ? null
                          : () => unawaited(_confirmAndStartLiveRecording()),
                    ),
                  if (_hasProgramDetail)
                    _osdButton(
                      focusNode: _osdDetailButtonFocusNode,
                      icon: Icons.info_outline,
                      label: _detailOpen ? '詳細を閉じる' : '番組詳細',
                      onPressed: () =>
                          _detailOpen ? _closeDetail() : _openDetail(),
                    ),
                  _osdButton(
                    icon: Icons.close,
                    label: playerOsdCloseMenuLabel,
                    onPressed: _closeOsd,
                  ),
                ],
            ),
          ],
        ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _osdButton({
    FocusNode? focusNode,
    bool autofocus = false,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      focusNode: focusNode,
      autofocus: autofocus,
      style: osdButtonStyle(),
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
    );
  }

  /// The interruption notice (plan 80): shown over the
  /// frozen frame when playback that had started dies
  /// mid-stream. Resume re-establishes the stream in place
  /// (see [_resume]); the close button dismisses the notice
  /// and leaves the stopped frame as it is.
  Widget _buildInterruptionBanner() {
    final countdownText = !_autoResumeDisabled && _autoResumeCountdown > 0
        ? 'あと $_autoResumeCountdown 秒で自動再接続します…（$_autoResumeAttempts回目）'
        : '電波復帰を待っています…（決定キーで今すぐ再開）';
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: Colors.black87,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.wifi_off, color: Colors.amberAccent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '再生が中断されました',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    countdownText,
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 13,
                    ),
                  ),
                  if (_interruptDetail != null)
                    Text(
                      _interruptDetail!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FocusTraversalGroup(
              child: Wrap(
                spacing: 10,
                children: [
                  FilledButton.icon(
                    focusNode: _resumeButtonFocusNode,
                    autofocus: true,
                    onPressed: _resume,
                    icon: const Icon(Icons.refresh),
                    label: const Text('今すぐ再開'),
                  ),
                  OutlinedButton.icon(
                    focusNode: _closeBannerFocusNode,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                    onPressed: () {
                      _autoResumeTimer?.cancel();
                      setState(() {
                        _autoResumeDisabled = true;
                        _autoResumeCountdown = 0;
                        _interrupted = false;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _rootFocusNode.canRequestFocus) {
                          _rootFocusNode.requestFocus();
                        }
                      });
                    },
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('閉じる'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

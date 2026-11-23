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
import 'dart:io' show Directory, Platform;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app/firetv_helper.dart';
import '../app/providers.dart';
import '../core/core.dart';
import 'player_cache_policy.dart';
import 'player_chapter_policy.dart';
import 'player_error_policy.dart';
import 'player_resume_policy.dart';
import 'player_seek_policy.dart';
import 'player_speed_policy.dart';
import 'player_teardown_policy.dart';
import 'player_track_policy.dart';

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

/// Computes accumulated pre-buffer seconds (clamped to `[0, targetSeconds]`)
/// from all available mpv cache signals. During live `cache-pause-initial`,
/// mpv may leave `demuxer-cache-duration` unemitted while updating
/// `cache-buffering-state` (`bufferingPercentage`) and/or `demuxer-cache-time`.
int computePreBufferSeconds({
  required int targetSeconds,
  required double demuxerCacheDuration,
  required double bufferingPercentage,
  required double bufferDeltaSeconds,
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
  final best = math.max(fromDuration, math.max(fromPercent, fromDelta));
  return best.clamp(0.0, targetSeconds.toDouble()).floor();
}

/// Outcome for resolving a system Back (`PopScope`) while the player is open.
enum PlayerBackOutcome { suppressed, closeDetail, closeOsd, popPlayer }

/// Resolves what a platform Back invocation should do for the current overlay
/// and debounce-suppression state.
PlayerBackOutcome resolvePlayerBackOutcome({
  required bool detailOpen,
  required bool osdOpen,
  DateTime? suppressUntil,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  if (suppressUntil != null && current.isBefore(suppressUntil)) {
    return PlayerBackOutcome.suppressed;
  }
  if (detailOpen) return PlayerBackOutcome.closeDetail;
  if (osdOpen) return PlayerBackOutcome.closeOsd;
  return PlayerBackOutcome.popPlayer;
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

  static const Duration rewindStep = Duration(seconds: -10);
  static const Duration forwardStep = Duration(seconds: 10);

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;
  late final WakelockSession _wakelockSession;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _watchdog;
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

  /// The caption toggle (plan 53). Default off, per the
  /// owner's spec; kept in this state only, never persisted.
  bool _subtitlesOn = false;

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
  bool _detailOpen = false;
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

  bool get _isPreBuffering {
    final plan = _bufferPlan;
    return plan != null &&
        plan.cachePauseInitial &&
        plan.cachePauseWaitSeconds > 0 &&
        (!_hasVideoFrame || !_playing);
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
  );

  void _startPreBufferPoller() {
    _preBufferPollTimer?.cancel();
    _preBufferPollTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      if (!mounted || !_isPreBuffering) {
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
    if (platform is! NativePlayer) return;
    _pollingBufferProps = true;
    final prevPreSec = _effectivePreBufferSeconds;
    final prevAheadFloor = _bufferedAheadSeconds.floor();
    try {
      try {
        final rawDur = await platform.getProperty('demuxer-cache-duration');
        final parsed = double.tryParse(rawDur);
        if (parsed != null && parsed.isFinite && parsed >= 0) {
          _bufferedAheadSeconds = parsed;
        }
      } catch (_) {}
      try {
        final rawPct = await platform.getProperty('cache-buffering-state');
        final parsed = double.tryParse(rawPct);
        if (parsed != null && parsed.isFinite) {
          _bufferingPercentage = parsed.clamp(0.0, 100.0).toDouble();
        }
      } catch (_) {}
      if (!mounted) return;
      final nextPreSec = _effectivePreBufferSeconds;
      if ((_isPreBuffering && nextPreSec != prevPreSec) ||
          ((_osdOpen || _seekHudVisible) &&
              _bufferedAheadSeconds.floor() != prevAheadFloor)) {
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
      setState(() => _hasVideoFrame = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _diag = ref.read(diagLogProvider);
    _fireTvHelper = ref.read(fireTvHelperProvider);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_fireTvHelper.setMediaVolumeMax());
    _player = Player();
    unawaited(_player.setVolume(100.0));
    _videoController = VideoController(_player);
    _videoController.rect.addListener(_onVideoRectChanged);
    _wakelockSession = ref.read(playbackWakelockProvider).openSession();
    _watchdog = Timer(startTimeout, _onStartTimeout);
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        _diag(DiagCategory.playback, 'player: playing=$playing');
        _wakelockSession.setPlaying(playing);
        final wasPlaying = _playingNow;
        if (mounted) {
          setState(() {
            _playingNow = playing;
            if (playing) {
              _playing = true;
              _interrupted = false;
              _interruptDetail = null;
            }
          });
        } else {
          _playingNow = playing;
          if (playing) _playing = true;
        }
        if (playing) {
          _watchdog?.cancel();
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
        } else if (wasPlaying) {
          _onPlaybackStopped();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        _diag(DiagCategory.playback, 'player: buffering=$buffering');
        if (_playingNow) {
          // Buffering while mpv is trying to play is the
          // signature the plan-78 stalls left just before
          // mpv stopped (plan 80); buffering clearing again
          // while playing is a recovery and clears it.
          _bufferingSincePlaying = buffering;
        }
        if (!buffering && _playingNow) {
          _autoResumeAttempts = 0;
        }
        if (mounted && _buffering != buffering) {
          setState(() => _buffering = buffering);
        } else {
          _buffering = buffering;
        }
      }),
    );
    _subscriptions.add(
      _player.stream.width.listen((width) {
        if (!_hasVideoFrame && width != null && width > 0 && mounted) {
          setState(() => _hasVideoFrame = true);
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
        final committed = _committedSeekTarget;
        if (committed != null &&
            (position - committed).abs() <= const Duration(seconds: 2)) {
          _committedSeekTarget = null;
          _committedSeekHoldTimer?.cancel();
          if (_seekHudVisible && mounted) setState(() {});
        }
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
        final prevPreSec = _effectivePreBufferSeconds;
        final prevDeltaFloor = _bufferDeltaSeconds.floor();
        if (bufferEnd > Duration.zero && _initialBufferPosition == null) {
          _initialBufferPosition = bufferEnd <= const Duration(seconds: 5)
              ? Duration.zero
              : bufferEnd;
        }
        if (bufferEnd != _bufferEndPosition) {
          _bufferEndPosition = bufferEnd;
          if (mounted &&
              ((_isPreBuffering &&
                      _effectivePreBufferSeconds != prevPreSec) ||
                  ((_osdOpen || _seekHudVisible) &&
                      _bufferDeltaSeconds.floor() != prevDeltaFloor))) {
            setState(() {});
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.bufferingPercentage.listen((pct) {
        if (!pct.isFinite) return;
        final clamped = pct.clamp(0.0, 100.0).toDouble();
        final prevPreSec = _effectivePreBufferSeconds;
        _bufferingPercentage = clamped;
        if (mounted &&
            _isPreBuffering &&
            _effectivePreBufferSeconds != prevPreSec) {
          setState(() {});
        }
      }),
    );
    _subscriptions.add(
      _player.stream.tracks.listen((tracks) {
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
      _player.stream.error.listen((error) {
        _diag(DiagCategory.playback, 'player: error: $error');
        if (!playerErrorIsFatal(
          error,
          live: widget.live,
          alreadyPlaying: _playing,
        )) {
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
        if (!mounted) return;
        if (_playing) {
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
          _setStartError(error);
        }
      }),
    );
    _observeSeekable();
    _observeCacheDuration();
    _open();
    _loadChapters();
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
      if (nav.canPop()) {
        nav.pop();
      }
    });
  }

  void _setStartError(String error) {
    _stopPreBufferPoller();
    if (!mounted) return;
    setState(() => _error = error);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _error != null && _errorBackFocusNode.canRequestFocus) {
        _errorBackFocusNode.requestFocus();
      }
    });
  }

  void _enterInterruptedState(String? detail) {
    _stopPreBufferPoller();
    if (!mounted || _completed) return;
    setState(() {
      _interrupted = true;
      if (detail != null) _interruptDetail = detail;
    });
    _scheduleAutoResume();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _interrupted &&
          _resumeButtonFocusNode.canRequestFocus) {
        _resumeButtonFocusNode.requestFocus();
      }
    });
  }

  void _scheduleAutoResume() {
    _autoResumeTimer?.cancel();
    if (_autoResumeDisabled || !_interrupted || !mounted) return;
    final delaySec = _autoResumeBackoffSeconds[
        math.min(_autoResumeAttempts, _autoResumeBackoffSeconds.length - 1)];
    _autoResumeAttempts++;
    setState(() => _autoResumeCountdown = delaySec);
    _diag(
      DiagCategory.playback,
      'player: scheduling auto-resume attempt $_autoResumeAttempts in ${delaySec}s',
    );
    _autoResumeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !_interrupted || _autoResumeDisabled) {
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
    if (!mounted || _playing || _error != null) return;
    final timeoutSec = _bufferPlan?.startTimeoutSeconds ?? startTimeout.inSeconds;
    _diag(
      DiagCategory.playback,
      'player: no playback within $timeoutSec seconds; '
      'showing a timeout error',
    );
    _setStartError(
      '再生が開始できませんでした ($timeoutSec 秒以内に映像が届きませんでした)。',
    );
  }

  /// A playing→stopped transition (plan 80): when the
  /// policy classes it as a mid-stream death, give mpv a
  /// grace period to recover on its own before surfacing
  /// anything.
  void _onPlaybackStopped() {
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
    if (!mounted || _playingNow || _completed || _error != null) {
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
    _diag(
      DiagCategory.playback,
      'player: resuming after an interruption at '
      '${_lastPosition.inSeconds}s (live=${widget.live})',
    );
    _stallTimer?.cancel();
    _autoResumeTimer?.cancel();
    _resumeWatchdogTimer?.cancel();
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
    });
    if (_isPreBuffering) {
      _startPreBufferPoller();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rootFocusNode.canRequestFocus) {
        _rootFocusNode.requestFocus();
      }
    });
    _resumeWatchdogTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted || _playingNow || _completed || _interrupted || _error != null) {
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
      await _player.open(
        Media(
          widget.session.mediaUri.toString(),
          start: (!widget.live && _lastPosition > Duration.zero)
              ? _lastPosition
              : null,
        ),
      );
      await _player.setVolume(100.0);
      _diag(DiagCategory.playback, 'player: resume open completed');
    } catch (e) {
      _diag(DiagCategory.playback, 'player: resume failed: $e');
      _resumeWatchdogTimer?.cancel();
      _enterInterruptedState('$e');
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
    try {
      if (id == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        await _player.setSubtitleTrack(
          _realSubtitleTracks.firstWhere((track) => track.id == id),
        );
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
                ((_osdOpen || _seekHudVisible) && clamped.floor() != prevFloor))) {
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
    try {
      await _player.seek(target);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: chapter seek failed: $e');
    }
  }

  Future<void> _open() async {
    _diag(DiagCategory.playback, 'player: opening ${widget.session.mediaUri}');
    try {
      final bufferSeconds = !widget.live
          ? ref.read(recordedBufferSecondsProvider)
          : ref.read(liveBufferSecondsProvider);
      final cacheDir = ref.read(mpvCacheDirectoryProvider);
      final availableDiskBytes =
          (bufferSeconds >= 60 && Platform.isAndroid)
          ? await _fireTvHelper.getCacheAvailableBytes()
          : null;
      final plan = computeMpvBufferPlan(
        live: widget.live,
        bufferSeconds: bufferSeconds,
        isAndroid: Platform.isAndroid,
        availableDiskBytes: availableDiskBytes,
        cacheDirPath: cacheDir?.path,
      );
      if (!mounted) return;
      _bufferPlan = plan;
      _bufferingPercentage = 0.0;
      _bufferedAheadSeconds = 0.0;
      _bufferEndPosition = Duration.zero;
      _initialBufferPosition = null;
      _usedDiskCacheDir = plan.useDiskCache ? cacheDir : null;
      _watchdog?.cancel();
      _watchdog = Timer(
        Duration(seconds: plan.startTimeoutSeconds),
        _onStartTimeout,
      );

      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty(
          'network-timeout',
          '${plan.networkTimeoutSeconds}',
        );
        await platform.setProperty('sid', 'no');
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
          await platform.setProperty('cache-pause', 'yes');
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
          if (plan.useDiskCache && plan.cacheDirPath != null) {
            await platform.setProperty('cache-on-disk', 'yes');
            await platform.setProperty('demuxer-cache-dir', plan.cacheDirPath!);
          }
        }
        _diag(
          DiagCategory.playback,
          'player: mpv buffer plan: target=${plan.configuredSeconds}s '
          'cache=${plan.useCache} disk=${plan.useDiskCache} '
          'maxBytes=${plan.demuxerMaxBytes} back=${plan.demuxerMaxBackBytes} '
          'wait=${plan.cachePauseWaitSeconds}s netTimeout=${plan.networkTimeoutSeconds}s',
        );
      }
      if (mounted) {
        setState(() {});
        if (plan.cachePauseInitial && plan.cachePauseWaitSeconds > 0) {
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
      await _applySubtitleSelection();
    } catch (e) {
      _diag(DiagCategory.playback, 'player: open failed: $e');
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
    if (widget.onResumePosition == null) return null;
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
        (name: 'stall timer', run: () => _stallTimer?.cancel()),
        (name: 'auto resume timer', run: () => _autoResumeTimer?.cancel()),
        (name: 'resume watchdog', run: () => _resumeWatchdogTimer?.cancel()),
        (name: 'pre-buffer poller', run: () => _preBufferPollTimer?.cancel()),
        (name: 'osd timer', run: () => _osdTimer?.cancel()),
        (name: 'hud timer', run: () => _hudTimer?.cancel()),
        (name: 'seek hud timer', run: () => _seekHudTimer?.cancel()),
        (name: 'seek debounce timer', run: () => _seekDebounceTimer?.cancel()),
        (
          name: 'seek hold timer',
          run: () => _committedSeekHoldTimer?.cancel(),
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

  bool get _hasProgramDetail =>
      (widget.programDetailBody?.trim().isNotEmpty ?? false);

  void _openDetail() {
    if (!_hasProgramDetail) return;
    _osdTimer?.cancel();
    setState(() => _detailOpen = true);
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

  void _closeDetail({bool fromBackKey = false}) {
    if (fromBackKey) {
      _suppressBackPopUntil = DateTime.now().add(
        const Duration(milliseconds: 450),
      );
    }
    if (!_detailOpen) return;
    setState(() => _detailOpen = false);
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

  void _openOsd() {
    setState(() => _osdOpen = true);
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
    if (!_osdOpen && !_detailOpen) return;
    setState(() {
      _osdOpen = false;
      _detailOpen = false;
    });
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

  void _togglePlayPauseWithHud() {
    final willPlay = !_playingNow;
    unawaited(_player.playOrPause());
    if (widget.live) {
      _showHudMessage(
        willPlay ? Icons.play_arrow : Icons.pause,
        willPlay ? '再生' : '一時停止',
      );
    } else {
      _showSeekHud(
        willPlay ? Icons.play_arrow : Icons.pause,
        willPlay ? '再生' : '一時停止',
      );
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
    try {
      await _player.seek(target);
    } catch (e) {
      _diag(DiagCategory.playback, 'player: dpad seek failed: $e');
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
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      if (widget.live) {
        if (!isRepeat) {
          _showHudMessage(Icons.live_tv, 'ライブ放送中はシークできません');
        }
      } else {
        _queueRelativeSeek(_rewindStep);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      if (widget.live) {
        if (!isRepeat) {
          _showHudMessage(Icons.live_tv, 'ライブ放送中はシークできません');
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
      _togglePlayPauseWithHud();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      unawaited(_player.play());
      if (widget.live) {
        _showHudMessage(Icons.play_arrow, '再生');
      } else {
        _showSeekHud(Icons.play_arrow, '再生');
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      unawaited(_player.pause());
      if (widget.live) {
        _showHudMessage(Icons.pause, '一時停止');
      } else {
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
          case PlayerBackOutcome.popPlayer:
            Navigator.of(context).pop();
            return;
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _error != null
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
                      ),
                      if (loadingLabel != null) _buildLoadingOverlay(loadingLabel),
                      if (_hudText != null && !_osdOpen) _buildStatusHud(),
                      if (_seekHudVisible && !_osdOpen && !widget.live)
                        _buildSeekHud(),
                      if (_osdOpen) _buildRemoteOsd(),
                      if (_detailOpen && _hasProgramDetail)
                        Positioned(
                          top: 20,
                          left: 28,
                          right: 28,
                          child: ProgramDetailOverlayPanel(
                            title: widget.programDetailTitle ?? widget.title,
                            meta: widget.programDetailMeta,
                            body: widget.programDetailBody!,
                            scrollController: _detailScrollController,
                            focusNode: _detailFocusNode,
                            onClose: () => _closeDetail(fromBackKey: true),
                            onScrollDelta: _scrollDetailBy,
                          ),
                        ),
                      if (_interrupted) _buildInterruptionBanner(),
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
    final showPreBuffer = _isPreBuffering;
    final targetSec = showPreBuffer ? plan!.cachePauseWaitSeconds : 0;
    final curSec = showPreBuffer ? _effectivePreBufferSeconds : 0;
    final progress = showPreBuffer && targetSec > 0
        ? (curSec / targetSec).clamp(0.0, 1.0)
        : null;
    final caption = showPreBuffer
        ? 'バッファ蓄積中… ${_formatShortDurationSeconds(curSec)} / ${_formatShortDurationSeconds(targetSec)}'
        : fallbackLabel;
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
                      caption,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
                if (progress != null) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: 220,
                    child: LinearProgressIndicator(
                      value: progress,
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
    final aheadSec = math.max(_bufferedAheadSeconds, _bufferDeltaSeconds).floor();
    final targetSec = plan?.configuredSeconds ?? 0;
    if (aheadSec <= 0 && targetSec <= 0) return const SizedBox.shrink();
    final text = targetSec > 0
        ? 'バッファ: ${_formatShortDurationSeconds(aheadSec)} / 設定 ${_formatShortDurationSeconds(targetSec)}'
        : 'バッファ: ${_formatShortDurationSeconds(aheadSec)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
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
        final barColor = isSeekingPreview || _seekHudPositionOverride != null
            ? Colors.amberAccent
            : Colors.lightBlueAccent;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 18,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final thumbLeft = (width * posFraction - 7)
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
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          height: 8,
                          width: width * bufferFraction,
                          color: Colors.white54,
                        ),
                      ),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          height: 8,
                          width: width * posFraction,
                          color: barColor,
                        ),
                      ),
                      for (final tick in ticks)
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

  Widget _buildSeekHud() {
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
                      border: Border.all(color: Colors.amberAccent),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_seekHudIcon != null) ...[
                          Icon(
                            _seekHudIcon,
                            color: Colors.amberAccent,
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
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildBufferBadge(),
                ],
              ),
              const SizedBox(height: 10),
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

  Widget _buildRemoteOsd() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
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
                Expanded(
                  child: Text(
                    widget.title,
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
                const SizedBox(width: 8),
                if (widget.live)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            if (!widget.live) ...[
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
    );
  }

  Widget _osdButton({
    FocusNode? focusNode,
    bool autofocus = false,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
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

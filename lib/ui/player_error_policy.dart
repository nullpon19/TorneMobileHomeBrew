/// Player error policy (plan 43).
///
/// mpv can report "Cannot seek in this stream." while a stream
/// is being opened. The demuxer queues an initial seek for
/// streams whose timestamps do not start at zero; the core's
/// seek path refuses it because the stream — served by the
/// loopback proxy as a chunked response without ranges — is not
/// seekable, and the refusal is logged at error level. In mpv
/// itself the refusal is non-fatal (playback continues), but
/// media_kit forwards the message to the player's error stream,
/// where the player screen used to turn ANY error into a
/// failed start.
///
/// That is what an external reporter hit on Android: BS live at
/// DR quality failed to start with exactly this message, while
/// the mobile quality — whose timestamps start at zero, so no
/// initial seek is queued — played fine. (The same app on iOS
/// played DR live; the Android mpv build is the one that queues
/// and reports the seek.) The app itself never issues a seek:
/// the seek is mpv-internal.
///
/// A live stream is endless and unseekable by design, so for
/// live viewing the complaint carries no information: it is
/// logged and ignored, and the start watchdog remains the
/// arbiter of a start that never reaches playback. Recorded
/// playback keeps the previous behaviour — every player error
/// fails the start — so this changes nothing for recordings.
///
/// The complaint arrives as TWO separate error events (measured
/// on a real device, plan 56): the refusal itself and, right
/// after it, the hint "You can force it with
/// '--force-seekable=yes'.", which mpv emits as its own error.
/// The hint alone does not contain the refusal text, so it used
/// to fall through this classification and fail the start —
/// that is what the user hit even after the plan-43 fix. The
/// pair can also arrive late (25 s after the start in the
/// measured case, with playback already running), so the
/// classification must not depend on timing either. Both events
/// are classified here as the one complaint.
///
/// The same reasoning extends past the start (player UI
/// follow-up after 1.4.0): once playback has started, the
/// complaint can only be answering a seek — mpv's internal
/// one arriving late, or the recorded screen's skip buttons
/// on a stream whose seekability has lapsed — and mpv keeps
/// playing through it either way. Failing a healthy playback
/// over it would punish the user for a seek the player
/// itself invited, so with playback under way the complaint
/// is non-fatal for recordings too. Before the start it
/// keeps the treatment above: fatal for recordings,
/// non-fatal for live.
library;

/// True when [error] is one of the two events of mpv's refusal
/// to seek in an unseekable stream: the refusal itself
/// ("Cannot seek in this stream.") or its companion hint
/// ("You can force it with '--force-seekable=yes'.").
bool isUnseekableStreamError(String error) =>
    error.contains('Cannot seek in this stream') ||
    error.contains('force-seekable');

/// Whether a player [error] must fail playback. The
/// unseekable-stream complaint is non-fatal for live
/// viewing and, once playback has started
/// ([alreadyPlaying]), for recordings as well (see the
/// library comment); everything else is fatal, as before.
bool playerErrorIsFatal(
  String error, {
  required bool live,
  bool alreadyPlaying = false,
}) => !((live || alreadyPlaying) && isUnseekableStreamError(error));

/// Whether a playing→stopped transition means the playback
/// died mid-stream (plan 80), as opposed to ending normally
/// or being paused on purpose.
///
/// The plan-78 stalls produced no fatal error at all: mpv
/// waited for data that never came (buffering), then simply
/// stopped on the last frame — from the screen's side, a
/// playing→stopped transition with buffering observed since
/// playback was last running and no end-of-stream signal.
/// [alreadyPlaying] is whether playback had ever started,
/// [completed] is mpv's end-of-stream signal, and
/// [bufferedBeforeStop] is whether buffering was observed
/// after playback was last running. A stop the user asked
/// for (a pause) shows no fresh buffering in the ordinary
/// case and stays unflagged; the exception — pausing in the
/// middle of a buffering episode — is accepted, because the
/// interruption notice this gates is dismissible and its
/// resume action is harmless.
bool playbackStoppedEarly({
  required bool alreadyPlaying,
  required bool completed,
  required bool bufferedBeforeStop,
}) => alreadyPlaying && !completed && bufferedBeforeStop;

/// Whether a recorded playback has effectively reached the end of the
/// programme, so a trailing stop after buffering or a truncated
/// Content-Length close is treated as normal completion rather than a
/// mid-stream disconnect.
bool isNearRecordedEnd({
  required bool live,
  required Duration position,
  required Duration duration,
  Duration tolerance = const Duration(seconds: 8),
}) {
  if (live) return false;
  if (duration <= Duration.zero || position <= Duration.zero) return false;
  final effectiveTolerance = duration <= const Duration(seconds: 30)
      ? const Duration(seconds: 2)
      : tolerance;
  return (duration - position) <= effectiveTolerance;
}

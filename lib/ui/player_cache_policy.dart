/// Which mpv cache mode a playback kind runs with (plan 80).
///
/// Recorded playback runs with mpv's cache ON. The
/// seek-freeze chain measured in plan 78.1 was the demuxer
/// re-reading the stream through the loopback proxy at every
/// step — head probe, tail probe, backward scans, seek
/// refinement — each hop a fresh proxy round trip competing
/// with the playback stream itself. mpv's own cache, sized
/// by the demuxer-max-bytes options the player screen sets
/// alongside, absorbs those re-reads locally instead.
///
/// Live playback keeps the cache OFF (plan 54): on the
/// unseekable live stream the demuxer cache stalled audio
/// track switching indefinitely (measured), and an endless
/// broadcast has no tail to probe or past to re-read, so
/// nothing in plan 78 argues for changing the live side.
library;

import 'dart:math' as math;

/// mpv's `cache` option value for the playback kind: 'yes'
/// for recordings, 'no' for live (see the library comment).
String mpvCacheMode({required bool live}) => live ? 'no' : 'yes';

/// How much demuxer cache a recording may hold ahead of the
/// play position (mpv's `demuxer-max-bytes`). Sized to cover
/// the demuxer's probe and refinement re-reads around a
/// position (plan 78.1) without turning the player into a
/// second full copy of the window the proxy already keeps.
const int recordingDemuxerMaxBytes = 32 * 1024 * 1024;

/// How much demuxer cache a recording may hold behind the
/// play position (mpv's `demuxer-max-back-bytes`): the
/// demuxer's backward scans and a small step back stay
/// local instead of re-entering the proxy.
const int recordingDemuxerMaxBackBytes = 16 * 1024 * 1024;

/// Tighter demuxer forward cache on memory-constrained Android / Fire TV
/// sticks (still ~30s+ at mobile bitrate without filling 1 GB RAM).
const int androidRecordingDemuxerMaxBytes = 8 * 1024 * 1024;

/// Tighter demuxer backward cache on Android / Fire TV devices.
const int androidRecordingDemuxerMaxBackBytes = 4 * 1024 * 1024;

/// Effective `demuxer-max-bytes` for recorded playback on [isAndroid].
int effectiveRecordingDemuxerMaxBytes({required bool isAndroid}) =>
    isAndroid ? androidRecordingDemuxerMaxBytes : recordingDemuxerMaxBytes;

/// Effective `demuxer-max-back-bytes` for recorded playback on [isAndroid].
int effectiveRecordingDemuxerMaxBackBytes({required bool isAndroid}) =>
    isAndroid
    ? androidRecordingDemuxerMaxBackBytes
    : recordingDemuxerMaxBackBytes;

/// Buffer duration choices (in seconds) for recorded playback on Fire TV.
const List<int> recordedBufferOptionsSeconds = [
  0,
  30,
  60,
  180,
  300,
  600,
  900,
  1800,
  2700,
  3600,
];

/// Default recorded buffer duration: 5 minutes (background disk cache).
const int defaultRecordedBufferSeconds = 300;

/// Buffer duration choices (in seconds) for live delayed buffering.
const List<int> liveBufferOptionsSeconds = [0, 15, 30, 60, 180, 300];

/// Default live buffer duration: standard low-latency (`0` = no extra delay).
const int defaultLiveBufferSeconds = 0;

/// Minimum free storage space preserved when sizing mpv's disk cache (512 MiB).
const int minFreeDiskReserveBytes = 512 * 1024 * 1024;

/// Upper bound on forward disk cache size (~60 min of mobile stream, < 2 GiB).
const int maxDiskCacheBytes = 1200 * 1024 * 1024;

/// Upper bound on backward disk cache size (~8-10 min for offline rewind).
const int maxDiskBackCacheBytes = 150 * 1024 * 1024;

/// Human-readable Japanese label for a buffer duration in seconds.
String formatBufferDurationLabel(int seconds) {
  if (seconds <= 0) return '標準 (0秒)';
  if (seconds < 60) return '$seconds秒';
  return '${seconds ~/ 60}分';
}

/// Resolved mpv cache configuration & timeout plan for a playback session.
class MpvBufferPlan {
  const MpvBufferPlan({
    required this.useCache,
    required this.useDiskCache,
    required this.cacheDirPath,
    required this.demuxerMaxBytes,
    required this.demuxerMaxBackBytes,
    required this.readaheadSeconds,
    required this.cachePauseInitial,
    required this.cachePauseWaitSeconds,
    required this.networkTimeoutSeconds,
    required this.startTimeoutSeconds,
    required this.configuredSeconds,
  });

  final bool useCache;
  final bool useDiskCache;
  final String? cacheDirPath;
  final int demuxerMaxBytes;
  final int demuxerMaxBackBytes;
  final int readaheadSeconds;
  final bool cachePauseInitial;
  final int cachePauseWaitSeconds;
  final int networkTimeoutSeconds;
  final int startTimeoutSeconds;
  final int configuredSeconds;
}

/// Computes RAM vs disk cache limits, pre-buffer wait, and timeouts safely.
MpvBufferPlan computeMpvBufferPlan({
  required bool live,
  required int bufferSeconds,
  required bool isAndroid,
  int? availableDiskBytes,
  String? cacheDirPath,
}) {
  final normalized = bufferSeconds < 0 ? 0 : bufferSeconds;
  final useCache = !live || normalized > 0;
  var useDiskCache =
      useCache &&
      normalized >= 60 &&
      cacheDirPath != null &&
      cacheDirPath.isNotEmpty;

  final int demuxerMaxBytes;
  if (!useCache) {
    demuxerMaxBytes = 0;
  } else if (normalized == 0) {
    demuxerMaxBytes = effectiveRecordingDemuxerMaxBytes(isAndroid: isAndroid);
  } else {
    // Mobile TS bitrate is ~11-15 MiB/min; provision 21 MiB/min headroom.
    final minFloor = normalized <= 15 ? 8 * 1024 * 1024 : 14 * 1024 * 1024;
    final scaled = ((normalized * 21) ~/ 60) * 1024 * 1024;
    final rawTarget = math.min(
      math.max(minFloor, scaled),
      maxDiskCacheBytes,
    );
    if (useDiskCache && availableDiskBytes != null) {
      final safeLimit = availableDiskBytes - minFreeDiskReserveBytes;
      if (safeLimit <= 16 * 1024 * 1024) {
        // Low storage fallback: disable disk cache and keep a small RAM budget.
        useDiskCache = false;
        demuxerMaxBytes = math.min(rawTarget, 24 * 1024 * 1024);
      } else {
        demuxerMaxBytes = math.min(rawTarget, safeLimit);
      }
    } else if (!useDiskCache) {
      demuxerMaxBytes = math.min(rawTarget, 48 * 1024 * 1024);
    } else {
      demuxerMaxBytes = rawTarget;
    }
  }

  final int demuxerMaxBackBytes;
  if (!useCache) {
    demuxerMaxBackBytes = 0;
  } else if (live) {
    demuxerMaxBackBytes = 2 * 1024 * 1024;
  } else if (useDiskCache) {
    final quarter = demuxerMaxBytes ~/ 4;
    demuxerMaxBackBytes = math.max(
      4 * 1024 * 1024,
      math.min(quarter, maxDiskBackCacheBytes),
    );
  } else {
    demuxerMaxBackBytes = effectiveRecordingDemuxerMaxBackBytes(
      isAndroid: isAndroid,
    );
  }

  final readaheadSeconds = normalized > 0 ? normalized + 15 : 20;
  final cachePauseInitial = normalized > 0;
  // Recordings start quickly (~5s) while pre-reading up to [normalized] in the
  // background; Live waits up to [normalized] before playing.
  final cachePauseWaitSeconds = normalized == 0
      ? 0
      : (live ? normalized : math.min(normalized, 5));
  final networkTimeoutSeconds = live
      ? math.max(30, math.min(normalized + 30, 360))
      : math.max(30, math.min(normalized > 0 ? normalized + 30 : 30, 600));
  final startTimeoutSeconds = 45 + (live ? normalized : 15);

  return MpvBufferPlan(
    useCache: useCache,
    useDiskCache: useDiskCache,
    cacheDirPath: useDiskCache ? cacheDirPath : null,
    demuxerMaxBytes: demuxerMaxBytes,
    demuxerMaxBackBytes: demuxerMaxBackBytes,
    readaheadSeconds: readaheadSeconds,
    cachePauseInitial: cachePauseInitial,
    cachePauseWaitSeconds: cachePauseWaitSeconds,
    networkTimeoutSeconds: networkTimeoutSeconds,
    startTimeoutSeconds: startTimeoutSeconds,
    configuredSeconds: normalized,
  );
}

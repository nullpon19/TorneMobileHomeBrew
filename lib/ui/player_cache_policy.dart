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

/// Minimum free storage space preserved when sizing mpv's disk cache (1 GiB).
const int minFreeDiskReserveBytes = 1024 * 1024 * 1024;

/// Comfort headroom target used when highlighting the recommended buffer tier.
const int recommendedFreeDiskReserveBytes = 1536 * 1024 * 1024;

/// Worst-case DR (元画質) MPEG-2 TS disk consumption estimate per minute.
const int drDiskMibPerMinute = 110;

/// Video hardware/software decoding preference for compatibility with older SoCs.
enum VideoHwdecMode {
  /// Default `auto-safe` hardware acceleration.
  auto,

  /// Keep H.264/HEVC in hardware, force MPEG-2 (DR broadcasts) to software.
  mpeg2Software,

  /// Disable hardware decoding (`hwdec=no`) across all codecs.
  software,
}

/// Hardware-decode codec list excluding `mpeg2video` for legacy Fire TV devices
/// whose MediaCodec MPEG-2 decoder stalls on interlaced DR streams.
const String mpeg2SoftwareHwdecCodecs = 'h264,hevc,mpeg4,vp8,vp9,av1';

/// Short label displayed on the Settings tile trailing summary.
String videoHwdecModeShortLabel(VideoHwdecMode mode) {
  switch (mode) {
    case VideoHwdecMode.auto:
      return '標準（自動）';
    case VideoHwdecMode.mpeg2Software:
      return 'MPEG-2 のみSW';
    case VideoHwdecMode.software:
      return 'すべてSW';
  }
}

/// Full option label displayed in the Settings picker dialog.
String videoHwdecModeLabel(VideoHwdecMode mode) {
  switch (mode) {
    case VideoHwdecMode.auto:
      return '標準（自動 / ハードウェア優先）';
    case VideoHwdecMode.mpeg2Software:
      return 'MPEG-2 のみソフトウェア（旧世代 DR 対策）';
    case VideoHwdecMode.software:
      return 'すべてソフトウェア（互換優先）';
  }
}

/// Concise helper text shown below each option or in the Settings summary.
String videoHwdecModeDescription(VideoHwdecMode mode) {
  switch (mode) {
    case VideoHwdecMode.auto:
      return '通常はこちら（Fire OS 8 等はハードウェア再生）';
    case VideoHwdecMode.mpeg2Software:
      return '元画質 (DR) の黒画面対策・モバイル画質はハードウェアのまま';
    case VideoHwdecMode.software:
      return '映像デコードで固まる場合の最終手段（負荷増）';
  }
}

/// Estimated total disk cache footprint (forward + backward) in bytes using DR
/// headroom so storage-tight devices stay protected.
int estimateBufferDiskBytes({required bool live, required int bufferSeconds}) {
  if (bufferSeconds <= 0) return 0;
  if (!live && bufferSeconds < 60) return 0;
  final forward = math.max(
    14 * 1024 * 1024,
    ((bufferSeconds * drDiskMibPerMinute) ~/ 60) * 1024 * 1024,
  );
  final back = live
      ? 2 * 1024 * 1024
      : math.max(
          4 * 1024 * 1024,
          math.min(forward ~/ 4, maxDiskBackCacheBytes),
        );
  return forward + back;
}

/// Classification of a buffer duration option relative to free storage.
enum BufferOptionTier { recommended, available, insufficientStorage }

/// Storage-aware evaluation result for one buffer duration option.
class BufferOptionEvaluation {
  const BufferOptionEvaluation({
    required this.seconds,
    required this.estimatedDiskBytes,
    required this.tier,
  });

  final int seconds;
  final int estimatedDiskBytes;
  final BufferOptionTier tier;

  bool get selectable => tier != BufferOptionTier.insufficientStorage;
  bool get isRecommended => tier == BufferOptionTier.recommended;
}

/// Formats byte sizes concisely for Fire TV settings dialogs (`GB` / `MB`).
String formatStorageBytes(int bytes) {
  const gib = 1024 * 1024 * 1024;
  if (bytes >= gib) {
    return '${(bytes / gib).toStringAsFixed(1)} GB';
  }
  return '${(bytes / (1024 * 1024)).round()} MB';
}

/// Evaluates each candidate buffer duration against [availableDiskBytes] using
/// DR-basis estimates and a strict 1 GiB minimum free reserve.
List<BufferOptionEvaluation> evaluateBufferOptions({
  required List<int> options,
  required bool live,
  required int? availableDiskBytes,
}) {
  final estimates = <int, int>{
    for (final opt in options)
      opt: estimateBufferDiskBytes(live: live, bufferSeconds: opt),
  };

  bool isSelectable(int opt) {
    if (availableDiskBytes == null) return true;
    final est = estimates[opt]!;
    if (est == 0) return true;
    return (availableDiskBytes - est) >= minFreeDiskReserveBytes;
  }

  int? recommendedSeconds;
  if (availableDiskBytes != null) {
    if (live) {
      recommendedSeconds = options.contains(0)
          ? 0
          : options.firstWhere(isSelectable, orElse: () => options.first);
    } else {
      for (final opt in options) {
        if (opt > defaultRecordedBufferSeconds) continue;
        final est = estimates[opt]!;
        if (est > 0 &&
            isSelectable(opt) &&
            (availableDiskBytes - est) >= recommendedFreeDiskReserveBytes) {
          recommendedSeconds = opt;
        }
      }
      if (recommendedSeconds == null) {
        for (final opt in options) {
          if (opt <= defaultRecordedBufferSeconds &&
              estimates[opt] == 0 &&
              isSelectable(opt)) {
            recommendedSeconds = opt;
          }
        }
      }
      recommendedSeconds ??= options.firstWhere(
        isSelectable,
        orElse: () => options.first,
      );
    }
  }

  return [
    for (final opt in options)
      BufferOptionEvaluation(
        seconds: opt,
        estimatedDiskBytes: estimates[opt]!,
        tier: !isSelectable(opt)
            ? BufferOptionTier.insufficientStorage
            : (opt == recommendedSeconds
                  ? BufferOptionTier.recommended
                  : BufferOptionTier.available),
      ),
  ];
}

/// Upper bound on forward disk cache size (~60 min of mobile stream, < 2 GiB).
const int maxDiskCacheBytes = 1200 * 1024 * 1024;

/// Upper bound on backward disk cache size (~8-10 min for offline rewind).
const int maxDiskBackCacheBytes = 150 * 1024 * 1024;

/// Initial FFmpeg/mpv stream-analysis duration cap for live MPEG-TS startup.
const double liveDemuxerAnalyzeDurationSeconds = 1.5;

/// Initial FFmpeg/mpv probe-size cap for live MPEG-TS startup by quality tier.
int liveDemuxerProbeSizeBytes({required bool useMobile}) =>
    useMobile ? 512 * 1024 : 2 * 1024 * 1024;

/// Human-readable Japanese label for a buffer duration in seconds.
String formatBufferDurationLabel(int seconds) {
  if (seconds <= 0) return '標準 (0秒)';
  if (seconds < 60) return '$seconds秒';
  return '${seconds ~/ 60}分';
}

/// Live pause timeshift target (seconds) buffered in the background so paused
/// viewers can resume with variable-speed catch-up without startup delay.
const int livePauseTimeshiftSeconds = 300;

/// Returns the playback speed multiplier for catching up from a paused live
/// offset, applying light hysteresis on downward transitions to prevent speed
/// chattering.
double liveCatchUpSpeedForLagSeconds(
  double lagSeconds, {
  double? currentRate,
}) {
  if (lagSeconds <= 1.5) return 1.0;
  if (currentRate != null) {
    if (currentRate >= 2.0 && lagSeconds > 115.0) return 2.0;
    if (currentRate >= 1.5 && lagSeconds > 25.0 && lagSeconds <= 120.0) {
      return 1.5;
    }
    if (currentRate >= 1.25 && lagSeconds > 1.5 && lagSeconds <= 30.0) {
      return 1.25;
    }
  }
  if (lagSeconds > 120.0) return 2.0;
  if (lagSeconds > 30.0) return 1.5;
  return 1.25;
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
    this.cachePause = true,
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
  final bool cachePause;
}

/// Computes RAM vs disk cache limits, pre-buffer wait, and timeouts safely.
MpvBufferPlan computeMpvBufferPlan({
  required bool live,
  required int bufferSeconds,
  required bool isAndroid,
  int? availableDiskBytes,
  String? cacheDirPath,
  bool liveUseMobile = true,
}) {
  final normalized = bufferSeconds < 0 ? 0 : bufferSeconds;
  final effectiveTargetSeconds = live
      ? math.max(normalized, livePauseTimeshiftSeconds)
      : normalized;
  var useDiskCache =
      (live || normalized >= 60) &&
      cacheDirPath != null &&
      cacheDirPath.isNotEmpty;

  final int demuxerMaxBytes;
  if (effectiveTargetSeconds == 0) {
    demuxerMaxBytes = effectiveRecordingDemuxerMaxBytes(isAndroid: isAndroid);
  } else {
    // Mobile TS bitrate is ~11-15 MiB/min (headroom 21 MiB/min); DR is ~90-100
    // Mbps (headroom 110 MiB/min for 5-minute background live pause timeshift).
    final mibPerMinute = (live && !liveUseMobile) ? 110 : 21;
    final minFloor = effectiveTargetSeconds <= 15
        ? 8 * 1024 * 1024
        : 14 * 1024 * 1024;
    final scaled =
        ((effectiveTargetSeconds * mibPerMinute) ~/ 60) * 1024 * 1024;
    final rawTarget = math.min(
      math.max(minFloor, scaled),
      maxDiskCacheBytes,
    );
    if (useDiskCache && availableDiskBytes != null) {
      final safeLimit = availableDiskBytes - minFreeDiskReserveBytes;
      if (safeLimit <= 20 * 1024 * 1024) {
        // Low storage fallback: disable disk cache and keep a small RAM budget.
        useDiskCache = false;
        demuxerMaxBytes = math.min(rawTarget, 24 * 1024 * 1024);
      } else {
        final int backBudget;
        if (live) {
          backBudget = 2 * 1024 * 1024;
        } else {
          backBudget = math.max(
            4 * 1024 * 1024,
            math.min(math.min(rawTarget, safeLimit) ~/ 5, maxDiskBackCacheBytes),
          );
        }
        final forwardCap = math.max(14 * 1024 * 1024, safeLimit - backBudget);
        demuxerMaxBytes = math.min(rawTarget, forwardCap);
      }
    } else if (!useDiskCache) {
      demuxerMaxBytes = math.min(rawTarget, 48 * 1024 * 1024);
    } else {
      demuxerMaxBytes = rawTarget;
    }
  }

  final int demuxerMaxBackBytes;
  if (live) {
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

  final readaheadSeconds = live
      ? math.max(normalized + 15, livePauseTimeshiftSeconds)
      : (normalized > 0 ? normalized + 15 : 20);
  final cachePauseInitial = normalized > 0;
  final cachePause = !live || normalized > 0;
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
    useCache: true,
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
    cachePause: cachePause,
  );
}

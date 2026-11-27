/// Session coordinator for Niconico Jikkyo Live streaming (including 5-minute
/// timeshift replay) and Recorded Kakolog chunked sync + momentum histogram
/// generation (Phase 40).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'jikkyo_channel_mapper.dart';
import 'jikkyo_client.dart';
import 'jikkyo_models.dart';

class JikkyoPlaybackController {
  JikkyoPlaybackController({
    required this._client,
    this.onStateChanged,
    this.retryBackoff = const Duration(seconds: 15),
  });

  final JikkyoClient _client;
  final void Function()? onStateChanged;
  final Duration retryBackoff;

  static const int recordedChunkSeconds = 1200; // 20-minute chunk
  static const int maxCachedBodyChunks = 3;
  static const int maxLiveBufferItems = 4000;
  static const int liveRetentionMs = 7 * 60 * 1000;

  bool _disposed = false;
  bool _isLive = false;
  int _sessionGen = 0;
  String? _jkId;

  // Live state
  JikkyoLiveConnection? _liveConn;
  bool _liveConnected = false;
  JikkyoChannelLiveInfo? _liveChannelInfo;
  String _latestNasneTitle = '';
  bool _programLikelyDifferent = false;
  Timer? _liveMetaRefreshTimer;
  final List<JikkyoComment> _liveBuffer = [];
  final Set<String> _liveSeenKeys = <String>{};
  int? _lastCursorMs;

  // Recorded state
  DateTime? _recordedStart;
  Duration _recordedDuration = Duration.zero;
  int _bucketSeconds = 60;
  List<int> _momentumBuckets = const [];
  final Set<int> _countedChunkIndices = <int>{};
  final LinkedHashMap<int, List<JikkyoComment>> _chunkBodyCache =
      LinkedHashMap<int, List<JikkyoComment>>();
  final Set<int> _loadingChunks = <int>{};
  final Set<int> _keepBodyRequestedChunks = <int>{};
  final Map<int, DateTime> _chunkRetryAfter = <int, DateTime>{};
  bool _momentumLoading = false;
  bool _recordedLoadedAny = false;
  int _totalCommentCount = 0;

  String? get jkId => _jkId;
  bool get isLive => _isLive;
  bool get liveConnected => _liveConnected;
  JikkyoChannelLiveInfo? get liveChannelInfo => _liveChannelInfo;
  String? get jikkyoProgramTitle => _liveChannelInfo?.programPresent?.title;
  int get jikkyoForce => _liveChannelInfo?.jikkyoForce ?? 0;
  bool get isProgramLikelyDifferent => _programLikelyDifferent;

  List<int> get momentumBuckets => _momentumBuckets;
  bool get momentumLoading => _momentumLoading;
  bool get recordedLoadedAny => _recordedLoadedAny;
  int get totalCommentCount => _totalCommentCount;

  void _notify() {
    if (!_disposed) {
      onStateChanged?.call();
    }
  }

  void startLive({
    required String jkId,
    String initialNasneTitle = '',
  }) {
    _resetSessionState();
    _isLive = true;
    _jkId = jkId;
    _latestNasneTitle = initialNasneTitle;

    unawaited(_refreshLiveChannelInfo());
    _liveMetaRefreshTimer = Timer.periodic(
      const Duration(seconds: 90),
      (_) => unawaited(_refreshLiveChannelInfo(forceRefresh: true)),
    );

    _liveConn = _client.connectLive(
      jkId: jkId,
      onComment: _handleIncomingLiveComment,
      onConnectionChanged: (connected) {
        if (_disposed) return;
        _liveConnected = connected;
        _notify();
      },
    );
    _notify();
  }

  void updateLiveProgramTitle(String nasneTitle) {
    if (_disposed || !_isLive) return;
    if (_latestNasneTitle == nasneTitle) return;
    _latestNasneTitle = nasneTitle;
    final nextDiff = _computeProgramDifferent();
    if (nextDiff != _programLikelyDifferent) {
      _programLikelyDifferent = nextDiff;
      _notify();
    }
  }

  bool _computeProgramDifferent() {
    final jkTitle = _liveChannelInfo?.programPresent?.title;
    if (jkTitle == null || jkTitle.trim().isEmpty) return false;
    if (_latestNasneTitle.trim().isEmpty) return false;
    return isJikkyoProgramLikelyDifferent(
      nasneTitle: _latestNasneTitle,
      jikkyoTitle: jkTitle,
    );
  }

  Future<void> _refreshLiveChannelInfo({bool forceRefresh = false}) async {
    final jkId = _jkId;
    final sessionGen = _sessionGen;
    if (_disposed || !_isLive || jkId == null) return;
    final map = await _client.fetchChannelsInfo(forceRefresh: forceRefresh);
    if (_disposed || !_isLive || sessionGen != _sessionGen || _jkId != jkId) {
      return;
    }
    final info = map[jkId];
    if (info != null) {
      _liveChannelInfo = info;
      _programLikelyDifferent = _computeProgramDifferent();
      _notify();
    }
  }

  void _handleIncomingLiveComment(JikkyoComment comment) {
    if (_disposed || !_isLive) return;
    final key = '${comment.no ?? -1}:${comment.timestampMs}:${comment.text}';
    if (!_liveSeenKeys.add(key)) return;

    // Insert keeping ascending timestamp order.
    if (_liveBuffer.isEmpty ||
        comment.timestampMs >= _liveBuffer.last.timestampMs) {
      _liveBuffer.add(comment);
    } else {
      var insertIdx = _liveBuffer.length;
      while (insertIdx > 0 &&
          _liveBuffer[insertIdx - 1].timestampMs > comment.timestampMs) {
        insertIdx--;
      }
      _liveBuffer.insert(insertIdx, comment);
    }

    // Prune older than retention window / max item cap.
    final cutoff = DateTime.now().millisecondsSinceEpoch - liveRetentionMs;
    while (_liveBuffer.length > maxLiveBufferItems ||
        (_liveBuffer.length > 50 && _liveBuffer.first.timestampMs < cutoff)) {
      final removed = _liveBuffer.removeAt(0);
      _liveSeenKeys.remove(
        '${removed.no ?? -1}:${removed.timestampMs}:${removed.text}',
      );
    }
  }

  /// Polls live comments matching [effectivePlaybackClock] (which tracks Live
  /// edge AND 5-minute timeshift rewind seamlessly).
  List<JikkyoComment> pollLiveComments({
    required DateTime effectivePlaybackClock,
    required int delaySeconds,
    int manualOffsetSeconds = 0,
  }) {
    if (_disposed || !_isLive) return const [];
    final targetMs =
        effectivePlaybackClock.millisecondsSinceEpoch -
        delaySeconds * 1000 +
        manualOffsetSeconds * 1000;

    final prev = _lastCursorMs;
    if (prev == null || (targetMs - prev).abs() > 3500) {
      // Initial join or timeshift jump: surface trailing 1.5s silently as starter.
      final starterCutoff = targetMs - 1500;
      _lastCursorMs = targetMs;
      return [
        for (final c in _liveBuffer)
          if (c.timestampMs > starterCutoff && c.timestampMs <= targetMs) c,
      ];
    }

    if (targetMs <= prev) {
      return const [];
    }
    _lastCursorMs = targetMs;
    return [
      for (final c in _liveBuffer)
        if (c.timestampMs > prev && c.timestampMs <= targetMs) c,
    ];
  }

  void startRecorded({
    required String jkId,
    required DateTime scheduledStart,
    required Duration duration,
  }) {
    _resetSessionState();
    _isLive = false;
    _jkId = jkId;
    _recordedStart = scheduledStart;
    _recordedDuration = duration;

    final totalSec = math.max(1, duration.inSeconds);
    _bucketSeconds = totalSec <= 5400 ? 30 : 60;
    final bucketCount = ((totalSec + _bucketSeconds - 1) ~/ _bucketSeconds)
        .clamp(1, 360);
    _momentumBuckets = List<int>.filled(bucketCount, 0);

    unawaited(_loadRecordedChunk(0, keepBody: true));
    unawaited(_prefetchMomentumRemainingChunks());
    _notify();
  }

  int _totalChunkCount() {
    final totalSec = _recordedDuration.inSeconds;
    if (totalSec <= 0) return 1;
    return math.max(1, (totalSec + recordedChunkSeconds - 1) ~/ recordedChunkSeconds);
  }

  Future<void> _loadRecordedChunk(
    int chunkIndex, {
    required bool keepBody,
  }) async {
    final jkId = _jkId;
    final start = _recordedStart;
    final sessionGen = _sessionGen;
    if (_disposed || _isLive || jkId == null || start == null) return;
    final totalChunks = _totalChunkCount();
    if (chunkIndex < 0 || chunkIndex >= totalChunks) return;
    if (keepBody && _chunkBodyCache.containsKey(chunkIndex)) {
      // Touch LRU position.
      final existing = _chunkBodyCache.remove(chunkIndex)!;
      _chunkBodyCache[chunkIndex] = existing;
      return;
    }
    if (!keepBody && _countedChunkIndices.contains(chunkIndex)) return;
    final retryAfter = _chunkRetryAfter[chunkIndex];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    if (keepBody) {
      _keepBodyRequestedChunks.add(chunkIndex);
    }
    if (!_loadingChunks.add(chunkIndex)) return;

    try {
      final chunkStartSec = chunkIndex * recordedChunkSeconds;
      final maxSec = _recordedDuration.inSeconds > 0
          ? _recordedDuration.inSeconds
          : recordedChunkSeconds;
      final chunkEndSec = math.min(maxSec, chunkStartSec + recordedChunkSeconds);
      if (chunkEndSec <= chunkStartSec) return;

      final List<JikkyoComment> rawComments;
      try {
        rawComments = await _client.fetchKakolog(
          jkId: jkId,
          startTime: start.add(Duration(seconds: chunkStartSec)),
          endTime: start.add(Duration(seconds: chunkEndSec)),
        );
      } catch (_) {
        if (!_disposed && sessionGen == _sessionGen) {
          _chunkRetryAfter[chunkIndex] = DateTime.now().add(retryBackoff);
        }
        return;
      }
      if (_disposed || _isLive || sessionGen != _sessionGen || _jkId != jkId) {
        return;
      }
      _chunkRetryAfter.remove(chunkIndex);

      final startMs = start.millisecondsSinceEpoch;
      final chunkStartMs = startMs + chunkStartSec * 1000;
      final chunkEndMs = startMs + chunkEndSec * 1000;
      final isLastChunk = chunkIndex == totalChunks - 1;
      final seenKeys = <String>{};
      final comments = <JikkyoComment>[];
      for (final c in rawComments) {
        final inRange = c.timestampMs >= chunkStartMs &&
            (isLastChunk
                ? c.timestampMs <= chunkEndMs
                : c.timestampMs < chunkEndMs);
        if (!inRange) continue;
        final key = '${c.no ?? -1}:${c.timestampMs}:${c.text}';
        if (seenKeys.add(key)) {
          comments.add(c);
        }
      }

      _recordedLoadedAny = true;
      if (_countedChunkIndices.add(chunkIndex) && _momentumBuckets.isNotEmpty) {
        final nextBuckets = List<int>.of(_momentumBuckets);
        final bucketMs = _bucketSeconds * 1000;
        for (final c in comments) {
          final relMs = c.timestampMs - startMs;
          if (relMs < 0) continue;
          final idx = (relMs ~/ bucketMs).clamp(0, nextBuckets.length - 1);
          nextBuckets[idx]++;
        }
        _momentumBuckets = List.unmodifiable(nextBuckets);
        _totalCommentCount += comments.length;
      }

      final shouldKeepBody =
          keepBody || _keepBodyRequestedChunks.remove(chunkIndex);
      if (shouldKeepBody) {
        _chunkBodyCache.remove(chunkIndex);
        _chunkBodyCache[chunkIndex] = comments;
        while (_chunkBodyCache.length > maxCachedBodyChunks) {
          _chunkBodyCache.remove(_chunkBodyCache.keys.first);
        }
      }
      _notify();
    } finally {
      if (sessionGen == _sessionGen) {
        _loadingChunks.remove(chunkIndex);
        _keepBodyRequestedChunks.remove(chunkIndex);
      }
    }
  }

  Future<void> _prefetchMomentumRemainingChunks() async {
    final sessionGen = _sessionGen;
    final totalChunks = _totalChunkCount();
    if (totalChunks <= 1) return;
    _momentumLoading = true;
    _notify();
    try {
      for (var i = 1; i < totalChunks; i++) {
        if (_disposed || _isLive || sessionGen != _sessionGen) break;
        if (!_countedChunkIndices.contains(i)) {
          await _loadRecordedChunk(i, keepBody: false);
          if (_disposed || _isLive || sessionGen != _sessionGen) break;
          await Future<void>.delayed(const Duration(milliseconds: 220));
        }
      }
    } finally {
      if (!_disposed && !_isLive && sessionGen == _sessionGen) {
        _momentumLoading = false;
        _notify();
      }
    }
  }

  /// Polls recorded comments matching playback [position] + [offsetSeconds].
  List<JikkyoComment> pollRecordedComments({
    required Duration position,
    int offsetSeconds = 0,
  }) {
    if (_disposed || _isLive || _recordedStart == null) return const [];
    final startMs = _recordedStart!.millisecondsSinceEpoch;
    final relMs = math.max(0, position.inMilliseconds + offsetSeconds * 1000);
    final chunkIdx = relMs ~/ (recordedChunkSeconds * 1000);
    unawaited(_loadRecordedChunk(chunkIdx, keepBody: true));
    // Preload next chunk 3 minutes before crossing chunk boundary.
    final remInChunkMs =
        ((chunkIdx + 1) * recordedChunkSeconds * 1000) - relMs;
    if (remInChunkMs <= 180 * 1000) {
      unawaited(_loadRecordedChunk(chunkIdx + 1, keepBody: true));
    }

    final targetMs = startMs + relMs;
    final prev = _lastCursorMs;
    if (!_chunkBodyCache.containsKey(chunkIdx)) {
      if (prev == null || targetMs < prev || (targetMs - prev) > 4000) {
        _lastCursorMs = targetMs;
      }
      return const [];
    }
    if (prev == null || targetMs < prev || (targetMs - prev) > 4000) {
      // First tick or seek jump: advance cursor without dumping stale comments.
      _lastCursorMs = targetMs;
      return const [];
    }
    if (targetMs <= prev) {
      return const [];
    }
    _lastCursorMs = targetMs;

    final seen = <String>{};
    final out = <JikkyoComment>[];
    for (final list in _chunkBodyCache.values) {
      for (final c in list) {
        if (c.timestampMs > prev && c.timestampMs <= targetMs) {
          final key = '${c.no ?? -1}:${c.timestampMs}:${c.text}';
          if (seen.add(key)) {
            out.add(c);
          }
        }
      }
    }
    if (out.length > 1) {
      out.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    }
    return out;
  }

  void _resetSessionState() {
    _sessionGen++;
    _liveMetaRefreshTimer?.cancel();
    _liveMetaRefreshTimer = null;
    final conn = _liveConn;
    _liveConn = null;
    if (conn != null) {
      unawaited(conn.dispose());
    }
    _liveConnected = false;
    _liveChannelInfo = null;
    _latestNasneTitle = '';
    _programLikelyDifferent = false;
    _liveBuffer.clear();
    _liveSeenKeys.clear();
    _lastCursorMs = null;

    _recordedStart = null;
    _recordedDuration = Duration.zero;
    _momentumBuckets = const [];
    _countedChunkIndices.clear();
    _chunkBodyCache.clear();
    _loadingChunks.clear();
    _keepBodyRequestedChunks.clear();
    _chunkRetryAfter.clear();
    _momentumLoading = false;
    _recordedLoadedAny = false;
    _totalCommentCount = 0;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _resetSessionState();
  }
}

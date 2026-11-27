/// Network client for NX-Jikkyo live WebSocket streams, channel metadata, and
/// jikkyo.tsukumijima.net Kakolog archive API (Phase 40).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'jikkyo_models.dart';

const String _kUserAgent = 'torne-hb-firetv/1.5';

class JikkyoFetchException implements Exception {
  const JikkyoFetchException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode != null
      ? 'JikkyoFetchException($statusCode): $message'
      : 'JikkyoFetchException: $message';
}

abstract class JikkyoLiveConnection {
  bool get isConnected;
  Future<void> dispose();
}

abstract class JikkyoClient {
  Future<Map<String, JikkyoChannelLiveInfo>> fetchChannelsInfo({
    bool forceRefresh = false,
  });

  Future<List<JikkyoComment>> fetchKakolog({
    required String jkId,
    required DateTime startTime,
    required DateTime endTime,
  });

  JikkyoLiveConnection connectLive({
    required String jkId,
    required void Function(JikkyoComment comment) onComment,
    void Function(bool connected)? onConnectionChanged,
  });

  void dispose();
}

/// Parsed instruction from an NX-Jikkyo `/ws/watch` frame.
class NxWatchDirective {
  const NxWatchDirective({
    this.replyPong = false,
    this.keepIntervalSec,
    this.messageServerUri,
    this.threadId,
  });

  final bool replyPong;
  final int? keepIntervalSec;
  final String? messageServerUri;
  final String? threadId;
}

NxWatchDirective? parseNxWatchMessage(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return null;
    final type = decoded['type']?.toString();
    final data = decoded['data'];
    switch (type) {
      case 'ping':
        return const NxWatchDirective(replyPong: true);
      case 'seat':
        if (data is Map) {
          final rawSec = data['keepIntervalSec'];
          final sec = rawSec is int ? rawSec : int.tryParse('$rawSec');
          return NxWatchDirective(
            keepIntervalSec: (sec != null && sec > 0) ? sec : 30,
          );
        }
        return const NxWatchDirective(keepIntervalSec: 30);
      case 'room':
        if (data is Map) {
          final ms = data['messageServer'];
          final uri = ms is Map ? ms['uri']?.toString() : null;
          final threadId = data['threadId']?.toString();
          if (uri != null &&
              uri.isNotEmpty &&
              threadId != null &&
              threadId.isNotEmpty) {
            return NxWatchDirective(
              messageServerUri: uri,
              threadId: threadId,
            );
          }
        }
    }
  } catch (_) {}
  return null;
}

JikkyoComment? parseNxCommentMessage(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return null;
    final chat = decoded['chat'];
    if (chat is! Map<String, dynamic>) return null;
    return JikkyoComment.fromChatJson(chat);
  } catch (_) {
    return null;
  }
}

class NxJikkyoClient implements JikkyoClient {
  NxJikkyoClient({
    this.baseApiUrl = 'https://nx-jikkyo.tsukumijima.net',
    this.kakologBaseUrl = 'https://jikkyo.tsukumijima.net',
  });

  final String baseApiUrl;
  final String kakologBaseUrl;

  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  Map<String, JikkyoChannelLiveInfo>? _channelsCache;
  DateTime? _channelsCachedAt;
  bool _disposed = false;

  @override
  Future<Map<String, JikkyoChannelLiveInfo>> fetchChannelsInfo({
    bool forceRefresh = false,
  }) async {
    if (_disposed) return const {};
    final cached = _channelsCache;
    final cachedAt = _channelsCachedAt;
    if (!forceRefresh &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(minutes: 3)) {
      return cached;
    }
    try {
      final uri = Uri.parse('$baseApiUrl/api/v1/channels');
      final req = await _httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      req.headers.set(HttpHeaders.userAgentHeader, _kUserAgent);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return cached ?? const {};
      }
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      final decoded = jsonDecode(body);
      if (decoded is! List) return cached ?? const {};
      final result = <String, JikkyoChannelLiveInfo>{};
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          try {
            final info = JikkyoChannelLiveInfo.fromJson(item);
            if (info != null) result[info.id] = info;
          } catch (_) {}
        }
      }
      if (result.isNotEmpty) {
        _channelsCache = Map.unmodifiable(result);
        _channelsCachedAt = DateTime.now();
      }
      return result.isNotEmpty ? result : (cached ?? const {});
    } catch (_) {
      return cached ?? const {};
    }
  }

  @override
  Future<List<JikkyoComment>> fetchKakolog({
    required String jkId,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    if (_disposed) return const [];
    final startSec = startTime.millisecondsSinceEpoch ~/ 1000;
    final endSec = endTime.millisecondsSinceEpoch ~/ 1000;
    if (endSec <= startSec) return const [];
    try {
      final uri = Uri.parse(
        '$kakologBaseUrl/api/kakolog/$jkId'
        '?starttime=$startSec&endtime=$endSec&format=json',
      );
      final req = await _httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      req.headers.set(HttpHeaders.userAgentHeader, _kUserAgent);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode == 404) {
        await res.drain<void>();
        return const [];
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw JikkyoFetchException(
          'HTTP ${res.statusCode}',
          statusCode: res.statusCode,
        );
      }
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 12));
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const JikkyoFetchException('invalid kakolog payload shape');
      }
      final packet = decoded['packet'];
      if (packet is! List) {
        throw const JikkyoFetchException('missing kakolog packet list');
      }
      final comments = <JikkyoComment>[];
      for (final item in packet) {
        if (item is Map<String, dynamic>) {
          final chat = item['chat'];
          if (chat is Map<String, dynamic>) {
            final comment = JikkyoComment.fromChatJson(chat);
            if (comment != null) comments.add(comment);
          }
        }
      }
      comments.sort((a, b) {
        final cmp = a.timestampMs.compareTo(b.timestampMs);
        if (cmp != 0) return cmp;
        return (a.no ?? 0).compareTo(b.no ?? 0);
      });
      return comments;
    } on JikkyoFetchException {
      rethrow;
    } catch (e) {
      throw JikkyoFetchException('kakolog fetch failed: $e');
    }
  }

  @override
  JikkyoLiveConnection connectLive({
    required String jkId,
    required void Function(JikkyoComment comment) onComment,
    void Function(bool connected)? onConnectionChanged,
  }) {
    final watchBase = baseApiUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final watchUri = '$watchBase/api/v1/channels/$jkId/ws/watch';
    return _NxJikkyoLiveConnection(
      watchUri: watchUri,
      onComment: onComment,
      onConnectionChanged: onConnectionChanged,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _httpClient.close(force: true);
    } catch (_) {}
  }
}

class _NxJikkyoLiveConnection implements JikkyoLiveConnection {
  _NxJikkyoLiveConnection({
    required this.watchUri,
    required this.onComment,
    this.onConnectionChanged,
  }) {
    unawaited(_connect());
  }

  final String watchUri;
  final void Function(JikkyoComment comment) onComment;
  final void Function(bool connected)? onConnectionChanged;

  static const List<int> _reconnectBackoffSec = [3, 6, 12, 20, 30, 60];

  bool _disposed = false;
  bool _connected = false;
  int _reconnectAttempts = 0;
  int _generation = 0;
  int _commentGeneration = 0;

  WebSocket? _watchSocket;
  WebSocket? _commentSocket;
  StreamSubscription<dynamic>? _watchSub;
  StreamSubscription<dynamic>? _commentSub;
  Timer? _keepSeatTimer;
  Timer? _reconnectTimer;
  Timer? _stableConnectionTimer;
  String? _currentThreadId;

  @override
  bool get isConnected => _connected;

  void _setConnected(bool next) {
    if (_connected == next) return;
    _connected = next;
    onConnectionChanged?.call(next);
  }

  Future<WebSocket> _connectWebSocket(
    String uri, {
    required Duration timeout,
    required bool Function() isStale,
  }) {
    final connectFuture = WebSocket.connect(
      uri,
      headers: {HttpHeaders.userAgentHeader: _kUserAgent},
    );
    var timedOut = false;
    unawaited(
      connectFuture.then(
        (ws) {
          if (timedOut || isStale()) {
            unawaited(ws.close().catchError((_) {}));
          }
        },
        onError: (_) {},
      ),
    );
    return connectFuture.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        throw TimeoutException('WebSocket connect timed out', timeout);
      },
    );
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final gen = ++_generation;
    await _closeSocketsOnly();
    if (_disposed || gen != _generation) return;

    try {
      final ws = await _connectWebSocket(
        watchUri,
        timeout: const Duration(seconds: 8),
        isStale: () => _disposed || gen != _generation,
      );
      if (_disposed || gen != _generation) {
        await ws.close();
        return;
      }
      _watchSocket = ws;
      ws.pingInterval = const Duration(seconds: 25);
      _watchSub = ws.listen(
        (event) {
          if (_disposed || gen != _generation) return;
          if (event is! String) return;
          final directive = parseNxWatchMessage(event);
          if (directive == null) return;
          if (directive.replyPong) {
            _safeSend(ws, '{"type":"pong"}');
          }
          if (directive.keepIntervalSec != null) {
            _keepSeatTimer?.cancel();
            _keepSeatTimer = Timer.periodic(
              Duration(seconds: math.max(10, directive.keepIntervalSec!)),
              (_) {
                if (!_disposed && gen == _generation) {
                  _safeSend(ws, '{"type":"keepSeat"}');
                }
              },
            );
          }
          if (directive.messageServerUri != null &&
              directive.threadId != null) {
            _currentThreadId = directive.threadId;
            unawaited(
              _connectCommentServer(
                uri: directive.messageServerUri!,
                threadId: directive.threadId!,
                gen: gen,
              ),
            );
          }
        },
        onError: (_) => _scheduleReconnect(gen),
        onDone: () => _scheduleReconnect(gen),
        cancelOnError: true,
      );
      _safeSend(
        ws,
        jsonEncode({
          'type': 'startWatching',
          'data': {'reconnect': _reconnectAttempts > 0},
        }),
      );
    } catch (_) {
      _scheduleReconnect(gen);
    }
  }

  Future<void> _connectCommentServer({
    required String uri,
    required String threadId,
    required int gen,
  }) async {
    if (_disposed || gen != _generation) return;
    final commentGen = ++_commentGeneration;
    _stableConnectionTimer?.cancel();
    _stableConnectionTimer = null;
    try {
      await _commentSub?.cancel();
      _commentSub = null;
      await _commentSocket?.close();
      _commentSocket = null;
    } catch (_) {}
    if (_disposed || gen != _generation || commentGen != _commentGeneration) {
      return;
    }

    try {
      final ws = await _connectWebSocket(
        uri,
        timeout: const Duration(seconds: 8),
        isStale: () =>
            _disposed || gen != _generation || commentGen != _commentGeneration,
      );
      if (_disposed || gen != _generation || commentGen != _commentGeneration) {
        await ws.close();
        return;
      }
      _commentSocket = ws;
      _setConnected(true);
      _stableConnectionTimer?.cancel();
      _stableConnectionTimer = Timer(const Duration(seconds: 15), () {
        if (!_disposed &&
            gen == _generation &&
            commentGen == _commentGeneration &&
            _connected) {
          _reconnectAttempts = 0;
        }
      });
      ws.pingInterval = const Duration(seconds: 25);
      _commentSub = ws.listen(
        (event) {
          if (_disposed ||
              gen != _generation ||
              commentGen != _commentGeneration) {
            return;
          }
          if (event is! String) return;
          final comment = parseNxCommentMessage(event);
          if (comment != null) {
            onComment(comment);
          }
        },
        onError: (_) {
          if (!_disposed &&
              gen == _generation &&
              commentGen == _commentGeneration) {
            _scheduleReconnect(gen);
          }
        },
        onDone: () {
          if (!_disposed &&
              gen == _generation &&
              commentGen == _commentGeneration) {
            _scheduleReconnect(gen);
          }
        },
        cancelOnError: true,
      );
      _safeSend(
        ws,
        jsonEncode([
          {'ping': {'content': 'rs:0'}},
          {'ping': {'content': 'ps:0'}},
          {
            'thread': {
              'thread': threadId,
              'version': '20061206',
              'user_id': 'guest',
              'res_from': -20,
              'with_global': 1,
              'scores': 1,
              'nicoru': 0,
            },
          },
          {'ping': {'content': 'pf:0'}},
          {'ping': {'content': 'rf:0'}},
        ]),
      );
    } catch (_) {
      if (!_disposed && gen == _generation && commentGen == _commentGeneration) {
        _scheduleReconnect(gen);
      }
    }
  }

  void _safeSend(WebSocket ws, String payload) {
    try {
      if (ws.readyState == WebSocket.open) {
        ws.add(payload);
      }
    } catch (_) {}
  }

  void _scheduleReconnect(int gen) {
    if (_disposed || gen != _generation) return;
    _stableConnectionTimer?.cancel();
    _stableConnectionTimer = null;
    _setConnected(false);
    if (_reconnectTimer != null) return;
    final idx = math.min(_reconnectAttempts, _reconnectBackoffSec.length - 1);
    _reconnectAttempts++;
    final delaySec = _reconnectBackoffSec[idx];
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      _reconnectTimer = null;
      if (!_disposed && gen == _generation) {
        unawaited(_connect());
      }
    });
  }

  Future<void> _closeSocketsOnly() async {
    _commentGeneration++;
    _stableConnectionTimer?.cancel();
    _stableConnectionTimer = null;
    _keepSeatTimer?.cancel();
    _keepSeatTimer = null;
    try {
      await _commentSub?.cancel();
    } catch (_) {}
    _commentSub = null;
    try {
      await _watchSub?.cancel();
    } catch (_) {}
    _watchSub = null;
    try {
      await _commentSocket?.close();
    } catch (_) {}
    _commentSocket = null;
    try {
      await _watchSocket?.close();
    } catch (_) {}
    _watchSocket = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _currentThreadId = null;
    _setConnected(false);
    await _closeSocketsOnly();
  }

  @override
  String toString() => 'NxJikkyoLiveConnection(thread=$_currentThreadId)';
}

/// WebAPI (JSON, port 64210) transport (plan 12.4).
///
/// GETs are unauthenticated; POST Set operations carry an
/// X-DTVToken computed by the injected [TokenProvider]. All failures
/// are converted to [NasneError] here, at the transport boundary.
///
/// An endpoint may override the port (plan 102): the
/// recorded-content write family lives on the unit's media
/// service, and the request must go there instead.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../endpoints.dart';
import '../errors.dart';
import '../token.dart';

class WebApiTransport {
  WebApiTransport(
    this.host, {
    http.Client? client,
    this.tokenProvider,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  static const int port = 64210;

  final String host;
  final TokenProvider? tokenProvider;
  final Duration timeout;
  final http.Client _client;

  Uri _uri(WebApiEndpoint endpoint, Map<String, String> params) {
    return Uri(
      scheme: 'http',
      host: host,
      port: endpoint.port ?? port,
      path: endpoint.path,
      queryParameters: params.isEmpty ? null : params,
    );
  }

  void _checkParams(WebApiEndpoint endpoint, Map<String, String> params) {
    for (final required in endpoint.requiredParams) {
      if (!params.containsKey(required)) {
        throw NasneError.validation(
          'webapi:${endpoint.path}',
          'missing required parameter "$required"',
        );
      }
    }
  }

  Future<http.Response> _sendWithAbort(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeoutOverride,
  }) async {
    final effectiveTimeout = timeoutOverride ?? timeout;
    final abortTrigger = Completer<void>();
    final timer = Timer(effectiveTimeout, () {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    });
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abortTrigger.future,
    );
    if (headers != null) request.headers.addAll(headers);
    if (body is String) {
      request.body = body;
    } else if (body is List<int>) {
      request.bodyBytes = body;
    }
    try {
      final streamed = await _client.send(request).timeout(effectiveTimeout);
      return await http.Response.fromStream(streamed).timeout(effectiveTimeout);
    } on TimeoutException {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  /// GET returning a decoded JSON object. Idempotent reads are
  /// retried a small number of times on reachability failures only.
  Future<Map<String, dynamic>> getJson(
    WebApiEndpoint endpoint, {
    Map<String, String> params = const {},
    Duration? timeoutOverride,
    int maxAttempts = 3,
  }) async {
    _checkParams(endpoint, params);
    const source = 'webapi';
    http.Response? lastError;
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final resp = await _sendWithAbort(
          'GET',
          _uri(endpoint, params),
          timeoutOverride: timeoutOverride,
        );
        return _decodeJson(endpoint, resp);
      } on NasneError {
        rethrow;
      } catch (e) {
        lastError = null;
        if (attempt == attempts - 1) {
          throw NasneError.unreachable('$source:${endpoint.path}', cause: e);
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    // Unreachable in practice; satisfies the analyzer.
    throw NasneError.unreachable('$source:${endpoint.path}',
        cause: lastError);
  }

  /// GET returning raw bytes (binary-response endpoints, plan 12.4).
  Future<List<int>> getBytes(
    WebApiEndpoint endpoint, {
    Map<String, String> params = const {},
  }) async {
    _checkParams(endpoint, params);
    try {
      final resp = await _sendWithAbort('GET', _uri(endpoint, params));
      if (resp.statusCode != 200) {
        throw _statusError(endpoint, resp);
      }
      return resp.bodyBytes;
    } on NasneError {
      rethrow;
    } catch (e) {
      throw NasneError.unreachable('webapi:${endpoint.path}', cause: e);
    }
  }

  /// POST with a form body. When the endpoint requires authentication
  /// the X-DTVToken header is attached (a [tokenProvider] must have
  /// been injected). Writes are never retried (plan 5.3 / 12.4).
  Future<Map<String, dynamic>> postJson(
    WebApiEndpoint endpoint, {
    Map<String, String> form = const {},
  }) async {
    _checkParams(endpoint, form);
    final body = Uri(queryParameters: form).query;
    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    if (endpoint.authRequired) {
      final tokens = tokenProvider;
      if (tokens == null) {
        throw NasneError.validation(
          'webapi:${endpoint.path}',
          'endpoint requires a token but no TokenProvider was injected',
        );
      }
      headers['X-DTVToken'] = tokens.tokenFor(endpoint.path, body);
    }
    try {
      final resp = await _sendWithAbort(
        'POST',
        _uri(endpoint, const {}),
        headers: headers,
        body: body,
      );
      return _decodeJson(endpoint, resp);
    } on NasneError {
      rethrow;
    } catch (e) {
      throw NasneError.unreachable('webapi:${endpoint.path}', cause: e);
    }
  }

  /// POST with a raw binary body (plan 21: `chEpg/EPGGet`). The
  /// Content-Type is exactly `application/binary` — the measured
  /// framework gate rejects anything else with 400 — and the
  /// X-DTVToken is computed over the raw body bytes.
  Future<List<int>> postBinary(
    WebApiEndpoint endpoint, {
    required List<int> body,
    Map<String, String> params = const {},
  }) async {
    _checkParams(endpoint, params);
    final headers = <String, String>{
      'Content-Type': 'application/binary',
    };
    if (endpoint.authRequired) {
      final tokens = tokenProvider;
      if (tokens == null) {
        throw NasneError.validation(
          'webapi:${endpoint.path}',
          'endpoint requires a token but no TokenProvider was injected',
        );
      }
      headers['X-DTVToken'] = tokens.tokenForBytes(endpoint.path, body);
    }
    try {
      final resp = await _sendWithAbort(
        'POST',
        _uri(endpoint, params),
        headers: headers,
        body: body,
      );
      if (resp.statusCode != 200) {
        throw _statusError(endpoint, resp);
      }
      return resp.bodyBytes;
    } on NasneError {
      rethrow;
    } catch (e) {
      throw NasneError.unreachable('webapi:${endpoint.path}', cause: e);
    }
  }

  Map<String, dynamic> _decodeJson(WebApiEndpoint endpoint, http.Response resp) {
    if (resp.statusCode != 200) {
      throw _statusError(endpoint, resp);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (e) {
      throw NasneError.parse('webapi:${endpoint.path}', cause: e);
    }
    if (decoded is! Map<String, dynamic>) {
      throw NasneError.parse('webapi:${endpoint.path}',
          cause: 'response is not a JSON object');
    }
    final errorCode = decoded['errorcode'];
    if (errorCode is num && errorCode != 0) {
      throw NasneError.webapi(errorCode.toInt(), 'webapi:${endpoint.path}');
    }
    return decoded;
  }

  NasneError _statusError(WebApiEndpoint endpoint, http.Response resp) {
    final source = 'webapi:${endpoint.path}';
    // A JSON errorcode, when present, is the more precise signal.
    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map && decoded['errorcode'] is num) {
        return NasneError.webapi(
            (decoded['errorcode'] as num).toInt(), source);
      }
    } catch (_) {
      // fall through to the status-based error
    }
    if (resp.statusCode == 400) {
      // Measured (plan 11.5): a POST without a valid token is rejected
      // with 400; treat 400 as a WebAPI-layer rejection.
      return NasneError(
        category: NasneErrorCategory.webapi,
        code: '400',
        source: source,
        messageKey: 'error.webapi',
        detail: 'HTTP 400 (bad parameters or missing/invalid token)',
      );
    }
    return NasneError.http(resp.statusCode, source);
  }
}

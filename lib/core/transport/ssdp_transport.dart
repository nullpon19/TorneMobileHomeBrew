/// SSDP transport: M-SEARCH send / response collection (plan 5.2).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors.dart';

/// One SSDP response datagram, parsed as HTTP-like headers.
class SsdpResponse {
  const SsdpResponse({required this.from, required this.headers});

  final InternetAddress from;

  /// Header names upper-cased.
  final Map<String, String> headers;

  String? get location => headers['LOCATION'];
  String? get searchTarget => headers['ST'];
  String? get server => headers['SERVER'];
}

/// Platform hook for OS-level multicast receive restrictions.
///
/// On Android, Wi-Fi multicast reception is filtered unless the app
/// holds a WifiManager.MulticastLock; the app layer supplies an
/// implementation backed by a platform channel (plan 17). Pure-Dart
/// interface so the core stays platform-free; implementations must
/// be best-effort and never throw.
abstract interface class MulticastLockGuard {
  Future<void> acquire();
  Future<void> release();
}

/// Sends M-SEARCH and collects responses. Pure dart:io, no platform
/// channels; OS-level multicast restrictions are handled through the
/// optional [MulticastLockGuard] hook (manual registration and the
/// subnet scan are the fallbacks, plan 5.2 / 16.3).
class SsdpTransport {
  const SsdpTransport({this.lockGuard});

  /// Held for the duration of [search] when provided.
  final MulticastLockGuard? lockGuard;

  static final InternetAddress multicastAddress =
      InternetAddress('239.255.255.250');
  static const int port = 1900;

  Future<List<SsdpResponse>> search(
    String searchTarget, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await lockGuard?.acquire();
    try {
      return await _search(searchTarget, timeout: timeout);
    } finally {
      await lockGuard?.release();
    }
  }

  Future<List<SsdpResponse>> _search(
    String searchTarget, {
    required Duration timeout,
  }) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    final responses = <SsdpResponse>[];
    final seen = <String>{};
    final done = Completer<void>();

    final request = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 3\r\n'
        'ST: $searchTarget\r\n'
        '\r\n';
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final activeSocket = socket;
      sub = activeSocket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = activeSocket.receive();
        if (datagram == null) return;
        final parsed = _parse(datagram);
        if (parsed == null) return;
        final key =
            '${parsed.from.address}|${parsed.location}|${parsed.searchTarget}';
        if (seen.add(key)) responses.add(parsed);
      }, onError: (_) {}, onDone: () {}, cancelOnError: false);

      activeSocket.send(utf8.encode(request), multicastAddress, port);
      // A second send improves reliability on lossy Wi-Fi.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      activeSocket.send(utf8.encode(request), multicastAddress, port);
      await Future<void>.delayed(timeout).whenComplete(() {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
    } catch (e) {
      throw NasneError.unreachable('ssdp:search', cause: e);
    } finally {
      await sub?.cancel();
      socket?.close();
    }
    return responses;
  }

  SsdpResponse? _parse(Datagram datagram) {
    final text = utf8.decode(datagram.data, allowMalformed: true);
    final lines = text.split('\r\n');
    if (lines.isEmpty || !lines.first.contains('200')) return null;
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      if (line.isEmpty) break;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers[line.substring(0, colon).trim().toUpperCase()] =
          line.substring(colon + 1).trim();
    }
    return SsdpResponse(from: datagram.address, headers: headers);
  }
}

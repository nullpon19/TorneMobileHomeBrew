/// Pure-Dart loopback HTTP tests for DtcpProxy unlimited auto-reconnect.
///
/// Kept separate from `testWidgets` files because `TestWidgetsFlutterBinding`
/// replaces `HttpOverrides.global` with a mock that returns HTTP 400.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmhb/core/core.dart';

import 'dtcp_kat.dart';

Uint8List _buildTestPcpPacket(Uint8List exchangeKey, Uint8List plaintext) {
  final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 9]);
  final derived = deriveContentKey(exchangeKey, 0x04, nonce);
  final paddedLen = (plaintext.length + 15) & ~15;
  final padded = Uint8List(paddedLen)
    ..setRange(0, plaintext.length, plaintext);
  final cipher = aesCbcEncrypt(derived.key, derived.iv, padded);
  final header = Uint8List(PcpHeader.size);
  header[0] = 0x04;
  header[1] = 0x2A;
  header.setRange(2, 10, nonce);
  header[10] = (plaintext.length >> 24) & 0xFF;
  header[11] = (plaintext.length >> 16) & 0xFF;
  header[12] = (plaintext.length >> 8) & 0xFF;
  header[13] = plaintext.length & 0xFF;
  return Uint8List.fromList([...header, ...cipher]);
}

void main() {
  group('DtcpProxy unlimited auto-reconnect', () {
    test('seekable proxy recovers across multiple mid-stream drops', () async {
      final exchangeKey = hexToBytes(katPcpExchangeKey);
      const totalBytes = 49152; // 256 * 192 MPEG-TTS aligned
      final fullPlaintext = Uint8List.fromList(
        List.generate(totalBytes, (i) => (i * 17 + 5) & 0xFF),
      );
      var upstreamAttempt = 0;
      var reauthCount = 0;

      // Raw ServerSocket lets attempt 1 drop mid-stream after headers are sent
      // (HttpServerResponse throws if detached after flush).
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) async {
        upstreamAttempt++;
        final attempt = upstreamAttempt;
        final headerBuf = <int>[];
        final lines = <String>[];
        await for (final chunk in socket) {
          headerBuf.addAll(chunk);
          final text = String.fromCharCodes(headerBuf);
          if (text.contains('\r\n\r\n')) {
            lines.addAll(text.split('\r\n'));
            break;
          }
        }
        if (attempt == 1) {
          // Send first 12288 bytes (64 * 192) cleanly, then drop connection.
          final packet = _buildTestPcpPacket(
            exchangeKey,
            Uint8List.sublistView(fullPlaintext, 0, 12288),
          );
          socket.write(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/x-dtcp1\r\n'
            'Content-Length: ${packet.length * 2}\r\n\r\n',
          );
          socket.add(packet);
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          socket.destroy();
          return;
        }
        if (attempt <= 4) {
          // Simulate prolonged network outage (3 consecutive errors).
          socket.write(
            'HTTP/1.1 503 Service Unavailable\r\n'
            'Connection: close\r\n'
            'Content-Length: 0\r\n\r\n',
          );
          await socket.flush();
          await socket.close();
          return;
        }
        // Signal restored: serve remainder from TimeSeekRange start byte.
        final hasSeek = lines.any(
          (l) => l.toLowerCase().startsWith('timeseekrange.dlna.org:'),
        );
        expect(hasSeek, isTrue);
        final body = _buildTestPcpPacket(
          exchangeKey,
          Uint8List.sublistView(fullPlaintext, 12288, totalBytes),
        );
        socket.write(
          'HTTP/1.1 200 OK\r\n'
          'Connection: close\r\n'
          'Content-Type: application/x-dtcp1\r\n'
          'TimeSeekRange.dlna.org: npt=4.000-20.000/20.000 bytes=12288-${totalBytes - 1}/$totalBytes\r\n'
          'Content-Length: ${body.length}\r\n\r\n',
        );
        socket.add(body);
        await socket.flush();
        await socket.close();
      });

      final diag = DiagLog(
        (cat, msg) => printOnFailure('[$cat] $msg'),
        (_) => true,
      );
      final fetcher = DtcpMediaFetcher(diag: diag);
      addTearDown(fetcher.close);
      final proxy = await DtcpProxy.start(
        contentUrl: Uri.parse('http://127.0.0.1:${server.port}/pvr'),
        keyForLabel: (_) async => exchangeKey,
        fetcher: fetcher,
        diag: diag,
        totalBytes: totalBytes,
        totalDuration: const Duration(seconds: 20),
        autoReconnect: true,
        onReauthenticate: () async {
          reauthCount++;
        },
        reconnectBackoff: const [Duration(milliseconds: 15)],
      );
      addTearDown(proxy.stop);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(proxy.uri);
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.ok);
      final received = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        received.add(chunk);
      }
      expect(received.toBytes(), fullPlaintext);
      expect(upstreamAttempt, 5);
      expect(reauthCount, greaterThanOrEqualTo(1));
    });

    test('live proxy auto-reconnects and allows resume reopen without 409', () async {
      final exchangeKey = hexToBytes(katPcpExchangeKey);
      final part1 = Uint8List.fromList(List.filled(4096, 0x31));
      final part2 = Uint8List.fromList(List.filled(4096, 0x62));
      final part3 = Uint8List.fromList(List.filled(4096, 0x73));
      var attempt = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        attempt++;
        if (attempt == 1) {
          request.response.statusCode = HttpStatus.ok;
          request.response.add(_buildTestPcpPacket(exchangeKey, part1));
          await request.response.close();
        } else if (attempt == 2) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
        } else if (attempt == 3) {
          request.response.statusCode = HttpStatus.ok;
          request.response.add(_buildTestPcpPacket(exchangeKey, part2));
          await request.response.flush();
          // Hold 3rd stream open slightly so reader sees part2, then finish.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await request.response.close();
        } else {
          // Continue streaming live packets while player reopens proxy URI.
          request.response.statusCode = HttpStatus.ok;
          request.response.add(_buildTestPcpPacket(exchangeKey, part3));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 120));
          try {
            await request.response.close();
          } catch (_) {}
        }
      });

      final diag = DiagLog(
        (cat, msg) => printOnFailure('[$cat] $msg'),
        (_) => true,
      );
      final fetcher = DtcpMediaFetcher(diag: diag);
      addTearDown(fetcher.close);
      final proxy = await DtcpProxy.start(
        contentUrl: Uri.parse('http://127.0.0.1:${server.port}/live'),
        keyForLabel: (_) async => exchangeKey,
        fetcher: fetcher,
        diag: diag,
        isLive: true,
        autoReconnect: true,
        reconnectBackoff: const [Duration(milliseconds: 15)],
      );
      addTearDown(proxy.stop);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req1 = await client.getUrl(proxy.uri);
      final resp1 = await req1.close();
      expect(resp1.statusCode, HttpStatus.ok);

      final collected = <int>[];
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = resp1.listen((chunk) {
        collected.addAll(chunk);
        if (collected.length >= part1.length + part2.length &&
            !done.isCompleted) {
          done.complete();
        }
      });
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(
        collected.sublist(0, part1.length + part2.length),
        [...part1, ...part2],
      );

      // Simulate player-side _resume() reopening the same proxy URI (must not 409).
      final req2 = await client.getUrl(proxy.uri);
      final resp2 = await req2.close();
      expect(resp2.statusCode, HttpStatus.ok);
      final reopenedChunk = await resp2.first.timeout(
        const Duration(seconds: 5),
      );
      expect(reopenedChunk, isNotEmpty);
    });

    test(
      'seekable proxy closes cleanly as EOF when actual bytes are slightly shorter than declared totalBytes',
      () async {
        final exchangeKey = hexToBytes(katPcpExchangeKey);
        const totalBytes = 49152;
        const actualBytes = 45056;
        final fullPlaintext = Uint8List.fromList(
          List.generate(totalBytes, (i) => (i * 13 + 3) & 0xFF),
        );
        final truncatedPacket = _buildTestPcpPacket(
          exchangeKey,
          Uint8List.sublistView(fullPlaintext, 0, actualBytes),
        );
        var upstreamAttempt = 0;
        var reauthCount = 0;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          upstreamAttempt++;
          if (upstreamAttempt == 1) {
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = ContentType(
              'application',
              'x-dtcp1',
            );
            request.response.contentLength = truncatedPacket.length;
            request.response.add(truncatedPacket);
            await request.response.close();
          } else {
            // Confirmation probe at EOF byte returns empty tail cleanly.
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.set(
              'TimeSeekRange.dlna.org',
              'npt=18.000-18.000/18.000 bytes=$actualBytes-${totalBytes - 1}/$totalBytes',
            );
            request.response.contentLength = 0;
            await request.response.close();
          }
        });

        final diag = DiagLog(
          (cat, msg) => printOnFailure('[$cat] $msg'),
          (_) => true,
        );
        final fetcher = DtcpMediaFetcher(diag: diag);
        addTearDown(fetcher.close);
        final proxy = await DtcpProxy.start(
          contentUrl: Uri.parse('http://127.0.0.1:${server.port}/pvr'),
          keyForLabel: (_) async => exchangeKey,
          fetcher: fetcher,
          diag: diag,
          totalBytes: totalBytes,
          totalDuration: const Duration(seconds: 20),
          autoReconnect: true,
          onReauthenticate: () async {
            reauthCount++;
          },
          reconnectBackoff: const [Duration(milliseconds: 500)],
        );
        addTearDown(proxy.stop);

        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final req = await client.getUrl(proxy.uri);
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);

        final received = BytesBuilder(copy: false);
        try {
          await for (final chunk in resp.timeout(const Duration(seconds: 3))) {
            received.add(chunk);
          }
        } on HttpException {
          // Expected when declared Content-Length (49152) exceeds actual EOF (45056).
        }
        expect(
          received.toBytes(),
          Uint8List.sublistView(fullPlaintext, 0, actualBytes),
        );
        expect(upstreamAttempt, lessThanOrEqualTo(2));
        expect(reauthCount, 0);

        // Subsequent range requests at or beyond observed _eofByte return 416.
        final tailReq = await client.getUrl(proxy.uri);
        tailReq.headers.set('Range', 'bytes=$actualBytes-${totalBytes - 1}');
        final tailResp = await tailReq.close();
        await tailResp.drain<void>();
        expect(tailResp.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(tailResp.headers.value('content-range'), 'bytes */$actualBytes');
      },
    );

    test(
      'non-seekable recorded proxy (isLive: false) ends cleanly at EOF without reconnecting',
      () async {
        final exchangeKey = hexToBytes(katPcpExchangeKey);
        final payload = Uint8List.fromList(
          List.generate(4096, (i) => (i * 7 + 1) & 0xFF),
        );
        final packet = _buildTestPcpPacket(exchangeKey, payload);
        var upstreamAttempt = 0;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          upstreamAttempt++;
          request.response.statusCode = HttpStatus.ok;
          request.response.contentLength = packet.length;
          request.response.add(packet);
          await request.response.close();
        });

        final diag = DiagLog(
          (cat, msg) => printOnFailure('[$cat] $msg'),
          (_) => true,
        );
        final fetcher = DtcpMediaFetcher(diag: diag);
        addTearDown(fetcher.close);
        final proxy = await DtcpProxy.start(
          contentUrl: Uri.parse('http://127.0.0.1:${server.port}/mobile_pvr'),
          keyForLabel: (_) async => exchangeKey,
          fetcher: fetcher,
          diag: diag,
          isLive: false,
          autoReconnect: true,
          reconnectBackoff: const [Duration(milliseconds: 15)],
        );
        addTearDown(proxy.stop);

        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final req = await client.getUrl(proxy.uri);
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        final received = BytesBuilder(copy: false);
        await for (final chunk in resp.timeout(const Duration(seconds: 3))) {
          received.add(chunk);
        }
        expect(received.toBytes(), payload);
        expect(upstreamAttempt, 1);
      },
    );

    test(
      'live proxy responds HEAD and Range probes without breaking active GET stream and resetToLiveEdge flushes backlog',
      () async {
        final exchangeKey = hexToBytes(katPcpExchangeKey);
        final stalePart = Uint8List.fromList(List.filled(4096, 0x41));
        final liveEdgePart = Uint8List.fromList(List.filled(4096, 0x5A));
        var upstreamAttempt = 0;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          upstreamAttempt++;
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'application',
            'x-dtcp1',
          );
          if (upstreamAttempt == 1) {
            request.response.add(_buildTestPcpPacket(exchangeKey, stalePart));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 600));
            try {
              await request.response.close();
            } catch (_) {}
          } else {
            request.response.add(_buildTestPcpPacket(exchangeKey, liveEdgePart));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 120));
            try {
              await request.response.close();
            } catch (_) {}
          }
        });

        final diag = DiagLog(
          (cat, msg) => printOnFailure('[$cat] $msg'),
          (_) => true,
        );
        final fetcher = DtcpMediaFetcher(diag: diag);
        addTearDown(fetcher.close);
        final proxy = await DtcpProxy.start(
          contentUrl: Uri.parse('http://127.0.0.1:${server.port}/live'),
          keyForLabel: (_) async => exchangeKey,
          fetcher: fetcher,
          diag: diag,
          isLive: true,
          autoReconnect: true,
          reconnectBackoff: const [Duration(milliseconds: 20)],
        );
        addTearDown(proxy.stop);

        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        // 1. Primary GET (with FFmpeg's default `Range: bytes=0-`) begins streaming stalePart as 200 OK.
        final req1 = await client.getUrl(proxy.uri);
        req1.headers.set('Range', 'bytes=0-');
        final resp1 = await req1.close();
        expect(resp1.statusCode, HttpStatus.ok);
        expect(resp1.headers.value('accept-ranges'), 'none');

        final streamBytes = <int>[];
        final firstGot = Completer<void>();
        final streamClosed = Completer<void>();
        late StreamSubscription<List<int>> sub1;
        sub1 = resp1.listen(
          (chunk) {
            streamBytes.addAll(chunk);
            if (streamBytes.length >= stalePart.length &&
                !firstGot.isCompleted) {
              firstGot.complete();
            }
          },
          onDone: () {
            if (!streamClosed.isCompleted) streamClosed.complete();
          },
          onError: (_) {
            if (!streamClosed.isCompleted) streamClosed.complete();
          },
        );
        addTearDown(sub1.cancel);
        await firstGot.future.timeout(const Duration(seconds: 5));
        expect(streamBytes.sublist(0, stalePart.length), stalePart);

        // 2. Concurrent HEAD & non-zero Range seek probe must return
        //    Accept-Ranges: none / 416 WITHOUT terminating resp1 or reopening upstream!
        final headReq = await client.headUrl(proxy.uri);
        final headResp = await headReq.close();
        await headResp.drain<void>();
        expect(headResp.statusCode, HttpStatus.ok);
        expect(headResp.headers.value('accept-ranges'), 'none');

        final rangeReq = await client.getUrl(proxy.uri);
        rangeReq.headers.set('Range', 'bytes=1024-2047');
        final rangeResp = await rangeReq.close();
        await rangeResp.drain<void>();
        expect(rangeResp.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(rangeResp.headers.value('accept-ranges'), 'none');
        expect(upstreamAttempt, 1);
        expect(streamClosed.isCompleted, isFalse);

        // 3. resetToLiveEdge flushes old stream and opens fresh upstream attempt.
        await proxy.resetToLiveEdge();
        await streamClosed.future.timeout(const Duration(seconds: 3));

        final edgeUri = proxy.uri.replace(queryParameters: {'live_edge': '1'});
        final req2 = await client.getUrl(edgeUri);
        final resp2 = await req2.close();
        expect(resp2.statusCode, HttpStatus.ok);
        final receivedEdge = BytesBuilder(copy: false);
        await for (final chunk in resp2.timeout(const Duration(seconds: 5))) {
          receivedEdge.add(chunk);
          if (receivedEdge.length >= liveEdgePart.length) break;
        }
        expect(
          receivedEdge.toBytes().sublist(0, liveEdgePart.length),
          liveEdgePart,
        );
        expect(upstreamAttempt, greaterThanOrEqualTo(2));
      },
    );

    test(
      'live proxy fails fast after maxInitialReconnectAttempts on 0-byte upstream failures and exposes diagnostics',
      () async {
        final exchangeKey = hexToBytes(katPcpExchangeKey);
        var upstreamAttempt = 0;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          upstreamAttempt++;
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.headers.contentType = ContentType.text;
          request.response.write('busy-$upstreamAttempt');
          await request.response.close();
        });

        final diag = DiagLog(
          (cat, msg) => printOnFailure('[$cat] $msg'),
          (_) => true,
        );
        final fetcher = DtcpMediaFetcher(diag: diag);
        addTearDown(fetcher.close);
        final proxy = await DtcpProxy.start(
          contentUrl: Uri.parse('http://127.0.0.1:${server.port}/live_fail'),
          keyForLabel: (_) async => exchangeKey,
          fetcher: fetcher,
          diag: diag,
          isLive: true,
          autoReconnect: true,
          maxInitialReconnectAttempts: 3,
          reconnectBackoff: const [Duration(milliseconds: 10)],
        );
        addTearDown(proxy.stop);

        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        // Wait briefly for the bounded initial attempts (1 initial + 3 retries = 4).
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(upstreamAttempt, 4);
        expect(proxy.cipherBytes, 0);
        expect(proxy.plaintextBytes, 0);
        expect(proxy.servedBytes, 0);
        expect(proxy.lastUpstreamError, isA<NasneError>());

        // Downstream GET observes 502 once queue is closed with the initial error.
        final req = await client.getUrl(proxy.uri);
        final resp = await req.close();
        await resp.drain<void>();
        expect(resp.statusCode, HttpStatus.badGateway);
        expect(proxy.downstreamRequestCount, 1);

        // Also verify DtcpMediaFetcher.openContent cleanly drains non-200 error bodies.
        await expectLater(
          fetcher.openContent(
            Uri.parse('http://127.0.0.1:${server.port}/direct_503'),
          ),
          throwsA(isA<NasneError>()),
        );
      },
    );
  });
}

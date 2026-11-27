/// Media fetcher HEAD tests (plan 28 regression).
///
/// Kept apart from dtcp_test.dart on purpose: that file uses
/// testWidgets, whose binding replaces HttpClient with a mock
/// that answers 400 to everything. These tests exercise the real
/// dart:io client against a local server.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmhb/core/core.dart';

void main() {
  group('media fetcher HEAD (plan 28 regression)', () {
    // Build 6 failed every playback start here: dart:io lowercases
    // Content-Type parameter names, so parameters['DTCP1HOST']
    // never matched. The fetcher now parses the raw header.
    Future<(HttpServer, Uri)> serve(
      void Function(HttpRequest request) respond,
    ) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        respond(request);
        await request.response.close();
      });
      return (server, Uri.parse('http://127.0.0.1:${server.port}/content'));
    }

    test('the measured nasne HEAD response yields the endpoint', () async {
      final (server, url) = await serve((request) {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/x-dtcp1; DTCP1HOST=192.168.11.129; '
          'DTCP1PORT=58293; CONTENTFORMAT="video/vnd.dlna.mpeg-tts"',
        );
      });
      final fetcher = DtcpMediaFetcher();
      final (host, port) = await fetcher.akeEndpoint(url);
      expect(host, '192.168.11.129');
      expect(port, 58293);
      fetcher.close();
      await server.close(force: true);
    });

    test('akeEndpoint retries transient HTTP 511/512/503 and succeeds on 200', () async {
      var attempts = 0;
      final (server, url) = await serve((request) {
        attempts++;
        if (attempts == 1) {
          request.response.statusCode = 511;
          return;
        }
        if (attempts == 2) {
          request.response.statusCode = 512;
          return;
        }
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/x-dtcp1; DTCP1HOST=192.0.2.10; DTCP1PORT=58293',
        );
      });
      final fetcher = DtcpMediaFetcher(
        headRetryDelays: const [
          Duration(milliseconds: 5),
          Duration(milliseconds: 5),
        ],
      );
      final (host, port) = await fetcher.akeEndpoint(url);
      expect(attempts, 3);
      expect(host, '192.0.2.10');
      expect(port, 58293);
      fetcher.close();
      await server.close(force: true);
    });

    test('akeEndpoint throws NasneError.http(511) when retries are exhausted', () async {
      var attempts = 0;
      final (server, url) = await serve((request) {
        attempts++;
        request.response.statusCode = 511;
        request.response.reasonPhrase = 'Custom Reason';
        request.response.headers.set('Server', 'MockNasne/1.0');
      });
      final fetcher = DtcpMediaFetcher(
        headRetryDelays: const [
          Duration(milliseconds: 5),
          Duration(milliseconds: 5),
        ],
      );
      await expectLater(
        fetcher.akeEndpoint(url.replace(queryParameters: {'quality': 'mobile'})),
        throwsA(
          isA<NasneError>()
              .having((e) => e.category, 'category', NasneErrorCategory.http)
              .having((e) => e.code, 'code', '511')
              .having((e) => e.detail, 'detail', contains('Custom Reason'))
              .having((e) => e.detail, 'detail', contains('quality=mobile'))
              .having((e) => e.detail, 'detail', contains('server=MockNasne/1.0')),
        ),
      );
      expect(attempts, 3);
      fetcher.close();
      await server.close(force: true);
    });

    test('a non-200 HEAD is an http error, not a missing endpoint',
        () async {
      final (server, url) = await serve((request) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/x-dtcp1; DTCP1HOST=192.168.11.129; DTCP1PORT=58293',
        );
      });
      final fetcher = DtcpMediaFetcher();
      await expectLater(
        fetcher.akeEndpoint(url),
        throwsA(
          isA<NasneError>().having(
            (e) => e.category,
            'category',
            NasneErrorCategory.http,
          ),
        ),
      );
      fetcher.close();
      await server.close(force: true);
    });

    test('a non-DTCP media type is a parse error', () async {
      final (server, url) = await serve((request) {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/html; charset=utf-8',
        );
      });
      final fetcher = DtcpMediaFetcher();
      await expectLater(
        fetcher.akeEndpoint(url),
        throwsA(
          isA<NasneError>().having(
            (e) => e.category,
            'category',
            NasneErrorCategory.parse,
          ),
        ),
      );
      fetcher.close();
      await server.close(force: true);
    });
  });
}

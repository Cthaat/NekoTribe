import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/endpoint_probe.dart';

void main() {
  test('a compatible ready response is required to report success', () {
    for (final (status, body, expected) in [
      (200, '{"status":"ready"}', EndpointReadiness.ready),
      (200, '{"status":"ok"}', EndpointReadiness.unsupported),
      (200, '<html>frontend</html>', EndpointReadiness.unsupported),
      (404, '', EndpointReadiness.unsupported),
      (503, '{"status":"unavailable"}', EndpointReadiness.unavailable),
      (503, '<html>proxy unavailable</html>', EndpointReadiness.unsupported),
      (503, '{"status":"ready"}', EndpointReadiness.unsupported),
      (405, '', EndpointReadiness.unsupported),
      (302, '', EndpointReadiness.unreachable),
      (401, '', EndpointReadiness.unreachable),
    ]) {
      expect(classifyEndpointReadiness(status, utf8.encode(body)), expected);
    }
  });

  test(
    'API and media probes use independent prefixes and omit credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String>[];
      server.listen((request) async {
        seen.add('${request.method} ${request.uri.path}');
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(request.cookies, isEmpty);
        if (request.method == 'HEAD') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.contentLength = 20;
        } else {
          request.response.write('{"status":"ready"}');
        }
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final result = await probeDeploymentEndpoints(
        AppConfig.fromCustom(
          apiBaseUrl: '$base/api-prefix',
          storageBaseUrl: '$base/media-prefix',
        ),
      );
      expect(result, (
        api: EndpointReadiness.ready,
        media: EndpointReadiness.ready,
      ));
      expect(
        seen,
        unorderedEquals([
          'GET /api-prefix/api/ready',
          'HEAD /media-prefix/storage/default-avatar.png',
        ]),
      );
    },
  );

  test('reads a bounded 503 body to identify backend unavailability', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.acceptHeader),
        'application/json',
      );
      request.response.statusCode = HttpStatus.serviceUnavailable;
      final body = switch (request.uri.path) {
        '/proxy/api/ready' => '<html>proxy unavailable</html>',
        '/oversized/api/ready' => '{"status":"unavailable"}${' ' * 4096}',
        _ => '{"status":"unavailable"}',
      };
      request.response.write(body);
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    expect(await probeEndpointReadiness(base), EndpointReadiness.unavailable);
    expect(
      await probeEndpointReadiness('$base/proxy'),
      EndpointReadiness.unsupported,
    );
    expect(
      await probeEndpointReadiness('$base/oversized'),
      EndpointReadiness.unreachable,
    );
  });

  test(
    'media requires positive PNG length and differentiates unavailability',
    () {
      expect(
        classifyMediaReadiness(200, 'image/png', '1'),
        EndpointReadiness.ready,
      );
      expect(
        classifyMediaReadiness(200, 'image/png', null),
        EndpointReadiness.unsupported,
      );
      expect(
        classifyMediaReadiness(200, 'image/png', '0'),
        EndpointReadiness.unsupported,
      );
      expect(
        classifyMediaReadiness(200, 'text/html', '20'),
        EndpointReadiness.unsupported,
      );
      expect(
        classifyMediaReadiness(503, null, null),
        EndpointReadiness.unavailable,
      );
      expect(
        classifyMediaReadiness(302, null, null),
        EndpointReadiness.unreachable,
      );
    },
  );
}

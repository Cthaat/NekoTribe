import 'dart:io';
import 'dart:typed_data';

import 'endpoint_probe_response.dart';

Future<EndpointProbeResponse> requestEndpointProbe(
  Uri uri,
  Duration timeout,
  int limit, {
  bool head = false,
}) async {
  final client = HttpClient();
  Future<EndpointProbeResponse> read() async {
    final request = await client.openUrl(head ? 'HEAD' : 'GET', uri);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.acceptHeader,
      head ? 'image/png' : 'application/json',
    );
    final response = await request.close();
    final bytes = BytesBuilder(copy: false);
    if (!head && (response.statusCode == 200 || response.statusCode == 503)) {
      await for (final chunk in response) {
        if (chunk.length > limit - bytes.length) {
          throw const FormatException('Invalid readiness response');
        }
        bytes.add(chunk);
      }
    }
    return (
      status: response.statusCode,
      body: bytes.takeBytes(),
      contentType: response.headers.value(HttpHeaders.contentTypeHeader),
      contentLength: response.headers.value(HttpHeaders.contentLengthHeader),
    );
  }

  try {
    return await read().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

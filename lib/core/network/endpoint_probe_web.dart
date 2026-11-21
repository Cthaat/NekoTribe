import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'endpoint_probe_response.dart';

Future<EndpointProbeResponse> requestEndpointProbe(
  Uri uri,
  Duration timeout,
  int limit, {
  bool head = false,
}) async {
  final abort = web.AbortController();
  Future<EndpointProbeResponse> read() async {
    final response = await web.window
        .fetch(
          uri.toString().toJS,
          web.RequestInit(
            method: head ? 'HEAD' : 'GET',
            headers: web.Headers()
              ..set('Accept', head ? 'image/png' : 'application/json'),
            credentials: 'omit',
            redirect: 'error',
            cache: 'no-store',
            signal: abort.signal,
          ),
        )
        .toDart;
    final stream = response.body;
    final bytes = BytesBuilder(copy: false);
    if (!head &&
        (response.status == 200 || response.status == 503) &&
        stream != null) {
      final reader = web.ReadableStreamDefaultReader(stream);
      try {
        while (true) {
          final result = await reader.read().toDart;
          if (result.done) break;
          final chunk = (result.value as JSUint8Array).toDart;
          if (chunk.length > limit - bytes.length) {
            throw const FormatException('Invalid readiness response');
          }
          bytes.add(chunk);
        }
      } finally {
        reader.releaseLock();
      }
    }
    return (
      status: response.status,
      body: bytes.takeBytes(),
      contentType: response.headers.get('content-type'),
      contentLength: response.headers.get('content-length'),
    );
  }

  try {
    return await read().timeout(timeout);
  } finally {
    abort.abort();
  }
}

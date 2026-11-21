import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;

Dio createApiDio() {
  final dio = Dio();
  dio.httpClientAdapter = _StrictRedirectAdapter(dio.httpClientAdapter);
  return dio;
}

/// XHR follows redirects automatically. Use Fetch for requests that forbid them.
class _StrictRedirectAdapter implements HttpClientAdapter {
  _StrictRedirectAdapter(this._defaultAdapter);

  final HttpClientAdapter _defaultAdapter;
  final _active = <web.AbortController>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.followRedirects) {
      return _defaultAdapter.fetch(options, requestStream, cancelFuture);
    }
    return _fetchWithoutRedirects(options, requestStream, cancelFuture);
  }

  Future<ResponseBody> _fetchWithoutRedirects(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final abort = web.AbortController();
    _active.add(abort);
    cancelFuture?.then((_) => abort.abort());
    final timeout =
        (options.connectTimeout ?? Duration.zero) +
        (options.sendTimeout ?? Duration.zero) +
        (options.receiveTimeout ?? Duration.zero);
    try {
      final request = _send(options, requestStream, abort.signal);
      return timeout == Duration.zero
          ? await request
          : await request.timeout(
              timeout,
              onTimeout: () => throw DioException.receiveTimeout(
                timeout: timeout,
                requestOptions: options,
              ),
            );
    } finally {
      _active.remove(abort);
      abort.abort();
    }
  }

  Future<ResponseBody> _send(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    web.AbortSignal signal,
  ) async {
    final headers = web.Headers();
    options.headers.forEach((name, value) {
      if (name.toLowerCase() != Headers.contentLengthHeader) {
        headers.set(
          name,
          value is Iterable ? value.join(', ') : value.toString(),
        );
      }
    });
    web.Blob? body;
    if (requestStream != null) {
      final parts = <JSUint8Array>[];
      await for (final chunk in requestStream) {
        if (signal.aborted) {
          throw DioException.requestCancelled(
            requestOptions: options,
            reason: null,
          );
        }
        parts.add(chunk.toJS);
      }
      body = web.Blob(parts.toJS);
    }
    final response = await web.window
        .fetch(
          options.uri.toString().toJS,
          web.RequestInit(
            method: options.method,
            headers: headers,
            body: body,
            credentials: options.extra['withCredentials'] == true
                ? 'include'
                : 'same-origin',
            redirect: 'error',
            cache: 'no-store',
            signal: signal,
          ),
        )
        .toDart;
    final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
    final responseHeaders = <String, List<String>>{};
    _FetchHeaders(response.headers).forEach(
      ((String value, String name) {
        responseHeaders[name] = [value];
      }).toJS,
    );
    return ResponseBody.fromBytes(
      bytes,
      response.status,
      headers: responseHeaders,
      statusMessage: response.statusText,
    );
  }

  @override
  void close({bool force = false}) {
    if (force) {
      for (final request in _active) {
        request.abort();
      }
    }
    _defaultAdapter.close(force: force);
  }
}

extension type _FetchHeaders(JSObject _) implements JSObject {
  external void forEach(JSFunction callback);
}

import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<String> loadAppConfigAsset(String assetPath) async {
  final base = Uri.parse(web.document.baseURI);
  final uri = base.resolve('assets/$assetPath');
  final abort = web.AbortController();
  Future<String> load() async {
    final response = await web.window
        .fetch(
          uri.toString().toJS,
          web.RequestInit(
            credentials: 'same-origin',
            mode: 'same-origin',
            redirect: 'error',
            cache: 'no-cache',
            signal: abort.signal,
          ),
        )
        .toDart;
    if (!response.ok) {
      throw const FormatException('Flutter Web configuration is unavailable');
    }
    return (await response.text().toDart).toDart;
  }

  try {
    return await load().timeout(const Duration(seconds: 5));
  } finally {
    abort.abort();
  }
}

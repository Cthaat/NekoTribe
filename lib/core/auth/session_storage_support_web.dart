import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

bool get sessionStorageSupported {
  if (!web.window.isSecureContext) return false;
  final crypto = web.window.getProperty<JSObject?>('crypto'.toJS);
  return crypto?.getProperty<JSObject?>('subtle'.toJS) != null;
}

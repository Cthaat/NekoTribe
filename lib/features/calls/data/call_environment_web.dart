import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

bool get callSecureContext => web.window.isSecureContext;
bool get callBrowserSupported =>
    web.window.getProperty<JSObject?>('RTCPeerConnection'.toJS) != null &&
    web.window.navigator.getProperty<JSObject?>('mediaDevices'.toJS) != null;

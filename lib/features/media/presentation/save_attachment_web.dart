import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

extension type _SaveFileWindow(JSObject _) implements JSObject {
  external JSPromise<web.FileSystemFileHandle> showSaveFilePicker(
    JSObject options,
  );
}

Future<void> saveAttachment(
  String fileName, {
  required Future<Uint8List> Function() readBytes,
  required Stream<Uint8List> Function() readParts,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return;
  final picker = web.window.getProperty<JSAny?>('showSaveFilePicker'.toJS);
  if (picker.isA<JSFunction>()) {
    await _saveParts(fileName, readParts, isCurrent);
    return;
  }
  final bytes = await readBytes();
  if (!isCurrent()) return;
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  try {
    anchor.click();
  } finally {
    Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  }
}

Future<void> _saveParts(
  String fileName,
  Stream<Uint8List> Function() readParts,
  bool Function() isCurrent,
) async {
  final web.FileSystemFileHandle file;
  try {
    file = await _SaveFileWindow(web.window)
        .showSaveFilePicker({'suggestedName': fileName}.jsify() as JSObject)
        .toDart;
  } catch (error) {
    if (error.toString().startsWith('AbortError:')) return;
    rethrow;
  }
  if (!isCurrent()) return;
  final writer = await file.createWritable().toDart;
  var committed = false;
  try {
    if (!isCurrent()) return;
    await for (final part in readParts()) {
      if (!isCurrent()) return;
      await writer.write(part.toJS).toDart;
    }
    if (!isCurrent()) return;
    await writer.close().toDart;
    committed = true;
  } finally {
    if (!committed) {
      try {
        await writer.abort().toDart;
      } catch (_) {
        /* The stream may already be closed on error. */
      }
    }
  }
}

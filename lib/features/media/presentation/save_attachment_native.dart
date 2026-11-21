import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<void> saveAttachment(
  String fileName, {
  required Future<Uint8List> Function() readBytes,
  required Stream<Uint8List> Function() readParts,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return;
  final mobile = Platform.isAndroid || Platform.isIOS;
  final bytes = mobile ? await readBytes() : null;
  if (!isCurrent()) return;
  final path = await FilePicker.platform.saveFile(
    fileName: fileName,
    bytes: bytes,
  );
  if (!mobile && path != null && isCurrent()) {
    await saveAttachmentParts(File(path), readParts(), isCurrent: isCurrent);
  }
}

Future<void> saveAttachmentParts(
  File destination,
  Stream<Uint8List> parts, {
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return;
  final directory = await destination.parent.createTemp('.neko-download-');
  final staged = File.fromUri(directory.uri.resolve('download.part'));
  try {
    final output = await staged.open(mode: FileMode.writeOnly);
    try {
      if (!isCurrent()) return;
      await for (final part in parts) {
        if (!isCurrent()) return;
        await output.writeFrom(part);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (isCurrent()) await staged.rename(destination.path);
  } finally {
    if (await staged.exists()) await staged.delete();
    await directory.delete();
  }
}

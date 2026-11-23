import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mime/mime.dart';

import '../../media/data/media_api.dart';
import '../../posts/domain/post_models.dart';

const chatAttachmentMaxBytes = 500 * 1024 * 1024;

Future<V2MediaAsset> uploadChatAttachment(
  MediaApi api,
  PlatformFile file,
  CancelToken cancelToken,
) {
  final mime = lookupMimeType(
    file.name,
    headerBytes: file.bytes?.take(16).toList(),
  );
  final type = switch (mime?.split('/').first) {
    'image' => 'image',
    'video' => 'video',
    'audio' => 'audio',
    _ => 'file',
  };
  if (file.bytes case final bytes?) {
    return api.uploadBytes(
      bytes: bytes,
      fileName: file.name,
      mediaType: type,
      mimeType: mime,
      altText: file.name,
      accessScope: 'chat',
      cancelToken: cancelToken,
    );
  }
  if (file.readStream case final stream?) {
    return api.uploadStream(
      chunks: stream,
      length: file.size,
      fileName: file.name,
      mediaType: type,
      altText: file.name,
      accessScope: 'chat',
      cancelToken: cancelToken,
    );
  }
  if (!kIsWeb && file.path != null) {
    return api.uploadFile(
      file: File(file.path!),
      mediaType: type,
      altText: file.name,
      accessScope: 'chat',
      cancelToken: cancelToken,
    );
  }
  throw const FormatException('Chat attachment is unavailable');
}

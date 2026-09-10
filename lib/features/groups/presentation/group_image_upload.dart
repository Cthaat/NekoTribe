import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/providers.dart';

Future<String?> pickAndUploadGroupImage({
  required WidgetRef ref,
  String? altText,
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    allowMultiple: false,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;

  final picked = result.files.single;
  final api = ref.read(mediaApiProvider);
  final label = altText == null || altText.trim().isEmpty
      ? picked.name
      : altText.trim();

  if (picked.bytes != null) {
    final asset = await api.uploadBytes(
      bytes: picked.bytes!,
      fileName: picked.name,
      mediaType: 'image',
      altText: label,
    );
    return asset.publicUrl;
  }

  if (!kIsWeb && picked.path != null) {
    final asset = await api.uploadFile(
      file: File(picked.path!),
      mediaType: 'image',
      altText: label,
    );
    return asset.publicUrl;
  }

  throw Exception('image file is empty');
}

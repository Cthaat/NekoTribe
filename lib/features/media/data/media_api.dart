import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';
import '../../posts/domain/post_models.dart';

class MediaApi {
  MediaApi(this._client);

  final ApiClient _client;

  Future<V2MediaAsset> uploadFile({
    required File file,
    String mediaType = 'image',
    String? altText,
    String? description,
    void Function(int sent, int total)? onProgress,
  }) async {
    final mime = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileName = file.uri.pathSegments.last;
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        file.path,
        filename: fileName,
        contentType: _parseContentType(mime),
      ),
      'media_type': mediaType,
      if (altText != null) 'alt_text': altText,
      if (description != null) 'description': description,
    });
    final res = await _client.raw.post<dynamic>(
      ApiPaths.media,
      data: form,
      onSendProgress: onProgress,
    );
    final body = res.data;
    if (body is Map<String, dynamic> && body['code'] is num) {
      final code = (body['code'] as num).toInt();
      if (code >= 200 && code < 30000) {
        return V2MediaAsset.fromJson(toMap(body['data']));
      }
    }
    throw Exception('media upload failed: ${res.statusCode}');
  }

  Future<V2MediaAsset> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    String mediaType = 'image',
    String? mimeType,
    String? altText,
    String? description,
    void Function(int sent, int total)? onProgress,
  }) async {
    final mime =
        mimeType ??
        lookupMimeType(fileName, headerBytes: bytes.take(16).toList()) ??
        'application/octet-stream';
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: fileName,
        contentType: _parseContentType(mime),
      ),
      'media_type': mediaType,
      if (altText != null) 'alt_text': altText,
      if (description != null) 'description': description,
    });
    final res = await _client.raw.post<dynamic>(
      ApiPaths.media,
      data: form,
      onSendProgress: onProgress,
    );
    final body = res.data;
    if (body is Map<String, dynamic> && body['code'] is num) {
      final code = (body['code'] as num).toInt();
      if (code >= 200 && code < 30000) {
        return V2MediaAsset.fromJson(toMap(body['data']));
      }
    }
    throw Exception('media upload failed: ${res.statusCode}');
  }

  Future<void> deleteMedia(int mediaId) async {
    await _client.request<void>(
      '${ApiPaths.media}/$mediaId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  DioMediaType _parseContentType(String mime) {
    final parts = mime.split('/');
    if (parts.length == 2) {
      return DioMediaType(parts[0], parts[1]);
    }
    return DioMediaType('application', 'octet-stream');
  }
}

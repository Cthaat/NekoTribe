import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
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
    String? accessScope,
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async {
    final mime = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileName = file.uri.pathSegments.last;
    final part = await MultipartFile.fromFile(
      file.path,
      filename: fileName,
      contentType: _parseContentType(mime),
    );
    return _upload(
      part,
      mediaType: mediaType,
      altText: altText,
      description: description,
      accessScope: accessScope,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  Future<V2MediaAsset> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    String mediaType = 'image',
    String? mimeType,
    String? altText,
    String? description,
    String? accessScope,
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async {
    final mime =
        mimeType ??
        lookupMimeType(fileName, headerBytes: bytes.take(16).toList()) ??
        'application/octet-stream';
    return _upload(
      MultipartFile.fromBytes(
        bytes,
        filename: fileName,
        contentType: _parseContentType(mime),
      ),
      mediaType: mediaType,
      altText: altText,
      description: description,
      accessScope: accessScope,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  Future<V2MediaAsset> uploadStream({
    required Stream<List<int>> chunks,
    required int length,
    required String fileName,
    required String mediaType,
    String? altText,
    String? accessScope,
    CancelToken? cancelToken,
  }) {
    final mime = lookupMimeType(fileName) ?? 'application/octet-stream';
    Stream<List<int>> readChunks() async* {
      await for (final chunk in chunks) {
        final error = cancelToken?.cancelError;
        if (error != null) throw error;
        yield chunk;
      }
    }

    return _upload(
      MultipartFile.fromStream(
        readChunks,
        length,
        filename: fileName,
        contentType: _parseContentType(mime),
      ),
      mediaType: mediaType,
      altText: altText,
      accessScope: accessScope,
      cancelToken: cancelToken,
    );
  }

  Future<V2MediaAsset> _upload(
    MultipartFile file, {
    required String mediaType,
    String? altText,
    String? description,
    String? accessScope,
    CancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    final isPrivate = accessScope == 'chat' || accessScope == 'post';
    if (!isPrivate && accessScope != null && accessScope != 'public') {
      throw ArgumentError.value(accessScope, 'accessScope');
    }
    final form = FormData.fromMap({
      'file': file,
      'media_type': mediaType,
      if (altText != null) 'alt_text': altText,
      if (description != null) 'description': description,
      if (accessScope != null) 'access_scope': accessScope,
    });
    final res = await _client.raw.post<dynamic>(
      isPrivate ? ApiPaths.privateMediaUpload : ApiPaths.media,
      data: form,
      options: isPrivate ? Options(followRedirects: false) : null,
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    final body = res.data;
    final status = res.statusCode ?? 0;
    if (status == 401) {
      throw ApiException(
        code: 40101,
        message: 'Upload requires a fresh request',
        statusCode: status,
      );
    }
    if (status < 200 || status >= 300) {
      throw Exception('media upload failed: $status');
    }
    if (status != 200 ||
        body is! Map<String, Object?> ||
        body['code'] != 200 ||
        body['message'] != 'media uploaded' ||
        !body.containsKey('meta') ||
        body['meta'] != null) {
      throw const FormatException('Invalid uploaded attachment');
    }
    final data = toMap(body['data']);
    final id = data['media_id'];
    final url = data['public_url'];
    if (id is! int ||
        id <= 0 ||
        id > 9007199254740991 ||
        data['status'] != 'ready' ||
        url is! String ||
        url.trim().isEmpty) {
      throw const FormatException('Invalid uploaded attachment');
    }
    final asset = V2MediaAsset.fromJson(data);
    if (isPrivate
        ? asset.privateContentPath == null ||
              !data.containsKey('thumbnail_url') ||
              data['thumbnail_url'] != null
        : asset.usesContentRoute) {
      throw const FormatException('Invalid uploaded attachment');
    }
    return asset;
  }

  Future<Uint8List> downloadPrivate(
    V2MediaAsset asset, {
    required CancelToken cancelToken,
  }) async {
    final path = asset.privateContentPath;
    if (path == null) throw const FormatException('Invalid attachment path');
    final response = await _client.raw.get<Uint8List>(
      path,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: false,
        headers: {'Accept': 'application/octet-stream, */*'},
      ),
      cancelToken: cancelToken,
    );
    final bytes = response.data;
    if (response.statusCode != 200 ||
        bytes == null ||
        !_isAttachment(response.headers)) {
      throw ApiException(
        code: response.statusCode ?? 0,
        statusCode: response.statusCode,
        message: 'Attachment download failed',
      );
    }
    return bytes;
  }

  Stream<Uint8List> downloadPrivateParts(
    V2MediaAsset asset, {
    required CancelToken cancelToken,
  }) async* {
    final path = asset.privateContentPath;
    if (path == null) throw const FormatException('Invalid attachment path');
    final metadata = await _client.raw.head<Uint8List>(
      path,
      options: _attachmentOptions(200),
      cancelToken: cancelToken,
    );
    final size = int.tryParse(
      metadata.headers.value(Headers.contentLengthHeader) ?? '',
      radix: 10,
    );
    if (size == null || size < 0 || !_isAttachment(metadata.headers)) {
      throw const FormatException('Invalid attachment metadata');
    }

    const partSize = 4 * 1024 * 1024;
    for (var start = 0; start < size; start += partSize) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      final length = size - start < partSize ? size - start : partSize;
      final end = start + length - 1;
      final range = await _client.raw.get<Uint8List>(
        path,
        options: _attachmentOptions(206, range: 'bytes=$start-$end'),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (received > length || total > length) {
            cancelToken.cancel('Attachment part exceeds the requested range');
          }
        },
      );
      final bytes = range.data;
      if (bytes == null ||
          bytes.length != length ||
          !_isAttachment(range.headers) ||
          range.headers.value('content-range') != 'bytes $start-$end/$size') {
        throw const FormatException('Invalid attachment range');
      }
      yield bytes;
    }
  }

  Options _attachmentOptions(int status, {String? range}) => Options(
    responseType: ResponseType.bytes,
    followRedirects: false,
    validateStatus: (value) => value == status,
    receiveDataWhenStatusError: false,
    headers: {
      'Accept': 'application/octet-stream, */*',
      if (range != null) 'Range': range,
    },
  );

  bool _isAttachment(Headers headers) =>
      headers
          .value(Headers.contentTypeHeader)
          ?.split(';')
          .first
          .trim()
          .toLowerCase() ==
      'application/octet-stream';

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

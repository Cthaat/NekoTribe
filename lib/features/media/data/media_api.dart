import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/json_utils.dart';
import '../../posts/domain/post_models.dart';

typedef ImageDescription = ({String altText, List<String> tags});

class MediaApi {
  MediaApi(this._client);

  final ApiClient _client;

  static const maxAltTextBytes = 500;
  static final _invalidText = RegExp(
    r'[\u0000-\u001f\u007f\uD800-\uDFFF]',
    unicode: true,
  );
  static final _invalidTag = RegExp(r'[#\s]');

  static bool validAltText(String value) =>
      !_invalidText.hasMatch(value) &&
      utf8.encode(value).length <= maxAltTextBytes;

  static bool canDescribe(V2MediaAsset asset) =>
      _validId(asset.mediaId) &&
      asset.status == 'ready' &&
      asset.mediaType == 'image' &&
      const {
        'image/jpeg',
        'image/png',
        'image/webp',
      }.contains(asset.mimeType) &&
      asset.fileSize > 0 &&
      asset.fileSize <= 4 * 1024 * 1024;

  static bool _validId(int value) => value > 0 && value <= 9007199254740991;

  Future<ImageDescription> describeImage(
    int mediaId, {
    required String locale,
    required CancelToken cancelToken,
  }) {
    if (!_validId(mediaId) || (locale != 'zh' && locale != 'en')) {
      throw const FormatException('Invalid image description request');
    }
    return _client.requestData<ImageDescription>(
      ApiPaths.aiMediaDescribe,
      method: 'POST',
      data: {'media_id': mediaId, 'locale': locale},
      cancelToken: cancelToken,
      decode: (raw) {
        final data = toMap(raw);
        final text = data['alt_text'], tags = data['tags'];
        if (data.length != 3 ||
            data['media_id'] is! int ||
            data['media_id'] != mediaId ||
            text is! String ||
            text.trim().isEmpty ||
            !validAltText(text) ||
            tags is! List ||
            tags.length > 5) {
          throw const FormatException('Invalid image description');
        }
        final topics = <String>{};
        for (final tag in tags) {
          if (tag is! String ||
              tag.isEmpty ||
              tag.trim() != tag ||
              tag.runes.length > 40 ||
              _invalidText.hasMatch(tag) ||
              _invalidTag.hasMatch(tag) ||
              !topics.add(tag)) {
            throw const FormatException('Invalid image topic');
          }
        }
        return (altText: text.trim(), tags: List.unmodifiable(topics));
      },
    );
  }

  Future<String?> updateAltText(
    int mediaId,
    String altText, {
    required CancelToken cancelToken,
  }) {
    if (!_validId(mediaId) || !validAltText(altText)) {
      throw const FormatException('Invalid image alternate text');
    }
    final clean = altText.trim();
    final String? expected = clean.isEmpty ? null : clean;
    return _client.requestData<String?>(
      '${ApiPaths.media}/$mediaId',
      method: 'PATCH',
      data: {'alt_text': clean},
      cancelToken: cancelToken,
      decode: (raw) {
        final data = toMap(raw);
        if (data.length != 2 ||
            data['media_id'] is! int ||
            data['media_id'] != mediaId ||
            !data.containsKey('alt_text') ||
            data['alt_text'] != expected) {
          throw const FormatException('Invalid alternate text receipt');
        }
        return expected;
      },
    );
  }

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

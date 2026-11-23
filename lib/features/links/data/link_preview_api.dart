import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/link_preview.dart';

class LinkPreviewApi {
  LinkPreviewApi(this._client);

  final ApiClient _client;

  Future<V2LinkPreview?> read(Uri url, {required CancelToken cancelToken}) {
    final target = normalizePreviewUrl(url.toString());
    if (target == null) {
      throw const FormatException('Invalid URL for link preview');
    }
    return _client.requestData<V2LinkPreview?>(
      ApiPaths.linkPreview,
      query: {'url': target.toString()},
      cancelToken: cancelToken,
      decode: (value) {
        final envelope = toMap(value);
        if (!envelope.containsKey('preview')) {
          throw const FormatException('Missing link preview');
        }
        final data = envelope['preview'];
        return data == null ? null : V2LinkPreview.fromJson(toMap(data));
      },
    );
  }
}

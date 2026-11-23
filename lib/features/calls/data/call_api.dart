import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';

class CallApi {
  const CallApi(this._client);

  final ApiClient _client;

  Future<List<Map<String, Object>>> iceServers({
    CancelToken? cancelToken,
  }) => _client.requestData(
    ApiPaths.callIceServers,
    cancelToken: cancelToken,
    decode: (raw) {
      const invalid = FormatException('Invalid ICE server configuration');
      if (raw is! Map<String, dynamic> || !raw.containsKey('expires_at')) {
        throw invalid;
      }
      final servers = raw['ice_servers'];
      final expires = raw['expires_at'];
      final deadline = expires is String ? DateTime.tryParse(expires) : null;
      if (servers is! List ||
          servers.length > 2 ||
          (expires != null &&
              (deadline == null || !deadline.isAfter(DateTime.now())))) {
        throw invalid;
      }
      return servers.map((server) {
        if (server is! Map<String, dynamic>) throw invalid;
        final urls = server['urls'];
        final user = server['username'];
        final credential = server['credential'];
        if (urls is! List ||
            urls.isEmpty ||
            urls.length > 8 ||
            !urls.every((url) => url is String && _iceUrl.hasMatch(url))) {
          throw invalid;
        }
        final turn = (urls.first as String).startsWith('turn');
        if (!urls.every((url) => (url as String).startsWith('turn') == turn)) {
          throw invalid;
        }
        if (turn &&
            (deadline == null ||
                user is! String ||
                user.isEmpty ||
                credential is! String ||
                credential.isEmpty)) {
          throw invalid;
        }
        return <String, Object>{
          'urls': urls.cast<String>(),
          if (turn) 'username': user as String,
          if (turn) 'credential': credential as String,
        };
      }).toList();
    },
  );
}

final _iceUrl = RegExp(r'^(stuns?|turns?):[^\s]+$');

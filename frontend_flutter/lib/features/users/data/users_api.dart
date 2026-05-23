import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/user_models.dart';

class UsersApi {
  UsersApi(this._client);

  final ApiClient _client;

  Future<V2SelfUser> getMe() {
    return _client.requestData<V2SelfUser>(
      ApiPaths.usersMe,
      decode: (data) => V2SelfUser.fromJson(toMap(data)),
    );
  }

  Future<V2SelfUser> updateMe(Map<String, dynamic> body) {
    return _client.requestData<V2SelfUser>(
      ApiPaths.usersMe,
      method: 'PATCH',
      data: body,
      decode: (data) => V2SelfUser.fromJson(toMap(data)),
    );
  }

  Future<void> updateEmail({
    required String email,
    required String otpCode,
    required String password,
  }) async {
    await _client.request<void>(
      ApiPaths.usersMeEmail,
      method: 'PUT',
      data: {
        'email': email,
        'otp_code': otpCode,
        'password': password,
      },
      decode: (_) {},
    );
  }

  Future<V2SelfUser> uploadAvatar({
    required int mediaId,
  }) {
    return _client.requestData<V2SelfUser>(
      ApiPaths.usersMeAvatar,
      method: 'PUT',
      data: {'media_id': mediaId},
      decode: (data) => V2SelfUser.fromJson(toMap(data)),
    );
  }

  Future<V2UserSettings> getSettings() {
    return _client.requestData<V2UserSettings>(
      ApiPaths.usersMeSettings,
      decode: (data) => V2UserSettings.fromJson(toMap(data)),
    );
  }

  Future<V2UserSettings> updateSettings(Map<String, dynamic> body) {
    return _client.requestData<V2UserSettings>(
      ApiPaths.usersMeSettings,
      method: 'PATCH',
      data: body,
      decode: (data) => V2UserSettings.fromJson(toMap(data)),
    );
  }

  Future<PagedResult<V2PublicUser>> getBlocks({int page = 1, int size = 20}) {
    return _client.requestData<PagedResult<V2PublicUser>>(
      ApiPaths.usersMeBlocks,
      query: {'page': page, 'size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2PublicUser.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2PublicUser>(items: items, meta: meta);
      },
    );
  }

  Future<PagedResult<V2PublicUser>> getMutes({int page = 1, int size = 20}) {
    return _client.requestData<PagedResult<V2PublicUser>>(
      ApiPaths.usersMeMutes,
      query: {'page': page, 'size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2PublicUser.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2PublicUser>(items: items, meta: meta);
      },
    );
  }

  Future<void> blockUser(int userId) async {
    await _client.request<void>(
      '${ApiPaths.usersMeBlocks}/$userId',
      method: 'PUT',
      decode: (_) {},
    );
  }

  Future<void> unblockUser(int userId) async {
    await _client.request<void>(
      '${ApiPaths.usersMeBlocks}/$userId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<void> muteUser(int userId) async {
    await _client.request<void>(
      '${ApiPaths.usersMeMutes}/$userId',
      method: 'PUT',
      decode: (_) {},
    );
  }

  Future<void> unmuteUser(int userId) async {
    await _client.request<void>(
      '${ApiPaths.usersMeMutes}/$userId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<PagedResult<V2AccountStatement>> getStatements({
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2AccountStatement>>(
      ApiPaths.usersMeStatements,
      query: {'page': page, 'size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2AccountStatement.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2AccountStatement>(items: items, meta: meta);
      },
    );
  }

  Future<V2PublicUser> getUserByUsername(String username) {
    return _client.requestData<V2PublicUser>(
      '${ApiPaths.users}/$username',
      decode: (data) => V2PublicUser.fromJson(toMap(data)),
    );
  }

  Future<V2Relationship> followUser(String username) {
    return _client.requestData<V2Relationship>(
      '${ApiPaths.users}/$username/relationships/following',
      method: 'PUT',
      decode: (data) => V2Relationship.fromJson(toMap(data)),
    );
  }

  Future<V2Relationship> unfollowUser(String username) {
    return _client.requestData<V2Relationship>(
      '${ApiPaths.users}/$username/relationships/following',
      method: 'DELETE',
      decode: (data) => V2Relationship.fromJson(toMap(data)),
    );
  }

  Future<PagedResult<V2PublicUser>> getFollowers(
    String username, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2PublicUser>>(
      '${ApiPaths.users}/$username/followers',
      query: {'page': page, 'size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2PublicUser.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2PublicUser>(items: items, meta: meta);
      },
    );
  }

  Future<PagedResult<V2PublicUser>> getFollowing(
    String username, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2PublicUser>>(
      '${ApiPaths.users}/$username/following',
      query: {'page': page, 'size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2PublicUser.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2PublicUser>(items: items, meta: meta);
      },
    );
  }

  Future<List<V2PublicUser>> getRecommendations({int limit = 10}) {
    return _client.requestData<List<V2PublicUser>>(
      ApiPaths.userRecommendations,
      query: {'limit': limit},
      decode: (data) {
        final map = toMap(data);
        return toList(
          map['items'],
          (e) => V2PublicUser.fromJson(toMap(e)),
        );
      },
    );
  }

  Future<Map<String, dynamic>> setupTwoFactor() {
    return _client.requestData<Map<String, dynamic>>(
      ApiPaths.usersMeTwoFactorSetup,
      method: 'POST',
      decode: (data) => toMap(data),
    );
  }

  Future<void> confirmTwoFactor({
    required String secret,
    required String code,
  }) async {
    await _client.request<void>(
      ApiPaths.usersMeTwoFactorConfirm,
      method: 'POST',
      data: {'secret': secret, 'code': code},
      decode: (_) {},
    );
  }

  Future<void> disableTwoFactor({required String password}) async {
    await _client.request<void>(
      ApiPaths.usersMeTwoFactor,
      method: 'DELETE',
      data: {'password': password},
      decode: (_) {},
    );
  }
}

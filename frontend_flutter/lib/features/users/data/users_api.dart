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
    required String newEmail,
    required String verificationId,
    required String code,
  }) async {
    await _client.request<void>(
      ApiPaths.usersMeEmail,
      method: 'PATCH',
      data: {
        'new_email': newEmail,
        'verification_id': verificationId,
        'code': code,
      },
      decode: (_) {},
    );
  }

  Future<V2SelfUser> uploadAvatar({required int mediaId}) {
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
      query: {'page': page, 'page_size': size},
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
      query: {'page': page, 'page_size': size},
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
      method: 'POST',
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
      method: 'POST',
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
      query: {'page': page, 'page_size': size},
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

  Future<V2PublicUser> getUserById(int userId) {
    return _client.requestData<V2PublicUser>(
      '${ApiPaths.users}/$userId',
      decode: (data) => V2PublicUser.fromJson(toMap(data)),
    );
  }

  Future<V2Relationship> followUser(int userId) {
    return _client.requestData<V2Relationship>(
      '${ApiPaths.users}/$userId/followers',
      method: 'POST',
      decode: (data) => V2Relationship.fromFollowJson(toMap(data)),
    );
  }

  Future<V2Relationship> unfollowUser(int userId) {
    return _client.requestData<V2Relationship>(
      '${ApiPaths.users}/$userId/followers',
      method: 'DELETE',
      decode: (data) => V2Relationship.fromFollowJson(toMap(data)),
    );
  }

  Future<PagedResult<V2PublicUser>> getFollowers(
    int userId, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2PublicUser>>(
      '${ApiPaths.users}/$userId/followers',
      query: {'page': page, 'page_size': size},
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
    int userId, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2PublicUser>>(
      '${ApiPaths.users}/$userId/following',
      query: {'page': page, 'page_size': size},
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
        return toList(map['items'], (e) => V2PublicUser.fromJson(toMap(e)));
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

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

  Future<Map<String, dynamic>> deleteMe({
    required String password,
    required String confirmation,
  }) {
    return _client.requestData<Map<String, dynamic>>(
      ApiPaths.usersMe,
      method: 'DELETE',
      data: {'password': password, 'confirmation': confirmation},
      decode: (data) => toMap(data),
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
    return _client.requestPaged<V2PublicUser>(
      ApiPaths.usersMeBlocks,
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2PublicUser.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2PublicUser>> getMutes({int page = 1, int size = 20}) {
    return _client.requestPaged<V2PublicUser>(
      ApiPaths.usersMeMutes,
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2PublicUser.fromJson(toMap(item)),
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
    return _client.requestPaged<V2AccountStatement>(
      ApiPaths.usersMeStatements,
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2AccountStatement.fromJson(toMap(item)),
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
    return _client.requestPaged<V2PublicUser>(
      '${ApiPaths.users}/$userId/followers',
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2PublicUser.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2PublicUser>> getFollowing(
    int userId, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestPaged<V2PublicUser>(
      '${ApiPaths.users}/$userId/following',
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2PublicUser.fromJson(toMap(item)),
    );
  }

  Future<List<V2PublicUser>> getRecommendations({int limit = 10}) {
    return _client.requestList<V2PublicUser>(
      ApiPaths.userRecommendations,
      query: {'limit': limit},
      decodeItem: (item) => V2PublicUser.fromJson(toMap(item)),
    );
  }

  Future<Map<String, dynamic>> setupTwoFactor({required String password}) {
    return _client.requestData<Map<String, dynamic>>(
      ApiPaths.usersMeTwoFactorSetup,
      method: 'POST',
      data: {'password': password},
      decode: (data) => toMap(data),
    );
  }

  Future<Map<String, dynamic>> confirmTwoFactor({required String code}) {
    return _client.requestData<Map<String, dynamic>>(
      ApiPaths.usersMeTwoFactorConfirm,
      method: 'POST',
      data: {'code': code},
      decode: (data) => toMap(data),
    );
  }

  Future<Map<String, dynamic>> disableTwoFactor({
    required String password,
    required String code,
  }) {
    return _client.requestData<Map<String, dynamic>>(
      ApiPaths.usersMeTwoFactor,
      method: 'DELETE',
      data: {'password': password, 'code': code},
      decode: (data) => toMap(data),
    );
  }
}

import '../../../core/network/api_response.dart';
import '../domain/user_models.dart';
import 'users_api.dart';

class UsersRepository {
  UsersRepository(this._api);

  final UsersApi _api;

  Future<V2SelfUser> getCurrentUser() => _api.getMe();

  Future<V2SelfUser> updateProfile({
    String? displayName,
    String? bio,
    String? location,
    String? website,
    String? birthDate,
  }) {
    final body = <String, dynamic>{};
    if (displayName != null) body['display_name'] = displayName;
    if (bio != null) body['bio'] = bio;
    if (location != null) body['location'] = location;
    if (website != null) body['website'] = website;
    if (birthDate != null) body['birth_date'] = birthDate;
    return _api.updateMe(body);
  }

  Future<V2SelfUser> changeAvatar(int mediaId) =>
      _api.uploadAvatar(mediaId: mediaId);

  Future<void> changeEmail({
    required String newEmail,
    required String verificationId,
    required String code,
  }) {
    return _api.updateEmail(
      newEmail: newEmail,
      verificationId: verificationId,
      code: code,
    );
  }

  Future<Map<String, dynamic>> deleteAccount({
    required String password,
    required String confirmation,
  }) => _api.deleteMe(password: password, confirmation: confirmation);

  Future<V2UserSettings> getSettings() => _api.getSettings();

  Future<V2UserSettings> updateSettings(Map<String, dynamic> body) =>
      _api.updateSettings(body);

  Future<V2PublicUser> getUserById(int userId) => _api.getUserById(userId);

  Future<V2Relationship> follow(int userId) => _api.followUser(userId);
  Future<V2Relationship> unfollow(int userId) => _api.unfollowUser(userId);

  Future<PagedResult<V2PublicUser>> followers(
    int userId, {
    int page = 1,
    int size = 20,
  }) => _api.getFollowers(userId, page: page, size: size);

  Future<PagedResult<V2PublicUser>> following(
    int userId, {
    int page = 1,
    int size = 20,
  }) => _api.getFollowing(userId, page: page, size: size);

  Future<PagedResult<V2PublicUser>> blocks({int page = 1, int size = 20}) =>
      _api.getBlocks(page: page, size: size);

  Future<PagedResult<V2PublicUser>> mutes({int page = 1, int size = 20}) =>
      _api.getMutes(page: page, size: size);

  Future<void> blockUser(int userId) => _api.blockUser(userId);
  Future<void> unblockUser(int userId) => _api.unblockUser(userId);
  Future<void> muteUser(int userId) => _api.muteUser(userId);
  Future<void> unmuteUser(int userId) => _api.unmuteUser(userId);

  Future<PagedResult<V2AccountStatement>> statements({
    int page = 1,
    int size = 20,
  }) => _api.getStatements(page: page, size: size);

  Future<List<V2PublicUser>> recommendations({int limit = 10}) =>
      _api.getRecommendations(limit: limit);

  Future<Map<String, dynamic>> setupTwoFactor({required String password}) =>
      _api.setupTwoFactor(password: password);
  Future<Map<String, dynamic>> confirmTwoFactor({required String code}) =>
      _api.confirmTwoFactor(code: code);
  Future<Map<String, dynamic>> disableTwoFactor({
    required String password,
    required String code,
  }) => _api.disableTwoFactor(password: password, code: code);
}

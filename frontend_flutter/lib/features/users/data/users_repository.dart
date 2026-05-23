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
    required String email,
    required String otpCode,
    required String password,
  }) {
    return _api.updateEmail(
      email: email,
      otpCode: otpCode,
      password: password,
    );
  }

  Future<V2UserSettings> getSettings() => _api.getSettings();

  Future<V2UserSettings> updateSettings(Map<String, dynamic> body) =>
      _api.updateSettings(body);

  Future<V2PublicUser> getUser(String username) =>
      _api.getUserByUsername(username);

  Future<V2Relationship> follow(String username) => _api.followUser(username);
  Future<V2Relationship> unfollow(String username) =>
      _api.unfollowUser(username);

  Future<PagedResult<V2PublicUser>> followers(
    String username, {
    int page = 1,
    int size = 20,
  }) => _api.getFollowers(username, page: page, size: size);

  Future<PagedResult<V2PublicUser>> following(
    String username, {
    int page = 1,
    int size = 20,
  }) => _api.getFollowing(username, page: page, size: size);

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

  Future<Map<String, dynamic>> setupTwoFactor() => _api.setupTwoFactor();
  Future<void> confirmTwoFactor({
    required String secret,
    required String code,
  }) => _api.confirmTwoFactor(secret: secret, code: code);
  Future<void> disableTwoFactor({required String password}) =>
      _api.disableTwoFactor(password: password);
}

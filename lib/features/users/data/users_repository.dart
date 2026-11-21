import 'dart:io';
import 'dart:typed_data';

import '../../../core/network/api_response.dart';
import '../domain/user_models.dart';
import '../domain/security_action.dart';
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
    String? phone,
    String? birthDate,
  }) {
    return _api.updateMe({
      if (displayName != null) 'display_name': displayName,
      if (bio != null) 'bio': bio,
      if (location != null) 'location': location,
      if (website != null) 'website': website,
      if (phone != null) 'phone': phone,
      if (birthDate != null) 'birth_date': birthDate,
    });
  }

  Future<V2SelfUser> changeAvatarFile(File file) async {
    await _api.uploadAvatarFile(file: file);
    return _api.getMe();
  }

  Future<V2SelfUser> changeAvatarBytes({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    await _api.uploadAvatarBytes(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    );
    return _api.getMe();
  }

  Future<void> changeEmail({
    required String newEmail,
    required String verificationId,
    required String code,
  }) async {
    await _api.updateEmail(
      newEmail: newEmail,
      verificationId: verificationId,
      code: code,
    );
  }

  Future<V2AccountDeletionData> deleteAccount({
    required String password,
    required String confirmation,
  }) => _api.deleteMe(password: password, confirmation: confirmation);

  Future<V2UserSettings> getSettings() => _api.getSettings();

  Future<V2UserSettings> updateSettings(Map<String, dynamic> body) =>
      _api.updateSettings(body);

  Future<V2PublicUser> getUserById(int userId) => _api.getUserById(userId);

  Future<V2UserAnalytics> getUserAnalytics(int userId) =>
      _api.getUserAnalytics(userId);

  Future<List<V2UserDailyAnalytics>> getUserDailyAnalytics(
    int userId, {
    int days = 14,
  }) => _api.getUserDailyAnalytics(userId, days: days);

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
  Future<void> muteUser(int userId, {DateTime? expiresAt}) =>
      _api.muteUser(userId, expiresAt: expiresAt);
  Future<void> unmuteUser(int userId) => _api.unmuteUser(userId);

  Future<PagedResult<V2AccountStatement>> statements({
    int page = 1,
    int size = 20,
    String? status,
    String? type,
  }) => _api.getStatements(page: page, size: size, status: status, type: type);

  Future<void> changeStatementStatus(int id, String action) =>
      _api.changeStatementStatus(id, action);

  Future<void> submitStatementAppeal(int id, String message) =>
      _api.submitStatementAppeal(id, message);

  Future<PagedResult<V2PublicUser>> searchUsers(
    String query, {
    int page = 1,
    int size = 20,
  }) => _api.searchUsers(query, page: page, size: size);

  Future<List<V2PublicUser>> recommendations({int limit = 10}) =>
      _api.getRecommendations(limit: limit);

  Future<V2TwoFactorSetupData> setupTwoFactor({required String password}) =>
      _api.setupTwoFactor(password: password);
  Future<V2TwoFactorConfirmData> confirmTwoFactor({required String code}) =>
      _api.confirmTwoFactor(code: code);
  Future<V2TwoFactorDisabledData> disableTwoFactor({
    required String password,
    required String code,
  }) => _api.disableTwoFactor(password: password, code: code);
}

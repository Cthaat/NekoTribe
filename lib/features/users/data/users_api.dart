import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/user_models.dart';
import '../domain/email_change.dart';
import '../domain/security_action.dart';

class UsersApi {
  UsersApi(this._client);

  final ApiClient _client;

  Future<V2SelfUser> getMe() {
    return _client.requestData<V2SelfUser>(
      ApiPaths.usersMe,
      validateSuccessEnvelope: (envelope) {
        if (envelope is! Map<String, Object?> ||
            envelope['code'] is! int ||
            envelope['code'] != 200 ||
            envelope['message'] != 'success' ||
            !envelope.containsKey('meta') ||
            envelope['meta'] != null) {
          throw const FormatException('Invalid current user profile response');
        }
      },
      decode: (data) {
        final json = toMap(data);
        final id = json['user_id'];
        if (id is! int || id <= 0 || id > 9007199254740991) {
          throw const FormatException('Invalid current user profile response');
        }
        return V2SelfUser.fromJson(json);
      },
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

  Future<V2EmailChangeData> updateEmail({
    required String newEmail,
    required String verificationId,
    required String code,
  }) {
    return _client.requestData<V2EmailChangeData>(
      ApiPaths.usersMeEmail,
      method: 'PATCH',
      data: {
        'new_email': newEmail,
        'verification_id': verificationId,
        'code': code,
      },
      validateSuccessEnvelope: validateEmailChangeEnvelope,
      decode: (data) =>
          V2EmailChangeData.fromJson(data, expectedEmail: newEmail),
    );
  }

  Future<V2AccountDeletionData> deleteMe({
    required String password,
    required String confirmation,
  }) {
    return _client.requestData<V2AccountDeletionData>(
      ApiPaths.usersMe,
      method: 'DELETE',
      data: {'password': password, 'confirmation': confirmation},
      validateSuccessEnvelope: validateSecurityActionEnvelope,
      decode: V2AccountDeletionData.fromJson,
    );
  }

  Future<V2AvatarData> uploadAvatarFile({required File file}) async {
    final mime = lookupMimeType(file.path) ?? 'application/octet-stream';
    final form = FormData.fromMap({
      'avatar': await MultipartFile.fromFile(
        file.path,
        filename: file.uri.pathSegments.last,
        contentType: _parseContentType(mime),
      ),
    });
    return _uploadAvatarForm(form);
  }

  Future<V2AvatarData> uploadAvatarBytes({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    final mime =
        mimeType ??
        lookupMimeType(fileName, headerBytes: bytes.take(16).toList()) ??
        'application/octet-stream';
    final form = FormData.fromMap({
      'avatar': MultipartFile.fromBytes(
        bytes,
        filename: fileName,
        contentType: _parseContentType(mime),
      ),
    });
    return _uploadAvatarForm(form);
  }

  Future<V2AvatarData> _uploadAvatarForm(FormData form) async {
    final res = await _client.raw.put<dynamic>(
      ApiPaths.usersMeAvatar,
      data: form,
    );
    final body = res.data;
    if (body is Map<String, dynamic> && body['code'] is num) {
      final code = (body['code'] as num).toInt();
      if (code >= 200 && code < 30000) {
        return V2AvatarData.fromJson(toMap(body['data']));
      }
    }
    throw Exception('avatar upload failed: ${res.statusCode}');
  }

  Future<V2UserSettings> getSettings() {
    return _client.requestData<V2UserSettings>(
      ApiPaths.usersMeSettings,
      validateSuccessEnvelope: validateAccountSettingsEnvelope,
      decode: V2UserSettings.fromJson,
    );
  }

  Future<V2UserSettings> updateSettings(Map<String, dynamic> body) {
    return _client.requestData<V2UserSettings>(
      ApiPaths.usersMeSettings,
      method: 'PATCH',
      data: body,
      validateSuccessEnvelope: validateAccountSettingsEnvelope,
      decode: V2UserSettings.fromJson,
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

  Future<void> muteUser(int userId, {DateTime? expiresAt}) async {
    await _client.request<void>(
      '${ApiPaths.usersMeMutes}/$userId',
      method: 'POST',
      data: expiresAt == null
          ? null
          : {'expires_at': expiresAt.toUtc().toIso8601String()},
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
    String? status,
    String? type,
  }) {
    return _client.requestPaged<V2AccountStatement>(
      ApiPaths.usersMeStatements,
      query: {
        'page': page,
        'page_size': size,
        if (status != null) 'status': status,
        if (type != null) 'type': type,
      },
      decodeItem: (item) => V2AccountStatement.fromJson(toMap(item)),
    );
  }

  Future<void> changeStatementStatus(int id, String action) {
    return _client.requestData<void>(
      '${ApiPaths.usersMeStatements}/$id',
      method: 'PATCH',
      data: {'action': action},
      decode: (_) {},
    );
  }

  Future<void> submitStatementAppeal(int id, String message) {
    return _client.requestData<void>(
      '${ApiPaths.usersMeStatements}/$id/appeals',
      method: 'POST',
      data: {'appeal_message': message},
      decode: (_) {},
    );
  }

  Future<V2PublicUser> getUserByUsername(String username) {
    return _client.requestData<V2PublicUser>(
      '${ApiPaths.users}/$username',
      decode: (data) => V2PublicUser.fromJson(toMap(data)),
    );
  }

  Future<V2PublicUser> getUserById(int userId) async {
    if (userId <= 0 || userId > 9007199254740991) {
      throw const FormatException('Invalid profile route');
    }
    return _client.requestData<V2PublicUser>(
      '${ApiPaths.users}/$userId',
      decode: (data) {
        final profile = toMap(data);
        final id = profile['user_id'];
        if (id is! int || id <= 0 || id > 9007199254740991 || id != userId) {
          throw const FormatException('Invalid public profile response');
        }
        return V2PublicUser.fromJson(profile);
      },
    );
  }

  Future<V2UserAnalytics> getUserAnalytics(int userId) {
    return _client.requestData<V2UserAnalytics>(
      '${ApiPaths.users}/$userId/analytics',
      decode: (data) => V2UserAnalytics.fromJson(toMap(data)),
    );
  }

  Future<List<V2UserDailyAnalytics>> getUserDailyAnalytics(
    int userId, {
    int days = 14,
  }) {
    return _client.requestList<V2UserDailyAnalytics>(
      '${ApiPaths.users}/$userId/analytics/daily',
      query: {'days': days},
      decodeItem: (item) => V2UserDailyAnalytics.fromJson(toMap(item)),
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

  Future<PagedResult<V2PublicUser>> searchUsers(
    String query, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestPaged<V2PublicUser>(
      ApiPaths.users,
      query: {'q': query, 'page': page, 'page_size': size, 'sort': 'popular'},
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

  Future<V2TwoFactorSetupData> setupTwoFactor({required String password}) {
    return _client.requestData<V2TwoFactorSetupData>(
      ApiPaths.usersMeTwoFactorSetup,
      method: 'POST',
      data: {'password': password},
      validateSuccessEnvelope: validateSecurityActionEnvelope,
      decode: V2TwoFactorSetupData.fromJson,
    );
  }

  Future<V2TwoFactorConfirmData> confirmTwoFactor({required String code}) {
    return _client.requestData<V2TwoFactorConfirmData>(
      ApiPaths.usersMeTwoFactorConfirm,
      method: 'POST',
      data: {'code': code},
      validateSuccessEnvelope: validateSecurityActionEnvelope,
      decode: V2TwoFactorConfirmData.fromJson,
    );
  }

  Future<V2TwoFactorDisabledData> disableTwoFactor({
    required String password,
    required String code,
  }) {
    return _client.requestData<V2TwoFactorDisabledData>(
      ApiPaths.usersMeTwoFactor,
      method: 'DELETE',
      data: {'password': password, 'code': code},
      validateSuccessEnvelope: validateSecurityActionEnvelope,
      decode: V2TwoFactorDisabledData.fromJson,
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

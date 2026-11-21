import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';
import '../domain/auth_models.dart';

class AuthApi {
  AuthApi(this._client);

  final ApiClient _client;

  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
    String channel = 'email',
  }) {
    return _client.requestData<V2AuthOtpData>(
      ApiPaths.authOtp,
      method: 'POST',
      data: {'account': account, 'type': purpose, 'channel': channel},
      sendAuth: false,
      decode: (data) =>
          V2AuthOtpData.fromJson(toMap(data), expectedAccount: account),
    );
  }

  Future<V2AuthOtpVerificationData> verifyOtp({
    required String account,
    required String purpose,
    required String verificationId,
    required String code,
  }) {
    return _client.requestData<V2AuthOtpVerificationData>(
      ApiPaths.authOtpVerification,
      method: 'POST',
      data: {
        'account': account,
        'type': purpose,
        'verification_id': verificationId,
        'code': code,
      },
      sendAuth: false,
      decode: (data) => V2AuthOtpVerificationData.fromJson(
        toMap(data),
        expectedAccount: account,
      ),
    );
  }

  Future<V2SelfUser> register({
    required String email,
    required String username,
    required String displayName,
    required String password,
    required String confirmPassword,
    required String verificationId,
    required bool agreeToTerms,
    String? bio,
    String? location,
    String? phone,
    String? birthDate,
  }) {
    return _client.requestData<V2SelfUser>(
      ApiPaths.authRegistration,
      method: 'POST',
      data: {
        'email': email,
        'username': username,
        'password': password,
        'confirm_password': confirmPassword,
        'display_name': displayName,
        if (bio != null && bio.isNotEmpty) 'bio': bio,
        if (location != null && location.isNotEmpty) 'location': location,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (birthDate != null && birthDate.isNotEmpty) 'birth_date': birthDate,
        'verification_id': verificationId,
        'agree_to_terms': agreeToTerms,
      },
      sendAuth: false,
      decode: (data) =>
          parseRegistrationUser(toMap(data), email: email, username: username),
    );
  }

  Future<V2LoginResult> login({
    required String account,
    required String password,
    bool rememberMe = false,
  }) async {
    final proof = kIsWeb
        ? null
        : await _client.tokenStore.readTrustedDevice(_client.config.apiBaseUrl);
    return _client.requestData<V2LoginResult>(
      ApiPaths.authTokens,
      method: 'POST',
      data: {
        'account': account,
        'password': password,
        'remember_me': rememberMe,
      },
      sendAuth: false,
      headers: proof == null
          ? null
          : {'Cookie': '${ApiClient.trustedDeviceCookie}=$proof'},
      decode: (data) => parseLoginResult(toMap(data)),
    );
  }

  Future<V2LoginSuccess> completeTwoFactor({
    required String challengeId,
    required String code,
  }) async {
    String? proof;
    final response = await _client.request<V2LoginSuccess>(
      '${ApiPaths.authTwoFactorChallenges}/$challengeId',
      method: 'POST',
      data: {'code': code},
      sendAuth: false,
      onTrustedDeviceProof: (value) => proof = value,
      decode: (data) {
        return parseLoginSuccess(toMap(data));
      },
    );
    return V2LoginSuccess(
      user: response.data.user,
      tokens: response.data.tokens,
      trustedDeviceProof: proof,
    );
  }

  Future<void> rememberTrustedDevice(String proof, int revision) => _client
      .tokenStore
      .rememberTrustedDevice(_client.config.apiBaseUrl, proof, revision);

  Future<V2TokenData> refresh({required String refreshToken}) {
    return _client.requestData<V2TokenData>(
      ApiPaths.authTokensCurrent,
      method: 'PATCH',
      data: {'refresh_token': refreshToken},
      sendAuth: false,
      decode: (data) => V2TokenData.fromSessionJson(toMap(data)),
    );
  }

  Future<void> logout() async {
    await _client.request<void>(
      ApiPaths.authTokensCurrent,
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<PagedResult<V2SessionItem>> listSessions({int page = 1}) {
    return _client.requestPaged<V2SessionItem>(
      ApiPaths.authSessions,
      query: {'page': page, 'page_size': 20},
      decodeItem: (data) => V2SessionItem.fromJson(toMap(data)),
    );
  }

  Future<void> revokeSession(String sessionId) async {
    await _client.request<void>(
      '${ApiPaths.authSessions}/$sessionId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<void> revokeOtherSessions() async {
    await _client.request<void>(
      ApiPaths.authSessionsOthers,
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<void> requestPasswordReset({
    required String email,
    required String verificationId,
    required String code,
    required String newPassword,
  }) async {
    await _client.request<void>(
      ApiPaths.authPasswordReset,
      method: 'POST',
      data: {
        'email': email,
        'verification_id': verificationId,
        'code': code,
        'new_password': newPassword,
      },
      sendAuth: false,
      decode: (_) {},
    );
  }
}

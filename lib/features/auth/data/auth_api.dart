import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';
import '../domain/auth_models.dart';
import '../domain/github_oauth_models.dart';
import '../domain/passkey_models.dart';

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
  }) {
    return _loginRequest(ApiPaths.authTokens, {
      'account': account,
      'password': password,
      'remember_me': rememberMe,
    }, parseLoginResult);
  }

  Future<PasskeyChallenge> beginPasskeyRegistration() =>
      _beginPasskey(ApiPaths.authPasskeyRegistrationOptions, sendAuth: true);

  Future<PasskeyChallenge> beginPasskeyAuthentication() =>
      _beginPasskey(ApiPaths.authPasskeyAuthenticationOptions, sendAuth: false);

  Future<PasskeyChallenge> _beginPasskey(
    String path, {
    required bool sendAuth,
  }) => _client.requestData(
    path,
    method: 'POST',
    sendAuth: sendAuth,
    decode: (data) => PasskeyChallenge.fromJson(toMap(data)),
  );

  Future<PasskeyCredential> verifyPasskeyRegistration({
    required String challengeId,
    required Map<String, dynamic> credential,
    required String label,
  }) => _client.requestData(
    ApiPaths.authPasskeyRegistrationVerification,
    method: 'POST',
    data: {
      'challenge_id': challengeId,
      'credential': credential,
      if (label.isNotEmpty) 'label': label,
    },
    decode: (data) =>
        PasskeyCredential.fromJson(toMap(toMap(data)['credential'])),
  );

  Future<V2LoginResult> verifyPasskeyAuthentication({
    required String challengeId,
    required Map<String, dynamic> credential,
    required bool rememberMe,
  }) => _loginRequest(ApiPaths.authPasskeyAuthenticationVerification, {
    'challenge_id': challengeId,
    'credential': credential,
    'remember_me': rememberMe,
  }, parseLoginResult);

  Future<List<PasskeyCredential>> listPasskeys() => _client.requestData(
    ApiPaths.usersMePasskeys,
    decode: (data) {
      final credentials = toMap(data)['credentials'];
      if (credentials is! List) {
        throw const FormatException('Invalid Passkey list');
      }
      return credentials
          .map((item) => PasskeyCredential.fromJson(toMap(item)))
          .toList(growable: false);
    },
  );

  Future<void> removePasskey(String id) => _client.requestData<void>(
    '${ApiPaths.usersMePasskeys}/${Uri.encodeComponent(id)}',
    method: 'DELETE',
    decode: (_) {},
  );

  Future<T> _loginRequest<T>(
    String path,
    Map<String, Object> data,
    T Function(Map<String, dynamic>) decode, {
    CancelToken? cancelToken,
  }) async {
    final revision = _client.tokenStore.revision;
    final proof = kIsWeb
        ? null
        : await _client.tokenStore.readTrustedDevice(_client.config.apiBaseUrl);
    if (_client.tokenStore.revision != revision) {
      throw StateError('Authentication operation superseded');
    }
    return _client.requestData<T>(
      path,
      method: 'POST',
      data: data,
      sendAuth: false,
      headers: proof == null
          ? null
          : {'Cookie': '${ApiClient.trustedDeviceCookie}=$proof'},
      cancelToken: cancelToken,
      decode: (data) => decode(toMap(data)),
    );
  }

  Future<GitHubOAuthFlow> beginGitHubOAuth({
    required bool signIn,
    required CancelToken cancelToken,
  }) => _client.requestData(
    signIn ? ApiPaths.authGitHubLoginFlows : ApiPaths.usersMeGitHubFlows,
    method: 'POST',
    sendAuth: !signIn,
    cancelToken: cancelToken,
    decode: (data) => GitHubOAuthFlow.fromJson(toMap(data)),
  );

  Future<V2LoginResult?> pollGitHubLogin(
    GitHubOAuthFlow flow, {
    required bool rememberMe,
    required CancelToken cancelToken,
  }) => _loginRequest(
    '${ApiPaths.authGitHubLoginFlows}/${flow.id}/complete',
    {'flow_key': flow.key, 'remember_me': rememberMe},
    (data) => _gitHubCompletion(data, 'login', parseLoginResult),
    cancelToken: cancelToken,
  );

  Future<GitHubLink?> pollGitHubLink(
    GitHubOAuthFlow flow, {
    required CancelToken cancelToken,
  }) => _client.requestData(
    '${ApiPaths.usersMeGitHubFlows}/${flow.id}/complete',
    method: 'POST',
    data: {'flow_key': flow.key},
    cancelToken: cancelToken,
    decode: (data) =>
        _gitHubCompletion(toMap(data), 'link', GitHubLink.fromJson),
  );

  T? _gitHubCompletion<T>(
    Map<String, dynamic> data,
    String key,
    T Function(Map<String, dynamic>) decode,
  ) {
    if (data['status'] == 'pending') return null;
    if (data['status'] != 'completed' || data[key] is! Map) {
      throw const FormatException('Invalid GitHub OAuth completion');
    }
    return decode(toMap(data[key]));
  }

  Future<GitHubLink?> readGitHubLink() => _client.requestData(
    ApiPaths.usersMeGitHub,
    decode: (data) {
      final receipt = toMap(data);
      if (!receipt.containsKey('link')) {
        throw const FormatException('Invalid GitHub link receipt');
      }
      final link = receipt['link'];
      return link == null ? null : GitHubLink.fromJson(toMap(link));
    },
  );

  Future<void> removeGitHubLink() => _client.requestData<void>(
    ApiPaths.usersMeGitHub,
    method: 'DELETE',
    decode: (_) {},
  );

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

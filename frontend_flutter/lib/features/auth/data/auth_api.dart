import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';
import '../domain/auth_models.dart';

class AuthApi {
  AuthApi(this._client);

  final ApiClient _client;

  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
  }) {
    return _client.requestData<V2AuthOtpData>(
      ApiPaths.authOtp,
      method: 'POST',
      data: {'account': account, 'purpose': purpose},
      sendAuth: false,
      decode: (data) => V2AuthOtpData.fromJson(toMap(data)),
    );
  }

  Future<V2AuthOtpVerificationData> verifyOtp({
    required String account,
    required String purpose,
    required String code,
  }) {
    return _client.requestData<V2AuthOtpVerificationData>(
      ApiPaths.authOtpVerification,
      method: 'POST',
      data: {'account': account, 'purpose': purpose, 'code': code},
      sendAuth: false,
      decode: (data) => V2AuthOtpVerificationData.fromJson(toMap(data)),
    );
  }

  Future<V2LoginSuccess> register({
    required String account,
    required String username,
    required String displayName,
    required String password,
    required String otpCode,
    String? inviteCode,
  }) {
    return _client.requestData<V2LoginSuccess>(
      ApiPaths.authRegistration,
      method: 'POST',
      data: {
        'account': account,
        'username': username,
        'display_name': displayName,
        'password': password,
        'otp_code': otpCode,
        if (inviteCode != null && inviteCode.isNotEmpty)
          'invite_code': inviteCode,
      },
      sendAuth: false,
      decode: (data) {
        final map = toMap(data);
        final user = V2SelfUser.fromJson(toMap(map['user']));
        final tokens = V2TokenData.fromJson(toMap(map['tokens']));
        return V2LoginSuccess(user: user, tokens: tokens);
      },
    );
  }

  Future<V2LoginResult> login({
    required String account,
    required String password,
    bool rememberMe = false,
  }) {
    return _client.requestData<V2LoginResult>(
      ApiPaths.authTokens,
      method: 'POST',
      data: {
        'account': account,
        'password': password,
        'remember_me': rememberMe,
      },
      sendAuth: false,
      decode: (data) => parseLoginResult(toMap(data)),
    );
  }

  Future<V2LoginSuccess> completeTwoFactor({
    required String challengeId,
    required String code,
  }) {
    return _client.requestData<V2LoginSuccess>(
      '${ApiPaths.authTwoFactorChallenges}/$challengeId',
      method: 'POST',
      data: {'code': code},
      sendAuth: false,
      decode: (data) {
        final map = toMap(data);
        final user = V2SelfUser.fromJson(toMap(map['user']));
        final tokens = V2TokenData.fromJson(toMap(map['tokens']));
        return V2LoginSuccess(user: user, tokens: tokens);
      },
    );
  }

  Future<V2TokenData> refresh({required String refreshToken}) {
    return _client.requestData<V2TokenData>(
      ApiPaths.authTokensCurrent,
      method: 'PATCH',
      data: {'refresh_token': refreshToken},
      sendAuth: false,
      decode: (data) => V2TokenData.fromJson(toMap(data)),
    );
  }

  Future<void> logout() async {
    await _client.request<void>(
      ApiPaths.authTokensCurrent,
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<List<V2SessionItem>> listSessions() async {
    final res = await _client.requestData<List<V2SessionItem>>(
      ApiPaths.authSessions,
      decode: (data) {
        final map = toMap(data);
        return toList(
          map['items'],
          (e) => V2SessionItem.fromJson(toMap(e)),
        );
      },
    );
    return res;
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
    required String account,
    required String otpCode,
    required String newPassword,
  }) async {
    await _client.request<void>(
      ApiPaths.authPasswordReset,
      method: 'POST',
      data: {
        'account': account,
        'otp_code': otpCode,
        'new_password': newPassword,
      },
      sendAuth: false,
      decode: (_) {},
    );
  }
}

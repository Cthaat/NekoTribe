import '../../../core/auth/token_store.dart';
import '../../users/domain/user_models.dart';
import '../domain/auth_models.dart';
import 'auth_api.dart';

class AuthRepository {
  AuthRepository({required AuthApi api, required TokenStore tokenStore})
    : _api = api,
      _tokenStore = tokenStore;

  final AuthApi _api;
  final TokenStore _tokenStore;

  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
  }) {
    return _api.requestOtp(account: account, purpose: purpose);
  }

  Future<V2AuthOtpVerificationData> verifyOtp({
    required String account,
    required String purpose,
    required String verificationId,
    required String code,
  }) {
    return _api.verifyOtp(
      account: account,
      purpose: purpose,
      verificationId: verificationId,
      code: code,
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
  }) {
    return _api.register(
      email: email,
      username: username,
      displayName: displayName,
      password: password,
      confirmPassword: confirmPassword,
      verificationId: verificationId,
      agreeToTerms: agreeToTerms,
    );
  }

  Future<V2LoginResult> login({
    required String account,
    required String password,
    bool rememberMe = false,
  }) async {
    final result = await _api.login(
      account: account,
      password: password,
      rememberMe: rememberMe,
    );
    if (result is V2LoginSuccess) {
      await _persistTokens(result.tokens);
    }
    return result;
  }

  Future<V2LoginSuccess> completeTwoFactor({
    required String challengeId,
    required String code,
  }) async {
    final result = await _api.completeTwoFactor(
      challengeId: challengeId,
      code: code,
    );
    await _persistTokens(result.tokens);
    return result;
  }

  Future<void> requestPasswordReset({
    required String email,
    required String verificationId,
    required String code,
    required String newPassword,
  }) {
    return _api.requestPasswordReset(
      email: email,
      verificationId: verificationId,
      code: code,
      newPassword: newPassword,
    );
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {
      // 即使后端登出失败也清理本地令牌
    }
    await _tokenStore.clear();
  }

  Future<bool> hasSession() async {
    final pair = await _tokenStore.read();
    return pair != null;
  }

  Future<void> _persistTokens(V2TokenData tokens) async {
    final accessToken = tokens.accessToken ?? '';
    final refreshToken = tokens.refreshToken ?? '';
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      return;
    }
    final accessExp = tokens.accessTokenExpiresAt;
    final refreshExp = tokens.refreshTokenExpiresAt;
    await _tokenStore.write(
      TokenPair(
        accessToken: accessToken,
        refreshToken: refreshToken,
        sessionId: tokens.sessionId,
        accessTokenExpiresAt: accessExp == null
            ? null
            : DateTime.tryParse(accessExp),
        refreshTokenExpiresAt: refreshExp == null
            ? null
            : DateTime.tryParse(refreshExp),
      ),
    );
  }
}

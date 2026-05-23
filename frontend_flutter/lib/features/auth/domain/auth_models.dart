import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';

class V2TokenData {
  V2TokenData({
    required this.sessionId,
    this.accessToken,
    this.refreshToken,
    this.accessTokenExpiresAt,
    this.refreshTokenExpiresAt,
  });

  final String sessionId;
  final String? accessToken;
  final String? refreshToken;
  final String? accessTokenExpiresAt;
  final String? refreshTokenExpiresAt;

  factory V2TokenData.fromJson(Map<String, dynamic> json) {
    return V2TokenData(
      sessionId: toStr(json['session_id']),
      accessToken: toStrOrNull(json['access_token']),
      refreshToken: toStrOrNull(json['refresh_token']),
      accessTokenExpiresAt: toStrOrNull(json['access_token_expires_at']),
      refreshTokenExpiresAt: toStrOrNull(json['refresh_token_expires_at']),
    );
  }
}

class V2AuthOtpData {
  V2AuthOtpData({
    required this.account,
    required this.verificationId,
    required this.expiresAt,
  });

  final String account;
  final String verificationId;
  final String expiresAt;

  factory V2AuthOtpData.fromJson(Map<String, dynamic> json) {
    return V2AuthOtpData(
      account: toStr(json['account']),
      verificationId: toStr(json['verification_id']),
      expiresAt: toStr(json['expires_at']),
    );
  }
}

class V2AuthOtpVerificationData {
  V2AuthOtpVerificationData({
    required this.account,
    required this.verified,
    required this.verifiedAt,
  });

  final String account;
  final bool verified;
  final String verifiedAt;

  factory V2AuthOtpVerificationData.fromJson(Map<String, dynamic> json) {
    return V2AuthOtpVerificationData(
      account: toStr(json['account']),
      verified: toBool(json['verified']),
      verifiedAt: toStr(json['verified_at']),
    );
  }
}

sealed class V2LoginResult {}

class V2LoginSuccess extends V2LoginResult {
  V2LoginSuccess({required this.user, required this.tokens});
  final V2SelfUser user;
  final V2TokenData tokens;
}

class V2TwoFactorRequired extends V2LoginResult {
  V2TwoFactorRequired({
    required this.challengeId,
    required this.account,
    required this.expiresAt,
  });
  final String challengeId;
  final String account;
  final String expiresAt;
}

V2LoginResult parseLoginResult(Map<String, dynamic> data) {
  if (toBool(data['two_factor_required'])) {
    return V2TwoFactorRequired(
      challengeId: toStr(data['challenge_id']),
      account: toStr(data['account']),
      expiresAt: toStr(data['expires_at']),
    );
  }
  final user = V2SelfUser.fromJson(toMap(data['user']));
  final tokens = V2TokenData.fromJson(toMap(data['tokens']));
  return V2LoginSuccess(user: user, tokens: tokens);
}

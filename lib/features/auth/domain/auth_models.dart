import '../../../core/utils/json_utils.dart';
import '../../../core/auth/token_pair.dart';
import '../../users/domain/user_models.dart';

class V2TokenData {
  factory V2TokenData.fromSessionJson(Map<String, dynamic> data) {
    final pair = TokenPair.fromJson(data);
    final tokens = V2TokenData(
      sessionId: pair.sessionId,
      accessToken: pair.accessToken,
      refreshToken: pair.refreshToken,
      accessTokenExpiresAt: pair.accessTokenExpiresAt!.toIso8601String(),
      refreshTokenExpiresAt: pair.refreshTokenExpiresAt!.toIso8601String(),
    );
    return tokens;
  }

  void validateSession() {
    TokenPair.fromJson({
      'session_id': sessionId,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'access_token_expires_at': accessTokenExpiresAt,
      'refresh_token_expires_at': refreshTokenExpiresAt,
    });
  }

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

  factory V2AuthOtpData.fromJson(
    Map<String, dynamic> json, {
    String? expectedAccount,
  }) {
    return V2AuthOtpData(
      account: _requiredAccount(json['account'], expectedAccount),
      verificationId: _requiredText(json['verification_id']),
      expiresAt: _requiredExpiry(json['expires_at']),
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

  factory V2AuthOtpVerificationData.fromJson(
    Map<String, dynamic> json, {
    String? expectedAccount,
  }) {
    if (json['verified'] != true) {
      throw const FormatException('Invalid authentication data');
    }
    return V2AuthOtpVerificationData(
      account: _requiredAccount(json['account'], expectedAccount),
      verified: true,
      verifiedAt: _requiredExpiry(json['verified_at']),
    );
  }
}

sealed class V2LoginResult {}

class V2LoginSuccess extends V2LoginResult {
  V2LoginSuccess({
    required this.user,
    required this.tokens,
    this.trustedDeviceProof,
  });
  final V2SelfUser user;
  final V2TokenData tokens;
  final String? trustedDeviceProof;
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
  if (data['two_factor_required'] is! bool) {
    throw const FormatException('Invalid login response');
  }
  if (data['two_factor_required'] == true) {
    return V2TwoFactorRequired(
      challengeId: _requiredText(data['challenge_id']),
      account: _requiredText(data['account']),
      expiresAt: _requiredExpiry(data['expires_at']),
    );
  }
  return parseLoginSuccess(data);
}

V2LoginSuccess parseLoginSuccess(Map<String, dynamic> data) {
  if (data.containsKey('two_factor_required') &&
      data['two_factor_required'] != false) {
    throw const FormatException('Invalid login success');
  }
  final identity = _requiredIdentity(data['user']);
  final user = V2SelfUser.fromJson(identity);
  final tokens = V2TokenData.fromSessionJson(toMap(data['tokens']));
  return V2LoginSuccess(user: user, tokens: tokens);
}

Map<String, dynamic> _requiredIdentity(Object? value) {
  final identity = toMap(value);
  final id = identity['user_id'];
  if (id is! int || id < 1 || id > 9007199254740991) {
    throw const FormatException('Invalid login identity');
  }
  _requiredText(identity['username']);
  return identity;
}

V2SelfUser parseRegistrationUser(
  Map<String, dynamic> data, {
  required String email,
  required String username,
}) {
  final identity = _requiredIdentity(data['user']);
  _requiredAccount(identity['email'], email);
  if (identity['username'] != username.trim()) {
    throw const FormatException('Invalid authentication data');
  }
  return V2SelfUser.fromJson(identity);
}

String _requiredAccount(Object? value, String? expected) {
  final account = _requiredText(value);
  if (expected != null && account != expected.trim()) {
    throw const FormatException('Invalid authentication data');
  }
  return account;
}

String _requiredText(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Invalid authentication data');
  }
  return value;
}

String _requiredExpiry(Object? value) {
  final text = _requiredText(value);
  parseSessionExpiry(text);
  return text;
}

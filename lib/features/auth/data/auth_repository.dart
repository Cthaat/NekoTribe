import '../../../core/auth/token_store.dart';
import 'package:flutter/foundation.dart';
import '../../users/domain/user_models.dart';
import '../domain/auth_models.dart';
import 'auth_api.dart';

class SessionClearReceipt {
  const SessionClearReceipt(this.revision);
  final int revision;
}

typedef SessionClearedCallback = Future<void> Function(int revision);

class AuthRepository {
  AuthRepository({
    required AuthApi api,
    required TokenStore tokenStore,
    SessionClearedCallback? onSessionCleared,
  }) : _api = api,
       _tokenStore = tokenStore,
       _onSessionCleared = onSessionCleared;

  final AuthApi _api;
  final TokenStore _tokenStore;
  final SessionClearedCallback? _onSessionCleared;
  int get sessionRevision => _tokenStore.revision;
  bool get isSessionChanging => _tokenStore.isSessionChanging;
  VoidCallback listenSessionChanges(VoidCallback listener) =>
      _tokenStore.listenSessionChanges(listener);
  bool isCurrentReceipt(SessionClearReceipt receipt) =>
      sessionRevision == receipt.revision;

  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
  }) async {
    _tokenStore.requireSessionStorage();
    return _api.requestOtp(account: account, purpose: purpose);
  }

  Future<V2AuthOtpVerificationData> verifyOtp({
    required String account,
    required String purpose,
    required String verificationId,
    required String code,
  }) async {
    _tokenStore.requireSessionStorage();
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
  }) async {
    _tokenStore.requireSessionStorage();
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
    _tokenStore.requireSessionStorage();
    return _tokenStore.runSessionChange((revision) async {
      final result = await _api.login(
        account: account,
        password: password,
        rememberMe: rememberMe,
      );
      if (result is V2LoginSuccess) {
        await _persistTokens(result.tokens, revision);
      }
      _requireCurrent(revision);
      return result;
    });
  }

  Future<V2LoginSuccess> completeTwoFactor({
    required String challengeId,
    required String code,
  }) async {
    _tokenStore.requireSessionStorage();
    return _tokenStore.runSessionChange((revision) async {
      final result = await _api.completeTwoFactor(
        challengeId: challengeId,
        code: code,
      );
      await _persistTokens(result.tokens, revision);
      final proof = result.trustedDeviceProof;
      if (proof != null) await _api.rememberTrustedDevice(proof, revision);
      _requireCurrent(revision);
      return result;
    });
  }

  Future<SessionClearReceipt> requestPasswordReset({
    required String email,
    required String verificationId,
    required String code,
    required String newPassword,
  }) async {
    _tokenStore.requireSessionStorage();
    final revision = sessionRevision;
    await _api.requestPasswordReset(
      email: email,
      verificationId: verificationId,
      code: code,
      newPassword: newPassword,
    );
    _requireCurrent(revision);
    final receipt = await _clearCurrentSession(revision);
    if (receipt == null) {
      throw StateError('Authentication operation superseded');
    }
    return receipt;
  }

  Future<SessionClearReceipt?> logout() =>
      _tokenStore.runSessionChange((revision) async {
        try {
          await _api.logout();
        } catch (_) {
          // 即使后端登出失败也清理本地令牌
        }
        return _clearCurrentSession(revision);
      });

  Future<SessionClearReceipt?> clearAfterCredentialMutation(
    int expectedRevision,
  ) => _clearCurrentSession(expectedRevision);

  Future<SessionClearReceipt?> _clearCurrentSession(int revision) async {
    final clearedRevision = revision + 1;
    try {
      if (!await _tokenStore.clearIfCurrent(revision)) return null;
    } catch (_) {
      if (sessionRevision == clearedRevision) {
        await _onSessionCleared?.call(clearedRevision);
      }
      rethrow;
    }
    if (sessionRevision != clearedRevision) return null;
    await _onSessionCleared?.call(clearedRevision);
    if (sessionRevision != clearedRevision) return null;
    return SessionClearReceipt(clearedRevision);
  }

  Future<bool> hasSession() async {
    final pair = await _tokenStore.read();
    return pair != null;
  }

  void _requireCurrent(int revision) {
    if (_tokenStore.revision != revision) {
      throw StateError('Authentication operation superseded');
    }
  }

  Future<void> _persistTokens(V2TokenData tokens, int revision) async {
    tokens.validateSession();
    final accessToken = tokens.accessToken ?? '';
    final refreshToken = tokens.refreshToken ?? '';
    final accessExp = tokens.accessTokenExpiresAt;
    final refreshExp = tokens.refreshTokenExpiresAt;
    final stored = await _tokenStore.writeIfCurrent(
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
      revision,
    );
    if (!stored) throw StateError('Authentication operation superseded');
  }
}

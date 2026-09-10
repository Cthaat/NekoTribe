import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../constants/storage_keys.dart';

class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.sessionId,
    this.accessTokenExpiresAt,
    this.refreshTokenExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String sessionId;
  final DateTime? accessTokenExpiresAt;
  final DateTime? refreshTokenExpiresAt;

  bool get isAccessExpired {
    final expires = accessTokenExpiresAt;
    if (expires == null) return false;
    return DateTime.now().isAfter(expires);
  }

  bool get isRefreshExpired {
    final expires = refreshTokenExpiresAt;
    if (expires == null) return false;
    return DateTime.now().isAfter(expires);
  }
}

class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  TokenPair? _cached;
  String? _deviceFingerprintCache;

  Future<TokenPair?> read() async {
    if (_cached != null) return _cached;
    final access = await _storage.read(key: StorageKeys.accessToken);
    final refresh = await _storage.read(key: StorageKeys.refreshToken);
    final session = await _storage.read(key: StorageKeys.sessionId);
    if (access == null ||
        access.isEmpty ||
        refresh == null ||
        refresh.isEmpty ||
        session == null ||
        session.isEmpty) {
      return null;
    }
    final accessExp = await _storage.read(
      key: StorageKeys.accessTokenExpiresAt,
    );
    final refreshExp = await _storage.read(
      key: StorageKeys.refreshTokenExpiresAt,
    );
    _cached = TokenPair(
      accessToken: access,
      refreshToken: refresh,
      sessionId: session,
      accessTokenExpiresAt: accessExp == null
          ? null
          : DateTime.tryParse(accessExp),
      refreshTokenExpiresAt: refreshExp == null
          ? null
          : DateTime.tryParse(refreshExp),
    );
    return _cached;
  }

  Future<void> write(TokenPair pair) async {
    _cached = pair;
    await _storage.write(key: StorageKeys.accessToken, value: pair.accessToken);
    await _storage.write(
      key: StorageKeys.refreshToken,
      value: pair.refreshToken,
    );
    await _storage.write(key: StorageKeys.sessionId, value: pair.sessionId);
    if (pair.accessTokenExpiresAt != null) {
      await _storage.write(
        key: StorageKeys.accessTokenExpiresAt,
        value: pair.accessTokenExpiresAt!.toIso8601String(),
      );
    }
    if (pair.refreshTokenExpiresAt != null) {
      await _storage.write(
        key: StorageKeys.refreshTokenExpiresAt,
        value: pair.refreshTokenExpiresAt!.toIso8601String(),
      );
    }
  }

  Future<void> updateAccess({
    required String accessToken,
    DateTime? accessTokenExpiresAt,
    String? refreshToken,
    DateTime? refreshTokenExpiresAt,
  }) async {
    final current = await read();
    if (current == null) return;
    final next = TokenPair(
      accessToken: accessToken,
      refreshToken: refreshToken ?? current.refreshToken,
      sessionId: current.sessionId,
      accessTokenExpiresAt:
          accessTokenExpiresAt ?? current.accessTokenExpiresAt,
      refreshTokenExpiresAt:
          refreshTokenExpiresAt ?? current.refreshTokenExpiresAt,
    );
    await write(next);
  }

  Future<void> clear() async {
    _cached = null;
    await _storage.delete(key: StorageKeys.accessToken);
    await _storage.delete(key: StorageKeys.refreshToken);
    await _storage.delete(key: StorageKeys.sessionId);
    await _storage.delete(key: StorageKeys.accessTokenExpiresAt);
    await _storage.delete(key: StorageKeys.refreshTokenExpiresAt);
    await _storage.delete(key: StorageKeys.currentUser);
  }

  Future<String> deviceFingerprint() async {
    if (_deviceFingerprintCache != null) return _deviceFingerprintCache!;
    var fp = await _storage.read(key: StorageKeys.deviceFingerprint);
    if (fp == null || fp.isEmpty) {
      fp = 'fp_${const Uuid().v4()}';
      await _storage.write(key: StorageKeys.deviceFingerprint, value: fp);
    }
    _deviceFingerprintCache = fp;
    return fp;
  }
}

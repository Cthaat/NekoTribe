import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../constants/storage_keys.dart';
import 'session_storage_support.dart'
    if (dart.library.js_interop) 'session_storage_support_web.dart';
import 'token_pair.dart';
export 'token_pair.dart';

final _trustedDevicePattern = RegExp(r'^td1_[0-9a-f]{64}$');

bool isTrustedDeviceProof(String proof) =>
    proof.length == 68 && _trustedDevicePattern.hasMatch(proof);

class SessionStorageUnavailable implements Exception {
  const SessionStorageUnavailable();
}

class _SessionChangeSignal extends ChangeNotifier {
  void publish() => notifyListeners();
}

class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  TokenPair? _cached;
  String? _deviceFingerprintCache;
  Future<void> _operations = Future<void>.value();
  int _revision = 0;
  int _endpointRevision = 0;
  int _pendingSessionChanges = 0;
  final _sessionChanges = _SessionChangeSignal();
  int get revision => _revision;
  int get endpointRevision => _endpointRevision;
  bool get supportsSessionStorage => sessionStorageSupported;

  void requireSessionStorage() {
    if (!supportsSessionStorage) throw const SessionStorageUnavailable();
  }

  bool get isSessionChanging => _pendingSessionChanges > 0;
  VoidCallback listenSessionChanges(VoidCallback listener) {
    _sessionChanges.addListener(listener);
    return () => _sessionChanges.removeListener(listener);
  }

  int beginSessionChange() {
    final revision = ++_revision;
    _sessionChanges.publish();
    return revision;
  }

  Future<T> runSessionChange<T>(Future<T> Function(int revision) action) async {
    _pendingSessionChanges++;
    final revision = beginSessionChange();
    try {
      return await action(revision);
    } finally {
      _pendingSessionChanges--;
      _sessionChanges.publish();
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<TokenPair?> read() => _exclusive(_readPair);

  String _trustedDeviceKey(String endpoint) =>
      'nekotribe.trusted_device.${Uri.encodeComponent(endpoint)}';

  Future<String?> readTrustedDevice(String endpoint) => _exclusive(() async {
    if (!supportsSessionStorage) return null;
    try {
      final proof = await _storage.read(key: _trustedDeviceKey(endpoint));
      return proof != null && isTrustedDeviceProof(proof) ? proof : null;
    } on Exception {
      return null;
    }
  });

  Future<void> rememberTrustedDevice(
    String endpoint,
    String proof,
    int expectedRevision,
  ) => _exclusive(() async {
    if (_revision != expectedRevision ||
        !supportsSessionStorage ||
        !isTrustedDeviceProof(proof)) {
      return;
    }
    final key = _trustedDeviceKey(endpoint);
    try {
      await _storage.write(key: key, value: proof);
      if (_revision != expectedRevision) await _storage.delete(key: key);
    } on Exception {
      // The current login remains valid when the optional device write fails.
    }
  });

  Future<TokenPair?> _readPair() async {
    if (!supportsSessionStorage) return null;
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

  Future<void> write(TokenPair pair) => _exclusive(() => _writePair(pair));

  Future<bool> writeIfCurrent(TokenPair pair, int expectedRevision) =>
      _exclusive(() async {
        if (_revision != expectedRevision) return false;
        await _writePair(pair);
        if (_revision != expectedRevision) {
          _cached = null;
          await _storage.delete(key: StorageKeys.sessionId);
          return false;
        }
        return true;
      });

  Future<void> _writePair(TokenPair pair) async {
    requireSessionStorage();
    if (pair.sessionId.trim().isEmpty ||
        pair.accessToken.trim().isEmpty ||
        pair.refreshToken.trim().isEmpty) {
      throw const FormatException('Invalid token pair');
    }
    // sessionId is the durable commit marker; readers cannot use partial writes.
    _cached = null;
    await _storage.delete(key: StorageKeys.sessionId);
    await _storage.write(key: StorageKeys.accessToken, value: pair.accessToken);
    await _storage.write(
      key: StorageKeys.refreshToken,
      value: pair.refreshToken,
    );
    if (pair.accessTokenExpiresAt != null) {
      await _storage.write(
        key: StorageKeys.accessTokenExpiresAt,
        value: pair.accessTokenExpiresAt!.toIso8601String(),
      );
    } else {
      await _storage.delete(key: StorageKeys.accessTokenExpiresAt);
    }
    if (pair.refreshTokenExpiresAt != null) {
      await _storage.write(
        key: StorageKeys.refreshTokenExpiresAt,
        value: pair.refreshTokenExpiresAt!.toIso8601String(),
      );
    } else {
      await _storage.delete(key: StorageKeys.refreshTokenExpiresAt);
    }
    await _storage.write(key: StorageKeys.sessionId, value: pair.sessionId);
    _cached = pair;
  }

  Future<void> updateAccess({
    required String accessToken,
    DateTime? accessTokenExpiresAt,
    String? refreshToken,
    DateTime? refreshTokenExpiresAt,
  }) => _exclusive(() async {
    final current = await _readPair();
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
    await _writePair(next);
  });

  Future<void> clear() => runSessionChange((_) => _exclusive(_clearPair));

  // Let already queued credential writes finish before invalidating old clients.
  Future<void> switchEndpoint(void Function() publish) => _exclusive(() async {
    _endpointRevision++;
    await runSessionChange((_) async => publish());
  });

  Future<bool> _hasStoredSession() async {
    if (_cached != null) return true;
    if (!supportsSessionStorage) return false;
    for (final key in const [
      StorageKeys.sessionId,
      StorageKeys.accessToken,
      StorageKeys.refreshToken,
      StorageKeys.currentUser,
    ]) {
      final value = await _storage.read(key: key);
      if (value != null && value.isNotEmpty) return true;
    }
    return false;
  }

  Future<bool> clearIfCurrent(int expectedRevision) => _exclusive(() async {
    if (_revision != expectedRevision) return false;
    if (!await _hasStoredSession()) return false;
    if (_revision != expectedRevision) return false;
    return runSessionChange((_) async {
      await _clearPair();
      return true;
    });
  });

  Future<void> _clearPair() async {
    _cached = null;
    if (!supportsSessionStorage) return;
    await _storage.delete(key: StorageKeys.sessionId);
    await _storage.delete(key: StorageKeys.accessToken);
    await _storage.delete(key: StorageKeys.refreshToken);
    await _storage.delete(key: StorageKeys.accessTokenExpiresAt);
    await _storage.delete(key: StorageKeys.refreshTokenExpiresAt);
    await _storage.delete(key: StorageKeys.currentUser);
  }

  Future<String> deviceFingerprint() async {
    requireSessionStorage();
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

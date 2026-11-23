import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/token_store.dart';
import '../../../core/constants/storage_keys.dart';
import '../../realtime/data/realtime_service.dart'
    show realtimeUserIdFromAccessToken;

typedef LocalPostDraftText = ({String text, bool markdown});

final localPostDraftStoreProvider = Provider<LocalPostDraftStore>(
  (_) => LocalPostDraftStore(),
);

class LocalPostDraftStore {
  Future<void> _pending = Future.value();

  Future<T> _access<T>(
    FutureOr<T> Function(SharedPreferences prefs) operation,
  ) {
    final next = _pending.then((_) async {
      return await operation(await SharedPreferences.getInstance());
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  LocalPostDraftText? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, Object?> &&
          value['text'] is String &&
          value['markdown'] is bool) {
        return (
          text: value['text'] as String,
          markdown: value['markdown'] as bool,
        );
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<LocalPostDraftText?> read(String key) =>
      _access((prefs) => _decode(prefs.getString(key)));

  Future<bool> save(String key, LocalPostDraftText draft) => _access((prefs) {
    if (!draft.markdown && draft.text.isEmpty) return prefs.remove(key);
    return prefs.setString(
      key,
      jsonEncode({'text': draft.text, 'markdown': draft.markdown}),
    );
  });

  Future<bool> clear(String key, {LocalPostDraftText? expected}) =>
      _access((prefs) {
        if (expected != null && _decode(prefs.getString(key)) != expected) {
          return true;
        }
        return prefs.remove(key);
      });
}

class LocalPostDraftSession {
  LocalPostDraftSession({
    required LocalPostDraftStore storage,
    required TokenStore tokens,
    required String backend,
    int? groupId,
  }) : _storage = storage,
       _tokens = tokens,
       _revision = tokens.revision,
       _endpoint = tokens.endpointRevision {
    _key = _resolveKey(backend, groupId);
  }

  final LocalPostDraftStore _storage;
  final TokenStore _tokens;
  final int _revision;
  final int _endpoint;
  late final Future<String?> _key;
  bool _closed = false;
  bool _canRestore = true;
  LocalPostDraftText? snapshot;

  bool get _isCurrent =>
      !_closed &&
      !_tokens.isSessionChanging &&
      _tokens.revision == _revision &&
      _tokens.endpointRevision == _endpoint;

  bool get canRestore => _isCurrent && _canRestore;

  Future<String?> _resolveKey(String backend, int? groupId) async {
    try {
      final pair = await _tokens.read();
      if (!_isCurrent || pair == null) return null;
      final userId = realtimeUserIdFromAccessToken(pair.accessToken);
      if (userId == null) return null;
      final base = Uri.encodeComponent(
        backend.replaceFirst(RegExp(r'/+$'), ''),
      );
      final scope = groupId == null ? 'post' : 'group.$groupId';
      return '${StorageKeys.draftPost}.v1.$base.$userId.$scope';
    } catch (_) {
      return null;
    }
  }

  Future<LocalPostDraftText?> restore() async {
    try {
      final key = await _key;
      if (!canRestore || key == null) return null;
      final saved = await _storage.read(key);
      return canRestore ? saved : null;
    } catch (_) {
      return null;
    }
  }

  void acceptRestored(LocalPostDraftText restored) {
    if (!canRestore) return;
    _canRestore = false;
    snapshot = restored;
  }

  void preventRestore() => _canRestore = false;

  void invalidate() => _closed = true;

  void update(LocalPostDraftText draft) {
    preventRestore();
    if (!_isCurrent || draft == snapshot) return;
    snapshot = draft;
    unawaited(_save(draft));
  }

  Future<void> _save(LocalPostDraftText draft) async {
    try {
      final key = await _key;
      if (key != null && _isCurrent) await _storage.save(key, draft);
    } catch (_) {
      // Local draft storage is optional and must not interrupt composing.
    }
  }

  Future<bool> discard() async {
    preventRestore();
    snapshot = null;
    return _clear();
  }

  Future<void> clearPublished(LocalPostDraftText? published) async {
    if (published == null) return;
    preventRestore();
    await _clear(expected: published);
    if (snapshot == published) snapshot = null;
  }

  Future<bool> _clear({LocalPostDraftText? expected}) async {
    try {
      final key = await _key;
      return key == null ||
          !_isCurrent ||
          await _storage.clear(key, expected: expected);
    } catch (_) {
      return false;
    }
  }
}

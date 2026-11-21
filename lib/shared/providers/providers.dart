import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/token_store.dart';
import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/asset_url_resolver.dart';
import '../../features/auth/data/auth_api.dart';
import '../../features/ai/data/ai_writing_api.dart';
import '../../features/ai/data/ai_group_draft_api.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/chat/data/chat_api.dart';
import '../../features/groups/data/groups_api.dart';
import '../../features/media/data/media_api.dart';
import '../../features/moderation/data/moderation_api.dart';
import '../../features/notifications/data/notifications_api.dart';
import '../../features/posts/data/posts_api.dart';
import '../../features/posts/domain/post_models.dart';
import '../../features/realtime/data/realtime_service.dart';
import '../../features/sentiment_flow/data/sentiment_flow_api.dart';
import '../../features/users/data/users_api.dart';
import '../../features/users/data/users_repository.dart';

/// 由 `main()` 中通过 `ProviderScope.overrides` 注入的资源包（assets/config/app_config.json 解析结果）。
final appConfigBundleProvider = Provider<AppConfigBundle>((ref) {
  throw UnimplementedError(
    'appConfigBundleProvider must be overridden in main() with the asset-loaded AppConfigBundle.',
  );
});

/// 由 `main()` 中通过 `ProviderScope.overrides` 注入的启动时初始配置。
final appConfigInitialProvider = Provider<AppConfig>((ref) {
  throw UnimplementedError(
    'appConfigInitialProvider must be overridden in main() with the merged initial AppConfig.',
  );
});

/// 运行时可切换的端点配置；UI 通过 `ref.read(appConfigProvider.notifier)` 修改。
final appConfigProvider = StateNotifierProvider<AppConfigController, AppConfig>(
  (ref) {
    return AppConfigController(
      bundle: ref.watch(appConfigBundleProvider),
      initial: ref.watch(appConfigInitialProvider),
      tokenStore: ref.watch(tokenStoreProvider),
    );
  },
);

class AppConfigController extends StateNotifier<AppConfig> {
  AppConfigController({
    required this.bundle,
    required AppConfig initial,
    required TokenStore tokenStore,
    Uri? browserPage,
  }) : browserPage = browserPage ?? currentBrowserPage,
       _tokenStore = tokenStore,
       super(initial);

  final AppConfigBundle bundle;
  final Uri? browserPage;
  final TokenStore _tokenStore;
  Future<void> _writes = Future<void>.value();

  List<EndpointPreset> get presets => bundle.presets;

  EndpointPreset? presetById(String id) {
    for (final p in bundle.presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 切换为预置端点；id 必须存在于 bundle.presets 中。
  Future<void> selectPreset(String id) async {
    final preset = presetById(id);
    if (preset == null) return;
    final next = AppConfig.fromCustom(
      apiBaseUrl: preset.apiBaseUrl,
      wsBaseUrl: preset.wsBaseUrl,
      storageBaseUrl: preset.storageBaseUrl,
    ).copyWith(presetId: preset.id);
    await _apply(next);
  }

  /// 切换为用户自定义端点（presetId = 'custom'）。
  Future<void> setCustom({
    required String apiBaseUrl,
    String wsBaseUrl = '',
    String storageBaseUrl = '',
  }) async {
    final next = AppConfig.fromCustom(
      apiBaseUrl: apiBaseUrl,
      wsBaseUrl: wsBaseUrl,
      storageBaseUrl: storageBaseUrl,
    );
    await _apply(next);
  }

  /// 恢复本次构建的默认值，清除已保存的端点配置。
  Future<void> resetToDefaults() =>
      _apply(AppConfigLoader.buildDefaults(bundle), clearOverride: true);

  Future<void> _apply(AppConfig next, {bool clearOverride = false}) {
    final task = _writes.then((_) async {
      if (!mounted) return;
      if (hasMixedEndpointTransport(next, browserPage)) {
        throw const BrowserEndpointTransportException();
      }
      if (clearOverride) {
        await AppConfigLoader.clearOverride();
      } else {
        await AppConfigLoader.writeOverride(next);
      }
      if (!mounted) return;
      final changed =
          state.apiBaseUrl != next.apiBaseUrl ||
          state.wsBaseUrl != next.wsBaseUrl ||
          state.storageBaseUrl != next.storageBaseUrl;
      if (changed) {
        await _tokenStore.switchEndpoint(() {
          if (mounted) state = next;
        });
      } else if (state.presetId != next.presetId) {
        state = next;
      }
    });
    _writes = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }
}

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

Future<void> _synchronizeLoggedOut(
  Ref ref,
  TokenStore store,
  int revision,
  bool Function() isActive,
) async {
  bool current() =>
      isActive() &&
      identical(ref.read(tokenStoreProvider), store) &&
      store.revision == revision;
  if (!current()) return;
  try {
    await ref.read(realtimeServiceProvider).disconnect();
  } catch (_) {}
  if (!current()) return;
  ref.read(notificationsUnreadProvider.notifier).set(0);
  ref.read(authSessionProvider.notifier).markLoggedOut();
}

final assetUrlResolverProvider = Provider<AssetUrlResolver>((ref) {
  return AssetUrlResolver(ref.watch(appConfigProvider));
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final store = ref.watch(tokenStoreProvider);
  var active = true;
  final client = ApiClient(
    config: ref.watch(appConfigProvider),
    tokenStore: store,
    onLogout: () async {
      final revision = store.revision;
      await _synchronizeLoggedOut(ref, store, revision, () => active);
    },
  );
  ref.onDispose(() {
    active = false;
    client.dispose();
  });
  return client;
});

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final store = ref.watch(tokenStoreProvider);
  var active = true;
  ref.onDispose(() => active = false);
  return AuthRepository(
    api: ref.watch(authApiProvider),
    tokenStore: store,
    onSessionCleared: (revision) =>
        _synchronizeLoggedOut(ref, store, revision, () => active),
  );
});

final usersApiProvider = Provider<UsersApi>(
  (ref) => UsersApi(ref.watch(apiClientProvider)),
);

final usersRepositoryProvider = Provider<UsersRepository>(
  (ref) => UsersRepository(ref.watch(usersApiProvider)),
);

final mediaApiProvider = Provider<MediaApi>(
  (ref) => MediaApi(ref.watch(apiClientProvider)),
);

final postsApiProvider = Provider<PostsApi>(
  (ref) => PostsApi(ref.watch(apiClientProvider)),
);

// Lets an open list card receive confirmed edits made inside its detail route.
final savedPostProvider = StateProvider.autoDispose.family<V2Post?, int>(
  (_, _) => null,
);

final notificationsApiProvider = Provider<NotificationsApi>(
  (ref) => NotificationsApi(ref.watch(apiClientProvider)),
);

final groupsApiProvider = Provider<GroupsApi>(
  (ref) => GroupsApi(ref.watch(apiClientProvider)),
);

final chatApiProvider = Provider<ChatApi>(
  (ref) => ChatApi(ref.watch(apiClientProvider)),
);

final aiWritingApiProvider = Provider<AiWritingApi>(
  (ref) => AiWritingApi(ref.watch(apiClientProvider)),
);

final aiGroupDraftApiProvider = Provider<AiGroupDraftApi>(
  (ref) => AiGroupDraftApi(ref.watch(apiClientProvider)),
);

final aiAvailabilityProvider = FutureProvider.autoDispose<AiAvailability>(
  (ref) => ref.watch(aiWritingApiProvider).availability(),
);

final moderationApiProvider = Provider<ModerationApi>(
  (ref) => ModerationApi(ref.watch(apiClientProvider)),
);

final sentimentFlowApiProvider = Provider<SentimentFlowApi>(
  (ref) => SentimentFlowApi(ref.watch(apiClientProvider)),
);

final realtimeServiceProvider = Provider<RealtimeService>((ref) {
  final service = RealtimeService(
    config: ref.watch(appConfigProvider),
    tokenStore: ref.watch(tokenStoreProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

class AuthSessionState {
  const AuthSessionState({
    required this.isAuthenticated,
    required this.loading,
  });

  final bool isAuthenticated;
  final bool loading;

  AuthSessionState copyWith({bool? isAuthenticated, bool? loading}) {
    return AuthSessionState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      loading: loading ?? this.loading,
    );
  }

  static const initial = AuthSessionState(
    isAuthenticated: false,
    loading: true,
  );
}

class AuthSessionController extends StateNotifier<AuthSessionState> {
  AuthSessionController(this._tokenStore) : super(AuthSessionState.initial) {
    _hydrate();
  }

  final TokenStore _tokenStore;
  int _stateRevision = 0;

  Future<void> _hydrate() async {
    final revision = _stateRevision;
    try {
      final pair = await _tokenStore.read();
      if (!mounted || revision != _stateRevision) return;
      state = AuthSessionState(
        isAuthenticated: pair != null && pair.accessToken.isNotEmpty,
        loading: false,
      );
    } catch (_) {
      if (mounted && revision == _stateRevision) markLoggedOut();
    }
  }

  void markLoggedIn() {
    _stateRevision++;
    state = const AuthSessionState(isAuthenticated: true, loading: false);
  }

  void markLoggedOut() {
    _stateRevision++;
    state = const AuthSessionState(isAuthenticated: false, loading: false);
  }
}

final authSessionProvider =
    StateNotifierProvider<AuthSessionController, AuthSessionState>((ref) {
      return AuthSessionController(ref.watch(tokenStoreProvider));
    });

class NotificationsUnreadController extends StateNotifier<int> {
  NotificationsUnreadController(this._ref) : super(0);

  final Ref _ref;
  int _requestRevision = 0;

  void set(int count) {
    _requestRevision++;
    state = count < 0 ? 0 : count;
  }

  Future<void> refresh() async {
    final request = ++_requestRevision;
    final store = _ref.read(tokenStoreProvider);
    if (store.isSessionChanging) return;
    final revision = store.revision;
    final endpoint = store.endpointRevision;
    try {
      final api = _ref.read(notificationsApiProvider);
      final count = await api.unreadCount();
      if (!mounted ||
          request != _requestRevision ||
          !identical(store, _ref.read(tokenStoreProvider)) ||
          store.revision != revision ||
          store.endpointRevision != endpoint ||
          store.isSessionChanging ||
          !identical(api, _ref.read(notificationsApiProvider))) {
        return;
      }
      state = count < 0 ? 0 : count;
    } catch (_) {
      // Keep the previous value on transient failures.
    }
  }
}

final notificationsUnreadProvider =
    StateNotifierProvider<NotificationsUnreadController, int>((ref) {
      return NotificationsUnreadController(ref);
    });

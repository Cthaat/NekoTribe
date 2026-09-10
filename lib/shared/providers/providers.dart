import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/token_store.dart';
import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/asset_url_resolver.dart';
import '../../features/auth/data/auth_api.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/chat/data/chat_api.dart';
import '../../features/groups/data/groups_api.dart';
import '../../features/media/data/media_api.dart';
import '../../features/moderation/data/moderation_api.dart';
import '../../features/notifications/data/notifications_api.dart';
import '../../features/posts/data/posts_api.dart';
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
    );
  },
);

class AppConfigController extends StateNotifier<AppConfig> {
  AppConfigController({required this.bundle, required AppConfig initial})
    : super(initial);

  final AppConfigBundle bundle;

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
    final next = AppConfig(
      presetId: preset.id,
      apiBaseUrl: preset.apiBaseUrl,
      wsBaseUrl: preset.wsBaseUrl,
      storageBaseUrl: preset.storageBaseUrl,
    );
    state = next;
    await AppConfigLoader.writeOverride(next);
  }

  /// 切换为用户自定义端点（presetId = 'custom'）。
  Future<void> setCustom({
    required String apiBaseUrl,
    required String wsBaseUrl,
    required String storageBaseUrl,
  }) async {
    final next = AppConfig(
      presetId: 'custom',
      apiBaseUrl: apiBaseUrl.trim(),
      wsBaseUrl: wsBaseUrl.trim(),
      storageBaseUrl: storageBaseUrl.trim(),
    );
    state = next;
    await AppConfigLoader.writeOverride(next);
  }

  /// 恢复为 `assets/config/app_config.json` 中的默认值。
  Future<void> resetToDefaults() async {
    state = bundle.defaults;
    await AppConfigLoader.clearOverride();
  }
}

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final assetUrlResolverProvider = Provider<AssetUrlResolver>((ref) {
  return AssetUrlResolver(ref.watch(appConfigProvider));
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(
    config: ref.watch(appConfigProvider),
    tokenStore: ref.watch(tokenStoreProvider),
    onLogout: () async {
      // Forced 401/session death: tear down realtime + badge with auth.
      try {
        await ref.read(realtimeServiceProvider).disconnect();
      } catch (_) {}
      ref.read(notificationsUnreadProvider.notifier).set(0);
      ref.read(authSessionProvider.notifier).markLoggedOut();
    },
  );
  return client;
});

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    api: ref.watch(authApiProvider),
    tokenStore: ref.watch(tokenStoreProvider),
  ),
);

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

final notificationsApiProvider = Provider<NotificationsApi>(
  (ref) => NotificationsApi(ref.watch(apiClientProvider)),
);

final groupsApiProvider = Provider<GroupsApi>(
  (ref) => GroupsApi(ref.watch(apiClientProvider)),
);

final chatApiProvider = Provider<ChatApi>(
  (ref) => ChatApi(ref.watch(apiClientProvider)),
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
  ref.onDispose(service.disconnect);
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

  Future<void> _hydrate() async {
    final pair = await _tokenStore.read();
    state = AuthSessionState(
      isAuthenticated: pair != null && pair.accessToken.isNotEmpty,
      loading: false,
    );
  }

  void markLoggedIn() {
    state = const AuthSessionState(isAuthenticated: true, loading: false);
  }

  void markLoggedOut() {
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

  void set(int count) {
    state = count < 0 ? 0 : count;
  }

  Future<void> refresh() async {
    try {
      final count = await _ref.read(notificationsApiProvider).unreadCount();
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/auth/presentation/terms_screen.dart';
import '../../features/auth/presentation/two_factor_screen.dart';
import '../../features/chat/presentation/channel_screen.dart';
import '../../features/chat/presentation/chat_home_screen.dart';
import '../../features/chat/presentation/conversation_screen.dart';
import '../../features/groups/presentation/group_manage_screen.dart';
import '../../features/groups/presentation/group_detail_screen.dart';
import '../../features/groups/presentation/group_post_detail_screen.dart';
import '../../features/groups/presentation/group_posts_screen.dart';
import '../../features/groups/presentation/groups_screen.dart';
import '../../features/moderation/presentation/moderation_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/posts/presentation/compose_post_screen.dart';
import '../../features/posts/presentation/edit_post_screen.dart';
import '../../features/posts/presentation/feed_screen.dart';
import '../../features/posts/presentation/post_detail_screen.dart';
import '../../features/posts/presentation/search_screen.dart';
import '../../features/posts/presentation/tag_screen.dart';
import '../../features/posts/presentation/tweet_timeline_screen.dart';
import '../../features/sentiment_flow/presentation/sentiment_screen.dart';
import '../../features/users/presentation/about_screen.dart';
import '../../features/users/presentation/account_analytics_screen.dart';
import '../../features/users/presentation/account_data_analytics_screen.dart';
import '../../features/users/presentation/account_screen.dart';
import '../../features/users/presentation/account_posts_screen.dart';
import '../../features/users/presentation/appearance_screen.dart';
import '../../features/users/presentation/billing_screen.dart';
import '../../features/users/presentation/endpoint_screen.dart';
import '../../features/users/presentation/profile_screen.dart';
import '../../features/users/presentation/profile_edit_screen.dart';
import '../../features/users/presentation/pro_screen.dart';
import '../../features/users/presentation/security_screen.dart';
import '../../features/users/presentation/sessions_screen.dart';
import '../../features/users/presentation/settings_screen.dart';
import '../../features/users/presentation/statements_screen.dart';
import '../../features/users/presentation/user_posts_screen.dart';
import '../providers/providers.dart';
import 'app_shell.dart';

const productionRoutePaths = <String>{
  '/feed',
  '/discover',
  '/notifications',
  '/chat',
  '/me',
  '/auth/login',
  '/auth/register',
  '/auth/sign-up',
  '/auth/forgot',
  '/auth/forgot-password',
  '/auth/2fa',
  '/auth/terms',
  '/meow',
  '/posts/:postId',
  '/posts/:postId/edit',
  '/tweet/:postId',
  '/tweet/search/:search',
  '/tweet/:type/:userId',
  '/tags/:tag',
  '/user/:userId/profile',
  '/user/:userId/notifications',
  '/users/:userId',
  '/users/:userId/posts',
  '/groups',
  '/groups/discover',
  '/groups/my',
  '/groups/invites',
  '/groups/posts',
  '/groups/:slug',
  '/groups/:slug/manage',
  '/groups/:slug/posts/:postId',
  '/chat/conversation/:id',
  '/chat/groups/:groupId/channels/:channelId',
  '/settings',
  '/settings/appearance',
  '/settings/billing',
  '/settings/pro',
  '/settings/security',
  '/settings/sessions',
  '/settings/statements',
  '/settings/endpoint',
  '/account',
  '/account/overview',
  '/account/analytics',
  '/account/data',
  '/account/profile',
  '/account/settings',
  '/account/appearance',
  '/account/billing',
  '/account/pro',
  '/account/security',
  '/account/active',
  '/account/statements',
  '/account/posts',
  '/account/likes',
  '/account/bookmarks',
  '/moderation',
  '/moderation/content',
  '/moderation/reports',
  '/moderation/users',
  '/moderation/appeals',
  '/moderation/settings',
  '/sentiment',
  '/about',
};

bool isPublicRoutePath(String path) {
  final uriPath = Uri.tryParse(path)?.path ?? path;
  if (uriPath.startsWith('/auth')) return true;
  return uriPath == '/feed' ||
      uriPath == '/discover' ||
      uriPath == '/about' ||
      uriPath.startsWith('/posts/') ||
      uriPath.startsWith('/tweet/') ||
      uriPath.startsWith('/tags/') ||
      (uriPath.startsWith('/user/') && uriPath.endsWith('/profile')) ||
      uriPath.startsWith('/users/');
}

final routerProvider = Provider<GoRouter>((ref) {
  final session = ref.watch(authSessionProvider);
  return GoRouter(
    initialLocation: '/feed',
    debugLogDiagnostics: false,
    refreshListenable: AuthRefreshNotifier(ref),
    redirect: (context, state) {
      if (session.loading) return null;
      final loggedIn = session.isAuthenticated;
      final path = state.matchedLocation;
      final isAuthPath = path.startsWith('/auth');
      final isPublicPath = isPublicRoutePath(state.uri.path);
      if (!loggedIn && !isAuthPath && !isPublicPath) return '/auth/login';
      if (loggedIn && isAuthPath) return '/feed';
      return null;
    },
    routes: [
      GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/auth/register',
        builder: (_, __) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/auth/sign-up',
        builder: (_, __) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/auth/forgot',
        builder: (_, __) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/auth/forgot-password',
        builder: (_, __) => const ForgotPasswordScreen(),
      ),
      GoRoute(path: '/auth/terms', builder: (_, __) => const TermsScreen()),
      GoRoute(
        path: '/auth/2fa',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return TwoFactorScreen(
            challengeId: extra?['challengeId'] as String? ?? '',
            account: extra?['account'] as String? ?? '',
          );
        },
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/feed', builder: (_, __) => const FeedScreen()),
          // Keep discover in the shell so desktop side rail stays visible.
          // Mobile hides bottom NavigationBar for /discover (see AppShell).
          GoRoute(path: '/discover', builder: (_, __) => const SearchScreen()),
          GoRoute(
            path: '/notifications',
            builder: (_, __) => const NotificationsScreen(),
          ),
          GoRoute(path: '/chat', builder: (_, __) => const ChatHomeScreen()),
          GoRoute(path: '/me', builder: (_, __) => const AccountScreen()),
          GoRoute(path: '/groups', builder: (_, __) => const GroupsScreen()),
          // Keep static group sub-tabs inside the shell so bottom/side nav
          // stays on Groups (must be registered before `/groups/:slug`).
          GoRoute(
            path: '/groups/discover',
            builder: (_, __) => const GroupsScreen(initialTab: 0),
          ),
          GoRoute(
            path: '/groups/my',
            builder: (_, __) => const GroupsScreen(initialTab: 1),
          ),
          GoRoute(
            path: '/groups/invites',
            builder: (_, __) => const GroupsScreen(initialTab: 2),
          ),
          GoRoute(
            path: '/moderation',
            builder: (_, __) => const ModerationScreen(),
          ),
          GoRoute(
            path: '/sentiment',
            builder: (_, __) => const SentimentScreen(),
          ),
          GoRoute(path: '/about', builder: (_, __) => const AboutScreen()),
        ],
      ),
      GoRoute(
        path: '/posts/:postId',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['postId'] ?? '') ?? 0;
          return PostDetailScreen(postId: id);
        },
      ),
      GoRoute(
        path: '/posts/:postId/edit',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['postId'] ?? '') ?? 0;
          return EditPostScreen(postId: id);
        },
      ),
      GoRoute(path: '/meow', builder: (_, __) => const ComposePostScreen()),
      GoRoute(
        path: '/tweet/:postId',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['postId'] ?? '') ?? 0;
          return PostDetailScreen(postId: id);
        },
      ),
      GoRoute(
        path: '/tweet/search/:search',
        builder: (_, state) {
          final query = state.pathParameters['search'] ?? '';
          return SearchScreen(initialQuery: query);
        },
      ),
      GoRoute(
        path: '/tweet/:type/:userId',
        builder: (_, state) {
          final type = state.pathParameters['type'] ?? 'home';
          final userId =
              int.tryParse(state.pathParameters['userId'] ?? '') ?? 0;
          return TweetTimelineScreen(type: type, userId: userId);
        },
      ),
      GoRoute(
        path: '/tags/:tag',
        builder: (_, state) {
          final tag = state.pathParameters['tag'] ?? '';
          return TagScreen(tag: tag);
        },
      ),
      GoRoute(
        path: '/user/:userId/profile',
        builder: (_, state) {
          final userId =
              int.tryParse(state.pathParameters['userId'] ?? '') ?? 0;
          return ProfileScreen(userId: userId);
        },
      ),
      GoRoute(
        path: '/user/:userId/notifications',
        builder: (_, __) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/users/:userId',
        builder: (_, state) {
          final userId =
              int.tryParse(state.pathParameters['userId'] ?? '') ?? 0;
          return ProfileScreen(userId: userId);
        },
      ),
      GoRoute(
        path: '/users/:userId/posts',
        builder: (_, state) {
          final userId =
              int.tryParse(state.pathParameters['userId'] ?? '') ?? 0;
          return UserPostsScreen(userId: userId);
        },
      ),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(
        path: '/settings/appearance',
        builder: (_, __) => const AppearanceScreen(),
      ),
      GoRoute(
        path: '/settings/billing',
        builder: (_, __) => const BillingScreen(),
      ),
      GoRoute(path: '/settings/pro', builder: (_, __) => const ProScreen()),
      GoRoute(
        path: '/settings/security',
        builder: (_, __) => const SecurityScreen(),
      ),
      GoRoute(
        path: '/settings/sessions',
        builder: (_, __) => const SessionsScreen(),
      ),
      GoRoute(
        path: '/settings/statements',
        builder: (_, __) => const StatementsScreen(),
      ),
      GoRoute(
        path: '/settings/endpoint',
        builder: (_, __) => const EndpointScreen(),
      ),
      GoRoute(path: '/account', builder: (_, __) => const AccountScreen()),
      GoRoute(
        path: '/account/overview',
        builder: (_, __) => const AccountAnalyticsScreen(),
      ),
      GoRoute(
        path: '/account/analytics',
        builder: (_, __) => const AccountAnalyticsScreen(),
      ),
      GoRoute(
        path: '/account/data',
        builder: (_, __) => const AccountDataAnalyticsScreen(),
      ),
      GoRoute(
        path: '/account/profile',
        builder: (_, __) => const ProfileEditScreen(),
      ),
      GoRoute(
        path: '/account/settings',
        builder: (_, __) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/account/appearance',
        builder: (_, __) => const AppearanceScreen(),
      ),
      GoRoute(
        path: '/account/billing',
        builder: (_, __) => const BillingScreen(),
      ),
      GoRoute(path: '/account/pro', builder: (_, __) => const ProScreen()),
      GoRoute(
        path: '/account/security',
        builder: (_, __) => const SecurityScreen(),
      ),
      GoRoute(
        path: '/account/active',
        builder: (_, __) => const SessionsScreen(),
      ),
      GoRoute(
        path: '/account/statements',
        builder: (_, __) => const StatementsScreen(),
      ),
      GoRoute(
        path: '/account/posts',
        builder: (_, __) =>
            const AccountPostsScreen(kind: AccountPostsKind.posts),
      ),
      GoRoute(
        path: '/account/likes',
        builder: (_, __) =>
            const AccountPostsScreen(kind: AccountPostsKind.likes),
      ),
      GoRoute(
        path: '/account/bookmarks',
        builder: (_, __) =>
            const AccountPostsScreen(kind: AccountPostsKind.bookmarks),
      ),
      GoRoute(
        path: '/groups/posts',
        builder: (_, __) => const GroupPostsScreen(),
      ),
      GoRoute(
        path: '/groups/:slug',
        builder: (_, state) {
          final slug = state.pathParameters['slug'] ?? '';
          return GroupDetailScreen(slug: slug);
        },
      ),
      GoRoute(
        path: '/groups/:slug/manage',
        builder: (_, state) {
          final slug = state.pathParameters['slug'] ?? '';
          return GroupManageScreen(slug: slug);
        },
      ),
      GoRoute(
        path: '/groups/:slug/posts/:postId',
        builder: (_, state) {
          final slug = state.pathParameters['slug'] ?? '';
          final postId =
              int.tryParse(state.pathParameters['postId'] ?? '') ?? 0;
          return GroupPostDetailScreen(slug: slug, postId: postId);
        },
      ),
      GoRoute(
        path: '/chat/conversation/:id',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
          final title = _routeExtraString(state.extra, const [
            'title',
            'name',
          ]);
          return ConversationScreen(conversationId: id, title: title);
        },
      ),
      GoRoute(
        path: '/chat/groups/:groupId/channels/:channelId',
        builder: (_, state) {
          final groupId =
              int.tryParse(state.pathParameters['groupId'] ?? '') ?? 0;
          final channelId =
              int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0;
          final name = _routeExtraString(state.extra, const [
            'name',
            'title',
            'channelName',
          ]);
          return ChannelScreen(
            groupId: groupId,
            channelId: channelId,
            channelName: name,
          );
        },
      ),
      GoRoute(
        path: '/moderation/content',
        builder: (_, __) => const ModerationScreen(initialTab: 1),
      ),
      GoRoute(
        path: '/moderation/reports',
        builder: (_, __) => const ModerationScreen(initialTab: 2),
      ),
      GoRoute(
        path: '/moderation/users',
        builder: (_, __) => const ModerationScreen(initialTab: 3),
      ),
      GoRoute(
        path: '/moderation/appeals',
        builder: (_, __) => const ModerationScreen(initialTab: 4),
      ),
      GoRoute(
        path: '/moderation/settings',
        builder: (_, __) => const ModerationScreen(initialTab: 5),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('NekoTribe')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.explore_off_outlined, size: 48),
              const SizedBox(height: 12),
              const Text(
                'Page not found',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                state.uri.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/feed'),
                child: const Text('Home'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
});

class AuthRefreshNotifier extends ChangeNotifier {
  AuthRefreshNotifier(Ref ref) {
    ref.listen(authSessionProvider, (prev, next) {
      if (prev?.isAuthenticated != next.isAuthenticated ||
          prev?.loading != next.loading) {
        notifyListeners();
      }
    });
  }
}

String? _routeExtraString(Object? extra, List<String> keys) {
  if (extra is String) {
    final value = extra.trim();
    return value.isEmpty ? null : value;
  }
  if (extra is Map) {
    for (final key in keys) {
      final raw = extra[key];
      if (raw is String) {
        final value = raw.trim();
        if (value.isNotEmpty) return value;
      }
    }
  }
  return null;
}

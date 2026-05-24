import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/auth/presentation/two_factor_screen.dart';
import '../../features/chat/presentation/chat_home_screen.dart';
import '../../features/chat/presentation/conversation_screen.dart';
import '../../features/groups/presentation/group_detail_screen.dart';
import '../../features/groups/presentation/groups_screen.dart';
import '../../features/moderation/presentation/moderation_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/posts/presentation/feed_screen.dart';
import '../../features/posts/presentation/post_detail_screen.dart';
import '../../features/posts/presentation/search_screen.dart';
import '../../features/posts/presentation/tag_screen.dart';
import '../../features/sentiment_flow/presentation/sentiment_screen.dart';
import '../../features/users/presentation/account_screen.dart';
import '../../features/users/presentation/endpoint_screen.dart';
import '../../features/users/presentation/profile_screen.dart';
import '../../features/users/presentation/security_screen.dart';
import '../../features/users/presentation/sessions_screen.dart';
import '../../features/users/presentation/settings_screen.dart';
import '../../features/users/presentation/statements_screen.dart';
import '../providers/providers.dart';
import 'app_shell.dart';

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
      if (!loggedIn && !isAuthPath) return '/auth/login';
      if (loggedIn && isAuthPath) return '/feed';
      return null;
    },
    routes: [
      GoRoute(
        path: '/auth/login',
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: '/auth/register',
        builder: (_, __) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/auth/forgot',
        builder: (_, __) => const ForgotPasswordScreen(),
      ),
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
          GoRoute(
            path: '/feed',
            builder: (_, __) => const FeedScreen(),
          ),
          GoRoute(
            path: '/discover',
            builder: (_, __) => const SearchScreen(),
          ),
          GoRoute(
            path: '/notifications',
            builder: (_, __) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/chat',
            builder: (_, __) => const ChatHomeScreen(),
          ),
          GoRoute(
            path: '/me',
            builder: (_, __) => const AccountScreen(),
          ),
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
        path: '/tags/:tag',
        builder: (_, state) {
          final tag = state.pathParameters['tag'] ?? '';
          return TagScreen(tag: tag);
        },
      ),
      GoRoute(
        path: '/users/:userId',
        builder: (_, state) {
          final userId = int.tryParse(state.pathParameters['userId'] ?? '') ?? 0;
          return ProfileScreen(userId: userId);
        },
      ),
      GoRoute(
        path: '/settings',
        builder: (_, __) => const SettingsScreen(),
      ),
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
      GoRoute(
        path: '/groups',
        builder: (_, __) => const GroupsScreen(),
      ),
      GoRoute(
        path: '/groups/:slug',
        builder: (_, state) {
          final slug = state.pathParameters['slug'] ?? '';
          return GroupDetailScreen(slug: slug);
        },
      ),
      GoRoute(
        path: '/chat/conversation/:id',
        builder: (_, state) {
          final id =
              int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
          return ConversationScreen(conversationId: id);
        },
      ),
      GoRoute(
        path: '/moderation',
        builder: (_, __) => const ModerationScreen(),
      ),
      GoRoute(
        path: '/sentiment',
        builder: (_, __) => const SentimentScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text('Route not found: ${state.uri}')),
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

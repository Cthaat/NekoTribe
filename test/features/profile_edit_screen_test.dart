import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/account_screen.dart';
import 'package:nekotribe/features/users/presentation/profile_edit_screen.dart';
import 'package:nekotribe/features/users/presentation/profile_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('account screen discards a profile from the previous session', (
    tester,
  ) async {
    final tokens = _FakeTokenStore()
      ..pair = const TokenPair(
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        sessionId: 'test-session',
      );
    final previous = Completer<V2SelfUser>();
    final users = _FakeUsersRepository()..nextUser = previous.future;
    final current = V2SelfUser.fromJson({
      'user_id': 2,
      'username': 'current',
      'display_name': 'Current account',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          usersRepositoryProvider.overrideWithValue(users),
          tokenStoreProvider.overrideWithValue(tokens),
        ],
        child: const MaterialApp(home: AccountScreen()),
      ),
    );
    expect(users.selfReads, 1);

    final switching = Completer<void>();
    final transition = tokens.runSessionChange((_) => switching.future);
    previous.complete(_user);
    await tester.pump();
    expect(find.text('Edge'), findsNothing);

    users.nextUser = Future.value(current);
    switching.complete();
    await transition;
    await tester.pumpAndSettle();
    expect(find.text('Current account'), findsOneWidget);
    expect(find.text('Edge'), findsNothing);
    expect(users.selfReads, 2);

    await tokens.runSessionChange((_) async => tokens.pair = null);
    await tester.pumpAndSettle();
    expect(find.text('Current account'), findsNothing);
    expect(users.selfReads, 2);
  });

  testWidgets('public profile stays visible when its posts must be retried', (
    tester,
  ) async {
    final users = _FakeUsersRepository();
    final posts = _ProfilePosts();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          usersRepositoryProvider.overrideWithValue(users),
          postsApiProvider.overrideWithValue(posts),
          tokenStoreProvider.overrideWithValue(_FakeTokenStore()),
        ],
        child: const MaterialApp(home: ProfileScreen(userId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edge'), findsOneWidget);
    expect(find.text('Posts temporarily unavailable'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('Posts temporarily unavailable'), findsNothing);
    expect(find.text('Edge'), findsOneWidget);
    expect(users.publicReads, 1);
    expect(posts.reads, 2);
  });

  testWidgets('profile editor exposes avatar upload action', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          usersRepositoryProvider.overrideWithValue(_FakeUsersRepository()),
        ],
        child: const MaterialApp(home: ProfileEditScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('更换头像'), findsOneWidget);
  });

  testWidgets(
    'profile editor submits phone and birth date, including clearing',
    (tester) async {
      final repository = _FakeUsersRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigBundleProvider.overrideWithValue(_testBundle),
            appConfigInitialProvider.overrideWithValue(_testConfig),
            usersRepositoryProvider.overrideWithValue(repository),
            tokenStoreProvider.overrideWithValue(_FakeTokenStore()),
          ],
          child: const MaterialApp(home: ProfileEditScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final phone = find.byKey(const Key('profile-phone'));
      final birthDate = find.byKey(const Key('profile-birth-date'));
      final save = find.widgetWithText(TextButton, '保存');
      await tester.ensureVisible(phone);
      await tester.enterText(phone, '123456789');
      await tester.ensureVisible(birthDate);
      await tester.enterText(birthDate, '2000-02-30');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repository.privateEdits, isEmpty);

      await tester.enterText(birthDate, '2000-02-29');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repository.privateEdits.single, ('123456789', '2000-02-29'));

      await tester.ensureVisible(phone);
      await tester.enterText(phone, '');
      await tester.ensureVisible(birthDate);
      await tester.enterText(birthDate, '');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repository.privateEdits.last, ('', ''));
    },
  );
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository()
    : super(
        UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())),
      );

  Future<V2SelfUser>? nextUser;
  int selfReads = 0;

  @override
  Future<V2SelfUser> getCurrentUser() {
    selfReads++;
    return nextUser ?? Future.value(_user);
  }

  int publicReads = 0;

  @override
  Future<V2PublicUser> getUserById(int userId) async {
    publicReads++;
    return _user;
  }

  final privateEdits = <(String?, String?)>[];

  @override
  Future<V2SelfUser> updateProfile({
    String? displayName,
    String? bio,
    String? location,
    String? website,
    String? phone,
    String? birthDate,
  }) async {
    privateEdits.add((phone, birthDate));
    return _user;
  }
}

class _ProfilePosts extends PostsApi {
  _ProfilePosts()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  int reads = 0;

  @override
  Future<PagedResult<V2Post>> getUserPostsById(
    int userId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) async {
    if (++reads == 1) {
      throw ApiException(
        code: 50301,
        statusCode: 503,
        message: 'Posts temporarily unavailable',
      );
    }
    return const PagedResult(items: []);
  }
}

final _user = V2SelfUser(
  userId: 1,
  username: 'edge',
  displayName: 'Edge',
  avatarUrl: '',
  bio: '',
  location: '',
  website: '',
  isVerified: 0,
  followersCount: 0,
  followingCount: 0,
  postsCount: 0,
  likesCount: 0,
  relationship: V2Relationship.empty(),
  onlineStatus: 'online',
  email: 'edge@example.test',
  phone: '',
  birthDate: null,
  emailVerifiedAt: '2026-05-24T00:00:00.000Z',
  isActive: 1,
  status: 'active',
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
);

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);

class _FakeTokenStore extends TokenStore {
  TokenPair? pair;

  @override
  Future<TokenPair?> read() async => pair;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/profile_edit_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
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
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository()
    : super(UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())));

  @override
  Future<V2SelfUser> getCurrentUser() async => _user;
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
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}

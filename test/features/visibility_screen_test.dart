import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/visibility_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('clearing a relationship refreshes the corresponding tab', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.screen());
    await tester.pumpAndSettle();
    expect(find.text('Blocked account'), findsOneWidget);
    await tester.tap(find.text('解除拉黑'));
    await tester.pumpAndSettle();
    expect(fixture.users.unblocked, [7]);
    expect(find.text('没有已拉黑的账号。'), findsOneWidget);
    await tester.tap(find.text('已静音'));
    await tester.pumpAndSettle();
    expect(find.text('Muted account'), findsOneWidget);
    expect(find.textContaining('静音至'), findsOneWidget);
    await tester.tap(find.text('取消静音'));
    await tester.pumpAndSettle();
    expect(fixture.users.unmuted, [8]);
    expect(find.text('没有已静音的账号。'), findsOneWidget);
  });

  testWidgets('switching accounts discards the old account list', (
    tester,
  ) async {
    final fixture = _Fixture();
    final pending = Completer<PagedResult<V2PublicUser>>();
    fixture.users.pendingBlocks = pending;
    await tester.pumpWidget(fixture.screen());
    await tester.pump();
    fixture.store.beginSessionChange();
    pending.complete(PagedResult(items: [_user(7, 'Old account result')]));
    await tester.pumpAndSettle();
    expect(find.text('Old account result'), findsNothing);
    expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
  });
}

class _Fixture {
  final store = TokenStore();
  late final client = ApiClient(
    config: const AppConfig(
      apiBaseUrl: 'http://example.test',
      wsBaseUrl: 'ws://example.test',
      storageBaseUrl: 'http://example.test',
    ),
    tokenStore: store,
  );
  late final auth = AuthRepository(api: AuthApi(client), tokenStore: store);
  late final users = _Users(UsersApi(client));

  Widget screen() => ProviderScope(
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      usersRepositoryProvider.overrideWithValue(users),
    ],
    child: const MaterialApp(home: VisibilityScreen()),
  );
}

class _Users extends UsersRepository {
  _Users(super.api);

  Completer<PagedResult<V2PublicUser>>? pendingBlocks;
  final unblocked = <int>[];
  final unmuted = <int>[];

  @override
  Future<PagedResult<V2PublicUser>> blocks({
    int page = 1,
    int size = 20,
  }) async {
    final pending = pendingBlocks;
    if (pending != null) return pending.future;
    return PagedResult(
      items: [if (unblocked.isEmpty) _user(7, 'Blocked account')],
    );
  }

  @override
  Future<PagedResult<V2PublicUser>> mutes({int page = 1, int size = 20}) async {
    return PagedResult(
      items: [
        if (unmuted.isEmpty)
          _user(8, 'Muted account', '2027-01-01T12:00:00.000Z'),
      ],
    );
  }

  @override
  Future<void> unblockUser(int userId) async {
    unblocked.add(userId);
  }

  @override
  Future<void> unmuteUser(int userId) async {
    unmuted.add(userId);
  }
}

V2PublicUser _user(int id, String name, [String? expiry]) =>
    V2PublicUser.fromJson({
      'user_id': id,
      'display_name': name,
      'expires_at': expiry,
    });

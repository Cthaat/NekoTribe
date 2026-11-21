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
import 'package:nekotribe/features/users/presentation/statements_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('a warning supports filtering, acknowledgement and an appeal', (
    tester,
  ) async {
    final f = _Fixture();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(f.screen());
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部类型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('警告').last);
    await tester.pumpAndSettle();
    expect(f.users.type, 'warning');
    await tester.tap(find.byTooltip('处置记录操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记已读'));
    await tester.pumpAndSettle();
    expect(f.users.lastAction, 'mark_read');
    expect(find.text('已读'), findsOneWidget);
    await tester.tap(find.text('申诉'));
    await tester.pumpAndSettle();
    final submit = find.widgetWithText(FilledButton, '提交');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '请重新审核');
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(f.users.appeal, '请重新审核');
    expect(find.text('已申诉'), findsOneWidget);
  });

  testWidgets('the old dialog cannot send an appeal after switching accounts', (
    tester,
  ) async {
    final f = _Fixture();
    await tester.pumpWidget(f.screen());
    await tester.pumpAndSettle();
    await tester.tap(find.text('申诉'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'old account');
    await tester.pump();
    f.tokens.beginSessionChange();
    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.pumpAndSettle();
    expect(f.users.appeal, isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
    expect(find.text('Policy warning'), findsNothing);
  });
}

class _Fixture {
  final tokens = TokenStore();
  late final client = ApiClient(
    config: const AppConfig(
      apiBaseUrl: 'http://example.test',
      wsBaseUrl: 'ws://example.test',
      storageBaseUrl: 'http://example.test',
    ),
    tokenStore: tokens,
  );
  late final users = _Users(UsersApi(client));
  late final auth = AuthRepository(api: AuthApi(client), tokenStore: tokens);

  Widget screen() => ProviderScope(
    overrides: [
      usersRepositoryProvider.overrideWithValue(users),
      authRepositoryProvider.overrideWithValue(auth),
    ],
    child: const MaterialApp(home: StatementsScreen()),
  );
}

class _Users extends UsersRepository {
  _Users(super.api);
  String? appeal, lastAction, type;
  String status = 'unread';

  @override
  Future<PagedResult<V2AccountStatement>> statements({
    int page = 1,
    int size = 20,
    String? status,
    String? type,
  }) async {
    this.type = type;
    return PagedResult(
      items: [
        V2AccountStatement.fromJson({
          'statement_id': 9,
          'title': 'Policy warning',
          'message': 'A review was completed.',
          'type': 'warning',
          'status': this.status,
        }),
      ],
    );
  }

  @override
  Future<void> changeStatementStatus(int id, String action) async {
    expect(id, 9);
    lastAction = action;
    status = 'read';
  }

  @override
  Future<void> submitStatementAppeal(int id, String message) async {
    expect(id, 9);
    appeal = message;
    status = 'appealed';
  }
}

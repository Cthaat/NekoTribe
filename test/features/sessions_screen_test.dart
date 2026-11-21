import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/sessions_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('endpoint switching invalidates an open revoke confirmation', (
    tester,
  ) async {
    final tokens = TokenStore();
    final api = _Sessions(tokens);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(tokens),
          authApiProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Other fixture'), findsOneWidget);
    await tester.tap(find.byTooltip('撤销其他设备'));
    await tester.pumpAndSettle();
    expect(find.text('确认'), findsOneWidget);
    await tokens.switchEndpoint(() {});
    await tester.pump();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(api.revocations, 0);
    expect(find.text('Other fixture'), findsNothing);
  });
}

class _Sessions extends AuthApi {
  _Sessions(TokenStore tokens)
    : super(
        ApiClient(
          config: AppConfig.fromOrigin('https://neko.example'),
          tokenStore: tokens,
        ),
      );
  int revocations = 0;

  @override
  Future<PagedResult<V2SessionItem>> listSessions({int page = 1}) async =>
      PagedResult(
        items: [
          _session('current', 'Current fixture', true),
          _session('other', 'Other fixture', false),
        ],
      );

  @override
  Future<void> revokeOtherSessions() async {
    revocations++;
  }
}

V2SessionItem _session(String id, String name, bool current) => V2SessionItem(
  sessionId: id,
  deviceInfo: name,
  ipAddress: '',
  lastAccessedAt: '',
  createdAt: '',
  isCurrent: current,
);

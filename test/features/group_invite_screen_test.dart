import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/groups/presentation/group_invite_screen.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

class _InvitesApi extends Fake implements GroupsApi {
  final calls = <String>[];

  @override
  Future<V2GroupInvitePreview> previewInvite(String code) async {
    calls.add('preview:$code');
    return V2GroupInvitePreview.fromJson({
      'is_valid': true,
      'group': {'group_id': 7, 'name': 'Cat Town', 'slug': 'cat-town'},
      'inviter': {'username': 'host'},
      'message': 'Welcome!',
    });
  }

  @override
  Future<V2GroupMembership> joinGroup(
    int groupId, {
    String? message,
    String? inviteCode,
  }) async {
    calls.add('join:$groupId:$inviteCode');
    return V2GroupMembership(isMember: true, status: 'active');
  }
}

void main() {
  testWidgets('preview is read-only until the user taps join', (tester) async {
    final api = _InvitesApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupsApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
          localizationsDelegates: [AppLocalizationsDelegate()],
          home: GroupInviteScreen(code: 'aBc'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cat Town'), findsOneWidget);
    expect(find.text('Welcome!'), findsOneWidget);
    expect(api.calls, ['preview:ABC']);
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pumpAndSettle();
    expect(api.calls, ['preview:ABC', 'join:7:ABC']);
    expect(find.widgetWithText(FilledButton, 'Join'), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/moderation/data/moderation_api.dart';
import 'package:nekotribe/features/moderation/domain/moderation_models.dart';
import 'package:nekotribe/features/moderation/presentation/moderation_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('moderation settings can edit and save configured values', (
    tester,
  ) async {
    final api = _FakeModerationApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [moderationApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: ModerationScreen(initialTab: 5)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('审核设置'), findsOneWidget);
    expect(find.text('自动隐藏阈值'), findsOneWidget);
    expect(find.text('拒绝时要求备注'), findsOneWidget);
    expect(find.text('允许领取审核任务'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('moderation-setting-auto_hide_report_threshold')),
      '12',
    );
    await tester.tap(
      find.byKey(const Key('moderation-setting-require_note_on_reject')),
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('moderation-setting-default_mute_hours')),
      '36',
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moderation-settings-save-bottom')));
    await tester.pumpAndSettle();

    expect(api.savedBody, {
      'settings': [
        {'key': 'auto_hide_report_threshold', 'value': '12'},
        {'key': 'require_note_on_reject', 'value': 'false'},
        {'key': 'allow_moderator_claim', 'value': 'true'},
        {'key': 'default_mute_hours', 'value': '36'},
      ],
    });
    expect(find.text('审核设置已保存'), findsOneWidget);
  });
}

class _FakeModerationApi extends ModerationApi {
  _FakeModerationApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  Map<String, dynamic>? savedBody;
  List<V2ModerationSetting> _settings = [
    _setting(key: 'auto_hide_report_threshold', value: '10', type: 'number'),
    _setting(key: 'require_note_on_reject', value: 'true', type: 'boolean'),
    _setting(key: 'allow_moderator_claim', value: 'true', type: 'boolean'),
    _setting(key: 'default_mute_hours', value: '24', type: 'number'),
  ];

  @override
  Future<V2ModerationStats> stats() async {
    return V2ModerationStats(
      pending: 1,
      approved: 2,
      rejected: 3,
      flagged: 4,
      todayProcessed: 5,
      avgProcessMinutes: 6,
      openReports: 7,
      appealSuccessRate: 0.5,
    );
  }

  @override
  Future<List<V2ModerationSetting>> settings() async => _settings;

  @override
  Future<List<V2ModerationSetting>> updateSettings(
    Map<String, dynamic> body,
  ) async {
    savedBody = body;
    final values = {
      for (final item in body['settings'] as List<dynamic>)
        (item as Map<String, dynamic>)['key'] as String:
            item['value'] as String,
    };
    _settings = _settings
        .map((item) => item.copyWith(value: values[item.key] ?? item.value))
        .toList(growable: false);
    return _settings;
  }
}

V2ModerationSetting _setting({
  required String key,
  required String value,
  required String type,
}) {
  return V2ModerationSetting(
    key: key,
    value: value,
    valueType: type,
    label: key,
    description: '',
    updatedAt: '2026-05-24T00:00:00.000Z',
  );
}

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

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

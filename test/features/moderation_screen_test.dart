import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/moderation/data/moderation_api.dart';
import 'package:nekotribe/features/moderation/domain/moderation_models.dart';
import 'package:nekotribe/features/moderation/presentation/moderation_screen.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
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
    await tester.tap(find.byKey(const Key('moderation-settings-save')));
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

  testWidgets('content actions use post id and show localized labels', (
    tester,
  ) async {
    final api = _FakeModerationApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [moderationApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: ModerationScreen(initialTab: 1)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('举报 1'), findsOneWidget);
    expect(find.text('垃圾内容'), findsOneWidget);
    expect(find.text('拒绝'), findsWidgets);
    expect(find.text('通过'), findsWidgets);
    expect(find.text('moderation.content.reports 1'), findsNothing);
    expect(find.text('moderation.reject'), findsNothing);
    expect(find.text('moderation.approve'), findsNothing);

    await tester.tap(find.byKey(const Key('moderation-content-approve-2001')));
    await tester.pumpAndSettle();

    expect(api.resolvedPostId, 2001);
    expect(api.resolvedAction, 'approve');
  });

  testWidgets('resolved reports can be moved back to pending', (tester) async {
    final api = _FakeModerationApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [moderationApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: ModerationScreen(initialTab: 2)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('已处理'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moderation-report-reopen-3001')));
    await tester.pumpAndSettle();

    expect(api.updatedReportId, 3001);
    expect(api.updatedReportStatus, 'pending');
  });

  testWidgets('user moderation dialog closes without popping GoRouter stack', (
    tester,
  ) async {
    final api = _FakeModerationApi();
    final router = GoRouter(
      initialLocation: '/moderation',
      routes: [
        GoRoute(
          path: '/moderation',
          builder: (_, __) => ProviderScope(
            overrides: [moderationApiProvider.overrideWithValue(api)],
            child: const ModerationScreen(initialTab: 3),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('moderation-user-actions-42')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('封禁'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(api.restrictedUserId, 42);
    expect(api.restrictedAction, 'ban');
    expect(find.text('审核中心'), findsOneWidget);
  });
}

class _FakeModerationApi extends ModerationApi {
  _FakeModerationApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  Map<String, dynamic>? savedBody;
  int? resolvedPostId;
  String? resolvedAction;
  int? updatedReportId;
  String? updatedReportStatus;
  int? restrictedUserId;
  String? restrictedAction;
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
  Future<PagedResult<V2ModerationContentItem>> content({
    String status = 'pending',
    String? priority,
    int page = 1,
    int size = 20,
  }) async {
    return PagedResult(
      items: status == 'pending' ? [_contentItem] : const [],
      meta: const ApiMeta(page: 1, pageSize: 20, total: 1, hasNext: false),
    );
  }

  @override
  Future<void> resolveContent({
    required int postId,
    required String action,
    String? note,
  }) async {
    resolvedPostId = postId;
    resolvedAction = action;
  }

  @override
  Future<PagedResult<V2ModerationReport>> reports({
    String? status,
    String? priority,
    int page = 1,
    int size = 20,
  }) async {
    return PagedResult(
      items: status == 'resolved' ? [_resolvedReport] : const [],
      meta: const ApiMeta(page: 1, pageSize: 20, total: 1, hasNext: false),
    );
  }

  @override
  Future<void> updateReport({
    required int reportId,
    required String status,
    String? resolutionNote,
  }) async {
    updatedReportId = reportId;
    updatedReportStatus = status;
  }

  @override
  Future<PagedResult<V2ModerationUserItem>> users({
    String? status,
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    return PagedResult(
      items: [_moderationUser],
      meta: const ApiMeta(page: 1, pageSize: 20, total: 1, hasNext: false),
    );
  }

  @override
  Future<void> restrictUser({
    required int userId,
    required String action,
    String? reason,
    int? durationHours,
    String? note,
  }) async {
    restrictedUserId = userId;
    restrictedAction = action;
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

final _publicUser = V2PublicUser(
  userId: 42,
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
);

final _contentItem = V2ModerationContentItem(
  caseId: 9001,
  postId: 2001,
  content: '需要审核的内容',
  author: _publicUser,
  media: const <V2MediaAsset>[],
  reportCount: 1,
  reportReasons: const ['spam'],
  reports: const [],
  status: 'pending',
  priority: 'normal',
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
  reportedAt: '2026-05-24T00:00:00.000Z',
  likesCount: 0,
  retweetsCount: 0,
  repliesCount: 0,
);

final _resolvedReport = V2ModerationReport(
  reportId: 3001,
  targetType: 'post',
  targetId: 2001,
  reporter: _publicUser,
  reason: 'spam',
  description: '点错通过的举报',
  status: 'resolved',
  priority: 'normal',
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
  resolvedAt: '2026-05-24T00:05:00.000Z',
);

final _moderationUser = V2ModerationUserItem(
  userId: 42,
  username: 'edge',
  displayName: 'Edge',
  avatarUrl: '',
  email: 'edge@example.test',
  status: 'active',
  isActive: 1,
  isVerified: 0,
  followersCount: 0,
  postsCount: 1,
  likesCount: 0,
  reportCount: 2,
  activeRestriction: 'none',
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
);

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

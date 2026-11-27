import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/moderation/data/moderation_api.dart';
import 'package:nekotribe/features/moderation/domain/moderation_models.dart';
import 'package:nekotribe/features/moderation/presentation/moderation_screen.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:nekotribe/shared/widgets/ui/surface_card.dart';

void main() {
  testWidgets('case status shares the filter card and filters the queue', (
    tester,
  ) async {
    final fixture = _AppealsFixture();
    await tester.pumpWidget(fixture.screen(initialTab: 1));
    await tester.pumpAndSettle();

    final status = find.byKey(const Key('moderation-content-status'));
    expect(tester.widget(status), isA<DropdownButtonFormField<String>>());
    final card = find.ancestor(of: status, matching: find.byType(SurfaceCard));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(ExpansionTile)),
      findsOneWidget,
    );
    final decoration = tester.widget<InputDecorator>(
      find.descendant(of: status, matching: find.byType(InputDecorator)),
    ).decoration;
    expect(decoration.filled, isTrue);
    expect(decoration.enabledBorder?.borderSide, BorderSide.none);
    await tester.tap(status);
    await tester.pumpAndSettle();
    await tester.tap(find.text('已通过').last);
    await tester.pumpAndSettle();

    expect(fixture.api.contentStatus, 'approved');
    expect(
      find.descendant(of: status, matching: find.text('已通过')),
      findsOneWidget,
    );
  });

  testWidgets('queue displays only valid sentiment signals in original order', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _AppealsFixture();
    fixture.api.contentItems = [
      V2ModerationContentItem.fromJson({
        'post_id': 41,
        'content': 'First post',
      }),
      V2ModerationContentItem.fromJson({
        'post_id': 42,
        'content': 'Second post',
        'sentiment_signal': {'label': 'negative', 'confidence': 0.84},
      }),
      V2ModerationContentItem.fromJson({
        'post_id': 43,
        'content': 'Third post',
        'sentiment_signal': {'label': 'positive', 'confidence': 1.2},
      }),
    ];
    await tester.pumpWidget(fixture.screen(initialTab: 1));
    await tester.pumpAndSettle();
    expect(find.text('情感倾向：负面 · 84%'), findsOneWidget);
    expect(find.textContaining('情感倾向'), findsOneWidget);
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('First post'), lessThan(top('Second post')));
    expect(top('Second post'), lessThan(top('Third post')));
  });

  testWidgets(
    'appeal decision sends the reply and exposes the result in history',
    (tester) async {
      final f = _AppealsFixture();
      await tester.pumpWidget(f.screen());
      await tester.pumpAndSettle();
      expect(find.text('Please check this action.'), findsOneWidget);
      await tester.tap(find.text('通过申诉'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Reviewed by staff');
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(f.api.appealDecision, ('approved', 'Reviewed by staff'));
      expect(find.text('暂无申诉记录'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部申诉').last);
      await tester.pumpAndSettle();
      expect(find.text('已通过'), findsOneWidget);
      expect(find.text('Reviewed by staff'), findsOneWidget);
      expect(find.text('驳回申诉'), findsNothing);
    },
  );

  testWidgets('appeal dialog from an old session cannot send a decision', (
    tester,
  ) async {
    final f = _AppealsFixture();
    await tester.pumpWidget(f.screen());
    await tester.pumpAndSettle();
    await tester.tap(find.text('驳回申诉'));
    await tester.pumpAndSettle();
    f.tokens.beginSessionChange();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(f.api.appealDecision, isNull);
    expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
    expect(find.text('Please check this action.'), findsNothing);
  });

  testWidgets('moderation settings can edit and save configured values', (
    tester,
  ) async {
    final fixture = _AppealsFixture();
    final api = fixture.api;
    await tester.pumpWidget(fixture.screen(initialTab: 5));
    await tester.pumpAndSettle();

    expect(find.text('审核设置'), findsOneWidget);
    expect(find.text('举报提级阈值'), findsOneWidget);
    expect(find.textContaining('同一举报人只计一次，设为 0 可关闭'), findsOneWidget);
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
        {'key': 'default_mute_hours', 'value': '36'},
      ],
    });
    expect(find.text('审核设置已保存'), findsOneWidget);
  });

  testWidgets('moderation settings discard a draft when the session changes', (
    tester,
  ) async {
    final fixture = _AppealsFixture();
    await tester.pumpWidget(fixture.screen(initialTab: 5));
    await tester.pumpAndSettle();
    final setting = find.byKey(
      const Key('moderation-setting-auto_hide_report_threshold'),
    );
    await tester.enterText(setting, '19');
    fixture.tokens.beginSessionChange();
    await tester.pumpAndSettle();
    expect(setting, findsNothing);
    expect(fixture.api.savedBody, isNull);
    expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
  });

  testWidgets('content actions use post id and show localized labels', (
    tester,
  ) async {
    final fixture = _AppealsFixture();
    final api = fixture.api;
    await tester.pumpWidget(fixture.screen(initialTab: 1));
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

  testWidgets('claim and release reload the reviewer assignment', (
    tester,
  ) async {
    final fixture = _AppealsFixture();
    await tester.pumpWidget(fixture.screen(initialTab: 1));
    await tester.pumpAndSettle();
    final assignment = find.byKey(const Key('moderation-assignment-2001'));
    expect(find.text('领取审核'), findsOneWidget);
    await tester.tap(assignment);
    await tester.pumpAndSettle();
    expect(fixture.api.resolvedAction, 'claim');
    expect(find.text('释放审核'), findsOneWidget);
    await tester.tap(assignment);
    await tester.pumpAndSettle();
    expect(fixture.api.resolvedAction, 'release');
    expect(find.text('领取审核'), findsOneWidget);
  });

  testWidgets('content rejection sends the moderated post and note', (
    tester,
  ) async {
    final fixture = _AppealsFixture();
    await tester.pumpWidget(fixture.screen(initialTab: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moderation-content-reject-2001')));
    await tester.pumpAndSettle();
    final note = find.byKey(const Key('moderation-rejection-note'));
    expect(note, findsOneWidget);
    await tester.enterText(note, ' Reviewed ');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(fixture.api.resolvedPostId, 2001);
    expect(fixture.api.resolvedAction, 'reject');
    expect(fixture.api.resolvedNote, 'Reviewed');
  });

  testWidgets('bulk moderation submits only after confirmation and reloads', (
    tester,
  ) async {
    final fixture = _AppealsFixture();
    await tester.pumpWidget(fixture.screen(initialTab: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moderation-select-2001')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已选帖子 1'));
    await tester.pumpAndSettle();
    expect(fixture.api.bulkDecision, isNull);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(fixture.api.bulkDecision?.$1, [2001]);
    expect(fixture.api.bulkDecision?.$2, 'flag');
    expect(fixture.api.bulkDecision?.$3, isNull);
    expect(find.byKey(const Key('moderation-select-2001')), findsNothing);
    expect(find.text('已处理帖子 1'), findsOneWidget);
  });

  testWidgets(
    'content filters fit a small screen and clear on session change',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = _AppealsFixture();
      await tester.pumpWidget(fixture.screen(initialTab: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选案件'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moderation-content-priority')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高').last);
      await tester.pumpAndSettle();
      expect(fixture.api.contentPriority, 'high');
      expect(tester.takeException(), isNull);
      fixture.tokens.beginSessionChange();
      await tester.pumpAndSettle();
      expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
      expect(
        find.byKey(const Key('moderation-content-priority')),
        findsNothing,
      );
    },
  );

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
    final fixture = _AppealsFixture();
    final api = fixture.api;
    final router = GoRouter(
      initialLocation: '/moderation',
      routes: [
        GoRoute(
          path: '/moderation',
          builder: (_, __) => ProviderScope(
            overrides: [
              moderationApiProvider.overrideWithValue(api),
              authRepositoryProvider.overrideWithValue(fixture.auth),
            ],
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
    expect(api.restrictedHours, isNull);
    expect(find.text('审核中心'), findsOneWidget);
  });

  testWidgets(
    'user queue clears its rows and pending actions on session change',
    (tester) async {
      final fixture = _AppealsFixture();
      await tester.pumpWidget(fixture.screen(initialTab: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moderation-users-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('举报最多').last);
      await tester.pumpAndSettle();
      expect(fixture.api.userSort, 'reports');
      final action = find.byKey(const Key('moderation-user-actions-42'));
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('封禁'));
      await tester.pumpAndSettle();
      fixture.tokens.beginSessionChange();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(fixture.api.restrictedUserId, isNull);
      expect(action, findsNothing);
      expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
    },
  );
}

class _AppealsFixture {
  final tokens = _FakeTokenStore();
  final api = _FakeModerationApi();
  late final auth = AuthRepository(
    api: AuthApi(ApiClient(config: _testConfig, tokenStore: tokens)),
    tokenStore: tokens,
  );

  Widget screen({int initialTab = 4}) => ProviderScope(
    overrides: [
      moderationApiProvider.overrideWithValue(api),
      authRepositoryProvider.overrideWithValue(auth),
      usersRepositoryProvider.overrideWithValue(_FakeReviewerRepository()),
    ],
    child: MaterialApp(home: ModerationScreen(initialTab: initialTab)),
  );
}

class _FakeReviewerRepository extends UsersRepository {
  _FakeReviewerRepository()
    : super(
        UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())),
      );

  @override
  Future<V2SelfUser> getCurrentUser() async =>
      V2SelfUser.fromJson({'user_id': _publicUser.userId});
}

class _FakeModerationApi extends ModerationApi {
  _FakeModerationApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  Map<String, dynamic>? savedBody;
  int? resolvedPostId;
  String? resolvedNote;
  String? contentPriority;
  String? resolvedAction;
  (List<int>, String, String?)? bulkDecision;
  bool claimed = false;
  int? updatedReportId;
  String? updatedReportStatus;
  int? restrictedUserId;
  String? userSort;
  String? restrictedAction;
  int? restrictedHours;
  (String, String)? appealDecision;

  @override
  Future<PagedResult<V2ModerationAppeal>> appeals({
    String? status,
    int page = 1,
    int size = 20,
  }) async {
    final state = appealDecision?.$1 ?? 'pending';
    return PagedResult(
      items: [
        if (status == null || status == 'all' || status == state)
          V2ModerationAppeal(
            appealId: 12,
            statementId: 9,
            user: _publicUser,
            appealMessage: 'Please check this action.',
            appealStatus: state,
            adminResponse: appealDecision?.$2 ?? '',
            createdAt: '',
            updatedAt: '',
          ),
      ],
    );
  }

  @override
  Future<void> updateAppeal({
    required int appealId,
    required String status,
    String? response,
  }) async {
    expect(appealId, 12);
    appealDecision = (status, response ?? '');
  }

  List<V2ModerationContentItem>? contentItems;
  String? contentStatus;

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
    String? reason,
    String? keyword,
    String? dateRange,
    String? sort,
    int page = 1,
    int size = 20,
  }) async {
    contentStatus = status;
    contentPriority = priority;
    return PagedResult(
      items: status == 'pending' && bulkDecision == null
          ? contentItems ??
                [_contentItem(assignedTo: claimed ? _publicUser : null)]
          : const [],
      meta: const ApiMeta(page: 1, pageSize: 20, total: 1, hasNext: false),
    );
  }

  @override
  Future<int> bulkAction({
    required List<int> postIds,
    required String action,
    String? note,
  }) async {
    bulkDecision = (postIds, action, note);
    return postIds.length;
  }

  @override
  Future<void> resolveContent({
    required int postId,
    required String action,
    String? note,
  }) async {
    resolvedPostId = postId;
    resolvedAction = action;
    resolvedNote = note;
    if (action == 'claim' || action == 'release') claimed = action == 'claim';
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
    String? sort,
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    userSort = sort;
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
    restrictedHours = durationHours;
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

V2ModerationContentItem _contentItem({V2PublicUser? assignedTo}) =>
    V2ModerationContentItem(
      caseId: 9001,
      postId: 2001,
      content: '需要审核的内容',
      author: _publicUser,
      assignedTo: assignedTo,
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

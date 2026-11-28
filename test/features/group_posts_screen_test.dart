import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/ai/data/ai_writing_api.dart';
import 'package:nekotribe/features/ai/presentation/ai_writing_screen.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/groups/presentation/group_posts_screen.dart';
import 'package:nekotribe/features/groups/presentation/group_post_detail_screen.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

import '../support/media_preview_flight.dart';

void main() {
  List<Override> authOverrides({
    required GroupsApi groupsApi,
    PostsApi? postsApi,
  }) {
    return [
      appConfigBundleProvider.overrideWithValue(
        const AppConfigBundle(
          defaults: _testConfig,
          presets: [],
          groupPostShareBaseUrl: 'https://community.test/en',
        ),
      ),
      appConfigInitialProvider.overrideWithValue(_testConfig),
      groupsApiProvider.overrideWithValue(groupsApi),
      if (postsApi != null) postsApiProvider.overrideWithValue(postsApi),
      authSessionProvider.overrideWith(
        (ref) => AuthSessionController(_FakeTokenStore())..markLoggedIn(),
      ),
    ];
  }

  testWidgets('active members can reply to the cited group comment', (
    tester,
  ) async {
    final api = _FakeGroupsApi()..paginateComments = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(groupsApi: api),
        child: const MaterialApp(
          home: GroupPostDetailScreen(groupId: 42, postId: 9, commentId: 17),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('用 AI 总结讨论'), findsNothing);
    final reply = find.byTooltip('回复评论');
    await tester.ensureVisible(reply);
    await tester.tap(reply);
    await tester.pumpAndSettle();
    expect(find.text('正在回复 @cats'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  回复内容  ');
    await tester.pump();
    await tester.tap(find.byTooltip('发布'));
    await tester.pumpAndSettle();
    expect(api.createdReplies, [(42, 9, 17, '回复内容')]);
    expect(find.text('回复已发送'), findsOneWidget);
    expect(find.text('正在回复 @cats'), findsNothing);
  });

  testWidgets('group discussion rechecks public scope before opening a draft', (
    tester,
  ) async {
    final api = _FakeGroupsApi()..paginateComments = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(groupsApi: api),
          aiAvailabilityProvider.overrideWith(
            (_) async => const AiAvailability(knowledge: false, writing: true),
          ),
        ],
        child: const MaterialApp(
          home: GroupPostDetailScreen(groupId: 42, postId: 9),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final action = find.byTooltip('用 AI 总结讨论');
    api.privateOnLookup = true;
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.byType(AiWritingScreen), findsNothing);
    expect(find.text('无法读取可总结的公开群讨论，请刷新后重试。'), findsOneWidget);
    api.privateOnLookup = false;
    api.summaryCommentText = 'Edited comment';
    await tester.tap(action);
    await tester.pumpAndSettle();
    final screen = tester.widget<AiWritingScreen>(find.byType(AiWritingScreen));
    expect(screen.initialDiscussion, 'hello group\n\nEdited comment');
    expect(api.sharedReads, [
      (42, null, null),
      (42, 9, null),
      (42, 9, null),
      (42, 9, null),
      (42, 9, null),
      (42, null, null),
      (42, 9, null),
      (42, 9, null),
      (42, null, null),
    ]);
  });

  testWidgets(
    'group comments change server sort and keep it on the next page',
    (tester) async {
      final api = _FakeGroupsApi()..paginateComments = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: authOverrides(groupsApi: api),
          child: const MaterialApp(
            home: GroupPostDetailScreen(groupId: 42, postId: 9),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final order = find.byKey(const Key('group-comment-order'));
      await tester.ensureVisible(order);
      await tester.tap(order);
      await tester.pumpAndSettle();
      await tester.tap(find.text('最早').last);
      await tester.pumpAndSettle();
      final more = find.byKey(const Key('group-post-comments-load-more'));
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(api.commentPages, [(1, 'newest'), (1, 'oldest'), (2, 'oldest')]);
      expect(find.text('Comment oldest 2'), findsOneWidget);
      expect(find.text('Comment newest 1'), findsNothing);
    },
  );

  testWidgets(
    'shared post loads directly and copies a link to the cited comment',
    (tester) async {
      final api = _FakeGroupsApi();
      Object? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: authOverrides(groupsApi: api),
          child: const MaterialApp(
            home: GroupPostDetailScreen(groupId: 42, postId: 9, commentId: 17),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.sharedReads, [(42, null, null), (42, 9, null), (42, 9, 17)]);
      expect(find.text('hello group'), findsOneWidget);
      await tester.tap(find.byTooltip('复制群动态链接'));
      await tester.pumpAndSettle();
      expect(copied, {
        'text':
            'https://community.test/en/groups/posts?group=42&post=9&comment=17',
      });
    },
  );

  testWidgets('all groups merges further pages after pinned posts', (
    tester,
  ) async {
    final api = _FakeGroupsApi(aggregate: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(groupsApi: api),
        child: const MaterialApp(home: GroupPostsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pinned in second group'), findsOneWidget);
    expect(api.joinedPages, [1, 2]);
    expect(api.postPages, [(42, 1), (43, 1)]);
    final more = find.widgetWithText(OutlinedButton, '加载更多群组动态');
    await tester.scrollUntilVisible(
      more,
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(more);
    await tester.pumpAndSettle();
    final older = find.text('Older post from page two');
    await tester.scrollUntilVisible(
      older,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(older, findsOneWidget);
    expect(api.postPages, [(42, 1), (43, 1), (42, 2)]);
  });

  testWidgets('group posts feed exposes delete action', (tester) async {
    final api = _FakeGroupsApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(groupsApi: api),
        child: const MaterialApp(home: GroupPostsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('hello group'), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.deletedPostId, 9);
    expect(find.text('hello group'), findsNothing);
  });

  testWidgets('group posts feed can report a post', (tester) async {
    final groups = _FakeGroupsApi();
    final posts = _FakePostsApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(groupsApi: groups, postsApi: posts),
        child: const MaterialApp(home: GroupPostsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('举报'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(posts.reportedTargetType, 'group_post');
    expect(posts.reportedTargetId, 9);
  });

  testWidgets('group post media opens a lightbox preview', (tester) async {
    final api = _FakeGroupsApi(
      post: _postWith(mediaUrls: const ['/uploads/group-image.png']),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(groupsApi: api),
        child: const MaterialApp(home: GroupPostsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await checkMediaFlight(tester);
    await tester.tap(find.byTooltip('打开媒体').first);
    await tester.pumpAndSettle();

    expect(find.text('媒体预览'), findsOneWidget);
  });
}

class _FakeGroupsApi extends GroupsApi {
  _FakeGroupsApi({V2GroupPost? post, this.aggregate = false})
    : post = post ?? _post,
      super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final V2GroupPost post;
  final bool aggregate;
  final joinedPages = <int>[];
  final postPages = <(int, int)>[];
  final sharedReads = <(int, int?, int?)>[];
  final commentPages = <(int, String)>[];
  final createdReplies = <(int, int, int?, String)>[];
  bool paginateComments = false;
  bool privateOnLookup = false;
  String? summaryCommentText;
  int? deletedPostId;
  bool _deleted = false;

  @override
  Future<V2Group> getGroupById(int groupId) async {
    sharedReads.add((groupId, null, null));
    if (privateOnLookup) {
      return V2Group.fromJson({
        'group_id': groupId,
        'privacy': 'private',
        'is_active': 1,
      });
    }
    return _group;
  }

  @override
  Future<V2GroupPost> getPost({
    required int groupId,
    required int postId,
  }) async {
    sharedReads.add((groupId, postId, null));
    return post;
  }

  @override
  Future<PagedResult<V2GroupComment>> comments({
    required int groupId,
    required int postId,
    int page = 1,
    int size = 20,
    int? commentId,
    String sort = 'newest',
  }) async {
    sharedReads.add((groupId, postId, commentId));
    commentPages.add((page, sort));
    if (paginateComments) {
      return PagedResult(
        items: [
          V2GroupComment.fromJson({
            'comment_id': commentId ?? page,
            'post_id': postId,
            'content': summaryCommentText ?? 'Comment $sort $page',
            'author': {'user_id': 7, 'username': 'cats'},
          }),
          if (summaryCommentText != null)
            V2GroupComment.fromJson({
              'comment_id': 55,
              'post_id': postId,
              'content': 'Unseen comment',
            }),
        ],
        meta: ApiMeta(page: page, pageSize: size, total: 2, hasNext: page == 1),
      );
    }
    return const PagedResult(items: []);
  }

  @override
  Future<V2GroupComment> createComment({
    required int groupId,
    required int postId,
    required String content,
    int? parentCommentId,
    int? replyToUserId,
  }) async {
    createdReplies.add((groupId, postId, parentCommentId, content));
    return V2GroupComment.fromJson({
      'comment_id': 123,
      'post_id': postId,
      'parent_comment_id': parentCommentId,
      'content': content,
    });
  }

  @override
  Future<PagedResult<V2Group>> myGroups({
    int page = 1,
    int size = 20,
    String? category,
    String? privacy,
    String? search,
  }) async {
    if (aggregate) {
      joinedPages.add(page);
      return PagedResult(
        items: [
          if (page == 1)
            _group
          else
            V2Group.fromJson({
              'group_id': 43,
              'name': 'Second group',
              'slug': 'second',
            }),
        ],
        meta: ApiMeta(page: page, pageSize: size, total: 2, hasNext: page == 1),
      );
    }
    return PagedResult(
      items: [_group],
      meta: const ApiMeta(page: 1, pageSize: 20, total: 1, hasNext: false),
    );
  }

  @override
  Future<PagedResult<V2GroupPost>> posts(
    int groupId, {
    int page = 1,
    int size = 20,
    String type = 'all',
  }) async {
    if (aggregate) {
      postPages.add((groupId, page));
      final hasNext = groupId == 42 && page == 1;
      return PagedResult(
        items: [
          if (groupId == 43)
            _feedPost(43, 200, 'Pinned in second group', pinned: true)
          else if (page == 1)
            for (var id = 100; id > 80; id--)
              _feedPost(42, id, 'Earlier post $id')
          else
            _feedPost(42, 80, 'Older post from page two'),
        ],
        meta: ApiMeta(
          page: page,
          pageSize: size,
          total: groupId == 42 ? 21 : 1,
          hasNext: hasNext,
        ),
      );
    }
    return PagedResult(
      items: _deleted ? [] : [post],
      meta: ApiMeta(
        page: 1,
        pageSize: 20,
        total: _deleted ? 0 : 1,
        hasNext: false,
      ),
    );
  }

  @override
  Future<void> deleteGroupPost({
    required int groupId,
    required int postId,
    String? reason,
  }) async {
    deletedPostId = postId;
    _deleted = true;
  }
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? reportedTargetType;
  int? reportedTargetId;

  @override
  Future<void> reportContent({
    required String targetType,
    required int targetId,
    required String reason,
    String? description,
    String? evidenceUrl,
  }) async {
    reportedTargetType = targetType;
    reportedTargetId = targetId;
  }
}

final _user = V2PublicUser(
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
);

V2GroupPost _feedPost(
  int groupId,
  int id,
  String content, {
  bool pinned = false,
}) => V2GroupPost.fromJson({
  'post_id': id,
  'group_id': groupId,
  'content': content,
  'is_pinned': pinned,
  'created_at': '2026-05-24T00:00:00.000Z',
});

final _group = V2Group(
  groupId: 42,
  name: 'Cat Town',
  slug: 'cat-town',
  description: '',
  avatarUrl: '',
  coverUrl: '',
  category: 'general',
  tags: const [],
  owner: _user,
  privacy: 'public',
  privacyDesc: 'Public',
  joinApproval: false,
  postPermission: 'all',
  memberCount: 1,
  postCount: 1,
  isActive: 1,
  membership: V2GroupMembership(
    isMember: true,
    role: 'owner',
    status: 'active',
  ),
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
);

final _post = V2GroupPost(
  postId: 9,
  groupId: 42,
  author: _user,
  content: 'hello group',
  mediaUrls: const [],
  isPinned: false,
  isAnnouncement: false,
  likesCount: 0,
  commentsCount: 0,
  viewsCount: 0,
  isLikedByMe: false,
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
);

V2GroupPost _postWith({List<String> mediaUrls = const []}) {
  return V2GroupPost(
    postId: _post.postId,
    groupId: _post.groupId,
    author: _post.author,
    content: _post.content,
    mediaUrls: mediaUrls,
    isPinned: _post.isPinned,
    isAnnouncement: _post.isAnnouncement,
    likesCount: _post.likesCount,
    commentsCount: _post.commentsCount,
    viewsCount: _post.viewsCount,
    isLikedByMe: _post.isLikedByMe,
    createdAt: _post.createdAt,
    updatedAt: _post.updatedAt,
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/groups/presentation/group_posts_screen.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('group posts feed exposes delete action', (tester) async {
    final api = _FakeGroupsApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(
            const AppConfigBundle(defaults: _testConfig, presets: []),
          ),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          groupsApiProvider.overrideWithValue(api),
        ],
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
        overrides: [
          appConfigBundleProvider.overrideWithValue(
            const AppConfigBundle(defaults: _testConfig, presets: []),
          ),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          groupsApiProvider.overrideWithValue(groups),
          postsApiProvider.overrideWithValue(posts),
        ],
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
        overrides: [
          appConfigBundleProvider.overrideWithValue(
            const AppConfigBundle(defaults: _testConfig, presets: []),
          ),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          groupsApiProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: GroupPostsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('打开媒体').first);
    await tester.pumpAndSettle();

    expect(find.text('媒体预览'), findsOneWidget);
  });
}

class _FakeGroupsApi extends GroupsApi {
  _FakeGroupsApi({V2GroupPost? post})
    : post = post ?? _post,
      super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final V2GroupPost post;
  int? deletedPostId;
  bool _deleted = false;

  @override
  Future<PagedResult<V2Group>> myGroups({int page = 1, int size = 20}) async {
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
  membership: V2GroupMembership(isMember: true, role: 'owner'),
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

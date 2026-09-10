import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/compose_post_screen.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('composer submits location, mentioned visibility, and tags', (
    tester,
  ) async {
    final posts = _FakePostsApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
          authSessionProvider.overrideWith((ref) {
            final controller = AuthSessionController(
              _AuthenticatedTokenStore(),
            );
            controller.markLoggedIn();
            return controller;
          }),
          postsApiProvider.overrideWithValue(posts),
        ],
        child: const MaterialApp(home: ComposePostScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('compose-content-field')),
      'Hello #Flutter',
    );
    await tester.enterText(
      find.byKey(const Key('compose-location-field')),
      'Shanghai',
    );
    await tester.enterText(
      find.byKey(const Key('compose-tags-field')),
      'cats, flutter',
    );
    await tester.tap(find.byKey(const Key('compose-visibility-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提及的人').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('发布').last);
    await tester.pumpAndSettle();

    expect(posts.content, 'Hello #Flutter');
    expect(posts.visibility, 'mentioned');
    expect(posts.location, 'Shanghai');
    expect(posts.tags, ['flutter', 'cats']);
  });
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? content;
  String? visibility;
  String? location;
  List<String> tags = const [];

  @override
  Future<V2Post> createPost({
    required String content,
    String postType = 'normal',
    String visibility = 'public',
    String? language,
    String? location,
    int? replyToPostId,
    int? quotedPostId,
    int? repostOfPostId,
    List<int> mediaIds = const [],
    List<String> tags = const [],
    List<int> mentionUserIds = const [],
  }) async {
    this.content = content;
    this.visibility = visibility;
    this.location = location;
    this.tags = tags;
    return _post(content: content, visibility: visibility, location: location);
  }
}

V2Post _post({
  required String content,
  required String visibility,
  String? location,
}) {
  return V2Post(
    postId: 100001,
    author: _user,
    content: content,
    postType: 'post',
    visibility: visibility,
    language: 'zh',
    location: location ?? '',
    media: const [],
    tags: const [],
    mentions: const [],
    stats: V2PostStats(
      likesCount: 0,
      commentsCount: 0,
      repliesCount: 0,
      retweetsCount: 0,
      viewsCount: 0,
      engagementScore: 0,
    ),
    viewerState: V2ViewerPostState(
      isLiked: false,
      isBookmarked: false,
      canDelete: true,
    ),
    createdAt: '2026-05-25T00:00:00.000Z',
    updatedAt: '2026-05-25T00:00:00.000Z',
  );
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

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);

class _AuthenticatedTokenStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => const TokenPair(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    sessionId: 'session-1',
  );

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}
}

class _FakeTokenStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/edit_post_screen.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('edit screen updates location, mentioned visibility, and tags', (
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
        child: const MaterialApp(home: EditPostScreen(postId: 100001)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('edit-post-content-field')),
      'Updated #Flutter',
    );
    await tester.enterText(
      find.byKey(const Key('edit-post-location-field')),
      'Shanghai',
    );
    await tester.enterText(
      find.byKey(const Key('edit-post-tags-field')),
      'cats, flutter',
    );
    await tester.tap(find.byKey(const Key('edit-post-visibility-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提及的人').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(posts.updatedPostId, 100001);
    expect(posts.content, 'Updated #Flutter');
    expect(posts.visibility, 'mentioned');
    expect(posts.location, 'Shanghai');
    expect(posts.tags, ['flutter', 'cats']);
  });
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  int? updatedPostId;
  String? content;
  String? visibility;
  String? location;
  List<String>? tags;

  @override
  Future<V2Post> getPost(int postId) async => _post(
    content: 'Original #Old',
    visibility: 'public',
    location: 'Old Place',
    tags: const ['old'],
  );

  @override
  Future<V2Post> updatePost({
    required int postId,
    String? content,
    String? visibility,
    String? language,
    String? location,
    List<String>? tags,
  }) async {
    updatedPostId = postId;
    this.content = content;
    this.visibility = visibility;
    this.location = location;
    this.tags = tags;
    return _post(
      content: content ?? 'Original #Old',
      visibility: visibility ?? 'public',
      location: location,
      tags: tags ?? const [],
    );
  }
}

V2Post _post({
  required String content,
  required String visibility,
  String? location,
  List<String> tags = const [],
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
    tags: tags,
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

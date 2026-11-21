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
  testWidgets('an unconfirmed save keeps the draft in the editor', (
    tester,
  ) async {
    final posts = _FakePostsApi()..unconfirmed = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
          postsApiProvider.overrideWithValue(posts),
        ],
        child: const MaterialApp(home: EditPostScreen(postId: 100001)),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('edit-post-content-field'));
    await tester.enterText(field, 'My revised draft');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(posts.content, 'My revised draft');
    expect(tester.widget<TextField>(field).controller?.text, 'My revised draft');
    expect(
      find.text('无法确认编辑是否已保存。当前改动仍保留，请先查看帖子，再决定是否重试。'),
      findsOneWidget,
    );
  });

  testWidgets('edit route does not accept a response for another post', (
    tester,
  ) async {
    final posts = _FakePostsApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
          postsApiProvider.overrideWithValue(posts),
        ],
        child: const MaterialApp(home: EditPostScreen(postId: 100002)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-post-content-field')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    expect(posts.updatedPostId, isNull);
  });

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

    final languageField = find.byKey(const Key('edit-post-language-field'));
    await tester.ensureVisible(languageField);
    await tester.tap(languageField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('英文').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(posts.updatedPostId, 100001);
    expect(posts.content, 'Updated #Flutter');
    expect(posts.visibility, 'mentioned');
    expect(posts.language, 'en');
    expect(posts.location, 'Shanghai');
    expect(posts.tags, ['flutter', 'cats']);
  });

  testWidgets('location-only edit leaves the other patch fields absent', (
    tester,
  ) async {
    final posts = _FakePostsApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
          postsApiProvider.overrideWithValue(posts),
        ],
        child: const MaterialApp(home: EditPostScreen(postId: 100001)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('edit-post-location-field')),
      '',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(posts.updatedPostId, 100001);
    expect(posts.location, '');
    expect(posts.content, isNull);
    expect(posts.visibility, isNull);
    expect(posts.language, isNull);
    expect(posts.tags, isNull);
  });

  testWidgets('making a private post public requires attachment confirmation', (
    tester,
  ) async {
    final posts = _FakePostsApi()
      ..originalVisibility = 'followers'
      ..originalMedia = [
        V2MediaAsset.fromJson({
          'media_id': 1,
          'public_url': '/api/v2/media/1/content',
        }),
        V2MediaAsset.fromJson({
          'media_id': 2,
          'public_url': '/storage/public.png',
        }),
      ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
          postsApiProvider.overrideWithValue(posts),
        ],
        child: const MaterialApp(home: EditPostScreen(postId: 100001)),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('edit-post-visibility-field'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('公开').last);
    await tester.pumpAndSettle();

    final save = find.widgetWithText(FilledButton, '保存');
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('移除私有附件并公开？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(posts.updatedPostId, isNull);

    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(posts.updatedPostId, 100001);
    expect(posts.visibility, 'public');
    expect(posts.mediaIds, [2]);
  });

  testWidgets('attachment removal is reversible until the edit is saved', (
    tester,
  ) async {
    final posts = _FakePostsApi()
      ..originalMedia = [
        for (final id in [3, 2])
          V2MediaAsset.fromJson({
            'media_id': id,
            'file_name': 'attachment-$id.png',
            'public_url': '/storage/attachment-$id.png',
          }),
      ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
          postsApiProvider.overrideWithValue(posts),
        ],
        child: const MaterialApp(home: EditPostScreen(postId: 100001)),
      ),
    );
    await tester.pumpAndSettle();
    final keep = find.byKey(const ValueKey('edit-post-keep-media-3'));
    await tester.ensureVisible(keep);
    await tester.tap(keep);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(keep).value, isFalse);
    await tester.tap(keep);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(keep).value, isTrue);
    final remove = find.byKey(const ValueKey('edit-post-keep-media-2'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(posts.updatedPostId, isNull);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(posts.updatedPostId, 100001);
    expect(posts.mediaIds, [3]);
    expect(posts.content, isNull);
  });
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  int? updatedPostId;
  String? content;
  String? visibility;
  String? language;
  String? location;
  List<String>? tags;
  List<int>? mediaIds;
  bool unconfirmed = false;
  String originalVisibility = 'public';
  List<V2MediaAsset> originalMedia = const [];

  @override
  Future<V2Post> getPost(int postId) async => _post(
    content: 'Original #Old',
    visibility: originalVisibility,
    location: 'Old Place',
    tags: const ['old'],
    media: originalMedia,
  );

  @override
  Future<V2Post> updatePost({
    required int postId,
    String? content,
    String? visibility,
    String? language,
    String? location,
    List<String>? tags,
    List<int>? mediaIds,
  }) async {
    updatedPostId = postId;
    this.content = content;
    this.visibility = visibility;
    this.language = language;
    this.location = location;
    this.tags = tags;
    this.mediaIds = mediaIds;
    if (unconfirmed) throw const UnconfirmedPostUpdateError();
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
  List<V2MediaAsset> media = const [],
}) {
  return V2Post(
    postId: 100001,
    author: _user,
    content: content,
    postType: 'post',
    visibility: visibility,
    language: 'zh',
    location: location ?? '',
    media: media,
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

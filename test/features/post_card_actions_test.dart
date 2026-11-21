import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/post_card.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('card reports deletion only for its own returned post ID', (
    tester,
  ) async {
    var deleted = 0;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: PostCard(post: _likedPost, onDeleted: () => deleted++),
          ),
        ),
        GoRoute(
          path: '/posts/:id',
          builder: (_, _) => const Scaffold(body: Text('Post detail')),
        ),
      ],
    );
    addTearDown(router.dispose);
    final tokens = _AuthenticatedTokenStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          tokenStoreProvider.overrideWithValue(tokens),
          postsApiProvider.overrideWithValue(_FakePostsApi()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    for (final result in [null, _likedPost.postId + 1, _likedPost.postId]) {
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();
      expect(find.text('Post detail'), findsOneWidget);
      router.pop(result);
      await tester.pumpAndSettle();
      expect(deleted, result == _likedPost.postId ? 1 : 0);
    }
  });

  testWidgets(
    'post card opens or copies a public video URL and protects private video',
    (tester) async {
      String? copied;
      MethodCall? opened;
      var browserAvailable = true;
      final messenger = tester.binding.defaultBinaryMessenger;
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(launcher, (call) async {
        opened = call;
        return browserAvailable;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _pumpPostCard(
        tester,
        api: _FakePostsApi(),
        post: _samplePost(
          media: [
            V2MediaAsset.fromJson({
              'media_id': 7,
              'media_type': 'video',
              'file_name': 'public.mp4',
              'public_url': '/storage/public.mp4',
            }),
            V2MediaAsset.fromJson({
              'media_id': 8,
              'mime_type': 'video/mp4',
              'file_name': 'private.mp4',
              'public_url': '/api/v2/media/8/content',
            }),
          ],
        ),
      );
      expect(find.byTooltip('复制视频链接'), findsOneWidget);
      expect(find.byTooltip('下载附件'), findsOneWidget);
      final open = find.text('在浏览器中播放');
      expect(open, findsOneWidget);
      await tester.tap(open);
      await tester.pump();
      expect(opened?.method, 'launch');
      expect(
        opened?.arguments['url'],
        'http://example.test/storage/public.mp4',
      );
      expect(opened?.arguments['headers'], isEmpty);
      expect(opened?.arguments['useWebView'], isFalse);
      browserAvailable = false;
      await tester.tap(open);
      await tester.pump();
      expect(find.text('无法打开浏览器，请复制视频链接。'), findsOneWidget);
      await tester.tap(find.text('public.mp4'));
      await tester.pump();
      expect(copied, 'http://example.test/storage/public.mp4');
    },
  );

  testWidgets('post card bookmark keeps current liked state', (tester) async {
    final api = _FakePostsApi();
    V2Post? updated;

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
          postsApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PostCard(
              post: _likedPost,
              onChanged: (post) => updated = post,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bookmark_border));
    await tester.pumpAndSettle();

    expect(api.bookmarkCalls, 1);
    expect(updated?.viewerState.isBookmarked, isTrue);
    expect(updated?.viewerState.isLiked, isTrue);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('post card uses the server count after unliking', (tester) async {
    V2Post? updated;
    await _pumpPostCard(
      tester,
      api: _FakePostsApi(),
      post: _likedPost,
      onChanged: (post) => updated = post,
    );
    await tester.tap(find.byIcon(Icons.favorite));
    await tester.pumpAndSettle();
    expect(updated?.viewerState.isLiked, isFalse);
    expect(updated?.stats.likesCount, 42);
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('post card exposes retweet action and updates count', (
    tester,
  ) async {
    final api = _FakePostsApi();
    V2Post? updated;

    await _pumpPostCard(
      tester,
      api: api,
      post: _likedPost.copyWith(
        stats: _likedPost.stats.copyWith(retweetsCount: 2),
      ),
      onChanged: (post) => updated = post,
    );

    expect(find.byKey(const Key('post-retweet-button-200001')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-retweet-button-200001')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '转发一下');
    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pumpAndSettle();

    expect(api.retweetPostId, 200001);
    expect(api.retweetContent, '转发一下');
    expect(updated?.stats.retweetsCount, 3);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('post card more menu stays fixed at card right edge', (
    tester,
  ) async {
    final api = _FakePostsApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(api),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              child: Column(
                children: [
                  PostCard(post: _likedPost, onChanged: (_) {}),
                  PostCard(
                    post: _likedPost.copyWith(
                      stats: _likedPost.stats.copyWith(retweetsCount: 10),
                    ),
                    onChanged: (_) {},
                    key: const ValueKey('long-post-card'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.getTopRight(
      find.byKey(const Key('post-more-button-200001')).first,
    );
    final second = tester.getTopRight(
      find.byKey(const Key('post-more-button-200001')).last,
    );

    expect((first.dx - second.dx).abs(), lessThan(1));
  });

  testWidgets('an unconfirmed retweet leaves the count unchanged', (
    tester,
  ) async {
    final api = _FakePostsApi()..retweetUnconfirmed = true;
    await _pumpPostCard(
      tester,
      api: api,
      post: _likedPost.copyWith(
        stats: _likedPost.stats.copyWith(retweetsCount: 2),
      ),
      onChanged: (_) => fail('Unconfirmed receipt changed the post'),
    );
    await tester.tap(find.byKey(const Key('post-retweet-button-200001')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('无法确认转发是否已发布'), findsOneWidget);
  });
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  int bookmarkCalls = 0;
  int? retweetPostId;
  String? retweetContent;
  bool retweetUnconfirmed = false;

  @override
  Future<PostLikeReceipt> unlikePost(int postId) async =>
      (isLiked: false, likesCount: 42);

  @override
  Future<V2ViewerPostState> bookmarkPost(int postId) async {
    bookmarkCalls += 1;
    return V2ViewerPostState(
      isLiked: false,
      isBookmarked: true,
      canDelete: false,
    );
  }

  @override
  Future<V2Post> createRetweet({
    required int postId,
    required String content,
    String visibility = 'public',
  }) async {
    retweetPostId = postId;
    retweetContent = content;
    if (retweetUnconfirmed) throw const UnconfirmedRetweetError();
    return _likedPost.copyWith(
      stats: _likedPost.stats.copyWith(retweetsCount: 3),
    );
  }
}

Future<void> _pumpPostCard(
  WidgetTester tester, {
  required _FakePostsApi api,
  required V2Post post,
  void Function(V2Post post)? onChanged,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(api),
      child: MaterialApp(
        home: Scaffold(
          body: PostCard(post: post, onChanged: onChanged),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Override> _overrides(_FakePostsApi api) {
  return [
    appConfigBundleProvider.overrideWithValue(_testBundle),
    appConfigInitialProvider.overrideWithValue(_testConfig),
    tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
    authSessionProvider.overrideWith((ref) {
      final controller = AuthSessionController(_AuthenticatedTokenStore());
      controller.markLoggedIn();
      return controller;
    }),
    postsApiProvider.overrideWithValue(api),
  ];
}

final _likedPost = _samplePost();

V2Post _samplePost({List<V2MediaAsset> media = const []}) => V2Post(
  postId: 200001,
  author: _user,
  content: '3213213',
  postType: 'post',
  visibility: 'public',
  language: 'zh',
  location: '',
  media: media,
  tags: const [],
  mentions: const [],
  stats: V2PostStats(
    likesCount: 5,
    commentsCount: 0,
    repliesCount: 0,
    retweetsCount: 0,
    viewsCount: 0,
    engagementScore: 0,
  ),
  viewerState: V2ViewerPostState(
    isLiked: true,
    isBookmarked: false,
    canDelete: false,
  ),
  createdAt: '2026-05-23T00:00:00.000Z',
  updatedAt: '2026-05-23T00:00:00.000Z',
);

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

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}

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

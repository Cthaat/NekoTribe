import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/ai/data/ai_writing_api.dart';
import 'package:nekotribe/features/ai/presentation/ai_writing_screen.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_draft_metadata.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/edit_post_screen.dart';
import 'package:nekotribe/features/posts/presentation/post_card.dart';
import 'package:nekotribe/features/posts/presentation/post_detail_screen.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

class _Posts extends PostsApi {
  _Posts(TokenStore store)
    : super(
        ApiClient(
          config: const AppConfig(
            apiBaseUrl: 'http://example.test',
            wsBaseUrl: 'ws://example.test',
            storageBaseUrl: 'http://example.test',
          ),
          tokenStore: store,
        ),
      );

  final comment = Completer<V2Comment?>();
  final mutations = <(int, bool)>[];
  final replies = <(int, int?, String)>[];
  final deleted = <int>[];
  final deletedPosts = <int>[];
  final postReplyReads = <(int, int, int, String)>[];
  final repostReads = <(int, int, int, String)>[];
  Completer<PagedResult<V2Post>>? pendingReposts;
  bool failNextReplyPage = false;
  bool rejectReply = false;
  bool failComments = false;
  bool ownsPost = false;
  String postContent = 'previous post';
  String postVisibility = 'public';
  List<V2Comment> visibleComments = const [];
  int reads = 0;
  int postReads = 0;

  @override
  Future<V2Post> getPost(int postId) async {
    postReads++;
    return V2Post.fromJson({
      'post_id': postId,
      'content': postContent,
      'visibility': postVisibility,
      'author': {'user_id': 42, 'username': 'author'},
      'viewer_state': {'can_delete': ownsPost},
    });
  }

  @override
  Future<void> deletePost(int postId) async => deletedPosts.add(postId);

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
    postContent = content ?? postContent;
    return getPost(postId);
  }

  @override
  Future<V2Comment?> getComment(int postId, int commentId) {
    reads++;
    return comment.future;
  }

  @override
  Future<PagedResult<V2Comment>> getComments(
    int postId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) async {
    if (failComments) {
      throw ApiException(code: 50301, statusCode: 503, message: 'Unavailable');
    }
    return PagedResult(items: visibleComments);
  }

  @override
  Future<PagedResult<V2Post>> getReplies(
    int postId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) async {
    postReplyReads.add((postId, page, size, sort));
    if (page == 2 && failNextReplyPage) {
      throw ApiException(code: 50301, statusCode: 503, message: 'Unavailable');
    }
    V2Post reply(int id, int parent, String content) => V2Post.fromJson({
      'post_id': id,
      'reply_to_post_id': parent,
      'content': content,
      'author': {'user_id': 42, 'username': 'author'},
    });
    return PagedResult(
      items: [
        reply(10, postId, 'First reply post'),
        if (page == 2) reply(11, postId, 'Second reply post'),
        reply(12, 999, 'Unrelated post'),
      ],
      meta: ApiMeta(page: page, hasNext: page == 1),
    );
  }

  @override
  Future<PagedResult<V2Post>> getRetweets(
    int postId, {
    int page = 1,
    int size = 20,
    String sort = 'oldest',
  }) async {
    repostReads.add((postId, page, size, sort));
    if (pendingReposts case final pending?) return pending.future;
    return PagedResult(
      items: [
        V2Post.fromJson({
          'post_id': 30,
          'repost_of_post_id': postId,
          'content': 'Matching repost',
        }),
        V2Post.fromJson({
          'post_id': 31,
          'repost_of_post_id': 999,
          'content': 'Other repost',
        }),
      ],
    );
  }

  @override
  Future<CommentLikeState> likeComment(int commentId) async {
    mutations.add((commentId, true));
    return (isLiked: true, likesCount: 7);
  }

  @override
  Future<CommentLikeState> unlikeComment(int commentId) async {
    mutations.add((commentId, false));
    return (isLiked: false, likesCount: 4);
  }

  @override
  Future<V2Comment> createComment({
    required int postId,
    required String content,
    int? parentCommentId,
  }) async {
    replies.add((postId, parentCommentId, content));
    if (rejectReply) {
      throw ApiException(
        code: 40401,
        statusCode: 404,
        message: 'Parent unavailable',
      );
    }
    return V2Comment.fromJson({
      'comment_id': 10,
      'post_id': postId,
      'parent_comment_id': parentCommentId,
      'content': content,
    });
  }

  @override
  Future<void> deleteComment(int commentId) async {
    deleted.add(commentId);
  }
}

void main() {
  testWidgets('retries comments without hiding or rereading the post', (
    tester,
  ) async {
    final store = TokenStore();
    final posts = _Posts(store)..failComments = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          postsApiProvider.overrideWithValue(posts),
          authSessionProvider.overrideWith((_) => AuthSessionController(store)),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [AppLocalizationsDelegate()],
          home: PostDetailScreen(postId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('previous post'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    posts.failComments = false;
    posts.visibleComments = [
      V2Comment.fromJson({
        'comment_id': 8,
        'post_id': 1,
        'content': 'Recovered comment',
      }),
    ];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered comment'), findsOneWidget);
    expect(posts.postReads, 1);
  });

  test(
    'discussion drafts exclude restricted posts and stop at 20 comments',
    () async {
      final posts = _Posts(TokenStore())..postVisibility = 'followers';
      final comments = List.generate(
        21,
        (i) => V2Comment.fromJson({
          'comment_id': i + 1,
          'post_id': 1,
          'content': 'Reply $i',
        }),
      );
      expect(discussionSummaryDraft(await posts.getPost(1), comments), isEmpty);
      posts.postVisibility = 'public';
      final draft = discussionSummaryDraft(await posts.getPost(1), comments);
      expect(draft.split('\n\n'), hasLength(21));
      expect(draft, endsWith('Reply 19'));
    },
  );

  testWidgets('a public post can open a reviewable discussion summary', (
    tester,
  ) async {
    final store = TokenStore();
    final posts = _Posts(store)
      ..visibleComments = [
        V2Comment.fromJson({
          'comment_id': 8,
          'post_id': 1,
          'content': 'A reply',
        }),
        V2Comment.fromJson({
          'comment_id': 9,
          'post_id': 2,
          'content': 'Different post',
        }),
      ];
    final client = ApiClient(
      config: const AppConfig(
        apiBaseUrl: 'http://example.test',
        wsBaseUrl: 'ws://example.test',
        storageBaseUrl: 'http://example.test',
      ),
      tokenStore: store,
    );
    final ai = AiWritingApi(client);
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          postsApiProvider.overrideWithValue(posts),
          authSessionProvider.overrideWith(
            (_) => AuthSessionController(store)..markLoggedIn(),
          ),
          aiWritingApiProvider.overrideWithValue(ai),
          aiAvailabilityProvider.overrideWith(
            (_) async => const AiAvailability(knowledge: true, writing: true),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [AppLocalizationsDelegate()],
          home: PostDetailScreen(postId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    posts.postVisibility = 'followers';
    await tester.tap(find.text('Summarize discussion with AI'));
    await tester.pumpAndSettle();
    expect(find.byType(AiWritingScreen), findsNothing);
    posts.postVisibility = 'public';
    posts.visibleComments = [
      V2Comment.fromJson({
        'comment_id': 8,
        'post_id': 1,
        'content': 'Edited reply',
      }),
      V2Comment.fromJson({
        'comment_id': 10,
        'post_id': 1,
        'content': 'A new reply',
      }),
    ];
    await tester.tap(find.text('Summarize discussion with AI'));
    await tester.pumpAndSettle();
    expect(find.byType(AiWritingScreen), findsOneWidget);
    final input = find.byKey(const Key('ai-writing-input'));
    expect(
      tester.widget<TextField>(input).controller?.text,
      'previous post\n\nEdited reply',
    );
    expect(find.text('Summarize discussion'), findsOneWidget);
    expect(find.byKey(const Key('ai-conversation-title')), findsOneWidget);
  });

  testWidgets('saving from detail updates its original list card', (
    tester,
  ) async {
    final store = TokenStore();
    final posts = _Posts(store)..ownsPost = true;
    final original = await posts.getPost(1);
    V2Post? edited;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => StatefulBuilder(
            builder: (_, setState) => Scaffold(
              body: PostCard(
                post: edited ?? original,
                onEdited: (post) => setState(() => edited = post),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/posts/1',
          builder: (_, _) => const PostDetailScreen(postId: 1),
        ),
        GoRoute(
          path: '/posts/1/edit',
          builder: (_, _) => const EditPostScreen(postId: 1),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          postsApiProvider.overrideWithValue(posts),
          authSessionProvider.overrideWith(
            (_) => AuthSessionController(store)..markLoggedIn(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizationsDelegate()],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    expect(find.byType(PostDetailScreen), findsOneWidget);
    await tester.tap(find.byKey(const Key('post-more-button-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('edit-post-content-field')),
      'Edited from detail',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(posts.postContent, 'Edited from detail');
    expect(find.byType(EditPostScreen), findsNothing);
    expect(find.text('Edited from detail'), findsOneWidget);
    expect(edited, isNull);
    router.pop();
    await tester.pumpAndSettle();
    expect(edited?.content, 'Edited from detail');
    expect(find.text('Edited from detail'), findsOneWidget);
  });

  testWidgets('deleting a deep-linked post returns to the feed', (
    tester,
  ) async {
    final store = TokenStore();
    final posts = _Posts(store)..ownsPost = true;
    final router = GoRouter(
      initialLocation: '/posts/1',
      routes: [
        GoRoute(
          path: '/posts/1',
          builder: (_, _) => const PostDetailScreen(postId: 1),
        ),
        GoRoute(
          path: '/feed',
          builder: (_, _) => const Scaffold(body: Text('Feed')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          postsApiProvider.overrideWithValue(posts),
          authSessionProvider.overrideWith(
            (_) => AuthSessionController(store)..markLoggedIn(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizationsDelegate()],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-more-button-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(posts.deletedPosts, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(posts.deletedPosts, [1]);
    expect(find.text('Feed'), findsOneWidget);
  });

  testWidgets(
    'a cited comment supports reactions, replies, and confirmed deletion',
    (tester) async {
      final store = TokenStore();
      final posts = _Posts(store);
      posts.comment.complete(
        V2Comment.fromJson({
          'comment_id': 9,
          'post_id': 1,
          'content': 'cited comment',
          'author': {'user_id': 42, 'username': 'author'},
          'viewer_state': {'can_delete': true},
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            postsApiProvider.overrideWithValue(posts),
            authSessionProvider.overrideWith((ref) {
              return AuthSessionController(store)..markLoggedIn();
            }),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: [AppLocalizationsDelegate()],
            home: PostDetailScreen(postId: 1, commentId: 9),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Like'));
      await tester.tap(find.byTooltip('Like'));
      await tester.pumpAndSettle();
      expect(find.text('7'), findsOneWidget);
      await tester.tap(find.byTooltip('Unlike'));
      await tester.pumpAndSettle();
      expect(find.text('4'), findsOneWidget);
      expect(posts.mutations, [(9, true), (9, false)]);

      await tester.tap(find.byTooltip('Reply to comment'));
      await tester.pumpAndSettle();
      expect(find.text('Replying to @author'), findsOneWidget);
      await tester.enterText(find.byType(TextField), ' a nested reply ');
      posts.rejectReply = true;
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(posts.replies, [(1, 9, 'a nested reply')]);
      expect(find.text(' a nested reply '), findsOneWidget);
      expect(find.text('Reply sent'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      posts.rejectReply = false;
      await tester.tap(find.byTooltip('Post'));
      await tester.pumpAndSettle();
      expect(posts.replies, [
        (1, 9, 'a nested reply'),
        (1, 9, 'a nested reply'),
      ]);
      expect(find.text('cited comment'), findsOneWidget);
      expect(find.text('Reply sent'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this comment?'), findsOneWidget);
      expect(posts.deleted, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(posts.deleted, isEmpty);
      expect(find.text('cited comment'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(posts.deleted, [9]);
      expect(find.text('cited comment'), findsNothing);
      expect(posts.postReplyReads, isEmpty);
      expect(posts.repostReads, isEmpty);
    },
  );

  testWidgets('post replies page and retry independently of comments', (
    tester,
  ) async {
    final store = TokenStore();
    final posts = _Posts(store)..failNextReplyPage = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          postsApiProvider.overrideWithValue(posts),
          authSessionProvider.overrideWith(
            (ref) => AuthSessionController(store)..markLoggedIn(),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [AppLocalizationsDelegate()],
          home: PostDetailScreen(postId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final more = find.text('Load more replies');
    await tester.scrollUntilVisible(
      more,
      130,
      scrollable: find.byType(Scrollable).first,
    );
    expect(posts.postReplyReads, [(1, 1, 10, 'oldest')]);
    expect(find.text('First reply post'), findsOneWidget);
    expect(find.text('Unrelated post'), findsNothing);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('First reply post'), findsOneWidget);
    final retry = find.text('Retry');
    await tester.ensureVisible(retry);
    posts.failNextReplyPage = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Second reply post'),
      130,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('First reply post'), findsOneWidget);
    expect(find.text('Second reply post'), findsOneWidget);
    expect(posts.postReplyReads, [
      (1, 1, 10, 'oldest'),
      (1, 2, 10, 'oldest'),
      (1, 2, 10, 'oldest'),
    ]);

    final reposts = find.widgetWithText(ChoiceChip, 'Reposts');
    await tester.ensureVisible(reposts);
    final late = Completer<PagedResult<V2Post>>();
    posts.pendingReposts = late;
    await tester.tap(reposts);
    await tester.pump();
    expect(posts.repostReads, [(1, 1, 10, 'oldest')]);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Post replies'));
    await tester.pumpAndSettle();
    late.complete(
      PagedResult(
        items: [
          V2Post.fromJson({
            'post_id': 32,
            'repost_of_post_id': 1,
            'content': 'Late repost',
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Late repost'), findsNothing);
    expect(find.text('First reply post'), findsOneWidget);

    posts.pendingReposts = null;
    await tester.tap(reposts);
    await tester.pumpAndSettle();
    expect(find.text('Matching repost'), findsOneWidget);
    expect(find.text('Other repost'), findsNothing);
    expect(find.text('First reply post'), findsNothing);
  });

  for (final switchBackend in [false, true]) {
    testWidgets('a stale cited comment is ignored (backend=$switchBackend)', (
      tester,
    ) async {
      final store = TokenStore();
      final before = _Posts(store);
      final after = _Posts(store);
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          postsApiProvider.overrideWithValue(before),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: [AppLocalizationsDelegate()],
            supportedLocales: [Locale('en')],
            home: PostDetailScreen(postId: 1, commentId: 9),
          ),
        ),
      );
      await tester.pump();
      expect(before.reads, 1);
      if (switchBackend) {
        container.updateOverrides([
          tokenStoreProvider.overrideWithValue(store),
          postsApiProvider.overrideWithValue(after),
        ]);
        await tester.pump();
      } else {
        store.beginSessionChange();
      }
      before.comment.complete(
        V2Comment.fromJson({
          'comment_id': 9,
          'post_id': 1,
          'content': 'previous comment',
          'author': {'user_id': 42, 'username': 'author'},
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('previous post'), findsNothing);
      expect(find.text('previous comment'), findsNothing);
      expect(after.reads, 0);
      expect(find.textContaining('reopen this page'), findsOneWidget);
    });
  }
}

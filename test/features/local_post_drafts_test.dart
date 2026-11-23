import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/groups/presentation/group_detail_screen.dart';
import 'package:nekotribe/features/posts/data/local_post_drafts.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_draft.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/domain/post_poll.dart';
import 'package:nekotribe/features/posts/presentation/compose_post_screen.dart';
import 'package:nekotribe/features/posts/presentation/post_draft_scope.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'ordinary text and raw Markdown survive reopening, then discard',
    (tester) async {
      final tokens = _Tokens();
      await tester.pumpWidget(
        _app(tokens, _PostsApi(tokens), const _ComposeLauncher()),
      );
      await _open(tester);
      await tester.enterText(_plainField, 'Plain draft');
      await _close(tester);
      await _open(tester);
      expect(find.text('Plain draft'), findsOneWidget);
      await tester.tap(find.byKey(const Key('post-markdown-toggle')));
      await tester.pumpAndSettle();
      const source = '# Raw\n\n**first**\n';
      await tester.enterText(_markdownField, source);
      await _close(tester);
      await _open(tester);
      expect(find.text(source), findsOneWidget);
      expect(_plainField, findsNothing);
      await tester.tap(find.byKey(const Key('post-local-draft-discard')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '丢弃本地草稿'));
      await tester.pumpAndSettle();
      await _close(tester);
      await _open(tester);
      expect(_plainField, findsOneWidget);
      expect(find.text(source), findsNothing);
    },
  );

  testWidgets(
    'failed publish preserves the local draft and a receipt clears it',
    (tester) async {
      final tokens = _Tokens();
      final posts = _PostsApi(tokens)..unconfirmed = true;
      await tester.pumpWidget(_app(tokens, posts, const _ComposeLauncher()));
      await _open(tester);
      await tester.enterText(_plainField, 'Unsent text');
      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pumpAndSettle();
      await _close(tester);
      await _open(tester);
      expect(find.text('Unsent text'), findsOneWidget);
      posts.unconfirmed = false;
      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pumpAndSettle();
      await _open(tester);
      expect(find.text('Unsent text'), findsNothing);
    },
  );

  testWidgets(
    'group composers restore only their own locally stored document',
    (tester) async {
      final tokens = _Tokens();
      final posts = _PostsApi(tokens);
      await tester.pumpWidget(
        _app(tokens, posts, const GroupDetailScreen(slug: 'cats')),
      );
      await tester.pumpAndSettle();
      await _openGroup(tester);
      await tester.tap(find.byKey(const Key('post-markdown-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(_markdownField, '# Cats only');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      await _openGroup(tester);
      expect(find.text('# Cats only'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _app(tokens, posts, const GroupDetailScreen(slug: 'dogs')),
      );
      await tester.pumpAndSettle();
      await _openGroup(tester);
      expect(find.text('# Cats only'), findsNothing);
      expect(_markdownField, findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _app(tokens, posts, const GroupDetailScreen(slug: 'cats')),
      );
      await tester.pumpAndSettle();
      await _openGroup(tester);
      expect(find.text('# Cats only'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pumpAndSettle();
      await _openGroup(tester);
      expect(find.text('# Cats only'), findsNothing);
    },
  );

  testWidgets('late restore cannot replace an edit or cross a session change', (
    tester,
  ) async {
    final tokens = _Tokens();
    final posts = _PostsApi(tokens);
    final delayed = _DelayedStore();
    await tester.pumpWidget(
      _app(tokens, posts, const ComposePostScreen(), storage: delayed),
    );
    await tester.pumpAndSettle();
    expect(delayed.reads, 1);
    await tester.enterText(_plainField, 'Typed first');
    delayed.receipt.complete((text: 'Older response', markdown: false));
    await tester.pumpAndSettle();
    expect(find.text('Typed first'), findsOneWidget);
    expect(find.text('Older response'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    final inFlight = _DelayedStore();
    await tester.pumpWidget(
      _app(tokens, posts, const ComposePostScreen(), storage: inFlight),
    );
    await tester.pumpAndSettle();
    expect(inFlight.reads, 1);
    tokens.user = 2;
    tokens.beginSessionChange();
    inFlight.receipt.complete((text: 'Prior account', markdown: false));
    await tester.pumpAndSettle();
    expect(inFlight.reads, 2);
    expect(find.text('Prior account'), findsNothing);
    expect(find.text('Typed first'), findsNothing);
  });

  testWidgets('AI and cloud initial text leave an existing local draft alone', (
    tester,
  ) async {
    final tokens = _Tokens();
    final posts = _PostsApi(tokens);
    await tester.pumpWidget(_app(tokens, posts, const _ComposeLauncher()));
    await _open(tester);
    await tester.enterText(_plainField, 'Independent local');
    await _close(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _app(
        tokens,
        posts,
        const ComposePostScreen(initialDraft: 'Seeded by AI'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Seeded by AI'), findsOneWidget);
    expect(find.text('Independent local'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _app(
        tokens,
        posts,
        Consumer(
          builder: (_, ref, _) {
            return ComposePostScreen(
              cloudDraft: (
                scope: PostDraftScope(ref),
                draft: V2PostDraft(
                  id: 15,
                  payload: const V2PostDraftInput(content: 'Cloud-only text'),
                  status: PostDraftStatus.draft,
                  scheduledAt: null,
                  publishedPostId: null,
                  lastError: null,
                  updatedAt: DateTime.utc(2026),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cloud-only text'), findsOneWidget);
    expect(find.text('Independent local'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(tokens, posts, const ComposePostScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Independent local'), findsOneWidget);
  });

  test('storage excludes other account, API base and group scopes', () async {
    final tokens = _Tokens();
    final store = LocalPostDraftStore();
    LocalPostDraftSession session({
      int? group,
      String backend = 'https://fixture.invalid/v1',
    }) => LocalPostDraftSession(
      storage: store,
      tokens: tokens,
      backend: backend,
      groupId: group,
    );
    final original = session(group: 13);
    const value = (text: 'Group 13', markdown: false);
    original.update(value);
    expect(await session(group: 13).restore(), value);
    expect(await session(group: 14).restore(), isNull);
    expect(await session().restore(), isNull);
    expect(
      await session(group: 13, backend: 'https://fixture.invalid/v2').restore(),
      isNull,
    );
    tokens.user = 2;
    tokens.beginSessionChange();
    expect(await session(group: 13).restore(), isNull);
  });
}

Finder get _plainField => find.byKey(const Key('compose-content-field'));
Finder get _markdownField => find.byKey(const Key('post-markdown-field'));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pumpAndSettle();
}

Future<void> _openGroup(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FloatingActionButton, '发布群组动态'));
  await tester.pumpAndSettle();
}

Widget _app(
  _Tokens tokens,
  _PostsApi posts,
  Widget child, {
  LocalPostDraftStore? storage,
}) => ProviderScope(
  overrides: [
    appConfigInitialProvider.overrideWithValue(_config),
    appConfigBundleProvider.overrideWithValue(
      const AppConfigBundle(defaults: _config, presets: []),
    ),
    tokenStoreProvider.overrideWithValue(tokens),
    authSessionProvider.overrideWith(
      (_) => AuthSessionController(tokens)..markLoggedIn(),
    ),
    postsApiProvider.overrideWithValue(posts),
    groupsApiProvider.overrideWithValue(_GroupsApi(tokens)),
    if (storage != null) localPostDraftStoreProvider.overrideWithValue(storage),
  ],
  child: MaterialApp(home: child),
);

class _ComposeLauncher extends StatelessWidget {
  const _ComposeLauncher();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ComposePostScreen())),
      child: const Text('Open editor'),
    ),
  );
}

const _config = AppConfig(
  apiBaseUrl: 'https://fixture.invalid',
  wsBaseUrl: 'wss://fixture.invalid',
  storageBaseUrl: 'https://fixture.invalid',
);

ApiClient _client(TokenStore tokens) =>
    ApiClient(config: _config, tokenStore: tokens);

class _Tokens extends TokenStore {
  int user = 1;

  @override
  Future<TokenPair?> read() async {
    final claims = base64Url.encode(utf8.encode(jsonEncode({'userId': user})));
    return TokenPair(
      accessToken: 'header.$claims.signature',
      refreshToken: 'refresh',
      sessionId: 'session-$user',
    );
  }
}

class _DelayedStore extends LocalPostDraftStore {
  int reads = 0;
  final receipt = Completer<LocalPostDraftText?>();

  @override
  Future<LocalPostDraftText?> read(String key) =>
      ++reads == 1 ? receipt.future : super.read(key);
}

class _PostsApi extends PostsApi {
  _PostsApi(TokenStore tokens) : super(_client(tokens));

  bool unconfirmed = false;

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
    V2CreatePostPoll? poll,
    String? markdown,
  }) async {
    if (unconfirmed) throw const UnconfirmedPostError();
    return V2Post.fromJson({'post_id': 41, 'content': content});
  }
}

class _GroupsApi extends GroupsApi {
  _GroupsApi(TokenStore tokens) : super(_client(tokens));

  @override
  Future<V2Group> getGroup(String slug) async => V2Group.fromJson({
    'group_id': slug == 'cats' ? 24 : 25,
    'slug': slug,
    'name': slug,
    'privacy': 'private',
    'membership': {'is_member': true, 'role': 'member', 'status': 'active'},
    'post_permission': 'all',
  });

  @override
  Future<PagedResult<V2GroupPost>> posts(
    int groupId, {
    int page = 1,
    int size = 20,
    String type = 'all',
  }) async => const PagedResult(items: []);

  @override
  Future<V2GroupPost> createPost({
    required int groupId,
    required String content,
    bool isAnnouncement = false,
    List<String> mediaUrls = const [],
    V2CreatePostPoll? poll,
    String? markdown,
    CancelToken? cancelToken,
  }) async => V2GroupPost.fromJson({
    'group_id': groupId,
    'post_id': 1,
    'content': content,
    'markdown': markdown,
  });
}

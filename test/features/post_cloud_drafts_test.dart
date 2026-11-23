import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/posts/data/post_drafts_api.dart';
import 'package:nekotribe/features/posts/domain/post_draft.dart';
import 'package:nekotribe/features/posts/domain/post_poll.dart';
import 'package:nekotribe/features/posts/presentation/compose_post_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('explicit regular save, resume, schedule, cancel and publish', (
    tester,
  ) async {
    final store = _TestStore();
    final api = _DraftApi(store);
    await tester.pumpWidget(_app(store, api));
    await tester.enterText(
      find.byKey(const Key('compose-content-field')),
      'Cloud body',
    );
    await tester.pumpAndSettle();
    expect(api.actions, isEmpty);
    await _tap(tester, 'cloud-draft-save');
    expect(api.actions, ['create']);
    expect(api.record?.payload.content, 'Cloud body');
    expect(find.text('草稿已保存'), findsOneWidget);

    final saved = api.record!;
    api.record = _receipt(
      V2PostDraftInput(
        content: saved.payload.content,
        visibility: 'private',
        location: 'Shanghai',
        tags: ['two words', 'cats'],
        mentionUserIds: [18],
        mediaIds: [81],
        poll: V2CreatePostPoll(
          options: ['Cats', 'Dogs'],
          multiple: true,
          closesAt: DateTime.now().add(const Duration(days: 1)),
        ),
      ),
    );
    await tester.tap(find.byTooltip('云端草稿'));
    await tester.pumpAndSettle();
    await _tap(tester, 'cloud-draft-44');
    expect(find.text('Cloud body'), findsOneWidget);
    expect(find.text('Shanghai'), findsOneWidget);
    expect(find.text('two words, cats'), findsOneWidget);
    expect(find.text('已上传附件 81'), findsOneWidget);
    expect(find.text('Cats'), findsOneWidget);
    expect(find.text('Dogs'), findsOneWidget);
    final visibility = tester.widget<DropdownButton<String>>(
      find.byKey(const Key('compose-visibility-field')),
    );
    expect(visibility.value, 'private');
    final multiple = tester.widget<CheckboxListTile>(
      find.byKey(const Key('post-poll-multiple')),
    );
    expect(multiple.value, isTrue);

    await _tap(tester, 'cloud-draft-schedule');
    await _acceptPicker(tester);
    await _acceptPicker(tester);
    expect(api.actions, ['create', 'list']);
    await _confirm(tester, '定时发布');
    expect(api.actions.last, 'schedule');
    expect(api.record?.status, PostDraftStatus.scheduled);
    expect(find.textContaining('已定时'), findsOneWidget);

    await _tap(tester, 'cloud-draft-unschedule');
    expect(api.actions.last, 'unschedule');
    expect(api.record?.status, PostDraftStatus.draft);
    await _tap(tester, 'cloud-draft-publish');
    expect(api.actions.last, 'unschedule');
    await _confirm(tester, '立即发布草稿');
    expect(api.actions.last, 'publish');
    expect(api.record?.publishedPostId, 87);
    expect(find.text('已发布'), findsOneWidget);
    expect(api.record?.payload.mediaIds, [81]);
    expect(api.record?.payload.mentionUserIds, [18]);
    expect(api.record?.payload.poll?.options, ['Cats', 'Dogs']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除草稿'));
    await tester.pumpAndSettle();
    await _confirm(tester, '删除草稿');
    expect(api.actions, [
      'create',
      'list',
      'schedule',
      'unschedule',
      'publish',
      'list',
      'delete',
      'list',
    ]);
    expect(find.text('暂无云端草稿'), findsOneWidget);
  });

  testWidgets(
    'an account change invalidates the composer before a save receipt',
    (tester) async {
      final store = _TestStore();
      final pending = Completer<V2PostDraft>();
      final api = _DraftApi(store)..waitForSave = pending.future;
      await tester.pumpWidget(_app(store, api));
      await tester.enterText(
        find.byKey(const Key('compose-content-field')),
        'Old private draft',
      );
      await _tap(tester, 'cloud-draft-save');
      final request = api.saveToken!;
      store.beginSessionChange();
      pending.complete(
        _receipt(const V2PostDraftInput(content: 'Old private draft')),
      );
      await tester.pumpAndSettle();
      expect(request.isCancelled, isTrue);
      expect(find.text('Old private draft'), findsNothing);
      expect(find.text('草稿已保存'), findsNothing);
      expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
    },
  );

  testWidgets(
    'an unavailable group draft can reopen with its original fields',
    (tester) async {
      final store = _TestStore();
      final api = _DraftApi(store)
        ..record = _receipt(
          V2PostDraftInput.fromJson({
            'group_id': 10000000001,
            'content': 'Group note',
            'markdown': '# Group note',
            'media_urls': ['/previous.png'],
            'is_announcement': true,
          }),
          status: PostDraftStatus.failed,
        );
      await tester.pumpWidget(_app(store, api));
      await tester.tap(find.byTooltip('云端草稿'));
      await tester.pumpAndSettle();
      expect(find.textContaining('发布失败'), findsOneWidget);
      await _tap(tester, 'cloud-draft-44');
      final editor = find.byKey(const Key('post-markdown-field'));
      expect(find.text('# Group note'), findsOneWidget);
      expect(find.text('发布为群公告'), findsOneWidget);
      await tester.enterText(editor, '# Edited group note');
      await _tap(tester, 'cloud-draft-save');
      expect(api.actions, ['list', 'edit']);
      expect(api.record?.payload.groupId, 10000000001);
      expect(api.record?.payload.mediaUrls, ['/previous.png']);
      expect(api.record?.payload.announcement, isTrue);
      expect(api.record?.payload.content, 'Edited group note');
      expect(api.record?.payload.markdown, '# Edited group note');
    },
  );
}

Future<void> _tap(WidgetTester tester, String key) async {
  final button = find.byKey(Key(key));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.widgetWithText(FilledButton, label),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _acceptPicker(WidgetTester tester) async {
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Widget _app(TokenStore store, PostDraftsApi api) => ProviderScope(
  overrides: [
    appConfigBundleProvider.overrideWithValue(
      const AppConfigBundle(defaults: _config, presets: []),
    ),
    appConfigInitialProvider.overrideWithValue(_config),
    tokenStoreProvider.overrideWithValue(store),
    authSessionProvider.overrideWith(
      (_) => AuthSessionController(store)..markLoggedIn(),
    ),
    postDraftsApiProvider.overrideWithValue(api),
  ],
  child: const MaterialApp(home: ComposePostScreen()),
);

const _config = AppConfig(
  apiBaseUrl: 'https://example.invalid',
  wsBaseUrl: 'wss://example.invalid',
  storageBaseUrl: 'https://example.invalid',
);

class _TestStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => const TokenPair(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    sessionId: 'session-1',
  );
}

V2PostDraft _receipt(
  V2PostDraftInput payload, {
  PostDraftStatus status = PostDraftStatus.draft,
  DateTime? at,
  int? postId,
}) => V2PostDraft(
  id: 44,
  payload: payload,
  status: status,
  scheduledAt: at,
  publishedPostId: postId,
  lastError: status == PostDraftStatus.failed ? 'permission_denied' : null,
  updatedAt: DateTime.now(),
);

class _DraftApi extends PostDraftsApi {
  _DraftApi(TokenStore store)
    : super(ApiClient(config: _config, tokenStore: store));

  V2PostDraft? record;
  Future<V2PostDraft>? waitForSave;
  CancelToken? saveToken;
  final actions = <String>[];

  @override
  Future<PostDraftPage> list({
    int? groupId,
    int? beforeId,
    required CancelToken cancel,
  }) async {
    actions.add('list');
    return (items: [?record], cursor: null);
  }

  @override
  Future<V2PostDraft> save(
    V2PostDraftInput input, {
    int? id,
    required CancelToken cancel,
  }) async {
    actions.add(id == null ? 'create' : 'edit');
    saveToken = cancel;
    final saved =
        await (waitForSave ?? Future<V2PostDraft>.value(_receipt(input)));
    record = saved;
    return saved;
  }

  @override
  Future<V2PostDraft> schedule(
    V2PostDraft draft,
    DateTime at, {
    required CancelToken cancel,
  }) async {
    actions.add('schedule');
    return record = _receipt(
      draft.payload,
      status: PostDraftStatus.scheduled,
      at: at,
    );
  }

  @override
  Future<V2PostDraft> unschedule(
    V2PostDraft draft, {
    required CancelToken cancel,
  }) async {
    actions.add('unschedule');
    return record = _receipt(draft.payload);
  }

  @override
  Future<V2PostDraft> publish(
    V2PostDraft draft, {
    required CancelToken cancel,
  }) async {
    actions.add('publish');
    return record = _receipt(
      draft.payload,
      status: PostDraftStatus.published,
      postId: 87,
    );
  }

  @override
  Future<void> remove(int id, {required CancelToken cancel}) async {
    actions.add('delete');
    record = null;
  }
}

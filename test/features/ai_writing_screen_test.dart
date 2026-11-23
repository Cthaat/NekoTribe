import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/core/utils/ai_conversation_link.dart';
import 'package:nekotribe/features/ai/data/ai_writing_api.dart';
import 'package:nekotribe/features/ai/presentation/ai_writing_screen.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/posts/presentation/compose_post_screen.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

import 'fixtures/ai_availability.dart';

const _termsAsset = 'contracts/requirements/ai-public-terms-catalog.json';

class _CitationGroups implements GroupsApi {
  String privacy = 'private';

  @override
  Future<V2Group> getGroupById(int groupId) async {
    expect(groupId, 7);
    return V2Group.fromJson({
      'group_id': groupId,
      'slug': 'public-cat',
      'is_active': 1,
      'privacy': privacy,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _composerConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class _TermsBundle extends CachingAssetBundle {
  _TermsBundle(this.catalog);
  final String catalog;

  @override
  Future<ByteData> load(String key) => rootBundle.load(key);

  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      key == _termsAsset
      ? SynchronousFuture(catalog)
      : super.loadString(key, cache: cache);
}

class FakeWritingApi extends AiWritingApi {
  FakeWritingApi()
    : super(
        ApiClient(
          config: const AppConfig(
            apiBaseUrl: 'http://example.test',
            wsBaseUrl: 'ws://example.test',
            storageBaseUrl: 'http://example.test',
          ),
          tokenStore: TokenStore(),
        ),
      );
  final messages = <AiWritingMessage>[];
  int appends = 0;
  int generations = 0;
  int deletions = 0;
  int historyReads = 0;
  final historyCursors = <int?>[];
  bool legacyHistory = false;
  bool blockSavedHistory = false;
  bool failFirst = false;
  bool conversationMissing = false;
  bool ambiguousAppend = false;
  bool failDelete = false;
  bool hasHistory = false;
  AiConversationPage Function(String?)? historyPage;
  String historyPurpose = 'writing';
  bool noEvidence = false;
  int knowledgeCreations = 0;
  final createdTitles = <String?>[];
  String createdId = 'id';
  int knowledgeGenerations = 0;
  final phrases = <String?>[];
  final selectedWritingSkills = <bool>[];
  final selectedKnowledgeSkills = <bool>[];
  AiAvailability flags = const AiAvailability(knowledge: true, writing: true);
  bool failAvailability = false;
  Completer<AiAvailability>? pendingAvailability;
  Completer<void>? pendingAppend;
  bool waitForStop = false;
  bool conflictOnGeneration = false;
  final generatedSequences = <int?>[];
  @override
  Future<AiAvailability> availability() async {
    if (failAvailability) throw StateError('unavailable');
    return pendingAvailability?.future ?? flags;
  }

  @override
  Future<String> createKnowledgeConversation({
    String? title,
    AiKnowledgeScope? knowledgeScope,
    int? groupId,
  }) async {
    createdTitles.add(title);
    knowledgeCreations++;
    return 'id';
  }

  @override
  Future<bool> generateKnowledge(
    String id, {
    String? searchPhrase,
    CancelToken? cancelToken,
    bool selectSkill = false,
    int? expectedSequence,
    void Function(String)? onDelta,
  }) async {
    knowledgeGenerations++;
    selectedKnowledgeSkills.add(selectSkill);
    phrases.add(searchPhrase);
    return !noEvidence;
  }

  @override
  Future<String> createConversation({String? title}) async {
    createdTitles.add(title);
    return createdId;
  }

  @override
  Future<AiConversation> readConversation(String id) async => AiConversation(
    id: id,
    purpose: historyPurpose,
    title: 'previous draft',
    updatedAt: '2026-01-01',
  );

  @override
  Future<AiConversationPage> listConversations({
    String? afterId,
    String? purpose,
    AiKnowledgeScope? knowledgeScope,
    int? groupId,
  }) async =>
      historyPage?.call(afterId) ??
      AiConversationPage(
        items: hasHistory
            ? [
                AiConversation(
                  id: 'id',
                  purpose: historyPurpose,
                  title: 'previous draft',
                  updatedAt: '2026-01-01',
                ),
              ]
            : [],
        nextCursor: null,
      );
  @override
  Future<void> deleteConversation(String id) async {
    deletions++;
    if (failDelete) throw StateError('connection lost');
    messages.clear();
  }

  @override
  Future<int> appendMessage(String id, String content) async {
    appends++;
    final sequence = messages.length + 1;
    messages.add(
      AiWritingMessage(
        id: 'u',
        sequence: sequence,
        role: 'user',
        content: content,
      ),
    );
    await pendingAppend?.future;
    if (ambiguousAppend) throw StateError('connection lost after commit');
    return sequence;
  }

  @override
  Future<void> generate(
    String id, {
    CancelToken? cancelToken,
    bool selectSkill = false,
    int? expectedSequence,
    void Function(String)? onDelta,
  }) async {
    selectedWritingSkills.add(selectSkill);
    generatedSequences.add(expectedSequence);
    generations++;
    if (conflictOnGeneration) {
      messages.add(
        const AiWritingMessage(
          id: 'other',
          sequence: 2,
          role: 'user',
          content: '另一台设备的消息',
        ),
      );
      throw ApiException(code: 40901, statusCode: 409, message: 'conflict');
    }
    if (waitForStop) throw await cancelToken!.whenCancel;
    if (conversationMissing) {
      messages.clear();
      throw ApiException(code: 40401, statusCode: 404, message: 'not found');
    }
    if (failFirst && generations == 1) throw StateError('unavailable');
    messages.add(
      AiWritingMessage.fromJson({
        'message_id': 'a',
        'sequence_no': messages.length + 1,
        'role': 'assistant',
        'content': '草稿',
        'model_version': 'writing-build-4',
        'config_revision': 4,
      }),
    );
  }

  @override
  Future<List<AiWritingMessage>> listMessages(
    String id, {
    int afterSequence = 0,
    int? beforeSequence,
  }) async {
    historyReads++;
    historyCursors.add(beforeSequence);
    if (legacyHistory) beforeSequence = null;
    if (blockSavedHistory && generations > 0) throw StateError('offline');
    final selected = messages
        .where(
          (m) =>
              m.sequence > afterSequence &&
              (beforeSequence == null || m.sequence < beforeSequence),
        )
        .toList();
    return beforeSequence == null
        ? selected.take(50).toList()
        : selected
              .skip(selected.length > 50 ? selected.length - 50 : 0)
              .toList();
  }
}

Future<void> pumpScreen(
  WidgetTester tester,
  FakeWritingApi api, {
  bool knowledge = false,
  String? initialConversationId,
  Locale locale = const Locale('zh'),
  TokenStore? store,
  AssetBundle? bundle,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiWritingApiProvider.overrideWithValue(api),
        appConfigBundleProvider.overrideWithValue(
          const AppConfigBundle(defaults: _composerConfig, presets: []),
        ),
        appConfigInitialProvider.overrideWithValue(_composerConfig),
        if (store != null) tokenStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supported,
        home: DefaultAssetBundle(
          bundle: bundle ?? rootBundle,
          child: AiWritingScreen(
            knowledge: knowledge,
            initialConversationId: initialConversationId,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const linkedId = 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';

  testWidgets(
    'message bytes disable overlong drafts and allow the exact limit',
    (tester) async {
      final api = FakeWritingApi();
      await pumpScreen(tester, api);
      final input = find.byKey(const Key('ai-writing-input'));
      final send = find.byKey(const Key('ai-writing-send'));
      final prefix = '界' * 21845;
      await tester.enterText(input, '${prefix}ab');
      await tester.pump();
      expect(find.text('65537 / 65536 字节'), findsOneWidget);
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      expect(api.appends, 0);

      await tester.enterText(input, '${prefix}a');
      await tester.pump();
      expect(find.text('65536 / 65536 字节'), findsOneWidget);
      expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    },
  );

  testWidgets(
    'sequence conflict requires review of the newly loaded message before another generation',
    (tester) async {
      final api = FakeWritingApi()..conflictOnGeneration = true;
      await pumpScreen(tester, api);
      await tester.enterText(find.byKey(const Key('ai-writing-input')), '原请求');
      await tester.tap(find.byKey(const Key('ai-writing-send')));
      await tester.pumpAndSettle();
      expect(api.generatedSequences, [1]);
      expect(find.textContaining('会话已有更新'), findsOneWidget);
      final retry = find.byKey(const Key('ai-writing-retry'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(api.generatedSequences, [1]);
      expect(api.appends, 1);
      expect(find.textContaining('另一台设备的消息'), findsOneWidget);
    },
  );

  testWidgets(
    'a saved AI draft opens as editable post text and expires with the session',
    (tester) async {
      final store = TokenStore();
      final api = FakeWritingApi()
        ..messages.add(
          const AiWritingMessage(
            id: 'saved',
            sequence: 1,
            role: 'assistant',
            content: '待发布的草稿',
          ),
        );
      await pumpScreen(
        tester,
        api,
        initialConversationId: linkedId,
        store: store,
      );
      await tester.tap(find.text('用作帖子'));
      await tester.pumpAndSettle();
      final editor = find.byKey(const Key('compose-content-field'));
      expect(tester.widget<TextField>(editor).controller!.text, '待发布的草稿');
      await tester.enterText(editor, '已编辑的草稿');
      expect(api.appends, 0);
      store.beginSessionChange();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, isEmpty);
    },
  );

  testWidgets(
    'uses a writing reply in the existing post without losing metadata',
    (tester) async {
      final store = TokenStore();
      final api = FakeWritingApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            appConfigBundleProvider.overrideWithValue(
              const AppConfigBundle(defaults: _composerConfig, presets: []),
            ),
            appConfigInitialProvider.overrideWithValue(_composerConfig),
            authSessionProvider.overrideWith(
              (_) => AuthSessionController(store)..markLoggedIn(),
            ),
            aiWritingApiProvider.overrideWithValue(api),
          ],
          child: const MaterialApp(home: ComposePostScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final body = find.byKey(const Key('compose-content-field'));
      final location = find.byKey(const Key('compose-location-field'));
      final tags = find.byKey(const Key('compose-tags-field'));
      await tester.enterText(body, '原正文');
      await tester.enterText(location, '上海');
      await tester.enterText(tags, '手动标签');
      final open = find.byTooltip('AI 写作助手');
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      final draft = find.byKey(const Key('ai-writing-input'));
      expect(tester.widget<TextField>(draft).controller!.text, '原正文');
      expect(api.appends, 0);
      expect(api.createdTitles, isEmpty);
      await tester.tap(find.byKey(const Key('ai-writing-send')));
      await tester.pumpAndSettle();
      expect(api.messages.first.content, contains('原正文'));
      expect(api.messages.first.content, isNot(contains('上海')));
      await tester.tap(find.text('用到当前帖子'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(body).controller!.text, '草稿');
      expect(tester.widget<TextField>(location).controller!.text, '上海');
      expect(tester.widget<TextField>(tags).controller!.text, '手动标签');

      store.beginSessionChange();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(body).controller!.text, isEmpty);
    },
  );

  test('conversation links accept a single valid UUID', () {
    expect(validAiConversationLinkId(linkedId.toUpperCase()), linkedId);
    expect(validAiConversationLinkId('$linkedId\n'), isNull);
    expect(
      readAiConversationLink(
        Uri.parse('/ai/writing?conversation=$linkedId&conversation=$linkedId'),
      ),
      isNull,
    );
  });

  for (final pushed in [false, true]) {
    testWidgets(
      'keeps confirmed conversation across a stop (pushed: $pushed)',
      (tester) async {
        final api = FakeWritingApi()
          ..createdId = linkedId
          ..pendingAppend = Completer<void>()
          ..waitForStop = true;
        final router = GoRouter(
          initialLocation: pushed ? '/' : '/ai/writing',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('home')),
            ),
            GoRoute(
              path: '/ai/writing',
              builder: (context, state) {
                final id = readAiConversationLink(state.uri);
                return AiWritingRouteScreen(conversationId: id);
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [aiWritingApiProvider.overrideWithValue(api)],
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: const [
                AppLocalizationsDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supported,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (pushed) {
          router.push<void>('/ai/writing');
          await tester.pumpAndSettle();
        }
        await tester.enterText(
          find.byKey(const Key('ai-writing-input')),
          '写一篇公告',
        );
        await tester.tap(find.byKey(const Key('ai-writing-send')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        Uri? restoredLocation() {
          final current = router.routerDelegate.currentConfiguration;
          final match = current.lastOrNull;
          return match is ImperativeRouteMatch
              ? match.matches.uri
              : router.routeInformationParser
                    .restoreRouteInformation(current)
                    ?.uri;
        }

        expect(restoredLocation()?.queryParameters['conversation'], linkedId);
        expect(api.appends, 1);
        expect(api.generations, 0);
        api.pendingAppend!.complete();
        await tester.pump();
        final stop = find.byKey(const Key('ai-writing-stop'));
        expect(stop, findsOneWidget);
        await tester.tap(stop);
        await tester.pumpAndSettle();
        expect(restoredLocation()?.queryParameters['conversation'], linkedId);
        expect(find.textContaining('已停止等待回复'), findsOneWidget);
        api.waitForStop = false;
        await tester.tap(find.byKey(const Key('ai-writing-retry')));
        await tester.pumpAndSettle();
        expect(find.text('草稿'), findsOneWidget);
        expect(api.appends, 1);

        await tester.tap(find.byKey(const Key('ai-writing-new')));
        await tester.pumpAndSettle();
        expect(restoredLocation()?.hasQuery, isFalse);
        expect(find.text('草稿'), findsNothing);
        if (pushed) {
          expect(router.canPop(), isTrue);
          router.pop();
          await tester.pumpAndSettle();
          expect(find.text('home'), findsOneWidget);
          return;
        }
        router.go('/ai/writing?conversation=$linkedId');
        await tester.pumpAndSettle();
        expect(find.text('草稿'), findsOneWidget);
      },
    );
  }

  testWidgets('invalid conversation page preserves history and its cursor', (
    tester,
  ) async {
    AiConversation row(String id) => AiConversation(
      id: id,
      purpose: 'writing',
      title: 'draft $id',
      updatedAt: '2026-01-01',
    );
    final pages = [
      AiConversationPage(items: [row('a')], nextCursor: 'a'),
      AiConversationPage(items: [row('b'), row('b')], nextCursor: null),
      AiConversationPage(items: [row('b')], nextCursor: null),
    ];
    final cursors = <String?>[];
    final api = FakeWritingApi()
      ..historyPage = (cursor) {
        cursors.add(cursor);
        return pages.removeAt(0);
      };
    await pumpScreen(tester, api);
    await tester.tap(find.byKey(const Key('ai-writing-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('draft a'), findsOneWidget);
    expect(find.text('draft b'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '重试'));
    await tester.pumpAndSettle();
    expect(find.text('draft a'), findsOneWidget);
    expect(find.text('draft b'), findsOneWidget);
    expect(cursors, [null, 'a', 'a']);
  });

  testWidgets('opens saved messages from a matching conversation link', (
    tester,
  ) async {
    final api = FakeWritingApi()
      ..messages.add(
        const AiWritingMessage(
          id: 'saved',
          sequence: 1,
          role: 'assistant',
          content: '已保存的回复',
        ),
      );
    await pumpScreen(tester, api, initialConversationId: linkedId);
    await tester.pumpAndSettle();
    expect(api.historyReads, 1);
    expect(find.text('已保存的回复'), findsOneWidget);
  });

  testWidgets('does not read writing messages on a knowledge link', (
    tester,
  ) async {
    final api = FakeWritingApi();
    await pumpScreen(
      tester,
      api,
      knowledge: true,
      initialConversationId: linkedId,
    );
    await tester.pumpAndSettle();
    expect(api.historyReads, 0);
    expect(find.text('此会话已不存在或无法访问，可以开始新会话。'), findsOneWidget);
  });

  testWidgets('an explicit title is sent once and separate from the draft', (
    tester,
  ) async {
    final api = FakeWritingApi();
    await pumpScreen(tester, api);
    expect(find.byKey(const Key('ai-writing-explicit-skill')), findsNothing);
    await tester.tap(find.byKey(const Key('ai-conversation-title')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('ai-conversation-title-input')),
      '  项目笔记  ',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ai-writing-input')), '撰写公告');
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    expect(api.createdTitles, ['项目笔记']);
    expect(api.messages.first.content, '撰写公告');
    expect(find.byKey(const Key('ai-conversation-title')), findsNothing);
  });

  testWidgets(
    'stop cancels generation and retry never resends the user message',
    (tester) async {
      final api = FakeWritingApi()..waitForStop = true;
      await pumpScreen(tester, api);
      await tester.tap(find.byKey(const Key('ai-writing-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('总结讨论').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ai-writing-input')),
        'keep this question',
      );
      final stop = find.byKey(const Key('ai-writing-stop'));
      expect(stop, findsNothing);
      await tester.tap(find.byKey(const Key('ai-writing-send')));
      await tester.pump();
      expect(stop, findsOneWidget);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(stop, findsNothing);
      expect(find.textContaining('已停止等待回复'), findsOneWidget);
      expect(find.textContaining('keep this question'), findsOneWidget);
      expect(api.messages.single.content, startsWith('总结以下讨论'));
      expect(api.appends, 1);
      expect(api.generations, 1);
      api.waitForStop = false;
      await tester.tap(find.byKey(const Key('ai-writing-retry')));
      await tester.pumpAndSettle();
      expect(api.appends, 1);
      expect(api.generations, 2);
      expect(find.text('草稿'), findsOneWidget);
    },
  );

  testWidgets('restores the draft when the conversation disappears', (
    tester,
  ) async {
    final api = FakeWritingApi()..conversationMissing = true;
    await pumpScreen(tester, api);
    await tester.enterText(
      find.byKey(const Key('ai-writing-input')),
      'keep my draft',
    );
    final send = find.byKey(const Key('ai-writing-send'));
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('此会话已不存在或无法访问，可以开始新会话。'), findsOneWidget);
    expect(find.text('keep my draft'), findsOneWidget);
    expect(find.byKey(const Key('ai-writing-delete')), findsNothing);
    expect(api.appends, 1);
    api.conversationMissing = false;
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(api.appends, 2);
    expect(find.text('草稿'), findsOneWidget);
  });

  testWidgets('session change clears a pending draft and skips generation', (
    tester,
  ) async {
    final api = FakeWritingApi()..pendingAppend = Completer<void>();
    final store = TokenStore();
    await pumpScreen(tester, api, store: store);
    await tester.enterText(
      find.byKey(const Key('ai-writing-input')),
      'private draft',
    );
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pump();
    expect(api.appends, 1);
    store.beginSessionChange();
    api.pendingAppend!.complete();
    await tester.pumpAndSettle();
    expect(find.text('private draft'), findsNothing);
    expect(find.text('会话已切换。请返回并重新打开此页。'), findsOneWidget);
    expect(api.generations, 0);
  });

  testWidgets('session change dismisses the old history dialog', (
    tester,
  ) async {
    final api = FakeWritingApi()..hasHistory = true;
    final store = TokenStore();
    await pumpScreen(tester, api, store: store);
    await tester.tap(find.byKey(const Key('ai-writing-history')));
    await tester.pumpAndSettle();
    expect(find.text('previous draft'), findsOneWidget);
    store.beginSessionChange();
    await tester.pumpAndSettle();
    expect(find.text('previous draft'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'initial status loading preserves an editable draft and blocks send',
    (tester) async {
      final api = FakeWritingApi()
        ..pendingAvailability = Completer<AiAvailability>();
      await pumpScreen(tester, api);
      await tester.enterText(find.byKey(const Key('ai-writing-input')), '保留草稿');
      expect(find.text('正在读取功能状态…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('ai-writing-send')))
            .onPressed,
        isNull,
      );
      expect(api.appends, 0);
      api.pendingAvailability!.complete(
        const AiAvailability(knowledge: true, writing: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('保留草稿'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('ai-writing-send')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'status and refresh fit a narrow screen in both languages and purposes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final locale in [const Locale('zh'), const Locale('en')]) {
        for (final knowledge in [false, true]) {
          final api = FakeWritingApi()
            ..flags = AiAvailability.fromJson(
              aiAvailabilityFixture(knowledge: true, writing: false),
            );
          await pumpScreen(tester, api, locale: locale, knowledge: knowledge);
          final expected = switch ((locale.languageCode, knowledge)) {
            ('zh', true) => '技能 · 知识问答 · v3 · 已启用',
            ('zh', false) => '技能 · 写作草稿 · v3 · 未启用',
            ('en', true) => 'Skill · Knowledge answers · v3 · Enabled',
            _ => 'Skill · Writing drafts · v3 · Disabled',
          };
          expect(find.text(expected), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('ai-availability-refresh')),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const Key('ai-writing-input')),
            'draft',
          );
          await tester.tap(find.byKey(const Key('ai-availability-refresh')));
          await tester.pumpAndSettle();
          expect(find.text('draft'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );

  testWidgets(
    'an earlier retry callback cannot generate after status becomes unavailable',
    (tester) async {
      final api = FakeWritingApi()..hasHistory = true;
      api.messages.add(
        const AiWritingMessage(
          id: 'u',
          sequence: 1,
          role: 'user',
          content: 'question',
        ),
      );
      await pumpScreen(tester, api);
      await tester.tap(find.byKey(const Key('ai-writing-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('previous draft'));
      await tester.pumpAndSettle();
      final previousRetry = tester
          .widget<TextButton>(find.byKey(const Key('ai-writing-retry')))
          .onPressed!;
      api.failAvailability = true;
      await tester.tap(find.byKey(const Key('ai-availability-refresh')));
      await tester.pumpAndSettle();
      previousRetry();
      await tester.pumpAndSettle();
      expect(api.generations, 0);
      expect(api.appends, 0);
      expect(find.text('question'), findsOneWidget);
    },
  );

  testWidgets(
    'disabled purposes preserve input without appending or generating',
    (tester) async {
      for (final knowledge in [false, true]) {
        final api = FakeWritingApi()
          ..flags = AiAvailability(knowledge: !knowledge, writing: knowledge);
        await pumpScreen(tester, api, knowledge: knowledge);
        await tester.enterText(
          find.byKey(const Key('ai-writing-input')),
          '保留草稿',
        );
        expect(find.text('生成功能暂未启用，你仍可查看或删除历史会话。'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('ai-writing-send')))
              .onPressed,
          isNull,
        );
        expect(api.appends, 0);
        expect(api.generations, 0);
        expect(api.knowledgeGenerations, 0);
        expect(find.text('保留草稿'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('failed status can be refreshed without losing the draft', (
    tester,
  ) async {
    final api = FakeWritingApi()..failAvailability = true;
    await pumpScreen(tester, api);
    await tester.enterText(find.byKey(const Key('ai-writing-input')), '保留草稿');
    expect(find.text('暂时无法读取功能状态，请刷新后重试。'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('ai-writing-send')))
          .onPressed,
      isNull,
    );
    api.failAvailability = false;
    await tester.tap(find.byKey(const Key('ai-availability-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('生成功能已启用。'), findsOneWidget);
    expect(find.text('保留草稿'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    expect(api.appends, 1);
    expect(api.generations, 1);
    expect(find.text('模型版本 · writing-build-4'), findsOneWidget);
    expect(find.text('生成时的模型配置版本 4'), findsOneWidget);
  });

  testWidgets(
    'refresh clears the old enabled flag while the request is pending',
    (tester) async {
      final api = FakeWritingApi()
        ..flags = AiAvailability.fromJson(
          aiAvailabilityFixture(modelConfigRevision: 7),
        );
      await pumpScreen(tester, api);
      expect(find.text('技能 · 写作草稿 · v3 · 已启用'), findsOneWidget);
      expect(find.text('当前模型配置版本 7'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('ai-writing-input')), '草稿');
      final previousSend = tester
          .widget<IconButton>(find.byKey(const Key('ai-writing-send')))
          .onPressed!;
      api.pendingAvailability = Completer<AiAvailability>();
      await tester.tap(find.byKey(const Key('ai-availability-refresh')));
      await tester.pump();
      expect(find.text('正在读取功能状态…'), findsOneWidget);
      expect(find.text('技能 · 写作草稿 · v3 · 已启用'), findsNothing);
      expect(find.text('当前模型配置版本 7'), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('ai-writing-send')))
            .onPressed,
        isNull,
      );
      previousSend();
      await tester.pump();
      expect(api.appends, 0);
      api.pendingAvailability!.complete(
        const AiAvailability(knowledge: true, writing: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('草稿'), findsOneWidget);
      expect(api.appends, 0);
    },
  );

  testWidgets('unavailable generation leaves history and deletion usable', (
    tester,
  ) async {
    final api = FakeWritingApi()
      ..failAvailability = true
      ..hasHistory = true;
    api.messages.add(
      const AiWritingMessage(
        id: 'u',
        sequence: 1,
        role: 'user',
        content: 'old question',
      ),
    );
    await pumpScreen(tester, api);
    await tester.tap(find.byKey(const Key('ai-writing-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('previous draft'));
    await tester.pumpAndSettle();
    expect(find.text('old question'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('ai-writing-retry')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('ai-writing-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-writing-confirm-delete')));
    await tester.pumpAndSettle();
    expect(api.deletions, 1);
    expect(api.appends, 0);
  });

  test(
    'changing the API provider discards a pending status from the old client',
    () async {
      final oldApi = FakeWritingApi()
        ..pendingAvailability = Completer<AiAvailability>();
      final newApi = FakeWritingApi()
        ..flags = const AiAvailability(knowledge: false, writing: false);
      final container = ProviderContainer(
        overrides: [aiWritingApiProvider.overrideWithValue(oldApi)],
      );
      final subscription = container.listen(aiAvailabilityProvider, (_, _) {});
      try {
        container.updateOverrides([
          aiWritingApiProvider.overrideWithValue(newApi),
        ]);
        final result = await container.read(aiAvailabilityProvider.future);
        expect(result.writing, isFalse);
        oldApi.pendingAvailability!.complete(
          const AiAvailability(knowledge: true, writing: true),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(aiAvailabilityProvider).asData?.value.writing,
          isFalse,
        );
      } finally {
        subscription.close();
        container.dispose();
      }
    },
  );

  testWidgets(
    'knowledge conversation reports missing evidence without a false answer',
    (tester) async {
      final api = FakeWritingApi()
        ..noEvidence = true
        ..flags = AiAvailability.fromJson(
          aiAvailabilityFixture(explicitKnowledge: true),
        );
      await pumpScreen(tester, api, knowledge: true);
      await tester.tap(find.byKey(const Key('ai-writing-explicit-skill')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('ai-knowledge-search')), '猫');
      await tester.enterText(find.byKey(const Key('ai-writing-input')), '猫');
      await tester.tap(find.byKey(const Key('ai-writing-send')));
      await tester.pumpAndSettle();
      expect(api.knowledgeCreations, 1);
      expect(api.knowledgeGenerations, 1);
      expect(api.selectedKnowledgeSkills, [true]);
      expect(api.appends, 1);
      expect(find.text('当前范围内没有找到匹配的资料，请尝试其他文字。'), findsOneWidget);
      expect(find.text('草稿'), findsNothing);
    },
  );
  testWidgets('knowledge retry uses the new phrase without appending again', (
    tester,
  ) async {
    final api = FakeWritingApi()..noEvidence = true;
    await pumpScreen(tester, api, knowledge: true);
    await tester.enterText(
      find.byKey(const Key('ai-knowledge-search')),
      '\ufeff猫\u00a0',
    );
    await tester.enterText(
      find.byKey(const Key('ai-writing-input')),
      '社区有什么猫？',
    );
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ai-knowledge-search')), '猫咪');
    await tester.tap(find.byKey(const Key('ai-writing-retry')));
    await tester.pumpAndSettle();
    expect(api.appends, 1);
    expect(api.phrases, ['猫', '猫咪']);
    expect(api.messages.single.content, '社区有什么猫？');
  });
  testWidgets('invalid knowledge search does not append a question', (
    tester,
  ) async {
    final api = FakeWritingApi();
    await pumpScreen(tester, api, knowledge: true);
    await tester.enterText(find.byKey(const Key('ai-writing-input')), '问题');
    await tester.enterText(
      find.byKey(const Key('ai-knowledge-search')),
      '猫' * 86,
    );
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    expect(api.appends, 0);
    expect(api.knowledgeCreations, 0);
    expect(find.text('请输入不含控制字符、最多 256 UTF-8 字节的检索词。'), findsOneWidget);
  });
  testWidgets(
    'knowledge history refresh replaces stale answers without generating',
    (tester) async {
      final api = FakeWritingApi()
        ..hasHistory = true
        ..historyPurpose = 'knowledge';
      api.messages.add(
        const AiWritingMessage(
          id: 'a',
          sequence: 1,
          role: 'assistant',
          content: '回答',
          citations: [AiKnowledgeCitation(kind: 'comment', id: 42, postId: 99)],
        ),
      );
      await pumpScreen(tester, api, knowledge: true);
      await tester.tap(find.byKey(const Key('ai-writing-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('previous draft'));
      await tester.pumpAndSettle();
      expect(find.text('回答'), findsOneWidget);
      expect(find.text('评论 #42'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '评论 #42'), findsOneWidget);
      api.messages[0] = const AiWritingMessage(
        id: 'a',
        sequence: 1,
        role: 'assistant',
        content: '公开资料已变更，历史回答不可用。',
      );
      await tester.tap(find.widgetWithText(TextButton, '重新核对引用'));
      await tester.pumpAndSettle();
      expect(find.text('评论 #42'), findsNothing);
      expect(find.text('公开资料已变更，历史回答不可用。'), findsOneWidget);
      expect(api.knowledgeGenerations, 0);
    },
  );
  testWidgets('group citation opens the exact public group comment', (
    tester,
  ) async {
    final groups = _CitationGroups();
    final source = {
      'kind': 'group_comment',
      'id': 21,
      'post_id': 11,
      'group_id': 7,
      'version': 'a' * 64,
    };
    expect(
      () => AiKnowledgeCitation.fromJson({...source}..remove('group_id')),
      throwsFormatException,
    );
    final api = FakeWritingApi()..historyPurpose = 'knowledge';
    api.messages.add(
      AiWritingMessage(
        id: 'a',
        sequence: 1,
        role: 'assistant',
        content: '回答',
        citations: [AiKnowledgeCitation.fromJson(source)],
      ),
    );
    final router = GoRouter(
      initialLocation: '/ai/knowledge',
      routes: [
        GoRoute(
          path: '/ai/knowledge',
          builder: (_, _) => const AiWritingScreen(
            knowledge: true,
            initialConversationId: linkedId,
          ),
        ),
        GoRoute(
          path: '/groups/:slug/posts/:postId',
          builder: (_, state) => Scaffold(body: Text(state.uri.toString())),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiWritingApiProvider.overrideWithValue(api),
          groupsApiProvider.overrideWithValue(groups),
          appConfigBundleProvider.overrideWithValue(
            const AppConfigBundle(defaults: _composerConfig, presets: []),
          ),
          appConfigInitialProvider.overrideWithValue(_composerConfig),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supported,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final link = find.widgetWithText(TextButton, '群评论 #21');
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('这条来源已无法查看。'), findsOneWidget);
    expect(link, findsOneWidget);

    groups.privacy = 'public';
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('/groups/public-cat/posts/11?comment=21'), findsOneWidget);
  });
  for (final matchesVersion in [true, false]) {
    testWidgets(
      'terms citation opens only its exact version ($matchesVersion)',
      (tester) async {
        final catalog = await tester.runAsync(
          () => rootBundle.loadString(_termsAsset),
        );
        const conductVersion =
            '4b0140a9620e309395994e0cd38c1cf12dca541a8aad989da23f4c855a5e879a';
        final api = FakeWritingApi()
          ..hasHistory = true
          ..historyPurpose = 'knowledge';
        api.messages.add(
          AiWritingMessage.fromJson({
            'message_id': 'a',
            'sequence_no': 1,
            'role': 'assistant',
            'content': '回答',
            'citations': [
              {
                'kind': 'terms',
                'id': 3,
                'version': matchesVersion ? conductVersion : 'a' * 64,
              },
            ],
          }),
        );
        final store = TokenStore();
        await pumpScreen(
          tester,
          api,
          knowledge: true,
          store: store,
          bundle: _TermsBundle(catalog!),
        );
        await tester.tap(find.byKey(const Key('ai-writing-history')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('previous draft'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '平台条款 #3'));
        await tester.pumpAndSettle();
        expect(
          find.text('3. 用户行为'),
          matchesVersion ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('当前客户端版本未包含这版规则。'),
          matchesVersion ? findsNothing : findsOneWidget,
        );
        store.beginSessionChange();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }
  testWidgets('submits a writing request and shows the generated draft', (
    tester,
  ) async {
    final api = FakeWritingApi();
    await pumpScreen(tester, api);
    await tester.enterText(find.byKey(const Key('ai-writing-input')), '帮我写公告');
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    expect(find.text('帮我写公告'), findsOneWidget);
    expect(find.text('草稿'), findsOneWidget);
    expect(api.appends, 1);
  });

  testWidgets(
    'writing can explicitly select the skill on a supporting backend',
    (tester) async {
      final api = FakeWritingApi()
        ..flags = AiAvailability.fromJson(
          aiAvailabilityFixture(explicitWriting: true),
        );
      await pumpScreen(tester, api);
      await tester.tap(find.byKey(const Key('ai-writing-explicit-skill')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('ai-writing-input')), '公告');
      await tester.tap(find.byKey(const Key('ai-writing-send')));
      await tester.pumpAndSettle();
      expect(api.selectedWritingSkills, [true]);
    },
  );

  testWidgets('retrying generation does not resend the user message', (
    tester,
  ) async {
    final api = FakeWritingApi()..failFirst = true;
    await pumpScreen(tester, api);
    await tester.enterText(find.byKey(const Key('ai-writing-input')), '帮我写公告');
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-writing-retry')));
    await tester.pumpAndSettle();
    expect(find.text('草稿'), findsOneWidget);
    expect(api.appends, 1);
    expect(api.generations, 2);
  });

  testWidgets(
    'reopening current history reconciles an uncertain append and keeps the next draft',
    (tester) async {
      final api = FakeWritingApi()
        ..ambiguousAppend = true
        ..hasHistory = true;
      await pumpScreen(tester, api);
      await tester.enterText(find.byKey(const Key('ai-writing-input')), '公告');
      await tester.tap(find.byKey(const Key('ai-writing-send')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('ai-writing-send')))
            .onPressed,
        isNull,
      );
      expect(api.appends, 1);
      final input = find.byKey(const Key('ai-writing-input'));
      await tester.enterText(input, '下一条草稿');
      await tester.tap(find.byKey(const Key('ai-writing-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('previous draft'));
      await tester.pumpAndSettle();
      expect(find.text('公告'), findsWidgets);
      expect(tester.widget<TextField>(input).controller?.text, '下一条草稿');
      expect(api.appends, 1);
      expect(api.generations, 0);
    },
  );

  testWidgets('deleting a conversation asks for confirmation and clears it', (
    tester,
  ) async {
    final api = FakeWritingApi();
    await pumpScreen(tester, api);
    await tester.enterText(find.byKey(const Key('ai-writing-input')), '公告');
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-writing-delete')));
    await tester.pumpAndSettle();
    expect(api.deletions, 0);
    await tester.tap(find.byKey(const Key('ai-writing-confirm-delete')));
    await tester.pumpAndSettle();
    expect(api.deletions, 1);
    expect(find.text('草稿'), findsNothing);
  });

  testWidgets('uncertain delete keeps visible history and reports it', (
    tester,
  ) async {
    final api = FakeWritingApi()..failDelete = true;
    await pumpScreen(tester, api);
    await tester.enterText(find.byKey(const Key('ai-writing-input')), '公告');
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-writing-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-writing-confirm-delete')));
    await tester.pumpAndSettle();
    expect(find.text('草稿'), findsOneWidget);
    expect(find.text('删除未确认，请刷新会话状态或稍后重试。'), findsOneWidget);
  });

  testWidgets('restores an existing conversation and reads its messages', (
    tester,
  ) async {
    final api = FakeWritingApi()..hasHistory = true;
    api.messages.add(
      const AiWritingMessage(
        id: 'a',
        sequence: 1,
        role: 'assistant',
        content: 'old draft',
      ),
    );
    await pumpScreen(tester, api);
    await tester.tap(find.byKey(const Key('ai-writing-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('previous draft'));
    await tester.pumpAndSettle();
    expect(find.text('old draft'), findsOneWidget);
  });

  testWidgets('a saved reply waits for refresh without offering generation', (
    tester,
  ) async {
    final api = FakeWritingApi()..blockSavedHistory = true;
    await pumpScreen(tester, api);
    await tester.enterText(
      find.byKey(const Key('ai-writing-input')),
      'question',
    );
    await tester.tap(find.byKey(const Key('ai-writing-send')));
    await tester.pumpAndSettle();
    expect(find.text('回复已保存，暂时无法读取。请刷新会话查看。'), findsOneWidget);
    expect(find.byKey(const Key('ai-writing-retry')), findsNothing);
    api.blockSavedHistory = false;
    await tester.tap(find.byKey(const Key('ai-writing-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('草稿'), findsOneWidget);
    expect(api.generations, 1);
  });

  testWidgets(
    'restores recent AI history and fetches older messages on demand',
    (tester) async {
      final api = FakeWritingApi()..hasHistory = true;
      api.messages.addAll([
        for (var sequence = 4; sequence <= 55; sequence++)
          AiWritingMessage(
            id: 'message-$sequence',
            sequence: sequence,
            role: 'user',
            content: 'question $sequence',
          ),
      ]);
      await pumpScreen(tester, api);
      await tester.tap(find.byKey(const Key('ai-writing-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('previous draft'));
      await tester.pumpAndSettle();
      expect(find.text('question 55'), findsOneWidget);
      expect(api.historyCursors, [10000000000]);
      final older = find.text('加载更早的消息');
      await tester.scrollUntilVisible(
        older,
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(older);
      await tester.pumpAndSettle();
      expect(api.historyCursors, [10000000000, 6]);
      expect(older, findsNothing);
    },
  );

  testWidgets('loads older AI messages across gaps on a forward-only backend', (
    tester,
  ) async {
    final api = FakeWritingApi()
      ..hasHistory = true
      ..legacyHistory = true;
    api.messages.addAll([
      for (final sequence in [
        1,
        4,
        for (var index = 200; index < 250; index++) index,
      ])
        AiWritingMessage(
          id: 'message-$sequence',
          sequence: sequence,
          role: 'user',
          content: 'question $sequence',
        ),
    ]);
    await pumpScreen(tester, api);
    await tester.tap(find.byKey(const Key('ai-writing-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('previous draft'));
    await tester.pumpAndSettle();
    expect(find.text('question 249'), findsOneWidget);
    final older = find.text('加载更早的消息');
    final screen = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(older, 300, scrollable: screen);
    expect(find.text('question 4'), findsNothing);
    await tester.tap(older);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('question 1'),
      300,
      scrollable: screen,
    );
    expect(find.text('question 1'), findsOneWidget);
    expect(older, findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/ai/data/ai_writing_api.dart';
import 'package:nekotribe/features/ai/presentation/ai_writing_screen.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

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
  bool failFirst = false;
  bool ambiguousAppend = false;
  bool failDelete = false;
  bool hasHistory = false;
  String historyPurpose = 'writing';
  bool noEvidence = false;
  int knowledgeCreations = 0;
  int knowledgeGenerations = 0;
  final phrases = <String?>[];
  @override
  Future<String> createKnowledgeConversation() async {
    knowledgeCreations++;
    return 'id';
  }

  @override
  Future<bool> generateKnowledge(String id, {String? searchPhrase}) async {
    knowledgeGenerations++;
    phrases.add(searchPhrase);
    return !noEvidence;
  }

  @override
  Future<String> createConversation() async => 'id';
  @override
  Future<AiConversationPage> listConversations({String? afterId}) async =>
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
  Future<void> appendMessage(String id, String content) async {
    appends++;
    messages.add(
      AiWritingMessage(
        id: 'u',
        sequence: messages.length + 1,
        role: 'user',
        content: content,
      ),
    );
    if (ambiguousAppend) throw StateError('connection lost after commit');
  }

  @override
  Future<void> generate(String id) async {
    generations++;
    if (failFirst && generations == 1) throw StateError('unavailable');
    messages.add(
      AiWritingMessage(
        id: 'a',
        sequence: messages.length + 1,
        role: 'assistant',
        content: '草稿',
      ),
    );
  }

  @override
  Future<List<AiWritingMessage>> listMessages(
    String id, {
    int afterSequence = 0,
  }) async => messages.where((m) => m.sequence > afterSequence).toList();
}

Future<void> pumpScreen(
  WidgetTester tester,
  FakeWritingApi api, {
  bool knowledge = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [aiWritingApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supported,
        home: AiWritingScreen(knowledge: knowledge),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'knowledge conversation reports missing evidence without a false answer',
    (tester) async {
      final api = FakeWritingApi()..noEvidence = true;
      await pumpScreen(tester, api, knowledge: true);
      await tester.enterText(find.byKey(const Key('ai-knowledge-search')), '猫');
      await tester.enterText(find.byKey(const Key('ai-writing-input')), '猫');
      await tester.tap(find.byKey(const Key('ai-writing-send')));
      await tester.pumpAndSettle();
      expect(api.knowledgeCreations, 1);
      expect(api.knowledgeGenerations, 1);
      expect(api.appends, 1);
      expect(find.text('没有找到匹配的公开资料，请尝试其他文字。'), findsOneWidget);
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
  testWidgets('knowledge history shows cited sources', (tester) async {
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
  });
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

  testWidgets('an uncertain append requires refreshing before another send', (
    tester,
  ) async {
    final api = FakeWritingApi()..ambiguousAppend = true;
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
    await tester.tap(find.byKey(const Key('ai-writing-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('公告'), findsWidgets);
    expect(api.appends, 1);
  });

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
}

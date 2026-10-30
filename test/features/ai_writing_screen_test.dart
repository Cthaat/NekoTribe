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
  bool failFirst = false;
  bool ambiguousAppend = false;
  @override
  Future<String> createConversation() async => 'id';
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

Future<void> pumpScreen(WidgetTester tester, FakeWritingApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [aiWritingApiProvider.overrideWithValue(api)],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supported,
        home: AiWritingScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
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
}

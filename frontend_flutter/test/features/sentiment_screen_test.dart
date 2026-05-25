import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/sentiment_flow/data/sentiment_flow_api.dart';
import 'package:nekotribe/features/sentiment_flow/presentation/sentiment_screen.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('sentiment screen displays raw SentimentFlow prediction result', (
    tester,
  ) async {
    final api = _FakeSentimentFlowApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          sentimentFlowApiProvider.overrideWithValue(api),
          usersRepositoryProvider.overrideWithValue(_FakeUsersRepository()),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supported,
          home: const SentimentScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '432423');
    await tester.tap(find.text('分析'));
    await tester.pumpAndSettle();

    expect(api.predictedText, '432423');
    expect(api.predictedModelId, 'bert-v1');
    for (final element in find.byType(Text).evaluate()) {
      debugPrint('TEXT: ${(element.widget as Text).data}');
    }
    expect(find.text('neutral'), findsWidgets);
    expect(find.textContaining('50.0%'), findsWidgets);
  });
}

class _FakeSentimentFlowApi extends SentimentFlowApi {
  _FakeSentimentFlowApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? predictedText;
  String? predictedModelId;

  @override
  Future<V2SentimentFlowConfig> config() async => V2SentimentFlowConfig(
    enabled: true,
    baseUrl: '',
    baseUrlConfigured: true,
    proxyBasePath: '/api/v2/integrations/sentiment-flow',
    defaultModel: '',
    availableModels: const ['bert-v1', 'lstm-v1'],
    timeoutMs: 10000,
  );

  @override
  Future<V2SentimentPrediction> predict({
    required String text,
    String? modelId,
    bool? returnProbabilities,
    bool? includeMetadata,
    int? topK,
  }) async {
    predictedText = text;
    predictedModelId = modelId;
    return V2SentimentPrediction.fromJson({
      'text': text,
      'score': 3,
      'label': 'neutral',
      'label_zh': '中性',
      'confidence': 0.5,
      'probabilities': [0.1, 0.1, 0.1, 0.5, 0.1, 0.1],
      'reasoning': '模型将文本情感强度判定为 3 分（中性）。',
      'source': 'keyword-baseline-fallback(lstm:RuntimeError)',
      'model_name': '关键词基线',
    });
  }
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository()
    : super(
        UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())),
      );

  @override
  Future<V2UserSettings> getSettings() async => V2UserSettings(
    userId: 1,
    loginAlerts: true,
    profileVisibility: 'public',
    aiSentimentEnabled: true,
    aiSentimentModelId: 'bert-v1',
    aiSentimentReturnProbabilities: true,
    aiSentimentIncludeMetadata: true,
    aiSentimentTopK: 3,
    updatedAt: '2026-05-24T00:00:00.000Z',
  );
}

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);

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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/sentiment_flow/data/sentiment_flow_api.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/settings_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('settings page exposes SentimentFlow model and top-k controls', (
    tester,
  ) async {
    final users = _FakeUsersRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          usersRepositoryProvider.overrideWithValue(users),
          sentimentFlowApiProvider.overrideWithValue(_FakeSentimentFlowApi()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('BERT v1'), findsOneWidget);
    expect(find.textContaining('预测 12 次'), findsOneWidget);
    expect(find.text('Top-K 结果数'), findsOneWidget);

    await tester.tap(find.text('BERT v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LSTM v1').last);
    await tester.pumpAndSettle();

    expect(users.lastPatch?['ai_sentiment_model_id'], 'lstm-v1');

    await tester.tap(find.text('2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('5').last);
    await tester.pumpAndSettle();

    expect(users.lastPatch?['ai_sentiment_top_k'], 5);
  });
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository()
    : super(UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())));

  Map<String, dynamic>? lastPatch;
  V2UserSettings _settings = _settingsWith(modelId: 'bert-v1', topK: 2);

  @override
  Future<V2UserSettings> getSettings() async => _settings;

  @override
  Future<V2UserSettings> updateSettings(Map<String, dynamic> body) async {
    lastPatch = body;
    _settings = _settingsWith(
      modelId: body['ai_sentiment_model_id'] as String? ??
          _settings.aiSentimentModelId ??
          'bert-v1',
      topK: body['ai_sentiment_top_k'] as int? ??
          _settings.aiSentimentTopK ??
          3,
    );
    return _settings;
  }
}

class _FakeSentimentFlowApi extends SentimentFlowApi {
  _FakeSentimentFlowApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  @override
  Future<V2SentimentFlowConfig> config() async => V2SentimentFlowConfig(
    enabled: true,
    baseUrl: '',
    baseUrlConfigured: true,
    proxyBasePath: '/api/v2/integrations/sentiment-flow',
    defaultModel: 'bert-v1',
    availableModels: const ['bert-v1', 'lstm-v1'],
    timeoutMs: 10000,
  );

  @override
  Future<V2SentimentModelsData> listModels() async => V2SentimentModelsData(
    total: 2,
    items: [
      V2SentimentModelItem(
        modelId: 'bert-v1',
        name: 'BERT v1',
        version: '1.0.0',
        type: 'bert',
        isActive: true,
        createdAt: '2026-05-24T00:00:00.000Z',
      ),
      V2SentimentModelItem(
        modelId: 'lstm-v1',
        name: 'LSTM v1',
        version: '1.0.0',
        type: 'lstm',
        isActive: false,
        createdAt: '2026-05-24T00:00:00.000Z',
      ),
    ],
  );

  @override
  Future<V2SentimentStatsOverview> statsOverview() async =>
      V2SentimentStatsOverview(
        totalPredictions: 12,
        totalTrainingJobs: 3,
        activeModel: V2SentimentActiveModel(
          modelId: 'bert-v1',
          name: 'BERT v1',
          version: '1.0.0',
          activatedAt: '2026-05-24T00:00:00.000Z',
        ),
      );
}

V2UserSettings _settingsWith({required String modelId, required int topK}) {
  return V2UserSettings(
    userId: 1,
    twoFactorEnabled: false,
    loginAlerts: true,
    profileVisibility: 'public',
    showOnlineStatus: true,
    allowDmFromStrangers: true,
    pushNotificationEnabled: true,
    emailNotificationEnabled: true,
    aiSentimentEnabled: true,
    aiSentimentModelId: modelId,
    aiSentimentReturnProbabilities: true,
    aiSentimentIncludeMetadata: true,
    aiSentimentTopK: topK,
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

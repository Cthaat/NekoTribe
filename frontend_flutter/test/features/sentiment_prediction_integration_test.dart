import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/compose_post_screen.dart';
import 'package:nekotribe/features/posts/presentation/post_card.dart';
import 'package:nekotribe/features/sentiment_flow/data/sentiment_flow_api.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('compose screen can analyze the current draft text', (
    tester,
  ) async {
    final sentiment = _FakeSentimentFlowApi();

    await _pump(
      tester,
      sentiment: sentiment,
      child: const ComposePostScreen(),
    );

    await tester.enterText(find.byType(TextField).first, 'NekoTribe is lovely');
    await tester.tap(find.byTooltip('AI 情感分析'));
    await tester.pumpAndSettle();

    expect(sentiment.predictedText, 'NekoTribe is lovely');
    expect(find.text('positive'), findsOneWidget);
    expect(find.textContaining('91.0%'), findsOneWidget);
  });

  testWidgets('post card exposes AI sentiment prediction from its menu', (
    tester,
  ) async {
    final sentiment = _FakeSentimentFlowApi();

    await _pump(
      tester,
      sentiment: sentiment,
      child: Scaffold(body: PostCard(post: _post)),
    );

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 情感分析'));
    await tester.pumpAndSettle();

    expect(sentiment.predictedText, _post.content);
    expect(find.text('positive'), findsOneWidget);
    expect(find.text('BERT v1'), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeSentimentFlowApi sentiment,
  required Widget child,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(_testBundle),
        appConfigInitialProvider.overrideWithValue(_testConfig),
        tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
        usersRepositoryProvider.overrideWithValue(_FakeUsersRepository()),
        sentimentFlowApiProvider.overrideWithValue(sentiment),
      ],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeSentimentFlowApi extends SentimentFlowApi {
  _FakeSentimentFlowApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? predictedText;

  @override
  Future<V2SentimentFlowConfig> config() async => V2SentimentFlowConfig(
    enabled: true,
    baseUrl: '',
    baseUrlConfigured: true,
    proxyBasePath: '/api/v2/integrations/sentiment-flow',
    defaultModel: 'bert-v1',
    availableModels: const ['bert-v1'],
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
    return V2SentimentPrediction(
      label: 'positive',
      score: 0.88,
      confidence: 0.91,
      requestId: 'sent-1',
      modelId: modelId,
      modelName: 'BERT v1',
      modelVersion: '1.0.0',
      inputLanguage: 'en',
      inputLength: text.length,
      timingMs: 37,
      createdAt: '2026-05-24T00:00:00.000Z',
      probabilities: const {'positive': 0.91, 'neutral': 0.07},
      topK: [
        V2SentimentTopKItem(label: 'positive', score: 0.91),
        V2SentimentTopKItem(label: 'neutral', score: 0.07),
      ],
    );
  }
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository()
    : super(UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())));

  @override
  Future<V2UserSettings> getSettings() async => V2UserSettings(
    userId: 1,
    twoFactorEnabled: false,
    loginAlerts: true,
    profileVisibility: 'public',
    showOnlineStatus: true,
    allowDmFromStrangers: true,
    pushNotificationEnabled: true,
    emailNotificationEnabled: true,
    aiSentimentEnabled: true,
    aiSentimentModelId: 'bert-v1',
    aiSentimentReturnProbabilities: true,
    aiSentimentIncludeMetadata: true,
    aiSentimentTopK: 2,
    updatedAt: '2026-05-24T00:00:00.000Z',
  );
}

final _post = V2Post(
  postId: 100001,
  author: _user,
  content: 'NekoTribe is lovely',
  postType: 'post',
  visibility: 'public',
  language: 'en',
  location: '',
  media: const [],
  tags: const [],
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
    canDelete: false,
  ),
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
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

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';

class V2SentimentFlowConfig {
  V2SentimentFlowConfig({
    required this.enabled,
    required this.baseUrl,
    required this.baseUrlConfigured,
    required this.proxyBasePath,
    required this.defaultModel,
    required this.availableModels,
    required this.timeoutMs,
  });

  final bool enabled;
  final String baseUrl;
  final bool baseUrlConfigured;
  final String proxyBasePath;
  final String defaultModel;
  final List<String> availableModels;
  final int timeoutMs;

  factory V2SentimentFlowConfig.fromJson(Map<String, dynamic> json) {
    final baseUrl = toStr(json['base_url'] ?? json['baseUrl']);
    return V2SentimentFlowConfig(
      enabled: toBool(json['enabled']),
      baseUrl: baseUrl,
      baseUrlConfigured:
          json['baseUrlConfigured'] == null && json['base_url_configured'] == null
          ? baseUrl.isNotEmpty
          : toBool(json['baseUrlConfigured'] ?? json['base_url_configured']),
      proxyBasePath: toStr(
        json['proxyBasePath'] ?? json['proxy_base_path'],
        defaultValue: '/api/v2/integrations/sentiment-flow',
      ),
      defaultModel: toStr(json['default_model'] ?? json['defaultModel']),
      availableModels: toList(
        json['available_models'] ?? json['availableModels'],
        (e) => toStr(e),
      ),
      timeoutMs: toInt(json['timeout_ms'] ?? json['timeoutMs']) ?? 30000,
    );
  }
}

class V2SentimentTopKItem {
  V2SentimentTopKItem({required this.label, required this.score});

  final String label;
  final double score;

  factory V2SentimentTopKItem.fromJson(Map<String, dynamic> json) {
    return V2SentimentTopKItem(
      label: toStr(json['label']),
      score: toDouble(json['score']) ?? 0,
    );
  }
}

class V2SentimentPrediction {
  V2SentimentPrediction({
    required this.label,
    required this.score,
    required this.confidence,
    this.requestId,
    this.modelId,
    this.modelName,
    this.modelVersion,
    this.inputLanguage,
    this.inputLength,
    this.timingMs,
    this.createdAt,
    this.probabilities,
    this.topK,
    this.metadata,
  });

  final String label;
  final double score;
  final double confidence;
  final String? requestId;
  final String? modelId;
  final String? modelName;
  final String? modelVersion;
  final String? inputLanguage;
  final int? inputLength;
  final int? timingMs;
  final String? createdAt;
  final Map<String, double>? probabilities;
  final List<V2SentimentTopKItem>? topK;
  final Map<String, dynamic>? metadata;

  factory V2SentimentPrediction.fromJson(Map<String, dynamic> json) {
    final prediction = json['prediction'] is Map<String, dynamic>
        ? json['prediction'] as Map<String, dynamic>
        : json;
    final model = json['model'] is Map<String, dynamic>
        ? json['model'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final input = json['input'] is Map<String, dynamic>
        ? json['input'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final confidence =
        toDouble(prediction['confidence']) ?? toDouble(prediction['score']) ?? 0;
    return V2SentimentPrediction(
      label: toStr(prediction['label']),
      score: toDouble(prediction['score']) ?? confidence,
      confidence: confidence,
      requestId: toStrOrNull(json['request_id'] ?? json['requestId']),
      modelId: toStrOrNull(model['id'] ?? model['model_id']),
      modelName: toStrOrNull(model['name']),
      modelVersion: toStrOrNull(model['version']),
      inputLanguage: toStrOrNull(input['language']),
      inputLength: toInt(input['length']),
      timingMs: toInt(json['timing_ms'] ?? json['timingMs']),
      createdAt: toStrOrNull(json['created_at'] ?? json['createdAt']),
      probabilities: _probabilitiesFromJson(prediction['probabilities']),
      topK: toList(
        prediction['top_k'] ?? prediction['topK'],
        (e) => V2SentimentTopKItem.fromJson(toMap(e)),
      ),
      metadata: json['metadata'] is Map<String, dynamic>
          ? json['metadata'] as Map<String, dynamic>
          : null,
    );
  }

  static Map<String, double>? _probabilitiesFromJson(Object? value) {
    if (value is! Map) return null;
    return value.map(
      (key, item) => MapEntry(key.toString(), toDouble(item) ?? 0),
    );
  }
}

class SentimentFlowApi {
  SentimentFlowApi(this._client);

  final ApiClient _client;

  Future<V2SentimentFlowConfig> config() {
    return _client.requestData<V2SentimentFlowConfig>(
      ApiPaths.sentimentFlowConfig,
      decode: (data) => V2SentimentFlowConfig.fromJson(toMap(data)),
    );
  }

  Future<V2SentimentPrediction> predict({
    required String text,
    String? modelId,
    bool? returnProbabilities,
    bool? includeMetadata,
    int? topK,
  }) {
    return _client.requestData<V2SentimentPrediction>(
      '${ApiPaths.sentimentFlowProxy}/predict/',
      method: 'POST',
      data: {
        'text': text,
        if (modelId != null) 'model_id': modelId,
        if (returnProbabilities != null)
          'return_probabilities': returnProbabilities,
        if (includeMetadata != null) 'include_metadata': includeMetadata,
        if (topK != null) 'top_k': topK,
      },
      decode: (data) => V2SentimentPrediction.fromJson(toMap(data)),
    );
  }
}

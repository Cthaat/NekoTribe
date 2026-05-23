import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';

class V2SentimentFlowConfig {
  V2SentimentFlowConfig({
    required this.enabled,
    required this.baseUrl,
    required this.defaultModel,
    required this.availableModels,
    required this.timeoutMs,
  });

  final bool enabled;
  final String baseUrl;
  final String defaultModel;
  final List<String> availableModels;
  final int timeoutMs;

  factory V2SentimentFlowConfig.fromJson(Map<String, dynamic> json) {
    return V2SentimentFlowConfig(
      enabled: toBool(json['enabled']),
      baseUrl: toStr(json['base_url']),
      defaultModel: toStr(json['default_model']),
      availableModels: toList(json['available_models'], (e) => toStr(e)),
      timeoutMs: toInt(json['timeout_ms']) ?? 30000,
    );
  }
}

class V2SentimentPrediction {
  V2SentimentPrediction({
    required this.label,
    required this.confidence,
    this.probabilities,
    this.metadata,
  });

  final String label;
  final double confidence;
  final Map<String, dynamic>? probabilities;
  final Map<String, dynamic>? metadata;

  factory V2SentimentPrediction.fromJson(Map<String, dynamic> json) {
    return V2SentimentPrediction(
      label: toStr(json['label']),
      confidence: toDouble(json['confidence']) ?? 0,
      probabilities: json['probabilities'] is Map<String, dynamic>
          ? json['probabilities'] as Map<String, dynamic>
          : null,
      metadata: json['metadata'] is Map<String, dynamic>
          ? json['metadata'] as Map<String, dynamic>
          : null,
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
      '${ApiPaths.sentimentFlowProxy}/predict',
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

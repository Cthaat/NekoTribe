import '../../../core/utils/json_utils.dart';

typedef AiModelStatus = ({
  String purpose,
  String state,
  String? model,
  String? version,
});

typedef AiOpsSummary = ({
  String backend,
  int? revision,
  List<AiModelStatus> models,
  int? quotaUsed,
  int? quotaLimit,
  int windowSeconds,
  int? indexPoints,
  String? indexPhase,
  int helpful,
  int incorrect,
  int insufficient,
});

AiOpsSummary parseAiOpsSummary(Object? raw) {
  final result = toMap(raw);
  final quota = toMap(result['global_quota']);
  final index = toMap(result['index']);
  final models = (result['models'] as List<Object?>)
      .map(toMap)
      .map(
        (row) => (
          purpose: row['purpose'] as String,
          state: row['state'] as String,
          model: row['model_id'] as String?,
          version: row['model_version'] as String?,
        ),
      )
      .toList(growable: false);
  var helpful = 0, incorrect = 0, insufficient = 0;
  for (final row in (result['feedback'] as List<Object?>).map(toMap)) {
    helpful += row['helpful'] as int;
    incorrect += row['incorrect'] as int;
    insufficient += row['insufficient'] as int;
  }
  return (
    backend: result['backend'] as String,
    revision: result['model_config_revision'] as int?,
    models: models,
    quotaUsed: quota['used_units'] as int?,
    quotaLimit: quota['limit_units'] as int?,
    windowSeconds: quota['window_seconds'] as int,
    indexPoints: index['point_count'] as int?,
    indexPhase: index['phase'] as String?,
    helpful: helpful,
    incorrect: incorrect,
    insufficient: insufficient,
  );
}

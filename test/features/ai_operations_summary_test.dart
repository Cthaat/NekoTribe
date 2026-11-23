import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/features/moderation/domain/ai_operations_summary.dart';

void main() {
  test('summarizes reviewed outcomes even when service dependencies are unavailable', () {
    final result = parseAiOpsSummary({
      'backend': 'rust',
      'model_config_revision': 42,
      'models': [
        {'purpose': 'writing', 'state': 'unreachable', 'model_id': 'writer'},
      ],
      'global_quota': {
        'used_units': null,
        'limit_units': 120,
        'window_seconds': 60,
      },
      'index': null,
      'feedback': [
        {'helpful': 3, 'incorrect': 1, 'insufficient': 2},
        {'helpful': 2, 'incorrect': 4, 'insufficient': 6},
      ],
    });
    expect(result.backend, 'rust');
    expect(result.models.single.state, 'unreachable');
    expect(result.indexPoints, isNull);
    expect(result.quotaUsed, isNull);
    expect((result.helpful, result.incorrect, result.insufficient), (5, 5, 8));
  });
}

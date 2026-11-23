import '../../../core/utils/json_utils.dart';

typedef AccountUsage = ({
  int? usedUnits,
  int? limitUnits,
  int windowSeconds,
  int mediaBytes,
  int mediaFiles,
  int conversations,
});

AccountUsage decodeAccountUsage(Object? value) {
  final data = toMap(value);
  final quota = toMap(data['ai_quota']);
  final media = toMap(data['media']);
  final history = toMap(data['ai_history']);
  return (
    usedUnits: quota['used_units'] as int?,
    limitUnits: quota['limit_units'] as int?,
    windowSeconds: quota['window_seconds'] as int,
    mediaBytes: media['bytes'] as int,
    mediaFiles: media['files'] as int,
    conversations: history['conversations'] as int,
  );
}

enum AccountExportFormat {
  json('json'),
  markdown('md');

  const AccountExportFormat(this.extension);
  final String extension;
}

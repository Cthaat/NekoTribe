int? toInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  if (v is bool) return v ? 1 : 0;
  return null;
}

double? toDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

bool toBool(dynamic v, {bool defaultValue = false}) {
  if (v == null) return defaultValue;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final lower = v.toLowerCase();
    if (lower == 'true' || lower == '1' || lower == 'yes') return true;
    if (lower == 'false' || lower == '0' || lower == 'no') return false;
  }
  return defaultValue;
}

String toStr(dynamic v, {String defaultValue = ''}) {
  if (v == null) return defaultValue;
  if (v is String) return v;
  return v.toString();
}

String? toStrOrNull(dynamic v) {
  if (v == null) return null;
  if (v is String) return v.isEmpty ? null : v;
  return v.toString();
}

DateTime? toDateTime(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

List<T> toList<T>(dynamic v, T Function(dynamic item) mapper) {
  if (v == null) return <T>[];
  if (v is List) {
    return v.map(mapper).toList();
  }
  return <T>[];
}

Map<String, dynamic> toMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return <String, dynamic>{};
}

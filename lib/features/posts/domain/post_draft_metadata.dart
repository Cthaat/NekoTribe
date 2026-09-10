List<String> draftTagNames({required String content, required String tags}) {
  return _uniqueTags([
    ..._extractHashTags(content),
    ..._splitManualTags(tags),
  ]).take(8).toList(growable: false);
}

List<String> _extractHashTags(String value) {
  return RegExp(r'#([\p{L}\p{N}_]+)', unicode: true)
      .allMatches(value)
      .map((match) => _normalizeTag(match.group(1) ?? ''))
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
}

List<String> _splitManualTags(String value) {
  return value
      .split(RegExp(r'[\s,，]+'))
      .map(_normalizeTag)
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
}

List<String> _uniqueTags(Iterable<String> tags) {
  final seen = <String>{};
  final result = <String>[];
  for (final tag in tags) {
    if (seen.add(tag)) result.add(tag);
  }
  return result;
}

String _normalizeTag(String value) {
  final normalized = value
      .trim()
      .replaceFirst(RegExp(r'^#+'), '')
      .toLowerCase();
  if (normalized.length <= 32) return normalized;
  return normalized.substring(0, 32);
}

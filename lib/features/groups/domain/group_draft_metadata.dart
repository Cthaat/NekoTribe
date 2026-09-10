const groupPrivacyValues = ['public', 'private', 'secret'];

const groupCategoryValues = [
  'tech',
  'game',
  'music',
  'art',
  'life',
  'study',
  'work',
  'other',
];

const groupPostPermissionValues = ['all', 'moderator_up', 'admin_only'];

List<String> groupDraftTags(String value) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in value.split(RegExp(r'[\s,，]+'))) {
    final tag = _normalizeGroupTag(raw);
    if (tag.isEmpty || !seen.add(tag)) continue;
    result.add(tag);
    if (result.length >= 8) break;
  }
  return result;
}

String _normalizeGroupTag(String value) {
  final normalized = value
      .trim()
      .replaceFirst(RegExp(r'^#+'), '')
      .toLowerCase();
  if (normalized.length <= 50) return normalized;
  return normalized.substring(0, 50);
}

Map<String, Object> aiAvailabilityFixture({
  bool knowledge = true,
  bool writing = true,
  bool group = true,
  bool moderation = true,
  bool explicitModeration = false,
  bool explicitWriting = false,
  bool explicitKnowledge = false,
  int? modelConfigRevision,
}) {
  const ids = {
    'knowledge': 'knowledge-answer',
    'writing': 'writing-draft',
    'group': 'group-brief',
    'moderation': 'moderation-advice',
  };
  final flags = {
    'knowledge': knowledge,
    'writing': writing,
    'group': group,
    'moderation': moderation,
  };
  return {
    ...flags,
    if (modelConfigRevision != null)
      'model_config_revision': modelConfigRevision,
    'skills': [
      for (final entry in ids.entries)
        {
          'id': entry.value,
          'purpose': entry.key,
          'version': 3,
          'enabled': flags[entry.key],
          if ((explicitModeration && entry.key == 'moderation') ||
              (explicitWriting && entry.key == 'writing') ||
              (explicitKnowledge && entry.key == 'knowledge'))
            'explicit_selection': true,
        },
    ],
  };
}

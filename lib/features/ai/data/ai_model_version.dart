final _modelVersionPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$');

String? aiModelVersion(Object? role, Object? value) =>
    role == 'assistant' &&
        value is String &&
        value.trim() == value &&
        _modelVersionPattern.hasMatch(value)
    ? value
    : null;

int? aiReplyConfigRevision(Object? role, Object? value) =>
    role == 'assistant' &&
        value is int &&
        value >= 1 &&
        value <= 999999999999999
    ? value
    : null;

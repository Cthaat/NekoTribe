String? normalizeGroupInviteCode(String? raw) {
  final code = raw?.trim();
  if (code == null || !RegExp(r'^[a-zA-Z0-9]{1,32}$').hasMatch(code)) {
    return null;
  }
  return code.toUpperCase();
}

String? groupInviteLocation(String? raw) {
  final code = normalizeGroupInviteCode(raw);
  return code == null ? null : '/groups/invite/$code';
}

String? parseGroupInviteInput(String raw) {
  final originalCode = normalizeGroupInviteCode(raw);
  if (originalCode != null) return originalCode;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  final parts = uri.pathSegments;
  if (parts.length < 3 ||
      parts[parts.length - 3] != 'groups' ||
      parts[parts.length - 2] != 'invite') {
    return null;
  }
  return normalizeGroupInviteCode(parts.last);
}

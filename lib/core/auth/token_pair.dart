class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.sessionId,
    this.accessTokenExpiresAt,
    this.refreshTokenExpiresAt,
  });
  final String accessToken;
  final String refreshToken;
  final String sessionId;
  final DateTime? accessTokenExpiresAt;
  final DateTime? refreshTokenExpiresAt;

  factory TokenPair.fromJson(Map<String, dynamic> data) {
    final accessExpiry = parseSessionExpiry(data['access_token_expires_at']);
    final refreshExpiry = parseSessionExpiry(data['refresh_token_expires_at']);
    if (!refreshExpiry.isAfter(accessExpiry)) {
      throw const FormatException('Invalid session expiry order');
    }
    return TokenPair(
      accessToken: _text(data['access_token']),
      refreshToken: _text(data['refresh_token']),
      sessionId: _text(data['session_id']),
      accessTokenExpiresAt: accessExpiry,
      refreshTokenExpiresAt: refreshExpiry,
    );
  }
  bool get isAccessExpired =>
      accessTokenExpiresAt != null &&
      DateTime.now().isAfter(accessTokenExpiresAt!);
  bool get isRefreshExpired =>
      refreshTokenExpiresAt != null &&
      DateTime.now().isAfter(refreshTokenExpiresAt!);
}

String _text(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Invalid session data');
  }
  return value;
}

DateTime parseSessionExpiry(Object? value) {
  final text = _text(value);
  final parts = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|([+-])(\d{2}):(\d{2}))$',
  ).firstMatch(text);
  if (parts == null) throw const FormatException('Invalid session expiry');
  final year = int.parse(parts[1]!),
      month = int.parse(parts[2]!),
      day = int.parse(parts[3]!);
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      int.parse(parts[4]!) > 23 ||
      int.parse(parts[5]!) > 59 ||
      int.parse(parts[6]!) > 59 ||
      (parts[8] != null &&
          (int.parse(parts[8]!) > 23 || int.parse(parts[9]!) > 59))) {
    throw const FormatException('Invalid session expiry');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) throw const FormatException('Invalid session expiry');
  return parsed;
}

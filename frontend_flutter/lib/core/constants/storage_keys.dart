class StorageKeys {
  StorageKeys._();

  // Secure storage (auth)
  static const String accessToken = 'nekotribe.access_token';
  static const String refreshToken = 'nekotribe.refresh_token';
  static const String sessionId = 'nekotribe.session_id';
  static const String accessTokenExpiresAt =
      'nekotribe.access_token_expires_at';
  static const String refreshTokenExpiresAt =
      'nekotribe.refresh_token_expires_at';
  static const String currentUser = 'nekotribe.current_user';
  static const String deviceFingerprint = 'nekotribe.device_fingerprint';

  // Shared preferences (UI)
  static const String themeMode = 'nekotribe.theme_mode';
  static const String locale = 'nekotribe.locale';
  static const String draftPost = 'nekotribe.draft_post';

  // Shared preferences (network endpoint override)
  static const String endpointOverride = 'nekotribe.endpoint_override';
}

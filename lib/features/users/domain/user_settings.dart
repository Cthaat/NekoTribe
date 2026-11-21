import '../../../core/utils/auth_input.dart';

Never _invalid() =>
    throw const FormatException('Invalid account settings response');
Map<String, dynamic> _record(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

bool _boolean(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! bool) _invalid();
  return value;
}

String _string(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String) _invalid();
  return value;
}

void validateAccountSettingsEnvelope(Object? value) {
  final body = _record(value);
  if (body['code'] is! num ||
      body['code'] != 200 ||
      !body.containsKey('meta') ||
      (body.containsKey('error') && body['error'] != false)) {
    _invalid();
  }
  final message = body['message'];
  if (message is! String || trimAuthInput(message).isEmpty) _invalid();
  if (body['meta'] != null) {
    final meta = _record(body['meta']);
    if (meta['has_next'] != null && meta['has_next'] is! bool) _invalid();
  }
  _record(body['data']);
}

class V2UserSettings {
  V2UserSettings({
    required this.userId,
    this.twoFactorEnabled = false,
    required this.loginAlerts,
    required this.profileVisibility,
    this.showOnlineStatus = false,
    this.allowDmFromStrangers = false,
    this.pushNotificationEnabled = false,
    this.emailNotificationEnabled = false,
    this.aiSentimentEnabled = false,
    this.aiSentimentModelId,
    this.aiSentimentReturnProbabilities = true,
    this.aiSentimentIncludeMetadata = false,
    this.aiSentimentTopK = 3,
    required this.updatedAt,
  });
  final int userId;
  final bool twoFactorEnabled,
      loginAlerts,
      showOnlineStatus,
      allowDmFromStrangers,
      pushNotificationEnabled,
      emailNotificationEnabled,
      aiSentimentEnabled,
      aiSentimentReturnProbabilities,
      aiSentimentIncludeMetadata;
  final String profileVisibility, updatedAt;
  final String? aiSentimentModelId;
  final int aiSentimentTopK;
  factory V2UserSettings.fromJson(Object? value) {
    final data = _record(value),
        id = data['user_id'],
        top = data['ai_sentiment_top_k'],
        model = data['ai_sentiment_model_id'];
    if (id is! num ||
        !id.isFinite ||
        id <= 0 ||
        id > 9007199254740991 ||
        id != id.toInt() ||
        top is! num ||
        !top.isFinite ||
        top < 1 ||
        top > 10 ||
        top != top.toInt()) {
      _invalid();
    }
    if (!data.containsKey('ai_sentiment_model_id') ||
        (model != null && model is! String)) {
      _invalid();
    }
    return V2UserSettings(
      userId: id.toInt(),
      twoFactorEnabled: _boolean(data, 'two_factor_enabled'),
      loginAlerts: _boolean(data, 'login_alerts'),
      profileVisibility: _string(data, 'profile_visibility'),
      showOnlineStatus: _boolean(data, 'show_online_status'),
      allowDmFromStrangers: _boolean(data, 'allow_dm_from_strangers'),
      pushNotificationEnabled: _boolean(data, 'push_notification_enabled'),
      emailNotificationEnabled: _boolean(data, 'email_notification_enabled'),
      aiSentimentEnabled: _boolean(data, 'ai_sentiment_enabled'),
      aiSentimentModelId: model as String?,
      aiSentimentReturnProbabilities: _boolean(
        data,
        'ai_sentiment_return_probabilities',
      ),
      aiSentimentIncludeMetadata: _boolean(
        data,
        'ai_sentiment_include_metadata',
      ),
      aiSentimentTopK: top.toInt(),
      updatedAt: _string(data, 'updated_at'),
    );
  }
}

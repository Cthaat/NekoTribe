import '../../../core/auth/token_pair.dart';

Never _invalid() =>
    throw const FormatException('Invalid email change response');

Map<String, dynamic> _record(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

String _text(Object? value) {
  if (value is! String || value.trim().isEmpty) _invalid();
  return value;
}

void validateEmailChangeEnvelope(Object? value) {
  final body = _record(value);
  if (body['code'] is! num ||
      body['code'] != 200 ||
      body['error'] == true ||
      !body.containsKey('meta')) {
    _invalid();
  }
  _text(body['message']);
  if (body['meta'] != null) {
    final meta = _record(body['meta']);
    if (meta['has_next'] != null && meta['has_next'] is! bool) _invalid();
  }
}

class V2EmailChangeData {
  const V2EmailChangeData({required this.email, required this.verifiedAt});
  final String email;
  final String verifiedAt;

  factory V2EmailChangeData.fromJson(
    Object? value, {
    required String expectedEmail,
  }) {
    final data = _record(value);
    final email = _text(data['email']);
    if (email != expectedEmail.trim()) _invalid();
    final at = _text(data['email_verified_at']);
    try {
      parseSessionExpiry(at);
    } catch (_) {
      _invalid();
    }
    return V2EmailChangeData(email: email, verifiedAt: at);
  }
}

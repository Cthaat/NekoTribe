import '../../../core/utils/auth_input.dart';

Never _invalid() =>
    throw const FormatException('Invalid security action response');
Map<String, dynamic> _record(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

String _text(Object? value) {
  if (value is! String || trimAuthInput(value).isEmpty) _invalid();
  return value;
}

void validateSecurityActionEnvelope(Object? value) {
  final body = _record(value);
  if (body['code'] is! num ||
      body['code'] != 200 ||
      !body.containsKey('meta') ||
      (body.containsKey('error') && body['error'] != false)) {
    _invalid();
  }
  _text(body['message']);
  if (body['meta'] != null) {
    final meta = _record(body['meta']);
    if (meta['has_next'] != null && meta['has_next'] is! bool) _invalid();
  }
  _record(body['data']);
}

String _factorUri(Object? value, String secret) {
  final uri = _text(value);
  if (RegExp(r'[^\x21-\x7e]|\\').hasMatch(uri)) _invalid();
  final match = RegExp(r'^otpauth://totp/([^/?#]+)\?([^#]*)$').firstMatch(uri);
  if (match == null) _invalid();
  try {
    final label = Uri.decodeComponent(match.group(1)!);
    if (!label.startsWith('NekoTribe:') ||
        trimAuthInput(label.substring('NekoTribe:'.length)).isEmpty) {
      _invalid();
    }
    final parameters = <String, List<String>>{};
    for (final item in match.group(2)!.split('&')) {
      final separator = item.indexOf('=');
      if (separator < 0) _invalid();
      final key = Uri.decodeQueryComponent(item.substring(0, separator));
      final value = Uri.decodeQueryComponent(item.substring(separator + 1));
      parameters.putIfAbsent(key, () => []).add(value);
    }
    for (final entry in {
      'secret': secret,
      'issuer': 'NekoTribe',
      'algorithm': 'SHA1',
      'digits': '6',
      'period': '30',
    }.entries) {
      final actual = parameters[entry.key];
      if (actual == null ||
          actual.length != 1 ||
          actual.single != entry.value) {
        _invalid();
      }
    }
  } catch (_) {
    _invalid();
  }
  return uri;
}

class V2TwoFactorSetupData {
  const V2TwoFactorSetupData._(this.secret, this.otpauthUrl);
  final String secret;
  final String otpauthUrl;
  factory V2TwoFactorSetupData.fromJson(Object? value) {
    final data = _record(value);
    final secret = _text(data['secret']);
    if (secret.length != 32 || !RegExp(r'^[A-Z2-7]{32}$').hasMatch(secret)) {
      _invalid();
    }
    return V2TwoFactorSetupData._(
      secret,
      _factorUri(data['otpauth_url'], secret),
    );
  }
}

class V2TwoFactorConfirmData {
  V2TwoFactorConfirmData._(this.recoveryCodes);
  bool get enabled => true;
  final List<String> recoveryCodes;
  factory V2TwoFactorConfirmData.fromJson(Object? value) {
    final data = _record(value);
    final codes = data['recovery_codes'];
    if (data['enabled'] != true || codes is! List || codes.length != 10) {
      _invalid();
    }
    final decoded = codes.map((Object? code) {
      if (code is! String ||
          code.length != 17 ||
          !RegExp(r'^[A-Z2-7]{5}-[A-Z2-7]{5}-[A-Z2-7]{5}$').hasMatch(code)) {
        _invalid();
      }
      return code;
    });
    return V2TwoFactorConfirmData._(List.unmodifiable(decoded));
  }
}

class V2TwoFactorDisabledData {
  const V2TwoFactorDisabledData._();
  bool get enabled => false;
  factory V2TwoFactorDisabledData.fromJson(Object? value) {
    if (_record(value)['enabled'] != false) _invalid();
    return const V2TwoFactorDisabledData._();
  }
}

class V2AccountDeletionData {
  const V2AccountDeletionData._(this.userId);
  bool get deleted => true;
  final int userId;
  factory V2AccountDeletionData.fromJson(Object? value) {
    final data = _record(value);
    final id = data['user_id'];
    if (data['deleted'] != true ||
        id is! num ||
        !id.isFinite ||
        id <= 0 ||
        id > 9007199254740991 ||
        id != id.toInt()) {
      _invalid();
    }
    return V2AccountDeletionData._(id.toInt());
  }
}

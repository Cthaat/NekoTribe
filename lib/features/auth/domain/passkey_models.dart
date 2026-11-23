import '../../../core/utils/json_utils.dart';

typedef PasskeyPrompt =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> options);

class PasskeyChallenge {
  const PasskeyChallenge(this.id, this.options);

  factory PasskeyChallenge.fromJson(Map<String, dynamic> json) {
    final id = json['challenge_id'];
    final options = toMap(json['options']);
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(id) ||
        options['challenge'] is! String) {
      throw const FormatException('Invalid Passkey challenge');
    }
    return PasskeyChallenge(id, options);
  }

  final String id;
  final Map<String, dynamic> options;
}

class PasskeyCredential {
  const PasskeyCredential({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.lastUsedAt,
  });

  factory PasskeyCredential.fromJson(Map<String, dynamic> json) {
    final id = json['credential_id'];
    final label = json['label'];
    final createdAt = toDateTime(json['created_at']);
    final rawLastUsedAt = json['last_used_at'];
    final lastUsedAt = toDateTime(rawLastUsedAt);
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,1364}$').hasMatch(id) ||
        label is! String ||
        createdAt == null ||
        (rawLastUsedAt != null && lastUsedAt == null)) {
      throw const FormatException('Invalid Passkey credential');
    }
    return PasskeyCredential(
      id: id,
      label: label,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt,
    );
  }

  final String id;
  final String label;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
}

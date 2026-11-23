import '../../../core/utils/json_utils.dart';

final _flowValue = RegExp(r'^[A-Za-z0-9_-]{43}$');

class GitHubOAuthFlow {
  const GitHubOAuthFlow._(this.id, this.key, this.authorizationUrl);

  factory GitHubOAuthFlow.fromJson(Map<String, dynamic> json) {
    final id = json['flow_id'];
    final key = json['flow_key'];
    final rawUrl = json['authorization_url'];
    final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (id is! String ||
        !_flowValue.hasMatch(id) ||
        key is! String ||
        !_flowValue.hasMatch(key) ||
        id == key ||
        json['expires_in'] != 300 ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.port != 443 ||
        url.userInfo.isNotEmpty ||
        url.path != '/login/oauth/authorize' ||
        url.hasFragment ||
        Uri.decodeComponent(rawUrl as String).contains(key) ||
        url.queryParametersAll.containsKey('flow_key')) {
      throw const FormatException('Invalid GitHub OAuth flow');
    }
    return GitHubOAuthFlow._(id, key, url);
  }

  final String id;
  final String key;
  final Uri authorizationUrl;
  static const duration = Duration(minutes: 5);
}

class GitHubLink {
  const GitHubLink(this.id, this.login, this.linkedAt);

  factory GitHubLink.fromJson(Map<String, dynamic> json) {
    final id = json['github_user_id'];
    final login = json['github_login'];
    final linkedAt = toDateTime(json['linked_at']);
    if (id is! String ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(id) ||
        login is! String ||
        login.isEmpty ||
        linkedAt == null) {
      throw const FormatException('Invalid GitHub link');
    }
    return GitHubLink(id, login, linkedAt);
  }

  final String id;
  final String login;
  final DateTime linkedAt;
}

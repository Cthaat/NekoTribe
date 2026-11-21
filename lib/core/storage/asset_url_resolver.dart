import '../config/app_config.dart';

class AssetUrlResolver {
  AssetUrlResolver(this.config);

  final AppConfig config;

  static const String defaultAvatarPath = '/storage/default-avatar.png';

  String resolve(String? url) {
    if (url == null || url.trim().isEmpty) {
      return _join(config.storageBaseUrl, defaultAvatarPath);
    }
    final trimmed = url.trim();
    if (trimmed == '/default-avatar.png' || trimmed == 'default-avatar.png') {
      return _join(config.storageBaseUrl, defaultAvatarPath);
    }
    if (_absoluteHttp.hasMatch(trimmed) || trimmed.startsWith('/api/')) {
      return trimmed;
    }
    final path = trimmed.replaceFirst(_legacyStorage, '/storage/');
    return _join(config.storageBaseUrl, path);
  }

  static final _absoluteHttp = RegExp(r'^https?://', caseSensitive: false);
  static final _legacyStorage = RegExp(r'^/uploads?/+');

  String _join(String base, String path) {
    if (base.endsWith('/') && path.startsWith('/')) {
      return base.substring(0, base.length - 1) + path;
    }
    if (!base.endsWith('/') && !path.startsWith('/')) {
      return '$base/$path';
    }
    return '$base$path';
  }
}

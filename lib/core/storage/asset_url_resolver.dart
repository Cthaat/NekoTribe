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
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      // 完整 URL：可能需要把 /uploads 或 /upload 替换为 /storage
      try {
        final uri = Uri.parse(trimmed);
        final newPath = _convertLegacyPath(uri.path);
        if (newPath != uri.path) {
          return uri.replace(path: newPath).toString();
        }
        return trimmed;
      } catch (_) {
        return trimmed;
      }
    }
    if (trimmed.startsWith('/storage/')) {
      return _join(config.storageBaseUrl, trimmed);
    }
    if (trimmed.startsWith('/uploads/') || trimmed.startsWith('/upload/')) {
      return _join(config.storageBaseUrl, _convertLegacyPath(trimmed));
    }
    if (trimmed.startsWith('/')) {
      return _join(config.storageBaseUrl, trimmed);
    }
    return _join(config.storageBaseUrl, '/$trimmed');
  }

  String _convertLegacyPath(String path) {
    if (path.startsWith('/uploads/')) {
      return '/storage/${path.substring('/uploads/'.length)}';
    }
    if (path.startsWith('/upload/')) {
      return '/storage/${path.substring('/upload/'.length)}';
    }
    return path;
  }

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

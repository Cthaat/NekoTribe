import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/storage_keys.dart';
import 'app_config_asset.dart'
    if (dart.library.js_interop) 'app_config_asset_web.dart';

class BrowserEndpointTransportException implements Exception {
  const BrowserEndpointTransportException();
}

Uri? get currentBrowserPage => kIsWeb ? Uri.base : null;

bool hasMixedEndpointTransport(AppConfig config, Uri? browserPage) {
  if (browserPage?.scheme != 'https') return false;
  return [config.apiBaseUrl, config.wsBaseUrl, config.storageBaseUrl].any((
    address,
  ) {
    final endpoint = Uri.tryParse(address);
    if (endpoint == null ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'ws')) {
      return false;
    }
    final host = endpoint.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host == 'localhost' || host.endsWith('.localhost')) return false;
    if (host == '::1' || host == '0:0:0:0:0:0:0:1') return false;
    final ipv4 = host.split('.');
    return ipv4.length != 4 ||
        ipv4.first != '127' ||
        !ipv4.every((byte) {
          final value = int.tryParse(byte);
          return RegExp(r'^\d{1,3}$').hasMatch(byte) &&
              value != null &&
              value <= 255;
        });
  });
}

/// 一个端点预设（一组完整的 API / WS / Storage 基址）。
class EndpointPreset {
  const EndpointPreset({
    required this.id,
    required this.label,
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.storageBaseUrl,
    this.description,
  });

  final String id;
  final String label;
  final String? description;
  final String apiBaseUrl;
  final String wsBaseUrl;
  final String storageBaseUrl;

  static EndpointPreset fromJson(Map<String, dynamic> json) {
    final endpoints = AppConfig.fromJson(json);
    return EndpointPreset(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? (json['id'] as String?) ?? '',
      description: json['description'] as String?,
      apiBaseUrl: endpoints.apiBaseUrl,
      wsBaseUrl: endpoints.wsBaseUrl,
      storageBaseUrl: endpoints.storageBaseUrl,
    );
  }
}

/// 从 `assets/config/app_config.json` 加载得到的不可变包，
/// 包含默认值（首次启动 fallback）和预置端点列表。
class AppConfigBundle {
  const AppConfigBundle({
    required this.defaults,
    required this.presets,
    this.groupPostShareBaseUrl = '',
  });

  final AppConfig defaults;
  final List<EndpointPreset> presets;
  final String groupPostShareBaseUrl;

  static AppConfigBundle fromJson(Map<String, dynamic> json) {
    final defaultsJson = (json['defaults'] as Map<String, dynamic>?) ?? {};
    final defaults = AppConfig.fromJson(defaultsJson);
    final raw = (json['presets'] as List?) ?? const [];
    final presets = raw
        .whereType<Map<String, dynamic>>()
        .map(EndpointPreset.fromJson)
        .toList(growable: false);
    final shareBase = json['groupPostShareBaseUrl'];
    return AppConfigBundle(
      defaults: defaults.presetId == null
          ? defaults.copyWith(presetId: '')
          : defaults,
      presets: presets,
      groupPostShareBaseUrl: shareBase is String ? shareBase : '',
    );
  }
}

/// 运行时使用的端点配置。所有网络层组件（ApiClient / RealtimeService /
/// AssetUrlResolver）都依赖此对象，切换 baseurl 即可整体重建。
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.storageBaseUrl,
    this.presetId,
  });

  factory AppConfig.fromOrigin(String address) {
    final origin = _parseBase(address, const {'http', 'https'});
    if (origin.path.isNotEmpty && origin.path != '/') {
      throw const FormatException('Expected an HTTP or HTTPS origin');
    }
    return _sharedBase(origin);
  }

  factory AppConfig.fromCustom({
    required String apiBaseUrl,
    String wsBaseUrl = '',
    String storageBaseUrl = '',
  }) {
    final api = _parseBase(apiBaseUrl, const {'http', 'https'});
    final shared = _sharedBase(api);
    return shared.copyWith(
      wsBaseUrl: wsBaseUrl.trim().isEmpty
          ? null
          : _baseWithoutTrailingSlashes(
              _parseBase(wsBaseUrl, const {'ws', 'wss'}),
            ),
      storageBaseUrl: storageBaseUrl.trim().isEmpty
          ? null
          : _baseWithoutTrailingSlashes(
              _parseBase(storageBaseUrl, const {'http', 'https'}),
            ),
    );
  }

  static Uri _parseBase(String address, Set<String> schemes) {
    final value = address.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !schemes.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(value) ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException('Invalid backend base URL');
    }
    return uri;
  }

  static String _baseWithoutTrailingSlashes(Uri uri) =>
      uri.toString().replaceFirst(RegExp(r'/+$'), '');

  static AppConfig _sharedBase(Uri api) {
    final base = _baseWithoutTrailingSlashes(api);
    final websocketScheme = api.scheme == 'https' ? 'wss' : 'ws';
    return AppConfig(
      presetId: 'custom',
      apiBaseUrl: base,
      wsBaseUrl: _baseWithoutTrailingSlashes(
        api.replace(scheme: websocketScheme),
      ),
      storageBaseUrl: base,
    );
  }

  /// 当前选中的预设 id；若为 `null` 或 `custom` 表示用户输入的自定义端点。
  final String? presetId;
  final String apiBaseUrl;
  final String wsBaseUrl;
  final String storageBaseUrl;

  bool get isCustom => presetId == null || presetId == 'custom';

  AppConfig copyWith({
    String? apiBaseUrl,
    String? wsBaseUrl,
    String? storageBaseUrl,
    String? presetId,
    bool clearPresetId = false,
  }) {
    return AppConfig(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      wsBaseUrl: wsBaseUrl ?? this.wsBaseUrl,
      storageBaseUrl: storageBaseUrl ?? this.storageBaseUrl,
      presetId: clearPresetId ? null : (presetId ?? this.presetId),
    );
  }

  Map<String, dynamic> toJson() => {
    'presetId': presetId,
    'apiBaseUrl': apiBaseUrl,
    'wsBaseUrl': wsBaseUrl,
    'storageBaseUrl': storageBaseUrl,
  };

  static AppConfig fromJson(Map<String, dynamic> json) {
    final config = AppConfig(
      apiBaseUrl: (json['apiBaseUrl'] as String?) ?? '',
      wsBaseUrl: (json['wsBaseUrl'] as String?) ?? '',
      storageBaseUrl: (json['storageBaseUrl'] as String?) ?? '',
      presetId: json['presetId'] as String?,
    );
    final missingRealtime = config.wsBaseUrl.trim().isEmpty;
    final missingStorage = config.storageBaseUrl.trim().isEmpty;
    if (config.apiBaseUrl.trim().isEmpty ||
        (!missingRealtime && !missingStorage)) {
      return config;
    }
    try {
      final shared = AppConfig.fromCustom(apiBaseUrl: config.apiBaseUrl);
      return config.copyWith(
        apiBaseUrl: shared.apiBaseUrl,
        wsBaseUrl: missingRealtime ? shared.wsBaseUrl : null,
        storageBaseUrl: missingStorage ? shared.storageBaseUrl : null,
      );
    } on FormatException {
      // Keep the configured values available for manual correction.
      return config;
    }
  }
}

/// 启动加载 + 运行时持久化：
/// 1. 读取 `assets/config/app_config.json`
/// 2. 读取 SharedPreferences 中是否存在用户覆盖
/// 3. 合并得到当前 AppConfig
class AppConfigLoader {
  AppConfigLoader._();

  static const String assetPath = 'assets/config/app_config.json';

  /// 编译期 `--dart-define` 默认值；用户持久化设置仍拥有更高优先级。
  static const String _envApi = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
  static const String _envWs = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: '',
  );
  static const String _envStorage = String.fromEnvironment(
    'STORAGE_BASE_URL',
    defaultValue: '',
  );

  static Future<AppConfigBundle> loadBundle() async {
    try {
      final raw = await loadAppConfigAsset(assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppConfigBundle.fromJson(decoded);
      }
    } catch (_) {
      // ignore — fall through to safe defaults
    }
    return const AppConfigBundle(
      defaults: AppConfig(apiBaseUrl: '', wsBaseUrl: '', storageBaseUrl: ''),
      presets: [],
    );
  }

  /// 计算应用启动时使用的初始 AppConfig（优先级：
  /// SharedPreferences override → --dart-define → bundle.defaults）。
  static Future<AppConfig> initialConfig(AppConfigBundle bundle) async {
    return await readOverride() ?? buildDefaults(bundle);
  }

  static AppConfig buildDefaults(AppConfigBundle bundle) {
    if (_envApi.isNotEmpty || _envWs.isNotEmpty || _envStorage.isNotEmpty) {
      AppConfig? derived;
      if (_envApi.isNotEmpty) {
        try {
          derived = AppConfig.fromCustom(apiBaseUrl: _envApi);
        } on FormatException {
          // Preserve independently configured bases for an invalid API override.
        }
      }
      return AppConfig(
        apiBaseUrl: _envApi.isNotEmpty
            ? (derived?.apiBaseUrl ?? _envApi)
            : bundle.defaults.apiBaseUrl,
        wsBaseUrl: _envWs.isNotEmpty
            ? _envWs
            : (derived?.wsBaseUrl ?? bundle.defaults.wsBaseUrl),
        storageBaseUrl: _envStorage.isNotEmpty
            ? _envStorage
            : (derived?.storageBaseUrl ?? bundle.defaults.storageBaseUrl),
        presetId: 'custom',
      );
    }
    return bundle.defaults;
  }

  static Future<AppConfig?> readOverride() async {
    final prefs = await SharedPreferences.getInstance();
    // A failed setString or remove can still change the legacy in-memory cache.
    await prefs.reload();
    final raw = prefs.getString(StorageKeys.endpointOverride);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final presetId = decoded['presetId'] as String?;
        return AppConfig.fromCustom(
          apiBaseUrl: (decoded['apiBaseUrl'] as String?) ?? '',
          wsBaseUrl: (decoded['wsBaseUrl'] as String?) ?? '',
          storageBaseUrl: (decoded['storageBaseUrl'] as String?) ?? '',
        ).copyWith(presetId: presetId, clearPresetId: presetId == null);
      }
    } catch (_) {}
    return null;
  }

  static Future<void> writeOverride(AppConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      StorageKeys.endpointOverride,
      jsonEncode(config.toJson()),
    );
    if (!saved) throw StateError('Endpoint settings were not saved');
  }

  static Future<void> clearOverride() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(StorageKeys.endpointOverride)) {
      throw StateError('Endpoint settings were not cleared');
    }
  }
}

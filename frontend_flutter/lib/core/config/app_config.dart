import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/storage_keys.dart';

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
    return EndpointPreset(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? (json['id'] as String?) ?? '',
      description: json['description'] as String?,
      apiBaseUrl: (json['apiBaseUrl'] as String?) ?? '',
      wsBaseUrl: (json['wsBaseUrl'] as String?) ?? '',
      storageBaseUrl: (json['storageBaseUrl'] as String?) ?? '',
    );
  }
}

/// 从 `assets/config/app_config.json` 加载得到的不可变包，
/// 包含默认值（首次启动 fallback）和预置端点列表。
class AppConfigBundle {
  const AppConfigBundle({
    required this.defaults,
    required this.presets,
  });

  final AppConfig defaults;
  final List<EndpointPreset> presets;

  static AppConfigBundle fromJson(Map<String, dynamic> json) {
    final defaultsJson = (json['defaults'] as Map<String, dynamic>?) ?? {};
    final defaults = AppConfig(
      presetId: (defaultsJson['presetId'] as String?) ?? '',
      apiBaseUrl: (defaultsJson['apiBaseUrl'] as String?) ?? '',
      wsBaseUrl: (defaultsJson['wsBaseUrl'] as String?) ?? '',
      storageBaseUrl: (defaultsJson['storageBaseUrl'] as String?) ?? '',
    );
    final raw = (json['presets'] as List?) ?? const [];
    final presets = raw
        .whereType<Map<String, dynamic>>()
        .map(EndpointPreset.fromJson)
        .toList(growable: false);
    return AppConfigBundle(defaults: defaults, presets: presets);
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
    return AppConfig(
      apiBaseUrl: (json['apiBaseUrl'] as String?) ?? '',
      wsBaseUrl: (json['wsBaseUrl'] as String?) ?? '',
      storageBaseUrl: (json['storageBaseUrl'] as String?) ?? '',
      presetId: json['presetId'] as String?,
    );
  }
}

/// 启动加载 + 运行时持久化：
/// 1. 读取 `assets/config/app_config.json`
/// 2. 读取 SharedPreferences 中是否存在用户覆盖
/// 3. 合并得到当前 AppConfig
class AppConfigLoader {
  AppConfigLoader._();

  static const String assetPath = 'assets/config/app_config.json';

  /// 编译期 `--dart-define` 覆盖，依然支持作为最高优先级（CI 部署用）。
  static const String _envApi =
      String.fromEnvironment('API_BASE_URL', defaultValue: '');
  static const String _envWs =
      String.fromEnvironment('WS_BASE_URL', defaultValue: '');
  static const String _envStorage =
      String.fromEnvironment('STORAGE_BASE_URL', defaultValue: '');

  static Future<AppConfigBundle> loadBundle() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppConfigBundle.fromJson(decoded);
      }
    } catch (_) {
      // ignore — fall through to safe defaults
    }
    return const AppConfigBundle(
      defaults: AppConfig(
        apiBaseUrl: '',
        wsBaseUrl: '',
        storageBaseUrl: '',
      ),
      presets: [],
    );
  }

  /// 计算应用启动时使用的初始 AppConfig（优先级：
  /// SharedPreferences override → --dart-define → bundle.defaults）。
  static Future<AppConfig> initialConfig(AppConfigBundle bundle) async {
    final override = await readOverride();
    if (override != null) return override;
    if (_envApi.isNotEmpty || _envWs.isNotEmpty || _envStorage.isNotEmpty) {
      return AppConfig(
        apiBaseUrl: _envApi.isNotEmpty ? _envApi : bundle.defaults.apiBaseUrl,
        wsBaseUrl: _envWs.isNotEmpty ? _envWs : bundle.defaults.wsBaseUrl,
        storageBaseUrl: _envStorage.isNotEmpty
            ? _envStorage
            : bundle.defaults.storageBaseUrl,
        presetId: 'custom',
      );
    }
    return bundle.defaults;
  }

  static Future<AppConfig?> readOverride() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.endpointOverride);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final cfg = AppConfig.fromJson(decoded);
        if (cfg.apiBaseUrl.isEmpty &&
            cfg.wsBaseUrl.isEmpty &&
            cfg.storageBaseUrl.isEmpty) {
          return null;
        }
        return cfg;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> writeOverride(AppConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      StorageKeys.endpointOverride,
      jsonEncode(config.toJson()),
    );
  }

  static Future<void> clearOverride() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.endpointOverride);
  }
}

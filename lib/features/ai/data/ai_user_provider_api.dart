import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';

enum AiProviderPresetId {
  defaultService('default'),
  provided('provided');

  const AiProviderPresetId(this.id);

  final String id;

  static AiProviderPresetId? parse(Object? value) => switch (value) {
    'default' => defaultService,
    'provided' => provided,
    _ => null,
  };
}

typedef AiProviderPreset = ({AiProviderPresetId id, String baseUrl});
typedef AiUserProviderConfig = ({
  AiProviderPresetId preset,
  String model,
  bool enabled,
  bool keyConfigured,
  int revision,
  bool reconnectRequired,
});
typedef AiUserProviderSettings = ({
  bool setupAvailable,
  List<AiProviderPreset> presets,
  AiUserProviderConfig? config,
});

class AiUserProviderApi {
  AiUserProviderApi(this._client);

  final ApiClient _client;
  static final _model = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$');

  static bool validModel(String model) => _model.stringMatch(model) == model;

  static bool validKey(String key) =>
      key.isNotEmpty &&
      key.length <= 512 &&
      key.codeUnits.every(
        (character) => character >= 0x21 && character <= 0x7e,
      );

  Future<AiUserProviderSettings> getSettings(CancelToken cancel) =>
      _client.requestData(
        ApiPaths.usersMeAiProvider,
        cancelToken: cancel,
        decode: _readSettings,
      );

  Future<AiUserProviderSettings> saveSettings({
    required AiProviderPresetId preset,
    required String model,
    required bool enabled,
    required CancelToken cancel,
    String? apiKey,
  }) async {
    if (!validModel(model) || (apiKey != null && !validKey(apiKey))) {
      throw const FormatException('Invalid personal AI connection');
    }
    final settings = await _client.requestData(
      ApiPaths.usersMeAiProvider,
      method: 'PUT',
      data: {
        'preset': preset.id,
        'model': model,
        'enabled': enabled,
        if (apiKey != null) 'api_key': apiKey,
      },
      cancelToken: cancel,
      decode: _readSettings,
    );
    final config = settings.config;
    if (config == null ||
        !config.keyConfigured ||
        config.preset != preset ||
        config.model != model ||
        config.enabled != enabled) {
      throw const FormatException('Invalid personal AI connection receipt');
    }
    return settings;
  }

  Future<void> testConnection(CancelToken cancel) async {
    await _client.request<void>(
      '${ApiPaths.usersMeAiProvider}/test',
      method: 'POST',
      cancelToken: cancel,
      decode: (data) {
        if (data is! Map<String, dynamic> ||
            data.length != 1 ||
            data['verified'] != true) {
          throw const FormatException('Invalid personal AI test receipt');
        }
      },
    );
  }

  Future<void> removeConnection(CancelToken cancel) async {
    await _client.request<void>(
      ApiPaths.usersMeAiProvider,
      method: 'DELETE',
      cancelToken: cancel,
      decode: (data) {
        if (data != null) {
          throw const FormatException('Invalid personal AI removal receipt');
        }
      },
    );
  }
}

AiUserProviderSettings _readSettings(Object? raw) {
  const invalid = FormatException('Invalid personal AI settings');
  if (raw is! Map<String, dynamic> ||
      raw.length != 3 ||
      !raw.containsKey('config')) {
    throw invalid;
  }
  final available = raw['setup_available'];
  final rows = raw['presets'];
  if (available is! bool || rows is! List || rows.isEmpty || rows.length > 2) {
    throw invalid;
  }
  final presets = <AiProviderPreset>[];
  final ids = <AiProviderPresetId>{};
  for (final row in rows) {
    if (row is! Map<String, dynamic> || row.length != 2) throw invalid;
    final id = AiProviderPresetId.parse(row['id']);
    final baseUrl = row['base_url'];
    if (id == null ||
        !ids.add(id) ||
        baseUrl is! String ||
        !_validBaseUrl(baseUrl)) {
      throw invalid;
    }
    presets.add((id: id, baseUrl: baseUrl));
  }
  if (!ids.contains(AiProviderPresetId.defaultService)) throw invalid;
  return (
    setupAvailable: available,
    presets: List.unmodifiable(presets),
    config: _readConfig(raw['config']),
  );
}

bool _validBaseUrl(String value) {
  if (value.length > 500 || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(value)) {
    return false;
  }
  final url = Uri.tryParse(value);
  return url != null &&
      (url.scheme == 'https' || url.scheme == 'http') &&
      url.host.isNotEmpty &&
      !url.authority.contains('@') &&
      !url.hasQuery &&
      !url.hasFragment;
}

AiUserProviderConfig? _readConfig(Object? raw) {
  if (raw == null) return null;
  const invalid = FormatException('Invalid personal AI configuration');
  if (raw is! Map<String, dynamic> || raw.length != 6) throw invalid;
  final preset = AiProviderPresetId.parse(raw['preset']);
  final model = raw['model'];
  final enabled = raw['enabled'];
  final keyConfigured = raw['key_configured'];
  final revision = raw['revision'];
  final reconnect = raw['reconnect_required'];
  if (preset == null ||
      model is! String ||
      !AiUserProviderApi.validModel(model) ||
      enabled is! bool ||
      keyConfigured is! bool ||
      reconnect is! bool ||
      revision is! int ||
      revision < 1 ||
      revision > 999999999999999) {
    throw invalid;
  }
  return (
    preset: preset,
    model: model,
    enabled: enabled,
    keyConfigured: keyConfigured,
    revision: revision,
    reconnectRequired: reconnect,
  );
}

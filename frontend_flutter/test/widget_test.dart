import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';

void main() {
  test('AppLocalizations exposes localized strings', () {
    final zh = AppLocalizations(const Locale('zh'));
    final en = AppLocalizations(const Locale('en'));
    expect(zh.t('app.title'), 'NekoTribe');
    expect(en.t('app.title'), 'NekoTribe');
    expect(zh.t('common.settings'), '设置');
    expect(en.t('common.settings'), 'Settings');
  });

  test('AppLocalizations falls back to key when missing', () {
    final loc = AppLocalizations(const Locale('zh'));
    expect(loc.t('non.existent.key'), 'non.existent.key');
  });

  test('AppConfigBundle.fromJson parses defaults + presets', () {
    final bundle = AppConfigBundle.fromJson({
      'defaults': {
        'presetId': 'entry',
        'apiBaseUrl': 'http://localhost:30001',
        'wsBaseUrl': 'ws://localhost:30001',
        'storageBaseUrl': 'http://localhost:30001',
      },
      'presets': [
        {
          'id': 'entry',
          'label': 'Entry',
          'apiBaseUrl': 'http://localhost:30001',
          'wsBaseUrl': 'ws://localhost:30001',
          'storageBaseUrl': 'http://localhost:30001',
        },
        {
          'id': 'rust-direct',
          'label': 'Rust Direct',
          'apiBaseUrl': 'http://localhost:30003',
          'wsBaseUrl': 'ws://localhost:30003',
          'storageBaseUrl': 'http://localhost:30003',
        },
      ],
    });
    expect(bundle.presets.length, 2);
    expect(bundle.defaults.apiBaseUrl, 'http://localhost:30001');
    expect(bundle.presets[1].apiBaseUrl, 'http://localhost:30003');
  });

  test('AppConfig.copyWith preserves and overrides fields', () {
    const cfg = AppConfig(
      presetId: 'entry',
      apiBaseUrl: 'http://a',
      wsBaseUrl: 'ws://a',
      storageBaseUrl: 'http://a/s',
    );
    final next = cfg.copyWith(apiBaseUrl: 'http://b');
    expect(next.apiBaseUrl, 'http://b');
    expect(next.wsBaseUrl, 'ws://a');
    expect(next.storageBaseUrl, 'http://a/s');
    expect(next.presetId, 'entry');
    final custom = cfg.copyWith(presetId: 'custom');
    expect(custom.presetId, 'custom');
    expect(custom.isCustom, isTrue);
  });

  test('AppConfig roundtrips via toJson/fromJson', () {
    const cfg = AppConfig(
      presetId: 'custom',
      apiBaseUrl: 'http://x:1',
      wsBaseUrl: 'ws://x:1',
      storageBaseUrl: 'http://x:1',
    );
    final restored = AppConfig.fromJson(cfg.toJson());
    expect(restored.apiBaseUrl, cfg.apiBaseUrl);
    expect(restored.wsBaseUrl, cfg.wsBaseUrl);
    expect(restored.storageBaseUrl, cfg.storageBaseUrl);
    expect(restored.presetId, cfg.presetId);
  });
}

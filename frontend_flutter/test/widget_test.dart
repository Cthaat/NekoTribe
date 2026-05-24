import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/constants/storage_keys.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/theme/app_theme.dart';

void main() {
  test('AppLocalizations exposes localized strings', () {
    final zh = AppLocalizations(const Locale('zh'));
    final en = AppLocalizations(const Locale('en'));
    expect(zh.t('app.title'), 'NekoTribe');
    expect(en.t('app.title'), 'NekoTribe');
    expect(zh.t('common.settings'), '设置');
    expect(en.t('common.settings'), 'Settings');
  });

  test('AppLocalizations covers visible Flutter shell and settings copy', () {
    final zh = AppLocalizations(const Locale('zh'));
    final en = AppLocalizations(const Locale('en'));

    expect(zh.t('feed.tab.home'), '首页');
    expect(zh.t('feed.tab.discover'), '发现');
    expect(zh.t('feed.tab.following'), '关注');
    expect(zh.t('settings.section.appearance'), '外观');
    expect(zh.t('settings.appearance.workspace'), '外观工作台');
    expect(zh.t('settings.account.my_posts'), '我的推文');
    expect(zh.t('settings.account.liked_posts'), '已点赞推文');
    expect(zh.t('settings.option.system'), '跟随系统');
    expect(zh.t('post.delete.title'), '删除推文');
    expect(zh.t('window.minimize'), '最小化');
    expect(zh.t('window.maximize'), '最大化');
    expect(zh.t('window.restore'), '还原');
    expect(zh.t('window.close'), '关闭');

    expect(en.t('feed.tab.home'), 'Home');
    expect(en.t('settings.section.appearance'), 'Appearance');
    expect(en.t('settings.account.my_posts'), 'My posts');
    expect(en.t('settings.option.system'), 'System');
    expect(en.t('post.delete.title'), 'Delete post');
    expect(en.t('window.minimize'), 'Minimize');
    expect(en.t('window.maximize'), 'Maximize');
    expect(en.t('window.restore'), 'Restore');
    expect(en.t('window.close'), 'Close');
  });

  test(
    'AppLocalizations covers account, group, auth, and notification copy',
    () {
      final zh = AppLocalizations(const Locale('zh'));
      final en = AppLocalizations(const Locale('en'));
      const keys = [
        'auth.otp_sent',
        'auth.remember_me',
        'profile.saved',
        'profile.message',
        'notification.filter.all_types',
        'notification.mark_all_read',
        'chat.direct',
        'chat.no_channels',
        'group.create_title',
        'group.manage',
        'group.no_posts',
        'discover.trending_tags',
        'account.sessions.title',
        'account.security.setup_2fa',
        'account.statements.submit_appeal',
        'terms.title',
        'about.title',
        'pro.view_billing',
      ];

      for (final key in keys) {
        expect(zh.t(key), isNot(key), reason: 'missing zh key: $key');
        expect(en.t(key), isNot(key), reason: 'missing en key: $key');
      }
    },
  );

  test('theme preferences persist mode and seed color', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(themeProvider).mode, ThemeMode.system);
    expect(container.read(themeProvider).seedColor, AppTheme.defaultSeedColor);

    await container.read(themeProvider.notifier).setMode(ThemeMode.dark);
    await container
        .read(themeProvider.notifier)
        .setSeedColor(const Color(0xFF2563EB));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(StorageKeys.themeMode), 'dark');
    expect(prefs.getInt(StorageKeys.themeSeedColor), 0xFF2563EB);
    expect(container.read(themeProvider).mode, ThemeMode.dark);
    expect(container.read(themeProvider).seedColor, const Color(0xFF2563EB));
  });

  test(
    'theme preferences fall back when saved seed color is invalid',
    () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.themeMode: 'light',
        StorageKeys.themeSeedColor: -1,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(themeProvider.notifier).loaded;

      expect(container.read(themeProvider).mode, ThemeMode.light);
      expect(
        container.read(themeProvider).seedColor,
        AppTheme.defaultSeedColor,
      );
    },
  );

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

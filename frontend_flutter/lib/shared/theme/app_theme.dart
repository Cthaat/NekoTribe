import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/storage_keys.dart';

class ThemeSeedOption {
  const ThemeSeedOption({required this.color, required this.labelKey});

  final Color color;
  final String labelKey;
}

class AppThemePreference {
  const AppThemePreference({required this.mode, required this.seedColor});

  final ThemeMode mode;
  final Color seedColor;

  AppThemePreference copyWith({ThemeMode? mode, Color? seedColor}) {
    return AppThemePreference(
      mode: mode ?? this.mode,
      seedColor: seedColor ?? this.seedColor,
    );
  }
}

class ThemeController extends StateNotifier<AppThemePreference> {
  ThemeController() : super(AppTheme.defaultPreference) {
    loaded = _load();
  }

  late final Future<void> loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = _parseMode(prefs.getString(StorageKeys.themeMode));
    final seedColor = _parseSeedColor(prefs.getInt(StorageKeys.themeSeedColor));
    if (!mounted) return;
    state = AppThemePreference(mode: mode, seedColor: seedColor);
  }

  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.themeMode, mode.name);
  }

  Future<void> setSeedColor(Color color) async {
    final normalized = _normalizeSeedColor(color);
    state = state.copyWith(seedColor: normalized);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.themeSeedColor, normalized.toARGB32());
  }

  static ThemeMode _parseMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Color _parseSeedColor(int? raw) {
    if (raw == null || raw < 0 || raw > 0xFFFFFFFF) {
      return AppTheme.defaultSeedColor;
    }
    return _normalizeSeedColor(Color(raw));
  }

  static Color _normalizeSeedColor(Color color) {
    final argb = color.toARGB32();
    if (argb < 0 || argb > 0xFFFFFFFF) {
      return AppTheme.defaultSeedColor;
    }
    if ((argb & 0xFF000000) == 0) {
      return Color(argb | 0xFF000000);
    }
    return color;
  }
}

final themeProvider =
    StateNotifierProvider<ThemeController, AppThemePreference>(
      (ref) => ThemeController(),
    );

class AppTheme {
  AppTheme._();

  static const Color defaultSeedColor = Color(0xFFEC4899);
  static const AppThemePreference defaultPreference = AppThemePreference(
    mode: ThemeMode.system,
    seedColor: defaultSeedColor,
  );

  static const List<ThemeSeedOption> seedOptions = [
    ThemeSeedOption(color: Color(0xFFEC4899), labelKey: 'theme.color.pink'),
    ThemeSeedOption(color: Color(0xFF2563EB), labelKey: 'theme.color.blue'),
    ThemeSeedOption(color: Color(0xFF16A34A), labelKey: 'theme.color.green'),
    ThemeSeedOption(color: Color(0xFFF59E0B), labelKey: 'theme.color.amber'),
    ThemeSeedOption(color: Color(0xFF7C3AED), labelKey: 'theme.color.violet'),
    ThemeSeedOption(color: Color(0xFF0F766E), labelKey: 'theme.color.teal'),
  ];

  static ThemeData light([Color seedColor = defaultSeedColor]) {
    return _theme(Brightness.light, seedColor);
  }

  static ThemeData dark([Color seedColor = defaultSeedColor]) {
    return _theme(Brightness.dark, seedColor);
  }

  static ThemeData _theme(Brightness brightness, Color seedColor) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: seedColor,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    );
  }
}

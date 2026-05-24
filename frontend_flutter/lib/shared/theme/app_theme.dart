import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
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

  static String? get _primaryFontFamily {
    if (kIsWeb) return null;
    if (Platform.isWindows) return 'Microsoft YaHei UI';
    if (Platform.isMacOS || Platform.isIOS) return 'PingFang SC';
    if (Platform.isAndroid) return 'Noto Sans CJK SC';
    if (Platform.isLinux) return 'Noto Sans CJK SC';
    return null;
  }

  static const List<String> _fontFamilyFallback = <String>[
    'PingFang SC',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'Source Han Sans CN',
    'WenQuanYi Micro Hei',
    'Hiragino Sans GB',
    'Heiti SC',
    'SimHei',
    'sans-serif',
  ];

  static ThemeData _theme(Brightness brightness, Color seedColor) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;
    final baseText = isDark
        ? Typography.whiteMountainView
        : Typography.blackMountainView;
    final textTheme = _buildTextTheme(baseText, colorScheme);

    final scaffoldBackground = isDark
        ? const Color(0xFF0F1115)
        : const Color(0xFFF7F8FA);
    final cardSurface = isDark ? const Color(0xFF161A21) : Colors.white;
    final dividerColor = colorScheme.outlineVariant.withValues(alpha: 0.6);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBackground,
      canvasColor: scaffoldBackground,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      fontFamily: _primaryFontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: DividerThemeData(
        color: dividerColor,
        thickness: 0.6,
        space: 0.6,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: scaffoldBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        iconTheme: IconThemeData(color: colorScheme.onSurface, size: 22),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: cardSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: dividerColor),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? colorScheme.surfaceContainerHigh
            : colorScheme.surfaceContainerLowest,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.error, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          side: BorderSide(color: colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: colorScheme.primary,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        overlayColor: WidgetStatePropertyAll(
          colorScheme.primary.withValues(alpha: 0.06),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        side: BorderSide(color: colorScheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        labelStyle: textTheme.labelMedium,
        backgroundColor: cardSurface,
        selectedColor: colorScheme.primary.withValues(alpha: 0.12),
        showCheckmark: false,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF2A2F38)
            : const Color(0xFF1F232B),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 4,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.onSurfaceVariant,
        titleTextStyle: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 4,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cardSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.14),
        labelTextStyle: WidgetStatePropertyAll(
          textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: cardSurface,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.14),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        highlightElevation: 4,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.surfaceContainerHighest,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2F38) : const Color(0xFF1F232B),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: textTheme.bodyMedium,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(
            textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }

  static TextTheme _buildTextTheme(TextTheme base, ColorScheme scheme) {
    final defaultColor = scheme.onSurface;
    final softColor = scheme.onSurfaceVariant;

    TextStyle? style(
      TextStyle? source, {
      double? size,
      FontWeight? weight,
      double? height,
      double? letterSpacing,
      Color? color,
    }) {
      if (source == null) return null;
      return source.copyWith(
        fontSize: size ?? source.fontSize,
        fontWeight: weight ?? source.fontWeight,
        height: height ?? source.height,
        letterSpacing: letterSpacing ?? source.letterSpacing,
        color: color ?? defaultColor,
      );
    }

    return base.copyWith(
      displayLarge: style(base.displayLarge, weight: FontWeight.w600, height: 1.2),
      displayMedium: style(base.displayMedium, weight: FontWeight.w600, height: 1.2),
      displaySmall: style(base.displaySmall, weight: FontWeight.w600, height: 1.25),
      headlineLarge: style(base.headlineLarge, weight: FontWeight.w600, height: 1.25),
      headlineMedium: style(base.headlineMedium, weight: FontWeight.w600, height: 1.3),
      headlineSmall: style(base.headlineSmall, weight: FontWeight.w600, height: 1.3),
      titleLarge: style(base.titleLarge, weight: FontWeight.w600, height: 1.35, letterSpacing: 0),
      titleMedium: style(base.titleMedium, weight: FontWeight.w600, height: 1.4, letterSpacing: 0),
      titleSmall: style(base.titleSmall, weight: FontWeight.w600, height: 1.4, letterSpacing: 0),
      bodyLarge: style(base.bodyLarge, weight: FontWeight.w400, height: 1.5, letterSpacing: 0),
      bodyMedium: style(base.bodyMedium, weight: FontWeight.w400, height: 1.5, letterSpacing: 0),
      bodySmall: style(base.bodySmall, weight: FontWeight.w400, height: 1.45, color: softColor, letterSpacing: 0),
      labelLarge: style(base.labelLarge, weight: FontWeight.w500, height: 1.3, letterSpacing: 0.1),
      labelMedium: style(base.labelMedium, weight: FontWeight.w500, height: 1.3, letterSpacing: 0.1),
      labelSmall: style(base.labelSmall, weight: FontWeight.w500, height: 1.3, color: softColor, letterSpacing: 0.1),
    );
  }
}

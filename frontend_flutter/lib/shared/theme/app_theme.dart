import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
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
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;
    final textTheme = _textTheme(colorScheme, isDark);

    final scaffoldBackground = isDark
        ? const Color(0xFF0E1014)
        : const Color(0xFFFAFAFB);
    final cardSurface = isDark ? const Color(0xFF16181D) : Colors.white;
    final subtleBorder = isDark
        ? const Color(0xFF262932)
        : const Color(0xFFE6E8EC);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBackground,
      canvasColor: scaffoldBackground,
      visualDensity: VisualDensity.standard,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: DividerThemeData(
        color: subtleBorder,
        thickness: 0.6,
        space: 0.6,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scaffoldBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        toolbarHeight: 56,
        iconTheme: IconThemeData(color: colorScheme.onSurface, size: 22),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: cardSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: subtleBorder),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF1B1E25) : const Color(0xFFF1F2F5),
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
        floatingLabelStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.primary,
          fontWeight: FontWeight.w500,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: subtleBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.error, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          side: BorderSide(color: subtleBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
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
            letterSpacing: 0.1,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: colorScheme.onSurface,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: colorScheme.primary, width: 3),
          insets: const EdgeInsets.symmetric(horizontal: 4),
        ),
        dividerColor: Colors.transparent,
        overlayColor: WidgetStatePropertyAll(
          colorScheme.primary.withValues(alpha: 0.06),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(color: subtleBorder),
        ),
        side: BorderSide(color: subtleBorder),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        labelStyle: textTheme.labelMedium,
        backgroundColor: cardSurface,
        selectedColor: colorScheme.primary.withValues(alpha: 0.14),
        showCheckmark: false,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF2A2F38)
            : const Color(0xFF1F232B),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.onSurfaceVariant,
        titleTextStyle: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cardSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.14),
        labelTextStyle: WidgetStatePropertyAll(
          textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
        height: 64,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scaffoldBackground,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.14),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
        selectedIconTheme: IconThemeData(color: colorScheme.primary, size: 24),
        unselectedIconTheme: IconThemeData(
          color: colorScheme.onSurfaceVariant,
          size: 24,
        ),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
        unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        useIndicator: true,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        highlightElevation: 4,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        shape: const CircleBorder(),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: subtleBorder,
        circularTrackColor: Colors.transparent,
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
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: subtleBorder),
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
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return isDark ? const Color(0xFFBEC2CB) : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return colorScheme.primary;
          return isDark ? const Color(0xFF2E323B) : const Color(0xFFD7DAE0);
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: BorderSide(color: subtleBorder, width: 1.4),
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme, bool isDark) {
    final defaultColor = scheme.onSurface;
    final softColor = scheme.onSurfaceVariant;
    final platformTextTheme = isDark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;
    final base = kIsWeb
        ? platformTextTheme
        : GoogleFonts.notoSansScTextTheme(platformTextTheme);
    final theme = TextTheme(
      displayLarge: base.displayLarge?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.15,
        color: defaultColor,
        letterSpacing: -0.5,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: defaultColor,
        letterSpacing: -0.4,
      ),
      displaySmall: base.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.25,
        color: defaultColor,
        letterSpacing: -0.3,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.25,
        color: defaultColor,
        letterSpacing: -0.2,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: defaultColor,
        letterSpacing: -0.2,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: defaultColor,
        letterSpacing: -0.1,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.35,
        color: defaultColor,
        letterSpacing: -0.1,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: defaultColor,
        letterSpacing: 0,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: defaultColor,
        letterSpacing: 0,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontWeight: FontWeight.w400,
        height: 1.55,
        color: defaultColor,
        letterSpacing: 0,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: defaultColor,
        letterSpacing: 0,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: softColor,
        letterSpacing: 0,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontWeight: FontWeight.w500,
        height: 1.3,
        color: defaultColor,
        letterSpacing: 0.1,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontWeight: FontWeight.w500,
        height: 1.3,
        color: defaultColor,
        letterSpacing: 0.1,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontWeight: FontWeight.w500,
        height: 1.3,
        color: softColor,
        letterSpacing: 0.1,
      ),
    );
    return theme.apply(
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'PingFang SC',
        'Noto Sans CJK SC',
        'SimHei',
        'Arial Unicode MS',
        'sans-serif',
      ],
    );
  }
}

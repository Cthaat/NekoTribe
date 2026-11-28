import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/storage_keys.dart';
import '../widgets/glass/liquid_glass_tokens.dart';
import 'tokens.dart';

class ThemeSeedOption {
  const ThemeSeedOption({required this.color, required this.labelKey});

  final Color color;
  final String labelKey;
}

enum AppFontSize {
  small(0.92),
  normal(1.0),
  large(1.12);

  const AppFontSize(this.scale);
  final double scale;
}

class AppThemePreference {
  const AppThemePreference({
    required this.mode,
    required this.seedColor,
    this.fontSize = AppFontSize.normal,
    this.glassIntensity = LiquidGlassIntensity.standard,
    this.compactMode = false,
  });

  final ThemeMode mode;
  final Color seedColor;
  final AppFontSize fontSize;
  final LiquidGlassIntensity glassIntensity;
  final bool compactMode;

  AppThemePreference copyWith({
    ThemeMode? mode,
    Color? seedColor,
    AppFontSize? fontSize,
    LiquidGlassIntensity? glassIntensity,
    bool? compactMode,
  }) {
    return AppThemePreference(
      mode: mode ?? this.mode,
      seedColor: seedColor ?? this.seedColor,
      fontSize: fontSize ?? this.fontSize,
      glassIntensity: glassIntensity ?? this.glassIntensity,
      compactMode: compactMode ?? this.compactMode,
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
    final fontSize = _parseFontSize(prefs.getString(StorageKeys.fontSize));
    final glassIntensity =
        prefs.getString(StorageKeys.liquidGlassIntensity) ==
            LiquidGlassIntensity.subtle.name
        ? LiquidGlassIntensity.subtle
        : LiquidGlassIntensity.standard;
    if (!mounted) return;
    state = AppThemePreference(
      mode: mode,
      seedColor: seedColor,
      fontSize: fontSize,
      glassIntensity: glassIntensity,
      compactMode: prefs.getBool(StorageKeys.compactMode) ?? false,
    );
  }

  AppFontSize _parseFontSize(String? raw) {
    return AppFontSize.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => AppFontSize.normal,
    );
  }

  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.themeMode, mode.name);
  }

  Future<void> setFontSize(AppFontSize fontSize) async {
    state = state.copyWith(fontSize: fontSize);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.fontSize, fontSize.name);
  }

  Future<void> setGlassIntensity(LiquidGlassIntensity intensity) async {
    await loaded;
    if (!mounted) return;
    state = state.copyWith(glassIntensity: intensity);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.liquidGlassIntensity, intensity.name);
  }

  Future<void> setCompactMode(bool value) async {
    await loaded;
    if (!mounted) return;
    state = state.copyWith(compactMode: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageKeys.compactMode, value);
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

  static const Color defaultSeedColor = Color(0xFF007AFF);
  static const Color _legacyBlueSeedColor = Color(0xFF2563EB);
  static const List<String> _cjkFontFallback = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Hiragino Sans GB',
    'Noto Sans SC',
    'Noto Sans CJK SC',
    'SimHei',
    'Arial Unicode MS',
    'sans-serif',
  ];
  static const AppThemePreference defaultPreference = AppThemePreference(
    mode: ThemeMode.system,
    seedColor: defaultSeedColor,
    glassIntensity: LiquidGlassIntensity.standard,
  );

  static const List<ThemeSeedOption> seedOptions = [
    ThemeSeedOption(color: Color(0xFF007AFF), labelKey: 'theme.color.blue'),
    ThemeSeedOption(color: Color(0xFFEC4899), labelKey: 'theme.color.pink'),
    ThemeSeedOption(color: Color(0xFF16A34A), labelKey: 'theme.color.green'),
    ThemeSeedOption(color: Color(0xFFF59E0B), labelKey: 'theme.color.amber'),
    ThemeSeedOption(color: Color(0xFF7C3AED), labelKey: 'theme.color.violet'),
    ThemeSeedOption(color: Color(0xFF0F766E), labelKey: 'theme.color.teal'),
  ];

  static ThemeData light([
    Color seedColor = defaultSeedColor,
    LiquidGlassIntensity glassIntensity = LiquidGlassIntensity.standard,
    bool compact = false,
  ]) {
    return _theme(
      Brightness.light,
      seedColor,
      glassIntensity,
      compact: compact,
    );
  }

  static ThemeData dark([
    Color seedColor = defaultSeedColor,
    LiquidGlassIntensity glassIntensity = LiquidGlassIntensity.standard,
    bool compact = false,
  ]) {
    return _theme(Brightness.dark, seedColor, glassIntensity, compact: compact);
  }

  static bool _isDefaultBlue(Color seedColor) {
    final argb = seedColor.toARGB32();
    return argb == defaultSeedColor.toARGB32() ||
        argb == _legacyBlueSeedColor.toARGB32();
  }

  static Color _resolvePrimary(Color seedColor, bool isDark) {
    final defaultBlue = _isDefaultBlue(seedColor);
    if (!isDark) {
      return defaultBlue ? defaultSeedColor : seedColor;
    }
    if (defaultBlue) {
      return const Color(0xFF8CC8FF);
    }
    final hsl = HSLColor.fromColor(seedColor);
    return hsl
        .withLightness(hsl.lightness.clamp(0.64, 0.72))
        .withSaturation(hsl.saturation.clamp(0.75, 0.95))
        .toColor();
  }

  static ThemeData _theme(
    Brightness brightness,
    Color seedColor,
    LiquidGlassIntensity glassIntensity, {
    bool compact = false,
  }) {
    final isDark = brightness == Brightness.dark;
    final resolvedPrimary = _resolvePrimary(seedColor, isDark);
    final rawScheme = ColorScheme.fromSeed(
      seedColor: _isDefaultBlue(seedColor) ? defaultSeedColor : seedColor,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    final scheme = rawScheme.copyWith(
      primary: resolvedPrimary,
      onPrimary: isDark ? const Color(0xFF081829) : Colors.white,
      primaryContainer: resolvedPrimary.withValues(alpha: isDark ? 0.16 : 0.10),
      onPrimaryContainer: isDark
          ? resolvedPrimary
          : HSLColor.fromColor(resolvedPrimary).withLightness(0.28).toColor(),
      secondaryContainer: isDark
          ? const Color(0xFF20232A)
          : const Color(0xFFEEF1F6),
      onSecondaryContainer: isDark
          ? const Color(0xFFECEDEF)
          : const Color(0xFF111418),
      surface: isDark ? const Color(0xFF090A0D) : const Color(0xFFF2F4F7),
      surfaceContainerLowest: isDark
          ? const Color(0xFF16181D)
          : const Color(0xFFFFFFFF),
      surfaceContainerLow: isDark
          ? const Color(0xFF16181D)
          : const Color(0xFFFFFFFF),
      surfaceContainer: isDark
          ? const Color(0xFF20232A)
          : const Color(0xFFEEF1F6),
      surfaceContainerHigh: isDark
          ? const Color(0xFF2A2E37)
          : const Color(0xFFE3E8F0),
      surfaceContainerHighest: isDark
          ? const Color(0xFF333843)
          : const Color(0xFFD8DFEA),
      onSurface: isDark ? const Color(0xFFECEDEF) : const Color(0xFF111418),
      onSurfaceVariant: isDark
          ? const Color(0xFF949BA4)
          : const Color(0xFF5E6670),
      outline: isDark ? const Color(0xFF2E333E) : const Color(0xFFD6DCE5),
      outlineVariant: isDark
          ? const Color(0xFF22262F)
          : const Color(0xFFE6E9EF),
    );
    final social = SocialColors.fromScheme(
      scheme,
      isDark: isDark,
      glassIntensity: glassIntensity,
    );
    final textTheme = _textTheme(scheme, isDark);
    final buttonHover = scheme.onSurface.withValues(alpha: 0.07);
    final buttonFocus = scheme.onSurface.withValues(alpha: 0.15);
    final buttonPress = scheme.onSurface.withValues(alpha: 0.20);
    final buttonOverlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      if (states.contains(WidgetState.pressed)) return buttonPress;
      if (states.contains(WidgetState.focused)) return buttonFocus;
      if (states.contains(WidgetState.hovered)) return buttonHover;
      return null;
    });

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: social.surfaceBase,
      canvasColor: social.surfaceBase,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      fontFamily: kIsWeb ? 'Microsoft YaHei UI' : null,
      fontFamilyFallback: _cjkFontFallback,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      splashFactory: InkRipple.splashFactory,
      hoverColor: buttonHover,
      focusColor: buttonFocus,
      highlightColor: buttonPress,
      extensions: [social],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      dividerTheme: DividerThemeData(
        color: social.divider,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: social.surfaceBase,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        toolbarHeight: 54,
        iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: social.surfaceCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: social.surfaceSubtle,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppGap.lg,
          vertical: 14,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        floatingLabelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w500,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          shape: const StadiumBorder(),
          animationDuration: AppMotion.micro,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ).copyWith(overlayColor: buttonOverlay),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          backgroundColor: social.surfaceSubtle,
          foregroundColor: scheme.onSurface,
          elevation: 0,
          shape: const StadiumBorder(),
          animationDuration: AppMotion.micro,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ).copyWith(overlayColor: buttonOverlay),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          side: BorderSide(color: scheme.outlineVariant),
          shape: const StadiumBorder(),
          animationDuration: AppMotion.micro,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ).copyWith(overlayColor: buttonOverlay),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: AppGap.md,
            vertical: AppGap.sm,
          ),
          shape: const StadiumBorder(),
          animationDuration: AppMotion.micro,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ).copyWith(overlayColor: buttonOverlay),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: const ButtonStyle(
          shape: WidgetStatePropertyAll(StadiumBorder()),
          animationDuration: AppMotion.micro,
        ).copyWith(overlayColor: buttonOverlay),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        splashFactory: NoSplash.splashFactory,
        indicator: ShapeDecoration(color: social.surfaceCard, shape: const StadiumBorder()),
        dividerColor: Colors.transparent,
        overlayColor: buttonOverlay,
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: AppGap.md, vertical: 6),
        labelStyle: textTheme.labelMedium,
        backgroundColor: social.surfaceSubtle,
        selectedColor: social.primarySoft,
        showCheckmark: false,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.canvas),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        dragHandleSize: const Size(36, 4),
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.canvas),
          ),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.tile),
        ),
        elevation: 0,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppGap.lg,
          vertical: AppGap.xs,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: social.primarySoft,
        indicatorShape: const StadiumBorder(),
        overlayColor: buttonOverlay,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
        height: 60,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: social.shellFrame,
        indicatorColor: social.primarySoft,
        indicatorShape: const StadiumBorder(),
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 22,
        ),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        useIndicator: true,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        hoverColor: buttonHover,
        focusColor: buttonFocus,
        splashColor: buttonPress,
        shape: const CircleBorder(),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: social.surfaceHover,
        circularTrackColor: Colors.transparent,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        shadowColor: scheme.shadow.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 4,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.tile),
        ),
        textStyle: textTheme.bodyMedium,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          overlayColor: buttonOverlay,
          animationDuration: AppMotion.micro,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          textStyle: WidgetStatePropertyAll(
            textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return Colors.white.withValues(alpha: 0.65);
          }
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          if (states.contains(WidgetState.disabled)) {
            return (selected
                    ? const Color(0xFF34C759)
                    : social.surfaceHover)
                .withValues(alpha: 0.45);
          }
          return selected
              ? (isDark ? const Color(0xFF30D158) : const Color(0xFF34C759))
              : (isDark ? const Color(0xFF393B40) : const Color(0xFFE0E2E7));
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        trackOutlineWidth: const WidgetStatePropertyAll(0),
        thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme, bool isDark) {
    final defaultColor = scheme.onSurface;
    final softColor = scheme.onSurfaceVariant;
    final base = isDark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;
    final theme = TextTheme(
      displayLarge: base.displayLarge?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.15,
        color: defaultColor,
        letterSpacing: -0.5,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: defaultColor,
        letterSpacing: -0.4,
      ),
      displaySmall: base.displaySmall?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.25,
        color: defaultColor,
        letterSpacing: -0.3,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.25,
        color: defaultColor,
        letterSpacing: -0.2,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: defaultColor,
        letterSpacing: -0.2,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: defaultColor,
        letterSpacing: -0.1,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
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
        height: 1.62,
        color: defaultColor,
        letterSpacing: 0,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontWeight: FontWeight.w400,
        height: 1.56,
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
      fontFamily: kIsWeb ? 'Microsoft YaHei UI' : null,
      fontFamilyFallback: _cjkFontFallback,
    );
  }
}

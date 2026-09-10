import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/config/app_config.dart';
import 'shared/i18n/app_localizations.dart';
import 'shared/providers/providers.dart';
import 'shared/routing/app_router.dart';
import 'shared/theme/app_theme.dart';
import 'shared/window/desktop_window_frame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final windowOptions = await _desktopWindowOptions();
  final bundle = await AppConfigLoader.loadBundle();
  final initial = await AppConfigLoader.initialConfig(bundle);
  runApp(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(bundle),
        appConfigInitialProvider.overrideWithValue(initial),
      ],
      child: const NekoTribeApp(),
    ),
  );
  await _showDesktopWindow(windowOptions);
}

Future<WindowOptions?> _desktopWindowOptions() async {
  if (kIsWeb) return null;
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    return null;
  }

  await windowManager.ensureInitialized();
  if (!isDesktopWindowFrameSupported) {
    return const WindowOptions(title: 'NekoTribe');
  }

  return const WindowOptions(
    title: 'NekoTribe',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
}

Future<void> _showDesktopWindow(WindowOptions? options) async {
  if (options == null) return;
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

class NekoTribeApp extends ConsumerWidget {
  const NekoTribeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final theme = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'NekoTribe',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(theme.seedColor),
      darkTheme: AppTheme.dark(theme.seedColor),
      themeMode: theme.mode,
      locale: locale,
      supportedLocales: AppLocalizations.supported,
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => DesktopWindowFrame(
        enabled: isDesktopWindowFrameSupported,
        child: child ?? const SizedBox.shrink(),
      ),
      routerConfig: router,
    );
  }
}

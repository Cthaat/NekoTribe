import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'shared/i18n/app_localizations.dart';
import 'shared/providers/providers.dart';
import 'shared/routing/app_router.dart';
import 'shared/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      routerConfig: router,
    );
  }
}

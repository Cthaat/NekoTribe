import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/sentiment_flow/data/sentiment_flow_api.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/settings_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

const testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);
final expectations = {
  for (final item
      in (jsonDecode(
                File(
                  'contracts/scenarios/user-settings-client-lifecycle.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)['cases']
          as List<dynamic>)
    (item as Map<String, dynamic>)['id'] as String: item,
};

class Store extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<void> clear() async {}
  @override
  Future<String> deviceFingerprint() async => 'isolated';
}

V2UserSettings settings({bool login = true, String privacy = 'public'}) =>
    V2UserSettings(
      userId: 42,
      loginAlerts: login,
      profileVisibility: privacy,
      showOnlineStatus: true,
      updatedAt: '',
    );

class Users extends UsersRepository {
  Users() : super(UsersApi(ApiClient(config: testConfig, tokenStore: Store())));
  V2UserSettings value = settings();
  Completer<V2UserSettings>? load, save;
  int reads = 0;
  final writes = <Map<String, dynamic>>[];
  @override
  Future<V2UserSettings> getSettings() {
    reads++;
    return load?.future ?? Future.value(value);
  }

  @override
  Future<V2UserSettings> updateSettings(Map<String, dynamic> body) {
    writes.add(Map.of(body));
    return save?.future ?? Future.value(value);
  }
}

class Legacy extends SentimentFlowApi {
  Legacy() : super(ApiClient(config: testConfig, tokenStore: Store()));
  int calls = 0;
  @override
  Future<V2SentimentFlowConfig> config() async {
    calls++;
    return V2SentimentFlowConfig(
      enabled: false,
      baseUrl: '',
      baseUrlConfigured: false,
      proxyBasePath: '/api/v2/integrations/sentiment-flow',
      defaultModel: '',
      availableModels: [],
      timeoutMs: 100,
    );
  }
}

Future<Store> pump(
  WidgetTester tester,
  Users users, {
  bool settle = true,
  Legacy? legacy,
  Locale locale = const Locale('zh'),
}) async {
  final store = Store(),
      api = ApiClient(config: testConfig, tokenStore: Store());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(
          const AppConfigBundle(defaults: testConfig, presets: []),
        ),
        appConfigInitialProvider.overrideWithValue(testConfig),
        authRepositoryProvider.overrideWithValue(
          AuthRepository(api: AuthApi(api), tokenStore: store),
        ),
        usersRepositoryProvider.overrideWithValue(users),
        sentimentFlowApiProvider.overrideWithValue(legacy ?? Legacy()),
      ],
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supported,
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const SettingsScreen(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return store;
}

Future<ValueChanged<bool>> privacyControl(WidgetTester tester) async {
  for (var i = 0; i < 12 && find.byType(Switch).evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.byType(Switch).first);
  await tester.pumpAndSettle();
  return tester.widget<Switch>(find.byType(Switch).first).onChanged!;
}

void main() {
  testWidgets(
    'repository replacement expires settings and old callbacks cannot update either repository',
    (tester) async {
      final users = Users(), current = Users();
      await pump(tester, users);
      final change = await privacyControl(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsScreen)),
      );
      container.updateOverrides([
        appConfigBundleProvider.overrideWithValue(
          const AppConfigBundle(defaults: testConfig, presets: []),
        ),
        appConfigInitialProvider.overrideWithValue(testConfig),
        authRepositoryProvider.overrideWithValue(
          container.read(authRepositoryProvider),
        ),
        usersRepositoryProvider.overrideWithValue(current),
        sentimentFlowApiProvider.overrideWithValue(
          container.read(sentimentFlowApiProvider),
        ),
      ]);
      change(false);
      expect(users.writes, isEmpty);
      expect(current.writes, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-session-reopen')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-session-reopen')));
      await tester.pumpAndSettle();
      change(false);
      expect(current.writes, isEmpty);
      expect(current.reads, 1);
    },
  );
  testWidgets(
    'failed initial read and duplicate explicit retries never submit defaults',
    (tester) async {
      final users = Users()..load = Completer<V2UserSettings>();
      await pump(tester, users, settle: false);
      users.load!.completeError(Exception('isolated read failure'));
      await tester.pumpAndSettle();
      final retry = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '重试'))
          .onPressed!;
      users.load = Completer<V2UserSettings>();
      retry();
      retry();
      expect(users.reads, 2);
      expect(
        users.writes.length,
        expectations['initial-read-failed']!['expectedWrites'],
      );
      users.load!.complete(settings());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'late old read never starts a legacy service request under a different identity',
    (tester) async {
      final users = Users()..load = Completer<V2UserSettings>(),
          legacy = Legacy();
      final store = await pump(tester, users, settle: false, legacy: legacy);
      store.beginSessionChange();
      await tester.pump();
      users.load!.complete(settings());
      await tester.pumpAndSettle();
      expect(legacy.calls, 0);
      expect(find.byKey(const Key('settings-session-reopen')), findsOneWidget);
    },
  );
  testWidgets('unmounted settings ignore save completion', (tester) async {
    final users = Users()..save = Completer<V2UserSettings>();
    await pump(tester, users);
    final change = await privacyControl(tester);
    change(false);
    await tester.pumpWidget(const SizedBox.shrink());
    users.save!.complete(settings(login: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets(
      'unknown privacy and save feedback fit a320px viewport ${locale.languageCode}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 740));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final users = Users()..value = settings(privacy: 'legacy-unknown');
        await pump(tester, users, locale: locale);
        await privacyControl(tester);
        await tester.drag(find.byType(ListView), const Offset(0, -180));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        users.save = Completer<V2UserSettings>();
        tester.widget<Switch>(find.byType(Switch).first).onChanged!(false);
        users.save!.completeError(Exception('uncertain narrow layout'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('settings-save-uncertain')),
          findsOneWidget,
        );
        expect(
          find.text(AppLocalizations(locale).t('settings.save_uncertain')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'duplicate old callbacks cannot send concurrent updates and controls disable while saving',
    (tester) async {
      final users = Users()..save = Completer<V2UserSettings>();
      await pump(tester, users);
      final change = await privacyControl(tester);
      change(false);
      change(false);
      expect(
        users.writes.length,
        expectations['duplicate-save']!['expectedWrites'],
      );
      await tester.pump();
      expect(
        tester.widget<Switch>(find.byType(Switch).first).onChanged,
        isNull,
      );
      users.save!.complete(settings(login: false));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, false);
    },
  );
  testWidgets(
    'uncertain update blocks stale callbacks and requires explicit reload',
    (tester) async {
      final users = Users()..save = Completer<V2UserSettings>();
      await pump(tester, users);
      final change = await privacyControl(tester);
      change(false);
      users.save!.completeError(Exception('uncertain outcome'));
      await tester.pumpAndSettle();
      change(true);
      expect(
        users.writes.length,
        expectations['uncertain-save']!['expectedWrites'],
      );
      expect(
        users.reads - 1,
        expectations['uncertain-save']!['expectedAutomaticReads'],
      );
      expect(find.byKey(const Key('settings-save-uncertain')), findsOneWidget);
      users.save = null;
      users.value = settings(login: false);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(users.reads, 2);
      change(true);
      expect(users.writes.length, 1);
    },
  );
  testWidgets(
    'identity signal blocks old callbacks before repaint and explicit reopening invalidates them',
    (tester) async {
      final users = Users();
      final store = await pump(tester, users);
      final change = await privacyControl(tester);
      final pending = Completer<void>(),
          work = store.runSessionChange((_) => pending.future);
      change(false);
      expect(
        users.writes.length,
        expectations['stale-owner']!['expectedWrites'],
      );
      await tester.pump();
      final reopen = tester.widget<FilledButton>(
        find.byKey(const Key('settings-session-reopen')),
      );
      expect(reopen.onPressed, isNull);
      pending.complete();
      await work;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-session-reopen')));
      await tester.pumpAndSettle();
      change(false);
      expect(users.writes, isEmpty);
      expect(users.reads, 2);
    },
  );
  testWidgets('late update cannot replace a reopened identity snapshot', (
    tester,
  ) async {
    final users = Users()..save = Completer<V2UserSettings>();
    final store = await pump(tester, users);
    final change = await privacyControl(tester);
    change(false);
    store.beginSessionChange();
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-session-reopen')));
    await tester.pumpAndSettle();
    users.save!.complete(settings(login: false));
    await tester.pumpAndSettle();
    final current = await privacyControl(tester);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, true);
    expect(current, isNotNull);
  });
  testWidgets(
    'legacy privacy renders safely but followers is not a selectable new value',
    (tester) async {
      final users = Users()..value = settings(privacy: 'legacy-unknown');
      await pump(tester, users);
      await privacyControl(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      final dropdown = tester
          .widgetList<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .last;
      expect(dropdown.items!.any((item) => item.value == 'followers'), false);
      expect(
        dropdown.items!
            .where((item) => item.enabled)
            .map((item) => item.value)
            .toList()
          ..sort(),
        expectations['legacy-privacy']!['selectableValues'],
      );
      expect(
        dropdown.items!
            .singleWhere((item) => item.value == 'legacy-unknown')
            .enabled,
        false,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

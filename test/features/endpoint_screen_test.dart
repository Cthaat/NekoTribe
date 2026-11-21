import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/constants/storage_keys.dart';
import 'package:nekotribe/core/network/endpoint_probe.dart';
import 'package:nekotribe/features/users/presentation/endpoint_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an API-only saved endpoint derives realtime and media on startup',
    () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.endpointOverride:
            '{"presetId":"custom","apiBaseUrl":"https://api.example.test:8443/neko/"}',
      });

      final saved = await AppConfigLoader.readOverride();

      expect(saved?.presetId, 'custom');
      expect(saved?.apiBaseUrl, 'https://api.example.test:8443/neko');
      expect(saved?.wsBaseUrl, 'wss://api.example.test:8443/neko');
      expect(saved?.storageBaseUrl, 'https://api.example.test:8443/neko');
    },
  );

  test('a preset derives only the missing companion endpoint', () {
    final preset = EndpointPreset.fromJson({
      'id': 'remote',
      'apiBaseUrl': 'https://api.example.test:8443/neko/',
      'storageBaseUrl': 'https://cdn.example.test/media',
    });

    expect(preset.apiBaseUrl, 'https://api.example.test:8443/neko');
    expect(preset.wsBaseUrl, 'wss://api.example.test:8443/neko');
    expect(preset.storageBaseUrl, 'https://cdn.example.test/media');
  });

  test(
    'controller applies an API-only switch and rejects a malformed override',
    () async {
      SharedPreferences.setMockInitialValues({});
      final initial = AppConfig.fromCustom(
        apiBaseUrl: 'https://original.example.test',
      );
      final tokens = TokenStore();
      final controller = AppConfigController(
        bundle: AppConfigBundle(defaults: initial, presets: const []),
        initial: initial,
        tokenStore: tokens,
      );
      addTearDown(controller.dispose);
      var current = initial;
      controller.addListener((config) => current = config);

      await controller.setCustom(
        apiBaseUrl: ' https://api.example.test:8443/neko/ ',
      );
      final saved = await AppConfigLoader.readOverride();
      expect(saved?.apiBaseUrl, 'https://api.example.test:8443/neko');
      expect(current.toJson(), saved?.toJson());
      expect(current.wsBaseUrl, 'wss://api.example.test:8443/neko');
      expect(current.storageBaseUrl, 'https://api.example.test:8443/neko');
      final revision = tokens.revision;

      await expectLater(
        controller.setCustom(
          apiBaseUrl: 'https://other.example.test',
          wsBaseUrl: 'https://other.example.test',
          storageBaseUrl: '',
        ),
        throwsFormatException,
      );
      expect(tokens.revision, revision);
      expect(current.toJson(), saved?.toJson());
      expect((await AppConfigLoader.readOverride())?.toJson(), saved?.toJson());
    },
  );

  testWidgets(
    'HTTPS page rejects a remote insecure endpoint before save and probe',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(900, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final initial = AppConfig.fromCustom(
        apiBaseUrl: 'https://api.example.test',
      );
      var probes = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWith(
              (ref) => AppConfigController(
                bundle: AppConfigBundle(defaults: initial, presets: const []),
                initial: initial,
                tokenStore: ref.read(tokenStoreProvider),
                browserPage: Uri.parse('https://community.example.test/'),
              ),
            ),
          ],
          child: MaterialApp(
            home: EndpointScreen(
              probe: (_) async {
                probes++;
                return (
                  api: EndpointReadiness.ready,
                  media: EndpointReadiness.ready,
                );
              },
            ),
          ),
        ),
      );
      final realtime = find.byType(TextField).at(1);
      await tester.enterText(realtime, 'ws://realtime.example.test/socket');
      await tester.tap(find.text('检查 API 和媒体'));
      await tester.pumpAndSettle();
      expect(probes, 0);
      expect(find.textContaining('当前页面使用 HTTPS'), findsOneWidget);
      await tester.tap(find.text('保存自定义'));
      await tester.pumpAndSettle();
      expect(await AppConfigLoader.readOverride(), isNull);
      await tester.enterText(realtime, 'wss://realtime.example.test/socket');
      await tester.tap(find.text('保存自定义'));
      await tester.pumpAndSettle();
      expect(
        (await AppConfigLoader.readOverride())?.wsBaseUrl,
        'wss://realtime.example.test/socket',
      );
    },
  );

  testWidgets(
    'editing media discards the old probe and keeps settings unsaved',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(900, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final config = AppConfig.fromCustom(apiBaseUrl: 'http://127.0.0.1:3000');
      final pending = <Completer<EndpointChecks>>[];
      final checked = <AppConfig>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigBundleProvider.overrideWithValue(
              AppConfigBundle(defaults: config, presets: const []),
            ),
            appConfigInitialProvider.overrideWithValue(config),
          ],
          child: MaterialApp(
            home: EndpointScreen(
              probe: (value) {
                checked.add(value);
                final request = Completer<EndpointChecks>();
                pending.add(request);
                return request.future;
              },
            ),
          ),
        ),
      );
      final button = find.text('检查 API 和媒体');
      await tester.tap(button);
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).at(2),
        'https://files.example.test/proxy',
      );
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      expect(checked.map((value) => value.storageBaseUrl), [
        'http://127.0.0.1:3000',
        'https://files.example.test/proxy',
      ]);
      pending.last.complete((
        api: EndpointReadiness.ready,
        media: EndpointReadiness.unavailable,
      ));
      await tester.pumpAndSettle();
      pending.first.complete((
        api: EndpointReadiness.ready,
        media: EndpointReadiness.ready,
      ));
      await tester.pumpAndSettle();
      expect(find.text('API 已就绪。'), findsOneWidget);
      expect(find.text('媒体服务暂不可用。'), findsOneWidget);
      expect(find.text('公开媒体可访问。'), findsNothing);
      expect(await AppConfigLoader.readOverride(), isNull);
    },
  );

  testWidgets('changing the API port updates only endpoints that follow it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final initial = AppConfig.fromCustom(
      apiBaseUrl: 'http://127.0.0.1:3000',
      storageBaseUrl: 'https://files.example.test',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(
            AppConfigBundle(defaults: initial, presets: const []),
          ),
          appConfigInitialProvider.overrideWithValue(initial),
        ],
        child: const MaterialApp(home: EndpointScreen()),
      ),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'http://127.0.0.1:30006');
    await tester.pump();
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'ws://127.0.0.1:30006',
    );
    expect(
      tester.widget<TextField>(fields.at(2)).controller!.text,
      'https://files.example.test',
    );
    await tester.tap(find.text('保存自定义'));
    await tester.pumpAndSettle();

    final saved = await AppConfigLoader.readOverride();
    expect(saved?.apiBaseUrl, 'http://127.0.0.1:30006');
    expect(saved?.wsBaseUrl, 'ws://127.0.0.1:30006');
    expect(saved?.storageBaseUrl, 'https://files.example.test');
  });
}

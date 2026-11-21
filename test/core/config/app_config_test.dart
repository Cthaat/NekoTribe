import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/constants/storage_keys.dart';
import 'package:nekotribe/core/storage/asset_url_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a failed save or reset leaves the persisted endpoint readable',
    () async {
      const channel = MethodChannel('plugins.flutter.io/shared_preferences');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final previous = AppConfig.fromCustom(
        apiBaseUrl: 'https://previous.example.test/app',
      );
      final next = AppConfig.fromCustom(
        apiBaseUrl: 'https://next.example.test/app',
      );
      final key = 'flutter.${StorageKeys.endpointOverride}';
      var stored = jsonEncode(previous.toJson());
      var allowWrite = false;
      SharedPreferences.resetStatic();
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getAll':
            return {key: stored};
          case 'setString':
            if (!allowWrite) return false;
            stored = call.arguments['value'] as String;
            return true;
          case 'remove':
            throw PlatformException(code: 'storage-unavailable');
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        SharedPreferences.resetStatic();
      });

      await expectLater(AppConfigLoader.writeOverride(next), throwsStateError);
      expect(
        (await AppConfigLoader.readOverride())?.apiBaseUrl,
        previous.apiBaseUrl,
      );
      await expectLater(
        AppConfigLoader.clearOverride(),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await AppConfigLoader.readOverride())?.apiBaseUrl,
        previous.apiBaseUrl,
      );
      allowWrite = true;
      await AppConfigLoader.writeOverride(next);
      expect(
        (await AppConfigLoader.readOverride())?.apiBaseUrl,
        next.apiBaseUrl,
      );
    },
  );

  test('startup ignores malformed persisted endpoint values', () async {
    final defaults = AppConfig.fromCustom(
      apiBaseUrl: 'https://default.example.test',
    );
    final bundle = AppConfigBundle(defaults: defaults, presets: const []);
    for (final stored in [
      {'apiBaseUrl': 'https://api.example.test?unexpected=1'},
      {
        'apiBaseUrl': 'https://api.example.test',
        'wsBaseUrl': 'https://ws.example.test',
      },
      {'storageBaseUrl': 'https://files.example.test'},
    ]) {
      SharedPreferences.setMockInitialValues({
        StorageKeys.endpointOverride: jsonEncode(stored),
      });
      expect(await AppConfigLoader.initialConfig(bundle), same(defaults));
    }
  });

  test('public media follows the shared storage address vectors', () {
    final suite =
        jsonDecode(
              File(
                'contracts/scenarios/storage-public-urls.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final cases = suite['clientCases'] as List<Object?>;
    for (final item in cases.cast<Map<String, Object?>>()) {
      final resolver = AssetUrlResolver(
        AppConfig.fromCustom(
          apiBaseUrl: 'https://api.example:3443/gateway',
          storageBaseUrl: item['useApiBase'] == true
              ? ''
              : 'https://cdn.example:8443/public/',
        ),
      );
      expect(
        resolver.resolve(item['input'] as String),
        item['expected'],
        reason: item['id'] as String,
      );
    }
  });

  test(
    'only remote insecure endpoints are rejected by secure browser transport',
    () {
      final httpsPage = Uri.parse('https://community.example.test/');
      for (final host in ['localhost', '127.0.0.2', '[::1]']) {
        final local = AppConfig.fromCustom(apiBaseUrl: 'http://$host:3000');
        expect(hasMixedEndpointTransport(local, httpsPage), isFalse);
      }
      final remote = AppConfig.fromCustom(
        apiBaseUrl: 'http://127.example.test:3000',
      );
      expect(hasMixedEndpointTransport(remote, httpsPage), isTrue);
      expect(
        hasMixedEndpointTransport(remote, Uri.parse('http://localhost/')),
        isFalse,
      );
      expect(hasMixedEndpointTransport(remote, null), isFalse);
    },
  );

  test('published asset defaults support a shared API origin', () {
    final defaults = AppConfigBundle.fromJson({
      'defaults': {
        'apiBaseUrl': 'https://example.test:3443',
        'storageBaseUrl': 'https://files.example.test',
      },
    }).defaults;

    expect(defaults.apiBaseUrl, 'https://example.test:3443');
    expect(defaults.wsBaseUrl, 'wss://example.test:3443');
    expect(defaults.storageBaseUrl, 'https://files.example.test');

    final shared = AppConfigBundle.fromJson({
      'defaults': {'apiBaseUrl': 'http://127.0.0.1:30006/gateway/'},
    }).defaults;
    expect(shared.apiBaseUrl, 'http://127.0.0.1:30006/gateway');
    expect(shared.wsBaseUrl, 'ws://127.0.0.1:30006/gateway');
    expect(shared.storageBaseUrl, 'http://127.0.0.1:30006/gateway');
  });

  test('a shared origin preserves its port for HTTP, realtime and files', () {
    for (final (address, api, websocket) in [
      (
        'http://127.0.0.1:30006/',
        'http://127.0.0.1:30006',
        'ws://127.0.0.1:30006',
      ),
      (
        'https://example.test:3443',
        'https://example.test:3443',
        'wss://example.test:3443',
      ),
      ('http://[::1]:30005', 'http://[::1]:30005', 'ws://[::1]:30005'),
    ]) {
      final config = AppConfig.fromOrigin(address);
      expect(config.apiBaseUrl, api);
      expect(config.wsBaseUrl, websocket);
      expect(config.storageBaseUrl, api);
    }
  });

  test(
    'a custom base derives missing addresses and preserves split services',
    () {
      final config = AppConfig.fromCustom(
        apiBaseUrl: ' https://api.example.test:3443/gateway/ ',
        storageBaseUrl: 'https://files.example.test/media/',
      );
      expect(config.apiBaseUrl, 'https://api.example.test:3443/gateway');
      expect(config.wsBaseUrl, 'wss://api.example.test:3443/gateway');
      expect(config.storageBaseUrl, 'https://files.example.test/media');
      expect(
        () => AppConfig.fromCustom(
          apiBaseUrl: 'https://api.example.test',
          wsBaseUrl: 'https://files.example.test',
        ),
        throwsFormatException,
      );
      expect(
        () => AppConfig.fromCustom(
          apiBaseUrl: 'https://api.example.test',
          storageBaseUrl: 'https://files.example.test?token=fixture',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'a shared address rejects non-HTTP schemes, credentials and suffixes',
    () {
      for (final address in [
        'ws://example.test',
        'https://user:secret@example.test',
        'http://example.test:0',
        'http://example.test:65536',
        'https://example.test/api/v2',
        'https://example.test?token=fixture',
        'https://example.test#fragment',
      ]) {
        expect(() => AppConfig.fromOrigin(address), throwsFormatException);
      }
    },
  );
}

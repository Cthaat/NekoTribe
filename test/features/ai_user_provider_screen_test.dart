import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/ai/data/ai_user_provider_api.dart';
import 'package:nekotribe/features/users/presentation/ai_provider_settings_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

const _path = '/api/v2/users/me/ai-provider';
const _keyField = Key('ai-provider-api-key');
const _modelField = Key('ai-provider-model');
const _draftKey = 'fixture-key-for-offline-test';
final _activeApi = StateProvider<AiUserProviderApi>(
  (_) => throw StateError('Test API was not installed'),
);

void main() {
  testWidgets(
    'saves a preset, tests the saved disabled connection and removes it',
    (tester) async {
      final server = _Backend();
      await _mount(tester, server, _Tokens());
      expect(find.text('仅用于本人的 AI 写作。'), findsOneWidget);
      expect(find.text('https://api.openai.com/v1'), findsOneWidget);
      final input = find.byKey(_keyField);
      expect(tester.widget<TextField>(input).obscureText, isTrue);
      await tester.enterText(input, 'fixture-key-for-other-preset');
      final picker = find.byType(DropdownButton<AiProviderPresetId>);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('管理员预设').last);
      await tester.pumpAndSettle();
      expect(find.text('https://provider.example.test/v1'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);

      await tester.enterText(find.byKey(_modelField), 'draft-model/v2');
      await tester.enterText(input, _draftKey);
      await tester.pump();
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(server.requests.last.method, 'PUT');
      expect(server.requests.last.path, _path);
      expect(server.requests.last.data, {
        'preset': 'provided',
        'model': 'draft-model/v2',
        'enabled': false,
        'api_key': _draftKey,
      });
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(find.text(_draftKey), findsNothing);

      final test = find.text('试连已保存的配置');
      await tester.ensureVisible(test);
      await tester.tap(test);
      await tester.pumpAndSettle();
      expect(server.requests.last.method, 'POST');
      expect(server.requests.last.path, '$_path/test');
      expect(server.requests.last.data, isNull);
      expect(find.text('连接验证成功。'), findsOneWidget);

      final enable = find.text('在个人 AI 写作中启用');
      await tester.ensureVisible(enable);
      await tester.tap(enable);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(server.requests.last.method, 'PUT');
      expect(server.requests.last.data, {
        'preset': 'provided',
        'model': 'draft-model/v2',
        'enabled': true,
      });
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);

      final remove = find.text('移除连接');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(server.requests.last.method, 'PUT');
      await tester.tap(find.text('确认移除'));
      await tester.pumpAndSettle();
      expect(server.requests.last.method, 'DELETE');
      expect(server.requests.last.path, _path);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(find.text('连接已移除。'), findsOneWidget);
    },
  );

  testWidgets('a session change clears an unsent key and saved metadata', (
    tester,
  ) async {
    final server = _Backend()..config = _savedConfig;
    final tokens = _Tokens();
    await _mount(tester, server, tokens);
    final input = find.byKey(_keyField);
    final oldField = tester.widget<TextField>(input).controller!;
    expect(oldField.text, isEmpty);
    await tester.enterText(input, _draftKey);
    tokens.beginSessionChange();
    await tester.pumpAndSettle();
    expect(oldField.text, isEmpty);
    expect(input, findsNothing);
    expect(find.text('stored-model'), findsNothing);
    expect(server.requests.map((request) => request.method), ['GET']);
  });

  testWidgets('changing backends cancels a save and ignores its old receipt', (
    tester,
  ) async {
    final previous = _Backend()..config = _savedConfig;
    final tokens = _Tokens();
    final container = await _mount(tester, previous, tokens);
    final input = find.byKey(_keyField);
    final field = tester.widget<TextField>(input).controller!;
    await tester.enterText(input, _draftKey);
    final pending = previous.pendingSave = Completer<ResponseBody>();
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(previous.requests.last.method, 'PUT');
    expect(field.text, isEmpty);

    final next = _Backend();
    container.read(_activeApi.notifier).state = _api(next, tokens);
    await tester.pump();
    pending.complete(previous.ok(previous.settings));
    await tester.pumpAndSettle();
    expect(previous.cancelled, isTrue);
    expect(input, findsNothing);
    expect(find.text('stored-model'), findsNothing);
    expect(next.requests, isEmpty);
  });

  test('rejects a metadata response that tries to echo an API key', () async {
    final server = _Backend()..config = {..._savedConfig, 'api_key': _draftKey};
    await expectLater(
      _api(server, _Tokens()).getSettings(CancelToken()),
      throwsFormatException,
    );
  });

  testWidgets(
    'reports unavailable setup and keeps connection inputs disabled',
    (tester) async {
      final server = _Backend()..setupAvailable = false;
      await _mount(tester, server, _Tokens());
      expect(find.text('当前部署暂未开放个人 AI 服务配置。'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_keyField)).enabled, isFalse);
      expect(
        tester.widget<TextField>(find.byKey(_modelField)).enabled,
        isFalse,
      );
      expect(server.requests.map((request) => request.method), ['GET']);
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Backend server,
  _Tokens tokens,
) async {
  final api = _api(server, tokens);
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(tokens),
      authSessionProvider.overrideWith(
        (_) => AuthSessionController(tokens)..markLoggedIn(),
      ),
      _activeApi.overrideWith((_) => api),
      aiUserProviderApiProvider.overrideWith((ref) => ref.watch(_activeApi)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AiProviderSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

AiUserProviderApi _api(_Backend server, _Tokens tokens) {
  final client = ApiClient(
    config: const AppConfig(
      apiBaseUrl: 'http://example.test',
      wsBaseUrl: 'ws://example.test',
      storageBaseUrl: 'http://example.test',
    ),
    tokenStore: tokens,
    dio: Dio()..httpClientAdapter = server,
  );
  addTearDown(client.dispose);
  return AiUserProviderApi(client);
}

class _Tokens extends TokenStore {
  @override
  Future<TokenPair?> read() async => const TokenPair(
    accessToken: 'fixture-access',
    refreshToken: 'fixture-refresh',
    sessionId: 'fixture-session',
  );

  @override
  Future<String> deviceFingerprint() async => 'widget-test';
}

const _savedConfig = <String, Object?>{
  'preset': 'default',
  'model': 'stored-model',
  'enabled': false,
  'key_configured': true,
  'revision': 1,
  'reconnect_required': false,
};

class _Backend implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Map<String, Object?>? config;
  Completer<ResponseBody>? pendingSave;
  bool cancelled = false;
  bool setupAvailable = true;

  Map<String, Object?> get settings => {
    'setup_available': setupAvailable,
    'presets': [
      {'id': 'default', 'base_url': 'https://api.openai.com/v1'},
      {'id': 'provided', 'base_url': 'https://provider.example.test/v1'},
    ],
    'config': config,
  };

  ResponseBody ok(Object? data) => ResponseBody.fromString(
    jsonEncode({'code': 200, 'message': 'success', 'data': data, 'meta': null}),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    switch ((options.method, options.path)) {
      case ('GET', _path):
        return ok(settings);
      case ('PUT', _path):
        if (pendingSave case final pending?) {
          unawaited(cancelFuture?.then((_) => cancelled = true));
          return pending.future;
        }
        final body = options.data as Map<String, Object?>;
        config = {
          'preset': body['preset'],
          'model': body['model'],
          'enabled': body['enabled'],
          'key_configured': true,
          'revision': 2,
          'reconnect_required': false,
        };
        return ok(settings);
      case ('POST', '$_path/test'):
        return ok({'verified': true});
      case ('DELETE', _path):
        config = null;
        return ok(null);
      default:
        throw StateError('Unexpected fixture request');
    }
  }

  @override
  void close({bool force = false}) {}
}

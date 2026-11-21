import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/ai/data/ai_moderation_advice_api.dart';
import 'package:nekotribe/features/ai/data/moderation_rule_catalog.dart';
import 'package:nekotribe/features/ai/presentation/moderation_advice_dialog.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

import 'fixtures/ai_availability.dart';

const _base = '/api/v2/ai/conversations';
const _id = 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';
const _other = 'e7dd4d7f-8462-45b6-9bf4-a630d0ba7478';
const _secondary = 'f9d50a00-e8bd-46bd-acb3-83d9a901fc6a';
const _generate = '$_base/$_id/moderation-generate';
const _ruleVersion =
    '3a7170bf3109f8c035b08fe850eb15d5591f1342ee956ceef19c98d07e7cc93f';
const _reason = 'Possible repeated solicitation';
final _testClient = StateProvider<ApiClient>(
  (ref) => throw StateError('Expected a test API client'),
);

class _Session extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<String> deviceFingerprint() async => 'widget-test';
}

String _messageId(int sequence) =>
    '2625acec-6d03-42ee-92f5-${sequence.toString().padLeft(12, '0')}';

String _ratingPath(String conversation, int sequence) =>
    '$_base/$conversation/messages/${_messageId(sequence)}/moderation-feedback';

Finder _ratingChip(int sequence, String rating) =>
    find.byKey(ValueKey('rating-${_messageId(sequence)}-$rating'));

class _Backend implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final ratings = <String, String>{};
  bool invalidated = false, conflict = false, sawCancellation = false;
  bool historyUnavailable = false;
  bool multiple = false, wrongReceipt = false;
  bool deleted = false;
  bool withSkills = false;
  bool explicitModeration = false;
  int? feedbackError;
  int sequence = 1;
  bool legacyHistory = false;
  bool trailingUserMessage = false;
  Completer<ResponseBody>? pending;
  Completer<ResponseBody>? pendingFeedback;

  ResponseBody ok(Object? data, {int status = 200}) => ResponseBody.fromString(
    jsonEncode({'code': status, 'message': 'test', 'data': data, 'meta': null}),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  Map<String, Object?> _conversation(String id, String title) => {
    'conversation_id': id,
    'purpose': 'moderation',
    'group_id': null,
    'title': title,
  };

  Map<String, Object?> _message(
    int currentSequence, {
    String conversation = _id,
  }) => {
    'conversation_id': conversation,
    'message_id': _messageId(currentSequence),
    'sequence_no': currentSequence,
    'role': trailingUserMessage && currentSequence == sequence
        ? 'user'
        : 'assistant',
    'created_at':
        '2026-11-17T12:00:${currentSequence.toString().padLeft(2, '0')}Z',
    'content': 'Never show raw fallback',
    if (ratings[_messageId(currentSequence)] case final rating?)
      'moderation_feedback': rating,
    'moderation_advice': invalidated
        ? null
        : {
            'risk': 'spam',
            'reason': _reason,
            'recommendation': 'human_review',
            'target': {
              'kind': 'group_post_comment',
              'id': 17,
              'post_id': 27,
              'group_id': 7,
            },
            'rule_ids': [7, 6],
            'rules': [
              {'kind': 'terms', 'id': 6, 'version': _ruleVersion},
              {'kind': 'terms', 'id': 7, 'version': _ruleVersion},
            ],
          },
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    switch (request.path) {
      case '/api/v2/ai/availability':
        return ok(
          withSkills
              ? aiAvailabilityFixture(
                  explicitModeration: explicitModeration,
                  modelConfigRevision: 9,
                )
              : {'knowledge': true, 'writing': true, 'moderation': true},
        );
      case _base:
        return ok({
          'items': [
            _conversation(_other, 'moderation:post:17'),
            if (!deleted)
              _conversation(_id, 'moderation:group_post_comment:17'),
            if (multiple)
              _conversation(_secondary, 'moderation:group_post_comment:17'),
          ],
          'next_cursor': null,
        });
      case '$_base/$_id/messages':
        if (deleted) return ok(null, status: 404);
        if (historyUnavailable) throw StateError('History offline');
        final before = legacyHistory
            ? null
            : request.queryParameters['before_sequence'] as int?;
        final after = request.queryParameters['after_sequence'] as int? ?? 0;
        final limit = request.queryParameters['limit'] as int;
        final rows = [
          for (var index = after + 1; index <= sequence; index++)
            if (before == null || index < before) _message(index),
        ];
        return ok(
          before != null && rows.length > limit
              ? rows.sublist(rows.length - limit)
              : rows.take(limit).toList(),
        );
      case '$_base/$_id' when request.method == 'DELETE':
        deleted = true;
        return ok(null);
      case '$_base/$_secondary' when request.method == 'DELETE':
        multiple = false;
        return ok(null);
      case '$_base/$_secondary/messages':
        final before = request.queryParameters['before_sequence'] as int?;
        final after = request.queryParameters['after_sequence'] as int?;
        return ok([
          if ((before == null || before > 9) && (after == null || after < 9))
            _message(9, conversation: _secondary),
        ]);
      case _generate:
        final waiting = pending;
        if (waiting != null) {
          unawaited(cancelFuture?.then((_) => sawCancellation = true));
          return waiting.future;
        }
        return conflict
            ? ok(null, status: 409)
            : ok({'status': 'generated', 'message': _message(++sequence)});
      default:
        if (request.method == 'PUT' &&
            request.path.endsWith('/moderation-feedback')) {
          final waiting = pendingFeedback;
          if (waiting != null) {
            unawaited(cancelFuture?.then((_) => sawCancellation = true));
            return waiting.future;
          }
          final failure = feedbackError;
          if (failure != null) return ok(null, status: failure);
          final segments = Uri.parse(request.path).pathSegments;
          final message = segments[segments.length - 2];
          final rating = (request.data as Map<String, Object?>)['rating'];
          if (rating is! String) throw StateError('Missing rating');
          ratings[message] = rating;
          return ok({
            'message_id': wrongReceipt ? _messageId(42) : message,
            'rating': rating,
          });
        }
        throw StateError('Unexpected request: ${request.path}');
    }
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _client(_Backend backend, _Session session) => ApiClient(
  config: const AppConfig(
    apiBaseUrl: 'http://example.test',
    wsBaseUrl: 'ws://example.test',
    storageBaseUrl: 'http://example.test',
  ),
  tokenStore: session,
  dio: Dio()..httpClientAdapter = backend,
);

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Backend backend,
  _Session session,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final client = _client(backend, session);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(session),
        _testClient.overrideWith((ref) => client),
        apiClientProvider.overrideWith((ref) => ref.watch(_testClient)),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supported,
        home: Scaffold(
          body: Column(
            children: [
              ModerationAdviceButton(kind: 'group_comment', targetId: 17),
              ModerationAdviceButton(kind: 'user', targetId: 17),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('AI review assistant'), findsOneWidget);
  expect(backend.requests, isEmpty);
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ModerationAdviceButton).first),
  );
  await tester.tap(find.text('AI review assistant'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'a reviewed group comment opens its exact source and preserves the advice',
    (tester) async {
      final backend = _Backend();
      final session = _Session();
      final client = _client(backend, session);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: ModerationAdviceButton(kind: 'group_comment', targetId: 17),
            ),
          ),
          GoRoute(
            path: '/groups/posts',
            builder: (_, state) =>
                Scaffold(body: Text(state.uri.queryParameters.toString())),
          ),
        ],
      );
      addTearDown(router.dispose);
      addTearDown(client.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(session),
            apiClientProvider.overrideWithValue(client),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('en'),
            localizationsDelegates: const [AppLocalizationsDelegate()],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI review assistant'));
      await tester.pumpAndSettle();
      final source = find.text('Open reviewed content');
      await tester.ensureVisible(source);
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(find.text('{group: 7, post: 27, comment: 17}'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text(_reason), findsOneWidget);
      expect(
        backend.requests.where((request) => request.method != 'GET'),
        isEmpty,
      );
    },
  );

  test(
    'moderation history reads the newest page and keeps the raw sequence when loading older suggestions',
    () async {
      final backend = _Backend()
        ..sequence = 53
        ..invalidated = true;
      final api = AiModerationAdviceApi(_client(backend, _Session()));
      const target = (kind: 'group_post_comment', id: 17);
      final first = await api.history(target, CancelToken());
      expect(first.messages.length, 50);
      expect(first.messages.first.id, _messageId(53));
      expect(first.messages.first.advice, isNull);
      expect(first.sequence, 53);
      expect(first.older, {_id: (before: 4, forwardOnly: false)});
      expect(backend.requests.last.queryParameters, {
        'before_sequence': 10000000000,
        'limit': 50,
      });
      final expanded = await api.older(first, target, CancelToken());
      expect(expanded.messages.last.id, _messageId(1));
      expect(expanded.sequence, 53);
      expect(expanded.older, isEmpty);
      expect(backend.requests.last.queryParameters, {
        'before_sequence': 4,
        'limit': 50,
      });
    },
  );

  test(
    'old moderation backend pages by raw sequence, including user messages',
    () async {
      final backend = _Backend()
        ..sequence = 53
        ..legacyHistory = true
        ..trailingUserMessage = true;
      final api = AiModerationAdviceApi(_client(backend, _Session()));
      const target = (kind: 'group_post_comment', id: 17);
      final first = await api.history(target, CancelToken());
      expect(first.messages.length, 49);
      expect(first.messages.first.id, _messageId(52));
      expect(first.messages.last.id, _messageId(4));
      expect(first.sequence, 53);
      expect(first.older, {_id: (before: 4, forwardOnly: true)});
      final expanded = await api.older(first, target, CancelToken());
      expect(expanded.messages.length, 52);
      expect(expanded.messages.last.id, _messageId(1));
      expect(expanded.sequence, 53);
      expect(expanded.older, isEmpty);
      expect(backend.requests.last.queryParameters, {
        'after_sequence': 0,
        'limit': 50,
      });
    },
  );

  test('older history drops a deleted session and keeps the remaining generation sequence', () async {
    final backend = _Backend()
      ..sequence = 53
      ..multiple = true;
    final api = AiModerationAdviceApi(_client(backend, _Session()));
    const target = (kind: 'group_post_comment', id: 17);
    final first = await api.history(target, CancelToken());
    expect(first.conversationId, _id);
    expect(first.messages.length, 51);
    backend.deleted = true;
    final expanded = await api.older(first, target, CancelToken());
    expect(expanded.messages.single.conversationId, _secondary);
    expect(expanded.conversationId, _secondary);
    expect(expanded.sequence, 9);
    expect(expanded.older, isEmpty);
  });

  testWidgets('saved advice is recovered by refreshing history', (
    tester,
  ) async {
    final backend = _Backend();
    await _mount(tester, backend, _Session());
    backend.historyUnavailable = true;
    await tester.tap(find.text('Generate advice'));
    await tester.pumpAndSettle();
    expect(
      find.text('The advice was saved. Refresh history to view it.'),
      findsOneWidget,
    );
    backend.historyUnavailable = false;
    await tester.tap(find.text('Refresh history'));
    await tester.pumpAndSettle();
    expect(find.text(_reason), findsWidgets);
    expect(
      backend.requests.where((request) => request.path == _generate),
      hasLength(1),
    );
  });

  testWidgets('removes only the confirmed current AI conversation', (
    tester,
  ) async {
    final backend = _Backend()..multiple = true;
    await _mount(tester, backend, _Session());
    final delete = find.text('Delete current AI conversation');
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(
      backend.requests.where((request) => request.method == 'DELETE'),
      isEmpty,
    );
    await tester.tap(find.text('Confirm conversation deletion'));
    await tester.pumpAndSettle();
    expect(
      backend.requests
          .where((request) => request.method == 'DELETE')
          .map((request) => request.path),
      ['$_base/$_id'],
    );
    expect(find.text('AI conversation deleted.'), findsOneWidget);
    expect(find.text(_reason), findsOneWidget);
    expect(_ratingChip(1, 'helpful'), findsNothing);
    expect(_ratingChip(9, 'helpful'), findsOneWidget);
  });

  testWidgets('removes the selected historical AI conversation only', (
    tester,
  ) async {
    final backend = _Backend()..multiple = true;
    await _mount(tester, backend, _Session());
    await tester.tap(find.text('Delete this advice’s conversation'));
    await tester.pumpAndSettle();
    expect(
      find.text('Delete all advice and ratings in the selected conversation?'),
      findsOneWidget,
    );
    expect(
      backend.requests.where((request) => request.method == 'DELETE'),
      isEmpty,
    );
    await tester.tap(find.text('Confirm conversation deletion'));
    await tester.pumpAndSettle();
    expect(
      backend.requests
          .where((request) => request.method == 'DELETE')
          .map((request) => request.path),
      ['$_base/$_secondary'],
    );
    expect(_ratingChip(1, 'helpful'), findsOneWidget);
    expect(_ratingChip(9, 'helpful'), findsNothing);
  });

  testWidgets(
    'changing backends cancels a rating and clears the original history',
    (tester) async {
      final firstBackend = _Backend()..withSkills = true,
          nextBackend = _Backend(),
          session = _Session();
      final container = await _mount(tester, firstBackend, session);
      final skill = find.text('Skill · Moderation advice · v3 · Enabled');
      expect(skill, findsOneWidget);
      final revision = find.text('Current model configuration revision 9');
      expect(revision, findsOneWidget);
      expect(find.text('Explicitly use this skill'), findsNothing);
      final pending = firstBackend.pendingFeedback = Completer<ResponseBody>();
      final helpful = _ratingChip(1, 'helpful');
      await tester.ensureVisible(helpful);
      await tester.tap(helpful);
      await tester.pump(const Duration(milliseconds: 50));
      final request = firstBackend.requests.last;
      expect(request.path, _ratingPath(_id, 1));
      container.read(_testClient.notifier).state = _client(
        nextBackend,
        session,
      );
      await tester.pump();
      pending.complete(
        firstBackend.ok({'message_id': _messageId(1), 'rating': 'helpful'}),
      );
      await tester.pumpAndSettle();
      expect(firstBackend.sawCancellation, isTrue);
      expect(firstBackend.requests.last, same(request));
      expect(nextBackend.requests, isEmpty);
      expect(helpful, findsNothing);
      expect(skill, findsNothing);
      expect(revision, findsNothing);
    },
  );

  testWidgets('sends the explicit moderation skill only when chosen', (
    tester,
  ) async {
    final backend = _Backend()
      ..withSkills = true
      ..explicitModeration = true;
    await _mount(tester, backend, _Session());
    final choice = find.text('Explicitly use this skill');
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    final generate = find.text('Generate advice');
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    final call = backend.requests.singleWhere(
      (request) => request.path == _generate,
    );
    expect(call.data['skill_id'], 'moderation-advice');
  });

  testWidgets('rates merged advice via its originating conversation', (
    tester,
  ) async {
    final backend = _Backend()..multiple = true;
    backend.ratings[_messageId(9)] = 'helpful';
    await _mount(tester, backend, _Session());
    final helpful = _ratingChip(9, 'helpful');
    final incorrect = _ratingChip(9, 'incorrect');
    expect(tester.widget<ChoiceChip>(helpful).selected, isTrue);
    await tester.ensureVisible(helpful);
    await tester.tap(helpful);
    await tester.pumpAndSettle();
    expect(
      backend.requests.where((request) => request.method == 'PUT'),
      isEmpty,
    );
    await tester.ensureVisible(incorrect);
    await tester.tap(incorrect);
    await tester.pumpAndSettle();
    final saved = backend.requests
        .where((request) => request.method == 'PUT')
        .single;
    expect(saved.path, _ratingPath(_secondary, 9));
    expect(saved.data, {'rating': 'incorrect'});
    expect(tester.widget<ChoiceChip>(incorrect).selected, isTrue);
    expect(find.text('Rating saved.'), findsOneWidget);
    backend.invalidated = true;
    await tester.ensureVisible(find.text('Refresh history'));
    await tester.tap(find.text('Refresh history'));
    await tester.pumpAndSettle();
    expect(incorrect, findsNothing);
  });

  testWidgets('ratings on older advice keep the opened messages visible', (
    tester,
  ) async {
    final backend = _Backend()..sequence = 51;
    await _mount(tester, backend, _Session());
    final older = find.text('Load older messages');
    await tester.ensureVisible(older);
    await tester.tap(older);
    await tester.pumpAndSettle();
    final helpful = _ratingChip(1, 'helpful');
    await tester.ensureVisible(helpful);
    await tester.tap(helpful);
    await tester.pumpAndSettle();

    expect(
      backend.requests[backend.requests.length - 2].path,
      _ratingPath(_id, 1),
    );
    expect(backend.requests.last.queryParameters, {
      'after_sequence': 0,
      'limit': 1,
    });
    expect(tester.widget<ChoiceChip>(helpful).selected, isTrue);
    expect(_ratingChip(51, 'helpful'), findsOneWidget);
  });

  testWidgets(
    'reloads committed ratings after an invalid receipt and hides redacted advice after conflict',
    (tester) async {
      final backend = _Backend()..wrongReceipt = true;
      await _mount(tester, backend, _Session());
      final helpful = _ratingChip(1, 'helpful');
      await tester.ensureVisible(helpful);
      await tester.tap(helpful);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not confirm the rating'),
        findsOneWidget,
      );
      expect(helpful, findsNothing);
      expect(
        backend.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
      await tester.tap(find.text('Refresh history'));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(helpful).selected, isTrue);
      backend.feedbackError = 409;
      backend.invalidated = true;
      final insufficient = _ratingChip(1, 'insufficient');
      await tester.ensureVisible(insufficient);
      await tester.tap(insufficient);
      await tester.pumpAndSettle();
      expect(find.textContaining('history changed'), findsOneWidget);
      await tester.tap(find.text('Refresh history'));
      await tester.pumpAndSettle();
      expect(find.textContaining('evidence or rules changed'), findsOneWidget);
      expect(helpful, findsNothing);
    },
  );

  testWidgets(
    'cancels rating and suppresses a late receipt after changing accounts',
    (tester) async {
      final backend = _Backend(), session = _Session();
      await _mount(tester, backend, session);
      final pending = backend.pendingFeedback = Completer<ResponseBody>();
      final helpful = _ratingChip(1, 'helpful');
      await tester.ensureVisible(helpful);
      await tester.tap(helpful);
      await tester.pump(const Duration(milliseconds: 50));
      final request = backend.requests.last;
      expect(request.path, _ratingPath(_id, 1));
      expect(request.method, 'PUT');
      expect(tester.widget<ChoiceChip>(helpful).onSelected, isNull);
      session.beginSessionChange();
      pending.complete(
        backend.ok({'message_id': _messageId(1), 'rating': 'helpful'}),
      );
      await tester.pumpAndSettle();
      expect(backend.sawCancellation, isTrue);
      expect(backend.requests.last, same(request));
      expect(find.textContaining('session changed'), findsOneWidget);
      expect(helpful, findsNothing);
    },
  );

  testWidgets(
    'advises the selected group comment without sending a case action',
    (tester) async {
      final backend = _Backend();
      await _mount(tester, backend, _Session());
      expect(find.text(_reason), findsOneWidget);
      expect(
        backend.requests.any((request) => request.path.contains(_other)),
        isFalse,
      );
      await tester.tap(find.text('Generate advice'));
      await tester.pumpAndSettle();
      expect(find.text(_reason), findsNWidgets(2));
      final writes = backend.requests.where(
        (request) => request.method != 'GET',
      );
      expect(writes.map((request) => request.path), [_generate]);
      expect(writes.single.data, {
        'target_type': 'group_post_comment',
        'target_id': 17,
        'locale': 'en',
        'expected_sequence': 1,
      });
      backend.invalidated = true;
      await tester.tap(find.text('Refresh history'));
      await tester.pumpAndSettle();
      expect(find.text(_reason), findsNothing);
      expect(find.text('Never show raw fallback'), findsNothing);
      expect(
        find.textContaining('evidence or rules changed'),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restores history after a sequence conflict without retrying the write',
    (tester) async {
      final backend = _Backend()..conflict = true;
      await _mount(tester, backend, _Session());
      await tester.tap(find.text('Generate advice'));
      await tester.pumpAndSettle();
      expect(find.textContaining('history changed'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Generate advice'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Refresh history'));
      await tester.pumpAndSettle();
      expect(find.text(_reason), findsOneWidget);
      expect(
        backend.requests.where((request) => request.path == _generate),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'stopping advice requires refreshing the target history before generation',
    (tester) async {
      final backend = _Backend(), session = _Session();
      await _mount(tester, backend, session);
      final pending = backend.pending = Completer<ResponseBody>();
      await tester.tap(find.text('Generate advice'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('moderation-advice-stop')));
      await tester.pumpAndSettle();
      expect(backend.sawCancellation, isTrue);
      expect(find.textContaining('Stopped waiting for advice'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Generate advice'),
            )
            .onPressed,
        isNull,
      );
      pending.complete(
        backend.ok({'status': 'insufficient_evidence', 'message': null}),
      );
      await tester.pumpAndSettle();
      expect(backend.requests.last.path, _generate);
      await tester.tap(find.text('Refresh history'));
      await tester.pumpAndSettle();
      expect(find.text(_reason), findsOneWidget);
      expect(
        backend.requests.where((request) => request.path == _generate),
        hasLength(1),
      );
    },
  );

  testWidgets('cancels generation and clears advice when the account changes', (
    tester,
  ) async {
    final backend = _Backend(), session = _Session();
    await _mount(tester, backend, session);
    final pending = backend.pending = Completer<ResponseBody>();
    await tester.tap(find.text('Generate advice'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      backend.requests.where((request) => request.path == _generate),
      hasLength(1),
    );
    session.beginSessionChange();
    pending.complete(
      backend.ok({'status': 'insufficient_evidence', 'message': null}),
    );
    await tester.pumpAndSettle();
    expect(backend.sawCancellation, isTrue);
    expect(backend.requests.last.path, _generate);
    expect(find.text(_reason), findsNothing);
    expect(find.textContaining('session changed'), findsOneWidget);
  });

  testWidgets(
    'only resolves the bundled rule when the exact reference version matches',
    (tester) async {
      final result = await tester.runAsync(
        () => readModerationRule((id: 7, version: _ruleVersion)),
      );
      expect(result?.title, '3. User Conduct');
      expect(result?.blocks.length, 5);
      final wrong = await tester.runAsync(
        () => readModerationRule((id: 6, version: _ruleVersion)),
      );
      expect(wrong, isNull);
    },
  );
}

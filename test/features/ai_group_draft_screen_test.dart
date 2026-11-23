import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/features/ai/data/ai_writing_api.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/ai/data/ai_group_draft_api.dart';
import 'package:nekotribe/features/ai/presentation/ai_group_draft_screen.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

import 'fixtures/ai_availability.dart';

const _id = 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';
const _other = 'e7dd4d7f-8462-45b6-9bf4-a630d0ba7478';
const _conversations = '/api/v2/ai/conversations';
const _generate = '$_conversations/$_id/group-generate';
const _posts = '/api/v2/groups/7/posts';

class _Session extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<String> deviceFingerprint() async => 'widget-test';
}

class _Backend implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool generated = false, sourceHidden = false, private = false;
  bool historyUnavailable = false, historyMissing = false;
  bool invalidHistoryCursor = false;
  bool duplicateHistoryMessage = false;
  String role = 'admin';
  Object? groupActive = 1;
  Completer<ResponseBody>? pending;
  Completer<ResponseBody>? pendingPublication;
  bool sawCancellation = false;
  int? retryAfter;
  bool groupInference = true;
  bool withSkills = false;
  bool invalidPostReceipt = false;
  int? historySize;
  bool legacyHistory = false;
  List<String>? draftTools;

  ResponseBody ok(Object? data) => ResponseBody.fromString(
    jsonEncode({'code': 200, 'message': 'success', 'data': data, 'meta': null}),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
  ResponseBody generatedReply() => ResponseBody.fromString(
    'event: done\ndata: ${jsonEncode({'code': 200, 'data': receipt})}\n\n',
    200,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );
  Map<String, Object?> conversation(String id, int group, String title) => {
    'conversation_id': id,
    'purpose': 'group',
    'group_id': group,
    'title': title,
    'updated_at': '2026-11-17',
  };
  Map<String, Object?> get receipt => {
    'status': 'generated',
    'message': {
      'conversation_id': _id,
      'message_id': 'draft',
      'sequence_no': 1,
      'role': 'assistant',
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
        return ok({
          'knowledge': true,
          'writing': true,
          'group': true,
          'moderation': true,
          if (withSkills) 'skills': aiAvailabilityFixture()['skills'],
          if (withSkills) 'model_config_revision': 8,
          'inference': {
            'knowledge': true,
            'writing': true,
            'group': groupInference,
            'moderation': true,
          },
        });
      case '/api/v2/groups/by-slug/test-group':
        return ok({
          'group_id': 7,
          'slug': 'test-group',
          'name': 'Example',
          'privacy': private ? 'private' : 'public',
          if (groupActive != null) 'is_active': groupActive,
          'membership': {'role': role, 'status': 'active', 'is_member': true},
        });
      case _conversations:
        if (request.method == 'POST') return ok(conversation(_id, 7, 'Weekly'));
        return ok({
          'items': [
            conversation(_other, 8, 'Other group'),
            conversation(_id, 7, 'Weekly'),
          ],
          'next_cursor': invalidHistoryCursor ? _other : null,
        });
      case _generate:
        if (pending != null) {
          unawaited(cancelFuture?.then((_) => sawCancellation = true));
          return pending!.future;
        }
        final seconds = retryAfter;
        if (seconds != null) {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 42901,
              'message': 'Limited',
              'data': null,
              'meta': null,
            }),
            429,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
              'retry-after': ['$seconds'],
            },
          );
        }
        generated = true;
        return generatedReply();
      case '$_conversations/$_id/messages':
        if (historyMissing) return ResponseBody.fromString('{"code":404}', 404);
        if (historyUnavailable) throw StateError('History offline');
        if (historySize case final size?) {
          final before = legacyHistory
              ? null
              : request.queryParameters['before_sequence'] as int?;
          final after = request.queryParameters['after_sequence'] as int? ?? 0;
          final limit = request.queryParameters['limit'] as int;
          final rows = [
            for (var sequence = 1; sequence <= size; sequence++)
              if (sequence > after && (before == null || sequence < before))
                {
                  'conversation_id': _id,
                  'message_id': duplicateHistoryMessage ? 'same' : 'm$sequence',
                  'sequence_no': sequence,
                  'role': sequence == 1 || sequence == size
                      ? 'assistant'
                      : 'user',
                  'content': 'Draft sequence $sequence.',
                  'group_sources': [
                    {'kind': 'post', 'source_id': 24, 'post_id': 24},
                  ],
                },
          ];
          return ok(
            before != null && rows.length > limit
                ? rows.sublist(rows.length - limit)
                : rows.take(limit).toList(),
          );
        }
        return ok(
          generated
              ? [
                  {
                    'message_id': 'draft',
                    'conversation_id': _id,
                    'sequence_no': 1,
                    'role': 'assistant',
                    'content': 'Draft for review',
                    'group_sources': sourceHidden
                        ? []
                        : [
                            {'kind': 'post', 'source_id': 24, 'post_id': 24},
                          ],
                    if (!sourceHidden && draftTools != null)
                      'group_tools': draftTools,
                  },
                ]
              : [],
        );
      case _posts:
        if (pendingPublication case final pending?) {
          unawaited(cancelFuture?.then((_) => sawCancellation = true));
          return pending.future;
        }
        final body = request.data as Map<String, Object?>;
        final announcement = body['is_announcement'] == true;
        return ok({
          'post_id': 25,
          'group_id': 7,
          'is_announcement': invalidPostReceipt ? !announcement : announcement,
        });
      case '$_conversations/$_id':
        if (request.method == 'DELETE') return ok(null);
        throw StateError('Unexpected conversation request');
      default:
        throw StateError('Unexpected request: ${request.path}');
    }
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _mount(
  WidgetTester tester,
  _Backend backend,
  _Session session,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final client = ApiClient(
    config: const AppConfig(
      apiBaseUrl: 'http://example.test',
      wsBaseUrl: 'ws://example.test',
      storageBaseUrl: 'http://example.test',
    ),
    tokenStore: session,
    dio: Dio()..httpClientAdapter = backend,
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) =>
            const AiGroupDraftScreen(groupId: 7, slug: 'test-group'),
      ),
      GoRoute(
        path: '/groups/:slug',
        builder: (_, state) =>
            Scaffold(body: Text('Group feed: ${state.pathParameters['slug']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(session),
        aiGroupDraftApiProvider.overrideWithValue(AiGroupDraftApi(client)),
        aiWritingApiProvider.overrideWithValue(AiWritingApi(client)),
        groupsApiProvider.overrideWithValue(GroupsApi(client)),
      ],
      child: MaterialApp.router(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supported,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('restores all three authorized tools in saved group drafts', (
    tester,
  ) async {
    final backend = _Backend()
      ..generated = true
      ..draftTools = [
        'public_search',
        'public_statistics',
        'community_sentiment_summary',
      ];
    await _mount(tester, backend, _Session());
    await tester.ensureVisible(find.text('Weekly'));
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    expect(find.text('Draft for review'), findsOneWidget);
    expect(
      find.textContaining('Summarize community sentiment'),
      findsOneWidget,
    );
  });

  testWidgets('group draft history retries an invalid cursor', (tester) async {
    final backend = _Backend()..invalidHistoryCursor = true;
    await _mount(tester, backend, _Session());
    expect(find.text('Weekly'), findsNothing);
    backend.invalidHistoryCursor = false;
    await tester.tap(find.byKey(const Key('group-draft-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Other group'), findsNothing);
  });

  testWidgets('group draft history rejects a repeated message ID', (
    tester,
  ) async {
    final backend = _Backend()
      ..historySize = 2
      ..duplicateHistoryMessage = true;
    await _mount(tester, backend, _Session());
    await tester.ensureVisible(find.text('Weekly'));
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    expect(find.text('Draft sequence 2.'), findsNothing);
    backend.duplicateHistoryMessage = false;
    await tester.tap(find.byKey(const Key('group-draft-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Draft sequence 2.'), findsOneWidget);
  });

  testWidgets('opening a deleted group draft keeps the search term', (
    tester,
  ) async {
    final backend = _Backend()..historyMissing = true;
    await _mount(tester, backend, _Session());
    final search = find.byKey(const Key('group-draft-search'));
    await tester.ensureVisible(search);
    await tester.enterText(search, 'planned release');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Weekly'));
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    expect(
      find.text('This conversation is no longer available.'),
      findsOneWidget,
    );
    expect(find.text('Weekly'), findsNothing);
    expect(find.text('planned release'), findsOneWidget);
    expect(
      backend.requests.any((request) => request.method == 'POST'),
      isFalse,
    );
  });

  testWidgets(
    'group draft history opens at the newest page and loads older drafts on demand',
    (tester) async {
      final backend = _Backend()..historySize = 53;
      await _mount(tester, backend, _Session());
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      List<Map<String, dynamic>> history() => backend.requests
          .where((request) => request.path == '$_conversations/$_id/messages')
          .map((request) => request.queryParameters)
          .toList();
      expect(history(), [
        {'before_sequence': 10000000000, 'limit': 50},
      ]);
      expect(find.text('Draft sequence 53.'), findsOneWidget);
      expect(find.text('Draft sequence 1.'), findsNothing);
      final older = find.text('Load older messages');
      final screen = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(older, 180, scrollable: screen);
      await tester.tap(older);
      await tester.pumpAndSettle();
      expect(history().last, {'before_sequence': 4, 'limit': 50});
      await tester.scrollUntilVisible(
        find.text('Draft sequence 1.'),
        180,
        scrollable: screen,
      );
      expect(find.text('Draft sequence 1.'), findsOneWidget);
      expect(older, findsNothing);
    },
  );

  testWidgets(
    'old group backend keeps the newest page and loads earlier drafts on demand',
    (tester) async {
      final backend = _Backend()
        ..historySize = 53
        ..legacyHistory = true;
      await _mount(tester, backend, _Session());
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      expect(find.text('Draft sequence 53.'), findsOneWidget);
      final older = find.text('Load older messages');
      final screen = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(older, 180, scrollable: screen);
      expect(find.text('Draft sequence 1.'), findsNothing);
      backend.historyUnavailable = true;
      await tester.tap(older);
      await tester.pumpAndSettle();
      expect(backend.requests.last.queryParameters, {
        'after_sequence': 0,
        'limit': 50,
      });
      expect(older, findsOneWidget);
      backend.historyUnavailable = false;
      await tester.tap(older);
      await tester.pumpAndSettle();
      expect(backend.requests.last.queryParameters, {
        'after_sequence': 0,
        'limit': 50,
      });
      await tester.scrollUntilVisible(
        find.text('Draft sequence 1.'),
        180,
        scrollable: screen,
      );
      expect(find.text('Draft sequence 1.'), findsOneWidget);
      expect(older, findsNothing);
    },
  );

  testWidgets(
    'disabled group model preserves draft history until availability refreshes',
    (tester) async {
      final backend = _Backend()
        ..groupInference = false
        ..withSkills = true;
      await _mount(tester, backend, _Session());
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('Skill · Group briefs · v3 · Enabled'), findsOneWidget);
      expect(
        find.text('Current model configuration revision 8'),
        findsOneWidget,
      );
      final generate = find.widgetWithText(FilledButton, 'Generate draft');
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);
      expect(
        backend.requests.where((request) => request.path == _generate),
        isEmpty,
      );
      backend.groupInference = true;
      await tester.tap(find.byKey(const Key('group-draft-refresh')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
      expect(
        backend.requests.where((request) => request.path == _generate),
        isEmpty,
      );
    },
  );

  testWidgets(
    'sends an activity plan with the explicitly selected group skill',
    (tester) async {
      final backend = _Backend();
      await _mount(tester, backend, _Session());
      await tester.tap(find.text('Weekly report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activity plan').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatic skill'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group operations').last);
      await tester.pumpAndSettle();
      final search = find.byKey(const Key('group-draft-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, '猫' * 86);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Generate draft'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(search, ' 活动报名 ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate draft'));
      await tester.pumpAndSettle();
      expect(backend.requests.singleWhere((r) => r.path == _generate).data, {
        'kind': 'activity_plan',
        'expected_sequence': 0,
        'skill_id': 'group-brief',
        'search_term': '活动报名',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saved draft is recovered by refreshing history', (tester) async {
    final backend = _Backend()..historyUnavailable = true;
    await _mount(tester, backend, _Session());
    await tester.tap(find.text('Generate draft'));
    await tester.pumpAndSettle();
    expect(
      find.text('The draft was saved. Refresh history to view it.'),
      findsOneWidget,
    );
    backend.historyUnavailable = false;
    await tester.tap(find.byKey(const Key('group-draft-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Draft for review'), findsOneWidget);
    expect(
      backend.requests.where((request) => request.path == _generate),
      hasLength(1),
    );
  });

  testWidgets('shows the quota wait without clearing a restored draft', (
    tester,
  ) async {
    final backend = _Backend()..generated = true;
    await _mount(tester, backend, _Session());
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    backend.retryAfter = 30;
    await tester.tap(find.text('Generate draft'));
    await tester.pumpAndSettle();
    expect(
      find.text('AI request quota reached. Try again in 30 seconds.'),
      findsOneWidget,
    );
    expect(find.text('Draft for review'), findsOneWidget);
    expect(backend.requests.where((r) => r.path == _generate), hasLength(1));
  });

  testWidgets(
    'groups need live admin permission before listing draft history',
    (tester) async {
      final backend = _Backend()..role = 'moderator';
      await _mount(tester, backend, _Session());
      expect(backend.requests.map((r) => r.path), [
        '/api/v2/groups/by-slug/test-group',
      ]);
      expect(find.text('Generate draft'), findsNothing);
    },
  );

  for (final active in <Object?>[0, null, '1']) {
    testWidgets('unconfirmed active flag ($active) blocks AI history', (
      tester,
    ) async {
      final backend = _Backend()..groupActive = active;
      await _mount(tester, backend, _Session());
      expect(backend.requests.map((r) => r.path), [
        '/api/v2/groups/by-slug/test-group',
      ]);
      expect(find.text('Generate draft'), findsNothing);
    });
  }

  testWidgets(
    'generates with last sequence and posts only after explicit review and edit',
    (tester) async {
      final backend = _Backend();
      await _mount(tester, backend, _Session());
      expect(find.text('Other group'), findsNothing);
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate draft'));
      await tester.pumpAndSettle();
      expect(backend.requests.singleWhere((r) => r.path == _generate).data, {
        'kind': 'weekly_report',
        'expected_sequence': 0,
      });
      expect(find.text('Draft for review'), findsOneWidget);
      expect(find.text('Post #24'), findsOneWidget);
      expect(backend.requests.where((r) => r.path == _posts), isEmpty);
      await tester.tap(find.text('Review and edit'));
      await tester.pumpAndSettle();
      expect(backend.requests.where((r) => r.path == _posts), isEmpty);
      await tester.enterText(
        find.byKey(const Key('group-draft-editor')),
        List.filled(1334, '界').join(),
      );
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'Confirm post');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(
        find.text('Shorten the post to 4,000 bytes or less.'),
        findsOneWidget,
      );
      expect(backend.requests.where((r) => r.path == _posts), isEmpty);
      await tester.enterText(
        find.byKey(const Key('group-draft-editor')),
        'My reviewed text',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(find.text('Post as a group announcement'));
      await tester.ensureVisible(find.text('Confirm post'));
      await tester.tap(find.text('Confirm post'));
      await tester.pumpAndSettle();
      final post = backend.requests.singleWhere((r) => r.path == _posts);
      expect(post.method, 'POST');
      expect(post.data, {
        'content': 'My reviewed text',
        'is_announcement': true,
      });
      expect(find.text('Posted to this group.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopening current history preserves uncertain edits only for an unchanged draft',
    (tester) async {
      final backend = _Backend()
        ..generated = true
        ..invalidPostReceipt = true;
      await _mount(tester, backend, _Session());
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review and edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('group-draft-editor')),
        'Preserved edit',
      );
      await tester.tap(find.text('Post as a group announcement'));
      await tester.ensureVisible(find.text('Confirm post'));
      await tester.tap(find.text('Confirm post'));
      await tester.pumpAndSettle();
      final refresh = find.byKey(const Key('group-draft-refresh'));
      await tester.tap(find.text('Open group posts'));
      await tester.pumpAndSettle();
      final feed = find.text('Group feed: test-group');
      expect(feed, findsOneWidget);
      GoRouter.of(tester.element(feed)).pop();
      await tester.pumpAndSettle();
      final currentHistory = find.text('Weekly');
      await tester.ensureVisible(currentHistory);
      await tester.tap(currentHistory);
      await tester.pumpAndSettle();
      expect(find.textContaining('Your edits were kept'), findsOneWidget);
      expect(find.text('Open group posts'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('group-draft-editor')))
            .controller!
            .text,
        'Preserved edit',
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.ancestor(
                of: find.text('Post as a group announcement'),
                matching: find.byType(CheckboxListTile),
              ),
            )
            .value,
        isTrue,
      );
      final publish = find.widgetWithText(FilledButton, 'Confirm post');
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
      final retry = find.text(
        'I checked the group feed and want to post again',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(publish).onPressed, isNotNull);
      expect(backend.requests.where((r) => r.path == _posts), hasLength(1));

      backend.sourceHidden = true;
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('group-draft-editor')), findsNothing);
      expect(find.text('Open group posts'), findsNothing);
      expect(find.textContaining('its sources changed'), findsOneWidget);
    },
  );

  testWidgets(
    'rechecks a restored draft before publishing and discards stale content',
    (tester) async {
      final backend = _Backend()..generated = true;
      await _mount(tester, backend, _Session());
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review and edit'));
      await tester.pumpAndSettle();
      backend.sourceHidden = true;
      await tester.ensureVisible(find.text('Confirm post'));
      await tester.tap(find.text('Confirm post'));
      await tester.pumpAndSettle();
      expect(backend.requests.where((r) => r.path == _posts), isEmpty);
      expect(find.text('Draft for review'), findsNothing);
      expect(
        find.text(
          'The conversation or its sources changed. Refresh to continue.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'history removal only deletes the explicitly confirmed conversation',
    (tester) async {
      final backend = _Backend();
      await _mount(tester, backend, _Session());
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete conversation'));
      await tester.pumpAndSettle();
      expect(backend.requests.where((r) => r.method == 'DELETE'), isEmpty);
      await tester.tap(find.text('Confirm delete'));
      await tester.pumpAndSettle();
      expect(
        backend.requests.singleWhere((r) => r.method == 'DELETE').path,
        '$_conversations/$_id',
      );
      expect(find.text('Weekly'), findsNothing);
      expect(find.text('Conversation deleted.'), findsOneWidget);
    },
  );

  testWidgets('account replacement cancels a pending publication', (
    tester,
  ) async {
    final backend = _Backend()
      ..generated = true
      ..pendingPublication = Completer<ResponseBody>();
    final session = _Session();
    await _mount(tester, backend, session);
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review and edit'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm post'));
    await tester.tap(find.text('Confirm post'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      backend.requests.where((request) => request.path == _posts),
      hasLength(1),
    );
    session.beginSessionChange();
    await tester.pump();
    backend.pendingPublication!.complete(
      backend.ok({'post_id': 31, 'group_id': 7}),
    );
    await tester.pumpAndSettle();
    expect(backend.sawCancellation, isTrue);
    expect(find.text('Posted to this group.'), findsNothing);
    expect(find.byKey(const Key('group-draft-editor')), findsNothing);
  });

  testWidgets(
    'session replacement cancels pending generation and clears drafts',
    (tester) async {
      final session = _Session();
      final backend = _Backend()
        ..pending = Completer<ResponseBody>()
        ..withSkills = true;
      await _mount(tester, backend, session);
      expect(find.text('Skill · Group briefs · v3 · Enabled'), findsOneWidget);
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate draft'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(backend.requests.where((r) => r.path == _generate), hasLength(1));
      session.beginSessionChange();
      await tester.pump();
      backend.pending!.complete(backend.generatedReply());
      await tester.pumpAndSettle();
      expect(backend.sawCancellation, isTrue);
      expect(find.text('Weekly'), findsNothing);
      expect(find.text('Skill · Group briefs · v3 · Enabled'), findsNothing);
      expect(
        find.text('Your session changed. Reopen group management.'),
        findsOneWidget,
      );
      expect(backend.requests.where((r) => r.path == _posts), isEmpty);
    },
  );
}

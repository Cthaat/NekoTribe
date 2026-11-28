import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_poll.dart';
import 'package:nekotribe/features/posts/presentation/post_poll_card.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  test('regular and group polls use their dedicated wire contracts', () async {
    final client = _client(_WireTokenStore());
    addTearDown(client.dispose);
    final requests = <RequestOptions>[];
    client.raw.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          final Object data = switch (request.path) {
            '/api/v2/posts' => {'post_id': 71, 'poll': _pollJson()},
            '/api/v2/groups/13/posts' => {
              'group_id': 13,
              'post_id': 71,
              'is_announcement': false,
              'poll': _pollJson(),
            },
            _ => _pollJson(),
          };
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {'code': 200, 'message': 'ok', 'data': data, 'meta': null},
            ),
          );
        },
      ),
    );
    final posts = PostsApi(client);
    final groups = GroupsApi(client);
    final draft = V2CreatePostPoll(
      options: [' First ', 'Second'],
      multiple: false,
      closesAt: DateTime.utc(2090, 1, 2),
    );
    expect(
      (await posts.createPost(content: 'Pick', poll: draft)).poll?.pollId,
      4,
    );
    expect(
      (await groups.createPost(
        groupId: 13,
        content: 'Pick',
        poll: draft,
      )).poll?.pollId,
      4,
    );
    expect((await posts.getPoll(71)).options.first.text, 'First');
    expect(
      (await groups.getPoll(groupId: 13, postId: 71)).options.last.text,
      'Second',
    );
    await posts.votePoll(71, [1]);
    await groups.votePoll(groupId: 13, postId: 71, optionIds: [2]);
    expect(requests.map((it) => (it.method, it.path)), [
      ('POST', '/api/v2/posts'),
      ('POST', '/api/v2/groups/13/posts'),
      ('GET', '/api/v2/posts/71/poll'),
      ('GET', '/api/v2/groups/13/posts/71/poll'),
      ('POST', '/api/v2/posts/71/poll/vote'),
      ('POST', '/api/v2/groups/13/posts/71/poll/vote'),
    ]);
    expect((requests[0].data as Map<String, Object?>)['poll'], draft.toJson());
    expect((requests[1].data as Map<String, Object?>)['poll'], draft.toJson());
    expect(requests[4].data, {
      'option_ids': [1],
    });
    expect(requests[5].data, {
      'option_ids': [2],
    });
  });

  test('poll creation trims, validates UTF-8 byte limits and emits UTC', () {
    final closes = DateTime.now().add(const Duration(days: 1));
    final draft = V2CreatePostPoll(
      options: [' ${'界' * 80} ', ' Other '],
      multiple: true,
      closesAt: closes,
    );
    expect(draft.isValid, isTrue);
    expect(draft.toJson(), {
      'options': ['界' * 80, 'Other'],
      'multiple': true,
      'closes_at': closes.toUtc().toIso8601String(),
    });
    expect(
      V2CreatePostPoll(
        options: ['界' * 81, 'Other'],
        multiple: false,
        closesAt: closes,
      ).isValid,
      isFalse,
    );
    expect(
      V2CreatePostPoll(
        options: ['Choice', ' Choice '],
        multiple: false,
        closesAt: closes,
      ).isValid,
      isFalse,
    );
  });

  testWidgets('one choice is sent and the server beats a pending refresh', (
    tester,
  ) async {
    final tokens = TokenStore();
    final api = _PostsApi(_client(tokens));
    final staleRead = Completer<V2PostPoll>();
    api.read = staleRead.future;
    await tester.pumpWidget(
      _app(tokens, PostPollCard(postId: 71, poll: _poll()), posts: api),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(api.pollReads, 1);

    await tester.tap(find.text('First'));
    await tester.tap(find.text('Second'));
    await tester.pump();
    await tester.tap(find.text('提交投票'));
    await tester.pump();
    expect(api.votes.single.$1, 71);
    expect(api.votes.single.$2, [2]);
    expect(find.text('1 人投票'), findsOneWidget);
    expect(find.byTooltip('你的选择'), findsOneWidget);
    expect(find.text('提交投票'), findsNothing);

    staleRead.complete(_poll());
    await tester.pump();
    expect(find.text('1 人投票'), findsOneWidget);
    expect(find.byTooltip('你的选择'), findsOneWidget);
  });

  testWidgets('group poll submits multiple choices and preserves percentages', (
    tester,
  ) async {
    final tokens = TokenStore();
    final api = _GroupsApi(_client(tokens));
    await tester.pumpWidget(
      _app(
        tokens,
        PostPollCard(postId: 71, groupId: 13, poll: _poll(multiple: true)),
        groups: api,
      ),
    );
    await tester.tap(find.text('First'));
    await tester.tap(find.text('Second'));
    await tester.pump();
    await tester.tap(find.text('提交投票'));
    await tester.pump();
    expect((api.votes.single.$1, api.votes.single.$2), (13, 71));
    expect(api.votes.single.$3, [1, 2]);
    expect(find.text('1 票 · 100.0%'), findsNWidgets(2));
    double fraction() => tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    ).first.value!;
    await tester.pump(const Duration(milliseconds: 80));
    expect(fraction(), allOf(greaterThan(0), lessThan(1)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(fraction(), 1);

    expect(find.byTooltip('你的选择'), findsNWidgets(2));
  });

  testWidgets('offscreen and background polls wait and closed polls stop', (
    tester,
  ) async {
    final tokens = TokenStore();
    final api = _PostsApi(_client(tokens))
      ..read = Future.value(_poll(closed: true));
    await tester.pumpWidget(
      _app(
        tokens,
        SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 900),
              PostPollCard(postId: 71, poll: _poll()),
            ],
          ),
        ),
        posts: api,
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(api.pollReads, 0);

    await tester.ensureVisible(find.text('First'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 5));
    expect(api.pollReads, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(api.pollReads, 1);
    expect(find.textContaining('已于'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(api.pollReads, 1);
  });

  testWidgets(
    'account changes discard earlier vote and reload current result',
    (tester) async {
      final tokens = TokenStore();
      final pending = Completer<V2PostPoll>();
      final api = _PostsApi(_client(tokens))
        ..ballot = pending.future
        ..read = Future.value(_poll(choices: [2]));
      await tester.pumpWidget(
        _app(tokens, PostPollCard(postId: 71, poll: _poll()), posts: api),
      );
      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.tap(find.text('提交投票'));
      await tester.pump();
      expect(api.votes.single.$2, [1]);
      tokens.beginSessionChange();
      pending.complete(_poll(choices: [1]));
      await tester.pump();
      expect(find.byTooltip('你的选择'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(api.pollReads, 1);
      expect(find.byTooltip('你的选择'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('post-poll-choice-2')))
            .selected,
        isTrue,
      );
    },
  );
}

Widget _app(
  TokenStore tokens,
  Widget child, {
  PostsApi? posts,
  GroupsApi? groups,
}) => ProviderScope(
  overrides: [
    tokenStoreProvider.overrideWithValue(tokens),
    authSessionProvider.overrideWith(
      (_) => AuthSessionController(tokens)..markLoggedIn(),
    ),
    if (posts != null) postsApiProvider.overrideWithValue(posts),
    if (groups != null) groupsApiProvider.overrideWithValue(groups),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

ApiClient _client(TokenStore tokens) => ApiClient(
  config: const AppConfig(
    apiBaseUrl: 'https://example.invalid',
    wsBaseUrl: 'wss://example.invalid',
    storageBaseUrl: 'https://example.invalid',
  ),
  tokenStore: tokens,
);

V2PostPoll _poll({
  bool closed = false,
  bool multiple = false,
  List<int> choices = const [],
}) => V2PostPoll.fromJson(
  _pollJson(closed: closed, multiple: multiple, choices: choices),
);

Map<String, dynamic> _pollJson({
  bool closed = false,
  bool multiple = false,
  List<int> choices = const [],
}) => {
  'poll_id': 4,
  'multiple': multiple,
  'closes_at': '2090-01-02T00:00:00.000Z',
  'closed': closed,
  'total_ballots': choices.isEmpty ? 0 : 1,
  'my_option_ids': choices,
  'options': [
    for (var id = 1; id <= 2; id++)
      {
        'option_id': id,
        'text': id == 1 ? 'First' : 'Second',
        'votes_count': choices.contains(id) ? 1 : 0,
        'percent': choices.contains(id) ? 100 : 0,
      },
  ],
};

class _WireTokenStore extends TokenStore {
  @override
  Future<String> deviceFingerprint() async => 'test';

  @override
  Future<TokenPair?> read() async => null;
}

class _PostsApi extends PostsApi {
  _PostsApi(super.client);

  Future<V2PostPoll>? read;
  Future<V2PostPoll>? ballot;
  int pollReads = 0;
  final votes = <(int, List<int>)>[];

  @override
  Future<V2PostPoll> getPoll(int postId, {CancelToken? cancelToken}) async {
    pollReads++;
    return read ?? _poll();
  }

  @override
  Future<V2PostPoll> votePoll(
    int postId,
    List<int> optionIds, {
    CancelToken? cancelToken,
  }) async {
    votes.add((postId, optionIds));
    return ballot ?? _poll(choices: optionIds);
  }
}

class _GroupsApi extends GroupsApi {
  _GroupsApi(super.client);

  final votes = <(int, int, List<int>)>[];

  @override
  Future<V2PostPoll> votePoll({
    required int groupId,
    required int postId,
    required List<int> optionIds,
    CancelToken? cancelToken,
  }) async {
    votes.add((groupId, postId, optionIds));
    return _poll(multiple: true, choices: optionIds);
  }
}

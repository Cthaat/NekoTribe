import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/moderation/data/moderation_api.dart';
import 'package:nekotribe/features/notifications/data/notifications_api.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/users/data/users_api.dart';

void main() {
  group('PostsApi v2 contract', () {
    test('feed uses timeline and page_size query keys', () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));

      await api.getFeed(mode: 'home', page: 2, size: 15);

      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/posts',
        query: {'timeline': 'home', 'page': 2, 'page_size': 15},
      );
    });

    test('post like and bookmark use plural REST resources', () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));

      await api.likePost(9);
      recorder.expectLast(method: 'POST', path: '/api/v2/posts/9/likes');

      await api.bookmarkPost(9);
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/posts/9/bookmarks',
      );
    });
  });

  group('GroupsApi v2 contract', () {
    test('slug lookup stays separate from id-based member actions', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      await api.getGroup('cat-town');
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/groups/by-slug/cat-town',
      );

      await api.joinGroup(42);
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/members/current',
      );
    });

    test('invite response uses group invite response endpoint', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      await api.respondInvite(inviteId: 7, action: 'accept');

      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/invites/7/responses',
        body: {'action': 'accept'},
      );
    });
  });

  group('ChatApi v2 contract', () {
    test('message reactions and pinning match server route names', () async {
      final recorder = _ApiRecorder();
      final api = ChatApi(_client(recorder));

      await api.reactMessage(messageId: 5, emoji: '👍');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/chat/messages/5/reactions',
        body: {'emoji': '👍'},
      );

      await api.pinMessage(5);
      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/chat/messages/5/pin-status',
        body: {'is_pinned': true},
      );
    });
  });

  group('ModerationApi v2 contract', () {
    test('content and user actions use action endpoints', () async {
      final recorder = _ApiRecorder();
      final api = ModerationApi(_client(recorder));

      await api.resolveContent(caseId: 11, action: 'approve');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/moderation/content/11/actions',
        body: {'action': 'approve'},
      );

      await api.restrictUser(userId: 8, action: 'suspend', note: 'spam');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/moderation/users/8/actions',
        body: {'action': 'suspend', 'note': 'spam'},
      );
    });
  });

  group('NotificationsApi v2 contract', () {
    test('single read status and restore endpoints are exposed', () async {
      final recorder = _ApiRecorder();
      final api = NotificationsApi(_client(recorder));

      await api.setReadStatus(notificationId: 3, isRead: true);
      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/notifications/3/read-status',
        body: {'is_read': true},
      );

      await api.restoreNotification(3);
      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/notifications/3/restore-status',
      );
    });
  });

  group('UsersApi v2 contract', () {
    test('profile, follow, and email endpoints match current server API', () async {
      final recorder = _ApiRecorder();
      final api = UsersApi(_client(recorder));

      await api.getUserById(12);
      recorder.expectLast(method: 'GET', path: '/api/v2/users/12');

      await api.followUser(12);
      recorder.expectLast(method: 'POST', path: '/api/v2/users/12/followers');

      await api.unfollowUser(12);
      recorder.expectLast(method: 'DELETE', path: '/api/v2/users/12/followers');

      await api.updateEmail(
        newEmail: 'edge@example.test',
        verificationId: 'verify-1',
        code: '123456',
      );
      recorder.expectLast(
        method: 'PATCH',
        path: '/api/v2/users/me/email',
        body: {
          'new_email': 'edge@example.test',
          'verification_id': 'verify-1',
          'code': '123456',
        },
      );
    });

    test('block and mute actions use page_size and POST resources', () async {
      final recorder = _ApiRecorder();
      final api = UsersApi(_client(recorder));

      await api.getBlocks(page: 3, size: 10);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/users/me/blocks',
        query: {'page': 3, 'page_size': 10},
      );

      await api.blockUser(12);
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/users/me/blocks/12',
      );

      await api.muteUser(12);
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/users/me/mutes/12',
      );
    });
  });
}

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

ApiClient _client(_ApiRecorder recorder) {
  final dio = Dio()..httpClientAdapter = recorder;
  return ApiClient(
    config: _testConfig,
    tokenStore: _FakeTokenStore(),
    dio: dio,
  );
}

class _ApiRecorder implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'code': 200, 'message': 'success', 'data': _dataFor(options)}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  void expectLast({
    required String method,
    required String path,
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) {
    expect(requests, isNotEmpty);
    final request = requests.last;
    expect(request.method, method);
    expect(request.path, path);
    if (query != null) {
      expect(request.queryParameters, query);
    }
    if (body != null) {
      expect(request.data, body);
    }
  }

  dynamic _dataFor(RequestOptions options) {
    final path = options.path;
    if (path.endsWith('/likes')) {
      return {'is_liked': true, 'is_bookmarked': false, 'can_delete': true};
    }
    if (path.endsWith('/bookmarks')) {
      return {'is_liked': false, 'is_bookmarked': true, 'can_delete': true};
    }
    if (path.endsWith('/members/current')) {
      return {'is_member': true, 'role': 'member', 'status': 'active'};
    }
    if (path.contains('/groups/invites/')) {
      return {'is_member': true, 'role': 'member', 'status': 'active'};
    }
    if (path.contains('/by-slug/')) {
      return _groupJson;
    }
    if (path.startsWith('/api/v2/users/')) {
      return _publicUserJson;
    }
    return {
      'items': <Object>[],
      'meta': {'page': 1, 'page_size': 20, 'total': 0, 'has_next': false},
    };
  }
}

class _FakeTokenStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}

const _publicUserJson = {
  'user_id': 1,
  'username': 'edge',
  'display_name': 'Edge',
  'avatar_url': '',
  'bio': '',
  'location': '',
  'website': '',
  'is_verified': 0,
  'followers_count': 0,
  'following_count': 0,
  'posts_count': 0,
  'likes_count': 0,
  'relationship': {
    'is_self': false,
    'is_following': false,
    'is_blocked': false,
    'is_blocking': false,
    'relation': 'none',
  },
  'online_status': 'online',
};

const _groupJson = {
  'group_id': 42,
  'name': 'Cat Town',
  'slug': 'cat-town',
  'description': '',
  'avatar_url': '',
  'cover_url': '',
  'category': 'general',
  'tags': <String>[],
  'owner': _publicUserJson,
  'privacy': 'public',
  'privacy_desc': 'Public',
  'join_approval': false,
  'post_permission': 'all',
  'member_count': 1,
  'post_count': 0,
  'is_active': 1,
  'membership': {'is_member': false},
  'created_at': '2026-05-24T00:00:00.000Z',
  'updated_at': '2026-05-24T00:00:00.000Z',
};

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/moderation/data/moderation_api.dart';
import 'package:nekotribe/features/notifications/data/notifications_api.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/users/data/users_api.dart';

void main() {
  group('AuthApi v2 contract', () {
    test('otp requests use current type and channel payload', () async {
      final recorder = _ApiRecorder();
      final api = AuthApi(_client(recorder));

      await api.requestOtp(account: 'edge@example.test', purpose: 'register');

      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/auth/otp',
        body: {
          'account': 'edge@example.test',
          'type': 'register',
          'channel': 'email',
        },
      );
    });

    test('registration uses verified email payload without token assumptions', () async {
      final recorder = _ApiRecorder();
      final api = AuthApi(_client(recorder));

      final user = await api.register(
        email: 'edge@example.test',
        username: 'edge',
        displayName: 'Edge',
        password: 'password-1',
        confirmPassword: 'password-1',
        verificationId: 'otp-1',
        agreeToTerms: true,
      );

      expect(user.email, 'edge@example.test');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/auth/registration',
        body: {
          'email': 'edge@example.test',
          'username': 'edge',
          'display_name': 'Edge',
          'password': 'password-1',
          'confirm_password': 'password-1',
          'verification_id': 'otp-1',
          'agree_to_terms': true,
        },
      );
    });

    test('password reset uses verification id and code payload', () async {
      final recorder = _ApiRecorder();
      final api = AuthApi(_client(recorder));

      await api.requestPasswordReset(
        email: 'edge@example.test',
        verificationId: 'otp-1',
        code: '123456',
        newPassword: 'password-2',
      );

      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/auth/password-reset',
        body: {
          'email': 'edge@example.test',
          'verification_id': 'otp-1',
          'code': '123456',
          'new_password': 'password-2',
        },
      );
    });
  });

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

    test('feed decodes v2 list data from envelope meta', () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));

      final page = await api.getFeed(mode: 'home', page: 1, size: 20);

      expect(page.items, hasLength(1));
      expect(page.items.single.postId, 100001);
      expect(page.items.single.content, contains('NekoTribe'));
      expect(page.page, 1);
      expect(page.pageSize, 20);
      expect(page.total, 1);
      expect(page.hasNext, isFalse);
    });

    test('post like and bookmark use plural REST resources', () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));

      await api.likePost(9);
      recorder.expectLast(method: 'POST', path: '/api/v2/posts/9/likes');

      await api.bookmarkPost(9);
      recorder.expectLast(method: 'POST', path: '/api/v2/posts/9/bookmarks');
    });
  });

  group('GroupsApi v2 contract', () {
    test('group pages decode v2 list data from envelope meta', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      final page = await api.list(mode: 'discover', page: 1, size: 20);

      expect(page.items, hasLength(1));
      expect(page.items.single.groupId, 42);
      expect(page.items.single.name, 'Cat Town');
      expect(page.page, 1);
      expect(page.pageSize, 20);
      expect(page.total, 1);
    });

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

    test('group post comments use numeric group and post ids', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      await api.comments(groupId: 42, postId: 9, page: 2, size: 10);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/groups/42/posts/9/comments',
        query: {'page': 2, 'page_size': 10},
      );

      await api.createComment(groupId: 42, postId: 9, content: 'hi');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/posts/9/comments',
        body: {'content': 'hi'},
      );

      await api.setCommentLikeStatus(
        groupId: 42,
        postId: 9,
        commentId: 5,
        liked: true,
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/posts/9/comments/5/likes',
      );
    });
  });

  group('ChatApi v2 contract', () {
    test('chat lists decode v2 list data from envelope meta', () async {
      final recorder = _ApiRecorder();
      final api = ChatApi(_client(recorder));

      final conversations = await api.listConversations();
      expect(conversations, hasLength(1));
      expect(conversations.single.conversationId, 77);
      expect(conversations.single.lastMessage?.content, 'hello');

      final groups = await api.listChatGroups();
      expect(groups, hasLength(1));
      expect(groups.single.groupId, 42);
      expect(groups.single.channelCount, 1);
    });

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

      await api.restrictUser(
        userId: 8,
        action: 'ban',
        reason: 'spam',
        durationHours: 24,
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/moderation/users/8/actions',
        body: {'action': 'ban', 'reason': 'spam', 'duration_hours': 24},
      );
    });
  });

  group('NotificationsApi v2 contract', () {
    test('notification pages decode v2 list data from envelope meta', () async {
      final recorder = _ApiRecorder();
      final api = NotificationsApi(_client(recorder));

      final page = await api.list(page: 1, size: 20);

      expect(page.items, hasLength(1));
      expect(page.items.single.notificationId, 3001);
      expect(page.items.single.title, 'New reply');
      expect(page.page, 1);
      expect(page.total, 1);
    });

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
    test(
      'profile, follow, and email endpoints match current server API',
      () async {
        final recorder = _ApiRecorder();
        final api = UsersApi(_client(recorder));

        await api.getUserById(12);
        recorder.expectLast(method: 'GET', path: '/api/v2/users/12');

        await api.followUser(12);
        recorder.expectLast(method: 'POST', path: '/api/v2/users/12/followers');

        await api.unfollowUser(12);
        recorder.expectLast(
          method: 'DELETE',
          path: '/api/v2/users/12/followers',
        );

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
      },
    );

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
      recorder.expectLast(method: 'POST', path: '/api/v2/users/me/blocks/12');

      await api.muteUser(12);
      recorder.expectLast(method: 'POST', path: '/api/v2/users/me/mutes/12');
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
    final meta = _metaFor(options);
    return ResponseBody.fromString(
      jsonEncode({
        'code': 200,
        'message': 'success',
        'data': _dataFor(options),
        if (meta != null) 'meta': meta,
      }),
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
    if (path == '/api/v2/posts') {
      return <Object>[_postJson];
    }
    if (path == '/api/v2/groups') {
      return <Object>[_groupJson];
    }
    if (path == '/api/v2/chat/direct-conversations') {
      return <Object>[_directConversationJson];
    }
    if (path == '/api/v2/chat/groups') {
      return <Object>[_chatGroupJson];
    }
    if (path == '/api/v2/notifications') {
      return <Object>[_notificationJson];
    }
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
    if (path.contains('/groups/') && path.contains('/comments')) {
      if (options.method == 'POST') return _groupCommentJson;
      return {
        'items': <Object>[_groupCommentJson],
        'meta': {'page': 1, 'page_size': 20, 'total': 1, 'has_next': false},
      };
    }
    if (path.startsWith('/api/v2/users/')) {
      return _publicUserJson;
    }
    return {
      'items': <Object>[],
      'meta': {'page': 1, 'page_size': 20, 'total': 0, 'has_next': false},
    };
  }

  Map<String, Object>? _metaFor(RequestOptions options) {
    if (options.path == '/api/v2/posts') {
      return {'page': 1, 'page_size': 20, 'total': 1, 'has_next': false};
    }
    if (options.path == '/api/v2/groups' ||
        options.path == '/api/v2/notifications') {
      return {'page': 1, 'page_size': 20, 'total': 1, 'has_next': false};
    }
    return null;
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

const _chatGroupJson = {
  'group_id': 42,
  'name': 'Cat Town',
  'avatar_url': '',
  'member_count': 3,
  'channel_count': 1,
  'unread_count': 2,
  'membership': {'role': 'member', 'can_manage': false},
};

const _directConversationJson = {
  'conversation_id': 77,
  'participant': _publicUserJson,
  'unread_count': 1,
  'last_message': {
    'message_id': 7001,
    'content': 'hello',
    'author_name': 'Edge',
    'created_at': '2026-05-24T00:00:00.000Z',
  },
  'created_at': '2026-05-24T00:00:00.000Z',
  'updated_at': '2026-05-24T00:00:00.000Z',
};

const _notificationJson = {
  'notification_id': 3001,
  'type': 'comment',
  'title': 'New reply',
  'message': 'Edge replied to you',
  'resource_type': 'post',
  'resource_id': 100001,
  'priority': 'normal',
  'is_read': 0,
  'read_at': null,
  'deleted_at': null,
  'actor': _publicUserJson,
  'metadata': <String, Object>{},
  'created_at': '2026-05-24T00:00:00.000Z',
};

const _groupCommentJson = {
  'comment_id': 5,
  'post_id': 9,
  'author': _publicUserJson,
  'parent_comment_id': null,
  'reply_to_user': null,
  'content': 'hi',
  'likes_count': 0,
  'is_liked_by_me': false,
  'can_delete_by_me': true,
  'created_at': '2026-05-24T00:00:00.000Z',
  'updated_at': '2026-05-24T00:00:00.000Z',
};

const _postJson = {
  'post_id': 100001,
  'author': _publicUserJson,
  'content': '欢迎来到 NekoTribe V2 开发环境。',
  'post_type': 'post',
  'visibility': 'public',
  'language': 'zh',
  'location': '',
  'reply_to_post_id': null,
  'repost_of_post_id': null,
  'quoted_post_id': null,
  'media': <Object>[],
  'tags': <String>['v2'],
  'mentions': <Object>[],
  'stats': {
    'likes_count': 0,
    'comments_count': 0,
    'replies_count': 0,
    'retweets_count': 0,
    'views_count': 0,
    'engagement_score': 0,
  },
  'viewer_state': {
    'is_liked': false,
    'is_bookmarked': false,
    'can_delete': false,
  },
  'created_at': '2026-05-24T00:00:00.000Z',
  'updated_at': '2026-05-24T00:00:00.000Z',
};

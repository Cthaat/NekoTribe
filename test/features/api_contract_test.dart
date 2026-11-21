import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/ai/data/ai_writing_api.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/chat/domain/chat_models.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/moderation/data/moderation_api.dart';
import 'package:nekotribe/features/notifications/data/notifications_api.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/sentiment_flow/data/sentiment_flow_api.dart';
import 'package:nekotribe/features/users/data/users_api.dart';

void main() {
  test('private conversation sends the canonical recipient field', () async {
    final recorder = _ApiRecorder();
    final api = ChatApi(_client(recorder));

    final conversation = await api.openConversation(userId: 42);
    expect(conversation.conversationId, 77);
    recorder.expectLast(
      method: 'POST',
      path: '/api/v2/chat/direct-conversations',
      body: {'target_user_id': 42},
    );
    await expectLater(api.openConversation(userId: 43), throwsFormatException);

    final message = await api.sendDirectMessage(
      conversationId: 77,
      content: ' hi ',
    );
    expect(message.content, 'hi');
    await expectLater(
      api.sendDirectMessage(conversationId: 77, content: 'different'),
      throwsFormatException,
    );
  });

  test('channel writes confirm the target and deletion envelope', () async {
    final recorder = _ApiRecorder();
    final api = ChatApi(_client(recorder));
    final channel = {'channel_id': 7, 'group_id': 42};
    recorder.channelWriteEnvelope = {
      'code': 200,
      'message': 'success',
      'data': channel,
      'meta': null,
    };
    expect((await api.createChannel(groupId: 42, name: 'team')).channelId, 7);
    expect(
      (await api.updateChannel(
        channelId: 7,
        category: '',
        isPrivate: true,
      )).groupId,
      42,
    );
    recorder.expectLast(
      method: 'PATCH',
      path: '/api/v2/chat/channels/7',
      body: {'category': '', 'is_private': true},
    );
    recorder.channelWriteEnvelope = {
      'code': 200,
      'message': 'success',
      'data': {...channel, 'group_id': 1},
      'meta': null,
    };
    await expectLater(
      api.createChannel(groupId: 42, name: 'team'),
      throwsFormatException,
    );
    await expectLater(api.updateChannel(channelId: 8), throwsFormatException);
    await expectLater(api.deleteChannel(7), throwsFormatException);
    recorder.channelWriteEnvelope = {
      'code': 200,
      'message': 'chat channel deleted',
      'data': null,
      'meta': null,
    };
    await api.deleteChannel(7);
  });

  test('post detail only accepts the requested post', () async {
    final recorder = _ApiRecorder();
    final api = PostsApi(_client(recorder));
    expect((await api.getPost(42)).postId, 42);

    for (final receipt in [
      null,
      {'post_id': 7},
      {'post_id': '42'},
    ]) {
      recorder.postDetailReceipt = receipt;
      await expectLater(api.getPost(42), throwsFormatException);
    }
  });

  test(
    'post update checks the receipt before decoding fallback values',
    () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));
      final post = await api.updatePost(postId: 42, content: 'new');
      expect(post.postId, 42);
      recorder.expectLast(
        method: 'PATCH',
        path: '/api/v2/posts/42',
        body: {'content': 'new'},
      );

      final valid = recorder.updatePostEnvelope;
      final data = valid['data'] as Map<String, Object?>;
      for (final envelope in [
        {...valid, 'message': 'success'},
        {...valid}..remove('meta'),
        {...valid, 'data': null},
        {
          ...valid,
          'data': {...data, 'post_id': '42'},
        },
        {
          ...valid,
          'data': {
            ...data,
            'author': {'user_id': 0},
          },
        },
        {
          ...valid,
          'data': {
            ...data,
            'viewer_state': {'can_delete': false},
          },
        },
      ]) {
        recorder.updatePostEnvelope = envelope;
        await expectLater(
          api.updatePost(postId: 42),
          throwsA(isA<UnconfirmedPostUpdateError>()),
        );
      }
    },
  );

  test('delete post requires the committed deletion envelope', () async {
    final recorder = _ApiRecorder();
    final api = PostsApi(_client(recorder));
    await api.deletePost(42);
    recorder.expectLast(method: 'DELETE', path: '/api/v2/posts/42');

    final valid = recorder.deletePostEnvelope as Map<String, Object?>;
    for (final envelope in [
      null,
      <String, Object?>{},
      {...valid, 'code': 40401},
      {...valid, 'message': 'success'},
      {...valid, 'data': {}},
      {...valid}..remove('meta'),
    ]) {
      recorder.deletePostEnvelope = envelope;
      await expectLater(api.deletePost(42), throwsFormatException);
    }
  });

  test('create post requires a valid new ID and matching references', () async {
    final recorder = _ApiRecorder();
    final api = PostsApi(_client(recorder));
    recorder.createPostReceipt = {'post_id': 53, 'quoted_post_id': 42};
    final post = await api.createPost(content: 'draft', quotedPostId: 42);
    expect(post.postId, 53);
    expect(post.quotedPostId, 42);

    for (final receipt in [
      null,
      {'post_id': '53', 'quoted_post_id': 42},
      {'post_id': 42, 'quoted_post_id': 42},
      {'post_id': 53, 'quoted_post_id': 43},
      {'post_id': 53, 'quoted_post_id': 42, 'reply_to_post_id': 43},
      {'post_id': 53},
    ]) {
      recorder.createPostReceipt = receipt;
      await expectLater(
        api.createPost(content: 'draft', quotedPostId: 42),
        throwsA(isA<UnconfirmedPostError>()),
      );
    }
  });

  test(
    'retweet receipt must identify a new post linked to the original',
    () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));
      final result = await api.createRetweet(postId: 42, content: '');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/posts/42/retweets',
        body: {'content': '', 'visibility': 'public'},
      );
      expect(result.postId, 53);
      for (final body in [
        null,
        {'post_id': 42, 'repost_of_post_id': 42},
        {'post_id': 53, 'repost_of_post_id': 43},
        {'post_id': 0, 'repost_of_post_id': 42},
      ]) {
        recorder.retweetReceipt = body;
        await expectLater(
          api.createRetweet(postId: 42, content: ''),
          throwsA(isA<UnconfirmedRetweetError>()),
        );
      }
    },
  );

  test('sessions decode the V2 array and envelope paging metadata', () async {
    final recorder = _ApiRecorder();
    final result = await AuthApi(_client(recorder)).listSessions(page: 2);
    recorder.expectLast(
      method: 'GET',
      path: '/api/v2/auth/sessions',
      query: {'page': 2, 'page_size': 20},
    );
    expect(result.items.single.sessionId, 'secondary');
    expect(result.items.single.isCurrent, isFalse);
    expect(result.page, 2);
    expect(result.total, 42);
    expect(result.hasNext, isTrue);
  });
  test('trending tags use the backend page size parameter', () async {
    final recorder = _ApiRecorder();
    final tags = await PostsApi(_client(recorder)).getTrendingTags(limit: 6);
    recorder.expectLast(
      method: 'GET',
      path: '/api/v2/tags/trending',
      query: {'page_size': 6},
    );
    expect(tags.single.name, 'Cats');
  });
  test(
    'tag analytics encodes the slug as one segment and reads the aggregates',
    () async {
      final recorder = _ApiRecorder();
      final stats = await PostsApi(
        _client(recorder),
      ).getTagAnalytics('C# cats');
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/tags/C%23%20cats/analytics',
      );
      expect(stats.totalPosts, 4);
      expect(stats.totalAuthors, 2);
      expect(stats.totalViews, 30);
      expect(stats.totalLikes, 5);
      expect(stats.engagementScore, 12.25);
    },
  );

  test(
    'user moderation omits default mute duration and preserves explicit zero ban',
    () async {
      final recorder = _ApiRecorder();
      final api = ModerationApi(_client(recorder));
      await api.restrictUser(userId: 7, action: 'mute');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/moderation/users/7/actions',
        body: {'action': 'mute'},
      );
      await api.restrictUser(
        userId: 7,
        action: 'ban',
        durationHours: 0,
        note: 'Reviewed',
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/moderation/users/7/actions',
        body: {'action': 'ban', 'duration_hours': 0, 'note': 'Reviewed'},
      );
    },
  );
  test(
    'moderation actions use post IDs and carry notes in single and bulk requests',
    () async {
      final recorder = _ApiRecorder();
      final api = ModerationApi(_client(recorder));
      await api.resolveContent(postId: 81, action: 'reject', note: 'Reviewed');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/moderation/content/81/actions',
        body: {'action': 'reject', 'note': 'Reviewed'},
      );
      final processed = await api.bulkAction(
        postIds: [81, 82],
        action: 'remove',
        note: 'Reviewed',
      );
      expect(processed, 2);
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/moderation/content/bulk-actions',
        body: {
          'post_ids': [81, 82],
          'action': 'remove',
          'note': 'Reviewed',
        },
      );
    },
  );
  test('content moderation sends all shared queue filters', () async {
    final recorder = _ApiRecorder();
    final api = ModerationApi(_client(recorder));
    await api.content(
      status: 'pending',
      priority: 'high',
      reason: 'spam',
      keyword: 'all%',
      dateRange: 'week',
      sort: 'most_reports',
      page: 2,
      size: 10,
    );
    recorder.expectLast(
      method: 'GET',
      path: '/api/v2/moderation/content',
      query: {
        'status': 'pending',
        'priority': 'high',
        'reason': 'spam',
        'q': 'all%',
        'date_range': 'week',
        'sort': 'most_reports',
        'page': 2,
        'page_size': 10,
      },
    );
  });
  test('moderation user search uses q with status and pagination', () async {
    final recorder = _ApiRecorder();
    final api = ModerationApi(_client(recorder));
    await api.users(
      status: 'active',
      sort: 'reports',
      keyword: 'reader%',
      page: 2,
      size: 10,
    );
    recorder.expectLast(
      method: 'GET',
      path: '/api/v2/moderation/users',
      query: {
        'q': 'reader%',
        'status': 'active',
        'sort': 'reports',
        'page': 2,
        'page_size': 10,
      },
    );
  });
  test(
    'AI availability reads the shared route and validates boolean flags',
    () async {
      final recorder = _ApiRecorder();
      final api = AiWritingApi(_client(recorder));
      final vectors =
          jsonDecode(
                File(
                  'contracts/scenarios/ai-availability-client-vectors.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final vector
          in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
        recorder.availabilityResult = vector['data'];
        if (vector['accepted'] == true) {
          final result = await api.availability();
          final inference = result.inference;
          expect(
            {
              'knowledge': result.knowledge,
              'writing': result.writing,
              if (result.group != null) 'group': result.group,
              if (result.moderation != null) 'moderation': result.moderation,
              if (result.modelConfigRevision != null)
                'modelConfigRevision': result.modelConfigRevision,
              if (result.skills.isNotEmpty)
                'skills': [
                  for (final skill in result.skills.values)
                    {
                      'id': skill.id,
                      'purpose': skill.purpose,
                      'version': skill.version,
                      'enabled': skill.enabled,
                      if (skill.explicitSelection) 'explicitSelection': true,
                    },
                ],
              if (inference != null)
                'inference': {
                  'knowledge': inference.knowledge,
                  'writing': inference.writing,
                  if (result.groupInference != null)
                    'group': result.groupInference,
                  if (result.moderationInference != null)
                    'moderation': result.moderationInference,
                },
            },
            vector['expected'],
            reason: vector['id'] as String,
          );
        } else {
          await expectLater(
            api.availability(),
            throwsFormatException,
            reason: vector['id'] as String,
          );
        }
        recorder.expectLast(method: 'GET', path: '/api/v2/ai/availability');
      }
    },
  );
  test(
    'AI knowledge uses shared generation contract and parses citations',
    () async {
      final recorder = _ApiRecorder();
      final api = AiWritingApi(_client(recorder));
      final id = await api.createKnowledgeConversation();
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/ai/conversations',
        body: {'purpose': 'knowledge'},
      );
      expect(await api.generateKnowledge(id, searchPhrase: '猫'), isFalse);
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/ai/conversations/$id/knowledge-generate',
        body: {'search_phrase': '猫'},
      );
      recorder.knowledgeResult = {
        'status': 'generated',
        'message': {
          'conversation_id': id,
          'message_id': 'a',
          'sequence_no': 2,
          'role': 'assistant',
        },
      };
      expect(
        await api.generateKnowledge(
          id,
          searchPhrase: '猫',
          selectSkill: true,
          expectedSequence: 1,
        ),
        isTrue,
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/ai/conversations/$id/knowledge-generate',
        body: {
          'search_phrase': '猫',
          'skill_id': 'knowledge-answer',
          'expected_sequence': 1,
        },
      );
      expect(await api.generateKnowledge(id), isTrue);
      recorder.knowledgeResult = {'status': 'generated', 'message': null};
      await expectLater(api.generateKnowledge(id), throwsFormatException);
      final message = AiWritingMessage.fromJson({
        'message_id': 'a',
        'sequence_no': 2,
        'role': 'assistant',
        'content': 'answer',
        'citations': [
          {'kind': 'comment', 'id': 42, 'post_id': 99, 'version': 'a' * 64},
        ],
      });
      expect(message.citations.single.id, 42);
      expect(message.citations.single.postId, 99);
      final legacy = AiKnowledgeCitation.fromJson({
        'kind': 'comment',
        'id': 42,
        'version': 'b' * 64,
      });
      expect(legacy.postId, isNull);
      final terms = AiKnowledgeCitation.fromJson({
        'kind': 'terms',
        'id': 3,
        'version': 'a' * 64,
      });
      expect(terms.kind, 'terms');
      expect(terms.postId, isNull);
      expect(
        () => AiKnowledgeCitation.fromJson({
          'kind': 'terms',
          'id': 9,
          'version': 'a' * 64,
        }),
        throwsFormatException,
      );
      expect(
        () => AiKnowledgeCitation.fromJson({
          'kind': 'terms',
          'id': 3,
          'post_id': 99,
          'version': 'a' * 64,
        }),
        throwsFormatException,
      );
      expect(
        () => AiKnowledgeCitation.fromJson({
          'kind': 'terms',
          'id': 3,
          'post_id': null,
          'version': 'a' * 64,
        }),
        throwsFormatException,
      );
      expect(
        () => AiKnowledgeCitation.fromJson({
          'kind': 'post',
          'id': 42,
          'post_id': 99,
          'version': 'a' * 64,
        }),
        throwsFormatException,
      );
      expect(
        () => AiWritingMessage.fromJson({
          'message_id': 'a',
          'sequence_no': 2,
          'role': 'assistant',
          'content': 'answer',
          'citations': [
            {'kind': 'post', 'id': 42, 'version': 'invalid'},
          ],
        }),
        throwsFormatException,
      );
    },
  );
  test('AI writing uses the shared conversation contract', () async {
    final recorder = _ApiRecorder();
    final api = AiWritingApi(_client(recorder));
    final page = await api.listConversations();
    recorder.expectLast(
      method: 'GET',
      path: '/api/v2/ai/conversations',
      query: {'limit': 50},
    );
    expect(page.items.single.title, 'previous draft');
    final conversation = await api.createConversation();
    expect(conversation, 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb');
    recorder.expectLast(
      method: 'POST',
      path: '/api/v2/ai/conversations',
      body: {'purpose': 'writing'},
    );
    final sequence = await api.appendMessage(conversation, 'hello');
    expect(sequence, 1);
    recorder.expectLast(
      method: 'POST',
      path: '/api/v2/ai/conversations/$conversation/messages',
      body: {'content': 'hello'},
    );
    await api.generate(conversation, expectedSequence: sequence);
    recorder.expectLast(
      method: 'POST',
      path: '/api/v2/ai/conversations/$conversation/generate',
      body: {'expected_sequence': 1},
    );
    final messages = await api.listMessages(conversation, afterSequence: 1);
    recorder.expectLast(
      method: 'GET',
      path: '/api/v2/ai/conversations/$conversation/messages',
      query: {'after_sequence': 1, 'limit': 50},
    );
    expect(messages.single.content, 'draft');
    expect(messages.single.sequence, 2);
    expect(messages.single.role, 'assistant');
    await api.deleteConversation(conversation);
    recorder.expectLast(
      method: 'DELETE',
      path: '/api/v2/ai/conversations/$conversation',
    );
  });
  test('AI history rejects incomplete or unrelated message pages', () async {
    const id = 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';
    const first = {
      'conversation_id': id,
      'message_id': 'reply',
      'sequence_no': 2,
      'role': 'assistant',
      'content': 'draft',
    };
    final recorder = _ApiRecorder()..aiMessageHistory = [first];
    final api = AiWritingApi(_client(recorder));
    expect(
      (await api.listMessages(id, beforeSequence: 100)).single.id,
      'reply',
    );
    for (final page in [
      {
        'items': [first],
      },
      [
        {...first, 'conversation_id': null},
      ],
      [
        first,
        {...first, 'conversation_id': 'other', 'message_id': 'second'},
      ],
      [
        first,
        {...first, 'sequence_no': 3},
      ],
      [
        {...first, 'message_id': ''},
      ],
      [
        {...first, 'sequence_no': 10000000000},
      ],
    ]) {
      recorder.aiMessageHistory = page;
      await expectLater(api.listMessages(id), throwsFormatException);
    }
  });
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

    test(
      'registration uses verified email payload without token assumptions',
      () async {
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
      },
    );

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
    test(
      'comment citation requests the exact ID and ignores unrelated rows',
      () async {
        final recorder = _ApiRecorder();
        final api = PostsApi(_client(recorder));
        expect((await api.getComment(1, 9))?.commentId, 9);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/posts/1/comments',
          query: {'comment_id': 9},
        );
        expect(await api.getComment(1, 12), isNull);
      },
    );

    test(
      'post comments decode shared envelope and nullable thread IDs',
      () async {
        final recorder = _ApiRecorder();
        final api = PostsApi(_client(recorder));

        final page = await api.getComments(1, page: 2, size: 3);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/posts/1/comments',
          query: {'page': 2, 'page_size': 3},
        );
        final comment = page.items.single;
        expect(comment.commentId, 9);
        expect(comment.parentCommentId, isNull);
        expect(comment.rootCommentId, 3);
        expect(comment.likesCount, 2);
        expect(comment.isLiked, isTrue);
        expect(comment.canDelete, isFalse);
        expect(page.total, 4);
      },
    );
    test(
      'report submission uses the shared v2 body and omits empty options',
      () async {
        final recorder = _ApiRecorder();
        final api = PostsApi(_client(recorder));
        await api.reportContent(
          targetType: 'group_post',
          targetId: 30,
          reason: 'spam',
          description: 'Detail',
        );
        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/reports',
          body: {
            'target_type': 'group_post',
            'target_id': 30,
            'reason': 'spam',
            'description': 'Detail',
          },
        );
      },
    );

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

      expect(await api.likePost(9), (isLiked: true, likesCount: 42));
      recorder.expectLast(method: 'POST', path: '/api/v2/posts/9/likes');

      await api.bookmarkPost(9);
      recorder.expectLast(method: 'POST', path: '/api/v2/posts/9/bookmarks');

      recorder.postLikeReceipt = {
        'post_id': 8,
        'is_liked': true,
        'likes_count': 42,
      };
      await expectLater(api.likePost(9), throwsFormatException);
      recorder.postBookmarkReceipt = {'post_id': 8, 'is_bookmarked': true};
      await expectLater(api.bookmarkPost(9), throwsFormatException);
    });

    test('create post sends web composer metadata keys', () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));

      await api.createPost(
        content: 'hello #flutter',
        visibility: 'mentioned',
        location: 'Shanghai',
        mediaIds: const [91],
        tags: const ['flutter', 'cats'],
      );

      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/posts',
        body: {
          'content': 'hello #flutter',
          'post_type': 'normal',
          'visibility': 'mentioned',
          'location': 'Shanghai',
          'media_ids': [91],
          'tag_names': ['flutter', 'cats'],
        },
      );
    });

    test(
      'recommendation feedback submits the canonical post payload',
      () async {
        final recorder = _ApiRecorder();
        final api = PostsApi(_client(recorder));
        await api.recordRecommendationFeedback(
          postId: 100001,
          feedback: 'show_less',
        );
        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/recommendations/feedback',
          body: {
            'resource_type': 'post',
            'resource_id': 100001,
            'action': 'show_less',
          },
        );
      },
    );

    test('post analytics uses the current post analytics endpoint', () async {
      final recorder = _ApiRecorder();
      final api = PostsApi(_client(recorder));

      final analytics = await api.getPostAnalytics(100001);

      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/posts/100001/analytics',
      );
      expect(analytics.postId, 100001);
      expect(analytics.viewsCount, 32);
      expect(analytics.likesCount, 8);
      expect(analytics.likeRate, 0.25);
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

    test(
      'group detail encodes its slug and confirms the requested group',
      () async {
        final recorder = _ApiRecorder();
        final api = GroupsApi(_client(recorder));
        recorder.groupDetailReceipt = {..._groupJson, 'slug': 'cat town%'};
        expect((await api.getGroup('cat town%')).groupId, 42);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/groups/by-slug/cat%20town%25',
        );
        await expectLater(api.getGroup('different'), throwsFormatException);
        await expectLater(api.getGroupById(9), throwsFormatException);
      },
    );

    test(
      'member pages decode roles, mute expiry and filtered totals',
      () async {
        final recorder = _ApiRecorder();
        final api = GroupsApi(_client(recorder));

        final page = await api.members(42, page: 2, size: 3, role: 'member');

        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/groups/42/members',
          query: {'page': 2, 'page_size': 3, 'role': 'member'},
        );
        final member = page.items.single;
        expect(member.memberId, 12);
        expect(member.user.username, _publicUserJson['username']);
        expect(member.status, 'muted');
        expect(member.muteUntil, '2026-12-01T00:00:00.000Z');
        expect(page.total, 4);
        expect(page.hasNext, isFalse);
      },
    );

    test(
      'invite preview does not consume the code and join sends it',
      () async {
        final recorder = _ApiRecorder();
        final api = GroupsApi(_client(recorder));

        final preview = await api.previewInvite('ABC');
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/groups/invite-codes/ABC',
        );
        expect(preview.group.groupId, 42);
        expect(preview.isValid, isTrue);
        expect(preview.message, 'Welcome');
        expect(recorder.requests, hasLength(1));

        final joined = await api.joinGroup(
          preview.group.groupId,
          inviteCode: 'ABC',
        );
        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/groups/42/members/current',
          body: {'invite_code': 'ABC'},
        );
        expect(joined.status, 'active');
      },
    );

    test('invite response uses group invite response endpoint', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      for (final accept in [true, false]) {
        final result = await api.respondInvite(inviteId: 7, accept: accept);
        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/groups/invites/7/responses',
          body: {'accept': accept},
        );
        expect(result.inviteId, 7);
        expect(result.groupId, 42);
        expect(result.status, accept ? 'accepted' : 'rejected');
      }
    });

    test(
      'dissolve group uses the group id and accepts a null payload',
      () async {
        final recorder = _ApiRecorder();
        final api = GroupsApi(_client(recorder));

        await api.deleteGroup(42);

        recorder.expectLast(method: 'DELETE', path: '/api/v2/groups/42');
      },
    );

    test('create and update group send web group metadata keys', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      await api.createGroup(
        name: 'Flutter Cats',
        description: 'A parity test group',
        avatarUrl: '/uploads/avatar.png',
        coverUrl: '/uploads/cover.png',
        privacy: 'private',
        category: 'tech',
        tags: const ['flutter', 'cats'],
        joinApproval: true,
        postPermission: 'moderator_up',
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups',
        body: {
          'name': 'Flutter Cats',
          'description': 'A parity test group',
          'avatar_url': '/uploads/avatar.png',
          'cover_url': '/uploads/cover.png',
          'privacy': 'private',
          'category': 'tech',
          'tags': ['flutter', 'cats'],
          'join_approval': true,
          'post_permission': 'moderator_up',
        },
      );

      await api.updateGroup(
        groupId: 42,
        name: 'Updated Cats',
        description: 'Updated description',
        avatarUrl: '',
        coverUrl: null,
        privacy: 'secret',
        category: 'art',
        tags: const ['updated'],
        joinApproval: false,
        postPermission: 'admin_only',
      );
      recorder.expectLast(
        method: 'PATCH',
        path: '/api/v2/groups/42',
        body: {
          'name': 'Updated Cats',
          'description': 'Updated description',
          'avatar_url': null,
          'privacy': 'secret',
          'category': 'art',
          'tags': ['updated'],
          'join_approval': false,
          'post_permission': 'admin_only',
        },
      );
    });

    test('group post mutations use their scoped paths and payloads', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));
      final post = await api.createPost(
        groupId: 42,
        content: 'notice',
        isAnnouncement: true,
        mediaUrls: ['/storage/a.png'],
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/posts',
        body: {
          'content': 'notice',
          'is_announcement': true,
          'media_urls': ['/storage/a.png'],
        },
      );
      expect(post.isAnnouncement, isTrue);
      expect(post.postId, 9);
      expect(
        await api.setGroupPostPinStatus(groupId: 42, postId: 9, isPinned: true),
        isTrue,
      );
      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/groups/42/posts/9/pin-status',
        body: {'is_pinned': true},
      );
      expect(
        await api.setGroupPostLikeStatus(groupId: 42, postId: 9, liked: false),
        (liked: false, count: 12),
      );
      recorder.expectLast(
        method: 'DELETE',
        path: '/api/v2/groups/42/posts/9/likes',
      );
      await api.deleteGroupPost(groupId: 42, postId: 9);
      recorder.expectLast(
        method: 'DELETE',
        path: '/api/v2/groups/42/posts/9',
        body: {'reason': null},
      );
    });

    test('group post comments use numeric group and post ids', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      await api.comments(groupId: 42, postId: 9, page: 2, size: 10);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/groups/42/posts/9/comments',
        query: {'page': 2, 'page_size': 10, 'sort': 'newest'},
      );
      await api.comments(groupId: 42, postId: 9, commentId: 31);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/groups/42/posts/9/comments',
        query: {'page': 1, 'page_size': 20, 'sort': 'newest', 'comment_id': 31},
      );

      await api.createComment(groupId: 42, postId: 9, content: 'hi');
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/posts/9/comments',
        body: {'content': 'hi'},
      );

      final reply = await api.createComment(
        groupId: 42,
        postId: 9,
        content: 'reply',
        parentCommentId: 4,
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/posts/9/comments',
        body: {'content': 'reply', 'parent_comment_id': 4},
      );
      expect(reply.parentCommentId, 4);
      expect(reply.replyToUser?.userId, 1);
      expect(reply.canDeleteByMe, isTrue);

      final reaction = await api.setCommentLikeStatus(
        groupId: 42,
        postId: 9,
        commentId: 5,
        liked: true,
      );
      expect(reaction, (liked: true, count: 7));
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/posts/9/comments/5/likes',
      );
    });

    test('group post likes reject mismatched or malformed receipts', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));
      for (final invalid in [
        {'post_id': 10, 'is_liked': true, 'likes_count': 12},
        {'post_id': 9, 'is_liked': 1, 'likes_count': 12},
        {'post_id': 9, 'is_liked': true, 'likes_count': -1},
        {'post_id': 9, 'is_liked': true, 'likes_count': 1.5},
      ]) {
        recorder.groupPostReaction = invalid;
        await expectLater(
          api.setGroupPostLikeStatus(groupId: 42, postId: 9, liked: true),
          throwsFormatException,
        );
      }
    });

    test('notification preference uses group id endpoint', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      final preference = await api.getNotificationPreference(42);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/groups/42/notification-preference',
      );
      expect(preference.groupId, 42);
      expect(preference.isEnabled, isTrue);

      await api.setNotificationPreference(groupId: 42, isEnabled: false);
      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/groups/42/notification-preference',
        body: {'is_enabled': false},
      );
    });

    test(
      'member management uses numeric user ids and status resources',
      () async {
        final recorder = _ApiRecorder();
        final api = GroupsApi(_client(recorder));

        await api.changeMemberRole(groupId: 42, userId: 8, role: 'moderator');
        recorder.expectLast(
          method: 'PATCH',
          path: '/api/v2/groups/42/members/8/role',
          body: {'role': 'moderator'},
        );

        await api.muteMember(
          groupId: 42,
          userId: 8,
          durationHours: 24,
          reason: 'spam',
        );
        recorder.expectLast(
          method: 'PUT',
          path: '/api/v2/groups/42/members/8/mute-status',
          body: {'duration_hours': 24, 'reason': 'spam'},
        );

        await api.unmuteMember(groupId: 42, userId: 8);
        recorder.expectLast(
          method: 'DELETE',
          path: '/api/v2/groups/42/members/8/mute-status',
        );

        await api.removeMember(groupId: 42, userId: 8);
        recorder.expectLast(
          method: 'DELETE',
          path: '/api/v2/groups/42/members/8',
        );
      },
    );

    test('admission uses the membership id and a boolean decision', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));
      for (final decision in [true, false]) {
        final result = await api.approveMember(
          groupId: 42,
          memberId: 12,
          approved: decision,
        );
        recorder.expectLast(
          method: 'PUT',
          path: '/api/v2/groups/42/members/12/approval-status',
          body: {'approved': decision},
        );
        expect(result.memberId, 12);
        expect(result.status, decision ? 'active' : 'rejected');
      }
    });

    test('ownership transfer sends the next owner user id', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));

      await api.transferOwnership(groupId: 42, newOwnerId: 9);

      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/groups/42/ownership',
        body: {'new_owner_id': 9},
      );
    });

    test('invite creation decodes link and directed results', () async {
      final recorder = _ApiRecorder();
      final api = GroupsApi(_client(recorder));
      final link = await api.createInvite(42, {
        'max_uses': 100,
        'expire_hours': 168,
      });
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/invites',
        body: {'max_uses': 100, 'expire_hours': 168},
      );
      expect(link.inviteCode, '0123456789ABCDEF0123456789ABCDEF');
      expect(link.expiresAt, '2026-11-17T12:00:00.000Z');
      final directed = await api.createInvite(42, {'invitee_id': 9});
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/groups/42/invites',
        body: {'invitee_id': 9},
      );
      expect(directed.inviteId, 12);
      expect(directed.inviteCode, isNull);
    });
  });

  group('ChatApi v2 contract', () {
    test(
      'channel histories reject invalid pages before rendering or acknowledging messages',
      () async {
        final recorder = _ApiRecorder();
        final api = ChatApi(_client(recorder));
        const message = {
          'channel_id': 7,
          'group_id': 42,
          'message_id': 5,
          'is_deleted': false,
        };
        const meta = {
          'page': 2,
          'page_size': 30,
          'total': 31,
          'has_next': false,
        };
        const valid = {
          'code': 200,
          'message': 'ok',
          'data': [message],
          'meta': meta,
        };
        Future<PagedResult<V2ChatMessage>> read() =>
            api.listMessages(channelId: 7, page: 2, search: 'cat');
        recorder.channelHistoryEnvelope = valid;
        expect((await read()).items.single.messageId, 5);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/chat/channels/7/messages',
          query: {'page': 2, 'page_size': 30, 'q': 'cat'},
        );
        for (final invalid in [
          {
            ...valid,
            'meta': {...meta, 'page': 1},
          },
          {
            ...valid,
            'data': [message, message],
          },
          {
            ...valid,
            'data': [
              {...message, 'channel_id': 8},
            ],
          },
          {
            ...valid,
            'data': [
              {...message, 'is_deleted': true},
            ],
          },
        ]) {
          recorder.channelHistoryEnvelope = invalid;
          await expectLater(read(), throwsFormatException);
        }
      },
    );

    test(
      'direct conversation lookup validates the exact existing ID',
      () async {
        final recorder = _ApiRecorder();
        final api = ChatApi(_client(recorder));
        const meta = {'page': 1, 'page_size': 1, 'total': 1, 'has_next': false};
        const envelope = {
          'code': 200,
          'message': 'ok',
          'data': [_directConversationJson],
          'meta': meta,
        };
        recorder.directConversationsEnvelope = envelope;
        expect((await api.getDirectConversation(77))?.conversationId, 77);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/chat/direct-conversations',
          query: {'conversation_id': 77, 'page': 1, 'page_size': 1},
        );
        await expectLater(api.getDirectConversation(78), throwsFormatException);
        recorder.directConversationsEnvelope = {
          ...envelope,
          'data': [],
          'meta': {...meta, 'total': 0},
        };
        expect(await api.getDirectConversation(77), isNull);
      },
    );

    test(
      'direct conversations reject broken pages and malformed summaries',
      () async {
        final recorder = _ApiRecorder();
        final api = ChatApi(_client(recorder));
        const meta = {
          'page': 2,
          'page_size': 20,
          'total': 0,
          'has_next': false,
        };
        const empty = {'code': 200, 'message': 'ok', 'data': [], 'meta': meta};
        recorder.directConversationsEnvelope = empty;
        expect((await api.listConversations(page: 2)).items, isEmpty);
        for (final invalid in [
          {...empty, 'meta': null},
          {...empty, 'data': null},
          {
            ...empty,
            'data': [_directConversationJson, _directConversationJson],
          },
          {
            ...empty,
            'data': [
              {..._directConversationJson, 'participant': null},
            ],
          },
          {
            ...empty,
            'data': [
              {..._directConversationJson, 'unread_count': -1},
            ],
          },
        ]) {
          recorder.directConversationsEnvelope = invalid;
          await expectLater(
            api.listConversations(page: 2),
            throwsFormatException,
          );
        }
      },
    );

    test(
      'direct history requires matching page metadata and unique messages from the conversation',
      () async {
        final recorder = _ApiRecorder();
        final api = ChatApi(_client(recorder));
        const message = {
          'conversation_id': 77,
          'message_id': 7,
          'author': {'user_id': 42},
          'content': 'hello',
          'created_at': '2026-11-20T10:00:00Z',
          'is_deleted': false,
        };
        const meta = {
          'page': 2,
          'page_size': 20,
          'total': 22,
          'has_next': false,
        };
        const envelope = {
          'code': 200,
          'message': 'ok',
          'data': [message],
          'meta': meta,
        };
        Future<PagedResult<V2DirectMessage>> readHistory() =>
            api.listDirectMessages(conversationId: 77, page: 2, size: 20);
        recorder.directHistoryEnvelope = envelope;
        expect((await readHistory()).items.single.messageId, 7);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/chat/direct-conversations/77/messages',
          query: {'page': 2, 'page_size': 20},
        );
        for (final invalid in [
          {...envelope, 'meta': null},
          {
            ...envelope,
            'meta': {...meta, 'page': 1},
          },
          {
            ...envelope,
            'meta': {...meta, 'page': '2'},
          },
          {
            ...envelope,
            'data': {'items': []},
          },
          {
            ...envelope,
            'data': [message, message],
          },
          {
            ...envelope,
            'data': [
              {...message, 'conversation_id': 78},
            ],
          },
          {
            ...envelope,
            'data': [
              {...message, 'is_deleted': true},
            ],
          },
        ]) {
          recorder.directHistoryEnvelope = invalid;
          await expectLater(readHistory(), throwsFormatException);
        }
      },
    );

    test('channel list accepts only unique IDs from its group', () async {
      final recorder = _ApiRecorder();
      final api = ChatApi(_client(recorder));
      const channel = {'channel_id': 7, 'group_id': 42};
      recorder.channelListReceipt = [channel];
      expect((await api.listChannels(42)).single.channelId, 7);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/chat/groups/42/channels',
      );
      recorder.channelListReceipt = [];
      expect(await api.listChannels(42), isEmpty);
      for (final invalid in [
        null,
        {'items': []},
        [channel, channel],
        [
          {...channel, 'group_id': 9},
        ],
        [
          {...channel, 'channel_id': '7'},
        ],
      ]) {
        recorder.channelListReceipt = invalid;
        await expectLater(api.listChannels(42), throwsFormatException);
      }
    });

    test('chat lists decode v2 list data from envelope meta', () async {
      final recorder = _ApiRecorder();
      final api = ChatApi(_client(recorder));

      final conversations = await api.listConversations(page: 2);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/chat/direct-conversations',
        query: {'page': 2, 'page_size': 20},
      );
      expect(conversations.items, hasLength(1));
      expect(conversations.items.single.conversationId, 77);
      expect(conversations.items.single.lastMessage?.content, 'hello');
      expect(conversations.page, 2);

      final groups = await api.listChatGroups(page: 2);
      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/chat/groups',
        query: {'page': 2, 'page_size': 20},
      );
      expect(groups.items, hasLength(1));
      expect(groups.items.single.groupId, 42);
      expect(groups.items.single.channelCount, 1);
      expect(groups.page, 2);
      expect(groups.hasNext, isTrue);
    });

    test('message reactions and pinning match server route names', () async {
      final recorder = _ApiRecorder();
      final api = ChatApi(_client(recorder));

      final added = await api.reactMessage(messageId: 5, emoji: '👍');
      expect(added.reactions.single.reactedByMe, isTrue);
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/chat/messages/5/reactions',
        body: {'emoji': '👍'},
      );
      final removed = await api.unreactMessage(messageId: 5, emoji: '👍');
      expect(removed.reactions.single.reactedByMe, isFalse);
      recorder.expectLast(
        method: 'DELETE',
        path: '/api/v2/chat/messages/5/reactions',
        body: {'emoji': '👍'},
      );

      await api.pinMessage(5);
      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/chat/messages/5/pin-status',
        body: {'is_pinned': true},
      );
      recorder.messageWriteEnvelope = {
        'code': 200,
        'message': 'chat message pin status updated',
        'data': {
          'message_id': 5,
          'channel_id': 7,
          'group_id': 42,
          'is_deleted': false,
          'is_pinned': false,
        },
        'meta': null,
      };
      await expectLater(api.pinMessage(5), throwsFormatException);
      expect((await api.unpinMessage(5)).isPinned, isFalse);
      await expectLater(api.deleteMessage(5), throwsFormatException);
      recorder.messageWriteEnvelope = {
        'code': 200,
        'message': 'chat message deleted',
        'data': null,
        'meta': null,
      };
      await api.deleteMessage(5);
    });

    test('channel management endpoints match current server API', () async {
      final recorder = _ApiRecorder();
      final api = ChatApi(_client(recorder));
      recorder.channelWriteEnvelope = {
        'code': 200,
        'message': 'chat channel updated',
        'data': {'channel_id': 12, 'group_id': 42},
        'meta': null,
      };

      await api.updateChannel(
        channelId: 12,
        name: 'team-room',
        category: 'Ops',
        isPrivate: true,
      );
      recorder.expectLast(
        method: 'PATCH',
        path: '/api/v2/chat/channels/12',
        body: {'name': 'team-room', 'category': 'Ops', 'is_private': true},
      );

      recorder.channelWriteEnvelope = {
        'code': 200,
        'message': 'chat channel deleted',
        'data': null,
        'meta': null,
      };
      await api.deleteChannel(12);
      recorder.expectLast(method: 'DELETE', path: '/api/v2/chat/channels/12');
    });
  });

  group('ModerationApi v2 contract', () {
    test('appeal decision uses the shared status and reply fields', () async {
      final recorder = _ApiRecorder();
      final api = ModerationApi(_client(recorder));
      await api.updateAppeal(
        appealId: 12,
        status: 'approved',
        response: 'Reviewed',
      );
      recorder.expectLast(
        method: 'PATCH',
        path: '/api/v2/moderation/appeals/12',
        body: {'appeal_status': 'approved', 'admin_response': 'Reviewed'},
      );
    });

    test('content and user actions use action endpoints', () async {
      final recorder = _ApiRecorder();
      final api = ModerationApi(_client(recorder));

      await api.resolveContent(postId: 11, action: 'approve');
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

    test('settings update sends settings list and decodes response', () async {
      final recorder = _ApiRecorder();
      final api = ModerationApi(_client(recorder));

      final settings = await api.updateSettings({
        'settings': [
          {'key': 'auto_hide_report_threshold', 'value': '12'},
          {'key': 'require_note_on_reject', 'value': 'false'},
        ],
      });

      recorder.expectLast(
        method: 'PATCH',
        path: '/api/v2/moderation/settings',
        body: {
          'settings': [
            {'key': 'auto_hide_report_threshold', 'value': '12'},
            {'key': 'require_note_on_reject', 'value': 'false'},
          ],
        },
      );
      expect(settings, hasLength(2));
      expect(settings.first.key, 'auto_hide_report_threshold');
      expect(settings.first.value, '12');
      expect(settings[1].value, 'false');
    });
  });

  group('NotificationsApi v2 contract', () {
    test(
      'batch read sends explicit read state and empty selection is a no-op',
      () async {
        final recorder = _ApiRecorder();
        final api = NotificationsApi(_client(recorder));

        await api.markRead([3, 7]);
        recorder.expectLast(
          method: 'PUT',
          path: '/api/v2/notifications/read-status',
          body: {
            'notification_ids': [3, 7],
            'is_read': true,
          },
        );
        await api.markRead([]);
        recorder.expectLast(
          method: 'PUT',
          path: '/api/v2/notifications/read-status',
          body: {
            'notification_ids': [3, 7],
            'is_read': true,
          },
        );
        await api.markAllRead();
        recorder.expectLast(
          method: 'PUT',
          path: '/api/v2/notifications/read-status',
          body: {'is_read': true},
        );
      },
    );
    for (final total in [7, 0]) {
      test('unread count uses filtered list total ($total)', () async {
        final recorder = _ApiRecorder(unreadNotificationTotal: total);
        final api = NotificationsApi(_client(recorder));

        expect(await api.unreadCount(), total);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/notifications',
          query: {'page': 1, 'page_size': 1, 'unread_only': 'true'},
        );
      });
    }

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

      await api.deleteNotification(3);
      recorder.expectLast(method: 'DELETE', path: '/api/v2/notifications/3');

      await api.restoreNotification(3);
      recorder.expectLast(
        method: 'PUT',
        path: '/api/v2/notifications/3/restore-status',
      );
    });

    test('notification actions reject unconfirmed writes', () async {
      final recorder = _ApiRecorder();
      final api = NotificationsApi(_client(recorder));

      recorder.notificationWriteEnvelope = {
        'code': 200,
        'message': 'success',
        'data': {'notification_id': 4, 'is_read': 1, 'read_at': '2026-11-20'},
        'meta': null,
      };
      await expectLater(
        api.setReadStatus(notificationId: 3, isRead: true),
        throwsFormatException,
      );
      await expectLater(api.restoreNotification(3), throwsFormatException);
      await expectLater(api.deleteNotification(3), throwsFormatException);
    });
  });

  group('UsersApi v2 contract', () {
    test(
      'current profile requires its success envelope and numeric ID',
      () async {
        final recorder = _ApiRecorder();
        final api = UsersApi(_client(recorder));
        final receipt = <String, Object?>{
          'code': 200,
          'message': 'success',
          'meta': null,
          'data': {..._publicUserJson, 'user_id': 42},
        };
        recorder.currentProfileEnvelope = receipt;
        expect((await api.getMe()).userId, 42);
        recorder.expectLast(method: 'GET', path: '/api/v2/users/me');

        for (final invalid in [
          {...receipt}..remove('meta'),
          {...receipt, 'message': 'OK'},
          {
            ...receipt,
            'data': {'user_id': '42'},
          },
        ]) {
          recorder.currentProfileEnvelope = invalid;
          await expectLater(api.getMe(), throwsFormatException);
        }
      },
    );

    test(
      'public profile accepts only the requested numeric identity',
      () async {
        final recorder = _ApiRecorder();
        final api = UsersApi(_client(recorder));
        recorder.publicProfileReceipt = {..._publicUserJson, 'user_id': 42};
        expect((await api.getUserById(42)).userId, 42);
        recorder.expectLast(method: 'GET', path: '/api/v2/users/42');
        for (final data in [
          null,
          {..._publicUserJson, 'user_id': 43},
          {..._publicUserJson, 'user_id': '42'},
        ]) {
          recorder.publicProfileReceipt = data;
          await expectLater(api.getUserById(42), throwsFormatException);
        }
        await expectLater(api.getUserById(0), throwsFormatException);
      },
    );

    test(
      'account statements use shared filters and owner mutation payloads',
      () async {
        final recorder = _ApiRecorder();
        final api = UsersApi(_client(recorder));
        final page = await api.getStatements(status: 'unread', type: 'warning');
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/users/me/account-statements',
          query: {
            'page': 1,
            'page_size': 20,
            'status': 'unread',
            'type': 'warning',
          },
        );
        expect(page.items.single.statementId, 9);
        await api.changeStatementStatus(9, 'mark_read');
        recorder.expectLast(
          method: 'PATCH',
          path: '/api/v2/users/me/account-statements/9',
          body: {'action': 'mark_read'},
        );
        await api.submitStatementAppeal(9, 'Please review');
        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/users/me/account-statements/9/appeals',
          body: {'appeal_message': 'Please review'},
        );
      },
    );

    test(
      'profile, follow, and email endpoints match current server API',
      () async {
        final recorder = _ApiRecorder()
          ..publicProfileReceipt = {..._publicUserJson, 'user_id': 42};
        final api = UsersApi(_client(recorder));

        expect((await api.getUserById(42)).userId, 42);
        recorder.expectLast(method: 'GET', path: '/api/v2/users/42');

        await api.followUser(42);
        recorder.expectLast(method: 'POST', path: '/api/v2/users/42/followers');

        await api.unfollowUser(42);
        recorder.expectLast(
          method: 'DELETE',
          path: '/api/v2/users/42/followers',
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

        await api.deleteMe(
          password: 'current-password',
          confirmation: 'DELETE',
        );
        recorder.expectLast(
          method: 'DELETE',
          path: '/api/v2/users/me',
          body: {'password': 'current-password', 'confirmation': 'DELETE'},
        );
      },
    );

    test(
      'user discovery decodes the shared search and recommendation lists',
      () async {
        final recorder = _ApiRecorder();
        final api = UsersApi(_client(recorder));
        final results = await api.searchUsers('Alice', page: 2, size: 3);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/users',
          query: {'q': 'Alice', 'page': 2, 'page_size': 3, 'sort': 'popular'},
        );
        expect(results.items.single.username, _publicUserJson['username']);
        expect(results.total, 7);
        expect(results.hasNext, true);
        final recommendations = await api.getRecommendations(limit: 6);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/users/recommendations',
          query: {'limit': 6},
        );
        expect(recommendations.single.userId, results.items.single.userId);
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

      await api.muteUser(
        12,
        expiresAt: DateTime.parse('2027-01-01T08:00:00+08:00'),
      );
      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/users/me/mutes/12',
        body: {'expires_at': '2027-01-01T00:00:00.000Z'},
      );

      await api.unmuteUser(12);
      recorder.expectLast(method: 'DELETE', path: '/api/v2/users/me/mutes/12');
    });

    test(
      'two-factor setup, confirm, and disable match server payloads',
      () async {
        final recorder = _ApiRecorder();
        final api = UsersApi(_client(recorder));

        await api.setupTwoFactor(password: 'current-password');
        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/users/me/two-factor/setup',
          body: {'password': 'current-password'},
        );

        await api.confirmTwoFactor(code: '123456');
        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/users/me/two-factor/confirm',
          body: {'code': '123456'},
        );

        await api.disableTwoFactor(
          password: 'current-password',
          code: '654321',
        );
        recorder.expectLast(
          method: 'DELETE',
          path: '/api/v2/users/me/two-factor',
          body: {'password': 'current-password', 'code': '654321'},
        );
      },
    );

    test('avatar update uploads multipart avatar file', () async {
      final recorder = _ApiRecorder();
      final api = UsersApi(_client(recorder));

      final avatar = await api.uploadAvatarBytes(
        bytes: Uint8List.fromList([137, 80, 78, 71]),
        fileName: 'avatar.png',
        mimeType: 'image/png',
      );

      recorder.expectLast(method: 'PUT', path: '/api/v2/users/me/avatar');
      final request = recorder.requests.last;
      expect(request.data, isA<FormData>());
      final form = request.data as FormData;
      expect(form.files.single.key, 'avatar');
      expect(form.fields, isEmpty);
      expect(avatar.avatarUrl, '/uploads/avatars/edge.png');
      expect(avatar.avatarMediaId, 99);
    });

    test(
      'user analytics and daily analytics decode current v2 endpoints',
      () async {
        final recorder = _ApiRecorder();
        final api = UsersApi(_client(recorder));

        final analytics = await api.getUserAnalytics(1);
        recorder.expectLast(method: 'GET', path: '/api/v2/users/1/analytics');
        expect(analytics.totalPosts, 12);
        expect(analytics.postsThisWeek, 3);
        expect(analytics.totalLikesReceived, 40);
        expect(analytics.engagementScore, 9.5);

        final daily = await api.getUserDailyAnalytics(1, days: 14);
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/users/1/analytics/daily',
          query: {'days': 14},
        );
        expect(daily, hasLength(1));
        expect(daily.single.day, '2026-05-24');
        expect(daily.single.postsCount, 2);
        expect(daily.single.likesReceived, 6);
      },
    );
  });

  group('SentimentFlowApi v2 contract', () {
    test('config decodes current integration info shape', () async {
      final recorder = _ApiRecorder();
      final api = SentimentFlowApi(_client(recorder));

      final config = await api.config();

      recorder.expectLast(
        method: 'GET',
        path: '/api/v2/integrations/sentiment-flow/config',
      );
      expect(config.enabled, isTrue);
      expect(config.baseUrlConfigured, isTrue);
      expect(config.proxyBasePath, '/api/v2/integrations/sentiment-flow');
      expect(config.timeoutMs, 10000);
    });

    test(
      'prediction uses proxy path and decodes normalized nested data',
      () async {
        final recorder = _ApiRecorder();
        final api = SentimentFlowApi(_client(recorder));

        final prediction = await api.predict(
          text: 'NekoTribe is lovely',
          modelId: 'bert-v1',
          returnProbabilities: true,
          includeMetadata: true,
          topK: 2,
        );

        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/integrations/sentiment-flow/predict/',
          body: {
            'text': 'NekoTribe is lovely',
            'model': 'bert',
            'model_id': 'bert-v1',
            'return_probabilities': true,
            'include_metadata': true,
            'top_k': 2,
          },
        );
        expect(prediction.label, 'positive');
        expect(prediction.confidence, 0.91);
        expect(prediction.score, 0.88);
        expect(prediction.requestId, 'sent-1');
        expect(prediction.modelName, 'BERT v1');
        expect(prediction.probabilities?['positive'], 0.91);
        expect(prediction.topK, hasLength(2));
      },
    );

    test(
      'prediction normalizes LSTM model ids for the proxy runtime',
      () async {
        final recorder = _ApiRecorder();
        final api = SentimentFlowApi(_client(recorder));

        await api.predict(text: 'NekoTribe is fast', modelId: 'lstm-v1');

        recorder.expectLast(
          method: 'POST',
          path: '/api/v2/integrations/sentiment-flow/predict/',
          body: {
            'text': 'NekoTribe is fast',
            'model': 'lstm',
            'model_id': 'lstm-v1',
          },
        );
      },
    );

    test('prediction decodes raw SentimentFlow proxy payloads', () async {
      final recorder = _ApiRecorder();
      final api = SentimentFlowApi(_client(recorder));

      final prediction = await api.predict(
        text: '432423',
        returnProbabilities: true,
        includeMetadata: true,
        topK: 3,
      );

      recorder.expectLast(
        method: 'POST',
        path: '/api/v2/integrations/sentiment-flow/predict/',
        body: {
          'text': '432423',
          'return_probabilities': true,
          'include_metadata': true,
          'top_k': 3,
        },
      );
      expect(prediction.label, 'neutral');
      expect(prediction.score, 0.5);
      expect(prediction.confidence, 0.5);
      expect(prediction.modelName, '关键词基线');
      expect(prediction.probabilities?['neutral'], 0.5);
      expect(prediction.topK?.first.label, 'neutral');
    });

    test(
      'model and stats endpoints use SentimentFlow proxy resources',
      () async {
        final recorder = _ApiRecorder();
        final api = SentimentFlowApi(_client(recorder));

        final models = await api.listModels();
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/integrations/sentiment-flow/models/',
        );
        expect(models.items.single.modelId, 'bert-v1');
        expect(models.items.single.isActive, isTrue);

        final active = await api.getActiveModel();
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/integrations/sentiment-flow/models/active',
        );
        expect(active.modelId, 'bert-v1');

        await api.setActiveModel('bert-v2');
        recorder.expectLast(
          method: 'PUT',
          path: '/api/v2/integrations/sentiment-flow/models/active',
          body: {'model_id': 'bert-v2'},
        );

        final stats = await api.statsOverview();
        recorder.expectLast(
          method: 'GET',
          path: '/api/v2/integrations/sentiment-flow/stats/overview',
        );
        expect(stats.totalPredictions, 12);
        expect(stats.totalTrainingJobs, 3);
      },
    );
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
  _ApiRecorder({this.unreadNotificationTotal = 7});

  final int unreadNotificationTotal;
  Object? aiMessageHistory;
  Map<String, Object?>? notificationWriteEnvelope;
  Object? retweetReceipt = {'post_id': 53, 'repost_of_post_id': 42};
  Object? createPostReceipt = _postJson;
  Object? postDetailReceipt = {..._postJson, 'post_id': 42};
  Object? groupDetailReceipt = _groupJson;
  Map<String, Object?>? channelWriteEnvelope;
  Object? channelListReceipt;
  Map<String, Object?>? directHistoryEnvelope;
  Map<String, Object?>? channelHistoryEnvelope;
  Map<String, Object?>? directConversationsEnvelope;
  Object? publicProfileReceipt;
  Map<String, Object?>? currentProfileEnvelope;
  Map<String, Object?>? messageWriteEnvelope;
  Map<String, Object?> updatePostEnvelope = {
    'code': 200,
    'message': 'post updated',
    'data': <String, Object?>{
      'post_id': 42,
      'author': {'user_id': 9},
      'viewer_state': {'can_delete': true},
    },
    'meta': null,
  };
  Object? deletePostEnvelope = <String, Object?>{
    'code': 200,
    'message': 'post deleted',
    'data': null,
    'meta': null,
  };
  Map<String, Object?> postLikeReceipt = {
    'post_id': 9,
    'is_liked': true,
    'likes_count': 42,
  };
  Map<String, Object?> postBookmarkReceipt = {
    'post_id': 9,
    'is_bookmarked': true,
  };
  Map<String, Object?> groupPostReaction = {
    'post_id': 9,
    'is_liked': false,
    'likes_count': 12,
  };
  Object? availabilityResult = {'knowledge': true, 'writing': false};
  Map<String, Object?> knowledgeResult = {
    'status': 'insufficient_evidence',
    'message': null,
  };
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (channelHistoryEnvelope != null &&
        options.path == '/api/v2/chat/channels/7/messages' &&
        options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode(channelHistoryEnvelope),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (directConversationsEnvelope != null &&
        options.path == '/api/v2/chat/direct-conversations' &&
        options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode(directConversationsEnvelope),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (directHistoryEnvelope != null &&
        options.path == '/api/v2/chat/direct-conversations/77/messages' &&
        options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode(directHistoryEnvelope),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (currentProfileEnvelope != null &&
        options.path == '/api/v2/users/me' &&
        options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode(currentProfileEnvelope),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (messageWriteEnvelope != null &&
        [
          '/api/v2/chat/messages/5',
          '/api/v2/chat/messages/5/pin-status',
        ].contains(options.path)) {
      return ResponseBody.fromString(
        jsonEncode(messageWriteEnvelope),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (channelWriteEnvelope != null &&
        (options.path == '/api/v2/chat/groups/42/channels' ||
            RegExp(r'^/api/v2/chat/channels/\d+$').hasMatch(options.path))) {
      return ResponseBody.fromString(
        jsonEncode(channelWriteEnvelope),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.path.startsWith('/api/v2/notifications/3') &&
        ['PUT', 'DELETE'].contains(options.method)) {
      final deleting = options.method == 'DELETE';
      final reading = options.path.endsWith('/read-status');
      return ResponseBody.fromString(
        jsonEncode(
          notificationWriteEnvelope ??
              {
                'code': 200,
                'message': deleting ? 'notification deleted' : 'success',
                'data': deleting
                    ? null
                    : reading
                    ? {
                        'notification_id': 3,
                        'is_read': 1,
                        'read_at': '2026-11-20',
                      }
                    : {'notification_id': 3, 'deleted_at': null},
                'meta': null,
              },
        ),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.path == '/api/v2/posts/42' &&
        (options.method == 'DELETE' || options.method == 'PATCH')) {
      return ResponseBody.fromString(
        jsonEncode(
          options.method == 'DELETE' ? deletePostEnvelope : updatePostEnvelope,
        ),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final meta = _metaFor(options);
    final data = _dataFor(options);
    if (_isRawProxyResponse(options.path)) {
      return ResponseBody.fromString(
        jsonEncode(data),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'code': 200,
        'message': 'success',
        'data': data,
        'meta': meta,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  bool _isRawProxyResponse(String path) {
    return path.startsWith('/api/v2/integrations/sentiment-flow/') &&
        path != '/api/v2/integrations/sentiment-flow/config';
  }

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
    if (options.path == '/api/v2/users/42' && options.method == 'GET') {
      return publicProfileReceipt;
    }
    if (options.method == 'GET' &&
        (options.path.startsWith('/api/v2/groups/by-slug/') ||
            RegExp(r'^/api/v2/groups/\d+$').hasMatch(options.path))) {
      return groupDetailReceipt;
    }
    if (options.path == '/api/v2/posts/42' && options.method == 'GET') {
      return postDetailReceipt;
    }
    if (options.path == '/api/v2/posts/9/likes') return postLikeReceipt;
    if (options.path == '/api/v2/posts/9/bookmarks') return postBookmarkReceipt;
    if (options.path == '/api/v2/posts/42/retweets' &&
        options.method == 'POST') {
      return retweetReceipt;
    }
    if (options.path == '/api/v2/moderation/content/bulk-actions') {
      return {'processed_count': 2};
    }
    if (options.path == '/api/v2/auth/sessions' && options.method == 'GET') {
      return [
        {
          'session_id': 'secondary',
          'device_info': 'Fixture device',
          'ip_address': '',
          'last_accessed_at': '2026-01-01T10:00:00Z',
          'created_at': '2026-01-01T09:00:00Z',
          'is_current': false,
        },
      ];
    }
    if (options.path == '/api/v2/groups/42/posts' && options.method == 'POST') {
      return {
        'post_id': 9,
        'group_id': 42,
        'content': 'notice',
        'is_announcement': true,
        'author': _publicUserJson,
        'media_urls': ['/storage/a.png'],
      };
    }
    if (options.path == '/api/v2/groups/42/posts/9/pin-status') {
      return {'post_id': 9, 'is_pinned': true};
    }
    if (options.path == '/api/v2/groups/42/posts/9/likes') {
      return groupPostReaction;
    }
    if (options.path == '/api/v2/groups/42/posts/9/comments/5/likes') {
      return {'comment_id': 5, 'is_liked': true, 'likes_count': 7};
    }
    if (options.path == '/api/v2/groups/42/posts/9' &&
        options.method == 'DELETE') {
      return null;
    }
    if (options.path == '/api/v2/groups/42' && options.method == 'DELETE') {
      return null;
    }
    if (options.path == '/api/v2/users/me' && options.method == 'DELETE') {
      return {'deleted': true, 'user_id': 1};
    }
    if (options.path == '/api/v2/users/me/email') {
      return {
        'email': options.data['new_email'],
        'email_verified_at': '2026-01-02T03:04:05.000Z',
      };
    }
    final path = options.path;
    if (path == '/api/v2/ai/availability') return availabilityResult;
    if (path == '/api/v2/ai/conversations') {
      if (options.method == 'GET') {
        return {
          'items': [
            {
              'conversation_id': 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb',
              'purpose': 'writing',
              'title': 'previous draft',
              'updated_at': '2026-01-01',
            },
          ],
          'next_cursor': null,
        };
      }
      return {'conversation_id': 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb'};
    }
    if (path.startsWith('/api/v2/ai/conversations/') &&
        path.endsWith('/knowledge-generate')) {
      return knowledgeResult;
    }
    if (path.startsWith('/api/v2/ai/conversations/') &&
        path.endsWith('/messages') &&
        options.method == 'GET') {
      return aiMessageHistory ??
          [
            {
              'conversation_id': path.split('/')[5],
              'message_id': 'a',
              'sequence_no': 2,
              'role': 'assistant',
              'content': 'draft',
            },
          ];
    }
    if (path.startsWith('/api/v2/ai/conversations/') &&
        path.endsWith('/messages') &&
        options.method == 'POST') {
      return {
        'conversation_id': path.split('/')[5],
        'message_id': 'u',
        'sequence_no': 1,
        'role': 'user',
      };
    }
    if (path.startsWith('/api/v2/ai/conversations/')) {
      return {
        'conversation_id': path.split('/')[5],
        'message_id': 'a',
        'sequence_no': 2,
        'role': 'assistant',
      };
    }
    if (path == '/api/v2/posts/1/comments') {
      return <Object>[_postCommentJson];
    }
    if (path == '/api/v2/posts' && options.method == 'POST') {
      return createPostReceipt;
    }
    if (path == '/api/v2/posts') {
      return <Object>[_postJson];
    }
    if (path == '/api/v2/recommendations/feedback' &&
        options.method == 'POST') {
      return {'accepted': true};
    }
    if (path == '/api/v2/posts/100001/analytics') {
      return {
        'post_id': 100001,
        'views_count': 32,
        'likes_count': 8,
        'comments_count': 3,
        'replies_count': 2,
        'retweets_count': 1,
        'engagement_score': 14.5,
        'like_rate': 0.25,
      };
    }
    if (path == '/api/v2/tags/trending') {
      return [
        {'tag_id': 17, 'name': 'Cats', 'is_trending': 1},
      ];
    }
    if (path == '/api/v2/tags/C%23%20cats/analytics') {
      return {
        'name': 'C# cats',
        'total_posts': 4,
        'total_authors': 2,
        'total_views': 30,
        'total_likes': 5,
        'engagement_score': 12.25,
      };
    }
    if (path == '/api/v2/groups') {
      return <Object>[_groupJson];
    }
    if (path == '/api/v2/groups/42/members') {
      return [
        {
          'member_id': 12,
          'user': _publicUserJson,
          'role': 'member',
          'role_desc': 'Member',
          'status': 'muted',
          'nickname': null,
          'mute_until': '2026-12-01T00:00:00.000Z',
          'joined_at': '2026-11-01T00:00:00.000Z',
        },
      ];
    }
    if (path == '/api/v2/groups/42/members/12/approval-status') {
      return {
        'member_id': 12,
        'status': options.data['approved'] == true ? 'active' : 'rejected',
      };
    }
    if (path == '/api/v2/groups/invite-codes/ABC') {
      return {
        'is_valid': true,
        'group': _groupJson,
        'inviter': _publicUserJson,
        'message': 'Welcome',
      };
    }
    if (path == '/api/v2/groups/42/members/current' &&
        options.method == 'POST') {
      return {'group_id': 42, 'role': 'member', 'status': 'active'};
    }
    if (path == '/api/v2/groups/invites/7/responses') {
      return {
        'invite_id': 7,
        'group_id': 42,
        'status': options.data['accept'] == true ? 'accepted' : 'rejected',
      };
    }
    if (path == '/api/v2/groups/42/invites' && options.method == 'POST') {
      final code = options.data['invitee_id'] == null
          ? '0123456789ABCDEF0123456789ABCDEF'
          : null;
      return {
        'invite_id': 12,
        'invite_code': code,
        'invite_url': code == null ? null : '/groups/invite/$code',
        'expires_at': '2026-11-17T12:00:00.000Z',
      };
    }
    if (path == '/api/v2/groups/42/ownership') {
      return {'group_id': 42, 'owner_id': options.data['new_owner_id']};
    }
    if (path == '/api/v2/chat/direct-conversations') {
      if (options.method == 'POST') {
        return {
          ..._directConversationJson,
          'participant': {..._publicUserJson, 'user_id': 42},
        };
      }
      return <Object>[_directConversationJson];
    }
    if (path == '/api/v2/chat/direct-conversations/77/messages' &&
        options.method == 'POST') {
      return {
        'conversation_id': 77,
        'message_id': 9,
        'is_deleted': false,
        'content': 'hi',
        'author': _publicUserJson,
      };
    }
    if (path == '/api/v2/chat/groups') {
      return <Object>[_chatGroupJson];
    }
    if (path == '/api/v2/chat/groups/42/channels' && options.method == 'GET') {
      return channelListReceipt;
    }
    if (path == '/api/v2/chat/messages/5/reactions') {
      return {
        'message_id': 5,
        'channel_id': 7,
        'group_id': 42,
        'message_type': 'text',
        'is_deleted': false,
        'reactions': [
          {
            'emoji': '👍',
            'count': 7,
            'reacted_by_me': options.method == 'POST',
          },
        ],
      };
    }
    if (path == '/api/v2/chat/messages/5/pin-status') {
      return {
        'message_id': 5,
        'channel_id': 7,
        'group_id': 42,
        'is_deleted': false,
        'is_pinned': options.data['is_pinned'],
      };
    }
    if (path == '/api/v2/notifications') {
      if (options.queryParameters['unread_only'] == 'true' &&
          unreadNotificationTotal == 0) {
        return <Object>[];
      }
      return <Object>[_notificationJson];
    }
    if (path == '/api/v2/moderation/settings') {
      if (options.method == 'PATCH') {
        final settings = options.data['settings'] as List<dynamic>;
        return settings
            .map((item) => _moderationSettingJson(item as Map<String, dynamic>))
            .toList(growable: false);
      }
      return <Object>[
        _moderationSettingJson({
          'key': 'auto_hide_report_threshold',
          'value': '10',
        }),
      ];
    }
    if (path == '/api/v2/integrations/sentiment-flow/config') {
      return {
        'enabled': true,
        'baseUrlConfigured': true,
        'proxyBasePath': '/api/v2/integrations/sentiment-flow',
        'timeoutMs': 10000,
      };
    }
    if (path == '/api/v2/integrations/sentiment-flow/predict/') {
      if (options.data['text'] == '432423') {
        return {
          'text': '432423',
          'score': 3,
          'label': 'neutral',
          'label_zh': '中性',
          'confidence': 0.5,
          'probabilities': [0.1, 0.1, 0.1, 0.5, 0.1, 0.1],
          'reasoning': '模型将文本情感强度判定为 3 分（中性）。',
          'source': 'keyword-baseline-fallback(lstm:RuntimeError)',
          'model_name': '关键词基线',
        };
      }
      return {
        'request_id': 'sent-1',
        'model': {'id': 'bert-v1', 'name': 'BERT v1', 'version': '1.0.0'},
        'input': {'text': options.data['text'], 'language': 'en', 'length': 19},
        'prediction': {
          'label': 'positive',
          'score': 0.88,
          'confidence': 0.91,
          'probabilities': {'positive': 0.91, 'neutral': 0.07},
          'top_k': [
            {'label': 'positive', 'score': 0.91},
            {'label': 'neutral', 'score': 0.07},
          ],
        },
        'timing_ms': 37,
        'created_at': '2026-05-24T00:00:00.000Z',
      };
    }
    if (path == '/api/v2/integrations/sentiment-flow/models/') {
      return {
        'items': [
          {
            'model_id': 'bert-v1',
            'name': 'BERT v1',
            'version': '1.0.0',
            'type': 'bert',
            'path': 'models/bert-v1.pt',
            'size_mb': 98.5,
            'best_f1': 0.93,
            'best_mae': 0.21,
            'best_qwk': 0.88,
            'best_epoch': 4,
            'is_active': true,
            'created_at': '2026-05-24T00:00:00.000Z',
          },
        ],
        'total': 1,
      };
    }
    if (path == '/api/v2/integrations/sentiment-flow/models/active') {
      return {
        'model_id': options.data is Map<String, dynamic>
            ? options.data['model_id']
            : 'bert-v1',
        'name': 'BERT v1',
        'version': '1.0.0',
        'activated_at': '2026-05-24T00:00:00.000Z',
      };
    }
    if (path == '/api/v2/integrations/sentiment-flow/stats/overview') {
      return {
        'total_predictions': 12,
        'total_training_jobs': 3,
        'active_model': {
          'model_id': 'bert-v1',
          'name': 'BERT v1',
          'version': '1.0.0',
          'activated_at': '2026-05-24T00:00:00.000Z',
        },
      };
    }
    if (path == '/api/v2/auth/otp') {
      return {
        'account': options.data['account'],
        'verification_id': 'otp-1',
        'expires_at': '2026-05-24T00:05:00.000Z',
      };
    }
    if (path == '/api/v2/auth/registration') {
      return {'user': _selfUserJson};
    }
    if (path == '/api/v2/users/me/two-factor/setup') {
      return {
        'secret': 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567',
        'otpauth_url':
            'otpauth://totp/NekoTribe:edge?secret=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567&issuer=NekoTribe&algorithm=SHA1&digits=6&period=30',
      };
    }
    if (path == '/api/v2/users/me/two-factor/confirm') {
      return {
        'enabled': true,
        'recovery_codes': List.filled(10, 'ABCDE-FGHIJ-KLMNO'),
      };
    }
    if (path == '/api/v2/users/me/two-factor') {
      return {'enabled': false};
    }
    if (path == '/api/v2/users/me/avatar') {
      return {'avatar_url': '/uploads/avatars/edge.png', 'avatar_media_id': 99};
    }
    if (path == '/api/v2/users/1/analytics') {
      return {
        'user_id': 1,
        'total_posts': 12,
        'posts_this_week': 3,
        'posts_this_month': 7,
        'total_likes_received': 40,
        'avg_likes_per_post': 3.3,
        'total_likes_given': 18,
        'total_comments_made': 11,
        'engagement_score': 9.5,
      };
    }
    if (path == '/api/v2/users/1/analytics/daily') {
      return [
        {
          'day': '2026-05-24',
          'posts_count': 2,
          'likes_received': 6,
          'comments_received': 4,
          'retweets_received': 1,
          'likes_given': 3,
          'comments_made': 2,
          'engagement_score': 12.5,
        },
      ];
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
    if (path.endsWith('/notification-preference')) {
      return {
        'user_id': 8,
        'group_id': 42,
        'is_enabled': options.method == 'PUT'
            ? options.data['is_enabled']
            : true,
        'updated_at': '2026-05-24T00:00:00.000Z',
      };
    }
    if (path.contains('/groups/') && path.contains('/members/')) {
      return {
        'member_id': 700,
        'user_id': 8,
        'status': 'active',
        'role': options.data is Map<String, dynamic>
            ? options.data['role'] ?? 'member'
            : 'member',
        'mute_until': null,
      };
    }
    if (path.contains('/by-slug/')) {
      return _groupJson;
    }
    if (path.contains('/groups/') && path.contains('/comments')) {
      if (options.method == 'POST') {
        final parent = options.data['parent_comment_id'];
        return {
          ..._groupCommentJson,
          'parent_comment_id': parent,
          'reply_to_user': parent == null ? null : _publicUserJson,
        };
      }
      return {
        'items': <Object>[_groupCommentJson],
        'meta': {'page': 1, 'page_size': 20, 'total': 1, 'has_next': false},
      };
    }
    if (path == '/api/v2/users' || path == '/api/v2/users/recommendations') {
      return [_publicUserJson];
    }
    if (path == '/api/v2/users/me/account-statements') {
      return [
        {'statement_id': 9, 'type': 'warning', 'status': 'unread'},
      ];
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
    if (options.path == '/api/v2/chat/direct-conversations') {
      return {'page': 2, 'page_size': 20, 'total': 22, 'has_next': false};
    }
    if (options.path == '/api/v2/chat/groups') {
      return {'page': 2, 'page_size': 20, 'total': 42, 'has_next': true};
    }
    if (options.path == '/api/v2/auth/sessions') {
      return {'page': 2, 'page_size': 20, 'total': 42, 'has_next': true};
    }
    if (options.path == '/api/v2/users') {
      return {'page': 2, 'page_size': 3, 'total': 7, 'has_next': true};
    }
    if (options.path == '/api/v2/users/recommendations') {
      return {'limit': 6};
    }
    if (options.path == '/api/v2/groups/42/members') {
      return {'page': 2, 'page_size': 3, 'total': 4, 'has_next': false};
    }
    if (options.path == '/api/v2/posts/1/comments') {
      return {'page': 2, 'page_size': 3, 'total': 4, 'has_next': false};
    }
    if (options.path == '/api/v2/notifications' &&
        options.queryParameters['unread_only'] == 'true') {
      return {
        'page': 1,
        'page_size': 1,
        'total': unreadNotificationTotal,
        'has_next': unreadNotificationTotal > 1,
      };
    }
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

const _selfUserJson = {
  ..._publicUserJson,
  'email': 'edge@example.test',
  'phone': '',
  'birth_date': null,
  'email_verified_at': '2026-05-24T00:00:00.000Z',
  'is_active': 1,
  'status': 'active',
  'created_at': '2026-05-24T00:00:00.000Z',
  'updated_at': '2026-05-24T00:00:00.000Z',
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

const _postCommentJson = {
  'comment_id': 9,
  'post_id': 1,
  'author': _publicUserJson,
  'parent_comment_id': null,
  'root_comment_id': 3,
  'content': 'text',
  'stats': {'likes_count': 2, 'replies_count': 1},
  'viewer_state': {'is_liked': true, 'can_delete': false},
  'created_at': '2026-01-02T03:04:05.000Z',
  'updated_at': '',
};

Map<String, Object> _moderationSettingJson(Map<String, dynamic> item) {
  final key = item['key'] as String;
  final value = item['value'] as String;
  return {
    'key': key,
    'value': value,
    'value_type': key == 'require_note_on_reject' ? 'boolean' : 'number',
    'label': key,
    'description': '',
    'updated_at': '2026-05-24T00:00:00.000Z',
  };
}

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

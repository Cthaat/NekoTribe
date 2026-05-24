import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/group_models.dart';

class GroupsApi {
  GroupsApi(this._client);

  final ApiClient _client;

  Future<PagedResult<V2Group>> list({
    String mode = 'discover',
    String? category,
    int page = 1,
    int size = 20,
  }) {
    final query = <String, dynamic>{
      'mode': mode,
      'page': page,
      'page_size': size,
    };
    if (category != null) query['category'] = category;
    return _client.requestData<PagedResult<V2Group>>(
      ApiPaths.groups,
      query: query,
      decode: (data) => _decodeGroupPage(data),
    );
  }

  Future<List<V2Group>> popular({int limit = 10}) {
    return _client.requestData<List<V2Group>>(
      ApiPaths.groupsPopular,
      query: {'limit': limit},
      decode: (data) {
        final map = toMap(data);
        return toList(
          map['items'],
          (e) => V2Group.fromJson(toMap(e)),
        );
      },
    );
  }

  Future<PagedResult<V2Group>> myGroups({int page = 1, int size = 20}) {
    return _client.requestData<PagedResult<V2Group>>(
      ApiPaths.usersMeGroups,
      query: {'page': page, 'page_size': size},
      decode: (data) => _decodeGroupPage(data),
    );
  }

  Future<V2Group> getGroup(String slug) {
    return _client.requestData<V2Group>(
      '${ApiPaths.groups}/by-slug/$slug',
      decode: (data) => V2Group.fromJson(toMap(data)),
    );
  }

  Future<V2Group> createGroup(Map<String, dynamic> body) {
    return _client.requestData<V2Group>(
      ApiPaths.groups,
      method: 'POST',
      data: body,
      decode: (data) => V2Group.fromJson(toMap(data)),
    );
  }

  Future<V2Group> updateGroup(int groupId, Map<String, dynamic> body) {
    return _client.requestData<V2Group>(
      '${ApiPaths.groups}/$groupId',
      method: 'PATCH',
      data: body,
      decode: (data) => V2Group.fromJson(toMap(data)),
    );
  }

  Future<V2GroupMembership> joinGroup(int groupId, {String? message}) {
    return _client.requestData<V2GroupMembership>(
      '${ApiPaths.groups}/$groupId/members/current',
      method: 'POST',
      data: {if (message != null) 'message': message},
      decode: (data) => V2GroupMembership.fromJson(toMap(data)),
    );
  }

  Future<void> leaveGroup(int groupId) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/members/current',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<PagedResult<V2GroupMember>> members(
    int groupId, {
    int page = 1,
    int size = 30,
    String? role,
  }) {
    final query = <String, dynamic>{'page': page, 'page_size': size};
    if (role != null) query['role'] = role;
    return _client.requestData<PagedResult<V2GroupMember>>(
      '${ApiPaths.groups}/$groupId/members',
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2GroupMember.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2GroupMember>(items: items, meta: meta);
      },
    );
  }

  Future<PagedResult<V2GroupPost>> posts(
    int groupId, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2GroupPost>>(
      '${ApiPaths.groups}/$groupId/posts',
      query: {'page': page, 'page_size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2GroupPost.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2GroupPost>(items: items, meta: meta);
      },
    );
  }

  Future<V2GroupPost> getPost({
    required int groupId,
    required int postId,
  }) {
    return _client.requestData<V2GroupPost>(
      '${ApiPaths.groups}/$groupId/posts/$postId',
      decode: (data) => V2GroupPost.fromJson(toMap(data)),
    );
  }

  Future<V2GroupPost> createPost({
    required int groupId,
    required String content,
    bool isAnnouncement = false,
    List<String> mediaUrls = const [],
  }) {
    return _client.requestData<V2GroupPost>(
      '${ApiPaths.groups}/$groupId/posts',
      method: 'POST',
      data: {
        'content': content,
        'is_announcement': isAnnouncement,
        if (mediaUrls.isNotEmpty) 'media_urls': mediaUrls,
      },
      decode: (data) => V2GroupPost.fromJson(toMap(data)),
    );
  }

  Future<PagedResult<V2GroupInvite>> myInvites({
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2GroupInvite>>(
      ApiPaths.usersMeGroupInvites,
      query: {'page': page, 'page_size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2GroupInvite.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2GroupInvite>(items: items, meta: meta);
      },
    );
  }

  Future<V2GroupInvite> createInvite(int groupId, Map<String, dynamic> body) {
    return _client.requestData<V2GroupInvite>(
      '${ApiPaths.groups}/$groupId/invites',
      method: 'POST',
      data: body,
      decode: (data) => V2GroupInvite.fromJson(toMap(data)),
    );
  }

  Future<V2GroupMembership> respondInvite({
    required int inviteId,
    required String action,
  }) {
    return _client.requestData<V2GroupMembership>(
      '${ApiPaths.groups}/invites/$inviteId/responses',
      method: 'POST',
      data: {'action': action},
      decode: (data) => V2GroupMembership.fromJson(toMap(data)),
    );
  }

  Future<void> deleteGroupPost({
    required int groupId,
    required int postId,
    String? reason,
  }) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/posts/$postId',
      method: 'DELETE',
      data: {'reason': reason},
      decode: (_) {},
    );
  }

  Future<void> setGroupPostPinStatus({
    required int groupId,
    required int postId,
    required bool isPinned,
  }) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/posts/$postId/pin-status',
      method: 'PUT',
      data: {'is_pinned': isPinned},
      decode: (_) {},
    );
  }

  Future<void> setGroupPostLikeStatus({
    required int groupId,
    required int postId,
    required bool liked,
  }) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/posts/$postId/likes',
      method: liked ? 'POST' : 'DELETE',
      decode: (_) {},
    );
  }

  Future<PagedResult<V2GroupComment>> comments({
    required int groupId,
    required int postId,
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2GroupComment>>(
      '${ApiPaths.groups}/$groupId/posts/$postId/comments',
      query: {'page': page, 'page_size': size},
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2GroupComment.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2GroupComment>(items: items, meta: meta);
      },
    );
  }

  Future<V2GroupComment> createComment({
    required int groupId,
    required int postId,
    required String content,
    int? parentCommentId,
    int? replyToUserId,
  }) {
    return _client.requestData<V2GroupComment>(
      '${ApiPaths.groups}/$groupId/posts/$postId/comments',
      method: 'POST',
      data: {
        'content': content,
        if (parentCommentId != null) 'parent_comment_id': parentCommentId,
        if (replyToUserId != null) 'reply_to_user_id': replyToUserId,
      },
      decode: (data) => V2GroupComment.fromJson(toMap(data)),
    );
  }

  Future<void> deleteComment({
    required int groupId,
    required int postId,
    required int commentId,
  }) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/posts/$postId/comments/$commentId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<void> setCommentLikeStatus({
    required int groupId,
    required int postId,
    required int commentId,
    required bool liked,
  }) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/posts/$postId/comments/$commentId/likes',
      method: liked ? 'POST' : 'DELETE',
      decode: (_) {},
    );
  }

  PagedResult<V2Group> _decodeGroupPage(dynamic data) {
    final map = toMap(data);
    final items = toList(
      map['items'],
      (e) => V2Group.fromJson(toMap(e)),
    );
    final meta = map['meta'] is Map<String, dynamic>
        ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
        : null;
    return PagedResult<V2Group>(items: items, meta: meta);
  }
}

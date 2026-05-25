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
    return _client.requestPaged<V2Group>(
      ApiPaths.groups,
      query: query,
      decodeItem: (item) => V2Group.fromJson(toMap(item)),
    );
  }

  Future<List<V2Group>> popular({int limit = 10}) {
    return _client.requestList<V2Group>(
      ApiPaths.groupsPopular,
      query: {'limit': limit},
      decodeItem: (item) => V2Group.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Group>> myGroups({int page = 1, int size = 20}) {
    return _client.requestPaged<V2Group>(
      ApiPaths.usersMeGroups,
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2Group.fromJson(toMap(item)),
    );
  }

  Future<V2Group> getGroup(String slug) {
    return _client.requestData<V2Group>(
      '${ApiPaths.groups}/by-slug/$slug',
      decode: (data) => V2Group.fromJson(toMap(data)),
    );
  }

  Future<V2Group> createGroup({
    required String name,
    required String description,
    String? avatarUrl,
    String? coverUrl,
    String privacy = 'public',
    String? category,
    List<String> tags = const [],
    bool joinApproval = false,
    String postPermission = 'all',
  }) {
    return _client.requestData<V2Group>(
      ApiPaths.groups,
      method: 'POST',
      data: {
        'name': name,
        'description': description,
        'avatar_url': _nullableUrl(avatarUrl),
        'cover_url': _nullableUrl(coverUrl),
        'privacy': privacy,
        'category': category,
        'tags': tags,
        'join_approval': joinApproval,
        'post_permission': postPermission,
      },
      decode: (data) => V2Group.fromJson(toMap(data)),
    );
  }

  Future<V2Group> updateGroup({
    required int groupId,
    String? name,
    String? description,
    String? avatarUrl,
    String? coverUrl,
    String? privacy,
    String? category,
    List<String>? tags,
    bool? joinApproval,
    String? postPermission,
  }) {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    if (avatarUrl != null) body['avatar_url'] = _nullableUrl(avatarUrl);
    if (coverUrl != null) body['cover_url'] = _nullableUrl(coverUrl);
    if (privacy != null) body['privacy'] = privacy;
    if (category != null) body['category'] = category;
    if (tags != null) body['tags'] = tags;
    if (joinApproval != null) body['join_approval'] = joinApproval;
    if (postPermission != null) body['post_permission'] = postPermission;
    return _client.requestData<V2Group>(
      '${ApiPaths.groups}/$groupId',
      method: 'PATCH',
      data: body,
      decode: (data) => V2Group.fromJson(toMap(data)),
    );
  }

  Future<void> deleteGroup(int groupId) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<V2GroupNotificationPreference> getNotificationPreference(int groupId) {
    return _client.requestData<V2GroupNotificationPreference>(
      '${ApiPaths.groups}/$groupId/notification-preference',
      decode: (data) => V2GroupNotificationPreference.fromJson(toMap(data)),
    );
  }

  Future<V2GroupNotificationPreference> setNotificationPreference({
    required int groupId,
    required bool isEnabled,
  }) {
    return _client.requestData<V2GroupNotificationPreference>(
      '${ApiPaths.groups}/$groupId/notification-preference',
      method: 'PUT',
      data: {'is_enabled': isEnabled},
      decode: (data) => V2GroupNotificationPreference.fromJson(toMap(data)),
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
    return _client.requestPaged<V2GroupMember>(
      '${ApiPaths.groups}/$groupId/members',
      query: query,
      decodeItem: (item) => V2GroupMember.fromJson(toMap(item)),
    );
  }

  Future<V2GroupMemberStatus> approveMember({
    required int groupId,
    required int memberId,
    required bool approved,
  }) {
    return _client.requestData<V2GroupMemberStatus>(
      '${ApiPaths.groups}/$groupId/members/$memberId/approval-status',
      method: 'PUT',
      data: {'approved': approved},
      decode: (data) => V2GroupMemberStatus.fromJson(toMap(data)),
    );
  }

  Future<void> removeMember({required int groupId, required int userId}) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/members/$userId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<V2GroupMemberStatus> changeMemberRole({
    required int groupId,
    required int userId,
    required String role,
  }) {
    return _client.requestData<V2GroupMemberStatus>(
      '${ApiPaths.groups}/$groupId/members/$userId/role',
      method: 'PATCH',
      data: {'role': role},
      decode: (data) => V2GroupMemberStatus.fromJson(toMap(data)),
    );
  }

  Future<V2GroupMemberStatus> muteMember({
    required int groupId,
    required int userId,
    required int durationHours,
    String? reason,
  }) {
    return _client.requestData<V2GroupMemberStatus>(
      '${ApiPaths.groups}/$groupId/members/$userId/mute-status',
      method: 'PUT',
      data: {
        'duration_hours': durationHours,
        if (reason != null) 'reason': reason,
      },
      decode: (data) => V2GroupMemberStatus.fromJson(toMap(data)),
    );
  }

  Future<V2GroupMemberStatus> unmuteMember({
    required int groupId,
    required int userId,
  }) {
    return _client.requestData<V2GroupMemberStatus>(
      '${ApiPaths.groups}/$groupId/members/$userId/mute-status',
      method: 'DELETE',
      decode: (data) => V2GroupMemberStatus.fromJson(toMap(data)),
    );
  }

  Future<void> transferOwnership({
    required int groupId,
    required int newOwnerId,
  }) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$groupId/ownership',
      method: 'PUT',
      data: {'new_owner_id': newOwnerId},
      decode: (_) {},
    );
  }

  Future<PagedResult<V2GroupPost>> posts(
    int groupId, {
    int page = 1,
    int size = 20,
    String type = 'all',
  }) {
    final query = <String, dynamic>{'page': page, 'page_size': size};
    if (type != 'all') query['type'] = type;
    return _client.requestPaged<V2GroupPost>(
      '${ApiPaths.groups}/$groupId/posts',
      query: query,
      decodeItem: (item) => V2GroupPost.fromJson(toMap(item)),
    );
  }

  Future<V2GroupPost> getPost({required int groupId, required int postId}) {
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

  Future<PagedResult<V2GroupInvite>> myInvites({int page = 1, int size = 20}) {
    return _client.requestPaged<V2GroupInvite>(
      ApiPaths.usersMeGroupInvites,
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2GroupInvite.fromJson(toMap(item)),
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

  Future<PagedResult<V2GroupInvite>> groupInvites(
    int groupId, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestPaged<V2GroupInvite>(
      '${ApiPaths.groups}/$groupId/invites',
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2GroupInvite.fromJson(toMap(item)),
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
    return _client.requestPaged<V2GroupComment>(
      '${ApiPaths.groups}/$groupId/posts/$postId/comments',
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2GroupComment.fromJson(toMap(item)),
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
}

String? _nullableUrl(String? value) {
  final next = value?.trim();
  if (next == null || next.isEmpty) return null;
  return next;
}

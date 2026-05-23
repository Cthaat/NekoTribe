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
      'size': size,
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
      query: {'page': page, 'size': size},
      decode: (data) => _decodeGroupPage(data),
    );
  }

  Future<V2Group> getGroup(String slug) {
    return _client.requestData<V2Group>(
      '${ApiPaths.groups}/$slug',
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

  Future<V2Group> updateGroup(String slug, Map<String, dynamic> body) {
    return _client.requestData<V2Group>(
      '${ApiPaths.groups}/$slug',
      method: 'PATCH',
      data: body,
      decode: (data) => V2Group.fromJson(toMap(data)),
    );
  }

  Future<V2GroupMembership> joinGroup(String slug, {String? message}) {
    return _client.requestData<V2GroupMembership>(
      '${ApiPaths.groups}/$slug/members',
      method: 'POST',
      data: {if (message != null) 'message': message},
      decode: (data) => V2GroupMembership.fromJson(toMap(data)),
    );
  }

  Future<void> leaveGroup(String slug) async {
    await _client.request<void>(
      '${ApiPaths.groups}/$slug/members/me',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<PagedResult<V2GroupMember>> members(
    String slug, {
    int page = 1,
    int size = 30,
    String? role,
  }) {
    final query = <String, dynamic>{'page': page, 'size': size};
    if (role != null) query['role'] = role;
    return _client.requestData<PagedResult<V2GroupMember>>(
      '${ApiPaths.groups}/$slug/members',
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
    String slug, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestData<PagedResult<V2GroupPost>>(
      '${ApiPaths.groups}/$slug/posts',
      query: {'page': page, 'size': size},
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

  Future<V2GroupPost> createPost({
    required String slug,
    required String content,
    bool isAnnouncement = false,
    List<String> mediaUrls = const [],
  }) {
    return _client.requestData<V2GroupPost>(
      '${ApiPaths.groups}/$slug/posts',
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
      query: {'page': page, 'size': size},
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

  Future<V2GroupInvite> createInvite(String slug, Map<String, dynamic> body) {
    return _client.requestData<V2GroupInvite>(
      '${ApiPaths.groups}/$slug/invites',
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
      '${ApiPaths.usersMeGroupInvites}/$inviteId',
      method: 'PATCH',
      data: {'action': action},
      decode: (data) => V2GroupMembership.fromJson(toMap(data)),
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

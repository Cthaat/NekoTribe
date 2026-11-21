typedef GroupPostLink = ({int groupId, int postId, int? commentId});

int? _safeId(List<String>? values) {
  if (values?.length != 1) return null;
  final raw = values!.single;
  if (raw.trim() != raw || !RegExp(r'^[1-9][0-9]{0,15}$').hasMatch(raw)) {
    return null;
  }
  final id = int.tryParse(raw);
  return id != null && id <= 9007199254740991 ? id : null;
}

GroupPostLink? readGroupPostLink(Uri uri) {
  final query = uri.queryParametersAll;
  final groupId = _safeId(query['group']);
  final postId = _safeId(query['post']);
  if (groupId == null || postId == null) return null;
  return (
    groupId: groupId,
    postId: postId,
    commentId: _safeId(query['comment']),
  );
}

Map<String, String> groupPostLinkQuery(GroupPostLink link) => {
  'group': '${link.groupId}',
  'post': '${link.postId}',
  if (link.commentId != null) 'comment': '${link.commentId}',
};

String groupPostLocation(GroupPostLink link) => Uri(
  path: '/groups/posts',
  queryParameters: groupPostLinkQuery(link),
).toString();

GroupPostLink? groupPostFromNotification({
  required bool isComment,
  required String? resourceType,
  required int? resourceId,
  required Map<String, Object?> metadata,
}) {
  int? id(Object? value) {
    if (value is String) return _safeId([value]);
    if (value is num &&
        value.isFinite &&
        value >= 1 &&
        value <= 9007199254740991 &&
        value == value.truncate()) {
      return value.toInt();
    }
    return null;
  }

  final groupId = id(metadata['group_id']);
  final postId =
      id(metadata['post_id']) ??
      (!isComment && resourceType == 'group_post' ? id(resourceId) : null);
  if (groupId == null || postId == null) return null;
  final cited = isComment ? id(metadata['comment_id']) : null;
  final resource = isComment && resourceType == 'group_comment'
      ? id(resourceId)
      : null;
  if (cited != null && resource != null && cited != resource) return null;
  return (groupId: groupId, postId: postId, commentId: cited ?? resource);
}

bool _isWebOrigin(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty &&
    !uri.authority.contains('@') &&
    (!uri.hasPort || (uri.port > 0 && uri.port <= 65535));

Uri? groupPostShareUrl(
  GroupPostLink link, {
  required String configuredBase,
  Uri? browserEntry,
}) {
  final base = configuredBase.trim();
  if (base.isNotEmpty) {
    final uri = Uri.tryParse(base);
    if (uri == null ||
        !_isWebOrigin(uri) ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(base)) {
      return null;
    }
    final path = uri.pathSegments.toList();
    while (path.isNotEmpty && path.last.isEmpty) {
      path.removeLast();
    }
    return uri.replace(
      pathSegments: [...path, 'groups', 'posts'],
      queryParameters: groupPostLinkQuery(link),
    );
  }
  if (browserEntry == null || !_isWebOrigin(browserEntry)) return null;
  return Uri(
    scheme: browserEntry.scheme,
    host: browserEntry.host,
    port: browserEntry.hasPort ? browserEntry.port : null,
    pathSegments: browserEntry.pathSegments,
    fragment: groupPostLocation(link),
  );
}

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/post_models.dart';

class PostsApi {
  PostsApi(this._client);

  final ApiClient _client;

  Future<PagedResult<V2Post>> getFeed({
    String mode = 'home',
    int page = 1,
    int size = 20,
    String? cursor,
    String? language,
    String? sort,
  }) {
    final query = <String, dynamic>{
      'timeline': mode,
      'page': page,
      'page_size': size,
    };
    if (cursor != null) query['cursor'] = cursor;
    if (language != null) query['language'] = language;
    if (sort != null) query['sort'] = sort;
    return _client.requestPaged<V2Post>(
      ApiPaths.posts,
      query: query,
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getUserPosts(
    String username, {
    int page = 1,
    int size = 20,
    String mode = 'posts',
  }) {
    return _client.requestPaged<V2Post>(
      '${ApiPaths.users}/$username/posts',
      query: {'page': page, 'page_size': size, 'sort': mode},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getUserPostsById(
    int userId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) {
    return _client.requestPaged<V2Post>(
      '${ApiPaths.users}/$userId/posts',
      query: {'page': page, 'page_size': size, 'sort': sort},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getMyPosts({
    int page = 1,
    int size = 20,
    String mode = 'posts',
  }) {
    return _client.requestPaged<V2Post>(
      ApiPaths.usersMePosts,
      query: {'page': page, 'page_size': size, 'sort': mode},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getMyLikes({int page = 1, int size = 20}) {
    return _client.requestPaged<V2Post>(
      ApiPaths.usersMeLikes,
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getMyBookmarks({int page = 1, int size = 20}) {
    return _client.requestPaged<V2Post>(
      ApiPaths.usersMeBookmarks,
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<V2Post> getPost(int postId) {
    return _client.requestData<V2Post>(
      '${ApiPaths.posts}/$postId',
      decode: (data) => V2Post.fromJson(toMap(data)),
    );
  }

  Future<V2Post> createPost({
    required String content,
    String postType = 'normal',
    String visibility = 'public',
    String? language,
    String? location,
    int? replyToPostId,
    int? quotedPostId,
    int? repostOfPostId,
    List<int> mediaIds = const [],
    List<String> tags = const [],
  }) {
    final body = <String, dynamic>{
      'content': content,
      'post_type': postType,
      'visibility': visibility,
      if (language != null) 'language': language,
      if (location != null) 'location': location,
      if (replyToPostId != null) 'reply_to_post_id': replyToPostId,
      if (quotedPostId != null) 'quoted_post_id': quotedPostId,
      if (repostOfPostId != null) 'repost_of_post_id': repostOfPostId,
      if (mediaIds.isNotEmpty) 'media_ids': mediaIds,
      if (tags.isNotEmpty) 'tags': tags,
    };
    return _client.requestData<V2Post>(
      ApiPaths.posts,
      method: 'POST',
      data: body,
      decode: (data) => V2Post.fromJson(toMap(data)),
    );
  }

  Future<V2Post> updatePost({
    required int postId,
    String? content,
    String? visibility,
    String? language,
    String? location,
    List<String>? tags,
  }) {
    return _client.requestData<V2Post>(
      '${ApiPaths.posts}/$postId',
      method: 'PUT',
      data: {
        if (content != null) 'content': content,
        if (visibility != null) 'visibility': visibility,
        if (language != null) 'language': language,
        if (location != null) 'location': location,
        if (tags != null) 'tag_names': tags,
      },
      decode: (data) => V2Post.fromJson(toMap(data)),
    );
  }

  Future<void> deletePost(int postId) async {
    await _client.request<void>(
      '${ApiPaths.posts}/$postId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<V2ViewerPostState> likePost(int postId) {
    return _client.requestData<V2ViewerPostState>(
      '${ApiPaths.posts}/$postId/likes',
      method: 'POST',
      decode: (data) => V2ViewerPostState.fromJson(toMap(data)),
    );
  }

  Future<V2ViewerPostState> unlikePost(int postId) {
    return _client.requestData<V2ViewerPostState>(
      '${ApiPaths.posts}/$postId/likes',
      method: 'DELETE',
      decode: (data) => V2ViewerPostState.fromJson(toMap(data)),
    );
  }

  Future<V2ViewerPostState> bookmarkPost(int postId) {
    return _client.requestData<V2ViewerPostState>(
      '${ApiPaths.posts}/$postId/bookmarks',
      method: 'POST',
      decode: (data) => V2ViewerPostState.fromJson(toMap(data)),
    );
  }

  Future<V2ViewerPostState> unbookmarkPost(int postId) {
    return _client.requestData<V2ViewerPostState>(
      '${ApiPaths.posts}/$postId/bookmarks',
      method: 'DELETE',
      decode: (data) => V2ViewerPostState.fromJson(toMap(data)),
    );
  }

  Future<V2Post> createRetweet({
    required int postId,
    required String content,
    String visibility = 'public',
  }) {
    return _client.requestData<V2Post>(
      '${ApiPaths.posts}/$postId/retweets',
      method: 'POST',
      data: {'content': content, 'visibility': visibility},
      decode: (data) => V2Post.fromJson(toMap(data)),
    );
  }

  Future<PagedResult<V2Post>> getReplies(
    int postId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) {
    return _client.requestPaged<V2Post>(
      '${ApiPaths.posts}/$postId/replies',
      query: {'page': page, 'page_size': size, 'sort': sort},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Comment>> getComments(
    int postId, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestPaged<V2Comment>(
      '${ApiPaths.posts}/$postId/comments',
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2Comment.fromJson(toMap(item)),
    );
  }

  Future<V2Comment> createComment({
    required int postId,
    required String content,
    int? parentCommentId,
  }) {
    final body = <String, dynamic>{
      'content': content,
      if (parentCommentId != null) 'parent_comment_id': parentCommentId,
    };
    return _client.requestData<V2Comment>(
      '${ApiPaths.posts}/$postId/comments',
      method: 'POST',
      data: body,
      decode: (data) => V2Comment.fromJson(toMap(data)),
    );
  }

  Future<void> deleteComment(int commentId) async {
    await _client.request<void>(
      '${ApiPaths.comments}/$commentId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<void> likeComment(int commentId) async {
    await _client.request<void>(
      '${ApiPaths.comments}/$commentId/likes',
      method: 'POST',
      decode: (_) {},
    );
  }

  Future<void> unlikeComment(int commentId) async {
    await _client.request<void>(
      '${ApiPaths.comments}/$commentId/likes',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<PagedResult<V2Post>> searchPosts({
    required String query,
    int page = 1,
    int size = 20,
  }) {
    return _client.requestPaged<V2Post>(
      ApiPaths.posts,
      query: {'q': query, 'page': page, 'page_size': size},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<List<V2Post>> getTrending({int limit = 10}) {
    return _client.requestList<V2Post>(
      ApiPaths.postsTrending,
      query: {'limit': limit},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<List<V2TagItem>> getTrendingTags({int limit = 10}) {
    return _client.requestList<V2TagItem>(
      ApiPaths.tagsTrending,
      query: {'limit': limit},
      decodeItem: (item) => V2TagItem.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getPostsByTag(
    String tag, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestPaged<V2Post>(
      '${ApiPaths.tags}/$tag/posts',
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<void> reportContent({
    required String targetType,
    required int targetId,
    required String reason,
    String? description,
    String? evidenceUrl,
  }) async {
    await _client.request<void>(
      ApiPaths.reports,
      method: 'POST',
      data: {
        'target_type': targetType,
        'target_id': targetId,
        'reason': reason,
        if (description != null) 'description': description,
        if (evidenceUrl != null) 'evidence_url': evidenceUrl,
      },
      decode: (_) {},
    );
  }

  Future<void> recordRecommendationFeedback({
    required int postId,
    required String feedback,
  }) async {
    await _client.request<void>(
      ApiPaths.recommendationsFeedback,
      method: 'POST',
      data: {'post_id': postId, 'feedback': feedback},
      decode: (_) {},
    );
  }
}

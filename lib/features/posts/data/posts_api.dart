import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';
import '../domain/post_models.dart';
import '../domain/post_markdown.dart';
import '../domain/post_poll.dart';

class UnconfirmedPostError implements Exception {
  const UnconfirmedPostError();
}

class UnconfirmedPostUpdateError implements Exception {
  const UnconfirmedPostUpdateError();
}

class UnconfirmedRetweetError implements Exception {
  const UnconfirmedRetweetError();
}

typedef PostLikeReceipt = ({bool isLiked, int likesCount});

class PostsApi {
  PostsApi(this._client);

  final ApiClient _client;

  Future<PagedResult<V2PublicUser>> postLikers(
    int postId, {
    required int page,
    required CancelToken cancelToken,
  }) {
    return _client.requestPaged<V2PublicUser>(
      '${ApiPaths.posts}/$postId/likes',
      query: {'page': page, 'page_size': 20},
      cancelToken: cancelToken,
      decodeItem: (item) => V2PublicUser.fromJson(toMap(item)),
    );
  }

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
    String sort = 'newest',
    String? query,
  }) {
    return _client.requestPaged<V2Post>(
      ApiPaths.usersMePosts,
      query: {
        'page': page,
        'page_size': size,
        'sort': sort,
        if (query != null && query.isNotEmpty) 'q': query,
      },
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getMyLikes({
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) {
    return _client.requestPaged<V2Post>(
      ApiPaths.usersMeLikes,
      query: {'page': page, 'page_size': size, 'sort': sort},
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
      decode: (data) {
        final post = toMap(data);
        final id = post['post_id'];
        if (id is! int || id != postId) {
          throw const FormatException('Invalid post detail response');
        }
        return V2Post.fromJson(post);
      },
    );
  }

  Future<V2PostAnalytics> getPostAnalytics(int postId) {
    return _client.requestData<V2PostAnalytics>(
      '${ApiPaths.posts}/$postId/analytics',
      decode: (data) => V2PostAnalytics.fromJson(toMap(data)),
    );
  }

  Future<V2PostPoll> getPoll(int postId, {CancelToken? cancelToken}) {
    return _client.requestData<V2PostPoll>(
      '${ApiPaths.posts}/$postId/poll',
      cancelToken: cancelToken,
      decode: (data) => V2PostPoll.fromJson(toMap(data)),
    );
  }

  Future<V2PostPoll> votePoll(
    int postId,
    List<int> optionIds, {
    CancelToken? cancelToken,
  }) {
    return _client.requestData<V2PostPoll>(
      '${ApiPaths.posts}/$postId/poll/vote',
      method: 'POST',
      data: {'option_ids': optionIds},
      cancelToken: cancelToken,
      decode: (data) => V2PostPoll.fromJson(toMap(data)),
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
    List<int> mentionUserIds = const [],
    V2CreatePostPoll? poll,
    String? markdown,
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
      if (tags.isNotEmpty) 'tag_names': tags,
      if (mentionUserIds.isNotEmpty) 'mention_user_ids': mentionUserIds,
      if (poll != null) 'poll': poll.toJson(),
      if (markdown != null) 'markdown': markdown,
    };
    return _client.requestData<V2Post>(
      ApiPaths.posts,
      method: 'POST',
      data: body,
      decode: (data) {
        final receipt = toMap(data);
        final created = receipt['post_id'];
        if (!_isPostId(created) ||
            created == replyToPostId ||
            created == repostOfPostId ||
            created == quotedPostId ||
            receipt['reply_to_post_id'] != replyToPostId ||
            receipt['repost_of_post_id'] != repostOfPostId ||
            receipt['quoted_post_id'] != quotedPostId) {
          throw const UnconfirmedPostError();
        }
        final post = V2Post.fromJson(receipt);
        if ((poll != null && post.poll == null) ||
            (markdown != null && post.markdown != markdown)) {
          throw const UnconfirmedPostError();
        }
        return post;
      },
    );
  }

  Future<V2Post> updatePost({
    required int postId,
    String? content,
    String? visibility,
    String? language,
    String? location,
    List<String>? tags,
    List<int>? mediaIds,
    PostMarkdownUpdate? markdown,
  }) {
    return _client.requestData<V2Post>(
      '${ApiPaths.posts}/$postId',
      method: 'PATCH',
      data: {
        if (content != null) 'content': content,
        if (visibility != null) 'visibility': visibility,
        if (language != null) 'language': language,
        if (location != null) 'location': location,
        if (tags != null) 'tag_names': tags,
        if (mediaIds != null) 'media_ids': mediaIds,
        if (markdown != null) 'markdown': markdown.body,
      },
      validateSuccessEnvelope: (value) {
        final envelope = toMap(value);
        final post = toMap(envelope['data']);
        if (envelope['code'] != 200 ||
            envelope['message'] != 'post updated' ||
            !envelope.containsKey('meta') ||
            envelope['meta'] != null ||
            post['post_id'] != postId ||
            !_isPostId(toMap(post['author'])['user_id']) ||
            toMap(post['viewer_state'])['can_delete'] != true ||
            (markdown != null && post['markdown'] != markdown.body)) {
          throw const UnconfirmedPostUpdateError();
        }
      },
      decode: (data) => V2Post.fromJson(toMap(data)),
    );
  }

  Future<void> deletePost(int postId) async {
    await _client.request<void>(
      '${ApiPaths.posts}/$postId',
      method: 'DELETE',
      decode: (_) {},
      validateSuccessEnvelope: (value) {
        if (value is! Map<String, Object?> ||
            value['code'] != 200 ||
            value['message'] != 'post deleted' ||
            !value.containsKey('data') ||
            value['data'] != null ||
            !value.containsKey('meta') ||
            value['meta'] != null) {
          throw const FormatException('Invalid post delete response');
        }
      },
    );
  }

  Future<PostLikeReceipt> likePost(int postId) => _setPostLike(postId, 'POST');

  Future<PostLikeReceipt> unlikePost(int postId) =>
      _setPostLike(postId, 'DELETE');

  Future<PostLikeReceipt> _setPostLike(int postId, String method) {
    return _client.requestData<PostLikeReceipt>(
      '${ApiPaths.posts}/$postId/likes',
      method: method,
      decode: (data) {
        final body = toMap(data);
        final count = body['likes_count'];
        final liked = body['is_liked'];
        if (body['post_id'] != postId ||
            liked is! bool ||
            count is! num ||
            !count.isFinite ||
            count < 0 ||
            count > 9007199254740991 ||
            count != count.truncate()) {
          throw const FormatException('Invalid post like response');
        }
        return (isLiked: liked, likesCount: count.toInt());
      },
    );
  }

  Future<V2ViewerPostState> bookmarkPost(int postId) =>
      _setPostBookmark(postId, 'POST');

  Future<V2ViewerPostState> unbookmarkPost(int postId) =>
      _setPostBookmark(postId, 'DELETE');

  Future<V2ViewerPostState> _setPostBookmark(int postId, String method) {
    return _client.requestData<V2ViewerPostState>(
      '${ApiPaths.posts}/$postId/bookmarks',
      method: method,
      decode: (data) {
        final body = toMap(data);
        if (body['post_id'] != postId || body['is_bookmarked'] is! bool) {
          throw const FormatException('Invalid post bookmark response');
        }
        return V2ViewerPostState.fromJson(body);
      },
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
      decode: (data) {
        final body = toMap(data);
        final created = body['post_id'];
        if (body['repost_of_post_id'] != postId ||
            !_isPostId(created) ||
            created == postId) {
          throw const UnconfirmedRetweetError();
        }
        return V2Post.fromJson(body);
      },
    );
  }

  static bool _isPostId(Object? value) =>
      value is num &&
      value >= 1 &&
      value <= 9007199254740991 &&
      value == value.truncate();

  Future<PagedResult<V2Post>> getReplies(
    int postId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) {
    return _getPostReferences(
      postId,
      'replies',
      page: page,
      size: size,
      sort: sort,
    );
  }

  Future<PagedResult<V2Post>> getRetweets(
    int postId, {
    int page = 1,
    int size = 20,
    String sort = 'oldest',
  }) {
    return _getPostReferences(
      postId,
      'retweets',
      page: page,
      size: size,
      sort: sort,
    );
  }

  Future<PagedResult<V2Post>> _getPostReferences(
    int postId,
    String kind, {
    required int page,
    required int size,
    required String sort,
  }) {
    return _client.requestPaged<V2Post>(
      '${ApiPaths.posts}/$postId/$kind',
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

  Future<V2Comment?> getComment(int postId, int commentId) async {
    final page = await _client.requestPaged<V2Comment>(
      '${ApiPaths.posts}/$postId/comments',
      query: {'comment_id': commentId},
      decodeItem: (item) => V2Comment.fromJson(toMap(item)),
    );
    for (final item in page.items) {
      if (item.postId == postId && item.commentId == commentId) return item;
    }
    return null;
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

  Future<CommentLikeState> likeComment(int commentId) =>
      _setCommentLike(commentId, liked: true);

  Future<CommentLikeState> unlikeComment(int commentId) =>
      _setCommentLike(commentId, liked: false);

  Future<CommentLikeState> _setCommentLike(
    int commentId, {
    required bool liked,
  }) {
    return _client.requestData<CommentLikeState>(
      '${ApiPaths.comments}/$commentId/likes',
      method: liked ? 'POST' : 'DELETE',
      decode: (data) {
        final body = toMap(data);
        final count = body['likes_count'];
        final state = body['is_liked'];
        if (body['comment_id'] != commentId ||
            state is! bool ||
            count is! num ||
            !count.isFinite ||
            count < 0 ||
            count != count.truncate()) {
          throw const FormatException('Invalid comment like response');
        }
        return (isLiked: state, likesCount: count.toInt());
      },
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

  Future<PagedResult<V2Post>> getTrendingPage({
    required int page,
    int size = 20,
  }) => _client.requestPaged<V2Post>(
    ApiPaths.postsTrending,
    query: {'page': page, 'page_size': size},
    decodeItem: (item) => V2Post.fromJson(toMap(item)),
  );

  Future<List<V2TagItem>> getTrendingTags({int limit = 10}) {
    return _client.requestList<V2TagItem>(
      ApiPaths.tagsTrending,
      query: {'page_size': limit},
      decodeItem: (item) => V2TagItem.fromJson(toMap(item)),
    );
  }

  Future<List<V2TagItem>> searchTags(String query) {
    return _client.requestList<V2TagItem>(
      ApiPaths.tags,
      query: {'q': query, 'page_size': 6},
      decodeItem: (item) => V2TagItem.fromJson(toMap(item)),
    );
  }

  Future<PagedResult<V2Post>> getPostsByTag(
    String tag, {
    int page = 1,
    int size = 20,
  }) {
    return _client.requestPaged<V2Post>(
      '${ApiPaths.tags}/${Uri.encodeComponent(tag)}/posts',
      query: {'page': page, 'page_size': size},
      decodeItem: (item) => V2Post.fromJson(toMap(item)),
    );
  }

  Future<V2TagAnalytics> getTagAnalytics(String tag) {
    return _client.requestData<V2TagAnalytics>(
      '${ApiPaths.tags}/${Uri.encodeComponent(tag)}/analytics',
      decode: (value) => V2TagAnalytics.fromJson(toMap(value)),
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
      data: {
        'resource_type': 'post',
        'resource_id': postId,
        'action': feedback,
      },
      decode: (value) {
        if (toMap(value)['accepted'] != true) {
          throw const FormatException(
            'Recommendation feedback was not accepted.',
          );
        }
      },
    );
  }
}

import '../../../core/constants/api_paths.dart';
import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';
import 'post_markdown.dart';
import 'post_poll.dart';

class V2MediaAsset {
  V2MediaAsset({
    required this.mediaId,
    required this.mediaType,
    required this.fileName,
    required this.publicUrl,
    required this.fileSize,
    required this.mimeType,
    this.width,
    this.height,
    this.duration,
    this.thumbnailUrl,
    this.altText,
    this.description,
    required this.status,
    required this.createdAt,
  });

  final int mediaId;
  final String mediaType;
  final String fileName;
  final String publicUrl;
  final int fileSize;
  final String mimeType;
  final int? width;
  final int? height;
  final double? duration;
  final String? thumbnailUrl;
  final String? altText;
  final String? description;
  final String status;
  final String createdAt;

  bool get isVideo => mediaType == 'video' || mimeType.startsWith('video/');

  String? get privateContentPath {
    if (mediaId <= 0 || mediaId > 9007199254740991) return null;
    final path = '${ApiPaths.media}/$mediaId/content';
    return publicUrl == path ? path : null;
  }

  /// Keeps malformed forms of the authenticated route out of public image UI.
  bool get usesContentRoute {
    final uri = Uri.tryParse(publicUrl.trim());
    if (uri == null) return false;
    final path = uri.normalizePath().pathSegments.join('/');
    return path.startsWith('${ApiPaths.media.substring(1)}/');
  }

  factory V2MediaAsset.fromJson(Map<String, dynamic> json) {
    return V2MediaAsset(
      mediaId: switch (json['media_id']) {
        int id => id,
        String id when RegExp(r'^[1-9][0-9]*$').hasMatch(id) =>
          int.tryParse(id) ?? 0,
        _ => 0,
      },
      mediaType: toStr(json['media_type']),
      fileName: toStr(json['file_name']),
      publicUrl: toStr(json['public_url']),
      fileSize: toInt(json['file_size']) ?? 0,
      mimeType: toStr(json['mime_type']),
      width: toInt(json['width']),
      height: toInt(json['height']),
      duration: toDouble(json['duration']),
      thumbnailUrl: toStrOrNull(json['thumbnail_url']),
      altText: toStrOrNull(json['alt_text']),
      description: toStrOrNull(json['description']),
      status: toStr(json['status'], defaultValue: 'active'),
      createdAt: toStr(json['created_at']),
    );
  }
}

class V2PostStats {
  V2PostStats({
    required this.likesCount,
    required this.commentsCount,
    required this.repliesCount,
    required this.retweetsCount,
    required this.viewsCount,
    required this.engagementScore,
  });

  final int likesCount;
  final int commentsCount;
  final int repliesCount;
  final int retweetsCount;
  final int viewsCount;
  final double engagementScore;

  factory V2PostStats.fromJson(Map<String, dynamic> json) {
    return V2PostStats(
      likesCount: toInt(json['likes_count']) ?? 0,
      commentsCount: toInt(json['comments_count']) ?? 0,
      repliesCount: toInt(json['replies_count']) ?? 0,
      retweetsCount: toInt(json['retweets_count']) ?? 0,
      viewsCount: toInt(json['views_count']) ?? 0,
      engagementScore: toDouble(json['engagement_score']) ?? 0,
    );
  }

  V2PostStats copyWith({
    int? likesCount,
    int? commentsCount,
    int? repliesCount,
    int? retweetsCount,
    int? viewsCount,
    double? engagementScore,
  }) {
    return V2PostStats(
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      repliesCount: repliesCount ?? this.repliesCount,
      retweetsCount: retweetsCount ?? this.retweetsCount,
      viewsCount: viewsCount ?? this.viewsCount,
      engagementScore: engagementScore ?? this.engagementScore,
    );
  }
}

class V2PostAnalytics {
  V2PostAnalytics({
    required this.postId,
    required this.viewsCount,
    required this.likesCount,
    required this.commentsCount,
    required this.repliesCount,
    required this.retweetsCount,
    required this.engagementScore,
    required this.likeRate,
  });

  final int postId;
  final int viewsCount;
  final int likesCount;
  final int commentsCount;
  final int repliesCount;
  final int retweetsCount;
  final double engagementScore;
  final double likeRate;

  factory V2PostAnalytics.fromJson(Map<String, dynamic> json) {
    num number(String field) {
      final value = json[field];
      if (value is! num || !value.isFinite) {
        throw const FormatException('Invalid post analytics');
      }
      return value;
    }

    int integer(String field, {int minimum = 0}) {
      final value = number(field);
      if (value < minimum ||
          value > 9007199254740991 ||
          value != value.truncateToDouble()) {
        throw const FormatException('Invalid post analytics');
      }
      return value.toInt();
    }

    return V2PostAnalytics(
      postId: integer('post_id', minimum: 1),
      viewsCount: integer('views_count'),
      likesCount: integer('likes_count'),
      commentsCount: integer('comments_count'),
      repliesCount: integer('replies_count'),
      retweetsCount: integer('retweets_count'),
      engagementScore: number('engagement_score').toDouble(),
      likeRate: number('like_rate').toDouble(),
    );
  }
}

class V2ViewerPostState {
  V2ViewerPostState({
    required this.isLiked,
    required this.isBookmarked,
    required this.canDelete,
  });

  final bool isLiked;
  final bool isBookmarked;
  final bool canDelete;

  factory V2ViewerPostState.fromJson(Map<String, dynamic> json) {
    return V2ViewerPostState(
      isLiked: toBool(json['is_liked']),
      isBookmarked: toBool(json['is_bookmarked']),
      canDelete: toBool(json['can_delete']),
    );
  }

  V2ViewerPostState copyWith({
    bool? isLiked,
    bool? isBookmarked,
    bool? canDelete,
  }) {
    return V2ViewerPostState(
      isLiked: isLiked ?? this.isLiked,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      canDelete: canDelete ?? this.canDelete,
    );
  }
}

class V2Post {
  V2Post({
    required this.postId,
    required this.author,
    required this.content,
    required this.postType,
    required this.visibility,
    required this.language,
    required this.location,
    this.replyToPostId,
    this.repostOfPostId,
    this.quotedPostId,
    this.poll,
    this.markdown,
    required this.media,
    required this.tags,
    required this.mentions,
    required this.stats,
    required this.viewerState,
    required this.createdAt,
    required this.updatedAt,
  });

  final int postId;
  final V2PublicUser author;
  final String content;
  final String postType;
  final String visibility;
  final String language;
  final String location;
  final int? replyToPostId;
  final int? repostOfPostId;
  final int? quotedPostId;
  final V2PostPoll? poll;
  final String? markdown;
  final List<V2MediaAsset> media;
  final List<String> tags;
  final List<V2PublicUser> mentions;
  final V2PostStats stats;
  final V2ViewerPostState viewerState;
  final String createdAt;
  final String updatedAt;

  factory V2Post.fromJson(Map<String, dynamic> json) {
    return V2Post(
      postId: toInt(json['post_id']) ?? 0,
      author: V2PublicUser.fromJson(toMap(json['author'])),
      content: toStr(json['content']),
      postType: toStr(json['post_type'], defaultValue: 'normal'),
      visibility: toStr(json['visibility'], defaultValue: 'public'),
      language: toStr(json['language']),
      location: toStr(json['location']),
      replyToPostId: toInt(json['reply_to_post_id']),
      repostOfPostId: toInt(json['repost_of_post_id']),
      quotedPostId: toInt(json['quoted_post_id']),
      poll: V2PostPoll.optional(json['poll']),
      markdown: readPostMarkdown(json['markdown']),
      media: toList(json['media'], (e) => V2MediaAsset.fromJson(toMap(e))),
      tags: toList(json['tags'], (e) => toStr(e)),
      mentions: toList(
        json['mentions'],
        (e) => V2PublicUser.fromJson(toMap(e)),
      ),
      stats: V2PostStats.fromJson(toMap(json['stats'])),
      viewerState: V2ViewerPostState.fromJson(toMap(json['viewer_state'])),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }

  V2Post copyWith({V2PostStats? stats, V2ViewerPostState? viewerState}) {
    return V2Post(
      postId: postId,
      author: author,
      content: content,
      postType: postType,
      visibility: visibility,
      language: language,
      location: location,
      replyToPostId: replyToPostId,
      repostOfPostId: repostOfPostId,
      quotedPostId: quotedPostId,
      poll: poll,
      markdown: markdown,
      media: media,
      tags: tags,
      mentions: mentions,
      stats: stats ?? this.stats,
      viewerState: viewerState ?? this.viewerState,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

typedef CommentLikeState = ({bool isLiked, int likesCount});

class V2Comment {
  V2Comment({
    required this.commentId,
    required this.postId,
    required this.author,
    this.parentCommentId,
    this.rootCommentId,
    required this.content,
    required this.likesCount,
    required this.repliesCount,
    required this.isLiked,
    required this.canDelete,
    required this.createdAt,
    required this.updatedAt,
  });

  final int commentId;
  final int postId;
  final V2PublicUser author;
  final int? parentCommentId;
  final int? rootCommentId;
  final String content;
  final int likesCount;
  final int repliesCount;
  final bool isLiked;
  final bool canDelete;
  final String createdAt;
  final String updatedAt;

  V2Comment withLikeState(CommentLikeState state) => V2Comment(
    commentId: commentId,
    postId: postId,
    author: author,
    parentCommentId: parentCommentId,
    rootCommentId: rootCommentId,
    content: content,
    likesCount: state.likesCount,
    repliesCount: repliesCount,
    isLiked: state.isLiked,
    canDelete: canDelete,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory V2Comment.fromJson(Map<String, dynamic> json) {
    final stats = toMap(json['stats']);
    final viewer = toMap(json['viewer_state']);
    return V2Comment(
      commentId: toInt(json['comment_id']) ?? 0,
      postId: toInt(json['post_id']) ?? 0,
      author: V2PublicUser.fromJson(toMap(json['author'])),
      parentCommentId: toInt(json['parent_comment_id']),
      rootCommentId: toInt(json['root_comment_id']),
      content: toStr(json['content']),
      likesCount: toInt(stats['likes_count']) ?? 0,
      repliesCount: toInt(stats['replies_count']) ?? 0,
      isLiked: toBool(viewer['is_liked']),
      canDelete: toBool(viewer['can_delete']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

class V2TagAnalytics {
  V2TagAnalytics.fromJson(Map<String, dynamic> json)
    : totalPosts = toInt(json['total_posts']) ?? 0,
      totalAuthors = toInt(json['total_authors']) ?? 0,
      totalViews = toInt(json['total_views']) ?? 0,
      totalLikes = toInt(json['total_likes']) ?? 0,
      engagementScore = toDouble(json['engagement_score']) ?? 0;

  final int totalPosts;
  final int totalAuthors;
  final int totalViews;
  final int totalLikes;
  final double engagementScore;
}

class V2TagItem {
  V2TagItem({
    required this.tagId,
    required this.name,
    this.postsCount,
    this.followersCount,
  });

  final int tagId;
  final String name;
  final int? postsCount;
  final int? followersCount;

  factory V2TagItem.fromJson(Map<String, dynamic> json) {
    return V2TagItem(
      tagId: toInt(json['tag_id']) ?? 0,
      name: toStr(json['name']),
      postsCount: toInt(json['posts_count']),
      followersCount: toInt(json['followers_count']),
    );
  }
}

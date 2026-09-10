import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';

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

  factory V2MediaAsset.fromJson(Map<String, dynamic> json) {
    return V2MediaAsset(
      mediaId: toInt(json['media_id']) ?? 0,
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
    return V2PostAnalytics(
      postId: toInt(json['post_id']) ?? 0,
      viewsCount: toInt(json['views_count']) ?? 0,
      likesCount: toInt(json['likes_count']) ?? 0,
      commentsCount: toInt(json['comments_count']) ?? 0,
      repliesCount: toInt(json['replies_count']) ?? 0,
      retweetsCount: toInt(json['retweets_count']) ?? 0,
      engagementScore: toDouble(json['engagement_score']) ?? 0,
      likeRate: toDouble(json['like_rate']) ?? 0,
    );
  }

  factory V2PostAnalytics.fromPost(V2Post post) {
    final views = post.stats.viewsCount;
    return V2PostAnalytics(
      postId: post.postId,
      viewsCount: views,
      likesCount: post.stats.likesCount,
      commentsCount: post.stats.commentsCount,
      repliesCount: post.stats.repliesCount,
      retweetsCount: post.stats.retweetsCount,
      engagementScore: post.stats.engagementScore,
      likeRate: views <= 0 ? 0 : post.stats.likesCount / views,
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

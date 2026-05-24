import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/post_card.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('post media opens a lightbox preview', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
        ],
        child: MaterialApp(home: Scaffold(body: PostCard(post: _post))),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('打开媒体').first);
    await tester.pumpAndSettle();

    expect(find.text('媒体预览'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
  });
}

final _post = V2Post(
  postId: 100001,
  author: _user,
  content: 'media post',
  postType: 'post',
  visibility: 'public',
  language: 'zh',
  location: '',
  media: [
    V2MediaAsset(
      mediaId: 1,
      mediaType: 'image',
      fileName: 'image.png',
      publicUrl: '/uploads/image.png',
      fileSize: 10,
      mimeType: 'image/png',
      status: 'ready',
      createdAt: '2026-05-24T00:00:00.000Z',
    ),
  ],
  tags: const [],
  mentions: const [],
  stats: V2PostStats(
    likesCount: 0,
    commentsCount: 0,
    repliesCount: 0,
    retweetsCount: 0,
    viewsCount: 0,
    engagementScore: 0,
  ),
  viewerState: V2ViewerPostState(
    isLiked: false,
    isBookmarked: false,
    canDelete: false,
  ),
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
);

final _user = V2PublicUser(
  userId: 1,
  username: 'edge',
  displayName: 'Edge',
  avatarUrl: '',
  bio: '',
  location: '',
  website: '',
  isVerified: 0,
  followersCount: 0,
  followingCount: 0,
  postsCount: 0,
  likesCount: 0,
  relationship: V2Relationship.empty(),
  onlineStatus: 'online',
);

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);

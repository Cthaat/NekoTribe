import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/features/media/data/media_api.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/compose_post_screen.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets(
    'composer keeps media on conflict and removes it after confirmed deletion',
    (tester) async {
      FilePicker? original;
      try {
        original = FilePicker.platform;
      } catch (_) {}
      FilePicker.platform = _ComposerFilePicker();
      addTearDown(
        () => FilePicker.platform = original ?? _ComposerFilePicker(),
      );
      final media = _FakeMediaApi();
      final tokens = _AuthenticatedTokenStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigBundleProvider.overrideWithValue(_testBundle),
            appConfigInitialProvider.overrideWithValue(_testConfig),
            tokenStoreProvider.overrideWithValue(tokens),
            authSessionProvider.overrideWith(
              (ref) => AuthSessionController(tokens)..markLoggedIn(),
            ),
            mediaApiProvider.overrideWithValue(media),
          ],
          child: const MaterialApp(home: ComposePostScreen()),
        ),
      );
      final add = find.byTooltip('添加图片');
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(media.scopes, [null]);
      final remove = find.byKey(const ValueKey('compose-remove-media-7'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(media.deleted, [7]);
      expect(remove, findsOneWidget);
      expect(find.text('此附件仍被使用，无法删除。'), findsOneWidget);

      media.conflict = false;
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(media.deleted, [7, 7]);
      expect(remove, findsNothing);
      expect(find.text('此附件仍被使用，无法删除。'), findsNothing);
    },
  );

  for (final (type, tooltip) in [('image', '添加图片'), ('video', '添加视频')]) {
    testWidgets(
      'restricted draft keeps private $type when publication is unconfirmed',
      (tester) async {
        FilePicker.platform = _ComposerFilePicker();
        final media = _FakeMediaApi();
        final posts = _FakePostsApi();
        final tokens = _AuthenticatedTokenStore();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigBundleProvider.overrideWithValue(_testBundle),
              appConfigInitialProvider.overrideWithValue(_testConfig),
              tokenStoreProvider.overrideWithValue(tokens),
              authSessionProvider.overrideWith(
                (ref) => AuthSessionController(tokens)..markLoggedIn(),
              ),
              mediaApiProvider.overrideWithValue(media),
              postsApiProvider.overrideWithValue(posts),
            ],
            child: const MaterialApp(home: ComposePostScreen()),
          ),
        );
        final visibility = find.byKey(const Key('compose-visibility-field'));
        await tester.ensureVisible(visibility);
        await tester.tap(visibility);
        await tester.pumpAndSettle();
        await tester.tap(find.text('提及的人').last);
        await tester.pumpAndSettle();
        final add = find.byTooltip(tooltip);
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();

        expect(media.scopes, ['post']);
        expect(media.types, [type]);
        expect(media.fileNames, [type == 'video' ? 'draft.mp4' : 'draft.png']);
        final field = tester.widget<DropdownButton<String>>(visibility);
        expect(
          field.items!.firstWhere((item) => item.value == 'public').enabled,
          isFalse,
        );
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Image && widget.image is NetworkImage,
          ),
          findsNothing,
        );

        posts.unconfirmed = true;
        await tester.tap(find.text('发布').last);
        await tester.pumpAndSettle();
        expect(posts.visibility, 'mentioned');
        expect(posts.mediaIds, [7]);
        expect(
          find.text('无法确认是否已发布，草稿仍保留。请先查看发布结果，再决定是否重试。'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('compose-remove-media-7')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('composer submits location, mentioned visibility, and tags', (
    tester,
  ) async {
    final posts = _FakePostsApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          tokenStoreProvider.overrideWithValue(_AuthenticatedTokenStore()),
          authSessionProvider.overrideWith((ref) {
            final controller = AuthSessionController(
              _AuthenticatedTokenStore(),
            );
            controller.markLoggedIn();
            return controller;
          }),
          postsApiProvider.overrideWithValue(posts),
        ],
        child: const MaterialApp(home: ComposePostScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('compose-content-field')),
      'Hello #Flutter',
    );
    await tester.enterText(
      find.byKey(const Key('compose-location-field')),
      'Shanghai',
    );
    await tester.enterText(
      find.byKey(const Key('compose-tags-field')),
      'cats, flutter',
    );
    await tester.tap(find.byKey(const Key('compose-visibility-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提及的人').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('发布').last);
    await tester.pumpAndSettle();

    expect(posts.content, 'Hello #Flutter');
    expect(posts.visibility, 'mentioned');
    expect(posts.location, 'Shanghai');
    expect(posts.tags, ['flutter', 'cats']);
  });
}

class _ComposerFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    if (type == FileType.video)
      PlatformFile(name: 'draft.mp4', size: 4, path: 'draft.mp4')
    else
      PlatformFile(name: 'draft.png', size: 4, bytes: Uint8List(4)),
  ]);
}

class _FakeMediaApi extends MediaApi {
  _FakeMediaApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final deleted = <int>[];
  final scopes = <String?>[];
  final types = <String>[];
  final fileNames = <String>[];
  bool conflict = true;

  @override
  Future<V2MediaAsset> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    String mediaType = 'image',
    String? mimeType,
    String? altText,
    String? description,
    String? accessScope,
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async => _uploaded(fileName, mediaType, accessScope);

  @override
  Future<V2MediaAsset> uploadFile({
    required File file,
    String mediaType = 'image',
    String? altText,
    String? description,
    String? accessScope,
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async => _uploaded(file.uri.pathSegments.last, mediaType, accessScope);

  V2MediaAsset _uploaded(
    String fileName,
    String mediaType,
    String? accessScope,
  ) {
    scopes.add(accessScope);
    types.add(mediaType);
    fileNames.add(fileName);
    return V2MediaAsset.fromJson({
      'media_id': 7,
      'media_type': mediaType,
      'file_name': fileName,
      'public_url': accessScope == 'post'
          ? '/api/v2/media/7/content'
          : '/storage/draft.png',
    });
  }

  @override
  Future<void> deleteMedia(int mediaId) async {
    deleted.add(mediaId);
    if (conflict) {
      throw ApiException(code: 40901, statusCode: 409, message: '媒体正在使用');
    }
  }
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? content;
  String? visibility;
  String? location;
  List<String> tags = const [];
  List<int> mediaIds = const [];
  bool unconfirmed = false;

  @override
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
  }) async {
    this.content = content;
    this.visibility = visibility;
    this.location = location;
    this.tags = tags;
    this.mediaIds = mediaIds;
    if (unconfirmed) throw const UnconfirmedPostError();
    return _post(content: content, visibility: visibility, location: location);
  }
}

V2Post _post({
  required String content,
  required String visibility,
  String? location,
}) {
  return V2Post(
    postId: 100001,
    author: _user,
    content: content,
    postType: 'post',
    visibility: visibility,
    language: 'zh',
    location: location ?? '',
    media: const [],
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
      canDelete: true,
    ),
    createdAt: '2026-05-25T00:00:00.000Z',
    updatedAt: '2026-05-25T00:00:00.000Z',
  );
}

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

class _AuthenticatedTokenStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => const TokenPair(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    sessionId: 'session-1',
  );

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}
}

class _FakeTokenStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}
}

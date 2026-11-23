import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/groups/presentation/group_detail_screen.dart';
import 'package:nekotribe/features/groups/presentation/groups_screen.dart';
import 'package:nekotribe/features/media/data/media_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/domain/post_poll.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  FilePicker? originalFilePicker;

  setUp(() {
    try {
      originalFilePicker = FilePicker.platform;
    } catch (_) {
      originalFilePicker = null;
    }
    FilePicker.platform = _FakeFilePicker([]);
  });

  tearDown(() {
    if (originalFilePicker != null) {
      FilePicker.platform = originalFilePicker!;
    } else {
      FilePicker.platform = _FakeFilePicker([]);
    }
  });

  testWidgets('popular groups use the ranked endpoint without list filters', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    await tester.pumpWidget(
      _testApp(
        groupsApi: api,
        mediaApi: _FakeMediaApi(),
        child: const GroupsScreen(),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.popularLimits, isEmpty);
    await tester.tap(find.text('热门群组'));
    await tester.pumpAndSettle();

    expect(api.popularLimits, [10]);
    expect(find.text('筛选群组'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Ranked first')).dy,
      lessThan(tester.getTopLeft(find.text('Ranked second')).dy),
    );
  });

  testWidgets('moderator publishes an announcement with only retained images', (
    tester,
  ) async {
    final api = _FakeGroupsApi()
      ..membershipStatus = 'active'
      ..membershipRole = 'moderator';
    final media = _FakeMediaApi();
    FilePicker.platform = _FakeFilePicker([
      _pickedFile('drop.png'),
      _pickedFile('keep.png'),
    ]);
    await tester.pumpWidget(
      _testApp(
        groupsApi: api,
        mediaApi: media,
        child: const GroupDetailScreen(slug: 'private-cats'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FloatingActionButton, '发布群组动态'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '界' * 1334);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发布'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '  群公告  ');
    await tester.tap(find.text('发布为群公告'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 2; index++) {
      final add = find.widgetWithText(OutlinedButton, '添加图片');
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('移除图片').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pumpAndSettle();
    expect(api.publishedPost, (42, '群公告', true));
    expect(media.uploadedFileNames, ['drop.png', 'keep.png']);
    expect(api.publishedImages, ['/uploads/keep.png']);
    expect(api.groupPostReads, 2);
  });

  testWidgets('group members can add a multiple-choice poll to a group post', (
    tester,
  ) async {
    final api = _FakeGroupsApi()..membershipStatus = 'active';
    await tester.pumpWidget(
      _testApp(
        groupsApi: api,
        mediaApi: _FakeMediaApi(),
        child: const GroupDetailScreen(slug: 'private-cats'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FloatingActionButton, '发布群组动态'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Pick every favourite');
    final attach = find.byKey(const Key('post-poll-attach'));
    await tester.ensureVisible(attach);
    await tester.tap(attach);
    await tester.pumpAndSettle();
    for (final (index, text) in [(1, 'Cats'), (2, 'Dogs')]) {
      final field = find.byKey(ValueKey('post-poll-option-$index'));
      await tester.ensureVisible(field);
      await tester.enterText(field, text);
      await tester.pumpAndSettle();
    }
    final multiple = find.byKey(const Key('post-poll-multiple'));
    await tester.ensureVisible(multiple);
    await tester.tap(multiple);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pumpAndSettle();
    expect(api.publishedPost, (42, 'Pick every favourite', false));
    expect(api.publishedPoll?.options, ['Cats', 'Dogs']);
    expect(api.publishedPoll?.multiple, isTrue);
  });

  testWidgets('group composer publishes Markdown with its plain summary', (
    tester,
  ) async {
    final api = _FakeGroupsApi()..membershipStatus = 'active';
    await tester.pumpWidget(
      _testApp(
        groupsApi: api,
        mediaApi: _FakeMediaApi(),
        child: const GroupDetailScreen(slug: 'private-cats'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FloatingActionButton, '发布群组动态'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-markdown-toggle')));
    await tester.pumpAndSettle();
    const source = '# Group headline\n\n- read **this**';
    await tester.enterText(find.byKey(const Key('post-markdown-field')), source);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pumpAndSettle();
    expect(api.publishedPost, (42, 'Group headline read this', false));
    expect(api.publishedMarkdown, source);
  });

  testWidgets(
    'a pending private group request can be canceled without reading posts',
    (tester) async {
      final api = _FakeGroupsApi();
      await tester.pumpWidget(
        _testApp(
          groupsApi: api,
          mediaApi: _FakeMediaApi(),
          child: const GroupDetailScreen(slug: 'private-cats'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('仅正式成员可查看此群组的动态'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '加入'));
      await tester.pumpAndSettle();
      expect(find.text('发布群组动态'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '取消入群申请（待审批）'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '加入'), findsOneWidget);
      expect(api.membershipWrites, ['join:42', 'leave:42']);
      expect(api.groupPostReads, 0);
    },
  );

  testWidgets('discover applies filters and can clear an empty result', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    _useLargeDesktopView(tester);
    await tester.pumpWidget(
      _testApp(
        groupsApi: api,
        mediaApi: _FakeMediaApi(),
        child: const GroupsScreen(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选群组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '  Cats  ');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('公开').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('科技').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(api.discoveryQueries.last, (1, 'Cats', 'public', 'tech'));
    expect(find.text('没有符合条件的群组'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(api.discoveryQueries.last, (1, '', null, null));
  });

  testWidgets(
    'invite inbox reloads after a mismatched receipt and confirms the right invite',
    (tester) async {
      final api = _FakeGroupsApi()..invitePending = true;
      _useLargeDesktopView(tester);
      await tester.pumpWidget(
        _testApp(
          groupsApi: api,
          mediaApi: _FakeMediaApi(),
          child: const GroupsScreen(initialTab: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.myGroupReads, 1);
      await tester.tap(find.text('邀请'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('接受邀请'));
      await tester.pumpAndSettle();
      expect(api.inviteReads, 2);
      expect(find.text('Invite Cats'), findsOneWidget);
      expect(find.text('已接受邀请'), findsNothing);
      expect(find.text('打开群组'), findsNothing);
      expect(find.text('无法确认处理结果，正在重新读取邀请。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      api.validReceipt = true;
      await tester.tap(find.byTooltip('接受邀请'));
      await tester.pumpAndSettle();
      expect(api.inviteReads, 3);
      expect(find.text('Invite Cats'), findsNothing);
      expect(find.text('已接受邀请'), findsOneWidget);
      expect(find.text('打开群组'), findsOneWidget);
      await tester.tap(find.text('我的群组'));
      await tester.pumpAndSettle();
      expect(api.myGroupReads, 2);
      expect(find.text('Invite Cats'), findsOneWidget);
      await tester.tap(find.text('打开群组'));
      await tester.pumpAndSettle();
      expect(find.text('flutter-cats-42'), findsOneWidget);
    },
  );

  testWidgets('targeted invite hides other invitations from older backends', (tester) async {
    final api = _FakeGroupsApi()..invitePending = true;
    _useLargeDesktopView(tester);
    await tester.pumpWidget(
      _testApp(
        groupsApi: api,
        mediaApi: _FakeMediaApi(),
        child: const GroupsScreen(initialTab: 2, inviteId: 99),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.inviteFilter, 99);
    expect(find.text('Invite Cats'), findsNothing);
    expect(find.text('这条邀请已不可用。'), findsOneWidget);
    expect(find.text('查看全部邀请'), findsOneWidget);
  });

  testWidgets('create group dialog submits privacy, category, and tags', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    _useLargeDesktopView(tester);

    await tester.pumpWidget(
      _testApp(
        groupsApi: api,
        mediaApi: _FakeMediaApi(),
        child: const GroupsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('group-create-name-field')),
      'Flutter Cats',
    );
    await tester.enterText(
      find.byKey(const Key('group-create-description-field')),
      'A parity test group',
    );
    await tester.tap(find.byKey(const Key('group-create-privacy-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私密').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-create-category-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('游戏').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-create-tags-field')),
      'Flutter, Cats, flutter',
    );

    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    expect(api.createdName, 'Flutter Cats');
    expect(api.createdDescription, 'A parity test group');
    expect(api.createdPrivacy, 'private');
    expect(api.createdCategory, 'game');
    expect(api.createdTags, ['flutter', 'cats']);
    expect(api.createdJoinApproval, isTrue);
    expect(api.createdPostPermission, 'all');
  });

  testWidgets('create group dialog uploads avatar and cover before submit', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    final mediaApi = _FakeMediaApi();
    FilePicker.platform = _FakeFilePicker([
      _pickedFile('avatar.png'),
      _pickedFile('cover.png'),
    ]);
    _useLargeDesktopView(tester);

    await tester.pumpWidget(
      _testApp(groupsApi: api, mediaApi: mediaApi, child: const GroupsScreen()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('group-create-name-field')),
      'Media Cats',
    );
    await tester.enterText(
      find.byKey(const Key('group-create-description-field')),
      'Uploads are wired',
    );

    await tester.tap(find.byKey(const Key('group-create-avatar-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-create-cover-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();

    expect(mediaApi.uploadedFileNames, ['avatar.png', 'cover.png']);
    expect(api.createdAvatarUrl, '/uploads/avatar.png');
    expect(api.createdCoverUrl, '/uploads/cover.png');
  });
}

void _useLargeDesktopView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _testApp({
  required GroupsApi groupsApi,
  required MediaApi mediaApi,
  required Widget child,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => child),
      GoRoute(
        path: '/groups/:slug',
        builder: (_, state) => Text(state.pathParameters['slug'] ?? ''),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      appConfigBundleProvider.overrideWithValue(_testBundle),
      appConfigInitialProvider.overrideWithValue(_testConfig),
      groupsApiProvider.overrideWithValue(groupsApi),
      mediaApiProvider.overrideWithValue(mediaApi),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

class _FakeGroupsApi extends GroupsApi {
  V2CreatePostPoll? publishedPoll;
  String? publishedMarkdown;
  _FakeGroupsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? createdName;
  String? createdDescription;
  String? createdAvatarUrl;
  String? createdCoverUrl;
  String? createdPrivacy;
  String? createdCategory;
  List<String>? createdTags;
  bool? createdJoinApproval;
  String? createdPostPermission;
  bool invitePending = false;
  bool validReceipt = false;
  int inviteReads = 0;
  int? inviteFilter;
  int myGroupReads = 0;
  bool inviteAccepted = false;
  final discoveryQueries = <(int, String?, String?, String?)>[];
  final popularLimits = <int>[];
  final membershipWrites = <String>[];
  String? membershipStatus;
  String? membershipRole;
  (int, String, bool)? publishedPost;
  List<String>? publishedImages;
  int groupPostReads = 0;

  @override
  Future<List<V2Group>> popular({int limit = 10}) async {
    popularLimits.add(limit);
    return [
      V2Group.fromJson({
        'group_id': 43,
        'name': 'Ranked first',
        'slug': 'first',
      }),
      V2Group.fromJson({
        'group_id': 44,
        'name': 'Ranked second',
        'slug': 'second',
      }),
    ];
  }

  @override
  Future<V2Group> getGroup(String slug) async => V2Group.fromJson({
    'group_id': 42,
    'slug': slug,
    'name': 'Private Cats',
    'privacy': 'private',
    'membership': {
      'is_member': membershipStatus != null,
      'status': membershipStatus,
      'role': membershipRole,
    },
  });

  @override
  Future<V2GroupMembership> joinGroup(
    int groupId, {
    String? message,
    String? inviteCode,
  }) async {
    membershipWrites.add('join:$groupId');
    membershipStatus = 'pending';
    return V2GroupMembership(isMember: false, status: membershipStatus);
  }

  @override
  Future<void> leaveGroup(int groupId) async {
    membershipWrites.add('leave:$groupId');
    membershipStatus = null;
  }

  @override
  Future<PagedResult<V2GroupPost>> posts(
    int groupId, {
    int page = 1,
    int size = 20,
    String type = 'all',
  }) async {
    groupPostReads++;
    return const PagedResult(items: []);
  }

  @override
  Future<PagedResult<V2Group>> list({
    String mode = 'discover',
    String? category,
    String? privacy,
    String? search,
    int page = 1,
    int size = 20,
  }) async {
    discoveryQueries.add((page, search, privacy, category));
    return const PagedResult(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
    );
  }

  @override
  Future<V2GroupPost> createPost({
    required int groupId,
    required String content,
    bool isAnnouncement = false,
    List<String> mediaUrls = const [],
    V2CreatePostPoll? poll,
    String? markdown,
    CancelToken? cancelToken,
  }) async {
    publishedPost = (groupId, content, isAnnouncement);
    publishedImages = List.of(mediaUrls);
    publishedPoll = poll;
    publishedMarkdown = markdown;
    return V2GroupPost.fromJson({
      'group_id': groupId,
      'post_id': 123,
      'content': content,
      'is_announcement': isAnnouncement,
    });
  }

  @override
  Future<PagedResult<V2Group>> myGroups({
    int page = 1,
    int size = 20,
    String? category,
    String? privacy,
    String? search,
  }) async {
    myGroupReads++;
    if (inviteAccepted) {
      return PagedResult(
        items: [_group(name: 'Invite Cats', description: '')],
      );
    }
    return const PagedResult(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
    );
  }

  @override
  Future<PagedResult<V2GroupInvite>> myInvites({
    int page = 1,
    int size = 20,
    int? inviteId,
  }) async {
    inviteReads++;
    inviteFilter = inviteId;
    if (invitePending) {
      return PagedResult(
        items: [
          V2GroupInvite.fromJson({
            'invite_id': 10,
            'group': {
              'group_id': 42,
              'name': 'Invite Cats',
              'slug': 'flutter-cats-42',
            },
            'inviter': {'username': 'owner'},
          }),
        ],
      );
    }
    return const PagedResult(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
    );
  }

  @override
  Future<V2GroupInviteResponse> respondInvite({
    required int inviteId,
    required bool accept,
  }) async {
    if (validReceipt) {
      invitePending = false;
      inviteAccepted = accept;
    }
    return V2GroupInviteResponse(
      inviteId: inviteId,
      groupId: validReceipt ? 42 : 99,
      status: accept ? 'accepted' : 'rejected',
    );
  }

  @override
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
  }) async {
    createdName = name;
    createdDescription = description;
    createdAvatarUrl = avatarUrl;
    createdCoverUrl = coverUrl;
    createdPrivacy = privacy;
    createdCategory = category;
    createdTags = tags;
    createdJoinApproval = joinApproval;
    createdPostPermission = postPermission;
    return _group(name: name, description: description, privacy: privacy);
  }
}

class _FakeMediaApi extends MediaApi {
  _FakeMediaApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final uploadedFileNames = <String>[];

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
  }) async {
    uploadedFileNames.add(fileName);
    return V2MediaAsset(
      mediaId: uploadedFileNames.length,
      mediaType: mediaType,
      fileName: fileName,
      publicUrl: '/uploads/$fileName',
      fileSize: bytes.length,
      mimeType: mimeType ?? 'image/png',
      status: 'active',
      createdAt: '2026-05-25T00:00:00.000Z',
    );
  }
}

FilePickerResult _pickedFile(String name) {
  return FilePickerResult([
    PlatformFile(name: name, size: 4, bytes: Uint8List.fromList([1, 2, 3, 4])),
  ]);
}

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this._results);

  final List<FilePickerResult> _results;

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
  }) async {
    return _results.removeAt(0);
  }
}

V2Group _group({
  required String name,
  required String description,
  String privacy = 'public',
}) {
  return V2Group(
    groupId: 42,
    name: name,
    slug: 'flutter-cats-42',
    description: description,
    avatarUrl: '',
    coverUrl: '',
    category: 'tech',
    tags: const ['flutter'],
    owner: _user,
    privacy: privacy,
    privacyDesc: privacy,
    joinApproval: privacy != 'public',
    postPermission: 'all',
    memberCount: 1,
    postCount: 0,
    isActive: 1,
    membership: V2GroupMembership(isMember: true, role: 'owner'),
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

class _FakeTokenStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}
}

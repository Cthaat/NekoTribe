import 'dart:typed_data';

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
import 'package:nekotribe/features/groups/presentation/groups_screen.dart';
import 'package:nekotribe/features/media/data/media_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
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

  @override
  Future<PagedResult<V2Group>> list({
    String mode = 'discover',
    String? category,
    int page = 1,
    int size = 20,
  }) async {
    return const PagedResult(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
    );
  }

  @override
  Future<PagedResult<V2Group>> myGroups({int page = 1, int size = 20}) async {
    return const PagedResult(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
    );
  }

  @override
  Future<PagedResult<V2GroupInvite>> myInvites({
    int page = 1,
    int size = 20,
  }) async {
    return const PagedResult(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
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

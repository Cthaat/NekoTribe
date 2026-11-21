import 'dart:async';
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
import 'package:nekotribe/features/groups/presentation/group_manage_screen.dart';
import 'package:nekotribe/features/media/data/media_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
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

  testWidgets('group drafts appear only for public group managers', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(_FakeGroupsApi(), const GroupManageScreen(slug: 'cats')),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_note_outlined), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _testApp(
        _FakeGroupsApi(privacy: 'public'),
        const GroupManageScreen(slug: 'cats'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_note_outlined), findsOneWidget);
  });

  testWidgets(
    'audit log paginates and discards replies after identity changes',
    (tester) async {
      final api = _FakeGroupsApi();
      final tokens = _FakeTokenStore();
      await tester.pumpWidget(
        _testApp(
          api,
          const GroupManageScreen(slug: 'cats'),
          tokenStore: tokens,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.history));
      await tester.pumpAndSettle();
      expect(find.text('first_action'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      await tester.pump();
      expect(api.auditPages, [1, 2]);
      expect(find.text('first_action'), findsNothing);
      tokens.beginSessionChange();
      api.nextAudit.complete(PagedResult(items: [_auditEntry('stale_action')]));
      await tester.pumpAndSettle();
      expect(find.text('stale_action'), findsNothing);
      expect(find.text('会话已变化，请重新打开群组管理'), findsOneWidget);
    },
  );

  testWidgets('invite history paginates and clears old results on sign-out', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    final tokens = _FakeTokenStore();
    _useLargeDesktopView(tester);
    await tester.pumpWidget(
      _testApp(api, const GroupManageScreen(slug: 'cats'), tokenStore: tokens),
    );
    await tester.pumpAndSettle();
    final history = find.byKey(const Key('group-manage-invite-history'));
    await tester.scrollUntilVisible(
      history,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(history);
    await tester.pumpAndSettle();
    expect(find.text('PUBLIC2026'), findsOneWidget);
    expect(find.text('@recipient'), findsOneWidget);
    expect(find.text('DIRECT2026'), findsNothing);
    expect(find.byTooltip('复制邀请码'), findsOneWidget);
    await tester.tap(find.text('下一页'));
    await tester.pump();
    expect(api.invitePages, [1, 2]);
    tokens.beginSessionChange();
    api.nextInvite.complete(PagedResult(items: [_invite(3, 'STALE2026')]));
    await tester.pumpAndSettle();
    expect(find.text('STALE2026'), findsNothing);
    expect(find.text('会话已变化，请重新打开群组管理'), findsOneWidget);
  });

  testWidgets('directed invite sends only the explicitly selected account', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    _useLargeDesktopView(tester);
    await tester.pumpWidget(
      _testApp(
        api,
        const GroupManageScreen(slug: 'cats'),
        usersApi: _FakeInviteUsers(),
      ),
    );
    await tester.pumpAndSettle();
    final open = find.byKey(const Key('group-manage-invite-recipient'));
    await tester.scrollUntilVisible(
      open,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(open);
    await tester.pumpAndSettle();
    final query = find.byKey(const Key('group-invite-recipient-query'));
    final send = find.byKey(const Key('group-invite-recipient-send'));
    await tester.enterText(query, 'recipient');
    await tester.pump();
    await tester.tap(find.byTooltip('搜索用户'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.tap(find.text('@recipient'));
    await tester.pumpAndSettle();
    await tester.enterText(query, 'recip');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    expect(api.inviteBody, isNull);
    await tester.tap(find.byTooltip('搜索用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@recipient'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-invite-recipient-message')),
      '欢迎加入',
    );
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(api.inviteGroupId, 42);
    expect(api.inviteBody, {
      'invitee_id': 77,
      'max_uses': 1,
      'expire_hours': 168,
      'message': '欢迎加入',
    });
    expect(find.text('邀请已发送'), findsOneWidget);
  });

  testWidgets('manage screen saves group metadata and invite limits', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    _useLargeDesktopView(tester);

    await tester.pumpWidget(
      _testApp(api, const GroupManageScreen(slug: 'cats')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('group-manage-name-field')),
      'Updated Cats',
    );
    await tester.enterText(
      find.byKey(const Key('group-manage-description-field')),
      'Updated description',
    );
    await tester.tap(find.byKey(const Key('group-manage-privacy-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('秘密').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-manage-category-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('艺术').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-manage-tags-field')),
      'Updated, Flutter, updated',
    );
    await tester.tap(
      find.byKey(const Key('group-manage-join-approval-switch')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-manage-post-permission-field')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const Key('group-manage-post-permission-field')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅管理员').last);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('保存').last,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(api.updatedGroupId, 42);
    expect(api.updatedName, 'Updated Cats');
    expect(api.updatedDescription, 'Updated description');
    expect(api.updatedPrivacy, 'secret');
    expect(api.updatedCategory, 'art');
    expect(api.updatedTags, ['updated', 'flutter']);
    expect(api.updatedJoinApproval, isFalse);
    expect(api.updatedPostPermission, 'admin_only');

    await tester.scrollUntilVisible(
      find.byKey(const Key('group-manage-invite-max-uses-field')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('group-manage-invite-max-uses-field')),
      '7',
    );
    await tester.enterText(
      find.byKey(const Key('group-manage-invite-expire-hours-field')),
      '24',
    );
    await tester.tap(find.text('创建邀请').last);
    await tester.pumpAndSettle();

    expect(api.inviteGroupId, 42);
    expect(api.inviteBody, {'max_uses': 7, 'expire_hours': 24});
  });

  testWidgets('manage screen uploads avatar and cover before saving', (
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
      _testApp(api, const GroupManageScreen(slug: 'cats'), mediaApi: mediaApi),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-manage-avatar-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-manage-cover-button')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('保存').last,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(mediaApi.uploadedFileNames, ['avatar.png', 'cover.png']);
    expect(api.updatedAvatarUrl, '/uploads/avatar.png');
    expect(api.updatedCoverUrl, '/uploads/cover.png');
  });

  testWidgets('manage screen handles pending members and ownership transfer', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    _useLargeDesktopView(tester);

    await tester.pumpWidget(
      _testApp(api, const GroupManageScreen(slug: 'cats')),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-approve-3')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('group-member-approve-3')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-reject-3')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('group-member-reject-3')));
    await tester.pumpAndSettle();

    expect(api.approvalCalls, [
      _ApprovalCall(memberId: 3, approved: true),
      _ApprovalCall(memberId: 3, approved: false),
    ]);

    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-menu-2')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('group-member-menu-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-member-transfer-2')).last);
    await tester.pumpAndSettle();

    expect(api.transferredOwnerId, 2);
  });

  testWidgets(
    'manage screen searches newly loaded members without duplicates',
    (tester) async {
      final api = _FakeGroupsApi()..paginateMembers = true;
      _useLargeDesktopView(tester);

      await tester.pumpWidget(
        _testApp(api, const GroupManageScreen(slug: 'cats')),
      );
      await tester.pumpAndSettle();

      final loadMore = find.byKey(const Key('group-manage-members-load-more'));
      await tester.scrollUntilVisible(
        loadMore,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(loadMore);
      await tester.pumpAndSettle();
      expect(api.memberPages, [1, 2]);
      expect(find.text('Edge'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('group-member-search-field')),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('group-member-search-field')),
        'mika',
      );
      await tester.pumpAndSettle();

      expect(find.text('Mika'), findsOneWidget);
      expect(find.text('Edge'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('group-member-search-field')),
        'nobody',
      );
      await tester.pumpAndSettle();

      expect(find.text('暂无成员'), findsOneWidget);
    },
  );

  testWidgets('manage screen deletes group after owner confirmation', (
    tester,
  ) async {
    final api = _FakeGroupsApi();
    _useLargeDesktopView(tester);

    await tester.pumpWidget(
      _testApp(api, const GroupManageScreen(slug: 'cats')),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('group-manage-delete-confirm-field')),
      320,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('group-manage-delete-confirm-field')),
      'Cat Town',
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-manage-delete-button')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('group-manage-delete-button')));
    await tester.pumpAndSettle();

    expect(api.deletedGroupId, 42);
    expect(find.text('groups-root'), findsOneWidget);
  });
}

void _useLargeDesktopView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _testApp(
  GroupsApi api,
  Widget child, {
  MediaApi? mediaApi,
  TokenStore? tokenStore,
  UsersApi? usersApi,
}) {
  final router = GoRouter(
    initialLocation: '/groups/cats/manage',
    routes: [
      GoRoute(path: '/groups', builder: (_, __) => const Text('groups-root')),
      GoRoute(path: '/groups/:slug/manage', builder: (_, __) => child),
    ],
  );
  return ProviderScope(
    overrides: [
      appConfigBundleProvider.overrideWithValue(_testBundle),
      appConfigInitialProvider.overrideWithValue(_testConfig),
      groupsApiProvider.overrideWithValue(api),
      if (tokenStore != null) tokenStoreProvider.overrideWithValue(tokenStore),
      if (usersApi != null) usersApiProvider.overrideWithValue(usersApi),
      mediaApiProvider.overrideWithValue(mediaApi ?? _FakeMediaApi()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

V2GroupAuditEntry _auditEntry(String action) => V2GroupAuditEntry.fromJson({
  'log_id': 1,
  'group_id': 42,
  'actor_id': 15,
  'action': action,
  'created_at': '2026-05-25T00:00:00.000Z',
});

V2GroupInvite _invite(int id, String code, {bool directed = false}) =>
    V2GroupInvite.fromJson({
      'invite_id': id,
      'invite_code': code,
      'group': {'group_id': 42},
      'inviter': {'username': 'owner'},
      if (directed) 'invitee': {'username': 'recipient'},
      'status': 'pending',
      'is_valid': true,
    });

class _FakeInviteUsers extends UsersApi {
  _FakeInviteUsers()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  @override
  Future<PagedResult<V2PublicUser>> searchUsers(
    String query, {
    int page = 1,
    int size = 20,
  }) async => PagedResult(
    items: [
      V2PublicUser.fromJson({'user_id': 77, 'username': 'recipient'}),
    ],
  );
}

class _FakeGroupsApi extends GroupsApi {
  _FakeGroupsApi({this.privacy = 'private'})
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final String privacy;
  bool paginateMembers = false;
  final memberPages = <int>[];
  final auditPages = <int>[];
  final invitePages = <int>[];
  final nextInvite = Completer<PagedResult<V2GroupInvite>>();
  final nextAudit = Completer<PagedResult<V2GroupAuditEntry>>();
  int? updatedGroupId;
  String? updatedName;
  String? updatedDescription;
  String? updatedAvatarUrl;
  String? updatedCoverUrl;
  String? updatedPrivacy;
  String? updatedCategory;
  List<String>? updatedTags;
  bool? updatedJoinApproval;
  String? updatedPostPermission;
  int? inviteGroupId;
  Map<String, dynamic>? inviteBody;
  int? deletedGroupId;
  final approvalCalls = <_ApprovalCall>[];
  int? transferredOwnerId;

  @override
  Future<PagedResult<V2GroupAuditEntry>> auditLogs(
    int groupId, {
    required int page,
    required CancelToken cancelToken,
  }) async {
    auditPages.add(page);
    if (page > 1) return nextAudit.future;
    return PagedResult(
      items: [_auditEntry('first_action')],
      meta: const ApiMeta(hasNext: true),
    );
  }

  @override
  Future<PagedResult<V2GroupInvite>> groupInvites(
    int groupId, {
    int page = 1,
    int size = 20,
    CancelToken? cancelToken,
  }) async {
    invitePages.add(page);
    if (page > 1) return nextInvite.future;
    return PagedResult(
      items: [
        _invite(1, 'PUBLIC2026'),
        _invite(2, 'DIRECT2026', directed: true),
      ],
      meta: const ApiMeta(hasNext: true),
    );
  }

  @override
  Future<V2Group> getGroup(String slug) async => _group(privacy: privacy);

  @override
  Future<PagedResult<V2GroupMember>> members(
    int groupId, {
    int page = 1,
    int size = 30,
    String? role,
  }) async {
    memberPages.add(page);
    if (paginateMembers) {
      return PagedResult(
        items: page == 1
            ? [_ownerMember, _pendingMember]
            : [_ownerMember, _activeMember],
        meta: ApiMeta(page: page, pageSize: size, total: 3, hasNext: page == 1),
      );
    }
    return PagedResult(
      items: [_ownerMember, _activeMember, _pendingMember],
      meta: const ApiMeta(page: 1, pageSize: 30, total: 3, hasNext: false),
    );
  }

  @override
  Future<V2GroupNotificationPreference> getNotificationPreference(
    int groupId,
  ) async {
    return V2GroupNotificationPreference(
      userId: 1,
      groupId: groupId,
      isEnabled: true,
      updatedAt: '2026-05-25T00:00:00.000Z',
    );
  }

  @override
  Future<V2Group> updateGroup({
    required int groupId,
    String? name,
    String? description,
    String? avatarUrl,
    String? coverUrl,
    String? privacy,
    String? category,
    List<String>? tags,
    bool? joinApproval,
    String? postPermission,
  }) async {
    updatedGroupId = groupId;
    updatedName = name;
    updatedDescription = description;
    updatedAvatarUrl = avatarUrl;
    updatedCoverUrl = coverUrl;
    updatedPrivacy = privacy;
    updatedCategory = category;
    updatedTags = tags;
    updatedJoinApproval = joinApproval;
    updatedPostPermission = postPermission;
    return _group(
      name: name ?? 'Cat Town',
      description: description ?? 'Original description',
      privacy: privacy ?? 'private',
      category: category ?? 'tech',
      tags: tags ?? const ['old'],
      joinApproval: joinApproval ?? true,
      postPermission: postPermission ?? 'all',
    );
  }

  @override
  Future<V2GroupInvite> createInvite(
    int groupId,
    Map<String, dynamic> body,
  ) async {
    inviteGroupId = groupId;
    inviteBody = body;
    return V2GroupInvite(
      inviteId: 100,
      inviteCode: body['invitee_id'] == null ? 'abc' : null,
      status: 'pending',
      maxUses: body['max_uses'] as int?,
      usedCount: 0,
      expiresAt: '2026-05-26T00:00:00.000Z',
      createdAt: '2026-05-25T00:00:00.000Z',
      inviter: _user,
      isValid: true,
    );
  }

  @override
  Future<void> deleteGroup(int groupId) async {
    deletedGroupId = groupId;
  }

  @override
  Future<V2GroupMemberStatus> approveMember({
    required int groupId,
    required int memberId,
    required bool approved,
  }) async {
    approvalCalls.add(_ApprovalCall(memberId: memberId, approved: approved));
    return V2GroupMemberStatus(
      memberId: memberId,
      userId: _pendingMember.user.userId,
      status: approved ? 'active' : 'rejected',
      role: 'member',
    );
  }

  @override
  Future<void> transferOwnership({
    required int groupId,
    required int newOwnerId,
  }) async {
    transferredOwnerId = newOwnerId;
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
  String name = 'Cat Town',
  String description = 'Original description',
  String privacy = 'private',
  String category = 'tech',
  List<String> tags = const ['old'],
  bool joinApproval = true,
  String postPermission = 'all',
}) {
  return V2Group(
    groupId: 42,
    name: name,
    slug: 'cats',
    description: description,
    avatarUrl: '',
    coverUrl: '',
    category: category,
    tags: tags,
    owner: _user,
    privacy: privacy,
    privacyDesc: privacy,
    joinApproval: joinApproval,
    postPermission: postPermission,
    memberCount: 1,
    postCount: 0,
    isActive: 1,
    membership: V2GroupMembership(
      isMember: true,
      role: 'owner',
      status: 'active',
    ),
    createdAt: '2026-05-25T00:00:00.000Z',
    updatedAt: '2026-05-25T00:00:00.000Z',
  );
}

final _ownerMember = V2GroupMember(
  memberId: 1,
  user: _user,
  role: 'owner',
  roleDesc: 'Owner',
  status: 'active',
  joinedAt: '2026-05-25T00:00:00.000Z',
);

final _activeMember = V2GroupMember(
  memberId: 2,
  user: _activeUser,
  role: 'member',
  roleDesc: 'Member',
  status: 'active',
  joinedAt: '2026-05-25T00:00:00.000Z',
);

final _pendingMember = V2GroupMember(
  memberId: 3,
  user: _pendingUser,
  role: 'member',
  roleDesc: 'Member',
  status: 'pending',
  joinedAt: '2026-05-25T00:00:00.000Z',
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

final _activeUser = V2PublicUser(
  userId: 2,
  username: 'mika',
  displayName: 'Mika',
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

final _pendingUser = V2PublicUser(
  userId: 3,
  username: 'pending',
  displayName: 'Pending Cat',
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
  onlineStatus: 'offline',
);

class _ApprovalCall {
  const _ApprovalCall({required this.memberId, required this.approved});

  final int memberId;
  final bool approved;

  @override
  bool operator ==(Object other) {
    return other is _ApprovalCall &&
        other.memberId == memberId &&
        other.approved == approved;
  }

  @override
  int get hashCode => Object.hash(memberId, approved);
}

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

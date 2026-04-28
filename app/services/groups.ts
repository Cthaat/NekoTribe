import {
  v2CreateGroup,
  v2CreateGroupInvite,
  v2JoinGroup,
  v2LeaveGroup,
  v2ListGroupMembers,
  v2ListGroupPosts,
  v2ListGroups,
  v2ListMyGroups,
  v2RespondGroupInvite
} from '@/api/v2/groups';
import type {
  V2CreateGroupPayload,
  V2Group,
  V2GroupMember,
  V2GroupPost,
  V2GroupPrivacy,
  V2GroupRole,
  V2PublicUser
} from '@/types/v2';
import type {
  CreateGroupData,
  Group,
  GroupDetailResult,
  GroupFiltersData,
  GroupInviteView,
  GroupListResult,
  GroupMember,
  GroupOwner,
  GroupPost,
  GroupStatsData
} from '@/types/groups';
import {
  normalizeAssetUrl,
  normalizeAvatarUrl,
  normalizeNullableAssetUrl
} from '@/utils/assets';

const groupPrivacyValues = [
  'public',
  'private',
  'secret'
] as const;

const elevatedRoles: V2GroupRole[] = [
  'owner',
  'admin',
  'moderator'
];

function isGroupPrivacy(
  value: string
): value is V2GroupPrivacy {
  return groupPrivacyValues.some(item => item === value);
}

function toOptionalGroupPrivacy(
  value: string
): V2GroupPrivacy | undefined {
  return isGroupPrivacy(value) ? value : undefined;
}

function publicUserName(user: V2PublicUser): string {
  return user.display_name || user.username;
}

function mapOwner(user: V2PublicUser): GroupOwner {
  return {
    id: user.user_id,
    username: user.username,
    nickname: publicUserName(user),
    avatar: normalizeAvatarUrl(user.avatar_url)
  };
}

export function mapV2GroupToGroup(group: V2Group): Group {
  const role = group.membership.role;
  return {
    id: group.group_id,
    name: group.name,
    description: group.description,
    avatar: normalizeNullableAssetUrl(group.avatar_url) || '',
    coverImage:
      normalizeNullableAssetUrl(group.cover_url) || undefined,
    privacy: group.privacy,
    memberCount: group.member_count,
    postCount: group.post_count,
    createdAt: group.created_at,
    owner: mapOwner(group.owner),
    isMember: group.membership.is_member,
    isOwner: role === 'owner',
    isAdmin: role ? elevatedRoles.includes(role) : false,
    membershipStatus: group.membership.status,
    tags: []
  };
}

function mapV2MemberToGroupMember(
  member: V2GroupMember
): GroupMember {
  const displayName =
    member.nickname || publicUserName(member.user);
  return {
    id: member.member_id,
    userId: member.user.user_id,
    username: member.user.username,
    nickname: displayName,
    avatar: normalizeAvatarUrl(member.user.avatar_url),
    role: member.role,
    joinedAt: member.joined_at,
    isMuted: member.status === 'muted'
  };
}

function mediaTypeFromUrl(url: string): 'image' | 'video' {
  return /\.(mp4|webm|mov|m4v)$/i.test(url)
    ? 'video'
    : 'image';
}

function mapV2PostToGroupPost(
  post: V2GroupPost
): GroupPost {
  return {
    id: post.post_id,
    content: post.content,
    author: {
      ...mapOwner(post.author),
      role: 'member'
    },
    media: post.media_urls.map(rawUrl => {
      const url = normalizeAssetUrl(rawUrl);
      return {
        type: mediaTypeFromUrl(url),
        url
      };
    }),
    isPinned: post.is_pinned,
    likeCount: post.likes_count,
    commentCount: post.comments_count,
    isLiked: post.is_liked_by_me,
    createdAt: post.created_at
  };
}

function applyLocalGroupFilters(
  groups: Group[],
  filters: GroupFiltersData
): Group[] {
  let result = [...groups];
  const query = filters.search.trim().toLowerCase();

  if (query) {
    result = result.filter(
      group =>
        group.name.toLowerCase().includes(query) ||
        group.description.toLowerCase().includes(query)
    );
  }

  if (filters.privacy !== 'all') {
    result = result.filter(
      group => group.privacy === filters.privacy
    );
  }

  if (
    filters.category !== 'all' &&
    result.some(group => group.category)
  ) {
    const categoryMap: Record<string, string> = {
      tech: '科技',
      game: '游戏',
      music: '音乐',
      art: '艺术',
      life: '生活',
      study: '学习',
      work: '工作',
      other: '其他'
    };
    const category = categoryMap[filters.category];
    result = result.filter(
      group => group.category === category
    );
  }

  switch (filters.sortBy) {
    case 'newest':
      return result.sort(
        (a, b) =>
          new Date(b.createdAt).getTime() -
          new Date(a.createdAt).getTime()
      );
    case 'active':
      return result.sort(
        (a, b) => b.postCount - a.postCount
      );
    case 'members':
    case 'popular':
    default:
      return result.sort(
        (a, b) => b.memberCount - a.memberCount
      );
  }
}

function emptyGroupStats(): GroupStatsData {
  return {
    totalGroups: 0,
    myGroups: 0,
    pendingInvites: 0,
    todayPosts: 0,
    activeMembers: 0,
    newMembers: 0
  };
}

export function buildGroupStats(
  groups: Group[],
  totalGroups: number,
  myGroups: number
): GroupStatsData {
  return {
    ...emptyGroupStats(),
    totalGroups,
    myGroups,
    activeMembers: groups.reduce(
      (sum, group) => sum + group.memberCount,
      0
    ),
    todayPosts: groups.reduce(
      (sum, group) => sum + group.postCount,
      0
    )
  };
}

export async function listDiscoverGroups(
  filters: GroupFiltersData,
  page: number,
  pageSize: number
): Promise<GroupListResult> {
  const result = await v2ListGroups({
    q: filters.search.trim() || undefined,
    privacy: toOptionalGroupPrivacy(filters.privacy),
    page,
    page_size: pageSize
  });
  const groups = applyLocalGroupFilters(
    result.items.map(mapV2GroupToGroup),
    filters
  );
  return {
    groups,
    total: result.meta?.total ?? groups.length,
    hasNext: !!result.meta?.has_next
  };
}

export async function listJoinedGroups(
  filters: GroupFiltersData,
  page: number,
  pageSize: number
): Promise<GroupListResult> {
  const result = await v2ListMyGroups({
    page,
    page_size: pageSize
  });
  const groups = applyLocalGroupFilters(
    result.items.map(mapV2GroupToGroup),
    filters
  );
  return {
    groups,
    total: result.meta?.total ?? groups.length,
    hasNext: !!result.meta?.has_next
  };
}

export async function countJoinedGroups(): Promise<number> {
  const result = await v2ListMyGroups({
    page: 1,
    page_size: 1
  });
  return result.meta?.total ?? result.items.length;
}

export async function createGroup(
  data: CreateGroupData
): Promise<Group> {
  const payload: V2CreateGroupPayload = {
    name: data.name,
    description: data.description,
    avatar_url: data.avatar || null,
    cover_url: data.coverImage || null,
    privacy: data.privacy,
    join_approval: data.privacy !== 'public',
    post_permission: 'all'
  };
  return mapV2GroupToGroup(await v2CreateGroup(payload));
}

export async function joinGroup(
  groupId: number
): Promise<string> {
  const result = await v2JoinGroup(groupId);
  return result.status;
}

export async function leaveGroup(
  groupId: number
): Promise<void> {
  await v2LeaveGroup(groupId);
}

export async function loadGroupDetail(
  groupId: number
): Promise<GroupDetailResult> {
  const [membersResult, postsResult] = await Promise.allSettled([
    v2ListGroupMembers(groupId, {
      page: 1,
      page_size: 20
    }),
    v2ListGroupPosts(groupId, {
      page: 1,
      page_size: 10
    })
  ]);

  return {
    members:
      membersResult.status === 'fulfilled'
        ? membersResult.value.items.map(
            mapV2MemberToGroupMember
          )
        : [],
    posts:
      postsResult.status === 'fulfilled'
        ? postsResult.value.items.map(mapV2PostToGroupPost)
        : []
  };
}

export async function createGroupInvite(
  groupId: number
): Promise<string | null> {
  const result = await v2CreateGroupInvite(groupId, {
    max_uses: 100,
    expire_hours: 168
  });
  return result.invite_url;
}

export async function listMyGroupInvites(): Promise<
  GroupInviteView[]
> {
  return [];
}

export async function respondGroupInvite(
  inviteId: number,
  accept: boolean
): Promise<void> {
  await v2RespondGroupInvite(inviteId, { accept });
}

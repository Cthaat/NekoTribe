import {
  v2ApproveGroupMember,
  v2ChangeGroupMemberRole,
  v2CreateGroup,
  v2CreateGroupPostComment,
  v2CreateGroupInvite,
  v2CreateGroupPost,
  v2DeleteGroup,
  v2DeleteGroupPostComment,
  v2DeleteGroupPost,
  v2GetGroupNotificationPreference,
  v2GetGroupById,
  v2GetGroupBySlug,
  v2GetGroupPost,
  v2JoinGroup,
  v2LeaveGroup,
  v2ListGroupPostComments,
  v2ListGroupInvites,
  v2ListGroupMembers,
  v2ListGroupPosts,
  v2ListHomeGroupActivity,
  v2ListGroups,
  v2ListMyGroupInvites,
  v2ListMyGroups,
  v2ListPopularGroups,
  v2MuteGroupMember,
  v2PatchGroup,
  v2PutGroupNotificationPreference,
  v2RemoveGroupMember,
  v2RespondGroupInvite,
  v2SetGroupCommentLikeStatus,
  v2SetGroupPostLikeStatus,
  v2SetGroupPostPinStatus,
  v2TransferGroupOwnership,
  v2UnmuteGroupMember
} from '@/api/v2/groups';
import type {
  V2CreateGroupInviteData,
  V2CreateGroupCommentPayload,
  V2CreateGroupPostPayload,
  V2CreateGroupPayload,
  V2GroupCategory,
  V2Group,
  V2GroupComment,
  V2GroupCommentLikeData,
  V2GroupNotificationPreference,
  V2GroupPostLikeData,
  V2GroupMember,
  V2GroupPost,
  V2GroupPostListType,
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
  GroupPostFeedOptions,
  GroupPostFeedResult,
  GroupPostGroup,
  GroupStatsData,
  UpdateGroupData
} from '@/types/groups';
import type {
  CommentLikeVM,
  CommentVM,
  PageViewModel,
  PostAuthorVM
} from '@/types/posts';
import {
  normalizePublicMediaUrl,
  normalizeAvatarUrl,
  normalizeNullableAssetUrl
} from '@/utils/assets';

const groupPrivacyValues = [
  'public',
  'private',
  'secret'
] as const;

const groupCategoryValues = [
  'tech',
  'game',
  'music',
  'art',
  'life',
  'study',
  'work',
  'other'
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

function isGroupCategory(
  value: string
): value is V2GroupCategory {
  return groupCategoryValues.some(item => item === value);
}

function toOptionalGroupCategory(
  value: string
): V2GroupCategory | undefined {
  return isGroupCategory(value) ? value : undefined;
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
    slug: group.slug,
    name: group.name,
    description: group.description,
    avatar: normalizeNullableAssetUrl(group.avatar_url) || '',
    coverImage:
      normalizeNullableAssetUrl(group.cover_url) || undefined,
    privacy: group.privacy,
    isActive: group.is_active === 1,
    joinApproval: group.join_approval,
    postPermission: group.post_permission,
    memberCount: group.member_count,
    postCount: group.post_count,
    createdAt: group.created_at,
    updatedAt: group.updated_at,
    owner: mapOwner(group.owner),
    isMember: group.membership.is_member,
    isOwner: role === 'owner',
    isAdmin: role ? elevatedRoles.includes(role) : false,
    membershipRole: role,
    membershipStatus: group.membership.status,
    category: group.category,
    tags: group.tags
  };
}

export function mapV2MemberToGroupMember(
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
    status: member.status,
    joinedAt: member.joined_at,
    isMuted: member.status === 'muted',
    mutedUntil: member.mute_until ?? undefined
  };
}

function mapV2PublicUserToPostAuthor(
  user: V2PublicUser
): PostAuthorVM {
  return {
    id: user.user_id,
    username: user.username,
    name: publicUserName(user),
    avatarUrl: normalizeAvatarUrl(user.avatar_url),
    bio: user.bio,
    location: user.location,
    website: user.website,
    verified: user.is_verified === 1,
    followersCount: user.followers_count,
    followingCount: user.following_count,
    postsCount: user.posts_count,
    likesCount: user.likes_count,
    relation: user.relationship.relation
  };
}

function mapV2GroupCommentToComment(
  comment: V2GroupComment
): CommentVM {
  return {
    id: comment.comment_id,
    postId: comment.post_id,
    author: mapV2PublicUserToPostAuthor(comment.author),
    parentCommentId: comment.parent_comment_id,
    rootCommentId: null,
    content: comment.content,
    counts: {
      likes: comment.likes_count,
      replies: 0
    },
    viewer: {
      hasLiked: comment.is_liked_by_me,
      canDelete: comment.can_delete_by_me
    },
    createdAt: comment.created_at,
    updatedAt: comment.updated_at
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
    groupId: post.group_id,
    ...(post.poll ? {poll:post.poll} : {}),
    ...(post.markdown === undefined ? {} : {markdown:post.markdown}),
    content: post.content,
    author: {
      ...mapOwner(post.author),
      role: 'member'
    },
    media: post.media_urls.map(rawUrl => {
      const url = normalizePublicMediaUrl(rawUrl);
      return {
        type: mediaTypeFromUrl(url),
        url
      };
    }),
    isPinned: post.is_pinned,
    isAnnouncement: post.is_announcement,
    likeCount: post.likes_count,
    commentCount: post.comments_count,
    isLiked: post.is_liked_by_me,
    createdAt: post.created_at
  };
}

function mapGroupToPostGroup(group: Group): GroupPostGroup {
  return {
    id: group.id,
    name: group.name,
    avatar: group.avatar,
    privacy: group.privacy,
    isActive: group.isActive,
    isMember: group.isMember,
    canComment: group.membershipStatus === 'active',
    canManage: !!(group.isOwner || group.isAdmin)
  };
}

function matchesGroupPostType(
  post: GroupPost,
  type: V2GroupPostListType
): boolean {
  if (type === 'pinned') return !!post.isPinned;
  if (type === 'announcement') return !!post.isAnnouncement;
  return true;
}

function sortGroupPosts(posts: GroupPost[]): GroupPost[] {
  const rank = (post: GroupPost) => post.isPinned ? 2 : post.isAnnouncement ? 1 : 0;
  return [...posts].sort((a, b) => {
    return rank(b) - rank(a) ||
      (Date.parse(b.createdAt) - Date.parse(a.createdAt)) ||
      b.id - a.id;
  });
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
    const category = toOptionalGroupCategory(filters.category);
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
    category: toOptionalGroupCategory(filters.category),
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

export async function listPopularGroups(): Promise<GroupListResult> {
  const { items } = await v2ListPopularGroups({ limit: 10 });
  const groups = items.map(mapV2GroupToGroup);
  return { groups, total: groups.length, hasNext: false };
}

export async function listJoinedGroups(
  filters: GroupFiltersData,
  page: number,
  pageSize: number
): Promise<GroupListResult> {
  const result = await v2ListMyGroups({
    q: filters.search.trim() || undefined,
    privacy: toOptionalGroupPrivacy(filters.privacy),
    category: toOptionalGroupCategory(filters.category),
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
    category: data.category,
    tags: data.tags,
    privacy: data.privacy,
    join_approval: data.privacy !== 'public',
    post_permission: 'all'
  };
  return mapV2GroupToGroup(await v2CreateGroup(payload));
}

export async function getGroup(groupId: number): Promise<Group> {
  return mapV2GroupToGroup(await v2GetGroupById(groupId));
}

export async function getGroupBySlug(slug: string): Promise<Group> {
  return mapV2GroupToGroup(await v2GetGroupBySlug(slug));
}

export async function updateGroup(
  groupId: number,
  data: UpdateGroupData
): Promise<Group> {
  return mapV2GroupToGroup(
    await v2PatchGroup(groupId, {
      name: data.name,
      description: data.description,
      avatar_url: data.avatar || null,
      cover_url: data.coverImage || null,
      category: data.category,
      tags: data.tags,
      privacy: data.privacy,
      join_approval: data.joinApproval,
      post_permission: data.postPermission
    })
  );
}

export async function deleteGroup(
  groupId: number
): Promise<void> {
  await v2DeleteGroup(groupId);
}

export async function getGroupNotificationPreference(
  groupId: number
): Promise<V2GroupNotificationPreference> {
  return await v2GetGroupNotificationPreference(groupId);
}

export async function setGroupNotificationPreference(
  groupId: number,
  isEnabled: boolean
): Promise<V2GroupNotificationPreference> {
  return await v2PutGroupNotificationPreference(
    groupId,
    isEnabled
  );
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

export function groupMembershipAction(group: Group) {
  const status = group.membershipStatus;
  if (group.isOwner || group.membershipRole === 'owner') return null;
  if (status === 'pending') return { event: 'leave', label: 'cancelRequest' } as const;
  if (status === 'active' || status === 'muted') return { event: 'leave', label: 'leave' } as const;
  if (status || group.isMember || group.privacy === 'secret') return null;
  return {
    event: 'join',
    label: group.privacy === 'public' && !group.joinApproval ? 'join' : 'requestJoin'
  } as const;
}

export async function loadGroupDetail(
  group: Group
): Promise<GroupDetailResult> {
  const status = group.membershipStatus;
  const canReadMembers = status !== 'banned' &&
    (group.privacy === 'public' || status === 'active' || status === 'muted');
  const canReadPosts = group.privacy === 'public' || status === 'active';
  const [membersResult, postsResult] = await Promise.allSettled([
    canReadMembers ? v2ListGroupMembers(group.id, {
      page: 1,
      page_size: 20
    }) : null,
    canReadPosts ? v2ListGroupPosts(group.id, {
      page: 1,
      page_size: 10
    }) : null
  ]);

  return {
    members:
      membersResult.status === 'fulfilled' && membersResult.value
        ? membersResult.value.items.map(
            mapV2MemberToGroupMember
          )
        : [],
    posts:
      postsResult.status === 'fulfilled' && postsResult.value
        ? postsResult.value.items.map(mapV2PostToGroupPost)
        : []
  };
}

export async function listGroupPosts(
  groupId: number,
  page: number,
  pageSize: number,
  type: V2GroupPostListType = 'all'
): Promise<{
  posts: GroupPost[];
  total: number;
  hasNext: boolean;
}> {
  const result = await v2ListGroupPosts(groupId, {
    type,
    page,
    page_size: pageSize
  });
  const posts = result.items
    .map(mapV2PostToGroupPost)
    .filter(post => matchesGroupPostType(post, type));
  return {
    posts,
    total: result.meta?.total ?? posts.length,
    hasNext: !!result.meta?.has_next
  };
}

export type HomeGroupPost = GroupPost & { groupId: number; groupName: string };

export async function listHomeGroupActivity(page: number, pageSize: number): Promise<PageViewModel<HomeGroupPost>> {
  const result = await v2ListHomeGroupActivity(page, pageSize);
  return {
    items: result.items.map(post => ({
      ...mapV2PostToGroupPost(post), groupId: post.group_id, groupName: post.group_name,
    })),
    page, pageSize, total: result.meta?.total ?? result.items.length, hasNext: result.meta?.has_next === true,
  };
}

async function listJoinedGroupPostsForAllGroups(
  groups: Group[],
  type: V2GroupPostListType,
  page: number,
  pageSize: number,
  current: () => boolean
): Promise<GroupPostFeedResult> {
  const app = useNuxtApp();
  const end = page * pageSize;
  // Keep a fixed server page size when moving past the server's size cap.
  const batchSize = Math.min(100, end);
  async function readGroup(group: Group) {
    const groupContext = mapGroupToPostGroup(group);
    const posts = new Map<number, GroupPost>();
    let total = 0;
    for (let groupPage = 1; ; groupPage++) {
      if (!current()) throw Error('Group feed request superseded');
      const result = await app.runWithContext(() =>
        listGroupPosts(group.id, groupPage, batchSize, type));
      if (!current()) throw Error('Group feed request superseded');
      total = result.total;
      for (const post of result.posts) {
        posts.set(post.id, { ...post, group: groupContext });
      }
      if (!result.hasNext || posts.size >= end) break;
      if (!result.posts.length || groupPage === 10000) {
        throw Error('Invalid group post pagination');
      }
    }
    return { total, posts: [...posts.values()] };
  }
  const results: Awaited<ReturnType<typeof readGroup>>[] = [];
  for (let index = 0; index < groups.length; index += 8) {
    results.push(...await Promise.all(groups.slice(index, index + 8).map(readGroup)));
  }
  const allPosts = sortGroupPosts(
    results.flatMap(result => result.posts)
  );
  const start = (page - 1) * pageSize;
  const total = results.reduce((sum, result) => sum + result.total, 0);
  return {
    groups,
    posts: allPosts.slice(start, end),
    total,
    hasNext: total > end && allPosts.length > start
  };
}

export async function listJoinedGroupPostFeed(
  options: GroupPostFeedOptions,
  current: () => boolean
): Promise<GroupPostFeedResult> {
  const app = useNuxtApp();
  const joined = new Map<number, Group>();
  for (let page = 1; ; page++) {
    if (!current()) throw Error('Group feed request superseded');
    const groupsResult = await app.runWithContext(() =>
      v2ListMyGroups({ page, page_size: 100 }));
    if (!current()) throw Error('Group feed request superseded');
    for (const item of groupsResult.items) {
      joined.set(item.group_id, mapV2GroupToGroup(item));
    }
    if (!groupsResult.meta?.has_next) break;
    if (!groupsResult.items.length || page === 10000) throw Error('Invalid group pagination');
  }
  const groups = applyLocalGroupFilters(
    [...joined.values()],
    {
      search: '',
      privacy: 'all',
      category: 'all',
      sortBy: 'active'
    }
  );
  const type = options.type ?? 'all';

  if (options.groupId) {
    const group = groups.find(
      item => item.id === options.groupId
    );
    if (!group) {
      return {
        groups,
        posts: [],
        total: 0,
        hasNext: false
      };
    }
    const result = await app.runWithContext(() => listGroupPosts(
      group.id,
      options.page,
      options.pageSize,
      type
    ));
    const groupContext = mapGroupToPostGroup(group);
    return {
      groups,
      posts: result.posts.map(post => ({
        ...post,
        group: groupContext
      })),
      total: result.total,
      hasNext: result.hasNext
    };
  }

  return await app.runWithContext(() => listJoinedGroupPostsForAllGroups(
    groups,
    type,
    options.page,
    options.pageSize,
    current
  ));
}

export async function getGroupPost(groupId: number, postId: number): Promise<GroupPost> {
  const [group, post] = await Promise.all([getGroup(groupId), v2GetGroupPost(groupId, postId)]);
  if (group.id !== groupId || post.post_id !== postId || post.group_id !== groupId) {
    throw new Error('Invalid group post');
  }
  return { ...mapV2PostToGroupPost(post), group: mapGroupToPostGroup(group) };
}

export async function createGroupPost(
  groupId: number,
  payload: V2CreateGroupPostPayload,
  signal?: AbortSignal
): Promise<GroupPost> {
  return mapV2PostToGroupPost(
    await v2CreateGroupPost(groupId, payload, signal)
  );
}

export function canPublishGroupPost(group: Group): boolean {
  if (group.membershipStatus !== 'active') return false;
  const role = group.membershipRole;
  return group.postPermission === 'all' ||
    (group.postPermission === 'moderator_up' && (role === 'moderator' || role === 'admin' || role === 'owner')) ||
    (group.postPermission === 'admin_only' && (role === 'admin' || role === 'owner'));
}

export async function deleteGroupPost(
  groupId: number,
  postId: number
): Promise<void> {
  await v2DeleteGroupPost(groupId, postId);
}

export async function setGroupPostPinStatus(
  groupId: number,
  postId: number,
  isPinned: boolean
) {
  return await v2SetGroupPostPinStatus(
    groupId,
    postId,
    isPinned
  );
}

export async function setGroupPostLikeStatus(
  groupId: number,
  postId: number,
  liked: boolean
): Promise<V2GroupPostLikeData> {
  return await v2SetGroupPostLikeStatus(
    groupId,
    postId,
    liked
  );
}

export async function listGroupPostComments(
  groupId: number,
  postId: number,
  page = 1,
  pageSize = 50,
  commentId?: number,
  sort: 'newest' | 'oldest' | 'popular' = 'newest'
): Promise<{
  comments: CommentVM[];
  total: number;
  hasNext: boolean;
}> {
  const result = await v2ListGroupPostComments(groupId, postId, {
    page,
    page_size: pageSize,
    sort,
    ...(commentId === undefined ? {} : {comment_id: commentId})
  });
  const comments = result.items.map(mapV2GroupCommentToComment);
  return {
    comments,
    total: result.meta?.total ?? comments.length,
    hasNext: !!result.meta?.has_next
  };
}

export async function createGroupPostComment(
  groupId: number,
  postId: number,
  payload: V2CreateGroupCommentPayload
): Promise<CommentVM> {
  return mapV2GroupCommentToComment(
    await v2CreateGroupPostComment(groupId, postId, payload)
  );
}

export async function deleteGroupPostComment(
  groupId: number,
  postId: number,
  commentId: number
): Promise<void> {
  await v2DeleteGroupPostComment(groupId, postId, commentId);
}

export async function setGroupCommentLikeStatus(
  groupId: number,
  postId: number,
  commentId: number,
  liked: boolean
): Promise<CommentLikeVM> {
  const result: V2GroupCommentLikeData =
    await v2SetGroupCommentLikeStatus(
      groupId,
      postId,
      commentId,
      liked
    );
  return {
    commentId: result.comment_id,
    isLiked: result.is_liked,
    likesCount: result.likes_count
  };
}

export async function listGroupMembers(
  groupId: number,
  page: number,
  signal?: AbortSignal
): Promise<{ members: GroupMember[]; hasNext: boolean }> {
  const result = await v2ListGroupMembers(groupId, {
    page,
    page_size: 100
  }, signal);
  return {
    members: result.items.map(mapV2MemberToGroupMember),
    hasNext: result.meta?.has_next === true
  };
}

export async function approveGroupMember(
  groupId: number,
  memberId: number,
  approved: boolean
): Promise<void> {
  await v2ApproveGroupMember(groupId, memberId, approved);
}

export async function removeGroupMember(
  groupId: number,
  userId: number
): Promise<void> {
  await v2RemoveGroupMember(groupId, userId);
}

export async function changeGroupMemberRole(
  groupId: number,
  userId: number,
  role: Exclude<V2GroupRole, 'owner'>
): Promise<void> {
  await v2ChangeGroupMemberRole(groupId, userId, role);
}

export async function muteGroupMember(
  groupId: number,
  userId: number,
  durationHours: number,
  reason: string | null = null
): Promise<void> {
  await v2MuteGroupMember(groupId, userId, {
    duration_hours: durationHours,
    reason
  });
}

export async function unmuteGroupMember(
  groupId: number,
  userId: number
): Promise<void> {
  await v2UnmuteGroupMember(groupId, userId);
}

export async function transferGroupOwnership(
  groupId: number,
  newOwnerId: number
): Promise<void> {
  await v2TransferGroupOwnership(groupId, newOwnerId);
}

export async function listGroupInvites(
  groupId: number,
  page: number,
  signal?: AbortSignal
) {
  return v2ListGroupInvites(groupId, {
    page,
    page_size: 20
  }, signal);
}

export async function createGroupInviteData(
  groupId: number,
  maxUses: number,
  expireHours: number
): Promise<V2CreateGroupInviteData> {
  return await v2CreateGroupInvite(groupId, {
    max_uses: maxUses,
    expire_hours: expireHours
  });
}

export async function createGroupInvite(
  groupId: number
): Promise<string | null> {
  const result = await createGroupInviteData(groupId, 100, 168);
  return result.invite_url;
}

export async function listMyGroupInvites(page: number, signal?: AbortSignal, inviteId?: number) {
  const result = await v2ListMyGroupInvites({
    page,
    page_size: 20,
    ...(inviteId === undefined ? {} : { invite_id: inviteId })
  }, signal);
  const items: GroupInviteView[] = result.items
    .filter(invite => invite.group && (inviteId === undefined || invite.invite_id === inviteId))
    .map(invite => ({
      id: invite.invite_id,
      group: {
        id: invite.group?.group_id ?? 0,
        name: invite.group?.name ?? '',
        avatar:
          normalizeNullableAssetUrl(
            invite.group?.avatar_url ?? null
          ) || '',
        memberCount: invite.group?.member_count ?? 0,
        description: invite.group?.description ?? ''
      },
      inviter: mapOwner(invite.inviter),
      message: invite.message ?? undefined,
      createdAt: invite.created_at,
      expiresAt: invite.expires_at ?? undefined
    }));
  if (inviteId !== undefined) return { items, hasNext: false, total: items.length };
  return { items, hasNext: result.meta?.has_next === true, total: result.meta?.total ?? items.length };
}

export async function respondGroupInvite(
  inviteId: number,
  accept: boolean,
  signal?: AbortSignal
) {
  return v2RespondGroupInvite(inviteId, { accept }, signal);
}

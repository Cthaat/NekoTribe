import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import type {
  V2CreateGroupInviteData,
  V2CreateGroupInvitePayload,
  V2CreateGroupCommentPayload,
  V2CreateGroupPostPayload,
  V2CreateGroupPayload,
  V2Group,
  V2GroupAuditEntry,
  V2GroupComment,
  V2GroupCommentLikeData,
  V2GroupInvite,
  V2GroupInviteListQuery,
  V2MyGroupInviteListQuery,
  V2GroupListQuery,
  V2GroupMember,
  V2GroupMemberStatusData,
  V2GroupMemberListQuery,
  V2GroupPost,
  V2GroupPostLikeData,
  V2GroupPostListQuery,
  V2GroupPostPinStatusData,
  V2GroupNotificationPreference,
  V2JoinGroupData,
  V2JoinGroupPayload,
  V2PagedResult,
  V2PageQuery,
  V2PopularGroupsQuery,
  V2TransferGroupOwnershipData,
  V2UpdateGroupPayload,
  V2InviteResponseData,
  V2InviteCodeData,
  V2InviteResponsePayload
} from '@/types/v2';

export async function v2ListGroupAuditLogs(groupId: number, page: number, signal: AbortSignal) {
  return toV2PagedResult(await v2Request<V2GroupAuditEntry[], undefined, V2PageQuery>(
    `/api/v2/groups/${groupId}/audit-logs`,
    { method: 'GET', query: { page, page_size: 20 }, signal }
  ));
}

export async function v2ListGroups(
  query: V2GroupListQuery = {}
): Promise<V2PagedResult<V2Group>> {
  const response = await v2Request<
    V2Group[],
    undefined,
    V2GroupListQuery
  >('/api/v2/groups', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ListPopularGroups(
  query: V2PopularGroupsQuery = {}
): Promise<
  V2PagedResult<V2Group & { activity_score: number }>
> {
  const response = await v2Request<
    (V2Group & { activity_score: number })[],
    undefined,
    V2PopularGroupsQuery
  >('/api/v2/groups/popular', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ListMyGroups(
  query: V2GroupListQuery = {}
): Promise<V2PagedResult<V2Group>> {
  const response = await v2Request<
    V2Group[],
    undefined,
    V2GroupListQuery
  >('/api/v2/users/me/groups', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2CreateGroup(
  payload: V2CreateGroupPayload
): Promise<V2Group> {
  return await v2RequestData<V2Group, V2CreateGroupPayload>(
    '/api/v2/groups',
    {
      method: 'POST',
      body: payload
    }
  );
}

export async function v2GetGroupById(
  groupId: number
): Promise<V2Group> {
  const group = await v2RequestData<V2Group>(
    `/api/v2/groups/${groupId}`,
    {
      method: 'GET'
    }
  );
  if (!group || group.group_id !== groupId || !validGroupId(group.group_id)) {
    throw new Error('Invalid group detail response');
  }
  return group;
}

function validGroupId(id: number): boolean {
  return Number.isSafeInteger(id) && id > 0;
}

export async function v2GetGroupBySlug(slug: string): Promise<V2Group> {
  const group = await v2RequestData<V2Group>(
    `/api/v2/groups/by-slug/${encodeURIComponent(slug)}`,
    { method: 'GET' }
  );
  if (!group || !validGroupId(group.group_id) || group.slug !== slug) {
    throw new Error('Invalid group detail response');
  }
  return group;
}

export async function v2PatchGroup(
  groupId: number,
  payload: V2UpdateGroupPayload
): Promise<V2Group> {
  return await v2RequestData<
    V2Group,
    V2UpdateGroupPayload
  >(`/api/v2/groups/${groupId}`, {
    method: 'PATCH',
    body: payload
  });
}

export async function v2DeleteGroup(
  groupId: number
): Promise<void> {
  await v2RequestData<null>(`/api/v2/groups/${groupId}`, {
    method: 'DELETE'
  });
}

export async function v2GetGroupNotificationPreference(
  groupId: number
): Promise<V2GroupNotificationPreference> {
  return await v2RequestData<V2GroupNotificationPreference>(
    `/api/v2/groups/${groupId}/notification-preference`,
    {
      method: 'GET'
    }
  );
}

export async function v2PutGroupNotificationPreference(
  groupId: number,
  isEnabled: boolean
): Promise<V2GroupNotificationPreference> {
  return await v2RequestData<
    V2GroupNotificationPreference,
    { is_enabled: boolean }
  >(`/api/v2/groups/${groupId}/notification-preference`, {
    method: 'PUT',
    body: { is_enabled: isEnabled }
  });
}

export function v2GetInvitePreview(code: string): Promise<V2InviteCodeData> {
  return v2RequestData<V2InviteCodeData>(`/api/v2/groups/invite-codes/${encodeURIComponent(code)}`);
}

export async function v2JoinGroup(
  groupId: number,
  payload: V2JoinGroupPayload = {}
): Promise<V2JoinGroupData> {
  return await v2RequestData<
    V2JoinGroupData,
    V2JoinGroupPayload
  >(`/api/v2/groups/${groupId}/members/current`, {
    method: 'POST',
    body: payload
  });
}

export async function v2LeaveGroup(
  groupId: number
): Promise<void> {
  await v2RequestData<null>(
    `/api/v2/groups/${groupId}/members/current`,
    {
      method: 'DELETE'
    }
  );
}

export async function v2ListGroupMembers(
  groupId: number,
  query: V2GroupMemberListQuery = {},
  signal?: AbortSignal
): Promise<V2PagedResult<V2GroupMember>> {
  const response = await v2Request<
    V2GroupMember[],
    undefined,
    V2GroupMemberListQuery
  >(`/api/v2/groups/${groupId}/members`, {
    method: 'GET',
    query,
    signal
  });
  return toV2PagedResult(response);
}

export async function v2ApproveGroupMember(
  groupId: number,
  memberId: number,
  approved: boolean
): Promise<V2GroupMemberStatusData> {
  return await v2RequestData<
    V2GroupMemberStatusData,
    { approved: boolean }
  >(
    `/api/v2/groups/${groupId}/members/${memberId}/approval-status`,
    {
      method: 'PUT',
      body: { approved }
    }
  );
}

export async function v2RemoveGroupMember(
  groupId: number,
  userId: number
): Promise<void> {
  await v2RequestData<null>(
    `/api/v2/groups/${groupId}/members/${userId}`,
    {
      method: 'DELETE'
    }
  );
}

export async function v2ChangeGroupMemberRole(
  groupId: number,
  userId: number,
  role: 'admin' | 'moderator' | 'member'
): Promise<V2GroupMemberStatusData> {
  return await v2RequestData<
    V2GroupMemberStatusData,
    { role: 'admin' | 'moderator' | 'member' }
  >(
    `/api/v2/groups/${groupId}/members/${userId}/role`,
    {
      method: 'PATCH',
      body: { role }
    }
  );
}

export async function v2MuteGroupMember(
  groupId: number,
  userId: number,
  payload: {
    duration_hours: number;
    reason?: string | null;
  }
): Promise<V2GroupMemberStatusData> {
  return await v2RequestData<
    V2GroupMemberStatusData,
    {
      duration_hours: number;
      reason?: string | null;
    }
  >(
    `/api/v2/groups/${groupId}/members/${userId}/mute-status`,
    {
      method: 'PUT',
      body: payload
    }
  );
}

export async function v2UnmuteGroupMember(
  groupId: number,
  userId: number
): Promise<V2GroupMemberStatusData> {
  return await v2RequestData<V2GroupMemberStatusData>(
    `/api/v2/groups/${groupId}/members/${userId}/mute-status`,
    {
      method: 'DELETE'
    }
  );
}

export async function v2TransferGroupOwnership(
  groupId: number,
  newOwnerId: number
): Promise<V2TransferGroupOwnershipData> {
  return await v2RequestData<
    V2TransferGroupOwnershipData,
    { new_owner_id: number }
  >(`/api/v2/groups/${groupId}/ownership`, {
    method: 'PUT',
    body: { new_owner_id: newOwnerId }
  });
}

export async function v2ListGroupPosts(
  groupId: number,
  query: V2GroupPostListQuery = {}
): Promise<V2PagedResult<V2GroupPost>> {
  const response = await v2Request<
    V2GroupPost[],
    undefined,
    V2GroupPostListQuery
  >(`/api/v2/groups/${groupId}/posts`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export function v2GetGroupPost(groupId: number, postId: number): Promise<V2GroupPost> {
  return v2RequestData<V2GroupPost>(`/api/v2/groups/${groupId}/posts/${postId}`);
}

export async function v2CreateGroupPost(
  groupId: number,
  payload: V2CreateGroupPostPayload,
  signal?: AbortSignal
): Promise<V2GroupPost> {
  const post = await v2RequestData<
    V2GroupPost,
    V2CreateGroupPostPayload
  >(`/api/v2/groups/${groupId}/posts`, {
    method: 'POST',
    body: payload,
    signal
  });
  if (post?.group_id !== groupId || !Number.isSafeInteger(post.post_id) || post.post_id < 1 ||
      post.is_announcement !== (payload.is_announcement ?? false)) {
    throw new Error('Invalid group post receipt');
  }
  return post;
}

export async function v2DeleteGroupPost(
  groupId: number,
  postId: number,
  reason: string | null = null
): Promise<void> {
  await v2RequestData<null, { reason: string | null }>(
    `/api/v2/groups/${groupId}/posts/${postId}`,
    {
      method: 'DELETE',
      body: { reason }
    }
  );
}

export async function v2SetGroupPostPinStatus(
  groupId: number,
  postId: number,
  isPinned: boolean
): Promise<V2GroupPostPinStatusData> {
  const result = await v2RequestData<
    V2GroupPostPinStatusData,
    { is_pinned: boolean }
  >(`/api/v2/groups/${groupId}/posts/${postId}/pin-status`, {
    method: 'PUT',
    body: { is_pinned: isPinned }
  });
  if (result?.post_id !== postId || typeof result.is_pinned !== 'boolean') {
    throw new Error('Invalid group post pin receipt');
  }
  return result;
}

export async function v2SetGroupPostLikeStatus(
  groupId: number,
  postId: number,
  liked: boolean
): Promise<V2GroupPostLikeData> {
  const result = await v2RequestData<V2GroupPostLikeData>(
    `/api/v2/groups/${groupId}/posts/${postId}/likes`,
    {
      method: liked ? 'POST' : 'DELETE'
    }
  );
  if (result?.post_id !== postId || !validGroupReaction(result)) throw new Error('Invalid group post reaction receipt');
  return result;
}

function validGroupReaction(result: {is_liked: boolean; likes_count: number}) {
  return typeof result.is_liked === 'boolean' &&
    Number.isSafeInteger(result.likes_count) && result.likes_count >= 0;
}

export async function v2ListGroupPostComments(
  groupId: number,
  postId: number,
  query: V2PageQuery & {comment_id?: number; sort?: 'newest' | 'oldest' | 'popular'} = {}
): Promise<V2PagedResult<V2GroupComment>> {
  const response = await v2Request<
    V2GroupComment[],
    undefined,
    typeof query
  >(`/api/v2/groups/${groupId}/posts/${postId}/comments`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2CreateGroupPostComment(
  groupId: number,
  postId: number,
  payload: V2CreateGroupCommentPayload
): Promise<V2GroupComment> {
  return await v2RequestData<
    V2GroupComment,
    V2CreateGroupCommentPayload
  >(`/api/v2/groups/${groupId}/posts/${postId}/comments`, {
    method: 'POST',
    body: payload
  });
}

export async function v2DeleteGroupPostComment(
  groupId: number,
  postId: number,
  commentId: number
): Promise<void> {
  await v2RequestData<null>(
    `/api/v2/groups/${groupId}/posts/${postId}/comments/${commentId}`,
    {
      method: 'DELETE'
    }
  );
}

export async function v2SetGroupCommentLikeStatus(
  groupId: number,
  postId: number,
  commentId: number,
  liked: boolean
): Promise<V2GroupCommentLikeData> {
  const result = await v2RequestData<V2GroupCommentLikeData>(
    `/api/v2/groups/${groupId}/posts/${postId}/comments/${commentId}/likes`,
    {
      method: liked ? 'POST' : 'DELETE'
    }
  );
  if (result?.comment_id !== commentId || !validGroupReaction(result)) throw new Error('Invalid group comment reaction receipt');
  return result;
}

export async function v2CreateGroupInvite(
  groupId: number,
  payload: V2CreateGroupInvitePayload = {},
  signal?: AbortSignal
): Promise<V2CreateGroupInviteData> {
  return await v2RequestData<
    V2CreateGroupInviteData,
    V2CreateGroupInvitePayload
  >(`/api/v2/groups/${groupId}/invites`, {
    method: 'POST',
    body: payload,
    signal
  });
}

export async function v2ListGroupInvites(
  groupId: number,
  query: V2GroupInviteListQuery = {},
  signal?: AbortSignal
): Promise<V2PagedResult<V2GroupInvite>> {
  const response = await v2Request<
    V2GroupInvite[],
    undefined,
    V2GroupInviteListQuery
  >(`/api/v2/groups/${groupId}/invites`, {
    method: 'GET',
    query,
    signal
  });
  return toV2PagedResult(response);
}

export async function v2ListMyGroupInvites(
  query: V2MyGroupInviteListQuery = {},
  signal?: AbortSignal
): Promise<V2PagedResult<V2GroupInvite>> {
  const response = await v2Request<
    V2GroupInvite[],
    undefined,
    V2MyGroupInviteListQuery
  >('/api/v2/users/me/group-invites', {
    method: 'GET',
    query,
    signal
  });
  return toV2PagedResult(response);
}

export async function v2RespondGroupInvite(
  inviteId: number,
  payload: V2InviteResponsePayload,
  signal?: AbortSignal
): Promise<V2InviteResponseData> {
  return await v2RequestData<
    V2InviteResponseData,
    V2InviteResponsePayload
  >(`/api/v2/groups/invites/${inviteId}/responses`, {
    method: 'POST',
    body: payload,
    signal
  });
}

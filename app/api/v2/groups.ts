import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import type {
  V2CreateGroupInviteData,
  V2CreateGroupInvitePayload,
  V2CreateGroupPayload,
  V2Group,
  V2GroupInvite,
  V2GroupInviteListQuery,
  V2GroupListQuery,
  V2GroupMember,
  V2GroupMemberListQuery,
  V2GroupPost,
  V2GroupPostListQuery,
  V2JoinGroupData,
  V2JoinGroupPayload,
  V2PagedResult,
  V2PageQuery,
  V2PopularGroupsQuery,
  V2UpdateGroupPayload,
  V2InviteResponseData,
  V2InviteResponsePayload
} from '@/types/v2';

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
  query: V2PageQuery = {}
): Promise<V2PagedResult<V2Group>> {
  const response = await v2Request<
    V2Group[],
    undefined,
    V2PageQuery
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
  return await v2RequestData<V2Group>(
    `/api/v2/groups/${groupId}`,
    {
      method: 'GET'
    }
  );
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
  query: V2GroupMemberListQuery = {}
): Promise<V2PagedResult<V2GroupMember>> {
  const response = await v2Request<
    V2GroupMember[],
    undefined,
    V2GroupMemberListQuery
  >(`/api/v2/groups/${groupId}/members`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
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

export async function v2CreateGroupInvite(
  groupId: number,
  payload: V2CreateGroupInvitePayload = {}
): Promise<V2CreateGroupInviteData> {
  return await v2RequestData<
    V2CreateGroupInviteData,
    V2CreateGroupInvitePayload
  >(`/api/v2/groups/${groupId}/invites`, {
    method: 'POST',
    body: payload
  });
}

export async function v2ListGroupInvites(
  groupId: number,
  query: V2GroupInviteListQuery = {}
): Promise<V2PagedResult<V2GroupInvite>> {
  const response = await v2Request<
    V2GroupInvite[],
    undefined,
    V2GroupInviteListQuery
  >(`/api/v2/groups/${groupId}/invites`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2RespondGroupInvite(
  inviteId: number,
  payload: V2InviteResponsePayload
): Promise<V2InviteResponseData> {
  return await v2RequestData<
    V2InviteResponseData,
    V2InviteResponsePayload
  >(`/api/v2/groups/invites/${inviteId}/responses`, {
    method: 'POST',
    body: payload
  });
}

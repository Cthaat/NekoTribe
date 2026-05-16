import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2BoolNumber,
  v2Boolean,
  v2Count,
  v2DateString,
  v2Execute,
  v2JsonValue,
  v2NextId,
  v2NotFound,
  v2Null,
  v2Number,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryNumber,
  v2QueryString,
  v2RequiredNumber,
  v2RequiredString,
  v2Rows,
  v2String,
  v2StringArray,
  v2StringOrNull,
  v2Unprocessable,
  type V2DbRecord
} from '~/server/utils/v2';
import {
  v2MapGroup,
  v2MediaUrlArray,
  v2RequireGroup,
  v2RequirePublicUser
} from '~/server/models/v2';
import { v2CreateNotification } from './notifications';

function v2Slug(name: string, id: number): string {
  const base =
    name
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9\u4e00-\u9fa5]+/g, '-')
      .replace(/^-|-$/g, '') || 'group';
  return `${base}-${id}`;
}

function v2Privacy(value: string): string {
  if (['public', 'private', 'secret'].includes(value)) {
    return value;
  }
  v2BadRequest('privacy 参数错误');
}

function v2PostPermission(value: string): string {
  if (
    ['all', 'admin_only', 'moderator_up'].includes(value)
  ) {
    return value;
  }
  v2BadRequest('post_permission 参数错误');
}

function v2NormalizeInviteCode(code: string): string {
  return code.trim().toUpperCase();
}

async function v2GroupPermission(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  role: string
): Promise<boolean> {
  const row = await v2One(
    connection,
    'SELECT fn_has_group_permission(:user_id, :group_id, :role) AS allowed FROM dual',
    { user_id: userId, group_id: groupId, role }
  );
  return v2Boolean(row?.ALLOWED);
}

async function v2ValidGroupInvite(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  inviteCode: string
): Promise<V2DbRecord | null> {
  const code = v2NormalizeInviteCode(inviteCode);
  if (!code) return null;

  return await v2One(
    connection,
    `
    SELECT invite_id, inviter_id
    FROM n_group_invites
    WHERE group_id = :group_id
      AND invite_code = :invite_code
      AND status = 'pending'
      AND (invitee_id IS NULL OR invitee_id = :user_id)
      AND (max_uses IS NULL OR used_count < max_uses)
      AND (expires_at IS NULL OR expires_at >= SYSTIMESTAMP)
    FETCH FIRST 1 ROWS ONLY
    `,
    {
      group_id: groupId,
      invite_code: code,
      user_id: userId
    }
  );
}

async function v2GroupIdByInviteCode(
  connection: oracledb.Connection,
  userId: number,
  inviteCode: string
): Promise<number> {
  const code = v2NormalizeInviteCode(inviteCode);
  if (!code) v2BadRequest('code 参数错误');

  const row = await v2One(
    connection,
    `
    SELECT group_id
    FROM n_group_invites
    WHERE invite_code = :invite_code
      AND status = 'pending'
      AND (invitee_id IS NULL OR invitee_id = :user_id)
      AND (max_uses IS NULL OR used_count < max_uses)
      AND (expires_at IS NULL OR expires_at >= SYSTIMESTAMP)
    FETCH FIRST 1 ROWS ONLY
    `,
    {
      invite_code: code,
      user_id: userId
    }
  );
  if (!row) v2Unprocessable('邀请码无效或已过期');
  return v2Number(row.GROUP_ID);
}

export async function v2ListGroups(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Group[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const q = v2QueryString(event, 'q').trim().toLowerCase();
  const privacy = v2StringOrNull(
    v2QueryString(event, 'privacy')
  );
  const binds: Record<string, string | number | null> = {
    viewer_id: auth.userId,
    q: q ? `%${q}%` : null,
    privacy
  };
  const where = `
    WHERE is_deleted = 0
      AND is_active = 1
      AND (:privacy IS NULL OR privacy = :privacy)
      AND (:q IS NULL OR LOWER(group_name) LIKE :q OR LOWER(description) LIKE :q)
      AND (privacy = 'public' OR fn_can_view_group(:viewer_id, group_id) = 1)
  `;
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM v_group_details ${where}`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT g.*, ROW_NUMBER() OVER (
        ORDER BY member_count DESC, post_count DESC, created_at DESC
      ) AS rn
      FROM v_group_details g
      ${where}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  const groups = await Promise.all(
    rows.map(row =>
      v2MapGroup(connection, auth.userId, row)
    )
  );
  return v2Ok(
    groups,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2PopularGroups(
  event: H3Event,
  connection: oracledb.Connection
): Promise<
  V2Response<(V2Group & { activity_score: number })[]>
> {
  const auth = v2Auth(event);
  const limit = Math.min(
    v2QueryNumber(event, 'limit', 10),
    50
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM v_popular_groups
    ORDER BY activity_score DESC, member_count DESC
    FETCH FIRST :limit ROWS ONLY
    `,
    { limit }
  );
  const groups = await Promise.all(
    rows.map(async row => ({
      ...(await v2MapGroup(connection, auth.userId, row)),
      activity_score: v2Number(row.ACTIVITY_SCORE)
    }))
  );
  return v2Ok(groups, 'success', { limit });
}

export async function v2MyGroups(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Group[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_user_groups
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT gd.*
    FROM (
      SELECT group_id, ROW_NUMBER() OVER (ORDER BY joined_at DESC) AS rn
      FROM v_user_groups
      WHERE user_id = :user_id
    ) ug
    JOIN v_group_details gd ON gd.group_id = ug.group_id
    WHERE ug.rn BETWEEN :start_row AND :end_row
    `,
    {
      user_id: auth.userId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const groups = await Promise.all(
    rows.map(row =>
      v2MapGroup(connection, auth.userId, row)
    )
  );
  return v2Ok(
    groups,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateGroup(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Group>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2CreateGroupPayload = {
    name: v2RequiredString(body, 'name'),
    description: v2String(body.description),
    avatar_url: v2StringOrNull(body.avatar_url),
    cover_url: v2StringOrNull(body.cover_url),
    privacy: v2Privacy(
      v2String(body.privacy, 'public')
    ) as V2CreateGroupPayload['privacy'],
    join_approval: v2Boolean(body.join_approval),
    post_permission: v2PostPermission(
      v2String(body.post_permission, 'all')
    ) as V2CreateGroupPayload['post_permission']
  };
  const groupId = await v2NextId(
    connection,
    'seq_group_id'
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_groups (
      group_id,
      name,
      slug,
      description,
      avatar_url,
      cover_url,
      owner_id,
      privacy,
      join_approval,
      post_permission
    ) VALUES (
      :group_id,
      :name,
      :slug,
      :description,
      :avatar_url,
      :cover_url,
      :owner_id,
      :privacy,
      :join_approval,
      :post_permission
    )
    `,
    {
      group_id: groupId,
      name: payload.name,
      slug: v2Slug(payload.name, groupId),
      description: payload.description || null,
      avatar_url: payload.avatar_url,
      cover_url: payload.cover_url,
      owner_id: auth.userId,
      privacy: payload.privacy,
      join_approval: payload.join_approval ? 1 : 0,
      post_permission: payload.post_permission
    }
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_group_members (group_id, user_id, role, status)
    VALUES (:group_id, :user_id, 'owner', 'active')
    `,
    { group_id: groupId, user_id: auth.userId }
  );
  return v2Ok(
    await v2RequireGroup(connection, auth.userId, groupId),
    'group created'
  );
}

export async function v2GetGroupById(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2Group>> {
  return v2Ok(
    await v2RequireGroup(
      connection,
      v2Auth(event).userId,
      groupId
    )
  );
}

export async function v2GetGroupBySlug(
  event: H3Event,
  connection: oracledb.Connection,
  slug: string
): Promise<V2Response<V2Group>> {
  const auth = v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT *
    FROM v_group_details
    WHERE slug = :slug
      AND is_deleted = 0
    `,
    { slug }
  );
  if (!row) v2NotFound('群组不存在');
  return v2Ok(
    await v2MapGroup(connection, auth.userId, row)
  );
}

export async function v2PatchGroup(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2Group>> {
  const auth = v2Auth(event);
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'admin'
    ))
  ) {
    v2Unprocessable('无权修改群组');
  }
  const body = await v2Body(event);
  const clauses: string[] = [];
  const binds: Record<string, string | number | null> = {
    group_id: groupId
  };
  for (const key of [
    'name',
    'description',
    'avatar_url',
    'cover_url'
  ]) {
    if (Object.hasOwn(body, key)) {
      clauses.push(`${key} = :${key}`);
      binds[key] = v2StringOrNull(body[key]);
    }
  }
  if (Object.hasOwn(body, 'privacy')) {
    clauses.push('privacy = :privacy');
    binds.privacy = v2Privacy(v2String(body.privacy));
  }
  if (Object.hasOwn(body, 'join_approval')) {
    clauses.push('join_approval = :join_approval');
    binds.join_approval = v2BoolNumber(body.join_approval);
  }
  if (Object.hasOwn(body, 'post_permission')) {
    clauses.push('post_permission = :post_permission');
    binds.post_permission = v2PostPermission(
      v2String(body.post_permission)
    );
  }
  if (clauses.length > 0) {
    await v2Execute(
      connection,
      `
      UPDATE n_groups
      SET ${clauses.join(', ')},
          updated_at = SYSTIMESTAMP
      WHERE group_id = :group_id
      `,
      binds
    );
  }
  return v2Ok(
    await v2RequireGroup(connection, auth.userId, groupId),
    'group updated'
  );
}

export async function v2DeleteGroup(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const updated = await v2Execute(
    connection,
    `
    UPDATE n_groups
    SET is_deleted = 1,
        is_active = 0
    WHERE group_id = :group_id
      AND owner_id = :owner_id
      AND is_deleted = 0
    `,
    { group_id: groupId, owner_id: auth.userId }
  );
  if (updated === 0)
    v2Unprocessable('只有群主可以解散群组');
  return v2Null('group deleted');
}

type V2JoinGroupData = {
  member_id: number;
  group_id: number;
  user_id: number;
  role: string;
  status: string;
};

export async function v2JoinGroup(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2JoinGroupData>> {
  const body = await v2Body(event);
  const inviteCode =
    v2NormalizeInviteCode(
      v2StringOrNull(body.invite_code) || ''
    ) || null;
  return await v2JoinGroupWithInviteCode(
    event,
    connection,
    groupId,
    inviteCode
  );
}

export async function v2JoinGroupByInviteCode(
  event: H3Event,
  connection: oracledb.Connection,
  code: string
): Promise<V2Response<V2JoinGroupData>> {
  const auth = v2Auth(event);
  const inviteCode = v2NormalizeInviteCode(code);
  const groupId = await v2GroupIdByInviteCode(
    connection,
    auth.userId,
    inviteCode
  );
  return await v2JoinGroupWithInviteCode(
    event,
    connection,
    groupId,
    inviteCode
  );
}

async function v2JoinGroupWithInviteCode(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  inviteCode: string | null
): Promise<V2Response<V2JoinGroupData>> {
  const auth = v2Auth(event);
  const exists = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_group_members
    WHERE group_id = :group_id
      AND user_id = :user_id
    `,
    { group_id: groupId, user_id: auth.userId }
  );
  if (exists > 0) v2Unprocessable('您已经是群组成员');

  const group = await v2One(
    connection,
    `
    SELECT privacy, join_approval
    FROM n_groups
    WHERE group_id = :group_id
      AND is_deleted = 0
      AND is_active = 1
    `,
    { group_id: groupId }
  );
  if (!group) v2NotFound('群组不存在');

  const privacy = v2String(group.PRIVACY);
  const requiresApproval =
    privacy !== 'public' ||
    v2Number(group.JOIN_APPROVAL) === 1;
  let status = requiresApproval ? 'pending' : 'active';
  let invitedBy: number | null = null;
  let inviteId: number | null = null;

  if (inviteCode) {
    const invite = await v2ValidGroupInvite(
      connection,
      auth.userId,
      groupId,
      inviteCode
    );
    if (!invite) v2Unprocessable('邀请码无效或已过期');
    status = 'active';
    invitedBy = v2Number(invite.INVITER_ID);
    inviteId = v2Number(invite.INVITE_ID);
  } else if (privacy === 'secret') {
    v2Unprocessable('该群组仅限邀请加入');
  }

  const memberId = await v2NextId(
    connection,
    'seq_group_member_id'
  );
  const insertMemberSql = `
  INSERT INTO n_group_members (
    member_id,
    group_id,
    user_id,
    role,
    status,
    invited_by
  ) VALUES (
    :member_id,
    :group_id,
    :user_id,
    'member',
    :status,
    :invited_by
  )
  `;
  const insertMemberBinds = {
    member_id: memberId,
    group_id: groupId,
    user_id: auth.userId,
    status,
    invited_by: invitedBy
  };

  if (inviteId) {
    try {
      const updated = await v2Execute(
        connection,
        `
        UPDATE n_group_invites
        SET used_count = used_count + 1,
            status = CASE
              WHEN max_uses IS NOT NULL AND used_count + 1 >= max_uses THEN 'accepted'
              ELSE status
            END,
            responded_at = CASE
              WHEN max_uses IS NOT NULL AND used_count + 1 >= max_uses THEN SYSTIMESTAMP
              ELSE responded_at
            END
        WHERE invite_id = :invite_id
          AND status = 'pending'
          AND (max_uses IS NULL OR used_count < max_uses)
          AND (expires_at IS NULL OR expires_at >= SYSTIMESTAMP)
        `,
        { invite_id: inviteId },
        false
      );
      if (updated === 0)
        v2Unprocessable('邀请码无效或已过期');
      await v2Execute(
        connection,
        insertMemberSql,
        insertMemberBinds,
        false
      );
      await connection.commit();
    } catch (error) {
      await connection.rollback();
      throw error;
    }
  } else {
    await v2Execute(
      connection,
      insertMemberSql,
      insertMemberBinds
    );
  }

  return v2Ok(
    {
      member_id: memberId,
      group_id: groupId,
      user_id: auth.userId,
      role: 'member',
      status
    },
    status === 'active' ? 'joined' : 'pending approval'
  );
}

export async function v2LeaveGroup(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const role = await v2One(
    connection,
    `
    SELECT role
    FROM n_group_members
    WHERE group_id = :group_id
      AND user_id = :user_id
    `,
    { group_id: groupId, user_id: auth.userId }
  );
  if (!role) v2NotFound('成员不存在');
  if (v2String(role.ROLE) === 'owner') {
    v2Unprocessable('群主不能退出群组');
  }
  await v2Execute(
    connection,
    `
    DELETE FROM n_group_members
    WHERE group_id = :group_id
      AND user_id = :user_id
    `,
    { group_id: groupId, user_id: auth.userId }
  );
  return v2Null('left group');
}

export async function v2GroupMembers(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2GroupMember[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_group_member_details
    WHERE group_id = :group_id
    `,
    { group_id: groupId }
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT v.*, ROW_NUMBER() OVER (
        ORDER BY CASE role WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 WHEN 'moderator' THEN 3 ELSE 4 END,
                 joined_at ASC
      ) AS rn
      FROM v_group_member_details v
      WHERE group_id = :group_id
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      group_id: groupId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const members = await Promise.all(
    rows.map(async row => ({
      member_id: v2Number(row.MEMBER_ID),
      user: await v2RequirePublicUser(
        connection,
        auth.userId,
        v2Number(row.USER_ID)
      ),
      role: v2String(row.ROLE),
      role_desc: v2String(row.ROLE_DESC),
      status: v2String(row.STATUS),
      nickname: v2StringOrNull(row.NICKNAME),
      joined_at: v2DateString(row.JOINED_AT) || ''
    }))
  );
  return v2Ok(
    members,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2ApproveMember(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  memberId: number
): Promise<V2Response<V2GroupMemberStatusData>> {
  const auth = v2Auth(event);
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权审批成员');
  }
  const body = await v2Body(event);
  const approved = v2Boolean(body.approved);
  if (approved) {
    await v2Execute(
      connection,
      `
      UPDATE n_group_members
      SET status = 'active'
      WHERE member_id = :member_id
        AND group_id = :group_id
      `,
      { member_id: memberId, group_id: groupId }
    );
    return v2Ok(
      { member_id: memberId, status: 'active' },
      'member approved'
    );
  }
  await v2Execute(
    connection,
    `
    DELETE FROM n_group_members
    WHERE member_id = :member_id
      AND group_id = :group_id
    `,
    { member_id: memberId, group_id: groupId }
  );
  return v2Ok(
    { member_id: memberId, status: 'rejected' },
    'member rejected'
  );
}

export async function v2RemoveMember(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  userId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权移除成员');
  }
  await v2Execute(
    connection,
    `
    DELETE FROM n_group_members
    WHERE group_id = :group_id
      AND user_id = :user_id
      AND role != 'owner'
    `,
    { group_id: groupId, user_id: userId }
  );
  return v2Null('member removed');
}

export async function v2ChangeMemberRole(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  userId: number
): Promise<V2Response<V2GroupMemberStatusData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const role = v2RequiredString(body, 'role');
  if (!['admin', 'moderator', 'member'].includes(role)) {
    v2BadRequest('role 参数错误');
  }
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'admin'
    ))
  ) {
    v2Unprocessable('无权修改角色');
  }
  await v2Execute(
    connection,
    `
    UPDATE n_group_members
    SET role = :role
    WHERE group_id = :group_id
      AND user_id = :user_id
      AND role != 'owner'
    `,
    { role, group_id: groupId, user_id: userId }
  );
  return v2Ok({ user_id: userId, role }, 'role updated');
}

export async function v2MuteMember(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  userId: number
): Promise<V2Response<V2GroupMemberStatusData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const hours = Math.max(
    v2Number(body.duration_hours, 24),
    1
  );
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权禁言成员');
  }
  await v2Execute(
    connection,
    `
    UPDATE n_group_members
    SET status = 'muted',
        mute_until = SYSTIMESTAMP + NUMTODSINTERVAL(:hours, 'HOUR'),
        ban_reason = :reason
    WHERE group_id = :group_id
      AND user_id = :user_id
    `,
    {
      hours,
      reason: v2StringOrNull(body.reason),
      group_id: groupId,
      user_id: userId
    }
  );
  const row = await v2One(
    connection,
    `
    SELECT mute_until
    FROM n_group_members
    WHERE group_id = :group_id
      AND user_id = :user_id
    `,
    { group_id: groupId, user_id: userId }
  );
  return v2Ok(
    {
      user_id: userId,
      status: 'muted',
      mute_until: v2DateString(row?.MUTE_UNTIL)
    },
    'member muted'
  );
}

export async function v2UnmuteMember(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  userId: number
): Promise<V2Response<V2GroupMemberStatusData>> {
  const auth = v2Auth(event);
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权解除禁言');
  }
  await v2Execute(
    connection,
    `
    UPDATE n_group_members
    SET status = 'active',
        mute_until = NULL,
        ban_reason = NULL
    WHERE group_id = :group_id
      AND user_id = :user_id
    `,
    { group_id: groupId, user_id: userId }
  );
  return v2Ok(
    { user_id: userId, status: 'active' },
    'member unmuted'
  );
}

export async function v2TransferOwnership(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<
  V2Response<{ group_id: number; owner_id: number }>
> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const newOwnerId = v2RequiredNumber(
    body.new_owner_id,
    'new_owner_id'
  );
  const group = await v2One(
    connection,
    `
    SELECT owner_id
    FROM n_groups
    WHERE group_id = :group_id
    `,
    { group_id: groupId }
  );
  if (!group) v2NotFound('群组不存在');
  if (v2Number(group.OWNER_ID) !== auth.userId) {
    v2Unprocessable('只有群主可以转让群组');
  }
  await v2Execute(
    connection,
    `
    UPDATE n_group_members
    SET role = CASE
      WHEN user_id = :old_owner_id THEN 'admin'
      WHEN user_id = :new_owner_id THEN 'owner'
      ELSE role
    END
    WHERE group_id = :group_id
      AND user_id IN (:old_owner_id, :new_owner_id)
    `,
    {
      old_owner_id: auth.userId,
      new_owner_id: newOwnerId,
      group_id: groupId
    }
  );
  await v2Execute(
    connection,
    `
    UPDATE n_groups
    SET owner_id = :owner_id
    WHERE group_id = :group_id
    `,
    { owner_id: newOwnerId, group_id: groupId }
  );
  return v2Ok(
    { group_id: groupId, owner_id: newOwnerId },
    'ownership transferred'
  );
}

async function v2MapGroupPost(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2GroupPost> {
  const postId = v2Number(row.POST_ID);
  return {
    post_id: postId,
    group_id: v2Number(row.GROUP_ID),
    author: await v2RequirePublicUser(
      connection,
      viewerId,
      v2Number(row.AUTHOR_ID)
    ),
    content: v2String(row.CONTENT),
    media_urls: v2MediaUrlArray(row.MEDIA_URLS),
    is_pinned: v2Boolean(row.IS_PINNED),
    is_announcement: v2Boolean(row.IS_ANNOUNCEMENT),
    likes_count: v2Number(row.LIKES_COUNT),
    comments_count: v2Number(row.COMMENTS_COUNT),
    views_count: v2Number(row.VIEWS_COUNT),
    is_liked_by_me: v2Boolean(row.IS_LIKED_BY_ME),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2GroupPosts(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2GroupPost[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_group_timeline
    WHERE group_id = :group_id
    `,
    { group_id: groupId }
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        v.*,
        CASE WHEN EXISTS (
          SELECT 1 FROM n_group_post_likes l
          WHERE l.post_id = v.post_id AND l.user_id = :viewer_id
        ) THEN 1 ELSE 0 END AS is_liked_by_me,
        ROW_NUMBER() OVER (
          ORDER BY sort_weight DESC, created_at DESC
        ) AS rn
      FROM v_group_timeline v
      WHERE group_id = :group_id
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      viewer_id: auth.userId,
      group_id: groupId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const posts = await Promise.all(
    rows.map(row =>
      v2MapGroupPost(connection, auth.userId, row)
    )
  );
  return v2Ok(
    posts,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateGroupPost(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2GroupPost>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const content = v2RequiredString(body, 'content');
  const mediaUrls = v2StringArray(body.media_urls).join(
    ','
  );
  const allowed = await v2One(
    connection,
    'SELECT fn_can_post_in_group(:user_id, :group_id) AS allowed FROM dual',
    { user_id: auth.userId, group_id: groupId }
  );
  if (!v2Boolean(allowed?.ALLOWED))
    v2Unprocessable('无权发帖');
  const postId = await v2NextId(
    connection,
    'seq_group_post_id'
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_group_posts (
      post_id,
      group_id,
      author_id,
      content,
      media_urls
    ) VALUES (
      :post_id,
      :group_id,
      :author_id,
      :content,
      :media_urls
    )
    `,
    {
      post_id: postId,
      group_id: groupId,
      author_id: auth.userId,
      content,
      media_urls: mediaUrls || null
    }
  );
  return v2Ok(
    await v2RequireGroupPost(
      connection,
      auth.userId,
      groupId,
      postId
    ),
    'group post created'
  );
}

export async function v2RequireGroupPost(
  connection: oracledb.Connection,
  viewerId: number,
  groupId: number,
  postId: number
): Promise<V2GroupPost> {
  const row = await v2One(
    connection,
    `
    SELECT
      v.*,
      CASE WHEN EXISTS (
        SELECT 1 FROM n_group_post_likes l
        WHERE l.post_id = v.post_id AND l.user_id = :viewer_id
      ) THEN 1 ELSE 0 END AS is_liked_by_me
    FROM v_group_post_details v
    WHERE v.group_id = :group_id
      AND v.post_id = :post_id
      AND v.is_deleted = 0
    `,
    {
      viewer_id: viewerId,
      group_id: groupId,
      post_id: postId
    }
  );
  if (!row) v2NotFound('群组帖子不存在');
  return await v2MapGroupPost(connection, viewerId, row);
}

export async function v2GetGroupPost(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  postId: number
): Promise<V2Response<V2GroupPost>> {
  return v2Ok(
    await v2RequireGroupPost(
      connection,
      v2Auth(event).userId,
      groupId,
      postId
    )
  );
}

export async function v2DeleteGroupPost(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  postId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const post = await v2One(
    connection,
    `
    SELECT author_id
    FROM n_group_posts
    WHERE post_id = :post_id
      AND group_id = :group_id
      AND is_deleted = 0
    `,
    { post_id: postId, group_id: groupId }
  );
  if (!post) v2NotFound('群组帖子不存在');
  if (
    v2Number(post.AUTHOR_ID) !== auth.userId &&
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权删除帖子');
  }
  let body: Record<string, unknown> = {};
  try {
    body = await v2Body(event);
  } catch {
    body = {};
  }
  await v2Execute(
    connection,
    `
    UPDATE n_group_posts
    SET is_deleted = 1,
        deleted_by = :deleted_by,
        delete_reason = :reason
    WHERE post_id = :post_id
    `,
    {
      deleted_by: auth.userId,
      reason: v2StringOrNull(body.reason),
      post_id: postId
    }
  );
  return v2Null('group post deleted');
}

export async function v2SetGroupPostPin(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  postId: number
): Promise<
  V2Response<{ post_id: number; is_pinned: boolean }>
> {
  const auth = v2Auth(event);
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权置顶帖子');
  }
  const body = await v2Body(event);
  const isPinned = v2Boolean(body.is_pinned);
  await v2Execute(
    connection,
    `
    UPDATE n_group_posts
    SET is_pinned = :is_pinned
    WHERE post_id = :post_id
      AND group_id = :group_id
    `,
    {
      is_pinned: isPinned ? 1 : 0,
      post_id: postId,
      group_id: groupId
    }
  );
  return v2Ok(
    { post_id: postId, is_pinned: isPinned },
    'pin status updated'
  );
}

export async function v2LikeGroupPost(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number,
  liked: boolean
): Promise<
  V2Response<{
    post_id: number;
    is_liked: boolean;
    likes_count: number;
  }>
> {
  const auth = v2Auth(event);
  if (liked) {
    await v2Execute(
      connection,
      `
      INSERT INTO n_group_post_likes (post_id, user_id)
      SELECT :post_id, :user_id
      FROM dual
      WHERE NOT EXISTS (
        SELECT 1 FROM n_group_post_likes
        WHERE post_id = :post_id AND user_id = :user_id
      )
      `,
      { post_id: postId, user_id: auth.userId }
    );
  } else {
    await v2Execute(
      connection,
      `
      DELETE FROM n_group_post_likes
      WHERE post_id = :post_id
        AND user_id = :user_id
      `,
      { post_id: postId, user_id: auth.userId }
    );
  }
  const row = await v2One(
    connection,
    `
    SELECT likes_count
    FROM n_group_posts
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  return v2Ok({
    post_id: postId,
    is_liked: liked,
    likes_count: v2Number(row?.LIKES_COUNT)
  });
}

async function v2MapGroupComment(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2GroupComment> {
  const replyToId = v2Number(row.REPLY_TO_USER_ID);
  return {
    comment_id: v2Number(row.COMMENT_ID),
    post_id: v2Number(row.POST_ID),
    author: await v2RequirePublicUser(
      connection,
      viewerId,
      v2Number(row.AUTHOR_ID)
    ),
    parent_comment_id:
      row.PARENT_COMMENT_ID === null
        ? null
        : v2Number(row.PARENT_COMMENT_ID),
    reply_to_user: replyToId
      ? await v2RequirePublicUser(
          connection,
          viewerId,
          replyToId
        )
      : null,
    content: v2String(row.CONTENT),
    likes_count: v2Number(row.LIKES_COUNT),
    is_liked_by_me: v2Boolean(row.IS_LIKED_BY_ME),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2GroupComments(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2GroupComment[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_group_comment_details
    WHERE post_id = :post_id
      AND is_deleted = 0
    `,
    { post_id: postId }
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        v.*,
        CASE WHEN EXISTS (
          SELECT 1 FROM n_group_comment_likes l
          WHERE l.comment_id = v.comment_id AND l.user_id = :viewer_id
        ) THEN 1 ELSE 0 END AS is_liked_by_me,
        ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn
      FROM v_group_comment_details v
      WHERE post_id = :post_id
        AND is_deleted = 0
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      viewer_id: auth.userId,
      post_id: postId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const comments = await Promise.all(
    rows.map(row =>
      v2MapGroupComment(connection, auth.userId, row)
    )
  );
  return v2Ok(
    comments,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateGroupComment(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2GroupComment>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2CreateGroupCommentPayload = {
    content: v2RequiredString(body, 'content'),
    parent_comment_id:
      body.parent_comment_id === undefined ||
      body.parent_comment_id === null
        ? null
        : v2RequiredNumber(
            body.parent_comment_id,
            'parent_comment_id'
          ),
    reply_to_user_id:
      body.reply_to_user_id === undefined ||
      body.reply_to_user_id === null
        ? null
        : v2RequiredNumber(
            body.reply_to_user_id,
            'reply_to_user_id'
          )
  };
  const commentId = await v2NextId(
    connection,
    'seq_group_comment_id'
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_group_comments (
      comment_id,
      post_id,
      author_id,
      parent_comment_id,
      reply_to_user_id,
      content
    ) VALUES (
      :comment_id,
      :post_id,
      :author_id,
      :parent_comment_id,
      :reply_to_user_id,
      :content
    )
    `,
    {
      comment_id: commentId,
      post_id: postId,
      author_id: auth.userId,
      parent_comment_id: payload.parent_comment_id,
      reply_to_user_id: payload.reply_to_user_id,
      content: payload.content
    }
  );
  const row = await v2One(
    connection,
    `
    SELECT v.*, 0 AS is_liked_by_me
    FROM v_group_comment_details v
    WHERE comment_id = :comment_id
    `,
    { comment_id: commentId }
  );
  if (!row) v2NotFound('评论不存在');
  return v2Ok(
    await v2MapGroupComment(connection, auth.userId, row),
    'group comment created'
  );
}

export async function v2DeleteGroupComment(
  event: H3Event,
  connection: oracledb.Connection,
  commentId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const comment = await v2One(
    connection,
    `
    SELECT author_id, group_id
    FROM v_group_comment_details
    WHERE comment_id = :comment_id
      AND is_deleted = 0
    `,
    { comment_id: commentId }
  );
  if (!comment) v2NotFound('群组评论不存在');
  if (
    v2Number(comment.AUTHOR_ID) !== auth.userId &&
    !(await v2GroupPermission(
      connection,
      auth.userId,
      v2Number(comment.GROUP_ID),
      'moderator'
    ))
  ) {
    v2Unprocessable('无权删除评论');
  }
  await v2Execute(
    connection,
    `
    UPDATE n_group_comments
    SET is_deleted = 1,
        deleted_by = :deleted_by
    WHERE comment_id = :comment_id
    `,
    { deleted_by: auth.userId, comment_id: commentId }
  );
  return v2Null('group comment deleted');
}

export async function v2LikeGroupComment(
  event: H3Event,
  connection: oracledb.Connection,
  commentId: number,
  liked: boolean
): Promise<
  V2Response<{
    comment_id: number;
    is_liked: boolean;
    likes_count: number;
  }>
> {
  const auth = v2Auth(event);
  if (liked) {
    await v2Execute(
      connection,
      `
      INSERT INTO n_group_comment_likes (comment_id, user_id)
      SELECT :comment_id, :user_id
      FROM dual
      WHERE NOT EXISTS (
        SELECT 1 FROM n_group_comment_likes
        WHERE comment_id = :comment_id AND user_id = :user_id
      )
      `,
      { comment_id: commentId, user_id: auth.userId }
    );
  } else {
    await v2Execute(
      connection,
      `
      DELETE FROM n_group_comment_likes
      WHERE comment_id = :comment_id
        AND user_id = :user_id
      `,
      { comment_id: commentId, user_id: auth.userId }
    );
  }
  const row = await v2One(
    connection,
    `
    SELECT likes_count
    FROM n_group_comments
    WHERE comment_id = :comment_id
    `,
    { comment_id: commentId }
  );
  return v2Ok({
    comment_id: commentId,
    is_liked: liked,
    likes_count: v2Number(row?.LIKES_COUNT)
  });
}

function v2InviteCode(): string {
  return Math.random()
    .toString(36)
    .slice(2, 10)
    .toUpperCase();
}

async function v2GroupInviteNotificationNames(
  connection: oracledb.Connection,
  groupId: number,
  inviterId: number
): Promise<{ groupName: string; inviterName: string }> {
  const row = await v2One(
    connection,
    `
    SELECT
      g.name AS group_name,
      COALESCE(u.display_name, u.username) AS inviter_name
    FROM n_groups g
    JOIN n_users u ON u.user_id = :inviter_id
    WHERE g.group_id = :group_id
    `,
    {
      group_id: groupId,
      inviter_id: inviterId
    }
  );
  return {
    groupName: v2String(row?.GROUP_NAME, '群组'),
    inviterName: v2String(row?.INVITER_NAME, '有人')
  };
}

export async function v2CreateGroupInvite(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2CreateGroupInviteData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2CreateGroupInvitePayload = {
    invitee_id:
      body.invitee_id === undefined ||
      body.invitee_id === null
        ? null
        : v2RequiredNumber(body.invitee_id, 'invitee_id'),
    max_uses: v2Number(body.max_uses, 1),
    expire_hours: v2Number(body.expire_hours, 168),
    message: v2String(body.message)
  };
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'member'
    ))
  ) {
    v2Unprocessable('无权创建邀请');
  }
  const inviteId = await v2NextId(
    connection,
    'seq_group_invite_id'
  );
  const code = payload.invitee_id ? null : v2InviteCode();
  await v2Execute(
    connection,
    `
    INSERT INTO n_group_invites (
      invite_id,
      group_id,
      inviter_id,
      invitee_id,
      invite_code,
      max_uses,
      message,
      expires_at
    ) VALUES (
      :invite_id,
      :group_id,
      :inviter_id,
      :invitee_id,
      :invite_code,
      :max_uses,
      :message,
      SYSTIMESTAMP + NUMTODSINTERVAL(:expire_hours, 'HOUR')
    )
    `,
    {
      invite_id: inviteId,
      group_id: groupId,
      inviter_id: auth.userId,
      invitee_id: payload.invitee_id,
      invite_code: code,
      max_uses: payload.max_uses,
      message: payload.message || null,
      expire_hours: payload.expire_hours
    }
  );
  const row = await v2One(
    connection,
    `
    SELECT expires_at
    FROM n_group_invites
    WHERE invite_id = :invite_id
    `,
    { invite_id: inviteId }
  );
  if (payload.invitee_id) {
    const { groupName, inviterName } =
      await v2GroupInviteNotificationNames(
        connection,
        groupId,
        auth.userId
      );
    await v2CreateNotification(connection, {
      userId: payload.invitee_id,
      actorId: auth.userId,
      type: 'group_invite',
      title: `${inviterName} 邀请你加入 ${groupName}`,
      message: payload.message || '你收到了一条新的群组邀请。',
      resourceType: 'group_invite',
      resourceId: inviteId,
      priority: 'normal',
      metadata: {
        group_id: groupId,
        invite_id: inviteId,
        event: 'group_invite_created'
      }
    });
  }
  return v2Ok(
    {
      invite_id: inviteId,
      invite_code: code,
      invite_url: code ? `/groups/invite/${code}` : null,
      expires_at: v2DateString(row?.EXPIRES_AT)
    },
    'invite created'
  );
}

async function v2MapInvite(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2GroupInvite> {
  const inviteeId = v2Number(row.INVITEE_ID);
  return {
    invite_id: v2Number(row.INVITE_ID),
    invite_code: v2StringOrNull(row.INVITE_CODE),
    status: v2String(row.STATUS),
    max_uses:
      row.MAX_USES === null ? null : v2Number(row.MAX_USES),
    used_count: v2Number(row.USED_COUNT),
    expires_at: v2DateString(row.EXPIRES_AT),
    inviter: await v2RequirePublicUser(
      connection,
      viewerId,
      v2Number(row.INVITER_ID)
    ),
    invitee: inviteeId
      ? await v2RequirePublicUser(
          connection,
          viewerId,
          inviteeId
        )
      : null,
    is_valid: v2Boolean(row.IS_VALID)
  };
}

export async function v2GroupInvites(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2GroupInvite[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权查看群组邀请');
  }

  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_group_invite_details
    WHERE group_id = :group_id
    `,
    { group_id: groupId }
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT v.*, ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn
      FROM v_group_invite_details v
      WHERE group_id = :group_id
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      group_id: groupId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const invites = await Promise.all(
    rows.map(row =>
      v2MapInvite(connection, auth.userId, row)
    )
  );
  return v2Ok(
    invites,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2InviteCodeInfo(
  event: H3Event,
  connection: oracledb.Connection,
  code: string
): Promise<V2Response<V2InviteCodeData>> {
  const auth = v2Auth(event);
  const inviteCode = v2NormalizeInviteCode(code);
  if (!inviteCode) v2BadRequest('code 参数错误');

  const row = await v2One(
    connection,
    `
    SELECT *
    FROM v_group_invite_details
    WHERE invite_code = :invite_code
      AND (invitee_id IS NULL OR invitee_id = :user_id)
    `,
    {
      invite_code: inviteCode,
      user_id: auth.userId
    }
  );
  if (!row) v2NotFound('邀请码不存在');
  if (!v2Boolean(row.IS_VALID)) {
    v2Unprocessable('邀请码无效或已过期');
  }

  return v2Ok({
    is_valid: true,
    group: await v2RequireGroup(
      connection,
      auth.userId,
      v2Number(row.GROUP_ID)
    ),
    inviter: await v2RequirePublicUser(
      connection,
      auth.userId,
      v2Number(row.INVITER_ID)
    ),
    message: v2StringOrNull(row.MESSAGE)
  });
}

export async function v2RespondInvite(
  event: H3Event,
  connection: oracledb.Connection,
  inviteId: number
): Promise<V2Response<V2InviteResponseData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2InviteResponsePayload = {
    accept: v2Boolean(body.accept)
  };
  const invite = await v2One(
    connection,
    `
    SELECT
      i.invite_id,
      i.group_id,
      i.inviter_id,
      i.invitee_id,
      i.status,
      i.max_uses,
      i.used_count,
      i.expires_at,
      CASE
        WHEN i.status != 'pending' THEN 0
        WHEN i.max_uses IS NOT NULL AND i.used_count >= i.max_uses THEN 0
        WHEN i.expires_at IS NOT NULL AND i.expires_at < SYSTIMESTAMP THEN 0
        WHEN g.is_deleted = 1 OR g.is_active = 0 THEN 0
        ELSE 1
      END AS is_valid
    FROM n_group_invites i
    JOIN n_groups g ON i.group_id = g.group_id
    WHERE i.invite_id = :invite_id
    `,
    { invite_id: inviteId }
  );
  if (!invite) v2NotFound('邀请不存在');

  if (!v2Boolean(invite.IS_VALID)) {
    v2Unprocessable('邀请无效或已过期');
  }

  const inviteeId = v2Number(invite.INVITEE_ID);
  if (!inviteeId) {
    v2Unprocessable('公开邀请码请通过邀请码加入群组');
  }
  if (inviteeId && inviteeId !== auth.userId) {
    v2Unprocessable('无权响应该邀请');
  }

  const groupId = v2Number(invite.GROUP_ID);
  if (payload.accept) {
    const exists = await v2Count(
      connection,
      `
      SELECT COUNT(*) AS total
      FROM n_group_members
      WHERE group_id = :group_id
        AND user_id = :user_id
      `,
      { group_id: groupId, user_id: auth.userId }
    );
    if (exists > 0) v2Unprocessable('您已经是群组成员');
  }

  const status = payload.accept ? 'accepted' : 'rejected';

  if (!payload.accept) {
    await v2Execute(
      connection,
      `
      UPDATE n_group_invites
      SET status = 'rejected',
          responded_at = SYSTIMESTAMP
      WHERE invite_id = :invite_id
        AND status = 'pending'
      `,
      { invite_id: inviteId }
    );

    return v2Ok(
      {
        invite_id: inviteId,
        status,
        group_id: groupId
      },
      'invite rejected'
    );
  }

  try {
    const updated = await v2Execute(
      connection,
      `
      UPDATE n_group_invites
      SET used_count = used_count + 1,
          status = CASE
            WHEN invitee_id IS NOT NULL THEN 'accepted'
            WHEN max_uses IS NOT NULL AND used_count + 1 >= max_uses THEN 'accepted'
            ELSE status
          END,
          responded_at = CASE
            WHEN invitee_id IS NOT NULL
              OR (max_uses IS NOT NULL AND used_count + 1 >= max_uses)
            THEN SYSTIMESTAMP
            ELSE responded_at
          END
      WHERE invite_id = :invite_id
        AND status = 'pending'
        AND (max_uses IS NULL OR used_count < max_uses)
        AND (expires_at IS NULL OR expires_at >= SYSTIMESTAMP)
      `,
      { invite_id: inviteId },
      false
    );
    if (updated === 0) v2Unprocessable('邀请无效或已过期');

    const memberId = await v2NextId(
      connection,
      'seq_group_member_id'
    );
    await v2Execute(
      connection,
      `
      INSERT INTO n_group_members (
        member_id,
        group_id,
        user_id,
        role,
        status,
        invited_by
      ) VALUES (
        :member_id,
        :group_id,
        :user_id,
        'member',
        'active',
        :invited_by
      )
      `,
      {
        member_id: memberId,
        group_id: groupId,
        user_id: auth.userId,
        invited_by: v2Number(invite.INVITER_ID)
      },
      false
    );
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }

  return v2Ok(
    {
      invite_id: inviteId,
      status,
      group_id: groupId
    },
    'invite accepted'
  );
}

export async function v2AuditLogs(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2GroupAuditLog[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  if (
    !(await v2GroupPermission(
      connection,
      auth.userId,
      groupId,
      'moderator'
    ))
  ) {
    v2Unprocessable('无权查看审计日志');
  }
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_group_audit_log_details
    WHERE group_id = :group_id
    `,
    { group_id: groupId }
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT v.*, ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn
      FROM v_group_audit_log_details v
      WHERE group_id = :group_id
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      group_id: groupId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const logs = await Promise.all(
    rows.map(async row => ({
      log_id: v2Number(row.LOG_ID),
      group_id: v2Number(row.GROUP_ID),
      actor: await v2RequirePublicUser(
        connection,
        auth.userId,
        v2Number(row.ACTOR_ID)
      ),
      target_user: row.TARGET_USER_ID
        ? await v2RequirePublicUser(
            connection,
            auth.userId,
            v2Number(row.TARGET_USER_ID)
          )
        : null,
      target_post_id:
        row.TARGET_POST_ID === null
          ? null
          : v2Number(row.TARGET_POST_ID),
      target_comment_id:
        row.TARGET_COMMENT_ID === null
          ? null
          : v2Number(row.TARGET_COMMENT_ID),
      action: v2String(row.ACTION),
      details: v2JsonValue(row.DETAILS),
      ip_address: v2StringOrNull(row.IP_ADDRESS),
      created_at: v2DateString(row.CREATED_AT) || ''
    }))
  );
  return v2Ok(
    logs,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

import type { H3Event } from 'h3';
import type { File, Files } from 'formidable';
import formidable from 'formidable';
import type oracledb from 'oracledb';
import {
  deleteStorageReference,
  ensureStorageTempDir,
  STORAGE_AVATAR_MAX_SIZE,
  storeAvatarFile
} from '~/server/storage';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2BoolNumber,
  v2Boolean,
  v2Conflict,
  v2Count,
  v2DateString,
  v2Execute,
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
  v2StringOrNull,
  v2Unprocessable
} from '~/server/utils/v2';
import { v2VerifyOtpCode } from './auth';
import {
  v2MapPublicUser,
  v2RequirePublicUser,
  v2RequireSelfUser
} from '~/server/models/v2';

function v2FirstAvatarFile(files: Files<string>): File | null {
  return files.file?.[0] ?? files.avatar?.[0] ?? null;
}

export async function v2GetMe(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2SelfUser>> {
  return v2Ok(
    await v2RequireSelfUser(connection, v2Auth(event).userId)
  );
}

export async function v2PatchMe(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2SelfUser>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const clauses: string[] = [];
  const binds: Record<string, string | number | null> = {
    user_id: auth.userId
  };

  const textFields = [
    'display_name',
    'bio',
    'location',
    'website',
    'phone'
  ];
  for (const key of textFields) {
    if (Object.hasOwn(body, key)) {
      clauses.push(`${key} = :${key}`);
      binds[key] = v2String(body[key]);
    }
  }
  if (Object.hasOwn(body, 'birth_date')) {
    clauses.push(
      "birth_date = CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END"
    );
    binds.birth_date = v2StringOrNull(body.birth_date);
  }

  if (clauses.length > 0) {
    await v2Execute(
      connection,
      `
      UPDATE n_users
      SET ${clauses.join(', ')}
      WHERE user_id = :user_id
      `,
      binds
    );
  }

  return v2Ok(await v2RequireSelfUser(connection, auth.userId));
}

export async function v2UpdateAvatar(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2AvatarData>> {
  const auth = v2Auth(event);
  const currentAvatar = await v2One(
    connection,
    `
    SELECT
      avatar_url,
      avatar_media_id,
      (
        SELECT storage_key
        FROM n_media_assets
        WHERE media_id = u.avatar_media_id
      ) AS avatar_storage_key
    FROM n_users u
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  const tempDir = await ensureStorageTempDir();
  const form = formidable({
    multiples: false,
    uploadDir: tempDir,
    keepExtensions: true,
    maxFileSize: STORAGE_AVATAR_MAX_SIZE
  });

  try {
    return await new Promise<V2Response<V2AvatarData>>(
      (resolve, reject) => {
        form.parse(
          event.node.req,
          async (error: Error | null, _fields, files) => {
            let storedAvatar:
              | Awaited<ReturnType<typeof storeAvatarFile>>
              | null = null;
            try {
              if (error) {
                reject(error);
                return;
              }
              const file = v2FirstAvatarFile(files);
              if (!file) {
                reject(new Error('上传文件为空'));
                return;
              }

              storedAvatar = await storeAvatarFile(
                auth.userId,
                file
              );
              const mediaId = await v2NextId(
                connection,
                'seq_media_id'
              );

              await v2Execute(
                connection,
                `
                INSERT INTO n_media_assets (
                  media_id,
                  owner_user_id,
                  media_type,
                  file_name,
                  storage_key,
                  public_url,
                  file_size,
                  mime_type,
                  status
                ) VALUES (
                  :media_id,
                  :owner_user_id,
                  'image',
                  :file_name,
                  :storage_key,
                  :public_url,
                  :file_size,
                  :mime_type,
                  'ready'
                )
                `,
                {
                  media_id: mediaId,
                  owner_user_id: auth.userId,
                  file_name: storedAvatar.originalName,
                  storage_key: storedAvatar.key,
                  public_url: storedAvatar.url,
                  file_size: storedAvatar.size,
                  mime_type: storedAvatar.contentType
                },
                false
              );
              await v2Execute(
                connection,
                `
                UPDATE n_users
                SET avatar_url = :avatar_url,
                    avatar_media_id = :avatar_media_id
                WHERE user_id = :user_id
                `,
                {
                  avatar_url: storedAvatar.url,
                  avatar_media_id: mediaId,
                  user_id: auth.userId
                },
                false
              );

              const previousAvatarMediaId = v2Number(
                currentAvatar?.AVATAR_MEDIA_ID,
                0
              );
              if (previousAvatarMediaId > 0) {
                await v2Execute(
                  connection,
                  `
                  DELETE FROM n_media_assets
                  WHERE media_id = :media_id
                    AND owner_user_id = :user_id
                  `,
                  {
                    media_id: previousAvatarMediaId,
                    user_id: auth.userId
                  },
                  false
                );
              }

              await connection.commit();

              try {
                await deleteStorageReference({
                  storageKey:
                    currentAvatar?.AVATAR_STORAGE_KEY === null
                      ? null
                      : v2StringOrNull(
                          currentAvatar?.AVATAR_STORAGE_KEY
                        ),
                  publicUrl: v2StringOrNull(
                    currentAvatar?.AVATAR_URL
                  )
                });
              } catch (cleanupError) {
                console.error(
                  '清理旧头像文件失败:',
                  cleanupError
                );
              }

              resolve(
                v2Ok({
                  avatar_url: storedAvatar.url,
                  avatar_media_id: mediaId
                })
              );
            } catch (caught) {
              if (storedAvatar) {
                await connection.rollback().catch(
                  () => undefined
                );
                await deleteStorageReference({
                  storageKey: storedAvatar.key
                }).catch(cleanupError => {
                  console.error(
                    '清理新头像文件失败:',
                    cleanupError
                  );
                });
              } else {
                await connection.rollback().catch(
                  () => undefined
                );
              }
              reject(caught);
            }
          }
        );
      }
    );
  } catch (error) {
    v2BadRequest(
      error instanceof Error ? error.message : '头像上传失败'
    );
  }
}

export async function v2ChangeEmail(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2ChangeEmailData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2ChangeEmailPayload = {
    new_email: v2RequiredString(body, 'new_email'),
    verification_id: v2RequiredString(body, 'verification_id'),
    code: v2RequiredString(body, 'code')
  };

  const exists = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_users
    WHERE email = :email
      AND user_id != :user_id
    `,
    { email: payload.new_email, user_id: auth.userId }
  );
  if (exists > 0) v2Conflict('邮箱已被使用');

  await v2VerifyOtpCode(
    connection,
    payload.new_email,
    'change_email',
    payload.verification_id,
    payload.code
  );

  await v2Execute(
    connection,
    `
    UPDATE n_users
    SET email = :email,
        email_verified_at = CURRENT_TIMESTAMP
    WHERE user_id = :user_id
    `,
    { email: payload.new_email, user_id: auth.userId }
  );

  const row = await v2One(
    connection,
    `
    SELECT email, email_verified_at
    FROM n_users
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  if (!row) v2NotFound('用户不存在');
  return v2Ok({
    email: v2String(row.EMAIL),
    email_verified_at:
      v2DateString(row.EMAIL_VERIFIED_AT) || ''
  });
}

function v2MapSettings(row: Record<string, unknown>): V2UserSettings {
  return {
    user_id: v2Number(row.USER_ID),
    two_factor_enabled: v2Boolean(row.TWO_FACTOR_ENABLED),
    login_alerts: v2Boolean(row.LOGIN_ALERTS),
    profile_visibility: v2String(row.PROFILE_VISIBILITY),
    show_online_status: v2Boolean(row.SHOW_ONLINE_STATUS),
    allow_dm_from_strangers: v2Boolean(
      row.ALLOW_DM_FROM_STRANGERS
    ),
    push_notification_enabled: v2Boolean(
      row.PUSH_NOTIFICATION_ENABLED
    ),
    email_notification_enabled: v2Boolean(
      row.EMAIL_NOTIFICATION_ENABLED
    ),
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

async function v2EnsureSettings(
  connection: oracledb.Connection,
  userId: number
): Promise<void> {
  await v2Execute(
    connection,
    `
    MERGE INTO n_user_settings s
    USING (SELECT :user_id AS user_id FROM dual) src
    ON (s.user_id = src.user_id)
    WHEN NOT MATCHED THEN
      INSERT (user_id) VALUES (src.user_id)
    `,
    { user_id: userId }
  );
}

export async function v2GetSettings(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2UserSettings>> {
  const auth = v2Auth(event);
  await v2EnsureSettings(connection, auth.userId);
  const row = await v2One(
    connection,
    'SELECT * FROM n_user_settings WHERE user_id = :user_id',
    { user_id: auth.userId }
  );
  if (!row) v2NotFound('用户设置不存在');
  return v2Ok(v2MapSettings(row));
}

export async function v2PatchSettings(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2UserSettings>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  await v2EnsureSettings(connection, auth.userId);

  const fields = [
    'two_factor_enabled',
    'login_alerts',
    'show_online_status',
    'allow_dm_from_strangers',
    'push_notification_enabled',
    'email_notification_enabled'
  ];
  const clauses: string[] = [];
  const binds: Record<string, string | number> = {
    user_id: auth.userId
  };
  for (const key of fields) {
    if (Object.hasOwn(body, key)) {
      clauses.push(`${key} = :${key}`);
      binds[key] = v2BoolNumber(body[key]);
    }
  }
  if (Object.hasOwn(body, 'profile_visibility')) {
    const visibility = v2String(body.profile_visibility);
    if (!['public', 'private'].includes(visibility)) {
      v2BadRequest('profile_visibility 参数错误');
    }
    clauses.push('profile_visibility = :profile_visibility');
    binds.profile_visibility = visibility;
  }

  if (clauses.length > 0) {
    await v2Execute(
      connection,
      `
      UPDATE n_user_settings
      SET ${clauses.join(', ')},
          updated_at = CURRENT_TIMESTAMP
      WHERE user_id = :user_id
      `,
      binds
    );
  }
  return await v2GetSettings(event, connection);
}

function v2MapStatement(row: Record<string, unknown>): V2AccountStatement {
  return {
    statement_id: v2Number(row.STATEMENT_ID),
    type: v2String(row.STATEMENT_TYPE),
    title: v2String(row.TITLE),
    message: v2String(row.MESSAGE),
    policy_code: v2String(row.POLICY_CODE),
    status: v2String(row.STATUS),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2ListAccountStatements(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2AccountStatement[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const status = v2QueryString(event, 'status', 'all');
  const type = v2QueryString(event, 'type', 'all');
  const filters = ['user_id = :user_id'];
  const binds: Record<string, string | number> = {
    user_id: auth.userId
  };
  if (status && status !== 'all') {
    filters.push('status = :status');
    binds.status = status;
  }
  if (type && type !== 'all') {
    filters.push('statement_type = :statement_type');
    binds.statement_type = type;
  }
  const whereClause = filters.join('\n      AND ');
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_account_statements
    WHERE ${whereClause}
    `,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        statement_id,
        statement_type,
        title,
        message,
        policy_code,
        status,
        created_at,
        updated_at,
        ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn
      FROM n_account_statements
      WHERE ${whereClause}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  return v2Ok(
    rows.map(v2MapStatement),
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2PatchAccountStatement(
  event: H3Event,
  connection: oracledb.Connection,
  statementId: number
): Promise<V2Response<V2StatementStatusData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2UpdateStatementPayload = {
    action: v2RequiredString(
      body,
      'action'
    ) as V2UpdateStatementPayload['action']
  };
  const statusMap: Record<V2UpdateStatementPayload['action'], string> =
    {
      mark_read: 'read',
      mark_unread: 'unread',
      dismiss: 'dismissed',
      resolve: 'resolved'
    };
  const status = statusMap[payload.action];
  if (!status) v2BadRequest('action 参数错误');

  const updated = await v2Execute(
    connection,
    `
    UPDATE n_account_statements
    SET status = :status,
        updated_at = CURRENT_TIMESTAMP
    WHERE statement_id = :statement_id
      AND user_id = :user_id
    `,
    {
      status,
      statement_id: statementId,
      user_id: auth.userId
    }
  );
  if (updated === 0) v2NotFound('处置记录不存在');
  const row = await v2One(
    connection,
    `
    SELECT statement_id, status, updated_at
    FROM n_account_statements
    WHERE statement_id = :statement_id
    `,
    { statement_id: statementId }
  );
  if (!row) v2NotFound('处置记录不存在');
  return v2Ok({
    statement_id: v2Number(row.STATEMENT_ID),
    status: v2String(row.STATUS),
    updated_at: v2DateString(row.UPDATED_AT) || ''
  });
}

export async function v2CreateStatementAppeal(
  event: H3Event,
  connection: oracledb.Connection,
  statementId: number
): Promise<V2Response<V2StatementAppealData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2StatementAppealPayload = {
    appeal_message: v2RequiredString(body, 'appeal_message')
  };
  const statement = await v2One(
    connection,
    `
    SELECT statement_id
    FROM n_account_statements
    WHERE statement_id = :statement_id
      AND user_id = :user_id
    `,
    { statement_id: statementId, user_id: auth.userId }
  );
  if (!statement) v2NotFound('处置记录不存在');

  const appealId = await v2NextId(
    connection,
    'seq_statement_appeal_id'
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_statement_appeals (
      appeal_id,
      statement_id,
      user_id,
      appeal_message,
      appeal_status
    ) VALUES (
      :appeal_id,
      :statement_id,
      :user_id,
      :appeal_message,
      'pending'
    )
    `,
    {
      appeal_id: appealId,
      statement_id: statementId,
      user_id: auth.userId,
      appeal_message: payload.appeal_message
    }
  );
  await v2Execute(
    connection,
    `
    UPDATE n_account_statements
    SET status = 'appealed',
        updated_at = CURRENT_TIMESTAMP
    WHERE statement_id = :statement_id
    `,
    { statement_id: statementId }
  );

  return v2Ok({
    statement_id: statementId,
    status: 'appealed',
    appeal_id: appealId,
    appeal_status: 'pending'
  });
}

async function v2PublicUserPage(
  connection: oracledb.Connection,
  viewerId: number,
  sql: string,
  countSql: string,
  binds: Record<string, string | number | null>,
  page: ReturnType<typeof v2Page>
): Promise<V2Response<V2PublicUser[]>> {
  const total = await v2Count(connection, countSql, binds);
  const rows = await v2Rows(connection, sql, {
    ...binds,
    start_row: page.start,
    end_row: page.end
  });
  return v2Ok(
    rows.map(v2MapPublicUser),
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2SearchUsers(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2PublicUser[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const q = v2QueryString(event, 'q').trim();
  const verified = v2QueryString(event, 'verified');
  const binds: Record<string, string | number | null> = {
    viewer_id: auth.userId,
    q: `%${q.toLowerCase()}%`,
    verified: verified === 'true' ? 1 : null
  };
  const where = `
    WHERE is_active = 1
      AND (
        :q = '%%'
        OR LOWER(username) LIKE :q
        OR LOWER(display_name) LIKE :q
        OR LOWER(bio) LIKE :q
      )
      AND (:verified IS NULL OR is_verified = :verified)
  `;
  return await v2PublicUserPage(
    connection,
    auth.userId,
    `
    SELECT *
    FROM (
      SELECT
        user_id,
        username,
        avatar_url,
        display_name,
        bio,
        location,
        website,
        is_verified,
        followers_count,
        following_count,
        posts_count,
        likes_count,
        fn_get_user_relationship(:viewer_id, user_id) AS relation,
        ROW_NUMBER() OVER (
          ORDER BY followers_count DESC, created_at DESC
        ) AS rn
      FROM v_user_profile_public
      ${where}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    `
    SELECT COUNT(*) AS total
    FROM v_user_profile_public
    ${where}
    `,
    binds,
    page
  );
}

export async function v2RecommendedUsers(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2PublicUser[]>> {
  const auth = v2Auth(event);
  const limit = Math.min(v2QueryNumber(event, 'limit', 10), 50);
  const rows = await v2Rows(
    connection,
    `
    SELECT
      user_id,
      username,
      avatar_url,
      display_name,
      bio,
      location,
      website,
      is_verified,
      followers_count,
      following_count,
      posts_count,
      likes_count,
      fn_get_user_relationship(:viewer_id, user_id) AS relation
    FROM v_user_profile_public
    WHERE user_id != :viewer_id
      AND is_active = 1
      AND fn_get_user_relationship(:viewer_id, user_id) NOT IN ('following', 'mutual_follow', 'blocking', 'blocked_by')
    ORDER BY followers_count DESC, posts_count DESC, created_at DESC
    FETCH FIRST :limit ROWS ONLY
    `,
    { viewer_id: auth.userId, limit }
  );
  return v2Ok(rows.map(v2MapPublicUser), 'success', { limit });
}

export async function v2GetUserById(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number
): Promise<V2Response<V2PublicUser>> {
  const auth = v2Auth(event);
  return v2Ok(
    await v2RequirePublicUser(connection, auth.userId, userId)
  );
}

export async function v2GetUserAnalytics(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number
): Promise<V2Response<V2UserAnalytics>> {
  v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT
      a.user_id,
      a.posts_count AS total_posts,
      (
        SELECT COUNT(*)
        FROM n_posts
        WHERE author_id = :user_id
          AND is_deleted = 0
          AND created_at >= CURRENT_TIMESTAMP - INTERVAL '7' DAY
      ) AS posts_this_week,
      (
        SELECT COUNT(*)
        FROM n_posts
        WHERE author_id = :user_id
          AND is_deleted = 0
          AND created_at >= CURRENT_TIMESTAMP - INTERVAL '30' DAY
      ) AS posts_this_month,
      a.total_likes_received,
      a.avg_likes_per_post,
      (
        SELECT COUNT(*)
        FROM n_post_likes
        WHERE user_id = :user_id
      ) AS total_likes_given,
      (
        SELECT COUNT(*)
        FROM n_comments
        WHERE user_id = :user_id
          AND is_deleted = 0
      ) AS total_comments_made,
      a.avg_engagement_score AS engagement_score
    FROM v_user_analytics a
    WHERE a.user_id = :user_id
    `,
    { user_id: userId }
  );
  if (!row) v2NotFound('用户不存在');
  return v2Ok({
    user_id: v2Number(row.USER_ID),
    total_posts: v2Number(row.TOTAL_POSTS),
    posts_this_week: v2Number(row.POSTS_THIS_WEEK),
    posts_this_month: v2Number(row.POSTS_THIS_MONTH),
    total_likes_received: v2Number(
      row.TOTAL_LIKES_RECEIVED
    ),
    avg_likes_per_post: v2Number(row.AVG_LIKES_PER_POST),
    total_likes_given: v2Number(row.TOTAL_LIKES_GIVEN),
    total_comments_made: v2Number(row.TOTAL_COMMENTS_MADE),
    engagement_score: v2Number(row.ENGAGEMENT_SCORE)
  });
}

export async function v2FollowUser(
  event: H3Event,
  connection: oracledb.Connection,
  targetUserId: number
): Promise<
  V2Response<{
    target_user_id: number;
    relationship: string;
    followers_count: number;
  }>
> {
  const auth = v2Auth(event);
  if (auth.userId === targetUserId) v2Unprocessable('不能关注自己');
  await v2RequirePublicUser(connection, auth.userId, targetUserId);
  await v2Execute(
    connection,
    `
    MERGE INTO n_user_follows f
    USING (
      SELECT :follower_id AS follower_id,
             :following_id AS following_id
      FROM dual
    ) src
    ON (
      f.follower_id = src.follower_id
      AND f.following_id = src.following_id
    )
    WHEN MATCHED THEN
      UPDATE SET status = 'active', updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN
      INSERT (follower_id, following_id, status)
      VALUES (:follower_id, :following_id, 'active')
    `,
    {
      follower_id: auth.userId,
      following_id: targetUserId
    }
  );
  const stats = await v2One(
    connection,
    `
    SELECT followers_count
    FROM n_user_stats
    WHERE user_id = :user_id
    `,
    { user_id: targetUserId }
  );
  return v2Ok({
    target_user_id: targetUserId,
    relationship: 'following',
    followers_count: v2Number(stats?.FOLLOWERS_COUNT)
  });
}

export async function v2UnfollowUser(
  event: H3Event,
  connection: oracledb.Connection,
  targetUserId: number
): Promise<
  V2Response<{
    target_user_id: number;
    relationship: string;
    followers_count: number;
  }>
> {
  const auth = v2Auth(event);
  await v2Execute(
    connection,
    `
    UPDATE n_user_follows
    SET status = 'cancelled',
        updated_at = CURRENT_TIMESTAMP
    WHERE follower_id = :follower_id
      AND following_id = :following_id
      AND status = 'active'
    `,
    {
      follower_id: auth.userId,
      following_id: targetUserId
    }
  );
  const stats = await v2One(
    connection,
    `
    SELECT followers_count
    FROM n_user_stats
    WHERE user_id = :user_id
    `,
    { user_id: targetUserId }
  );
  return v2Ok({
    target_user_id: targetUserId,
    relationship: 'none',
    followers_count: v2Number(stats?.FOLLOWERS_COUNT)
  });
}

export async function v2BlockUser(
  event: H3Event,
  connection: oracledb.Connection,
  targetUserId: number
): Promise<
  V2Response<{ target_user_id: number; relationship: string }>
> {
  const auth = v2Auth(event);
  if (auth.userId === targetUserId) v2Unprocessable('不能屏蔽自己');
  await v2RequirePublicUser(connection, auth.userId, targetUserId);
  await v2Execute(
    connection,
    `
    MERGE INTO n_user_blocks b
    USING (
      SELECT :user_id AS user_id,
             :target_user_id AS target_user_id
      FROM dual
    ) src
    ON (
      b.user_id = src.user_id
      AND b.target_user_id = src.target_user_id
    )
    WHEN NOT MATCHED THEN
      INSERT (user_id, target_user_id)
      VALUES (:user_id, :target_user_id)
    `,
    { user_id: auth.userId, target_user_id: targetUserId }
  );
  await v2Execute(
    connection,
    `
    UPDATE n_user_follows
    SET status = 'cancelled',
        updated_at = CURRENT_TIMESTAMP
    WHERE (follower_id = :user_id AND following_id = :target_user_id)
       OR (follower_id = :target_user_id AND following_id = :user_id)
    `,
    { user_id: auth.userId, target_user_id: targetUserId }
  );
  return v2Ok({
    target_user_id: targetUserId,
    relationship: 'blocking'
  });
}

export async function v2UnblockUser(
  event: H3Event,
  connection: oracledb.Connection,
  targetUserId: number
): Promise<
  V2Response<{ target_user_id: number; relationship: string }>
> {
  const auth = v2Auth(event);
  await v2Execute(
    connection,
    `
    DELETE FROM n_user_blocks
    WHERE user_id = :user_id
      AND target_user_id = :target_user_id
    `,
    { user_id: auth.userId, target_user_id: targetUserId }
  );
  return v2Ok({
    target_user_id: targetUserId,
    relationship: 'none'
  });
}

export async function v2MuteUser(
  event: H3Event,
  connection: oracledb.Connection,
  targetUserId: number
): Promise<
  V2Response<{
    target_user_id: number;
    relationship: string;
    expires_at: string | null;
  }>
> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const expiresAt = v2StringOrNull(body.expires_at);
  const expiresDate = expiresAt ? new Date(expiresAt) : null;
  if (auth.userId === targetUserId) v2Unprocessable('不能静音自己');
  await v2RequirePublicUser(connection, auth.userId, targetUserId);
  await v2Execute(
    connection,
    `
    MERGE INTO n_user_mutes m
    USING (
      SELECT :user_id AS user_id,
             :target_user_id AS target_user_id
      FROM dual
    ) src
    ON (
      m.user_id = src.user_id
      AND m.target_user_id = src.target_user_id
    )
    WHEN MATCHED THEN
      UPDATE SET expires_at = :expires_at
    WHEN NOT MATCHED THEN
      INSERT (user_id, target_user_id, expires_at)
      VALUES (
        :user_id,
        :target_user_id,
        :expires_at
      )
    `,
    {
      user_id: auth.userId,
      target_user_id: targetUserId,
      expires_at: expiresDate
    }
  );
  return v2Ok({
    target_user_id: targetUserId,
    relationship: 'muted',
    expires_at: expiresAt
  });
}

export async function v2UnmuteUser(
  event: H3Event,
  connection: oracledb.Connection,
  targetUserId: number
): Promise<
  V2Response<{ target_user_id: number; relationship: string }>
> {
  const auth = v2Auth(event);
  await v2Execute(
    connection,
    `
    DELETE FROM n_user_mutes
    WHERE user_id = :user_id
      AND target_user_id = :target_user_id
    `,
    { user_id: auth.userId, target_user_id: targetUserId }
  );
  return v2Ok({
    target_user_id: targetUserId,
    relationship: 'none'
  });
}

export async function v2RelationshipList(
  event: H3Event,
  connection: oracledb.Connection,
  kind:
    | 'followers'
    | 'following'
    | 'mutual-following'
    | 'blocks'
    | 'mutes',
  targetUserId?: number
): Promise<V2Response<(V2PublicUser & { expires_at?: string | null })[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const target = targetUserId ?? auth.userId;
  let source = '';
  if (kind === 'followers') {
    source = `
      SELECT follower_id AS user_id, NULL AS expires_at
      FROM n_user_follows
      WHERE following_id = :target_user_id AND status = 'active'
    `;
  } else if (kind === 'following') {
    source = `
      SELECT following_id AS user_id, NULL AS expires_at
      FROM n_user_follows
      WHERE follower_id = :target_user_id AND status = 'active'
    `;
  } else if (kind === 'mutual-following') {
    source = `
      SELECT f1.following_id AS user_id, NULL AS expires_at
      FROM n_user_follows f1
      JOIN n_user_follows f2
        ON f2.follower_id = :viewer_id
       AND f2.following_id = f1.following_id
       AND f2.status = 'active'
      WHERE f1.follower_id = :target_user_id
        AND f1.status = 'active'
    `;
  } else if (kind === 'blocks') {
    source = `
      SELECT target_user_id AS user_id, NULL AS expires_at
      FROM n_user_blocks
      WHERE user_id = :viewer_id
    `;
  } else {
    source = `
      SELECT target_user_id AS user_id, expires_at
      FROM n_user_mutes
      WHERE user_id = :viewer_id
        AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
    `;
  }

  const binds = {
    viewer_id: auth.userId,
    target_user_id: target
  };
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM (${source})`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        u.user_id,
        u.username,
        u.avatar_url,
        u.display_name,
        u.bio,
        u.location,
        u.website,
        u.is_verified,
        u.followers_count,
        u.following_count,
        u.posts_count,
        u.likes_count,
        rel.expires_at,
        fn_get_user_relationship(:viewer_id, u.user_id) AS relation,
        ROW_NUMBER() OVER (ORDER BY u.followers_count DESC, u.created_at DESC) AS rn
      FROM (${source}) rel
      JOIN v_user_profile_public u ON u.user_id = rel.user_id
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );

  return v2Ok(
    rows.map(row => ({
      ...v2MapPublicUser(row),
      ...(kind === 'mutes'
        ? { expires_at: v2DateString(row.EXPIRES_AT) }
        : {})
    })),
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

import userDiscoverySql from '../../../specifications/requirements/user-discovery-sql.json';
import { requireFeatureSchema } from '~/server/database/readiness';
import { requireOtpAttempt } from '~/server/utils/otp-attempt-limit';
import { validNewEmail } from '../../../shared/utils/account-input';
import { setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import bcrypt from 'bcrypt';
import crypto from 'node:crypto';
import { parse as parseForm } from 'node:querystring';
import type oracledb from 'oracledb';
import { readBoundedBody } from '../../utils/bounded-body';
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
  v2NotFound,
  v2Null,
  v2Number,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryNumber,
  v2QueryString,
  v2Record,
  v2RequiredNumber,
  v2RequiredString,
  v2Rows,
  v2String,
  v2StringOrNull,
  v2ServerError,
  v2Unauthorized
} from '~/server/utils/v2';
import {
  v2ClearAuthCookies,
  v2VerifyUserPassword
} from './auth';
import { v2PublishUserPresence } from './presence';
import {
  v2MapPublicUser,
  v2RequirePublicUser,
  v2RequireSelfUser
} from '~/server/models/v2';

export async function v2GetMe(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2SelfUser>> {
  return v2Ok(
    await v2RequireSelfUser(
      connection,
      v2Auth(event).userId
    )
  );
}

export async function v2PatchMe(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2SelfUser>> {
  const auth = v2Auth(event);
  const request = event.node.req;
  const contentType = request.headers['content-type'] ?? '';
  const raw = await readBoundedBody(request, 1024 * 1024)
    .catch(() => v2BadRequest('请求体必须是 JSON 对象'));
  const text = raw.toString('utf8');
  let parsed: unknown;
  try {
    if (contentType.startsWith('application/x-www-form-urlencoded')) {
      parsed = parseForm(text, '&', '=', { maxKeys: 0 });
    } else if (!contentType.startsWith('text/')) {
      parsed = JSON.parse(text) as unknown;
    }
  } catch {
    v2BadRequest('请求体必须是 JSON 对象');
  }
  const body = v2Record(parsed);
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

  return v2Ok(
    await v2RequireSelfUser(connection, auth.userId)
  );
}

export async function v2DeleteMe(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2AccountDeletionData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const me = await v2RequireSelfUser(connection, auth.userId);
  const password = v2RequiredString(body, 'password');
  const confirmation = v2RequiredString(body, 'confirmation');

  if (
    confirmation !== me.username &&
    confirmation.toUpperCase() !== 'DELETE'
  ) {
    v2BadRequest('确认内容不匹配');
  }

  const oldHash = await v2VerifyUserPassword(connection, auth.userId, password);

  const anonymizedUsername = `deleted_${auth.userId}`;
  const anonymizedEmail = `deleted_${auth.userId}@deleted.local`;
  const disabledPasswordHash = await bcrypt.hash(
    crypto.randomBytes(32).toString('hex'),
    10
  );

  try {
    await v2Execute(
      connection,
      `
      UPDATE n_posts
      SET is_deleted = 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE author_id = :user_id
        AND is_deleted = 0
      `,
      { user_id: auth.userId }, false
    );
    await v2Execute(
      connection,
      `
      UPDATE n_comments
      SET is_deleted = 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE user_id = :user_id
        AND is_deleted = 0
      `,
      { user_id: auth.userId }, false
    );
    await v2Execute(
      connection,
      `
      UPDATE n_auth_sessions
      SET revoked_at = CURRENT_TIMESTAMP
      WHERE user_id = :user_id
        AND revoked_at IS NULL
      `,
      { user_id: auth.userId }, false
    );
    const changed = await v2Execute(
      connection,
      `
      UPDATE n_users
      SET email = :email,
          username = :username,
          password_hash = :password_hash,
          display_name = '已注销用户',
          bio = NULL,
          location = NULL,
          website = NULL,
          phone = NULL,
          avatar_url = NULL,
          avatar_media_id = NULL,
          is_active = 0,
          status = 'disabled',
          updated_at = CURRENT_TIMESTAMP
      WHERE user_id = :user_id
        AND password_hash = :old_hash AND is_active = 1 AND status = 'active'
      `,
      {
        user_id: auth.userId,
        email: anonymizedEmail,
        username: anonymizedUsername,
        password_hash: disabledPasswordHash,
        old_hash: oldHash
      }, false
    );
    if (changed === 0) v2Conflict('账号已变更，请重新验证');
    if (changed !== 1) v2ServerError();
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }

  v2ClearAuthCookies(event);
  try { await v2PublishUserPresence(connection, auth.userId); }
  catch { console.error('presence delivery unavailable'); }

  return v2Ok({
    deleted: true,
    user_id: auth.userId
  });
}

export async function v2ChangeEmail(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2ChangeEmailData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2ChangeEmailPayload = {
    new_email: v2RequiredString(body, 'new_email'),
    verification_id: v2RequiredString(
      body,
      'verification_id'
    ),
    code: v2RequiredString(body, 'code')
  };
  if (!validNewEmail(payload.new_email)) v2BadRequest('邮箱格式错误');

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

  const otp = await v2One(connection, `
    SELECT verification_code_hash FROM n_auth_otp_events
    WHERE account = :account AND otp_type = :otp_type
      AND verification_id = :verification_id AND expires_at > CURRENT_TIMESTAMP
    ORDER BY created_at DESC FETCH FIRST 1 ROWS ONLY
    `, {account: payload.new_email, otp_type: 'change_email', verification_id: payload.verification_id});
  if (!otp) v2BadRequest('验证码不存在或已过期');
  await requireOtpAttempt(event, payload.verification_id);
  const codeHash = v2String(otp.VERIFICATION_CODE_HASH);
  if (!await bcrypt.compare(payload.code, codeHash)) v2Unauthorized('验证码错误');

  try {
    const claimed = await v2Execute(connection, `
      UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP, expires_at = CURRENT_TIMESTAMP,
        verification_code_hash = '!consumed!'
      WHERE account = :account AND otp_type = 'change_email'
        AND verification_id = :verification_id AND verification_code_hash = :code_hash
        AND expires_at > CURRENT_TIMESTAMP
      `, {account: payload.new_email, verification_id: payload.verification_id, code_hash: codeHash}, false);
    if (claimed === 0) v2BadRequest('验证码不存在或已过期');
    if (claimed !== 1) v2ServerError();
    let updated: number;
    try {
      updated = await v2Execute(connection, `
        UPDATE n_users SET email = :email, email_verified_at = CURRENT_TIMESTAMP
        WHERE user_id = :user_id
        `, {email: payload.new_email, user_id: auth.userId}, false);
    } catch (error) {
      if (typeof error === 'object' && error !== null && 'errorNum' in error && error.errorNum === 1) {
        v2Conflict('邮箱已被使用');
      }
      throw error;
    }
    if (updated === 0) v2NotFound('用户不存在');
    if (updated !== 1) v2ServerError();
    const row = await v2One(connection, `
      SELECT email, TO_CHAR(FROM_TZ(email_verified_at, SESSIONTIMEZONE) AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS email_verified_at
      FROM n_users WHERE user_id = :user_id
      `, {user_id: auth.userId});
    const verifiedAt = v2DateString(row?.EMAIL_VERIFIED_AT);
    if (!row || v2String(row.EMAIL) !== payload.new_email || !verifiedAt) v2ServerError();
    const data = {email: payload.new_email, email_verified_at: verifiedAt};
    await connection.commit();
    return v2Ok(data);
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

function v2MapSettings(
  row: Record<string, unknown>
): V2UserSettings {
  const topK = v2Number(row.AI_SENTIMENT_TOP_K, 3);

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
    ai_sentiment_enabled: v2Boolean(
      row.AI_SENTIMENT_ENABLED
    ),
    ai_sentiment_model_id: v2StringOrNull(
      row.AI_SENTIMENT_MODEL_ID
    ),
    ai_sentiment_return_probabilities:
      row.AI_SENTIMENT_RETURN_PROBABILITIES === undefined ||
      row.AI_SENTIMENT_RETURN_PROBABILITIES === null
        ? true
        : v2Boolean(row.AI_SENTIMENT_RETURN_PROBABILITIES),
    ai_sentiment_include_metadata: v2Boolean(
      row.AI_SENTIMENT_INCLUDE_METADATA
    ),
    ai_sentiment_top_k:
      topK >= 1 && topK <= 10 ? Math.trunc(topK) : 3,
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

async function v2EnsureSettingsSchema(
  connection: oracledb.Connection
): Promise<void> {
  await requireFeatureSchema(connection, 'user-settings');
}

async function v2ApplySettings(
  connection: oracledb.Connection,
  userId: number,
  clauses: string[] = [],
  binds: Record<string, string | number | null> = { user_id: userId }
): Promise<V2UserSettings> {
  await v2EnsureSettingsSchema(connection);
  try {
    const users = await v2Rows(
      connection,
      'SELECT user_id FROM n_users WHERE user_id = :user_id FOR UPDATE',
      { user_id: userId }
    );
    if (users.length === 0) v2NotFound('用户不存在');
    if (users.length !== 1 || v2Number(users[0]?.USER_ID) !== userId) v2ServerError();
    await v2Execute(
      connection,
      `
      MERGE INTO n_user_settings s
      USING (SELECT :user_id AS user_id FROM dual) src
      ON (s.user_id = src.user_id)
      WHEN NOT MATCHED THEN
        INSERT (user_id) VALUES (src.user_id)
      `,
      { user_id: userId },
      false
    );
    if (clauses.length > 0) {
      await v2Execute(connection, `
        UPDATE n_user_settings
        SET ${clauses.join(', ')}, updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :user_id
      `, binds, false);
    }
    const rows = await v2Rows(connection,
      'SELECT * FROM n_user_settings WHERE user_id = :user_id',
      { user_id: userId });
    if (rows.length === 0) v2NotFound('用户设置不存在');
    const row = rows[0];
    if (rows.length !== 1 || !row || v2Number(row.USER_ID) !== userId) v2ServerError();
    const result = v2MapSettings(row);
    await connection.commit();
    return result;
  } catch (error) {
    // A failed commit can have an uncertain outcome; cleanup is best effort,
    // and the caller receives a fixed error rather than replaying the write.
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

export async function v2GetSettings(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2UserSettings>> {
  const auth = v2Auth(event);
  return v2Ok(await v2ApplySettings(connection, auth.userId));
}

export async function v2PatchSettings(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2UserSettings>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);

  if (Object.hasOwn(body, 'two_factor_enabled')) {
    v2BadRequest('请通过双因素认证设置流程修改 two_factor_enabled');
  }

  const fields = [
    'login_alerts',
    'show_online_status',
    'allow_dm_from_strangers',
    'push_notification_enabled',
    'email_notification_enabled',
    'ai_sentiment_enabled',
    'ai_sentiment_return_probabilities',
    'ai_sentiment_include_metadata'
  ];
  const clauses: string[] = [];
  const binds: Record<string, string | number | null> = {
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
    clauses.push(
      'profile_visibility = :profile_visibility'
    );
    binds.profile_visibility = visibility;
  }
  if (Object.hasOwn(body, 'ai_sentiment_model_id')) {
    const modelId = v2String(
      body.ai_sentiment_model_id
    ).trim();
    if (modelId.length > 128) {
      v2BadRequest('ai_sentiment_model_id 长度不能超过 128');
    }
    clauses.push(
      'ai_sentiment_model_id = :ai_sentiment_model_id'
    );
    binds.ai_sentiment_model_id =
      modelId.length > 0 ? modelId : null;
  }
  if (Object.hasOwn(body, 'ai_sentiment_top_k')) {
    const topK = Math.trunc(
      v2Number(body.ai_sentiment_top_k, 3)
    );
    if (topK < 1 || topK > 10) {
      v2BadRequest('ai_sentiment_top_k 必须在 1 到 10 之间');
    }
    clauses.push('ai_sentiment_top_k = :ai_sentiment_top_k');
    binds.ai_sentiment_top_k = topK;
  }

  const result = v2Ok(await v2ApplySettings(connection, auth.userId, clauses, binds));
  if (Object.hasOwn(body, 'show_online_status')) {
    await v2PublishUserPresence(connection, auth.userId);
  }
  return result;
}

export async function v2SearchUsers(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2PublicUser[]>> {
  const { userId } = v2Auth(event);
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const page = v2Page(event);
  const sort = v2QueryString(event, 'sort');
  const rows = await v2Rows(connection, userDiscoverySql.search, {
    viewer_id: userId,
    pattern: `%${v2QueryString(event, 'q').trim().toLowerCase()}%`,
    verified_only: v2QueryString(event, 'verified') === 'true' ? 1 : 0,
    sort_mode: sort === 'oldest' || sort === 'newest' ? sort : 'popular',
    start_row: page.start,
    end_row: page.end
  });
  const users = rows.filter(row => Number(row.USER_ID) > 0).map(v2MapPublicUser);
  return v2Ok(users, 'success', v2PageMeta(page.page, page.page_size, Number(rows[0]?.TOTAL ?? 0)));
}

export async function v2RecommendedUsers(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2PublicUser[]>> {
  const { userId } = v2Auth(event);
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const limit = Math.min(v2QueryNumber(event, 'limit', 10), 50);
  const rows = await v2Rows(connection, userDiscoverySql.recommendations, { viewer_id: userId, row_limit: limit });
  return v2Ok(rows.map(v2MapPublicUser), 'success', { limit });
}

export async function v2GetUserById(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number
): Promise<V2Response<V2PublicUser>> {
  const auth = v2Auth(event);
  return v2Ok(
    await v2RequirePublicUser(
      connection,
      auth.userId,
      userId
    )
  );
}

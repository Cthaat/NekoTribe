import type { H3Event } from 'h3';
import {
  deleteCookie,
  getCookie,
  getHeader,
  setCookie
} from 'h3';
import { useRuntimeConfig } from '#imports';
import bcrypt from 'bcrypt';
import crypto from 'crypto';
import jwt from 'jsonwebtoken';
import type { JwtPayload } from 'jsonwebtoken';
import nodemailer from 'nodemailer';
import type oracledb from 'oracledb';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2Conflict,
  v2DateString,
  v2Execute,
  v2Forbidden,
  v2NotFound,
  v2Null,
  v2Number,
  v2Ok,
  v2One,
  v2Page,
  v2RequestIp,
  v2RequiredString,
  v2Rows,
  v2String,
  v2StringOrNull,
  v2Unauthorized,
  v2Unprocessable,
  v2UserAgent
} from '~/server/utils/v2';
import { v2RequireSelfUser } from '~/server/models/v2';

const OTP_EXPIRES_SECONDS = 300;

interface V2MailOptions {
  to: string;
  subject: string;
  text: string;
  html: string;
}

async function v2SendMail(options: V2MailOptions): Promise<void> {
  const runtimeConfig = useRuntimeConfig();
  const transporter = nodemailer.createTransport({
    host: runtimeConfig.smtpHost,
    port: Number(runtimeConfig.smtpPort),
    secure: true,
    auth: {
      user: runtimeConfig.smtpUser,
      pass: runtimeConfig.smtpPass
    }
  });
  await transporter.sendMail({
    from: runtimeConfig.smtpUser,
    to: options.to,
    subject: options.subject,
    text: options.text,
    html: options.html
  });
}

function v2RandomCode(): string {
  return Array.from({ length: 6 })
    .map(() => Math.floor(Math.random() * 10))
    .join('');
}

function v2HashToken(token: string): string {
  return crypto
    .createHash('sha256')
    .update(token)
    .digest('hex');
}

function v2AccessExpiresSeconds(): number {
  return Number(useRuntimeConfig().accessExpiresIn) || 900;
}

function v2RefreshExpiresSeconds(): number {
  return (
    Number(useRuntimeConfig().refreshExpiresIn) ||
    30 * 24 * 60 * 60
  );
}

function v2CookieSecure(): boolean {
  return process.env.NODE_ENV === 'production';
}

function v2SetAuthCookies(
  event: H3Event,
  accessToken: string,
  refreshToken: string
): void {
  setCookie(event, 'access_token', accessToken, {
    httpOnly: true,
    secure: v2CookieSecure(),
    sameSite: 'lax',
    path: '/',
    maxAge: v2AccessExpiresSeconds()
  });
  setCookie(event, 'refresh_token', refreshToken, {
    httpOnly: true,
    secure: v2CookieSecure(),
    sameSite: 'lax',
    path: '/',
    maxAge: v2RefreshExpiresSeconds()
  });
}

function v2ClearAuthCookies(event: H3Event): void {
  deleteCookie(event, 'access_token', { path: '/' });
  deleteCookie(event, 'refresh_token', { path: '/' });
}

function v2IsAuthPayload(value: unknown): value is V2AuthPayload {
  if (!value || typeof value !== 'object') return false;
  const payload = value as Record<string, unknown>;
  return (
    typeof payload.userId === 'number' &&
    (payload.type === 'access' || payload.type === 'refresh')
  );
}

function v2SignAccessToken(
  payload: Omit<V2AuthPayload, 'type'>,
  accessJti: string
): string {
  return jwt.sign(
    {
      userId: payload.userId,
      userName: payload.userName,
      sessionId: payload.sessionId,
      type: 'access'
    },
    String(useRuntimeConfig().accessSecret),
    {
      expiresIn: v2AccessExpiresSeconds(),
      jwtid: accessJti
    }
  );
}

function v2SignRefreshToken(
  payload: Omit<V2AuthPayload, 'type'>
): string {
  return jwt.sign(
    {
      userId: payload.userId,
      userName: payload.userName,
      sessionId: payload.sessionId,
      type: 'refresh'
    },
    String(useRuntimeConfig().refreshSecret),
    {
      expiresIn: v2RefreshExpiresSeconds()
    }
  );
}

export function v2VerifyAccessToken(
  token: string
): V2AuthPayload | null {
  try {
    const decoded = jwt.verify(
      token,
      String(useRuntimeConfig().accessSecret)
    ) as JwtPayload;
    const payload = {
      userId: v2Number(decoded.userId),
      userName: v2String(decoded.userName),
      sessionId: v2String(decoded.sessionId),
      jti: v2String(decoded.jti),
      type: decoded.type
    };
    return v2IsAuthPayload(payload) ? payload : null;
  } catch {
    return null;
  }
}

function v2VerifyRefreshToken(
  token: string
): V2AuthPayload | null {
  try {
    const decoded = jwt.verify(
      token,
      String(useRuntimeConfig().refreshSecret)
    ) as JwtPayload;
    const payload = {
      userId: v2Number(decoded.userId),
      userName: v2String(decoded.userName),
      sessionId: v2String(decoded.sessionId),
      type: decoded.type
    };
    return v2IsAuthPayload(payload) ? payload : null;
  } catch {
    return null;
  }
}

function v2OtpType(value: string): V2AuthOtpPayload['type'] {
  if (
    value === 'register' ||
    value === 'password_reset' ||
    value === 'change_email'
  ) {
    return value;
  }
  v2BadRequest('type 参数错误');
}

function v2OtpChannel(
  value: string
): V2AuthOtpPayload['channel'] {
  if (value === 'email' || value === 'sms') return value;
  v2BadRequest('channel 参数错误');
}

async function v2ParseOtpPayload(
  event: H3Event
): Promise<V2AuthOtpPayload> {
  const body = await v2Body(event);
  return {
    account: v2RequiredString(body, 'account'),
    type: v2OtpType(v2RequiredString(body, 'type')),
    channel: v2OtpChannel(v2String(body.channel, 'email'))
  };
}

export async function v2CreateOtp(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2AuthOtpData>> {
  const payload = await v2ParseOtpPayload(event);
  const code = v2RandomCode();
  const verificationId = `otp_${crypto.randomUUID()}`;
  const expiresAt = new Date(
    Date.now() + OTP_EXPIRES_SECONDS * 1000
  );
  const otpId = await v2Number(
    (
      await v2One(
        connection,
        'SELECT seq_otp_event_id.NEXTVAL AS id FROM dual'
      )
    )?.ID
  );

  await v2Execute(
    connection,
    `
    INSERT INTO n_auth_otp_events (
      otp_event_id,
      account,
      otp_type,
      send_channel,
      verification_code_hash,
      verification_id,
      expires_at
    ) VALUES (
      :otp_event_id,
      :account,
      :otp_type,
      :send_channel,
      :verification_code_hash,
      :verification_id,
      :expires_at
    )
    `,
    {
      otp_event_id: otpId,
      account: payload.account,
      otp_type: payload.type,
      send_channel: payload.channel,
      verification_code_hash: await bcrypt.hash(code, 10),
      verification_id: verificationId,
      expires_at: expiresAt
    }
  );

  if (payload.channel === 'email') {
    await v2SendMail({
      to: payload.account,
      subject: 'Your verification code',
      text: `Your verification code is ${code}`,
      html: `<p>Your verification code is <strong>${code}</strong></p>`
    });
  }

  return v2Ok({
    account: payload.account,
    verification_id: verificationId,
    expires_at: expiresAt.toISOString()
  });
}

export async function v2VerifyOtpCode(
  connection: oracledb.Connection,
  account: string,
  type: V2AuthOtpPayload['type'],
  verificationId: string,
  code: string
): Promise<string> {
  const row = await v2One(
    connection,
    `
    SELECT verification_code_hash
    FROM n_auth_otp_events
    WHERE account = :account
      AND otp_type = :otp_type
      AND verification_id = :verification_id
      AND expires_at > CURRENT_TIMESTAMP
    ORDER BY created_at DESC
    FETCH FIRST 1 ROWS ONLY
    `,
    {
      account,
      otp_type: type,
      verification_id: verificationId
    }
  );

  if (!row) v2BadRequest('验证码不存在或已过期');
  const matched = await bcrypt.compare(
    code,
    v2String(row.VERIFICATION_CODE_HASH)
  );
  if (!matched) v2Unauthorized('验证码错误');

  await v2Execute(
    connection,
    `
    UPDATE n_auth_otp_events
    SET verified_at = CURRENT_TIMESTAMP
    WHERE verification_id = :verification_id
    `,
    { verification_id: verificationId }
  );

  const verified = await v2One(
    connection,
    `
    SELECT verified_at
    FROM n_auth_otp_events
    WHERE verification_id = :verification_id
    `,
    { verification_id: verificationId }
  );
  return v2DateString(verified?.VERIFIED_AT) || new Date().toISOString();
}

async function v2EnsureVerifiedOtp(
  connection: oracledb.Connection,
  account: string,
  type: V2AuthOtpPayload['type'],
  verificationId: string
): Promise<void> {
  const row = await v2One(
    connection,
    `
    SELECT verified_at
    FROM n_auth_otp_events
    WHERE account = :account
      AND otp_type = :otp_type
      AND verification_id = :verification_id
      AND expires_at > CURRENT_TIMESTAMP
      AND verified_at IS NOT NULL
    `,
    {
      account,
      otp_type: type,
      verification_id: verificationId
    }
  );
  if (!row) v2Unprocessable('请先完成验证码校验');
}

export async function v2VerifyOtp(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2AuthOtpVerificationData>> {
  const body = await v2Body(event);
  const account = v2RequiredString(body, 'account');
  const type = v2OtpType(v2RequiredString(body, 'type'));
  const verificationId = v2RequiredString(
    body,
    'verification_id'
  );
  const code = v2RequiredString(body, 'code');
  const verifiedAt = await v2VerifyOtpCode(
    connection,
    account,
    type,
    verificationId,
    code
  );

  return v2Ok({
    account,
    verified: true,
    verified_at: verifiedAt
  });
}

export async function v2Register(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<{ user: V2SelfUser }>> {
  const body = await v2Body(event);
  const payload: V2RegistrationPayload = {
    email: v2RequiredString(body, 'email'),
    username: v2RequiredString(body, 'username'),
    password: v2RequiredString(body, 'password'),
    confirm_password: v2RequiredString(body, 'confirm_password'),
    display_name: v2RequiredString(body, 'display_name'),
    bio: v2String(body.bio),
    location: v2String(body.location),
    phone: v2String(body.phone),
    birth_date: v2String(body.birth_date),
    verification_id: v2RequiredString(body, 'verification_id'),
    agree_to_terms: body.agree_to_terms === true
  };

  if (!payload.agree_to_terms) v2BadRequest('必须同意服务条款');
  if (payload.password !== payload.confirm_password) {
    v2BadRequest('两次输入的密码不一致');
  }
  await v2EnsureVerifiedOtp(
    connection,
    payload.email,
    'register',
    payload.verification_id
  );

  const exists = await v2One(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_users
    WHERE email = :email OR username = :username
    `,
    { email: payload.email, username: payload.username }
  );
  if (v2Number(exists?.TOTAL) > 0) {
    v2Conflict('邮箱或用户名已被注册');
  }

  const userId = v2Number(
    (
      await v2One(
        connection,
        'SELECT seq_user_id.NEXTVAL AS id FROM dual'
      )
    )?.ID
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_users (
      user_id,
      email,
      username,
      password_hash,
      display_name,
      bio,
      location,
      phone,
      birth_date,
      email_verified_at,
      status
    ) VALUES (
      :user_id,
      :email,
      :username,
      :password_hash,
      :display_name,
      :bio,
      :location,
      :phone,
      CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END,
      CURRENT_TIMESTAMP,
      'active'
    )
    `,
    {
      user_id: userId,
      email: payload.email,
      username: payload.username,
      password_hash: await bcrypt.hash(payload.password, 10),
      display_name: payload.display_name,
      bio: payload.bio || null,
      location: payload.location || null,
      phone: payload.phone || null,
      birth_date: payload.birth_date || null
    }
  );

  return v2Ok(
    {
      user: await v2RequireSelfUser(connection, userId)
    },
    'registration success'
  );
}

export async function v2Login(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2LoginData>> {
  const body = await v2Body(event);
  const payload: V2LoginPayload = {
    account: v2RequiredString(body, 'account'),
    password: v2RequiredString(body, 'password'),
    remember_me: body.remember_me === true
  };

  const row = await v2One(
    connection,
    `
    SELECT user_id, username, password_hash, status, is_active
    FROM n_users
    WHERE email = :account OR username = :account
    FETCH FIRST 1 ROWS ONLY
    `,
    { account: payload.account }
  );
  if (!row) v2Unauthorized('账号或密码错误');
  if (
    v2Number(row.IS_ACTIVE) !== 1 ||
    v2String(row.STATUS) !== 'active'
  ) {
    v2Forbidden('账号不可用');
  }

  const matched = await bcrypt.compare(
    payload.password,
    v2String(row.PASSWORD_HASH)
  );
  if (!matched) v2Unauthorized('账号或密码错误');

  const userId = v2Number(row.USER_ID);
  const username = v2String(row.USERNAME);
  const sessionId = `sess_${crypto.randomUUID()}`;
  const accessJti = crypto.randomUUID();
  const accessExpiresAt = new Date(
    Date.now() + v2AccessExpiresSeconds() * 1000
  );
  const refreshExpiresAt = new Date(
    Date.now() + v2RefreshExpiresSeconds() * 1000
  );
  const tokenPayload = {
    userId,
    userName: username,
    sessionId
  };
  const accessToken = v2SignAccessToken(tokenPayload, accessJti);
  const refreshToken = v2SignRefreshToken(tokenPayload);
  const deviceInfo = v2String(
    getHeader(event, 'x-device-info'),
    'unknown'
  );
  const deviceFingerprint = v2String(
    getHeader(event, 'x-device-fingerprint'),
    'unknown'
  );

  await v2Execute(
    connection,
    `
    INSERT INTO n_auth_sessions (
      session_id,
      user_id,
      access_jti,
      refresh_token_hash,
      device_info,
      device_fingerprint,
      ip_address,
      user_agent,
      access_token_expires_at,
      refresh_token_expires_at
    ) VALUES (
      :session_id,
      :user_id,
      :access_jti,
      :refresh_token_hash,
      :device_info,
      :device_fingerprint,
      :ip_address,
      :user_agent,
      :access_token_expires_at,
      :refresh_token_expires_at
    )
    `,
    {
      session_id: sessionId,
      user_id: userId,
      access_jti: accessJti,
      refresh_token_hash: v2HashToken(refreshToken),
      device_info: deviceInfo,
      device_fingerprint: deviceFingerprint,
      ip_address: v2RequestIp(event),
      user_agent: v2UserAgent(event),
      access_token_expires_at: accessExpiresAt,
      refresh_token_expires_at: refreshExpiresAt
    }
  );

  await v2Execute(
    connection,
    `
    UPDATE n_users
    SET last_login_at = CURRENT_TIMESTAMP
    WHERE user_id = :user_id
    `,
    { user_id: userId }
  );

  v2SetAuthCookies(event, accessToken, refreshToken);

  return v2Ok(
    {
      user: await v2RequireSelfUser(connection, userId),
      tokens: {
        session_id: sessionId,
        access_token_expires_at: accessExpiresAt.toISOString(),
        refresh_token_expires_at: refreshExpiresAt.toISOString()
      }
    },
    'login success'
  );
}

export async function v2RefreshCurrentToken(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2TokenData>> {
  const refreshToken = getCookie(event, 'refresh_token');
  if (!refreshToken) v2Unauthorized();
  const payload = v2VerifyRefreshToken(refreshToken);
  if (!payload?.sessionId) v2Unauthorized();

  const row = await v2One(
    connection,
    `
    SELECT session_id, user_id
    FROM n_auth_sessions
    WHERE session_id = :session_id
      AND user_id = :user_id
      AND refresh_token_hash = :refresh_token_hash
      AND revoked_at IS NULL
      AND refresh_token_expires_at > CURRENT_TIMESTAMP
    `,
    {
      session_id: payload.sessionId,
      user_id: payload.userId,
      refresh_token_hash: v2HashToken(refreshToken)
    }
  );
  if (!row) v2Unauthorized();

  const accessJti = crypto.randomUUID();
  const accessExpiresAt = new Date(
    Date.now() + v2AccessExpiresSeconds() * 1000
  );
  const refreshExpiresAt = new Date(
    Date.now() + v2RefreshExpiresSeconds() * 1000
  );
  const tokenPayload = {
    userId: payload.userId,
    userName: payload.userName,
    sessionId: payload.sessionId
  };
  const newAccessToken = v2SignAccessToken(
    tokenPayload,
    accessJti
  );
  const newRefreshToken = v2SignRefreshToken(tokenPayload);

  await v2Execute(
    connection,
    `
    UPDATE n_auth_sessions
    SET access_jti = :access_jti,
        refresh_token_hash = :refresh_token_hash,
        access_token_expires_at = :access_token_expires_at,
        refresh_token_expires_at = :refresh_token_expires_at,
        last_refresh_at = CURRENT_TIMESTAMP,
        last_accessed_at = CURRENT_TIMESTAMP
    WHERE session_id = :session_id
    `,
    {
      access_jti: accessJti,
      refresh_token_hash: v2HashToken(newRefreshToken),
      access_token_expires_at: accessExpiresAt,
      refresh_token_expires_at: refreshExpiresAt,
      session_id: payload.sessionId
    }
  );

  v2SetAuthCookies(event, newAccessToken, newRefreshToken);

  return v2Ok({
    session_id: payload.sessionId,
    access_token_expires_at: accessExpiresAt.toISOString(),
    refresh_token_expires_at: refreshExpiresAt.toISOString()
  });
}

export async function v2LogoutCurrent(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<null>> {
  const auth = (() => {
    try {
      return v2Auth(event);
    } catch {
      const refreshToken = getCookie(event, 'refresh_token');
      return refreshToken
        ? v2VerifyRefreshToken(refreshToken)
        : null;
    }
  })();

  if (auth?.sessionId) {
    await v2Execute(
      connection,
      `
      UPDATE n_auth_sessions
      SET revoked_at = CURRENT_TIMESTAMP
      WHERE session_id = :session_id
      `,
      { session_id: auth.sessionId }
    );
  }
  v2ClearAuthCookies(event);
  return v2Null('logout success');
}

export async function v2PasswordReset(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<null>> {
  const body = await v2Body(event);
  const payload: V2PasswordResetPayload = {
    email: v2RequiredString(body, 'email'),
    verification_id: v2RequiredString(body, 'verification_id'),
    code: v2RequiredString(body, 'code'),
    new_password: v2RequiredString(body, 'new_password')
  };
  await v2VerifyOtpCode(
    connection,
    payload.email,
    'password_reset',
    payload.verification_id,
    payload.code
  );
  const updated = await v2Execute(
    connection,
    `
    UPDATE n_users
    SET password_hash = :password_hash
    WHERE email = :email
    `,
    {
      password_hash: await bcrypt.hash(payload.new_password, 10),
      email: payload.email
    }
  );
  if (updated === 0) v2NotFound('用户不存在');
  return v2Null('password reset success');
}

export async function v2ListSessions(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2SessionItem[]>> {
  const auth = v2Auth(event);
  const pageState = v2Page(event);
  const page = pageState.page;
  const pageSize = pageState.page_size;
  const total = v2Number(
    (
      await v2One(
        connection,
        `
        SELECT COUNT(*) AS total
        FROM n_auth_sessions
        WHERE user_id = :user_id
          AND revoked_at IS NULL
        `,
        { user_id: auth.userId }
      )
    )?.TOTAL
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        session_id,
        device_info,
        ip_address,
        last_accessed_at,
        created_at,
        ROW_NUMBER() OVER (ORDER BY last_accessed_at DESC) AS rn
      FROM n_auth_sessions
      WHERE user_id = :user_id
        AND revoked_at IS NULL
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      user_id: auth.userId,
      start_row: pageState.start,
      end_row: pageState.end
    }
  );
  return v2Ok(
    rows.map(row => ({
      session_id: v2String(row.SESSION_ID),
      device_info: v2String(row.DEVICE_INFO),
      ip_address: v2String(row.IP_ADDRESS),
      last_accessed_at:
        v2DateString(row.LAST_ACCESSED_AT) || '',
      created_at: v2DateString(row.CREATED_AT) || '',
      is_current: v2String(row.SESSION_ID) === auth.sessionId
    })),
    'success',
    {
      page,
      page_size: pageSize,
      total,
      has_next: page * pageSize < total
    }
  );
}

export async function v2RevokeSession(
  event: H3Event,
  connection: oracledb.Connection,
  sessionId: string
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const updated = await v2Execute(
    connection,
    `
    UPDATE n_auth_sessions
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE session_id = :session_id
      AND user_id = :user_id
      AND revoked_at IS NULL
    `,
    { session_id: sessionId, user_id: auth.userId }
  );
  if (updated === 0) v2NotFound('会话不存在');
  if (sessionId === auth.sessionId) v2ClearAuthCookies(event);
  return v2Null('session revoked');
}

export async function v2RevokeOtherSessions(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<{ revoked_count: number }>> {
  const auth = v2Auth(event);
  const count = await v2Execute(
    connection,
    `
    UPDATE n_auth_sessions
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE user_id = :user_id
      AND session_id != :session_id
      AND revoked_at IS NULL
    `,
    {
      user_id: auth.userId,
      session_id: auth.sessionId || ''
    }
  );
  return v2Ok({ revoked_count: count }, 'other sessions revoked');
}

export function v2CurrentRefreshToken(event: H3Event): string | null {
  return getCookie(event, 'refresh_token') ?? null;
}

export function v2SessionIdFromRefresh(
  refreshToken: string
): string | null {
  return v2VerifyRefreshToken(refreshToken)?.sessionId ?? null;
}

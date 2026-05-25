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
  v2Boolean,
  v2Conflict,
  v2Count,
  v2DateString,
  v2Execute,
  v2Forbidden,
  v2NextId,
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
import {
  buildV2TokenData,
  resolveV2RefreshToken
} from '~/server/utils/auth-token-response';
import { v2RequireSelfUser } from '~/server/models/v2';
import { v2CreateNotification } from './notifications';

const OTP_EXPIRES_SECONDS = 300;
const TWO_FACTOR_CHALLENGE_EXPIRES_SECONDS = 300;
const TOTP_PERIOD_SECONDS = 30;
const TOTP_DIGITS = 6;
const TOTP_ALLOWED_DRIFT_STEPS = 1;
const TWO_FACTOR_TRUSTED_DEVICE_DAYS = 30;
const BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

interface V2MailOptions {
  to: string;
  subject: string;
  text: string;
  html: string;
}

async function v2SendMail(
  options: V2MailOptions
): Promise<void> {
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

function v2EscapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

async function v2SendLoginAlert(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number,
  sessionId: string,
  deviceInfo: string,
  deviceFingerprint: string,
  isNewDevice: boolean
): Promise<void> {
  if (!isNewDevice) return;

  const row = await v2One(
    connection,
    `
    SELECT
      u.email,
      NVL(us.login_alerts, 1) AS login_alerts,
      NVL(us.email_notification_enabled, 1) AS email_notification_enabled
    FROM n_users u
    LEFT JOIN n_user_settings us ON us.user_id = u.user_id
    WHERE u.user_id = :user_id
    `,
    { user_id: userId }
  );
  if (!v2Boolean(row?.LOGIN_ALERTS ?? 1)) return;

  const ipAddress = v2RequestIp(event);
  const userAgent = v2UserAgent(event);
  const title = '新设备登录提醒';
  const message = `你的账号刚刚通过新设备登录：${deviceInfo || 'unknown'}`;

  await v2CreateNotification(connection, {
    userId,
    actorId: null,
    type: 'login_alert',
    title,
    message,
    resourceType: 'auth_session',
    resourceId: null,
    priority: 'high',
    metadata: {
      session_id: sessionId,
      device_info: deviceInfo,
      device_fingerprint: deviceFingerprint,
      ip_address: ipAddress,
      user_agent: userAgent
    }
  });

  if (!v2Boolean(row?.EMAIL_NOTIFICATION_ENABLED ?? 1)) {
    return;
  }

  const email = v2String(row?.EMAIL);
  if (!email) return;

  await v2SendMail({
    to: email,
    subject: title,
    text: `${message}\nIP: ${ipAddress}\nUser-Agent: ${userAgent}`,
    html: `
      <p>${v2EscapeHtml(message)}</p>
      <p><strong>IP:</strong> ${v2EscapeHtml(ipAddress)}</p>
      <p><strong>User-Agent:</strong> ${v2EscapeHtml(userAgent)}</p>
      <p>如果这不是你本人操作，请尽快修改密码并注销其他设备。</p>
    `
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

function v2Base32Encode(bytes: Buffer): string {
  let bits = 0;
  let value = 0;
  let output = '';

  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }

  if (bits > 0) {
    output += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  }

  return output;
}

function v2Base32Decode(secret: string): Buffer {
  const normalized = secret
    .replace(/=+$/u, '')
    .replace(/\s+/gu, '')
    .toUpperCase();
  let bits = 0;
  let value = 0;
  const bytes: number[] = [];

  for (const char of normalized) {
    const index = BASE32_ALPHABET.indexOf(char);
    if (index < 0) v2BadRequest('双因素密钥格式错误');
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }

  return Buffer.from(bytes);
}

function v2TimingSafeEqualText(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  if (leftBuffer.length !== rightBuffer.length) return false;
  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function v2TotpCode(secret: string, step: number): string {
  const counter = Math.max(0, Math.trunc(step));
  const counterBuffer = Buffer.alloc(8);
  counterBuffer.writeUInt32BE(Math.floor(counter / 0x100000000), 0);
  counterBuffer.writeUInt32BE(counter >>> 0, 4);

  const digest = crypto
    .createHmac('sha1', v2Base32Decode(secret))
    .update(counterBuffer)
    .digest();
  const offset = digest[digest.length - 1]! & 0x0f;
  const binary =
    ((digest[offset]! & 0x7f) << 24) |
    ((digest[offset + 1]! & 0xff) << 16) |
    ((digest[offset + 2]! & 0xff) << 8) |
    (digest[offset + 3]! & 0xff);

  return String(binary % 10 ** TOTP_DIGITS).padStart(
    TOTP_DIGITS,
    '0'
  );
}

function v2VerifyTotpCode(secret: string, code: string): boolean {
  if (!/^\d{6}$/u.test(code)) return false;
  const currentStep = Math.floor(
    Date.now() / 1000 / TOTP_PERIOD_SECONDS
  );
  for (
    let offset = -TOTP_ALLOWED_DRIFT_STEPS;
    offset <= TOTP_ALLOWED_DRIFT_STEPS;
    offset += 1
  ) {
    if (
      v2TimingSafeEqualText(
        v2TotpCode(secret, currentStep + offset),
        code
      )
    ) {
      return true;
    }
  }
  return false;
}

function v2NormalizeTwoFactorCode(value: unknown): string {
  return v2String(value)
    .trim()
    .replace(/[\s-]+/gu, '')
    .toUpperCase();
}

function v2RecoveryCodeCandidates(value: unknown): string[] {
  const trimmed = v2String(value).trim();
  const normalized = v2NormalizeTwoFactorCode(trimmed);
  return Array.from(
    new Set(
      [normalized, trimmed, trimmed.toUpperCase()].filter(Boolean)
    )
  );
}

function v2TwoFactorEncryptionKey(): Buffer {
  const runtimeConfig = useRuntimeConfig();
  const keyMaterial = String(
    runtimeConfig.refreshSecret ||
      runtimeConfig.accessSecret ||
      'nekotribe-local-two-factor-key'
  );
  return crypto.createHash('sha256').update(keyMaterial).digest();
}

function v2EncryptTwoFactorSecret(secret: string): {
  encrypted: string;
  iv: string;
  tag: string;
} {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv(
    'aes-256-gcm',
    v2TwoFactorEncryptionKey(),
    iv
  );
  const encrypted = Buffer.concat([
    cipher.update(secret, 'utf8'),
    cipher.final()
  ]);
  return {
    encrypted: encrypted.toString('base64'),
    iv: iv.toString('base64'),
    tag: cipher.getAuthTag().toString('base64')
  };
}

function v2DecryptTwoFactorSecret(row: Record<string, unknown>): string {
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    v2TwoFactorEncryptionKey(),
    Buffer.from(v2String(row.SECRET_IV), 'base64')
  );
  decipher.setAuthTag(
    Buffer.from(v2String(row.SECRET_AUTH_TAG), 'base64')
  );
  return Buffer.concat([
    decipher.update(
      Buffer.from(v2String(row.SECRET_ENCRYPTED), 'base64')
    ),
    decipher.final()
  ]).toString('utf8');
}

function v2TwoFactorUri(account: string, secret: string): string {
  const issuer = 'NekoTribe';
  const label = encodeURIComponent(`${issuer}:${account}`);
  const params = new URLSearchParams({
    secret,
    issuer,
    algorithm: 'SHA1',
    digits: String(TOTP_DIGITS),
    period: String(TOTP_PERIOD_SECONDS)
  });
  return `otpauth://totp/${label}?${params.toString()}`;
}

function v2RandomRecoveryCode(): string {
  const token = v2Base32Encode(crypto.randomBytes(10));
  return `${token.slice(0, 5)}-${token.slice(5, 10)}-${token.slice(10, 15)}`;
}

function v2IsObjectAlreadyExistsError(error: unknown): boolean {
  return (
    error instanceof Error &&
    /ORA-00955|name is already used/i.test(error.message)
  );
}

let twoFactorSchemaReady = false;

async function v2EnsureTwoFactorSchema(
  connection: oracledb.Connection
): Promise<void> {
  if (twoFactorSchemaReady) return;

  const statements = [
    `
    CREATE SEQUENCE seq_2fa_recovery_code_id
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE
    `,
    `
    CREATE SEQUENCE seq_2fa_trusted_device_id
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE
    `,
    `
    CREATE TABLE n_user_two_factor_secrets (
      user_id            NUMBER(10) PRIMARY KEY,
      secret_encrypted   VARCHAR2(512) NOT NULL,
      secret_iv          VARCHAR2(64) NOT NULL,
      secret_auth_tag    VARCHAR2(64) NOT NULL,
      confirmed_at       TIMESTAMP,
      enabled_at         TIMESTAMP,
      created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      updated_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT fk_2fa_secret_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
    )
    `,
    `
    CREATE TABLE n_user_two_factor_recovery_codes (
      recovery_code_id   NUMBER(15) PRIMARY KEY,
      user_id            NUMBER(10) NOT NULL,
      code_hash          VARCHAR2(255) NOT NULL,
      used_at            TIMESTAMP,
      created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT fk_2fa_recovery_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
    )
    `,
    `
    CREATE TABLE n_user_two_factor_trusted_devices (
      trusted_device_id  NUMBER(15) PRIMARY KEY,
      user_id            NUMBER(10) NOT NULL,
      device_fingerprint VARCHAR2(200) NOT NULL,
      device_info        VARCHAR2(200),
      ip_address         VARCHAR2(64),
      user_agent         VARCHAR2(500),
      expires_at         TIMESTAMP NOT NULL,
      revoked_at         TIMESTAMP,
      created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      last_used_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT fk_2fa_trusted_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
      CONSTRAINT uk_2fa_trusted_device UNIQUE (user_id, device_fingerprint)
    )
    `,
    `
    CREATE TABLE n_auth_two_factor_challenges (
      challenge_id       VARCHAR2(80) PRIMARY KEY,
      user_id            NUMBER(10) NOT NULL,
      remember_me        NUMBER(1) DEFAULT 0 NOT NULL
        CHECK (remember_me IN (0, 1)),
      device_info        VARCHAR2(200),
      device_fingerprint VARCHAR2(200),
      ip_address         VARCHAR2(64),
      user_agent         VARCHAR2(500),
      expires_at         TIMESTAMP NOT NULL,
      consumed_at        TIMESTAMP,
      created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT fk_2fa_challenge_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
    )
    `,
    `
    CREATE INDEX idx_2fa_recovery_user
    ON n_user_two_factor_recovery_codes(user_id, used_at)
    `,
    `
    CREATE INDEX idx_2fa_challenge_user
    ON n_auth_two_factor_challenges(user_id, expires_at, consumed_at)
    `,
    `
    CREATE INDEX idx_2fa_trusted_user
    ON n_user_two_factor_trusted_devices(user_id, expires_at, revoked_at)
    `
  ];

  for (const statement of statements) {
    try {
      await v2Execute(connection, statement);
    } catch (error) {
      if (!v2IsObjectAlreadyExistsError(error)) {
        throw error;
      }
    }
  }

  twoFactorSchemaReady = true;
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
  return process.env.COOKIE_SECURE === 'true';
  // return false;
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

export function v2ClearAuthCookies(event: H3Event): void {
  deleteCookie(event, 'access_token', { path: '/' });
  deleteCookie(event, 'refresh_token', { path: '/' });
}

function v2IsAuthPayload(
  value: unknown
): value is V2AuthPayload {
  if (!value || typeof value !== 'object') return false;
  const payload = value as Record<string, unknown>;
  return (
    typeof payload.userId === 'number' &&
    (payload.type === 'access' ||
      payload.type === 'refresh')
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

function v2OtpType(
  value: string
): V2AuthOtpPayload['type'] {
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
  return (
    v2DateString(verified?.VERIFIED_AT) ||
    new Date().toISOString()
  );
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

export async function v2VerifyUserPassword(
  connection: oracledb.Connection,
  userId: number,
  password: string
): Promise<void> {
  const row = await v2One(
    connection,
    `
    SELECT password_hash, status, is_active
    FROM n_users
    WHERE user_id = :user_id
    `,
    { user_id: userId }
  );
  if (!row) v2NotFound('用户不存在');
  if (
    v2Number(row.IS_ACTIVE) !== 1 ||
    v2String(row.STATUS) !== 'active'
  ) {
    v2Forbidden('账号不可用');
  }
  const matched = await bcrypt.compare(
    password,
    v2String(row.PASSWORD_HASH)
  );
  if (!matched) v2Unauthorized('密码错误');
}

async function v2TwoFactorSecretRow(
  connection: oracledb.Connection,
  userId: number
): Promise<Record<string, unknown> | null> {
  await v2EnsureTwoFactorSchema(connection);
  return await v2One(
    connection,
    `
    SELECT *
    FROM n_user_two_factor_secrets
    WHERE user_id = :user_id
    `,
    { user_id: userId }
  );
}

async function v2ConsumeRecoveryCode(
  connection: oracledb.Connection,
  userId: number,
  code: string
): Promise<boolean> {
  const candidates = v2RecoveryCodeCandidates(code);
  if (
    candidates.length === 0 ||
    candidates.some(candidate => /^\d{6}$/u.test(candidate))
  ) {
    return false;
  }

  const rows = await v2Rows(
    connection,
    `
    SELECT recovery_code_id, code_hash
    FROM n_user_two_factor_recovery_codes
    WHERE user_id = :user_id
      AND used_at IS NULL
    ORDER BY created_at ASC
    `,
    { user_id: userId }
  );

  for (const row of rows) {
    const codeHash = v2String(row.CODE_HASH);
    let matched = false;
    for (const candidate of candidates) {
      if (await bcrypt.compare(candidate, codeHash)) {
        matched = true;
        break;
      }
    }
    if (!matched) continue;

    await v2Execute(
      connection,
      `
      UPDATE n_user_two_factor_recovery_codes
      SET used_at = CURRENT_TIMESTAMP
      WHERE recovery_code_id = :recovery_code_id
      `,
      { recovery_code_id: v2Number(row.RECOVERY_CODE_ID) }
    );
    return true;
  }

  return false;
}

async function v2VerifyTwoFactorCode(
  connection: oracledb.Connection,
  userId: number,
  code: string,
  options: { allowRecoveryCode: boolean }
): Promise<void> {
  const row = await v2TwoFactorSecretRow(connection, userId);
  if (!row || !row.ENABLED_AT) {
    v2Unprocessable('双因素认证尚未启用');
  }

  const normalizedCode = v2NormalizeTwoFactorCode(code);
  const secret = v2DecryptTwoFactorSecret(row);
  if (v2VerifyTotpCode(secret, normalizedCode)) return;

  if (
    options.allowRecoveryCode &&
    (await v2ConsumeRecoveryCode(
      connection,
      userId,
      normalizedCode
    ))
  ) {
    return;
  }

  v2Unauthorized('双因素验证码错误');
}

function v2RequestDeviceFingerprint(event: H3Event): string {
  return v2String(
    getHeader(event, 'x-device-fingerprint'),
    'unknown'
  ).slice(0, 200);
}

function v2RequestDeviceInfo(event: H3Event): string {
  return v2String(
    getHeader(event, 'x-device-info'),
    'unknown'
  ).slice(0, 200);
}

async function v2UseTrustedTwoFactorDevice(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number
): Promise<boolean> {
  const deviceFingerprint = v2RequestDeviceFingerprint(event);
  if (!deviceFingerprint || deviceFingerprint === 'unknown') {
    return false;
  }

  const row = await v2One(
    connection,
    `
    SELECT trusted_device_id
    FROM n_user_two_factor_trusted_devices
    WHERE user_id = :user_id
      AND device_fingerprint = :device_fingerprint
      AND expires_at > CURRENT_TIMESTAMP
      AND revoked_at IS NULL
    FETCH FIRST 1 ROWS ONLY
    `,
    {
      user_id: userId,
      device_fingerprint: deviceFingerprint
    }
  );
  if (!row) return false;

  await v2Execute(
    connection,
    `
    UPDATE n_user_two_factor_trusted_devices
    SET last_used_at = CURRENT_TIMESTAMP,
        device_info = :device_info,
        ip_address = :ip_address,
        user_agent = :user_agent
    WHERE trusted_device_id = :trusted_device_id
    `,
    {
      trusted_device_id: v2Number(row.TRUSTED_DEVICE_ID),
      device_info: v2RequestDeviceInfo(event),
      ip_address: v2RequestIp(event),
      user_agent: v2UserAgent(event)
    }
  );

  return true;
}

async function v2TrustTwoFactorDevice(
  connection: oracledb.Connection,
  row: Record<string, unknown>
): Promise<void> {
  const deviceFingerprint = v2String(row.DEVICE_FINGERPRINT).slice(
    0,
    200
  );
  if (!deviceFingerprint || deviceFingerprint === 'unknown') {
    return;
  }

  const trustedDeviceId = await v2NextId(
    connection,
    'seq_2fa_trusted_device_id'
  );
  const expiresAt = new Date(
    Date.now() +
      TWO_FACTOR_TRUSTED_DEVICE_DAYS * 24 * 60 * 60 * 1000
  );

  await v2Execute(
    connection,
    `
    MERGE INTO n_user_two_factor_trusted_devices target
    USING (
      SELECT :user_id AS user_id,
             :device_fingerprint AS device_fingerprint
      FROM dual
    ) src
    ON (
      target.user_id = src.user_id
      AND target.device_fingerprint = src.device_fingerprint
    )
    WHEN MATCHED THEN UPDATE SET
      device_info = :device_info,
      ip_address = :ip_address,
      user_agent = :user_agent,
      expires_at = :expires_at,
      revoked_at = NULL,
      last_used_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN INSERT (
      trusted_device_id,
      user_id,
      device_fingerprint,
      device_info,
      ip_address,
      user_agent,
      expires_at
    ) VALUES (
      :trusted_device_id,
      :user_id,
      :device_fingerprint,
      :device_info,
      :ip_address,
      :user_agent,
      :expires_at
    )
    `,
    {
      trusted_device_id: trustedDeviceId,
      user_id: v2Number(row.USER_ID),
      device_fingerprint: deviceFingerprint,
      device_info: v2StringOrNull(row.DEVICE_INFO),
      ip_address: v2StringOrNull(row.IP_ADDRESS),
      user_agent: v2StringOrNull(row.USER_AGENT),
      expires_at: expiresAt
    }
  );
}

async function v2CreateTwoFactorChallenge(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number,
  account: string,
  rememberMe: boolean
): Promise<V2TwoFactorLoginChallengeData> {
  await v2EnsureTwoFactorSchema(connection);
  const challengeId = `2fa_${crypto.randomUUID()}`;
  const expiresAt = new Date(
    Date.now() + TWO_FACTOR_CHALLENGE_EXPIRES_SECONDS * 1000
  );

  await v2Execute(
    connection,
    `
    INSERT INTO n_auth_two_factor_challenges (
      challenge_id,
      user_id,
      remember_me,
      device_info,
      device_fingerprint,
      ip_address,
      user_agent,
      expires_at
    ) VALUES (
      :challenge_id,
      :user_id,
      :remember_me,
      :device_info,
      :device_fingerprint,
      :ip_address,
      :user_agent,
      :expires_at
    )
    `,
    {
      challenge_id: challengeId,
      user_id: userId,
      remember_me: rememberMe ? 1 : 0,
      device_info: v2RequestDeviceInfo(event),
      device_fingerprint: v2RequestDeviceFingerprint(event),
      ip_address: v2RequestIp(event),
      user_agent: v2UserAgent(event),
      expires_at: expiresAt
    }
  );

  return {
    two_factor_required: true,
    challenge_id: challengeId,
    account,
    expires_at: expiresAt.toISOString()
  };
}

async function v2IssueLoginSession(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number,
  username: string
): Promise<V2LoginSuccessData> {
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
  const accessToken = v2SignAccessToken(
    tokenPayload,
    accessJti
  );
  const refreshToken = v2SignRefreshToken(tokenPayload);
  const deviceInfo = v2String(
    getHeader(event, 'x-device-info'),
    'unknown'
  );
  const deviceFingerprint = v2String(
    getHeader(event, 'x-device-fingerprint'),
    'unknown'
  );
  const knownDeviceCount = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_auth_sessions
    WHERE user_id = :user_id
      AND device_fingerprint = :device_fingerprint
    `,
    {
      user_id: userId,
      device_fingerprint: deviceFingerprint
    }
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

  try {
    await v2SendLoginAlert(
      event,
      connection,
      userId,
      sessionId,
      deviceInfo,
      deviceFingerprint,
      knownDeviceCount === 0
    );
  } catch (error) {
    console.error('[auth] login alert failed', error);
  }

  return {
    two_factor_required: false,
    user: await v2RequireSelfUser(connection, userId),
    tokens: buildV2TokenData({
      sessionId,
      accessToken,
      refreshToken,
      accessExpiresAt,
      refreshExpiresAt
    })
  };
}

export async function v2StartTwoFactorSetup(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2TwoFactorSetupData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  await v2VerifyUserPassword(
    connection,
    auth.userId,
    v2RequiredString(body, 'password')
  );
  await v2EnsureTwoFactorSchema(connection);
  const existingSecret = await v2TwoFactorSecretRow(
    connection,
    auth.userId
  );
  if (existingSecret?.ENABLED_AT) {
    v2Unprocessable('双因素认证已启用，请先关闭后再重新设置');
  }

  const user = await v2RequireSelfUser(connection, auth.userId);
  const secret = v2Base32Encode(crypto.randomBytes(20));
  const encrypted = v2EncryptTwoFactorSecret(secret);

  await v2Execute(
    connection,
    `
    MERGE INTO n_user_two_factor_secrets target
    USING (SELECT :user_id AS user_id FROM dual) src
    ON (target.user_id = src.user_id)
    WHEN MATCHED THEN UPDATE SET
      secret_encrypted = :secret_encrypted,
      secret_iv = :secret_iv,
      secret_auth_tag = :secret_auth_tag,
      confirmed_at = NULL,
      enabled_at = NULL,
      updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN INSERT (
      user_id,
      secret_encrypted,
      secret_iv,
      secret_auth_tag
    ) VALUES (
      :user_id,
      :secret_encrypted,
      :secret_iv,
      :secret_auth_tag
    )
    `,
    {
      user_id: auth.userId,
      secret_encrypted: encrypted.encrypted,
      secret_iv: encrypted.iv,
      secret_auth_tag: encrypted.tag
    }
  );

  await v2Execute(
    connection,
    `
    DELETE FROM n_user_two_factor_recovery_codes
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  await v2Execute(
    connection,
    `
    DELETE FROM n_user_two_factor_trusted_devices
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );

  await v2Execute(
    connection,
    `
    MERGE INTO n_user_settings target
    USING (SELECT :user_id AS user_id FROM dual) src
    ON (target.user_id = src.user_id)
    WHEN MATCHED THEN UPDATE SET
      two_factor_enabled = 0,
      updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN INSERT (
      user_id,
      two_factor_enabled
    ) VALUES (
      :user_id,
      0
    )
    `,
    { user_id: auth.userId }
  );

  return v2Ok({
    secret,
    otpauth_url: v2TwoFactorUri(user.email || user.username, secret)
  });
}

export async function v2ConfirmTwoFactorSetup(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2TwoFactorConfirmData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const code = v2NormalizeTwoFactorCode(body.code);
  const row = await v2TwoFactorSecretRow(connection, auth.userId);
  if (!row) v2Unprocessable('请先生成双因素认证密钥');

  const secret = v2DecryptTwoFactorSecret(row);
  if (!v2VerifyTotpCode(secret, code)) {
    v2Unauthorized('双因素验证码错误');
  }

  const recoveryCodes = Array.from({ length: 10 }, () =>
    v2RandomRecoveryCode()
  );

  await v2Execute(
    connection,
    `
    DELETE FROM n_user_two_factor_recovery_codes
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );

  for (const recoveryCode of recoveryCodes) {
    await v2Execute(
      connection,
      `
      INSERT INTO n_user_two_factor_recovery_codes (
        recovery_code_id,
        user_id,
        code_hash
      ) VALUES (
        :recovery_code_id,
        :user_id,
        :code_hash
      )
      `,
      {
        recovery_code_id: await v2NextId(
          connection,
          'seq_2fa_recovery_code_id'
        ),
        user_id: auth.userId,
        code_hash: await bcrypt.hash(
          v2NormalizeTwoFactorCode(recoveryCode),
          10
        )
      }
    );
  }

  await v2Execute(
    connection,
    `
    UPDATE n_user_two_factor_secrets
    SET confirmed_at = CURRENT_TIMESTAMP,
        enabled_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  await v2Execute(
    connection,
    `
    MERGE INTO n_user_settings target
    USING (SELECT :user_id AS user_id FROM dual) src
    ON (target.user_id = src.user_id)
    WHEN MATCHED THEN UPDATE SET
      two_factor_enabled = 1,
      updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN INSERT (
      user_id,
      two_factor_enabled
    ) VALUES (
      :user_id,
      1
    )
    `,
    { user_id: auth.userId }
  );

  return v2Ok({
    enabled: true,
    recovery_codes: recoveryCodes
  });
}

export async function v2DisableTwoFactor(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2TwoFactorStatusData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  await v2VerifyUserPassword(
    connection,
    auth.userId,
    v2RequiredString(body, 'password')
  );
  await v2VerifyTwoFactorCode(
    connection,
    auth.userId,
    v2RequiredString(body, 'code'),
    { allowRecoveryCode: true }
  );

  await v2Execute(
    connection,
    `
    UPDATE n_user_two_factor_secrets
    SET enabled_at = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  await v2Execute(
    connection,
    `
    DELETE FROM n_user_two_factor_recovery_codes
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  await v2Execute(
    connection,
    `
    DELETE FROM n_user_two_factor_trusted_devices
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );
  await v2Execute(
    connection,
    `
    UPDATE n_user_settings
    SET two_factor_enabled = 0,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_id = :user_id
    `,
    { user_id: auth.userId }
  );

  return v2Ok({ enabled: false });
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
    confirm_password: v2RequiredString(
      body,
      'confirm_password'
    ),
    display_name: v2RequiredString(body, 'display_name'),
    bio: v2String(body.bio),
    location: v2String(body.location),
    phone: v2String(body.phone),
    birth_date: v2String(body.birth_date),
    verification_id: v2RequiredString(
      body,
      'verification_id'
    ),
    agree_to_terms: body.agree_to_terms === true
  };

  if (!payload.agree_to_terms)
    v2BadRequest('必须同意服务条款');
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
      password_hash: await bcrypt.hash(
        payload.password,
        10
      ),
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

  await v2EnsureTwoFactorSchema(connection);
  const twoFactorRow = await v2One(
    connection,
    `
    SELECT NVL(us.two_factor_enabled, 0) AS two_factor_enabled,
           tf.enabled_at
    FROM n_users u
    LEFT JOIN n_user_settings us ON us.user_id = u.user_id
    LEFT JOIN n_user_two_factor_secrets tf
      ON tf.user_id = u.user_id
    WHERE u.user_id = :user_id
    `,
    { user_id: userId }
  );
  if (
    v2Boolean(twoFactorRow?.TWO_FACTOR_ENABLED) &&
    twoFactorRow?.ENABLED_AT
  ) {
    if (
      await v2UseTrustedTwoFactorDevice(
        event,
        connection,
        userId
      )
    ) {
      return v2Ok(
        await v2IssueLoginSession(
          event,
          connection,
          userId,
          username
        ),
        'login success'
      );
    }

    return v2Ok(
      await v2CreateTwoFactorChallenge(
        event,
        connection,
        userId,
        payload.account,
        payload.remember_me ?? false
      ),
      'two factor required'
    );
  }

  return v2Ok(
    await v2IssueLoginSession(event, connection, userId, username),
    'login success'
  );
}

export async function v2CompleteTwoFactorLogin(
  event: H3Event,
  connection: oracledb.Connection,
  challengeId?: string
): Promise<V2Response<V2LoginData>> {
  const body = await v2Body(event);
  const normalizedChallengeId =
    challengeId || v2RequiredString(body, 'challenge_id');
  const code = v2RequiredString(body, 'code');
  await v2EnsureTwoFactorSchema(connection);

  const row = await v2One(
    connection,
    `
    SELECT c.challenge_id,
           c.user_id,
           c.remember_me,
           c.device_info,
           c.device_fingerprint,
           c.ip_address,
           c.user_agent,
           u.username
    FROM n_auth_two_factor_challenges c
    JOIN n_users u ON u.user_id = c.user_id
    WHERE c.challenge_id = :challenge_id
      AND c.expires_at > CURRENT_TIMESTAMP
      AND c.consumed_at IS NULL
      AND u.is_active = 1
      AND u.status = 'active'
    `,
    { challenge_id: normalizedChallengeId }
  );
  if (!row) v2Unauthorized('双因素验证已过期，请重新登录');

  const userId = v2Number(row.USER_ID);
  await v2VerifyTwoFactorCode(connection, userId, code, {
    allowRecoveryCode: true
  });
  await v2Execute(
    connection,
    `
    UPDATE n_auth_two_factor_challenges
    SET consumed_at = CURRENT_TIMESTAMP
    WHERE challenge_id = :challenge_id
    `,
    { challenge_id: normalizedChallengeId }
  );
  if (v2Boolean(row.REMEMBER_ME)) {
    await v2TrustTwoFactorDevice(connection, row);
  }

  return v2Ok(
    await v2IssueLoginSession(
      event,
      connection,
      userId,
      v2String(row.USERNAME)
    ),
    'login success'
  );
}

export async function v2RefreshCurrentToken(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2TokenData>> {
  const refreshCookie = getCookie(event, 'refresh_token');
  const refreshBody = refreshCookie
    ? {}
    : await v2Body(event).catch(() => ({}));
  const refreshToken = resolveV2RefreshToken(
    refreshCookie,
    refreshBody
  );
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

  return v2Ok(
    buildV2TokenData({
      sessionId: payload.sessionId,
      accessToken: newAccessToken,
      refreshToken: newRefreshToken,
      accessExpiresAt,
      refreshExpiresAt
    })
  );
}

export async function v2LogoutCurrent(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<null>> {
  const auth = (() => {
    try {
      return v2Auth(event);
    } catch {
      const refreshToken = getCookie(
        event,
        'refresh_token'
      );
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
    verification_id: v2RequiredString(
      body,
      'verification_id'
    ),
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
      password_hash: await bcrypt.hash(
        payload.new_password,
        10
      ),
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
      is_current:
        v2String(row.SESSION_ID) === auth.sessionId
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
  if (sessionId === auth.sessionId)
    v2ClearAuthCookies(event);
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
  return v2Ok(
    { revoked_count: count },
    'other sessions revoked'
  );
}

export function v2CurrentRefreshToken(
  event: H3Event
): string | null {
  return getCookie(event, 'refresh_token') ?? null;
}

export function v2SessionIdFromRefresh(
  refreshToken: string
): string | null {
  return (
    v2VerifyRefreshToken(refreshToken)?.sessionId ?? null
  );
}

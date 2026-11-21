import type {
  V2AccountDeletionData,
  V2TwoFactorConfirmData,
  V2TwoFactorSetupData,
  V2TwoFactorStatusData
} from '@/types/v2';

function invalid(): never { throw new Error('Invalid security action response'); }
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function text(value: unknown): string {
  if (typeof value !== 'string' || !value.trim()) invalid();
  return value;
}
function responseData(value: unknown): Record<string, unknown> {
  const body = record(value);
  if (body.code !== 200 || !Object.prototype.hasOwnProperty.call(body, 'meta') ||
      (Object.prototype.hasOwnProperty.call(body, 'error') && body.error !== false)) invalid();
  text(body.message);
  if (body.meta !== null) {
    const meta = record(body.meta);
    if (meta.has_next !== undefined && meta.has_next !== null && typeof meta.has_next !== 'boolean') invalid();
  }
  return record(body.data);
}

function factorUri(value: unknown, secret: string): string {
  const uri = text(value);
  if (/[^\x21-\x7e]|\\/.test(uri)) invalid();
  const match = /^otpauth:\/\/totp\/([^/?#]+)\?([^#]*)$/.exec(uri);
  if (!match) invalid();
  try {
    const label = decodeURIComponent(match[1]!);
    if (!label.startsWith('NekoTribe:') || !label.slice('NekoTribe:'.length).trim()) invalid();
    const parameters = new Map<string, string[]>();
    for (const item of match[2]!.split('&')) {
      const separator = item.indexOf('=');
      if (separator < 0) invalid();
      const decode = (part: string): string => decodeURIComponent(part.replace(/\+/g, ' '));
      const key = decode(item.slice(0, separator)), value = decode(item.slice(separator + 1));
      parameters.set(key, [...(parameters.get(key) ?? []), value]);
    }
    for (const [key, expected] of Object.entries({secret, issuer: 'NekoTribe', algorithm: 'SHA1', digits: '6', period: '30'})) {
      const actual = parameters.get(key);
      if (actual?.length !== 1 || actual[0] !== expected) invalid();
    }
  } catch { invalid(); }
  return uri;
}

export function decodeFactorSetupResponse(value: unknown): V2TwoFactorSetupData {
  const data = responseData(value), secret = text(data.secret);
  if (secret.length !== 32 || !/^[A-Z2-7]{32}$/.test(secret)) invalid();
  return {secret, otpauth_url: factorUri(data.otpauth_url, secret)};
}

export function decodeFactorConfirmResponse(value: unknown): V2TwoFactorConfirmData {
  const data = responseData(value), codes = data.recovery_codes;
  if (data.enabled !== true || !Array.isArray(codes) || codes.length !== 10) invalid();
  const recoveryCodes = codes.map((code: unknown) => {
    if (typeof code !== 'string' || code.length !== 17 || !/^[A-Z2-7]{5}-[A-Z2-7]{5}-[A-Z2-7]{5}$/.test(code)) invalid();
    return code;
  });
  return {enabled: true, recovery_codes: recoveryCodes};
}

export function decodeFactorDisableResponse(value: unknown): V2TwoFactorStatusData {
  if (responseData(value).enabled !== false) invalid();
  return {enabled: false};
}

export function decodeAccountDeletionResponse(value: unknown): V2AccountDeletionData {
  const data = responseData(value), id = data.user_id;
  if (data.deleted !== true || typeof id !== 'number' || !Number.isSafeInteger(id) || id <= 0) invalid();
  return {deleted: true, user_id: id};
}

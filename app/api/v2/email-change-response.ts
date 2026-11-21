import type { V2ChangeEmailData } from '@/types/v2';
import { parseStrictTimestamp } from '@/utils/strict-timestamp';

function invalid(): never { throw new Error('Invalid email change response'); }
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function text(value: unknown): string {
  if (typeof value !== 'string' || !value.trim()) invalid();
  return value;
}
export function decodeEmailChangeResponse(value: unknown, expectedEmail: string): V2ChangeEmailData {
  const body = record(value);
  if (body.code !== 200 || body.error === true || !Object.prototype.hasOwnProperty.call(body, 'meta')) invalid();
  text(body.message);
  if (body.meta !== null) {
    const meta = record(body.meta);
    if (meta.has_next !== undefined && meta.has_next !== null && typeof meta.has_next !== 'boolean') invalid();
  }
  const data = record(body.data), email = text(data.email), verifiedAt = text(data.email_verified_at);
  if (email !== expectedEmail.trim()) invalid();
  try { parseStrictTimestamp(verifiedAt); } catch { invalid(); }
  return { email, email_verified_at: verifiedAt };
}

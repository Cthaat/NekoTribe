import type { V2UserSettings } from '@/types/v2';
function invalid(): never { throw new Error('Invalid account settings response'); }
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function booleanField(data: Record<string, unknown>, key: string): boolean {
  const value = data[key];
  if (typeof value !== 'boolean') invalid();
  return value;
}
function stringField(data: Record<string, unknown>, key: string): string {
  const value = data[key];
  if (typeof value !== 'string') invalid();
  return value;
}
export function decodeSettingsResponse(value: unknown): V2UserSettings {
  const body = record(value);
  if (body.code !== 200 || !Object.hasOwn(body, 'meta') || (Object.hasOwn(body, 'error') && body.error !== false)) invalid();
  if (typeof body.message !== 'string' || !body.message.trim()) invalid();
  if (body.meta !== null) {
    const meta = record(body.meta);
    if (meta.has_next !== undefined && meta.has_next !== null && typeof meta.has_next !== 'boolean') invalid();
  }
  const data = record(body.data), id = data.user_id, top = data.ai_sentiment_top_k, model = data.ai_sentiment_model_id;
  if (typeof id !== 'number' || !Number.isSafeInteger(id) || id <= 0 || typeof top !== 'number' || !Number.isInteger(top) || top < 1 || top > 10) invalid();
  if (!Object.hasOwn(data, 'ai_sentiment_model_id') || (model !== null && typeof model !== 'string')) invalid();
  return {
    user_id: id,
    two_factor_enabled: booleanField(data, 'two_factor_enabled'),
    login_alerts: booleanField(data, 'login_alerts'),
    profile_visibility: stringField(data, 'profile_visibility'),
    show_online_status: booleanField(data, 'show_online_status'),
    allow_dm_from_strangers: booleanField(data, 'allow_dm_from_strangers'),
    push_notification_enabled: booleanField(data, 'push_notification_enabled'),
    email_notification_enabled: booleanField(data, 'email_notification_enabled'),
    ai_sentiment_enabled: booleanField(data, 'ai_sentiment_enabled'),
    ai_sentiment_model_id: model,
    ai_sentiment_return_probabilities: booleanField(data, 'ai_sentiment_return_probabilities'),
    ai_sentiment_include_metadata: booleanField(data, 'ai_sentiment_include_metadata'),
    ai_sentiment_top_k: top,
    updated_at: stringField(data, 'updated_at')
  };
}

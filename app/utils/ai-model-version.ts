const modelVersionPattern = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/;

export function aiModelVersion(role: unknown, value: unknown): string | null {
  return role === 'assistant' && typeof value === 'string' &&
    value.trim() === value && modelVersionPattern.test(value) ? value : null;
}

export function isAiReplyConfigRevision(role: unknown, value: unknown): value is number {
  return role === 'assistant' && typeof value === 'number' && Number.isSafeInteger(value) &&
    value >= 1 && value <= 999_999_999_999_999;
}

import { joinStorageBaseUrl } from './apiBase';

const STORAGE_PUBLIC_BASE = '/storage';
const DEFAULT_AVATAR_PATH = `${STORAGE_PUBLIC_BASE}/default-avatar.png`;

function resolveAssetUrl(url: string, publicMedia: boolean): string {
  const trimmed = url.trim();
  if (
    !trimmed ||
    trimmed === '/default-avatar.png' ||
    trimmed === 'default-avatar.png'
  ) {
    return joinStorageBaseUrl(DEFAULT_AVATAR_PATH);
  }

  const path = trimmed.replace(/^\/uploads?\/+/, `${STORAGE_PUBLIC_BASE}/`);
  if (path.startsWith(`${STORAGE_PUBLIC_BASE}/`) ||
      (publicMedia && /^\/(?![/\\])/.test(path) && !path.startsWith('/api/'))) {
    return joinStorageBaseUrl(path);
  }

  return trimmed;
}

export function normalizeAssetUrl(url: string): string {
  return resolveAssetUrl(url, false);
}

// URLs in public media fields can use a backend-specific root-relative prefix.
export function normalizePublicMediaUrl(url: string): string {
  return resolveAssetUrl(url, true);
}

export function normalizeNullableAssetUrl(
  url: string | null | undefined
): string | null {
  return url ? normalizePublicMediaUrl(url) : null;
}

export function normalizeAvatarUrl(
  url: string | null | undefined
): string {
  return normalizePublicMediaUrl(url ?? '');
}

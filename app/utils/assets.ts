import { joinApiBaseUrl } from './apiBase';

const STORAGE_PUBLIC_BASE = '/storage';
const DEFAULT_AVATAR_PATH = `${STORAGE_PUBLIC_BASE}/default-avatar.png`;

function storagePathForKey(key: string): string {
  return `${STORAGE_PUBLIC_BASE}/${key.replace(/^\/+/, '')}`;
}

function withApiBase(path: string): string {
  if (!path.startsWith(`${STORAGE_PUBLIC_BASE}/`)) {
    return path;
  }
  return joinApiBaseUrl(path);
}

export function normalizeAssetUrl(url: string): string {
  const trimmed = url.trim();
  if (
    !trimmed ||
    trimmed === '/default-avatar.png' ||
    trimmed === 'default-avatar.png'
  ) {
    return withApiBase(DEFAULT_AVATAR_PATH);
  }

  if (trimmed.startsWith(`${STORAGE_PUBLIC_BASE}/`)) {
    return withApiBase(trimmed);
  }

  if (trimmed.startsWith('/uploads/')) {
    return withApiBase(
      storagePathForKey(trimmed.slice('/uploads/'.length))
    );
  }

  if (trimmed.startsWith('/upload/')) {
    return withApiBase(
      storagePathForKey(trimmed.slice('/upload/'.length))
    );
  }

  try {
    const parsed = new URL(trimmed);
    if (parsed.pathname.startsWith('/uploads/')) {
      return withApiBase(
        storagePathForKey(
          parsed.pathname.slice('/uploads/'.length)
        )
      );
    }
    if (parsed.pathname.startsWith('/upload/')) {
      return withApiBase(
        storagePathForKey(
          parsed.pathname.slice('/upload/'.length)
        )
      );
    }
  } catch {
    // Relative non-storage paths are returned unchanged below.
  }

  return trimmed;
}

export function normalizeNullableAssetUrl(
  url: string | null | undefined
): string | null {
  return url ? normalizeAssetUrl(url) : null;
}

export function normalizeAvatarUrl(
  url: string | null | undefined
): string {
  return normalizeAssetUrl(url ?? '');
}

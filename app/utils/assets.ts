const STORAGE_PUBLIC_BASE = '/storage';
const DEFAULT_AVATAR_URL = `${STORAGE_PUBLIC_BASE}/default-avatar.png`;

function storageUrlForKey(key: string): string {
  return `${STORAGE_PUBLIC_BASE}/${key.replace(/^\/+/, '')}`;
}

export function normalizeAssetUrl(url: string): string {
  const trimmed = url.trim();
  if (
    !trimmed ||
    trimmed === '/default-avatar.png' ||
    trimmed === 'default-avatar.png'
  ) {
    return DEFAULT_AVATAR_URL;
  }

  if (trimmed.startsWith(`${STORAGE_PUBLIC_BASE}/`)) {
    return trimmed;
  }

  if (trimmed.startsWith('/uploads/')) {
    return storageUrlForKey(
      trimmed.slice('/uploads/'.length)
    );
  }

  if (trimmed.startsWith('/upload/')) {
    return storageUrlForKey(
      trimmed.slice('/upload/'.length)
    );
  }

  try {
    const parsed = new URL(trimmed);
    if (parsed.pathname.startsWith('/uploads/')) {
      return storageUrlForKey(
        parsed.pathname.slice('/uploads/'.length)
      );
    }
    if (parsed.pathname.startsWith('/upload/')) {
      return storageUrlForKey(
        parsed.pathname.slice('/upload/'.length)
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

export function privateMediaContentPath(mediaId: number): string | null {
  return Number.isSafeInteger(mediaId) && mediaId > 0
    ? `/api/v2/media/${mediaId}/content`
    : null;
}

export function isPrivateMediaContent(mediaId: number, url: string | null | undefined): boolean {
  const path = privateMediaContentPath(mediaId);
  return path !== null && url === path;
}

export function usesMediaContentRoute(value: string): boolean {
  try {
    const path = new URL(value, 'https://storage.invalid/').pathname;
    return path.startsWith('/api/v2/media/') ||
      decodeURIComponent(path).startsWith('/api/v2/media/');
  } catch {
    return false;
  }
}

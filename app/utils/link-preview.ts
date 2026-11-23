import policy from '../../specifications/requirements/link-preview.json' with { type: 'json' };

export function previewUrl(raw: string): string | null {
  const authority = /^https?:\/\/([^/?#]+)/i.exec(raw)?.[1];
  // eslint-disable-next-line no-control-regex
  if (!authority || /[@%]/.test(authority) || authority.endsWith(':') || /[\u0000-\u0020\u007f\\]/u.test(raw)) return null;
  let url: URL;
  try { url = new URL(raw); } catch { return null; }
  if (!url.hostname || url.username || url.password || url.port) return null;
  url.hash = '';
  return new TextEncoder().encode(url.href).length <= policy.max_url_bytes ? url.href : null;
}

export function firstPreviewUrl(source: string): string | null {
  for (const [match] of source.matchAll(/https?:\/\/[^\s<>"'`]+/giu)) {
    const url = previewUrl(match.replace(/[.,!?;:，。！？；：、）】》]+$/u, ''));
    if (url) return url;
  }
  return null;
}

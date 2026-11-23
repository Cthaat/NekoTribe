import { previewUrl } from '@/utils/link-preview';
import { v2RequestData } from './client';

export interface V2LinkPreview {
  url: string;
  title: string;
  description: string;
  site_name: string;
}

export async function v2GetLinkPreview(url: string, signal: AbortSignal): Promise<V2LinkPreview | null> {
  const data = await v2RequestData<{ preview: V2LinkPreview | null }, undefined, { url: string }>(
    '/api/v2/links/preview', { query: { url }, signal },
  );
  const preview = data?.preview;
  if (!preview || typeof preview.url !== 'string' || typeof preview.title !== 'string' || typeof preview.description !== 'string' ||
      typeof preview.site_name !== 'string') return null;
  const canonical = previewUrl(preview.url);
  return canonical ? { ...preview, url: canonical } : null;
}

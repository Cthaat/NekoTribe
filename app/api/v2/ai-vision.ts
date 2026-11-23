import { v2RequestData } from './client';

const altTextBytes = (text: string) => new TextEncoder().encode(text).length;
export const validImageAltText = (text: string) =>
  text.isWellFormed() && !/[\u0000-\u001f\u007f]/.test(text) && altTextBytes(text) <= 500;

export async function describeAiMedia(mediaId: number, locale: 'zh' | 'en', signal: AbortSignal) {
  const result = await v2RequestData<{media_id:number;alt_text:string;tags:string[]}, {media_id:number;locale:'zh'|'en'}>(
    '/api/v2/ai/media/describe', {method:'POST',body:{media_id:mediaId,locale},signal,redirect:'error'},
  );
  if (result?.media_id !== mediaId || typeof result.alt_text !== 'string' || !result.alt_text.trim() ||
      !validImageAltText(result.alt_text) || !Array.isArray(result.tags) || result.tags.length > 5 ||
      new Set(result.tags).size !== result.tags.length || result.tags.some(tag => typeof tag !== 'string' ||
        !tag || !tag.isWellFormed() || [...tag].length > 40 || /[#\s\u0000-\u001f\u007f]/u.test(tag))) {
    throw new Error('Invalid image suggestion');
  }
  return result;
}

export async function updateImageAltText(mediaId: number, text: string, signal: AbortSignal) {
  const altText = text.trim();
  const result = await v2RequestData<{media_id:number;alt_text:string|null},{alt_text:string}>(
    `/api/v2/media/${mediaId}`, {method:'PATCH',body:{alt_text:altText},signal,redirect:'error'},
  );
  if (result?.media_id !== mediaId || result.alt_text !== (altText || null)) throw new Error('Invalid alt text receipt');
}

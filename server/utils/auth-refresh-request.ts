import { getCookie, getHeader, type H3Event } from 'h3';

const maxBodyBytes = 1024 * 1024;

async function readCredentialBody(event: H3Event): Promise<string | null> {
  const length = getHeader(event, 'content-length');
  if (length && Number(length) > maxBodyBytes) return null;
  const chunks: Uint8Array[] = [];
  let size = 0;
  const append = (chunk: Uint8Array) => {
    if (chunk.byteLength > maxBodyBytes - size) return false;
    size += chunk.byteLength;
    chunks.push(chunk);
    return true;
  };

  const webBody = event.web?.request?.body ?? event._requestBody;
  if (webBody != null) {
    const reader = new Response(webBody).body?.getReader();
    if (!reader) return null;
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        if (!append(chunk.value)) {
          void reader.cancel().catch(() => {});
          return null;
        }
      }
    } finally {
      reader.releaseLock();
    }
  } else {
    for await (const chunk of event.node.req.iterator({ destroyOnReturn: false })) {
      if (!Buffer.isBuffer(chunk) || !append(chunk)) return null;
    }
  }
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(Buffer.concat(chunks, size));
}

function formCredential(text: string): string | null {
  if (text.includes(';')) return null;
  const decode = (value: string) => decodeURIComponent(value.replaceAll('+', ' '));
  let token: string | null = null;
  for (const entry of text.split('&')) {
    const split = entry.indexOf('=');
    const key = decode(split < 0 ? entry : entry.slice(0, split));
    const value = decode(split < 0 ? '' : entry.slice(split + 1));
    if (key === 'refresh_token') {
      if (token !== null) return null;
      token = value;
    }
  }
  return token;
}

export async function readRefreshCredential(event: H3Event): Promise<string | null> {
  const cookie = getCookie(event, 'refresh_token');
  if (cookie) return cookie.trim() || null;
  const mediaType = getHeader(event, 'content-type')?.split(';', 1)[0]?.trim().toLowerCase();
  if (mediaType?.startsWith('text/')) return null;
  try {
    const text = await readCredentialBody(event);
    if (!text) return null;
    if (mediaType === 'application/x-www-form-urlencoded') return formCredential(text)?.trim() || null;
    const body: unknown = JSON.parse(text);
    if (!body || typeof body !== 'object' || Array.isArray(body) || !Object.hasOwn(body, 'refresh_token')) return null;
    const token = (body as Record<string, unknown>).refresh_token;
    return typeof token === 'string' ? token.trim() || null : null;
  } catch {
    return null;
  }
}

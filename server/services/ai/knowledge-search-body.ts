import type { Readable } from 'node:stream';

/** Read at most 4096 bytes into memory, regardless of request headers. */
export function readKnowledgeSearchBody(stream: Readable): Promise<string | null> {
  return new Promise((resolve, reject) => {
    if (stream.destroyed || stream.readableEnded) { reject(new Error('INVALID_KNOWLEDGE_BODY')); return; }
    const chunks: Buffer[] = [];
    let size = 0;
    const cleanup = () => {
      stream.off('data', onData); stream.off('end', onEnd);
      stream.off('error', onError); stream.off('close', onClose);
    };
    const onError = () => { cleanup(); reject(new Error('INVALID_KNOWLEDGE_BODY')); };
    const onClose = () => { if (!stream.readableEnded) onError(); };
    const onEnd = () => {
      cleanup();
      try { resolve(parseKnowledgeSearchBody(Buffer.concat(chunks, size))); }
      catch { reject(new Error('INVALID_KNOWLEDGE_BODY')); }
    };
    const onData = (chunk: Buffer | string) => {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > 4096) {
        cleanup();
        const ignoreError = () => {};
        stream.once('error', ignoreError);
        stream.once('close', () => stream.off('error', ignoreError));
        stream.resume(); reject(new Error('INVALID_KNOWLEDGE_BODY')); return;
      }
      chunks.push(bytes);
    };
    stream.on('error', onError); stream.on('close', onClose);
    stream.on('end', onEnd); stream.on('data', onData);
  });
}

/** Validates a bounded UTF-8 generation body before any business or model work. */
export function parseKnowledgeSearchBody(bytes: Uint8Array): string | null {
  if (bytes.length === 0) return null;
  if (bytes.length > 4096) throw new Error('INVALID_KNOWLEDGE_BODY');
  let value: unknown;
  let text: string;
  try {
    text = new TextDecoder('utf-8', {fatal:true, ignoreBOM:true}).decode(bytes);
    value = JSON.parse(text);
  } catch {
    throw new Error('INVALID_KNOWLEDGE_BODY');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('INVALID_KNOWLEDGE_BODY');
  let depth=0, fields=0, inString=false, escaped=false;
  for (const ch of text) {
    if (inString) {
      if (escaped) escaped=false;
      else if (ch==='\\') escaped=true;
      else if (ch==='"') inString=false;
    } else if (ch==='"') inString=true;
    else if (ch==='{' || ch==='[') depth++;
    else if (ch==='}' || ch===']') depth--;
    else if (ch===':' && depth===1 && ++fields>1) throw new Error('INVALID_KNOWLEDGE_BODY');
  }
  const body = value as Record<string, unknown>;
  const keys = Object.keys(body);
  if (!keys.length) return null;
  if (keys.length !== 1 || keys[0] !== 'search_phrase' || typeof body.search_phrase !== 'string' || !body.search_phrase.isWellFormed()) throw new Error('INVALID_KNOWLEDGE_BODY');
  const phrase = body.search_phrase.trim();
  if (!phrase || /[\u0000-\u001f\u007f]/.test(phrase) || Buffer.byteLength(phrase,'utf8') > 256) throw new Error('INVALID_KNOWLEDGE_BODY');
  return phrase;
}

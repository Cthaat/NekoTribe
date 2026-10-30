/** Validates a bounded UTF-8 generation body before any business or model work. */
export function parseKnowledgeSearchBody(bytes: Uint8Array): string | null {
  if (bytes.length === 0) return null;
  if (bytes.length > 4096) throw new Error('INVALID_KNOWLEDGE_BODY');
  let value: unknown;
  try {
    const text = new TextDecoder('utf-8', {fatal:true, ignoreBOM:true}).decode(bytes);
    value = JSON.parse(text);
  } catch {
    throw new Error('INVALID_KNOWLEDGE_BODY');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('INVALID_KNOWLEDGE_BODY');
  const body = value as Record<string, unknown>;
  const keys = Object.keys(body);
  if (!keys.length) return null;
  if (keys.length !== 1 || keys[0] !== 'search_phrase' || typeof body.search_phrase !== 'string' || !body.search_phrase.isWellFormed()) throw new Error('INVALID_KNOWLEDGE_BODY');
  const phrase = body.search_phrase.trim();
  if (!phrase || /[\u0000-\u001f\u007f]/.test(phrase) || Buffer.byteLength(phrase,'utf8') > 256) throw new Error('INVALID_KNOWLEDGE_BODY');
  return phrase;
}

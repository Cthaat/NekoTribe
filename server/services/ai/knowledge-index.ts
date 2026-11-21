import type { KnowledgeHit } from './knowledge-turn';
import { isKnowledgeKind } from './knowledge-citations';
import { normalizeAiHttpBaseUrl } from './model-configuration';

export async function discoverIndexedSources(query: string, limit: number, signal?: AbortSignal): Promise<KnowledgeHit[] | null> {
  const address = process.env.AI_KNOWLEDGE_INDEX_URL;
  if (!address) return null;
  signal?.throwIfAborted();
  const term = query.trim();
  if (!term || !term.isWellFormed() || Buffer.byteLength(term) > 256 ||
      /[\u0000-\u001f\u007f]/.test(term) || !Number.isInteger(limit) || limit < 1 || limit > 20) {
    throw Error('INDEX_QUERY_INVALID');
  }
  const token = process.env.AI_INDEX_SERVICE_TOKEN;
  const lexicalFallback = process.env.AI_KNOWLEDGE_INDEX_FALLBACK === 'lexical';
  if (Buffer.byteLength(address) > 2048 || !token || token.length < 32 || token.length > 512 || /[^!-~]/.test(token)) {
    throw Error('INDEX_CONFIGURATION_INVALID');
  }
  let base: string;
  try { base = normalizeAiHttpBaseUrl(address); }
  catch { throw Error('INDEX_CONFIGURATION_INVALID'); }
  const deadline = AbortSignal.timeout(11000);
  let response: Response;
  try {
    response = await fetch(`${base}/internal/v1/knowledge/search`, {
      method:'POST', redirect:'manual', signal:signal ? AbortSignal.any([signal,deadline]) : deadline,
      headers:{authorization:`Bearer ${token}`,'content-type':'application/json','x-neko-knowledge-chunks':'1','x-neko-knowledge-group-sources':'1'}, body:JSON.stringify({query:term,limit}),
    });
  } catch {
    if (lexicalFallback && !signal?.aborted) return null;
    throw Error('INDEX_UNAVAILABLE');
  }
  if (response.status !== 200 || !response.body) {
    await response.body?.cancel().catch(() => {});
    if (lexicalFallback && !signal?.aborted && [429, 502, 503, 504].includes(response.status)) return null;
    throw Error('INDEX_UNAVAILABLE');
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const {value,done} = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 8192) throw Error('INDEX_RESPONSE_INVALID');
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  signal?.throwIfAborted();
  const result: unknown = JSON.parse(new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(Buffer.concat(chunks)));
  if (!result || typeof result !== 'object' || Object.keys(result).length !== 2 || !('version' in result) || result.version !== 1 ||
      !('candidates' in result) || !Array.isArray(result.candidates) || result.candidates.length > limit) throw Error('INDEX_RESPONSE_INVALID');
  const seen = new Set<string>();
  return result.candidates.map((candidate: unknown) => {
    if (!candidate || typeof candidate !== 'object' || Object.keys(candidate).some(key=>!['kind','id','version','chunk'].includes(key))) throw Error('INDEX_RESPONSE_INVALID');
    const {kind,id,version,chunk} = candidate as Record<string,unknown>;
    if (chunk !== undefined && (typeof chunk !== 'number' || !Number.isInteger(chunk) || chunk < 0 || chunk > 102)) throw Error('INDEX_RESPONSE_INVALID');
    if (!isKnowledgeKind(kind) || typeof id !== 'number' || !Number.isSafeInteger(id) ||
        id < 1 || id > (kind === 'terms' ? 8 : 999_999_999_999_999) ||
        typeof version !== 'string' || !/^[0-9a-f]{64}$/.test(version)) throw Error('INDEX_RESPONSE_INVALID');
    const key = `${kind}:${id}`;
    if (seen.has(key)) throw Error('INDEX_RESPONSE_INVALID');
    seen.add(key);
    return {kind,id,version,chunk};
  });
}

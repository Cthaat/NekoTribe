import type { Readable } from 'node:stream';
import { readBoundedBody } from '../../utils/bounded-body';

interface KnowledgeSearchBody {
  phrase?: string;
  skillId?: 'knowledge-answer';
  expectedSequence?: number;
}

export function isExpectedAiSequence(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 9_999_999_999;
}

/** Read at most 4096 bytes into memory, regardless of request headers. */
export function readKnowledgeSearchBody(stream: Readable): Promise<KnowledgeSearchBody> {
  return readBoundedAiBody(stream).then(parseKnowledgeSearchBody);
}

export function readBoundedAiBody(stream: Readable): Promise<Buffer> {
  return readBoundedBody(stream, 4096).catch(() => {
    throw new Error('INVALID_KNOWLEDGE_BODY');
  });
}

/** Validates a bounded UTF-8 generation body before any business or model work. */
export function parseKnowledgeSearchBody(bytes: Uint8Array): KnowledgeSearchBody {
  if (bytes.length === 0) return {};
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
  const body = value as Record<string, unknown>;
  const keys = Object.keys(body);
  if (keys.some(key => key !== 'search_phrase' && key !== 'skill_id' && key !== 'expected_sequence') ||
      hasTooManyAiBodyMembers(text, keys.length)) throw new Error('INVALID_KNOWLEDGE_BODY');
  const result: KnowledgeSearchBody = {};
  if (Object.hasOwn(body, 'expected_sequence')) {
    if (!isExpectedAiSequence(body.expected_sequence)) throw new Error('INVALID_KNOWLEDGE_BODY');
    result.expectedSequence = body.expected_sequence;
  }
  if (Object.hasOwn(body, 'skill_id')) {
    if (body.skill_id !== 'knowledge-answer') throw new Error('INVALID_KNOWLEDGE_BODY');
    result.skillId = body.skill_id;
  }
  if (Object.hasOwn(body, 'search_phrase')) {
    if (typeof body.search_phrase !== 'string' || !body.search_phrase.isWellFormed()) throw new Error('INVALID_KNOWLEDGE_BODY');
    const phrase = body.search_phrase.trim();
    if (!phrase || /[\u0000-\u001f\u007f]/.test(phrase) || Buffer.byteLength(phrase,'utf8') > 256) throw new Error('INVALID_KNOWLEDGE_BODY');
    result.phrase = phrase;
  }
  return result;
}

/** JSON syntax must be checked before counting top-level keys. */
export function hasTooManyAiBodyMembers(text: string, limit: number): boolean {
  let depth=0, fields=0, inString=false, escaped=false;
  for (const ch of text) {
    if (inString) {
      if (escaped) escaped=false;
      else if (ch==='\\') escaped=true;
      else if (ch==='"') inString=false;
    } else if (ch==='"') inString=true;
    else if (ch==='{' || ch==='[') depth++;
    else if (ch==='}' || ch===']') depth--;
    else if (ch===':' && depth===1 && ++fields>limit) return true;
  }
  return false;
}

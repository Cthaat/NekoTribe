import { credential, embeddingBatch } from './config.mjs';
import { requestJson } from './http.mjs';

export function validVector(vector, dimensions) {
  return Array.isArray(vector) && vector.length === dimensions &&
    vector.every(number => typeof number === 'number' && Number.isFinite(Math.fround(number))) &&
    vector.some(number => Math.fround(number) !== 0);
}

export function assertMatchingProbe(profile, expected, actual) {
  const dimensions = profile.dimensions;
  if (!validVector(expected, dimensions) || !validVector(actual, dimensions)) {
    throw Error('EMBEDDING_REVISION_MISMATCH');
  }
  let dot = 0, expectedSquared = 0, actualSquared = 0;
  for (let i = 0; i < dimensions; i++) {
    const a = Math.fround(expected[i]), b = Math.fround(actual[i]);
    dot += a * b;
    expectedSquared += a * a;
    actualSquared += b * b;
  }
  // Cosine collections store unit vectors. Compare direction to allow that
  // normalization and small floating-point differences from the provider.
  const similarity = dot / (Math.sqrt(expectedSquared) * Math.sqrt(actualSquared));
  if (!Number.isFinite(similarity) || similarity < 0.999999) {
    throw Error('EMBEDDING_REVISION_MISMATCH');
  }
}

export async function embed(profile, texts, {signal, timeout=20000} = {}) {
  if (!Array.isArray(texts) || texts.length < 1 || texts.length > embeddingBatch ||
      texts.some(text => typeof text !== 'string' || !text.trim() || !text.isWellFormed() || Buffer.byteLength(text) > 3072)) throw Error('INVALID_EMBEDDING_INPUT');
  const ollama = profile.adapter === 'ollama';
  const headers = profile.keyEnv ? {authorization:`Bearer ${credential(process.env[profile.keyEnv])}`} : undefined;
  const response = await requestJson(`${profile.baseUrl}${ollama ? '/api/embed' : '/embeddings'}`, {
    method:'POST', headers, signal, timeout, limit:2 * 1024 * 1024,
    body:{model:profile.model,input:texts,...(ollama ? {truncate:false} : {encoding_format:'float'})},
  });
  if (response?.model !== profile.model) throw Error('EMBEDDING_MODEL_MISMATCH');
  const vectors = ollama ? response?.embeddings : new Array(texts.length);
  if (!ollama) {
    if (!Array.isArray(response?.data) || response.data.length !== texts.length) throw Error('INVALID_VECTORS');
    for (const item of response.data) {
      if (!Number.isInteger(item?.index) || item.index < 0 || item.index >= texts.length || Object.hasOwn(vectors,item.index)) throw Error('INVALID_VECTORS');
      vectors[item.index] = item.embedding;
    }
  }
  if (!Array.isArray(vectors) || vectors.length !== texts.length ||
      vectors.some(vector => !validVector(vector,profile.dimensions))) throw Error('INVALID_VECTORS');
  return vectors;
}

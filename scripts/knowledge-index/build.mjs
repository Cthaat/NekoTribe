import { createHash } from 'node:crypto';
import { chunkSize, chunkOverlap, embeddingBatch, verificationText } from './config.mjs';
import { assertMatchingProbe, embed } from './embedding.mjs';
import { indexStore } from './qdrant.mjs';
import { checkOracleSources, oracleSnapshot } from './oracle.mjs';

function* chunks(content) {
  const characters = Array.from(content);
  for (let start=0,index=0; start<characters.length; start+=chunkSize-chunkOverlap,index++) {
    const end = start+chunkSize;
    const text = characters.slice(start,end).join('');
    if (text.trim()) yield {index,text};
    if (end >= characters.length) break;
  }
}

function addSource(hash, {kind,id,version}) {
  hash.update(`${kind}:${id}:${version}\n`);
}

export async function snapshotDigest({signal,onProgress} = {}) {
  const digest = createHash('sha256');
  let sources = 0;
  for await (const source of oracleSnapshot({signal})) {
    addSource(digest,source);
    if (++sources % 128 === 0) onProgress?.({stage:'scanning-sources',sources});
  }
  return digest.digest('hex');
}

function pointId({kind,id,version,chunk}) {
  const bytes = createHash('sha256').update(`neko-knowledge-point-v1:${kind}:${id}:${version}:${chunk}`).digest();
  bytes[6] = (bytes[6] & 15) | 128;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.subarray(0,16).toString('hex');
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}

export async function buildIndex(profile, previous, {signal,onProgress} = {}) {
  signal?.throwIfAborted();
  onProgress?.({stage:'checking-sources'});
  const {ready} = await checkOracleSources({signal});
  signal?.throwIfAborted();
  if (!ready) throw Error('ORACLE_SOURCES_NOT_READY');

  onProgress?.({stage:'checking-model'});
  const [probe] = await embed(profile,[verificationText],{signal});
  if (previous) await previous.checkEmbedding(probe,signal);
  signal?.throwIfAborted();
  const store = indexStore(profile);
  onProgress?.({stage:'creating-collection'});
  await store.create(signal);
  const batch = [];
  const digest = createHash('sha256');
  let points = 0, sources = 0, reused = 0;
  const report = stage => onProgress?.({stage,sources,points,reused});
  report('writing-points');
  async function writeBatch() {
    if (!batch.length) return;
    signal?.throwIfAborted();
    const cached = previous ? await previous.reuseVectors(batch.map(entry=>entry.id),signal) : new Map();
    const missing = batch.filter(entry=>!cached.has(entry.id));
    const reusedInBatch = cached.size;
    if (missing.length) {
      const [batchProbe,...vectors] = await embed(profile,[verificationText,...missing.map(entry=>entry.text)],{signal});
      assertMatchingProbe(profile,probe,batchProbe);
      for (const [index,entry] of missing.entries()) cached.set(entry.id,vectors[index]);
    }
    signal?.throwIfAborted();
    await store.upsert(batch.map(({id,payload})=>({id,vector:cached.get(id),payload})),signal);
    points += batch.length;
    reused += reusedInBatch;
    batch.length = 0;
    report('writing-points');
  }
  for await (const {kind,id,version,content} of oracleSnapshot({signal})) {
    addSource(digest,{kind,id,version});
    let indexed = false;
    for (const {index,text} of chunks(content)) {
      if (!indexed) {
        indexed = true;
        sources++;
      }
      const payload = {kind,id,version,chunk:index};
      batch.push({id:pointId(payload),text,payload});
      if (batch.length === embeddingBatch-1) await writeBatch();
    }
  }
  await writeBatch();
  signal?.throwIfAborted();
  report('verifying-collection');
  await store.seal(points,probe,digest.digest('hex'),signal);
  signal?.throwIfAborted();
  return {collection:profile.collection,sources,points,reused};
}

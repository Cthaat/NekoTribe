import { baseUrl, credential, groupSourceKinds, profileFingerprint, validCandidate, versionPattern } from './config.mjs';
import { assertMatchingProbe, validVector } from './embedding.mjs';
import { requestJson } from './http.mjs';

const markerId = '00000000-0000-4000-8000-000000000000';

export function indexStoreConnection() {
  const url = baseUrl(process.env.AI_INDEX_QDRANT_URL);
  const key = process.env.AI_INDEX_QDRANT_KEY;
  const headers = key === undefined ? undefined : {'api-key':credential(key)};
  return {url,headers};
}

export function indexStore(profile) {
  const {url,headers} = indexStoreConnection();
  const root = `${url}/collections/${profile.collection}`;
  const fingerprint = profileFingerprint(profile);

  async function call(path, options) {
    const signal = options?.signal;
    signal?.throwIfAborted();
    const response = await requestJson(root+path, {...options,headers}).catch(error => {
      signal?.throwIfAborted();
      throw error;
    });
    signal?.throwIfAborted();
    if (response?.status !== 'ok' || !Object.hasOwn(response,'result')) throw Error('INDEX_RESPONSE_INVALID');
    return response.result;
  }

  async function count(signal) {
    const result = await call('/points/count',{method:'POST',body:{exact:true},signal});
    if (!Number.isSafeInteger(result?.count) || result.count < 0) throw Error('INDEX_COUNT_INVALID');
    return result.count;
  }

  async function hasExpectedPoints(points, signal) {
    return await count(signal) === points + 1;
  }

  async function exists(signal) {
    const result = await call('/exists',{signal});
    if (typeof result?.exists !== 'boolean') throw Error('INDEX_RESPONSE_INVALID');
    return result.exists;
  }

  async function upsert(points, signal) {
    const result = await call('/points?wait=true',{method:'PUT',body:{points},timeout:30000,signal});
    if (result?.status !== 'completed') throw Error('INDEX_WRITE_INCOMPLETE');
  }

  async function search(vector, limit, signal, {includeGroups = true} = {}) {
    const pointLimit = Math.min(256,limit*12);
    const excluded = [{has_id:[markerId]}];
    if (!includeGroups) excluded.push({key:'kind',match:{any:groupSourceKinds}});
    const result = await call('/points/query',{
      method:'POST',signal,timeout:5000,limit:131072,
      body:{query:vector,limit:pointLimit,with_payload:['kind','id','version','chunk'],with_vector:false,
        filter:{must_not:excluded}},
    });
    if (!Array.isArray(result?.points) || result.points.length > pointLimit) throw Error('INDEX_RESPONSE_INVALID');
    const seen = new Set(), candidates = [];
    for (const point of result.points) {
      const payload = point?.payload;
      if (!validCandidate(payload)) throw Error('INDEX_CANDIDATE_INVALID');
      const {kind,id,version,chunk} = payload;
      if (!includeGroups && groupSourceKinds.includes(kind)) throw Error('INDEX_CANDIDATE_INVALID');
      if (chunk !== undefined && (!Number.isInteger(chunk) || chunk < 0 || chunk > 102)) throw Error('INDEX_CANDIDATE_INVALID');
      const key = `${kind}:${id}`;
      if (!seen.has(key)) {
        seen.add(key);
        candidates.push({kind,id,version,...(chunk === undefined ? {} : {chunk})});
        if (candidates.length === limit) break;
      }
    }
    return candidates;
  }

  function markerInfo(marker) {
    const payload = marker?.payload;
    if (marker?.id !== markerId || payload?.fingerprint !== fingerprint ||
        !Number.isSafeInteger(payload.points) || payload.points < 0 || payload.points >= Number.MAX_SAFE_INTEGER ||
        (payload.snapshot !== undefined && (typeof payload.snapshot !== 'string' || !versionPattern.test(payload.snapshot)))) throw Error('INDEX_PROFILE_MISMATCH');
    return {points:payload.points,snapshot:payload.snapshot};
  }

  async function checkMarker(signal) {
    return markerInfo(await call(`/points/${markerId}`,{signal,timeout:3000}));
  }

  async function readEmbeddingMarker(signal, {allowMissing = false} = {}) {
    const rows = await call('/points', {
      method:'POST', signal, timeout:3000, limit:262144,
      body:{ids:[markerId],with_payload:true,with_vector:true},
    });
    if (allowMissing && Array.isArray(rows) && rows.length === 0) return null;
    if (!Array.isArray(rows) || rows.length !== 1) throw Error('INDEX_PROFILE_MISMATCH');
    const marker = rows[0];
    const info = markerInfo(marker);
    if (!validVector(marker.vector,profile.dimensions)) throw Error('EMBEDDING_REVISION_MISMATCH');
    return {...info,vector:marker.vector};
  }

  async function checkEmbedding(probe, signal) {
    const {vector,...info} = await readEmbeddingMarker(signal);
    assertMatchingProbe(profile,vector,probe);
    return info;
  }

  return {
    exists, hasExpectedPoints,
    async create(signal) {
      if (await exists(signal)) throw Error('INDEX_COLLECTION_EXISTS');
      signal?.throwIfAborted();
      if (await call('',{method:'PUT',body:{vectors:{size:profile.dimensions,distance:'Cosine'}},signal}) !== true) throw Error('INDEX_CREATE_FAILED');
    },
    upsert, search, checkMarker, readEmbeddingMarker, checkEmbedding,
    async removeRetired() {
      if (!await exists()) return null;
      try {
        await checkMarker();
      } catch (error) {
        if (error.message === 'NOT_FOUND') return 'INDEX_MARKER_MISSING';
        if (error.message === 'INDEX_PROFILE_MISMATCH') return 'INDEX_PROFILE_MISMATCH';
        throw error;
      }
      if (await call('',{method:'DELETE',timeout:30000}) !== true) throw Error('INDEX_DELETE_FAILED');
      return null;
    },
    async reuseVectors(ids, signal) {
      const rows = await call('/points',{method:'POST',limit:2*1024*1024,signal,
        body:{ids,with_payload:false,with_vector:true}});
      if (!Array.isArray(rows) || rows.length > ids.length) throw Error('INDEX_RESPONSE_INVALID');
      const result = new Map();
      for (const row of rows) {
        if (!ids.includes(row?.id) || result.has(row.id) || !validVector(row.vector,profile.dimensions)) throw Error('INVALID_VECTORS');
        result.set(row.id,row.vector);
      }
      return result;
    },
    async seal(points, probe, snapshot, signal) {
      if (await count(signal) !== points || (await search(probe,1,signal)).length !== (points > 0 ? 1 : 0)) throw Error('INDEX_VERIFICATION_FAILED');
      signal?.throwIfAborted();
      await upsert([{id:markerId,vector:probe,payload:{fingerprint,points,snapshot}}],signal);
    },
    async verify(probe, signal) {
      const {points} = await checkEmbedding(probe,signal);
      if (!await hasExpectedPoints(points,signal) || (await search(probe,1,signal)).length !== (points > 0 ? 1 : 0)) throw Error('INDEX_VERIFICATION_FAILED');
      return points;
    },
  };
}

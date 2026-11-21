import { randomUUID } from 'node:crypto';
import { profileFingerprint, readProfile, verificationText } from './config.mjs';
import { assertMatchingProbe, embed } from './embedding.mjs';
import { indexStore } from './qdrant.mjs';
import { publish, recover } from './lifecycle.mjs';

export async function syncIndex(activePath, loadBuilder = () => import('./build.mjs'), {signal,onProgress} = {}) {
  signal?.throwIfAborted();
  await recover(activePath);
  signal?.throwIfAborted();
  const profile = await readProfile(activePath);
  const expected = profileFingerprint(profile);
  const previous = indexStore(profile);
  onProgress?.({stage:'checking-active'});
  const available = await previous.exists(signal);
  signal?.throwIfAborted();
  const { buildIndex, snapshotDigest } = await loadBuilder();
  let reusable;
  let incomplete = false;
  if (available) {
    const marker = await previous.readEmbeddingMarker(signal,{allowMissing:true});
    if (marker) {
      const [probe] = await embed(profile,[verificationText],{signal});
      assertMatchingProbe(profile,marker.vector,probe);
    }
    incomplete = !marker || !await previous.hasExpectedPoints(marker.points,signal);
    if (marker && !incomplete && marker.snapshot) {
      onProgress?.({stage:'scanning-sources',sources:0});
      if (marker.snapshot === await snapshotDigest({signal,onProgress})) {
        const current = await readProfile(activePath);
        signal?.throwIfAborted();
        if (profileFingerprint(current) !== expected) throw Error('ACTIVE_PROFILE_CHANGED');
        return {changed:false,collection:profile.collection};
      }
      reusable = previous;
    }
  }

  signal?.throwIfAborted();
  const next = {...profile,collection:`neko_knowledge_sync_${randomUUID().replaceAll('-','')}`};
  const result = await buildIndex(next,reusable,{signal,onProgress});
  signal?.throwIfAborted();
  // Once publication starts, allow its journal and lock to finish together.
  onProgress?.({stage:'publishing',points:result.points,sources:result.sources,reused:result.reused});
  await publish(activePath,next,{expected,managed:true});
  return {changed:true,previous:profile.collection,...result,
    ...(incomplete ? {recoveredIncompleteCollection:true} : {}),
    ...(!available ? {recoveredMissingCollection:true} : {})};
}

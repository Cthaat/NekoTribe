import { realpath } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { profileFingerprint, readProfile, verificationText } from './config.mjs';
import { embed } from './embedding.mjs';
import { activeProfileFingerprint, publish, recover } from './lifecycle.mjs';
import { indexStore } from './qdrant.mjs';

export async function verifyIndex(profile, {signal, onProgress} = {}) {
  signal?.throwIfAborted();
  onProgress?.({stage:'checking-candidate'});
  const [vector] = await embed(profile, [verificationText], {signal});
  const points = await indexStore(profile).verify(vector,signal);
  signal?.throwIfAborted();
  return {collection:profile.collection, points};
}

export async function activateIndex(activePath, profile, {expected, signal, onProgress} = {}) {
  signal?.throwIfAborted();
  if (expected === undefined) expected = await activeProfileFingerprint(activePath,profile.scope);
  const result = await verifyIndex(profile,{signal,onProgress});
  signal?.throwIfAborted();
  onProgress?.({stage:'publishing',points:result.points});
  await publish(activePath, profile, {expected});
  return result;
}

async function checkActiveCollection(activePath, current, {signal,onProgress}) {
  onProgress?.({stage:'checking-active'});
  const store = indexStore(current);
  const {points} = await store.checkMarker(signal);
  if (!await store.hasExpectedPoints(points,signal)) throw Error('INDEX_INCOMPLETE');
  const expected = await activeProfileFingerprint(activePath);
  signal?.throwIfAborted();
  if (expected !== profileFingerprint(current)) throw Error('ACTIVE_PROFILE_CHANGED');
  return {outcome:'already-active', collection:current.collection, points};
}

async function buildAndActivate(activePath, profile, {expected, signal, onProgress, loadBuilder = () => import('./build.mjs')}) {
  onProgress?.({stage:'checking-candidate'});
  const exists = await indexStore(profile).exists(signal);
  if (!exists) {
    const {buildIndex} = await loadBuilder();
    await buildIndex(profile, undefined, {signal,onProgress});
  }
  signal?.throwIfAborted();
  const result = await activateIndex(activePath, profile, {expected, signal, onProgress});
  return {outcome:exists ? 'activated-existing' : 'built-and-activated', ...result};
}

export async function bootstrapIndex(activePath, initialPath, {
  signal, loadBuilder, onProgress,
} = {}) {
  signal?.throwIfAborted();
  const {active} = await recover(activePath);
  if (active !== null) {
    return checkActiveCollection(activePath, await readProfile(activePath), {signal,onProgress});
  }
  return buildAndActivate(activePath, await readProfile(initialPath), {expected:null,signal,loadBuilder,onProgress});
}

export async function switchIndex(activePath, profile, {signal, loadBuilder, onProgress} = {}) {
  signal?.throwIfAborted();
  const {active} = await recover(activePath);
  if (active === null) throw Error('ACTIVE_PROFILE_REQUIRED');
  const current = await readProfile(activePath);
  const expected = profileFingerprint(current);
  if (profile.collection === current.collection) {
    if (profileFingerprint(profile) !== expected) throw Error('INDEX_COLLECTION_IN_USE');
    return checkActiveCollection(activePath,current,{signal,onProgress});
  }
  return buildAndActivate(activePath, profile, {expected,signal,loadBuilder,onProgress});
}

async function activeLocation(path) {
  const absolute = resolve(path);
  const canonical = (target, fallback) => realpath(target).catch(error => {
    if (error?.code !== 'ENOENT') throw error;
    return fallback;
  });
  const parent = await canonical(dirname(absolute),dirname(absolute));
  const target = join(parent,basename(absolute));
  const location = await canonical(target,target);
  return process.platform === 'win32' ? location.toLowerCase() : location;
}

export async function rebuildGroupIndex(publicPath, groupPath, profilePath, {signal,onProgress} = {}) {
  signal?.throwIfAborted();
  if (!groupPath) throw Error('GROUP_ACTIVE_PROFILE_REQUIRED');
  if (publicPath) {
    const [publicLocation,groupLocation] = await Promise.all([activeLocation(publicPath),activeLocation(groupPath)]);
    if (publicLocation === groupLocation) throw Error('INDEX_ACTIVE_PROFILE_CONFLICT');
  }
  signal?.throwIfAborted();
  const profile = await readProfile(profilePath,'group');
  const expected = await activeProfileFingerprint(groupPath,'group');
  const {buildIndex} = await import('./build.mjs');
  const result = await buildIndex(profile,undefined,{signal,onProgress});
  await activateIndex(groupPath,profile,{expected,signal,onProgress});
  return result;
}

import {randomUUID} from 'node:crypto';
import {mkdir,readFile,rename,rm,rmdir,writeFile} from 'node:fs/promises';
import {parseProfile,profileFingerprint,readProfile} from './config.mjs';
import {indexStore} from './qdrant.mjs';

const managedName = /^neko_knowledge_sync_[0-9a-f]{32}$/;
const day = 86400000;
const maxLifecycleBytes = 4*1024*1024;

export async function writeJson(path, value) {
  const staged = `${path}.${randomUUID()}.new`;
  const content = `${JSON.stringify(value,null,2)}\n`;
  if (Buffer.byteLength(content) > maxLifecycleBytes) throw Error('COLLECTION_STATE_TOO_LARGE');
  await writeFile(staged,content,{flag:'wx',mode:0o600});
  try { await rename(staged,path); }
  finally { await rm(staged,{force:true}); }
}

async function withActivationLock(activePath, action) {
  if (!activePath) throw Error('ACTIVE_PROFILE_REQUIRED');
  const lock = `${activePath}.lock`;
  try { await mkdir(lock); }
  catch (error) {
    if (error?.code === 'EEXIST') throw Error('ACTIVATION_LOCKED');
    throw error;
  }
  try { return await action(); }
  finally { await rmdir(lock); }
}

const ledgerPath = activePath => `${activePath}.collections.json`;
const publicationPath = activePath => `${activePath}.publication.json`;

async function readOptional(path, reader) {
  try { return await reader(path); }
  catch (error) {
    if (error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

async function readLifecycleJson(path) {
  const file = await readFile(path);
  if (file.length > maxLifecycleBytes) throw Error('COLLECTION_STATE_TOO_LARGE');
  return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(file));
}

function validateLedger(ledger) {
  if (ledger?.version !== 1 || !Array.isArray(ledger.collections)) throw Error('COLLECTION_LEDGER_INVALID');
  const seen = new Set();
  for (const entry of ledger.collections) {
    const profile = parseProfile(entry?.profile);
    if (!managedName.test(profile.collection) || seen.has(profile.collection) ||
        (entry.retiredAt !== null && (!Number.isSafeInteger(entry.retiredAt) || entry.retiredAt < 1))) throw Error('COLLECTION_LEDGER_INVALID');
    seen.add(profile.collection);
    entry.profile = profile;
  }
  return ledger;
}

async function readLedger(activePath) {
  const ledger = await readOptional(ledgerPath(activePath), readLifecycleJson);
  return ledger === undefined ? {version:1,collections:[]} : validateLedger(ledger);
}

const fingerprintOf = profile => profile === undefined ? null : profileFingerprint(profile);

export async function activeProfileFingerprint(activePath, scope) {
  if (!activePath) throw Error('ACTIVE_PROFILE_REQUIRED');
  return fingerprintOf(await readOptional(activePath, path => readProfile(path,scope)));
}

async function reconcilePublication(activePath, current) {
  const path = publicationPath(activePath);
  const pending = await readOptional(path, readLifecycleJson);
  if (pending === undefined) return 'none';
  const hash = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
  if (pending?.version !== 1 || !hash(pending.next) ||
      (pending.previous !== null && !hash(pending.previous)) ||
      pending.previous === pending.next) throw Error('PUBLICATION_INVALID');

  const ledger = validateLedger(pending.ledger);
  const active = fingerprintOf(current);
  if (active !== pending.next && active !== pending.previous) throw Error('PUBLICATION_CONFLICT');
  if (active === pending.next) await writeJson(ledgerPath(activePath),ledger);
  await rm(path);
  return active === pending.next ? 'committed' : 'discarded';
}

export async function recover(activePath) {
  return withActivationLock(activePath, async () => {
    const current = await readOptional(activePath, readProfile);
    const publication = await reconcilePublication(activePath,current);
    return {active:current?.collection ?? null,publication};
  });
}

export async function publish(activePath, profile, {expected,managed=false} = {}) {
  return withActivationLock(activePath, async ()=>{
    const current = await readOptional(activePath, path => readProfile(path,profile.scope));
    await reconcilePublication(activePath,current);
    const previousFingerprint = fingerprintOf(current);
    if (expected !== undefined && previousFingerprint !== expected) throw Error('ACTIVE_PROFILE_CHANGED');
    // Pruning uses this same lock. Confirm the target survived the earlier verification.
    await indexStore(profile).checkMarker();

    const ledger = await readLedger(activePath);
    const previous = ledger.collections.find(entry=>entry.profile.collection === current?.collection);
    const next = ledger.collections.find(entry=>entry.profile.collection === profile.collection);
    if (previous && profileFingerprint(previous.profile) !== profileFingerprint(current)) throw Error('COLLECTION_LEDGER_INVALID');
    if (next && profileFingerprint(next.profile) !== profileFingerprint(profile)) throw Error('COLLECTION_LEDGER_INVALID');
    if (previous && previous !== next) previous.retiredAt = Date.now();
    if (next) next.retiredAt = null;
    if (managed && !next) {
      if (!managedName.test(profile.collection)) throw Error('COLLECTION_LEDGER_INVALID');
      ledger.collections.push({profile,retiredAt:null});
    }
    const nextFingerprint = profileFingerprint(profile);
    const ledgerChanged = previous || next || managed;
    if (ledgerChanged && previousFingerprint !== nextFingerprint) {
      await writeJson(publicationPath(activePath),{
        version:1,previous:previousFingerprint,next:nextFingerprint,ledger,
      });
      await writeJson(activePath,profile);
      await reconcilePublication(activePath,await readProfile(activePath));
      return;
    }
    if (ledgerChanged) await writeJson(ledgerPath(activePath),ledger);
    await writeJson(activePath,profile);
  });
}

export async function rollbackTarget(activePath, collection) {
  return withActivationLock(activePath, async () => {
    const current = await readOptional(activePath, readProfile);
    await reconcilePublication(activePath,current);
    const {collections} = await readLedger(activePath);
    const profile = collections.find(entry=>entry.profile.collection === collection)?.profile;
    if (!profile) throw Error('RETAINED_COLLECTION_NOT_FOUND');
    return {profile,expected:fingerprintOf(current)};
  });
}

export async function prune(activePath, apply, {signal} = {}) {
  const days = Number(process.env.AI_INDEX_RETENTION_DAYS ?? 7);
  const keep = Number(process.env.AI_INDEX_KEEP_RETIRED ?? 2);
  if (!Number.isInteger(days) || days < 1 || days > 365 || !Number.isInteger(keep) || keep < 1 || keep > 100) throw Error('INVALID_RETENTION');
  return withActivationLock(activePath, async ()=>{
    const active = await readProfile(activePath);
    await reconcilePublication(activePath,active);
    const ledger = await readLedger(activePath);
    const cutoff = Date.now()-days*day;
    const retired = ledger.collections.filter(entry=>entry.retiredAt !== null && entry.profile.collection !== active.collection);
    retired.sort((a,b)=>b.retiredAt-a.retiredAt);
    const eligible = retired.slice(keep).filter(entry=>entry.retiredAt <= cutoff);
    const removed = [];
    const skipped = [];
    if (apply) {
      for (const entry of eligible) {
        if (signal?.aborted) break;
        const collection = entry.profile.collection;
        // The ledger proves this collection was owned by the synchronizer. Qdrant verifies its marker.
        const code = await indexStore(entry.profile).removeRetired();
        if (code) {
          skipped.push({collection,code});
          continue;
        }
        removed.push(collection);
        ledger.collections = ledger.collections.filter(item=>item !== entry);
        await writeJson(ledgerPath(activePath),ledger);
      }
    }
    return {active:active.collection,eligible:eligible.map(entry=>entry.profile.collection),removed,skipped};
  });
}

import { randomUUID } from 'node:crypto';
import type Redis from 'ioredis';

const tagTtlSeconds = 7 * 24 * 60 * 60;

export async function readCacheTagVersions(redis: Redis, keys: string[]): Promise<string[]> {
  if (keys.length === 0) return [];
  const values = await redis.mget(...keys);
  return Promise.all(keys.map(async (key, index) => {
    const current = values[index];
    if (current !== null && current !== undefined) return current;

    // A tag can be evicted while its cached payload is still present. Mint a
    // fresh generation so an older payload can never become current again.
    const generation = randomUUID();
    if (await redis.set(key, generation, 'EX', tagTtlSeconds, 'NX') === 'OK') return generation;
    const winner = await redis.get(key);
    if (winner === null) throw new Error('Cache tag disappeared during initialization');
    return winner;
  }));
}

export async function rotateCacheTags(redis: Redis, keys: string[]): Promise<void> {
  const generation = randomUUID();
  const pipeline = redis.pipeline();
  for (const key of keys) pipeline.set(key, generation, 'EX', tagTtlSeconds);
  const results = await pipeline.exec();
  if (!results || results.length !== keys.length || results.some(([error, value]) => error || value !== 'OK')) {
    throw new Error('Cache tag rotation failed');
  }
}

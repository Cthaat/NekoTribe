import Redis from 'ioredis';
import { resolveRedisOptions } from './redis-config';
import type { RealtimeTransport } from './realtime-subscription';

export function createRedisRealtimeTransport(): RealtimeTransport {
  const client = new Redis({
    ...resolveRedisOptions(),
    lazyConnect: true,
    enableOfflineQueue: false,
    maxRetriesPerRequest: 0,
    autoResubscribe: false,
    autoResendUnfulfilledCommands: false,
    retryStrategy: () => null,
    commandTimeout: 1500,
    connectTimeout: 1500
  });
  let closed = false;
  let started = false;
  let onMessage: ((channel: string, raw: string) => void) | undefined;
  let onLost: (() => void) | undefined;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  const unavailable = () => new Error('Realtime subscription unavailable');
  const lost = () => { if (!closed) onLost?.(); };
  const message = (channel: string, raw: string) => {
    if (!closed && typeof channel === 'string' && typeof raw === 'string') onMessage?.(channel, raw);
  };
  // Error handling is installed before connect and never logs driver details.
  client.on('error', lost);
  client.on('close', lost);
  client.on('end', lost);
  client.on('message', message);
  return {
    async connect(received, disconnected) {
      if (closed || started) throw unavailable();
      started = true;
      onMessage = received;
      onLost = disconnected;
      try { await client.connect(); } catch { throw unavailable(); }
      if (closed || client.status !== 'ready') throw unavailable();
      let pinging = false;
      heartbeat = setInterval(() => {
        if (closed || pinging) return;
        pinging = true;
        void client.ping().catch(lost).finally(() => { pinging = false; });
      }, 30_000);
      heartbeat.unref?.();
    },
    async subscribe(channels) {
      if (closed) throw unavailable();
      try { await client.subscribe(...channels); } catch { throw unavailable(); }
      if (closed) throw unavailable();
    },
    async unsubscribe(channels) {
      if (closed) throw unavailable();
      try { await client.unsubscribe(...channels); } catch { throw unavailable(); }
      if (closed) throw unavailable();
    },
    close() {
      if (closed) return;
      closed = true;
      if (heartbeat) clearInterval(heartbeat);
      heartbeat = undefined;
      onMessage = undefined;
      onLost = undefined;
      client.off('message', message);
      client.off('close', lost);
      client.off('end', lost);
      // Keep a no-op error listener for late driver events until client GC.
      try { client.disconnect(false); } catch { /* Already disconnected. */ }
    }
  };
}

import { createClient } from 'redis';
import { randomUUID } from 'node:crypto';

export function createCache(url, ttl = 60) {
  if (!Number.isInteger(ttl) || ttl < 1) throw new Error('CACHE_TTL_SECONDS must be a positive integer.');
  const client = createClient({ url, disableOfflineQueue: true,
    socket: { connectTimeout: 500, reconnectStrategy: retries => Math.min(100 + retries * 100, 1000) } });
  client.on('error', () => {}); // Redis is optional; never log connection credentials.
  void client.connect().catch(() => {});
  const prefix = `recruitment:${randomUUID()}:applicant:`;
  const dirty = new Set();
  const key = id => `${prefix}${id}:application-count`;
  async function command(fn) {
    if (!client.isReady) throw new Error('Cache unavailable');
    return fn(client.withCommandOptions({ abortSignal: AbortSignal.timeout(500) }));
  }
  return {
    key, ttl, client,
    async get(id) {
      // A failed invalidation must complete before this process trusts that key again.
      if (dirty.has(id)) { await command(c => c.del(key(id))); dirty.delete(id); }
      return command(c => c.get(key(id)));
    },
    async set(id, data) {
      await command(c => c.set(key(id), JSON.stringify(data), { EX: ttl }));
    },
    async invalidate(id) {
      dirty.add(id);
      await command(c => c.del(key(id)));
      dirty.delete(id);
    },
    get ready() { return client.isReady; },
    close() { if (client.isOpen) client.destroy(); }
  };
}

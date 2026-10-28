import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { request as httpRequest } from 'node:http';
import sql from 'mssql';
import { createCache } from '../cache.js';
import { createApp } from '../app.js';
import { databaseConfig } from '../config.js';

const suffix = `${Date.now()}_${process.pid}`;
const database = `RecruitmentRedisTest_${suffix}`;
const container = `recruitment-redis-test-${suffix}`;
let admin, pool, cache, server, token, base, original;
function podman(...args) { return execFileSync(process.env.CONTAINER_ENGINE || 'podman', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }
async function until(fn, timeout = 6000) { const start = Date.now(); while (!fn()) { if (Date.now() - start > timeout) throw new Error('Timed out waiting for Redis'); await delay(50); } }
async function call(path, method = 'GET', body, customToken = token) {
  const res = await fetch(base + path, { method, headers: { Authorization: `Bearer ${customToken}`, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(4000) });
  return { status: res.status, cache: res.headers.get('X-Cache'), key: res.headers.get('X-Cache-Key'), data: await res.json() };
}
const count = id => call(`/api/applicants/${id}/application-count`);
const clear = id => call(`/api/applicants/${id}/cache`, 'POST', {});
const apply = (id, job, skill) => call(`/api/applicants/${id}/applications`, 'POST', { job_ad_id: job, skill_id: skill });
async function options(id) { return (await call(`/api/applicants/${id}/options`)).data; }
async function liveSnapshot() {
  return (await admin.request().query(`
    SELECT (SELECT COUNT(*) FROM RecruitmentDb.dbo.APPLICATION) AS applications,
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM RecruitmentDb.dbo.APPLICATION) AS application_hash,
      (SELECT COUNT(*) FROM RecruitmentDb.dbo.APPLICATION_STATUS_EVENT) AS events,
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM RecruitmentDb.dbo.APPLICATION_STATUS_EVENT) AS event_hash,
      (SELECT COUNT(*) FROM RecruitmentDb.dbo.APPLICANT_SKILL) AS skills,
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM RecruitmentDb.dbo.APPLICANT_SKILL) AS skill_hash;`)).recordset[0];
}
async function runBatches(connection, content) {
  for (const batch of content.split(/^GO\s*$/mi).filter(s => s.trim())) await connection.request().batch(batch);
}
before(async () => {
  admin = await new sql.ConnectionPool(databaseConfig('master')).connect();
  original = await liveSnapshot();
  const fixture = (await readFile(new URL('../sql/schema-and-data.sql', import.meta.url), 'utf8')).replaceAll('RecruitmentDb', database);
  await runBatches(admin, fixture);
  pool = await new sql.ConnectionPool(databaseConfig(database)).connect();
  const workflows = (await readFile(new URL('../sql/workflows.sql', import.meta.url), 'utf8')).replaceAll('USE RecruitmentDb;', `USE [${database}];`);
  await runBatches(pool, workflows);
  // An explicit host port survives Docker restarts; automatic mappings may change.
  const probe = createServer();
  probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const redisPort = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  podman('run', '-d', '--name', container, '-p', `127.0.0.1:${redisPort}:6379`, '--memory', '128m', 'docker.io/library/redis:8-alpine', 'redis-server', '--save', '', '--appendonly', 'no');
  const port = Number(podman('port', container, '6379/tcp').split(':').at(-1));
  cache = createCache(`redis://127.0.0.1:${port}`, 2);
  await until(() => cache.ready);
  ({ server, token } = createApp({ pool, cache }));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  base = `http://127.0.0.1:${server.address().port}`;
}, { timeout: 60000 });
after(async () => {
  if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  cache?.close();
  await pool?.close();
  try { podman('rm', '-f', container); } catch { /* setup may have failed before creating Redis */ }
  if (admin) {
    try {
      if (original) assert.deepEqual(await liveSnapshot(), original, 'Live recruitment rows were modified');
    } finally {
      try {
        await admin.request().batch(`USE master; IF DB_ID(N'${database}') IS NOT NULL BEGIN ALTER DATABASE [${database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${database}]; END`);
      } finally { await admin.close(); }
    }
  }
});

test('first count is a real Redis MISS; second is HIT without another SQL count query', async () => {
  await clear(1);
  const before = (await call('/api/metrics')).data.sqlCountQueries;
  const first = await count(1), second = await count(1);
  assert.equal(first.status, 200); assert.equal(first.cache, 'MISS'); assert.equal(second.cache, 'HIT');
  assert.deepEqual(first.data, second.data); assert.equal(first.data.application_count, 2);
  assert.deepEqual(JSON.parse(await cache.client.get(first.key)), first.data);
  assert.equal((await call('/api/metrics')).data.sqlCountQueries, before + 1);
});
test('Redis TTL expires and the next request queries SQL again', async () => {
  await clear(1); const first = await count(1);
  assert.ok((await cache.client.ttl(first.key)) > 0);
  await delay(2150);
  assert.equal(await cache.client.get(first.key), null);
  assert.equal((await count(1)).cache, 'MISS');
});
test('successful atomic application creation invalidates and refreshes the count', async () => {
  await clear(1); const before = await count(1); await count(1);
  const available = await options(1);
  const result = await apply(1, available.jobs[0].job_ad_id, available.skills[0].skill_id);
  assert.equal(result.status, 201); assert.equal(result.data.cache_invalidated, true);
  assert.equal(await cache.client.get(before.key), null);
  const after = await count(1);
  assert.equal(after.cache, 'MISS'); assert.equal(after.data.application_count, before.data.application_count + 1);
  assert.equal((await count(1)).cache, 'HIT');
  const history = await pool.request().input('id', sql.Int, result.data.application_id)
    .query('SELECT status FROM dbo.APPLICATION_STATUS_EVENT WHERE application_id=@id;');
  assert.deepEqual(history.recordset.map(x => x.status), ['Submitted']);
});
test('duplicate skill rolls back application and status without evicting valid cache', async () => {
  await clear(2); await count(2);
  const available = await options(2);
  const skill = (await pool.request().query('SELECT TOP(1) skill_id FROM dbo.APPLICANT_SKILL WHERE applicant_id=2;')).recordset[0].skill_id;
  const result = await apply(2, available.jobs[0].job_ad_id, skill);
  assert.equal(result.status, 409);
  assert.equal((await count(2)).data.application_count, 2);
  assert.equal((await count(2)).cache, 'HIT');
  const orphan = await pool.request().input('job', sql.Int, available.jobs[0].job_ad_id)
    .query('SELECT COUNT(*) AS n FROM dbo.APPLICATION WHERE applicant_id=2 AND job_ad_id=@job;');
  assert.equal(orphan.recordset[0].n, 0);
});
test('duplicate application and foreign-key errors return useful responses', async () => {
  const available = await options(2);
  const existing = (await pool.request().query('SELECT TOP(1) job_ad_id FROM dbo.APPLICATION WHERE applicant_id=2;')).recordset[0].job_ad_id;
  assert.equal((await apply(2, existing, available.skills[0].skill_id)).status, 409);
  assert.equal((await apply(2, 2147483647, available.skills[0].skill_id)).status, 400);
});
test('zero counts cache correctly, missing applicants remain 404, invalid inputs are rejected', async () => {
  const newRow = await pool.request().query(`INSERT dbo.APPLICANT(full_name,date_of_birth,gender,city,registration_date)
    OUTPUT INSERTED.applicant_id VALUES (N'Isolated cache fixture','20000101',N'Female',N'Riyadh','20260101');`);
  const id = newRow.recordset[0].applicant_id;
  assert.equal((await count(id)).data.application_count, 0);
  assert.equal((await count(id)).cache, 'HIT');
  assert.equal((await count(2147483647)).status, 404);
  assert.equal((await count(0)).status, 400);
  assert.equal((await apply(1, 'invalid', 1)).status, 400);
});
test('local mutation token and same-origin checks block unauthorized calls', async () => {
  assert.equal((await call('/api/applicants/1/cache', 'POST', {}, 'bad')).status, 401);
  const response = await fetch(base + '/api/applicants/1/applications', { method: 'POST', headers: { Origin: 'https://example.com', Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: '{"job_ad_id":1,"skill_id":1}' });
  assert.equal(response.status, 403);
});
test('per-applicant locking prevents concurrent stale fills during a committed write', async () => {
  await clear(3);
  const available = await options(3);
  const results = await Promise.all([count(3), apply(3, available.jobs[0].job_ad_id, available.skills[0].skill_id), count(3)]);
  assert.equal(results[1].status, 201);
  assert.equal((await count(3)).data.application_count, 3);
  assert.equal((await count(3)).cache, 'HIT');
});
test('corrupt cache values fall back to SQL rather than returning invalid data', async () => {
  await cache.client.set(cache.key(4), '{invalid', { EX: 2 });
  const result = await count(4);
  assert.equal(result.status, 200); assert.equal(result.cache, 'BYPASS'); assert.equal(result.data.application_count, 2);
  assert.equal((await count(4)).cache, 'HIT');
});
test('real Redis outage uses SQL, allows committed writes, then recovers without stale counts', async () => {
  await clear(5); await count(5);
  const available = await options(5);
  podman('stop', '-t', '0', container);
  await until(() => !cache.ready);
  const start = Date.now(), fallback = await count(5);
  assert.equal(fallback.status, 200); assert.equal(fallback.cache, 'BYPASS'); assert.ok(Date.now() - start < 3000);
  const write = await apply(5, available.jobs[0].job_ad_id, available.skills[0].skill_id);
  assert.equal(write.status, 201); assert.equal(write.data.cache_invalidated, false);
  assert.equal((await count(5)).data.application_count, 3);
  podman('start', container); await until(() => cache.ready);
  // Simulate an old cached value surviving an outage: dirty-key recovery must evict it.
  await cache.client.set(cache.key(5), JSON.stringify(fallback.data), { EX: 60 });
  const fresh = await count(5);
  assert.equal(fresh.cache, 'MISS'); assert.equal(fresh.data.application_count, 3);
  assert.equal((await count(5)).cache, 'HIT');
});
test('original recruitment database row counts and checksums are unchanged', async () => {
  assert.deepEqual(await liveSnapshot(), original);
});

test('Prometheus metrics and Kubernetes probes work without widening application access', async () => {
  await count(1);
  const metrics = await fetch(base + '/metrics');
  assert.equal(metrics.status, 200);
  assert.match(metrics.headers.get('content-type'), /text\/plain|openmetrics/);
  const text = await metrics.text();
  assert.match(text, /recruitment_cache_hits_total \d+/);
  assert.match(text, /recruitment_sql_up 1/);
  assert.match(text, /recruitment_redis_ready 1/);
  assert.match(text, /recruitment_http_request_duration_seconds_bucket/);
  assert.match(text, /recruitment_process_resident_memory_bytes/);
  function hostStatus(path, host) {
    return new Promise((resolve, reject) => {
      const req = httpRequest(base + path, { headers: { Host: host } }, res => { res.resume(); resolve(res.statusCode); });
      req.on('error', reject); req.end();
    });
  }
  assert.equal(await hostStatus('/live', '10.244.0.5:3102'), 200);
  assert.equal(await hostStatus('/api/applicants/1/application-count', 'untrusted.example:3102'), 403);
});

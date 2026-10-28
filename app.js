import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import sql from 'mssql';
import { publicDirectory } from './config.js';
import { createMetrics } from './metrics.js';

export function createApp({ pool, cache, token = randomBytes(32).toString('hex') }) {
  const stats = { hits: 0, misses: 0, bypasses: 0, sqlCountQueries: 0, invalidations: 0 };
  const telemetry = createMetrics({ stats, cache, pool });
  const locks = new Map();
  // Single-process demo: serialize reads/writes per applicant to avoid stale-fill races.
  async function locked(id, fn) {
    const previous = locks.get(id) || Promise.resolve();
    let release;
    const next = new Promise(resolve => { release = resolve; });
    locks.set(id, next);
    await previous;
    try { return await fn(); }
    finally { release(); if (locks.get(id) === next) locks.delete(id); }
  }
  function send(res, status, data, headers = {}) {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', ...headers });
    res.end(JSON.stringify(data));
  }
  function positive(value) { return Number.isInteger(value) && value > 0 && value <= 2147483647; }
  function allowed(req) {
    const provided = Buffer.from(req.headers.authorization || '');
    const expected = Buffer.from(`Bearer ${token}`);
    return provided.length === expected.length && timingSafeEqual(provided, expected);
  }
  async function body(req) {
    if (!req.headers['content-type']?.startsWith('application/json')) throw Object.assign(new Error('Use application/json.'), { status: 415 });
    let raw = '';
    for await (const chunk of req) {
      raw += chunk;
      if (Buffer.byteLength(raw) > 4096) throw Object.assign(new Error('Request too large.'), { status: 413 });
    }
    try { return JSON.parse(raw); }
    catch { throw Object.assign(new Error('Invalid JSON.'), { status: 400 }); }
  }
  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'");
    try {
      const url = new URL(req.url, 'http://127.0.0.1');
      telemetry.observe(req, res, url.pathname);
      // Only direct local clients and this page may call the API. No cross-origin CORS.
      const host = req.headers.host || '';
      const probe = ['/live', '/health', '/metrics'].includes(url.pathname);
      const allowedHosts = (process.env.ALLOWED_HOSTS || '').split(',').filter(Boolean);
      if (!probe && !/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(host) && !allowedHosts.includes(host.split(':')[0])) return send(res, 403, { error: 'Local access only.' });
      if (req.headers['sec-fetch-site'] === 'cross-site' || (req.headers.origin && req.headers.origin !== `http://${host}`)) {
        return send(res, 403, { error: 'Cross-origin requests are not allowed.' });
      }
      if (req.method === 'GET' && ['/', '/app.js', '/style.css'].includes(url.pathname)) {
        const name = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
        let content = await readFile(`${publicDirectory}${name}`, 'utf8');
        if (name === 'index.html') content = content.replace('__TOKEN__', token);
        res.writeHead(200, { 'Content-Type': name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html; charset=utf-8' });
        return res.end(content);
      }
      if (req.method === 'GET' && url.pathname === '/live') return send(res, 200, { api: 'alive' });
      if (req.method === 'GET' && url.pathname === '/metrics') {
        res.writeHead(200, { 'Content-Type': telemetry.registry.contentType });
        return res.end(await telemetry.registry.metrics());
      }
      if (req.method === 'GET' && url.pathname === '/health') {
        await pool.request().query('SELECT 1 AS ok;');
        return send(res, 200, { api: 'ready', sqlserver: 'ready', redis: cache.ready ? 'ready' : 'unavailable', cache_ttl_seconds: cache.ttl });
      }
      if (req.method === 'GET' && url.pathname === '/api/metrics') return send(res, 200, { ...stats, redisReady: cache.ready, ttlSeconds: cache.ttl });
      const match = /^\/api\/applicants\/(\d+)\/(application-count|applications|cache|options)$/.exec(url.pathname);
      if (!match) return send(res, 404, { error: 'Endpoint not found.' });
      const id = Number(match[1]), action = match[2];
      if (!positive(id)) return send(res, 400, { error: 'Applicant ID must be a positive SQL integer.' });
      if (req.method === 'GET' && action === 'application-count') {
        return await locked(id, async () => {
          let mode = 'MISS';
          try {
            const value = await cache.get(id);
            if (value !== null) {
              const data = JSON.parse(value);
              if (data.applicant_id !== id || !Number.isInteger(data.application_count) || data.application_count < 0) throw new Error('Invalid cache entry');
              stats.hits++;
              return send(res, 200, data, { 'X-Cache': 'HIT', 'X-Cache-Key': cache.key(id), 'X-Cache-TTL': String(cache.ttl) });
            }
          } catch { mode = 'BYPASS'; }
          stats.sqlCountQueries++;
          const endSqlTimer = telemetry.sqlDuration.startTimer();
          let result;
          try { result = await pool.request().input('id', sql.Int, id).query(`
            SELECT applicant_id, full_name,
              dbo.fn_ApplicantApplicationCount(applicant_id) AS application_count
            FROM dbo.APPLICANT WHERE applicant_id=@id;`); }
          finally { endSqlTimer(); }
          if (!result.recordset.length) return send(res, 404, { error: 'Applicant not found.' });
          const data = result.recordset[0];
          try { await cache.set(id, data); } catch { mode = 'BYPASS'; }
          if (mode === 'BYPASS') stats.bypasses++; else stats.misses++;
          return send(res, 200, data, { 'X-Cache': mode, 'X-Cache-Key': cache.key(id), 'X-Cache-TTL': String(cache.ttl) });
        });
      }
      if (req.method === 'GET' && action === 'options') {
        const result = await pool.request().input('id', sql.Int, id).query(`
          SELECT j.job_ad_id,j.title FROM dbo.JOB_AD j WHERE NOT EXISTS
            (SELECT 1 FROM dbo.APPLICATION a WHERE a.applicant_id=@id AND a.job_ad_id=j.job_ad_id) ORDER BY j.job_ad_id;
          SELECT s.skill_id,s.skill_name FROM dbo.SKILL s WHERE NOT EXISTS
            (SELECT 1 FROM dbo.APPLICANT_SKILL p WHERE p.applicant_id=@id AND p.skill_id=s.skill_id) ORDER BY s.skill_id;`);
        return send(res, 200, { jobs: result.recordsets[0], skills: result.recordsets[1] });
      }
      if (req.method !== 'POST' || !['cache', 'applications'].includes(action)) return send(res, 405, { error: 'Method not allowed.' });
      if (!allowed(req)) return send(res, 401, { error: 'A local API token is required for changes.' });
      if (action === 'cache') {
        return await locked(id, async () => {
          try { await cache.invalidate(id); stats.invalidations++; return send(res, 200, { cleared: true }); }
          catch { return send(res, 503, { error: 'Redis unavailable; this key will be cleared before it is reused.' }); }
        });
      }
      const data = await body(req);
      if (!data || !positive(data.job_ad_id) || !positive(data.skill_id)) return send(res, 400, { error: 'job_ad_id and skill_id must be positive SQL integers.' });
      return await locked(id, async () => {
        // The existing procedure commits application, skill, and initial status atomically.
        const result = await pool.request().input('ApplicantID', sql.Int, id)
          .input('JobAdID', sql.Int, data.job_ad_id).input('SkillID', sql.Int, data.skill_id)
          .execute('dbo.usp_ApplyForJobAndAddSkill');
        let invalidated = false;
        try { await cache.invalidate(id); invalidated = true; stats.invalidations++; }
        catch { /* SQL committed. Keep the key dirty and return success, never retry a committed write. */ }
        return send(res, 201, { application_id: result.recordset[0].application_id, applicant_id: id, cache_invalidated: invalidated });
      });
    } catch (error) {
      if (res.headersSent) return res.end();
      const number = error.number || error.originalError?.info?.number;
      if ([2601, 2627].includes(number)) return send(res, 409, { error: 'Application or applicant skill already exists. Both inserts were rolled back.' });
      if (number === 547) return send(res, 400, { error: 'Applicant, job, or skill does not exist. Both inserts were rolled back.' });
      if (error.status) return send(res, error.status, { error: error.message });
      console.error('Request failed:', error.code || error.name); // No query/credential dumps.
      send(res, 503, { error: 'Database unavailable or request failed.' });
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  return { server, token, stats };
}

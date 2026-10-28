import prom from '@prometheus-io/client';

export function createMetrics({ stats, cache, pool }) {
  const registry = new prom.Registry();
  prom.collectDefaultMetrics({ register: registry, prefix: 'recruitment_' });
  const requests = new prom.Counter({ name: 'recruitment_http_requests_total', help: 'Completed HTTP requests', labelNames: ['method', 'route', 'status'], registers: [registry] });
  const duration = new prom.Histogram({ name: 'recruitment_http_request_duration_seconds', help: 'HTTP request duration in seconds', labelNames: ['method', 'route'], buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10], registers: [registry] });
  const sqlDuration = new prom.Histogram({ name: 'recruitment_sql_count_duration_seconds', help: 'Application count SQL query duration', buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10], registers: [registry] });
  for (const [field, name, help] of [
    ['hits', 'cache_hits', 'Applicant cache hits'], ['misses', 'cache_misses', 'Applicant cache misses'],
    ['bypasses', 'cache_bypasses', 'Applicant SQL fallbacks'], ['invalidations', 'cache_invalidations', 'Successful cache invalidations'],
    ['sqlCountQueries', 'sql_count_queries', 'Application count queries, excluding health and monitoring']
  ]) {
    let last = 0;
    new prom.Counter({ name: `recruitment_${name}_total`, help, registers: [registry], collect() {
      const value = stats[field]; this.inc(Math.max(0, value - last)); last = value;
    } });
  }
  new prom.Gauge({ name: 'recruitment_redis_ready', help: 'Redis client ready: 1=yes', registers: [registry], collect() { this.set(cache.ready ? 1 : 0); } });
  new prom.Gauge({ name: 'recruitment_sql_up', help: 'SQL Server query succeeds: 1=yes', registers: [registry], async collect() {
    try { await pool.request().query('SELECT 1 AS ok;'); this.set(1); } catch { this.set(0); }
  } });
  return {
    registry, sqlDuration,
    observe(req, res, path) {
      if (path === '/metrics') return; // Do not inflate traffic with Prometheus scrapes.
      let route = path.replace(/\/api\/applicants\/\d+\//, '/api/applicants/:id/');
      if (!['/', '/app.js', '/style.css', '/live', '/health', '/api/metrics', '/api/applicants/:id/application-count', '/api/applicants/:id/options', '/api/applicants/:id/applications', '/api/applicants/:id/cache'].includes(route)) route = 'other';
      const end = duration.startTimer({ method: req.method, route });
      res.once('finish', () => { requests.inc({ method: req.method, route, status: String(res.statusCode) }); end(); });
    }
  };
}

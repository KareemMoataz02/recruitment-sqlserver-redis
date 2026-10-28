import sql from 'mssql';
import { databaseConfig } from './config.js';
import { createCache } from './cache.js';
import { createApp } from './app.js';
const port = Number(process.env.PORT || 3102);
const pool = await new sql.ConnectionPool(databaseConfig()).connect();
const cache = createCache(process.env.REDIS_URL || 'redis://127.0.0.1:6380', Number(process.env.CACHE_TTL_SECONDS || 60));
const { server } = createApp({ pool, cache });
try {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, process.env.HOST || '127.0.0.1', resolve); });
  console.log(`Recruitment cache demo: http://127.0.0.1:${port}`);
} catch (error) {
  cache.close(); await pool.close();
  console.error(`Cannot start API (${error.code || 'error'}). Choose another PORT if occupied.`);
  process.exit(1);
}
async function stop() { server.close(); server.closeAllConnections(); cache.close(); await pool.close(); }
process.on('SIGINT', () => void stop());
process.on('SIGTERM', () => void stop());

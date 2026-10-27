import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const envPath = fileURLToPath(new URL('./.env', import.meta.url));
if (existsSync(envPath)) process.loadEnvFile(envPath);

export function databaseConfig(database = process.env.DB_NAME || 'RecruitmentDb') {
  if (!process.env.DB_PASSWORD) throw new Error('Set DB_PASSWORD in .env or your environment.');
  return {
    server: process.env.DB_HOST || '127.0.0.1',
    port: Number(process.env.DB_PORT || 1434),
    user: process.env.DB_USER || 'sa', password: process.env.DB_PASSWORD, database,
    connectionTimeout: 5000, requestTimeout: 10000,
    pool: { min: 0, max: 5, idleTimeoutMillis: 10000 },
    options: { encrypt: true, trustServerCertificate: process.env.DB_TRUST_CERTIFICATE !== 'false', abortTransactionOnError: true }
  };
}
export const publicDirectory = fileURLToPath(new URL('./public/', import.meta.url));

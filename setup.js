import sql from 'mssql';
import { readFile } from 'node:fs/promises';
import { databaseConfig } from './config.js';
const config = databaseConfig();
if (config.database !== 'RecruitmentDb') throw new Error('The supplied setup fixture requires DB_NAME=RecruitmentDb.');
async function batches(pool, file) {
  const source = await readFile(new URL(file, import.meta.url), 'utf8');
  for (const batch of source.split(/^GO\s*$/mi).filter(value => value.trim())) await pool.request().batch(batch);
}
const admin = await new sql.ConnectionPool(databaseConfig('master')).connect();
try {
  const found = await admin.request().query("SELECT DB_ID(N'RecruitmentDb') AS id;");
  if (found.recordset[0].id === null) {
    await batches(admin, './sql/schema-and-data.sql');
    console.log('Created RecruitmentDb and loaded fictional sample data.');
  } else {
    console.log('Existing RecruitmentDb retained; sample data will not be reinserted.');
  }
} finally { await admin.close(); }
const pool = await new sql.ConnectionPool(config).connect();
try {
  const check = await pool.request().query("SELECT OBJECT_ID(N'dbo.APPLICANT',N'U') AS id;");
  if (check.recordset[0].id === null) throw new Error('Existing database does not contain the required final schema. No reset attempted.');
  await batches(pool, './sql/workflows.sql');
  console.log('Applicant function and stored procedures installed.');
} finally { await pool.close(); }

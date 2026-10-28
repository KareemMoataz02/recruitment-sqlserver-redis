# Test and verification guide

Run `npm run check` and `npm test` after starting dependencies and running `npm run setup`.

The Node test runner creates a fresh `RecruitmentRedisTest_<timestamp>_<pid>` database from sql/schema-and-data.sql and installs sql/workflows.sql there. It starts its own Redis container on an automatically assigned loopback port, with a two-second TTL, and serves the real API over HTTP on a random loopback port.

The fixture contains two applications per applicant, so expectations remain deterministic regardless of manual changes in the normal database. Tests never write to the original RecruitmentDb; they compare application, status, and applicant-skill counts/checksums before and after. They remove the temporary database and container during teardown.

## Cases

| # | Case | Evidence |
|---|---|---|
| 1 | MISS then HIT | Redis actually stores JSON; SQL count metric increases once |
| 2 | TTL | Redis key expires; next HTTP read is MISS |
| 3 | Successful write | HTTP 201, cache key removed, count increments, Submitted event exists |
| 4 | Duplicate skill | HTTP 409, no partial application, previous valid cache still HIT |
| 5 | Duplicate application/FK | HTTP 409 / 400 respectively |
| 6 | Boundary inputs | Zero cached correctly; invalid ID 400; missing applicant 404 |
| 7 | Access controls | Bad mutation token 401; cross-origin write 403 |
| 8 | Concurrency | Simultaneous reads/write leave the updated final count cached |
| 9 | Corrupt entry | SQL fallback and replacement, then a valid cache HIT |
| 10 | Real outage | Stop Redis; BYPASS reads and committed writes work; restart and discard a simulated stale value |
| 11 | Original DB | Counts and checksums match the pre-test snapshot |
| 12 | Monitoring and probes | Prometheus metrics present, SQL/Redis readiness gauges valid, Kubernetes probe hosts accepted without accepting untrusted application hosts |

GitHub Actions performs these against actual SQL Server/Redis containers. A source folder includes local test output as evidence; CI is authoritative for each pushed revision.

## Manual cache test

Open http://127.0.0.1:3102/, select applicant 1, clear the cache, and read twice. Inspect X-Cache and the SQL count-query counter. Wait 60 seconds and read again to check normal expiry.

The manual application form commits a real record to this clone's RecruitmentDb. It is separate from the disposable integration-test dataset. Failed transactions must leave both application and skill associations unchanged.

## Outage demonstration

Stop only the Compose Redis service (`docker compose stop redis` or the Podman equivalent). Read an applicant count and expect BYPASS. Start the same service again; a subsequent read repopulates Redis. This interrupts caching, not SQL Server. Automated tests stop only their own test Redis container.

## Cleanup after interruption

Normal teardown is automatic. If a test is forcefully interrupted, identify its exact test database/container by the generated timestamp and PID before removing it. Do not remove normal RecruitmentDb or the Compose SQL data volume unless intentionally resetting the entire sample setup.

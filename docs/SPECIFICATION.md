# Functional and technical specification

## Objective and scope

Provide a local recruitment API that demonstrates measurable Redis cache-aside behavior over SQL Server. Preserve the relational schema and atomic SQL workflows. Supply a browser lab and repeatable automated tests. The app is a single Node.js process, restricted to loopback; public hosting, account authentication, and multi-instance invalidation are outside this implementation.

## Database model

- APPLICANT: identity, full name, birth date, gender, city, registration date.
- COMPANY: identity, name, type (Government, Semi-government, Private).
- REPRESENTATIVE: company FK, full name, type (1 Main, 2 Sub User).
- JOB_AD: representative FK, title, optional experience/gender/salary/city criteria.
- APPLICATION: applicant/job FKs, submission timestamp; unique applicant/job pair.
- APPLICATION_STATUS_EVENT: application FK, status, change timestamp.
- EXPERIENCE and APPLICANT_QUALIFICATION: applicant history; qualification-type FK.
- SKILL, APPLICANT_SKILL, JOB_SKILL_REQUIREMENT: skills and many-to-many links.
- JOB_QUAL_REQUIREMENT: accepted qualification type and optional major for a job.

Dates and salaries have ordering/nonnegative constraints. Every inserted application receives an initial Submitted status through a trigger. Status-history guards prevent removing all history for an existing application. APPLICATION_CURRENT_STATUS chooses the latest timestamp, breaking ties by status-event ID. Qualification and general status vocabularies remain open in the schema; the status-update procedure permits six standard sample states.

## SQL workflow contracts

1. `fn_ApplicantApplicationCount(@ApplicantID int) RETURNS int`: count matching APPLICATION records; zero when none match.
2. `usp_UpdateApplicationStatus(@ApplicationID int, @Status nvarchar(max))`: append history; error 50010 for NULL/unrecognized status, 50011 for nonexistent application. Standard states: Submitted, Screening, Interviewing, Hired, Rejected, Withdrawn.
3. `usp_ApplyForJobAndAddSkill(@ApplicantID int, @JobAdID int, @SkillID int)`: transactional application insertion and existing catalog-skill association. Any FK/unique failure rolls back all inserts, including the trigger-created event. Returns application_id. Its error handler rolls back the entire active transaction, including any caller transaction.

## Cache algorithm

Key shape: `recruitment:<process-uuid>:applicant:<id>:application-count`.

1. Validate the applicant ID as a positive SQL integer.
2. Acquire the in-process per-applicant lock.
3. If this applicant has a pending invalidation, clear it before using Redis.
4. Read Redis. Valid JSON with the matching ID and nonnegative integer count is a HIT.
5. On a miss/error, query the parameterized applicant/count SELECT.
6. Missing applicants return 404 and are not cached.
7. Store the response with EX=60 by default. Cache failures produce BYPASS, not a failed SQL response.
8. Release the lock. Report HIT/MISS/BYPASS in X-Cache.

Redis connection/command operations are bounded; offline command queuing is disabled. Redis reconnects automatically. Corrupt entries fall back to SQL. Cache-aside TTL bounds staleness from out-of-band SQL modifications.

## Mutation semantics

The POST application endpoint validates IDs, authenticates the local bearer token, then serializes the operation with reads for the same applicant. It calls the existing procedure and invalidates only after SQL commit. SQL duplicate errors return 409; missing FK references return 400. A cache failure after commit still returns 201 with `cache_invalidated=false`; the dirty-key guard prevents stale reuse in this process. The client must not retry a successful 201 just because invalidation was deferred.

## Local UI

The page provides an applicant-ID input, count read, repeated read, cache clearing, response details, request history, SQL count-query metrics, and health indicators. The optional creation form lists unused jobs/skills and clearly states that submission commits a real local sample record. GET requests and cache-only demonstrations do not create recruitment records.

## Access and configuration

API binds 127.0.0.1 only. Host validation rejects unexpected hostnames; cross-origin browser requests are rejected. Mutation routes require a random in-memory bearer token embedded in the same-origin page. No CORS wildcard, public bind, durable token storage, or database credentials in UI responses. SQL values are parameterized; error responses avoid SQL/credential dumps. SQL encryption is enabled; local self-signed certificate trust is configurable.

## Acceptance criteria

- First read after clearing is MISS; repeated read is HIT with one total SQL count query.
- TTL expiry causes a fresh SQL query.
- A successful atomic write refreshes the next count; failed writes do not evict valid counts.
- Zero counts cache correctly; missing/invalid IDs return useful errors.
- Redis outage leaves SQL reads and writes working; recovery does not reuse a dirty stale count.
- Concurrent reads/writes do not refill an old value within this process.
- Tests remove only their disposable database/container and preserve the original database.

## Limits and extension points

Locks and dirty IDs are process-local. Multiple API processes need shared versioning/invalidation, e.g. a SQL outbox. General public-user access needs real authentication/authorization and deployment hardening. Timing observations demonstrate behavior; they are not controlled benchmark claims. Identity counters may advance even on rolled-back SQL inserts.

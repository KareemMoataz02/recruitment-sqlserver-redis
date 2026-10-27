# Applicant SQL workflows

The implementation is in `sql/workflows.sql`; `npm run setup` installs it in RecruitmentDb.

## 1. Scalar application count

`dbo.fn_ApplicantApplicationCount(@ApplicantID int)` returns the count of matching APPLICATION rows, or zero for no matches. The API calls it only on cache misses or Redis fallback.

```sql
SELECT TOP (5) applicant_id, full_name,
  dbo.fn_ApplicantApplicationCount(applicant_id) AS total_applications
FROM dbo.APPLICANT
ORDER BY total_applications DESC, applicant_id;
```

## 2. Validated status-history append

`dbo.usp_UpdateApplicationStatus` rejects NULL/unrecognized status values (error 50010) and missing application IDs (50011). Allowed states are Submitted, Screening, Interviewing, Hired, Rejected and Withdrawn. A successful call inserts an event; the table default supplies its timestamp. Earlier events remain intact.

```sql
BEGIN TRANSACTION;
EXEC dbo.usp_UpdateApplicationStatus
  @ApplicationID=1, @Status=N'Screening';
SELECT * FROM dbo.APPLICATION_STATUS_EVENT
WHERE application_id=1
ORDER BY changed_at DESC,status_event_id DESC;
ROLLBACK TRANSACTION;
```

This procedure is included for SQL practice. There is no status-update HTTP endpoint because status changes do not affect an applicant's application count.

## 3. Atomic application and skill association

`dbo.usp_ApplyForJobAndAddSkill` accepts applicant, job and catalog-skill IDs. It inserts the application and the profile's skill association in a transaction. The existing application trigger creates Submitted history in the same transaction. On failure, XACT_ABORT, TRY/CATCH, ROLLBACK and THROW ensure all inserts are rolled back and the caller receives the error.

SkillID identifies a pre-existing SKILL catalog entry; this operation does not invent a new skill name. Duplicate applicant/job pairs and duplicate applicant/skill pairs fail through unique constraints. Missing references fail through foreign keys. On success the procedure returns the new application_id.

The procedure's rollback covers the entire active transaction, including a caller transaction. An outer rollback can be used for a disposable successful-call demonstration. Identity sequences may advance despite rollback.

Integration tests verify successful creation and the trigger event, duplicate-skill rollback, duplicate application/FK errors, cache invalidation after commit, and preservation of the source database.

## Running SQL batches

The SQL files use GO as a client-side batch separator. Use SSMS/sqlcmd, or the included setup runner, which splits batches. Do not submit an entire GO-separated script to a web client that does not support GO.

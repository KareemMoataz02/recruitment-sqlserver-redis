# SQL Server Agent and scheduled backups

SQL Server Agent is enabled with `MSSQL_AGENT_ENABLED=true` in Compose and the Kubernetes SQL StatefulSet. The jobs protect RecruitmentDb; they do not back up disposable lab databases.

## Schedule and backup chain

- Full backup: daily at 02:00 **SQL Server time** (UTC in the supplied containers).
- Log backup: every 15 minutes, all day.
- Both jobs are enabled and retry failures twice, with one minute between attempts.
- The installer sets RecruitmentDb to FULL recovery and takes an initial full backup before creating/enabling the schedules.
- Files use unique UTC timestamps and GUIDs under `/var/opt/mssql/backups`. No existing backup file is overwritten.
- Each backup uses COMPRESSION and CHECKSUM, followed by RESTORE VERIFYONLY. A session-level application lock serializes this procedure's full/log operations.

These are normal full backups, not COPY_ONLY: they establish the differential base. Do not switch the database to SIMPLE or skip required log files when planning a point-in-time restore. If the SQL Server timezone changes, the scheduled execution time changes with it; filenames continue to use UTC.

## Fresh Compose setup

Start the SQL service using the updated Compose file, run the normal database setup, then install jobs:

```bash
# Choose your engine. Use `docker` instead if appropriate.
podman compose up -d --wait
npm run setup
CONTAINER_ENGINE=podman ./scripts/configure-agent-backups.sh container
```

The script discovers the Compose SQL container. For an existing standalone SQL container, specify `SQL_CONTAINER=your-container-name`. SQL Server Agent must be running; the script waits briefly for Agent startup and otherwise stops before installing jobs. Its credential is read inside the container from the existing environment and never printed.

The pre-existing standalone `sqlserver-test` container was enabled using `mssql-conf set sqlagent.enabled true` as container root, then restarted in place. It was not recreated, preserving its existing databases. New Compose containers get the setting through their environment.

## Kubernetes setup

`./scripts/deploy-local-k8s.sh` now installs the jobs after database initialization. To configure an existing local cluster:

```bash
export KUBECONFIG=/absolute/path/to/recruitment-kubeconfig
kubectl --context kind-recruitment apply -f k8s/backend.yaml
kubectl --context kind-recruitment -n recruitment rollout status statefulset/sqlserver --timeout=300s
./scripts/configure-agent-backups.sh kubernetes
```

Only the named RecruitmentDb jobs, their first steps, and their named schedules are created or updated. Other jobs are retained. Rerunning the installer takes another initial full backup and updates the same two jobs instead of duplicating them. The SQL script requires sysadmin privileges and an existing RecruitmentDb.

## Inspect and trigger jobs

Use an SQL command window:

```sql
SELECT servicename, status_desc FROM sys.dm_server_services;
SELECT j.name,j.enabled,s.name AS schedule_name,
       s.freq_subday_type,s.freq_subday_interval,s.active_start_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON js.job_id=j.job_id
JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id
WHERE j.name LIKE N'RecruitmentDb - %';

EXEC msdb.dbo.sp_start_job @job_name=N'RecruitmentDb - Daily Full Backup';
-- Wait for the full job to finish before starting the log job.
EXEC msdb.dbo.sp_start_job @job_name=N'RecruitmentDb - Log Backup Every 15 Minutes';

SELECT TOP (20) j.name,h.step_id,h.run_status,h.run_date,h.run_time,h.message
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id=h.job_id
WHERE j.name LIKE N'RecruitmentDb - %'
ORDER BY h.instance_id DESC;
```

`sp_start_job` is asynchronous. Check history: `step_id=0` is the job outcome, and `run_status=1` means success. A successful start request alone is not proof of a completed backup.

For a repeatable end-to-end check, execute `sql/verify-agent-backups.sql` with sqlcmd or an editor supporting GO batches. It runs both jobs, waits for successful outcomes, restores the latest full and subsequent logs to a uniquely named disposable database, compares APPLICATION count/checksum, and runs CHECKDB on source and restored databases. It also exercises NULL-parameter validation. The restored database remains for inspection; each verification run consumes additional storage.

## Verification on 28 October 2026

Verified on both the original container and the Kubernetes SQL instance:

- SQL Server Agent reports Running; RecruitmentDb reports FULL recovery.
- Exactly two configured jobs, both enabled and attached to the intended schedules.
- Repeated installation on the original container did not duplicate jobs.
- Both Agent jobs completed successfully (`run_status=1`).
- Compressed full and log backups have checksums and passed VERIFYONLY.
- Full-plus-log restores completed under unique disposable names. Each restored database contained 30 applicants and 69 applications; APPLICATION checksums matched the source.
- CHECKDB reported no errors for either source or either restored database.
- Invalid NULL backup type was rejected with error 51101.

Job execution was tested by manually triggering the configured Agent jobs. Scheduled trigger times have been configured and inspected; this verification did not wait for the next daily execution.

## Storage and operational limits

Kubernetes and Compose backups are stored inside their SQL data volumes. They survive SQL pod/container restarts, but deleting those volumes deletes the backups. The original standalone container has no persistent volume: copy its backups outside the container before removing it. These local backups do not protect against loss of the host or kind cluster.

No automatic backup deletion, off-device replication, email notifications, or retention policy is configured. Monitor free space and export required full/log chains before manually removing old files. Keep complete chains for the recovery period you need. The 8 GiB Kubernetes data PVC is shared with the database.

[Microsoft: enabling SQL Server Agent on Linux](https://learn.microsoft.com/en-us/sql/linux/configure/mssql-conf#enable-sql-server-agent)

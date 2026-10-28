-- Runs both jobs, waits for their outcomes, then restores to a unique disposable DB.
-- Requires the Agent configuration and sysadmin permissions. Keeps restore evidence.
USE msdb;
SET NOCOUNT ON;
DECLARE @Name sysname,@Job uniqueidentifier,@Before int,@Deadline datetime,@Status int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
SELECT name,job_id FROM dbo.sysjobs WHERE name IN
(N'RecruitmentDb - Daily Full Backup',N'RecruitmentDb - Log Backup Every 15 Minutes')
ORDER BY name;
IF (SELECT COUNT(*) FROM dbo.sysjobs WHERE name IN
(N'RecruitmentDb - Daily Full Backup',N'RecruitmentDb - Log Backup Every 15 Minutes'))<>2
    THROW 51110,'Expected two configured backup jobs.',1;
OPEN c;
FETCH NEXT FROM c INTO @Name,@Job;
WHILE @@FETCH_STATUS=0
BEGIN
    SELECT @Before=ISNULL(MAX(instance_id),0) FROM dbo.sysjobhistory WHERE job_id=@Job AND step_id=0;
    EXEC dbo.sp_start_job @job_id=@Job;
    SET @Deadline=DATEADD(second,60,GETDATE());
    WHILE NOT EXISTS(SELECT 1 FROM dbo.sysjobhistory WHERE job_id=@Job AND step_id=0 AND instance_id>@Before)
    BEGIN
        IF GETDATE()>@Deadline THROW 51111,'Timed out waiting for Agent backup job.',1;
        WAITFOR DELAY '00:00:01';
    END;
    SELECT TOP(1) @Status=run_status FROM dbo.sysjobhistory
    WHERE job_id=@Job AND step_id=0 AND instance_id>@Before ORDER BY instance_id DESC;
    IF @Status<>1 THROW 51112,'Agent backup job did not succeed. Inspect msdb job history.',1;
    SELECT @Name AS successful_job,@Status AS run_status;
    FETCH NEXT FROM c INTO @Name,@Job;
END;
CLOSE c;
DEALLOCATE c;

DECLARE @Full nvarchar(260),@FullLsn numeric(25,0),@FullEnd datetime,@Target sysname,
        @Data nvarchar(260),@Log nvarchar(260),@LogBackup nvarchar(260);
SELECT TOP(1) @Full=m.physical_device_name,@FullLsn=b.last_lsn,@FullEnd=b.backup_finish_date
FROM dbo.backupset b JOIN dbo.backupmediafamily m ON m.media_set_id=b.media_set_id
WHERE b.database_name=N'RecruitmentDb' AND b.type='D'
AND m.physical_device_name LIKE N'/var/opt/mssql/backups/RecruitmentDb_FULL_%'
ORDER BY b.backup_set_id DESC;
SET @Target=N'RecruitmentDb_AgentRestore_'+REPLACE(CONVERT(nvarchar(36),NEWID()),N'-',N'');
SET @Data=N'/var/opt/mssql/data/'+@Target+N'.mdf';
SET @Log=N'/var/opt/mssql/data/'+@Target+N'_log.ldf';
RESTORE DATABASE @Target FROM DISK=@Full
WITH MOVE N'RecruitmentDb' TO @Data,MOVE N'RecruitmentDb_log' TO @Log,NORECOVERY;
DECLARE logs_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT m.physical_device_name FROM dbo.backupset b
JOIN dbo.backupmediafamily m ON m.media_set_id=b.media_set_id
WHERE b.database_name=N'RecruitmentDb' AND b.type='L' AND b.last_lsn>@FullLsn
AND b.backup_finish_date>=@FullEnd
ORDER BY b.backup_set_id;
OPEN logs_cursor;
FETCH NEXT FROM logs_cursor INTO @LogBackup;
IF @@FETCH_STATUS<>0 THROW 51113,'No log backup found after full backup.',1;
WHILE @@FETCH_STATUS=0
BEGIN
    RESTORE LOG @Target FROM DISK=@LogBackup WITH NORECOVERY;
    FETCH NEXT FROM logs_cursor INTO @LogBackup;
END;
CLOSE logs_cursor;
DEALLOCATE logs_cursor;
RESTORE DATABASE @Target WITH RECOVERY;
DECLARE @Sql nvarchar(max)=N'
IF (SELECT COUNT(*) FROM '+QUOTENAME(@Target)+N'.dbo.APPLICATION)<>
   (SELECT COUNT(*) FROM RecruitmentDb.dbo.APPLICATION)
   OR (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM '+QUOTENAME(@Target)+N'.dbo.APPLICATION)<>
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM RecruitmentDb.dbo.APPLICATION)
    THROW 51114,''Application data differs between source and restored DB.'',1;
SELECT '+QUOTENAME(@Target,N'''')+N' AS restored_database,
 (SELECT COUNT(*) FROM '+QUOTENAME(@Target)+N'.dbo.APPLICANT) applicants,
 (SELECT COUNT(*) FROM '+QUOTENAME(@Target)+N'.dbo.APPLICATION) applications;';
EXEC sys.sp_executesql @Sql;
DBCC CHECKDB (@Target) WITH NO_INFOMSGS;
DBCC CHECKDB (N'RecruitmentDb') WITH NO_INFOMSGS;
BEGIN TRY
    EXEC RecruitmentDb.dbo.usp_AgentBackup @BackupType=NULL;
    THROW 51115,'NULL backup type was not rejected.',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51101 THROW;
    PRINT 'NULL backup-type validation passed.';
END CATCH;
SELECT servicename,status_desc FROM sys.dm_server_services;
SELECT name,recovery_model_desc FROM sys.databases WHERE name=N'RecruitmentDb';
SELECT TOP(4) b.type,b.has_backup_checksums,b.backup_size,b.compressed_backup_size
FROM dbo.backupset b WHERE b.database_name=N'RecruitmentDb'
ORDER BY b.backup_set_id DESC;

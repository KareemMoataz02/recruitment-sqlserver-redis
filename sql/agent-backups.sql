-- Run as sysadmin after RecruitmentDb exists. Applies only to this database.
USE master;
IF DB_ID(N'RecruitmentDb') IS NULL
    THROW 51100, 'RecruitmentDb must exist before configuring backups.', 1;
ALTER DATABASE RecruitmentDb SET RECOVERY FULL;
GO
USE RecruitmentDb;
GO
CREATE OR ALTER PROCEDURE dbo.usp_AgentBackup
    @BackupType varchar(4)
AS
BEGIN
    SET NOCOUNT ON;
    IF @BackupType IS NULL OR @BackupType NOT IN ('FULL', 'LOG')
        THROW 51101, 'BackupType must be FULL or LOG.', 1;
    DECLARE @LockResult int, @Path nvarchar(260);
    EXEC @LockResult = sys.sp_getapplock
        @Resource=N'RecruitmentDb.AgentBackup', @LockMode='Exclusive',
        @LockOwner='Session', @LockTimeout=60000;
    IF @LockResult < 0 THROW 51102, 'Could not obtain backup lock.', 1;
    BEGIN TRY
        SET @Path = N'/var/opt/mssql/backups/RecruitmentDb_' + @BackupType + N'_' +
            REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(23), GETUTCDATE(), 126),N'-',N''),N':',N''),N'.',N'') +
            N'_' + CONVERT(nvarchar(36),NEWID()) +
            CASE WHEN @BackupType='FULL' THEN N'.bak' ELSE N'.trn' END;
        IF @BackupType='FULL'
            BACKUP DATABASE RecruitmentDb TO DISK=@Path WITH COMPRESSION,CHECKSUM;
        ELSE
            BACKUP LOG RecruitmentDb TO DISK=@Path WITH COMPRESSION,CHECKSUM;
        RESTORE VERIFYONLY FROM DISK=@Path WITH CHECKSUM;
        EXEC sys.sp_releaseapplock @Resource=N'RecruitmentDb.AgentBackup', @LockOwner='Session';
        SELECT @Path AS backup_file, @BackupType AS backup_type;
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock @Resource=N'RecruitmentDb.AgentBackup', @LockOwner='Session';
        THROW;
    END CATCH;
END;
GO
-- A normal full backup establishes the chain before any scheduled log backup.
EXEC dbo.usp_AgentBackup @BackupType='FULL';
GO
USE msdb;
GO
BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @Owner sysname=SUSER_SNAME(0x01), @JobId uniqueidentifier;
    DECLARE @Jobs TABLE (job_name sysname, step_command nvarchar(max), schedule_name sysname, subday_type int, subday_interval int, start_time int);
    INSERT @Jobs VALUES
      (N'RecruitmentDb - Daily Full Backup', N'EXEC dbo.usp_AgentBackup @BackupType=''FULL'';', N'RecruitmentDb - Daily 0200 UTC', 1, 0, 20000),
      (N'RecruitmentDb - Log Backup Every 15 Minutes', N'EXEC dbo.usp_AgentBackup @BackupType=''LOG'';', N'RecruitmentDb - Every 15 Minutes UTC', 4, 15, 0);
    DECLARE @Name sysname,@Command nvarchar(max),@Schedule sysname,@Subday int,@Interval int,@Start int,@ScheduleId int;
    DECLARE jobs_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM @Jobs;
    OPEN jobs_cursor;
    FETCH NEXT FROM jobs_cursor INTO @Name,@Command,@Schedule,@Subday,@Interval,@Start;
    WHILE @@FETCH_STATUS=0
    BEGIN
        SET @JobId=NULL;
        SELECT @JobId=job_id FROM dbo.sysjobs WHERE name=@Name;
        IF @JobId IS NULL
        BEGIN
            EXEC dbo.sp_add_job @job_name=@Name,@enabled=1,@owner_login_name=@Owner,@job_id=@JobId OUTPUT;
            EXEC dbo.sp_add_jobserver @job_id=@JobId;
        END
        ELSE EXEC dbo.sp_update_job @job_id=@JobId,@enabled=1;
        IF EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=1)
            EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=1,@step_name=N'Compressed verified backup',
                @subsystem=N'TSQL',@database_name=N'RecruitmentDb',@command=@Command,@retry_attempts=2,@retry_interval=1;
        ELSE
            EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=1,@step_name=N'Compressed verified backup',
                @subsystem=N'TSQL',@database_name=N'RecruitmentDb',@command=@Command,@retry_attempts=2,@retry_interval=1;
        SET @ScheduleId=NULL;
        SELECT @ScheduleId=schedule_id FROM dbo.sysschedules WHERE name=@Schedule;
        IF @ScheduleId IS NULL
            EXEC dbo.sp_add_schedule @schedule_name=@Schedule,@enabled=1,@freq_type=4,@freq_interval=1,
                @freq_subday_type=@Subday,@freq_subday_interval=@Interval,@active_start_time=@Start,
                @active_end_time=235959,@schedule_id=@ScheduleId OUTPUT;
        ELSE
            EXEC dbo.sp_update_schedule @schedule_id=@ScheduleId,@enabled=1,@freq_type=4,@freq_interval=1,
                @freq_subday_type=@Subday,@freq_subday_interval=@Interval,@active_start_time=@Start,@active_end_time=235959;
        IF NOT EXISTS(SELECT 1 FROM dbo.sysjobschedules WHERE job_id=@JobId AND schedule_id=@ScheduleId)
            EXEC dbo.sp_attach_schedule @job_id=@JobId,@schedule_id=@ScheduleId;
        FETCH NEXT FROM jobs_cursor INTO @Name,@Command,@Schedule,@Subday,@Interval,@Start;
    END;
    CLOSE jobs_cursor;
    DEALLOCATE jobs_cursor;
    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK;
    THROW;
END CATCH;
GO
SELECT j.name,j.enabled,s.name AS schedule_name,s.freq_subday_type,s.freq_subday_interval,s.active_start_time
FROM dbo.sysjobs j JOIN dbo.sysjobschedules js ON js.job_id=j.job_id
JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
WHERE j.name LIKE N'RecruitmentDb - %';

-- SQL Server / RecruitmentDb
-- Allowed states assumed from the existing sample data.
-- Task 3 adds an existing catalog skill to the applicant's profile.
USE RecruitmentDb;
GO

-- Task 1: Count applications for one applicant.
CREATE OR ALTER FUNCTION dbo.fn_ApplicantApplicationCount
(
    @ApplicantID int
)
RETURNS int
AS
BEGIN
    RETURN (
        SELECT COUNT(*)
        FROM dbo.APPLICATION
        WHERE applicant_id = @ApplicantID
    );
END;
GO

-- Test query: ties are resolved by applicant ID.
SELECT TOP (5)
    applicant_id,
    full_name,
    dbo.fn_ApplicantApplicationCount(applicant_id) AS total_applications
FROM dbo.APPLICANT
ORDER BY total_applications DESC, applicant_id ASC;
GO

-- Task 2: Append a status history record.
CREATE OR ALTER PROCEDURE dbo.usp_UpdateApplicationStatus
    @ApplicationID int,
    @Status nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Status IS NULL OR @Status NOT IN
       (N'Submitted', N'Screening', N'Interviewing',
        N'Hired', N'Rejected', N'Withdrawn')
    BEGIN
        THROW 50010, 'Invalid application status.', 1;
    END;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.APPLICATION
        WHERE application_id = @ApplicationID
    )
    BEGIN
        THROW 50011, 'Application ID does not exist.', 1;
    END;

    INSERT INTO dbo.APPLICATION_STATUS_EVENT (application_id, status)
    VALUES (@ApplicationID, @Status);
END;
GO

-- Task 3: Apply for a job and add a skill atomically.
CREATE OR ALTER PROCEDURE dbo.usp_ApplyForJobAndAddSkill
    @ApplicantID int,
    @JobAdID int,
    @SkillID int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.APPLICATION (applicant_id, job_ad_id)
        VALUES (@ApplicantID, @JobAdID);

        DECLARE @ApplicationID int = CONVERT(int, SCOPE_IDENTITY());

        INSERT INTO dbo.APPLICANT_SKILL (applicant_id, skill_id)
        VALUES (@ApplicantID, @SkillID);

        COMMIT TRANSACTION;

        SELECT @ApplicationID AS application_id;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

-- Example calls (uncomment and supply suitable IDs):
-- EXEC dbo.usp_UpdateApplicationStatus @ApplicationID = 1, @Status = N'Screening';
-- EXEC dbo.usp_ApplyForJobAndAddSkill @ApplicantID = 1, @JobAdID = 2, @SkillID = 4;
-- Foreign keys reject missing IDs. Unique keys reject repeat applications
-- and skills already on the profile; either error rolls back both inserts.
-- The existing application trigger creates the initial Submitted status
-- inside the same transaction.

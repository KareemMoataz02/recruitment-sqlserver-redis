-- Final Jadarat schema and realistic fictional sample data.
-- Run in SSMS or sqlcmd. Refuses to overwrite an existing database.
USE master;
GO
IF DB_ID(N'RecruitmentDb') IS NOT NULL THROW 51000,'RecruitmentDb already exists. Choose a new database name or use an empty server.',1;
CREATE DATABASE RecruitmentDb;
GO
USE RecruitmentDb;
GO
SET XACT_ABORT ON;
BEGIN TRANSACTION;

CREATE TABLE dbo.COMPANY (
 company_id int IDENTITY PRIMARY KEY,
 company_name nvarchar(200) NOT NULL,
 company_type nvarchar(20) NOT NULL CHECK(company_type IN (N'Government',N'Semi-government',N'Private'))
);
CREATE TABLE dbo.REPRESENTATIVE (
 representative_id int IDENTITY PRIMARY KEY,
 company_id int NOT NULL REFERENCES dbo.COMPANY(company_id),
 full_name nvarchar(200) NOT NULL,
 representative_type tinyint NOT NULL CHECK(representative_type IN (1,2))
);
CREATE TABLE dbo.APPLICANT (
 applicant_id int IDENTITY PRIMARY KEY,
 full_name nvarchar(200) NOT NULL,
 date_of_birth date NOT NULL,
 gender nvarchar(30) NOT NULL,
 city nvarchar(100) NOT NULL,
 registration_date date NOT NULL DEFAULT CONVERT(date,SYSUTCDATETIME()),
 CHECK(date_of_birth < registration_date)
);
CREATE TABLE dbo.EXPERIENCE (
 experience_id int IDENTITY PRIMARY KEY,
 applicant_id int NOT NULL REFERENCES dbo.APPLICANT(applicant_id),
 employer_name nvarchar(200) NOT NULL,
 job_title nvarchar(200) NOT NULL,
 start_date date NOT NULL, end_date date NULL,
 CHECK(end_date IS NULL OR end_date >= start_date)
);
CREATE TABLE dbo.QUALIFICATION_TYPE (
 qualification_type_id int IDENTITY PRIMARY KEY,
 type_name nvarchar(100) NOT NULL UNIQUE
);
CREATE TABLE dbo.APPLICANT_QUALIFICATION (
 applicant_qualification_id int IDENTITY PRIMARY KEY,
 applicant_id int NOT NULL REFERENCES dbo.APPLICANT(applicant_id),
 qualification_type_id int NOT NULL REFERENCES dbo.QUALIFICATION_TYPE(qualification_type_id),
 major nvarchar(150) NOT NULL, institution nvarchar(200) NOT NULL,
 graduation_date date NOT NULL
);
CREATE TABLE dbo.SKILL (
 skill_id int IDENTITY PRIMARY KEY,
 skill_name nvarchar(100) NOT NULL UNIQUE
);
CREATE TABLE dbo.APPLICANT_SKILL (
 applicant_id int NOT NULL REFERENCES dbo.APPLICANT(applicant_id),
 skill_id int NOT NULL REFERENCES dbo.SKILL(skill_id),
 PRIMARY KEY(applicant_id,skill_id)
);
CREATE TABLE dbo.JOB_AD (
 job_ad_id int IDENTITY PRIMARY KEY,
 representative_id int NOT NULL REFERENCES dbo.REPRESENTATIVE(representative_id),
 title nvarchar(200) NOT NULL,
 min_years_experience decimal(4,1) NULL CHECK(min_years_experience >= 0),
 gender_criterion nvarchar(30) NULL,
 min_salary decimal(18,2) NULL CHECK(min_salary >= 0),
 max_salary decimal(18,2) NULL CHECK(max_salary >= 0),
 city_criterion nvarchar(100) NULL,
 CHECK(min_salary IS NULL OR max_salary IS NULL OR max_salary >= min_salary)
);
CREATE TABLE dbo.JOB_SKILL_REQUIREMENT (
 job_ad_id int NOT NULL REFERENCES dbo.JOB_AD(job_ad_id),
 skill_id int NOT NULL REFERENCES dbo.SKILL(skill_id),
 PRIMARY KEY(job_ad_id,skill_id)
);
CREATE TABLE dbo.JOB_QUAL_REQUIREMENT (
 job_qual_requirement_id int IDENTITY PRIMARY KEY,
 job_ad_id int NOT NULL REFERENCES dbo.JOB_AD(job_ad_id),
 qualification_type_id int NOT NULL REFERENCES dbo.QUALIFICATION_TYPE(qualification_type_id),
 required_major nvarchar(150) NULL,
 UNIQUE(job_ad_id,qualification_type_id,required_major)
);
CREATE TABLE dbo.APPLICATION (
 application_id int IDENTITY PRIMARY KEY,
 applicant_id int NOT NULL REFERENCES dbo.APPLICANT(applicant_id),
 job_ad_id int NOT NULL REFERENCES dbo.JOB_AD(job_ad_id),
 submitted_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 UNIQUE(applicant_id,job_ad_id)
);
CREATE TABLE dbo.APPLICATION_STATUS_EVENT (
 status_event_id int IDENTITY PRIMARY KEY,
 application_id int NOT NULL REFERENCES dbo.APPLICATION(application_id),
 status nvarchar(50) NOT NULL CHECK(LEN(LTRIM(RTRIM(status))) > 0),
 changed_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_REPRESENTATIVE_company ON dbo.REPRESENTATIVE(company_id);
CREATE INDEX IX_EXPERIENCE_applicant ON dbo.EXPERIENCE(applicant_id);
CREATE INDEX IX_APPLICANT_QUAL_applicant ON dbo.APPLICANT_QUALIFICATION(applicant_id);
CREATE INDEX IX_APPLICANT_QUAL_type ON dbo.APPLICANT_QUALIFICATION(qualification_type_id);
CREATE INDEX IX_APPLICANT_SKILL_skill ON dbo.APPLICANT_SKILL(skill_id);
CREATE INDEX IX_JOB_AD_representative ON dbo.JOB_AD(representative_id);
CREATE INDEX IX_JOB_SKILL_skill ON dbo.JOB_SKILL_REQUIREMENT(skill_id);
CREATE INDEX IX_JOB_QUAL_job ON dbo.JOB_QUAL_REQUIREMENT(job_ad_id);
CREATE INDEX IX_JOB_QUAL_type ON dbo.JOB_QUAL_REQUIREMENT(qualification_type_id);
CREATE INDEX IX_APPLICATION_job ON dbo.APPLICATION(job_ad_id);
CREATE INDEX IX_STATUS_application_time ON dbo.APPLICATION_STATUS_EVENT(application_id,changed_at DESC,status_event_id DESC) INCLUDE(status);

EXEC(N'CREATE TRIGGER dbo.tr_APPLICATION_initial_status ON dbo.APPLICATION AFTER INSERT AS
BEGIN
 SET NOCOUNT ON;
 INSERT dbo.APPLICATION_STATUS_EVENT(application_id,status,changed_at)
 SELECT application_id,N''Submitted'',submitted_at FROM inserted;
END');
EXEC(N'CREATE TRIGGER dbo.tr_STATUS_history_guard ON dbo.APPLICATION_STATUS_EVENT AFTER INSERT,UPDATE,DELETE AS
BEGIN
 SET NOCOUNT ON;
 IF EXISTS(SELECT 1 FROM inserted i JOIN dbo.APPLICATION a ON a.application_id=i.application_id WHERE i.changed_at<a.submitted_at)
 THROW 50001,''A status event cannot predate its application.'',1;
 IF EXISTS(SELECT 1 FROM deleted d JOIN dbo.APPLICATION a ON a.application_id=d.application_id WHERE NOT EXISTS(SELECT 1 FROM dbo.APPLICATION_STATUS_EVENT e WHERE e.application_id=a.application_id))
 THROW 50002,''Every application must retain at least one status event.'',1;
END');
EXEC(N'CREATE TRIGGER dbo.tr_APPLICATION_submission_guard ON dbo.APPLICATION AFTER UPDATE AS
BEGIN
 SET NOCOUNT ON;
 IF EXISTS(SELECT 1 FROM inserted i JOIN dbo.APPLICATION_STATUS_EVENT e ON i.application_id=e.application_id WHERE e.changed_at<i.submitted_at)
 THROW 50003,''Submission time cannot follow an existing status event.'',1;
END');
EXEC(N'CREATE VIEW dbo.APPLICATION_CURRENT_STATUS AS
 SELECT a.application_id,a.applicant_id,a.job_ad_id,a.submitted_at,e.status AS current_status,e.changed_at
 FROM dbo.APPLICATION a CROSS APPLY (
 SELECT TOP (1) status,changed_at FROM dbo.APPLICATION_STATUS_EVENT e
 WHERE e.application_id=a.application_id ORDER BY changed_at DESC,status_event_id DESC
 ) e');
COMMIT;
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;
DISABLE TRIGGER dbo.tr_APPLICATION_initial_status ON dbo.APPLICATION;
SET IDENTITY_INSERT dbo.[COMPANY] ON;
INSERT dbo.[COMPANY] ([company_id],[company_name],[company_type]) VALUES (1,N'Riyadh Civic Development Authority',N'Government');
INSERT dbo.[COMPANY] ([company_id],[company_name],[company_type]) VALUES (2,N'National Digital Services Commission',N'Government');
INSERT dbo.[COMPANY] ([company_id],[company_name],[company_type]) VALUES (3,N'Wadi Transit Development Company',N'Semi-government');
INSERT dbo.[COMPANY] ([company_id],[company_name],[company_type]) VALUES (4,N'Madar Energy Development Company',N'Semi-government');
INSERT dbo.[COMPANY] ([company_id],[company_name],[company_type]) VALUES (5,N'Rimal Software Solutions',N'Private');
INSERT dbo.[COMPANY] ([company_id],[company_name],[company_type]) VALUES (6,N'Sahab Retail Group',N'Private');
SET IDENTITY_INSERT dbo.[COMPANY] OFF;
SET IDENTITY_INSERT dbo.[REPRESENTATIVE] ON;
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (1,1,N'Hanan Al-Mansour',1);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (2,1,N'Fahad Al-Saif',2);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (3,2,N'Mariam Al-Hazmi',1);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (4,2,N'Abdulrahman Al-Bishi',2);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (5,3,N'Aisha Al-Dakhil',1);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (6,3,N'Sultan Al-Muqrin',2);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (7,4,N'Wafa Al-Ruwaili',1);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (8,4,N'Hamad Al-Saqer',2);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (9,5,N'Deema Al-Yami',1);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (10,5,N'Ziyad Al-Tuwaijri',2);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (11,6,N'Latifa Al-Suhaimi',1);
INSERT dbo.[REPRESENTATIVE] ([representative_id],[company_id],[full_name],[representative_type]) VALUES (12,6,N'Mansour Al-Bassam',2);
SET IDENTITY_INSERT dbo.[REPRESENTATIVE] OFF;
SET IDENTITY_INSERT dbo.[APPLICANT] ON;
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (1,N'Noura Al-Qahtani',N'1993-09-20',N'Female',N'Riyadh',N'2026-07-19');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (2,N'Faisal Al-Harbi',N'1991-05-03',N'Male',N'Jeddah',N'2026-06-04');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (3,N'Sara Al-Otaibi',N'1997-04-17',N'Female',N'Dammam',N'2026-06-24');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (4,N'Abdullah Al-Dosari',N'2002-08-25',N'Male',N'Madinah',N'2026-07-12');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (5,N'Reem Al-Shammari',N'1990-01-12',N'Female',N'Abha',N'2026-07-08');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (6,N'Omar Al-Zahrani',N'1991-03-11',N'Male',N'Khobar',N'2026-06-07');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (7,N'Hessa Al-Ghamdi',N'2002-11-01',N'Female',N'Tabuk',N'2026-06-16');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (8,N'Khalid Al-Mutairi',N'2000-12-28',N'Male',N'Taif',N'2026-06-20');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (9,N'Lama Al-Shehri',N'1997-01-09',N'Female',N'Riyadh',N'2026-06-05');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (10,N'Yousef Al-Anazi',N'1989-04-04',N'Male',N'Jeddah',N'2026-06-27');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (11,N'Maha Al-Subaie',N'1995-08-25',N'Female',N'Dammam',N'2026-06-19');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (12,N'Ahmed Al-Rashidi',N'1989-04-10',N'Male',N'Madinah',N'2026-06-11');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (13,N'Abeer Al-Malki',N'1997-08-16',N'Female',N'Abha',N'2026-07-14');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (14,N'Saud Al-Juhani',N'2000-12-20',N'Male',N'Khobar',N'2026-07-15');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (15,N'Ghada Al-Balawi',N'1999-01-02',N'Female',N'Tabuk',N'2026-07-15');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (16,N'Mohammed Al-Salem',N'2001-09-27',N'Male',N'Taif',N'2026-06-20');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (17,N'Dalal Al-Tamimi',N'1991-05-28',N'Female',N'Riyadh',N'2026-06-30');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (18,N'Turki Al-Harthi',N'1991-03-20',N'Male',N'Jeddah',N'2026-07-11');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (19,N'Amal Al-Faraj',N'1995-05-27',N'Female',N'Dammam',N'2026-06-20');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (20,N'Ibrahim Al-Ahmadi',N'1994-09-24',N'Male',N'Madinah',N'2026-07-02');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (21,N'Razan Al-Sultan',N'1996-08-01',N'Female',N'Abha',N'2026-07-12');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (22,N'Waleed Al-Nasser',N'1997-09-22',N'Male',N'Khobar',N'2026-06-01');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (23,N'Shahad Al-Hakami',N'1988-07-14',N'Female',N'Tabuk',N'2026-07-09');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (24,N'Majed Al-Amri',N'2001-12-05',N'Male',N'Taif',N'2026-07-07');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (25,N'Nouf Al-Abdali',N'1996-06-19',N'Female',N'Riyadh',N'2026-06-07');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (26,N'Bader Al-Suwailem',N'1997-09-24',N'Male',N'Jeddah',N'2026-06-20');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (27,N'Hind Al-Sharif',N'2001-12-18',N'Female',N'Dammam',N'2026-07-25');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (28,N'Nawaf Al-Humaidi',N'1998-01-27',N'Male',N'Madinah',N'2026-06-21');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (29,N'Raghad Al-Khaldi',N'1994-11-28',N'Female',N'Abha',N'2026-07-07');
INSERT dbo.[APPLICANT] ([applicant_id],[full_name],[date_of_birth],[gender],[city],[registration_date]) VALUES (30,N'Saleh Al-Qurashi',N'1995-10-16',N'Male',N'Khobar',N'2026-06-17');
SET IDENTITY_INSERT dbo.[APPLICANT] OFF;
SET IDENTITY_INSERT dbo.[EXPERIENCE] ON;
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (1,1,N'Afaq Technology Services',N'Software Developer',N'2015-08-10',N'2025-07-27');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (2,2,N'Jisr Business Solutions',N'Operations Coordinator',N'2013-08-26',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (3,4,N'Namaa Information Systems',N'IT Support Analyst',N'2026-08-16',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (4,5,N'Barq Engineering Consulting',N'Electrical Engineer',N'2012-08-05',N'2025-09-21');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (5,7,N'Jisr Business Solutions',N'Operations Coordinator',N'2024-09-01',N'2025-07-05');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (6,8,N'Rawafid Accounting Services',N'Junior Accountant',N'2024-08-26',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (7,10,N'Barq Engineering Consulting',N'Electrical Engineer',N'2011-08-07',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (8,11,N'Afaq Technology Services',N'Software Developer',N'2017-09-11',N'2025-12-12');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (9,13,N'Rawafid Accounting Services',N'Junior Accountant',N'2019-08-24',N'2025-08-04');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (10,14,N'Namaa Information Systems',N'IT Support Analyst',N'2022-08-20',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (11,16,N'Afaq Technology Services',N'Software Developer',N'2025-09-28',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (12,17,N'Jisr Business Solutions',N'Operations Coordinator',N'2013-07-28',N'2025-09-18');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (13,19,N'Namaa Information Systems',N'IT Support Analyst',N'2017-08-26',N'2025-12-09');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (14,20,N'Barq Engineering Consulting',N'Electrical Engineer',N'2018-09-07',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (15,22,N'Jisr Business Solutions',N'Operations Coordinator',N'2019-09-11',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (16,23,N'Rawafid Accounting Services',N'Junior Accountant',N'2010-08-14',N'2025-07-11');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (17,25,N'Barq Engineering Consulting',N'Electrical Engineer',N'2018-08-02',N'2025-08-13');
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (18,26,N'Afaq Technology Services',N'Software Developer',N'2019-08-22',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (19,28,N'Rawafid Accounting Services',N'Junior Accountant',N'2022-08-23',NULL);
INSERT dbo.[EXPERIENCE] ([experience_id],[applicant_id],[employer_name],[job_title],[start_date],[end_date]) VALUES (20,29,N'Namaa Information Systems',N'IT Support Analyst',N'2016-08-22',N'2025-10-04');
SET IDENTITY_INSERT dbo.[EXPERIENCE] OFF;
SET IDENTITY_INSERT dbo.[QUALIFICATION_TYPE] ON;
INSERT dbo.[QUALIFICATION_TYPE] ([qualification_type_id],[type_name]) VALUES (3,N'Bachelor');
INSERT dbo.[QUALIFICATION_TYPE] ([qualification_type_id],[type_name]) VALUES (2,N'Diploma');
INSERT dbo.[QUALIFICATION_TYPE] ([qualification_type_id],[type_name]) VALUES (5,N'Doctorate');
INSERT dbo.[QUALIFICATION_TYPE] ([qualification_type_id],[type_name]) VALUES (1,N'High School');
INSERT dbo.[QUALIFICATION_TYPE] ([qualification_type_id],[type_name]) VALUES (4,N'Master');
SET IDENTITY_INSERT dbo.[QUALIFICATION_TYPE] OFF;
SET IDENTITY_INSERT dbo.[APPLICANT_QUALIFICATION] ON;
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (1,1,3,N'Computer Science',N'King Saud University',N'2015-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (2,2,3,N'Business Administration',N'King Abdulaziz University',N'2013-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (3,3,3,N'Accounting',N'Imam Abdulrahman Bin Faisal University',N'2019-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (4,4,4,N'Information Systems',N'Taibah University',N'2026-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (5,5,3,N'Electrical Engineering',N'King Khalid University',N'2012-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (6,6,3,N'Computer Science',N'King Saud University',N'2013-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (7,7,3,N'Business Administration',N'King Abdulaziz University',N'2024-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (8,8,4,N'Accounting',N'Imam Abdulrahman Bin Faisal University',N'2024-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (9,9,3,N'Information Systems',N'Taibah University',N'2019-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (10,10,3,N'Electrical Engineering',N'King Khalid University',N'2011-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (11,11,3,N'Computer Science',N'King Saud University',N'2017-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (12,12,4,N'Business Administration',N'King Abdulaziz University',N'2013-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (13,13,3,N'Accounting',N'Imam Abdulrahman Bin Faisal University',N'2019-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (14,14,3,N'Information Systems',N'Taibah University',N'2022-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (15,15,3,N'Electrical Engineering',N'King Khalid University',N'2021-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (16,16,4,N'Computer Science',N'King Saud University',N'2025-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (17,17,3,N'Business Administration',N'King Abdulaziz University',N'2013-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (18,18,3,N'Accounting',N'Imam Abdulrahman Bin Faisal University',N'2013-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (19,19,3,N'Information Systems',N'Taibah University',N'2017-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (20,20,4,N'Electrical Engineering',N'King Khalid University',N'2018-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (21,21,3,N'Computer Science',N'King Saud University',N'2018-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (22,22,3,N'Business Administration',N'King Abdulaziz University',N'2019-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (23,23,3,N'Accounting',N'Imam Abdulrahman Bin Faisal University',N'2010-06-15');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (24,24,4,N'Information Systems',N'Taibah University',N'2025-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (25,25,3,N'Electrical Engineering',N'King Khalid University',N'2018-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (26,26,3,N'Computer Science',N'King Saud University',N'2019-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (27,27,3,N'Business Administration',N'King Abdulaziz University',N'2023-06-25');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (28,28,4,N'Accounting',N'Imam Abdulrahman Bin Faisal University',N'2022-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (29,29,3,N'Information Systems',N'Taibah University',N'2016-06-20');
INSERT dbo.[APPLICANT_QUALIFICATION] ([applicant_qualification_id],[applicant_id],[qualification_type_id],[major],[institution],[graduation_date]) VALUES (30,30,3,N'Electrical Engineering',N'King Khalid University',N'2017-06-15');
SET IDENTITY_INSERT dbo.[APPLICANT_QUALIFICATION] OFF;
SET IDENTITY_INSERT dbo.[SKILL] ON;
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (9,N'Accounting');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (4,N'C#');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (5,N'Communication');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (8,N'Customer Service');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (12,N'Cybersecurity');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (7,N'Data Analysis');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (10,N'Excel');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (3,N'Java');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (11,N'Networking');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (6,N'Project Management');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (2,N'Python');
INSERT dbo.[SKILL] ([skill_id],[skill_name]) VALUES (1,N'SQL');
SET IDENTITY_INSERT dbo.[SKILL] OFF;
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (1,1);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (11,1);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (12,1);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (13,1);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (23,1);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (24,1);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (25,1);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (1,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (2,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (12,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (13,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (14,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (24,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (25,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (26,2);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (1,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (2,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (3,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (13,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (14,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (15,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (25,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (26,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (27,3);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (2,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (3,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (4,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (14,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (15,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (16,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (26,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (27,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (28,4);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (3,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (4,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (5,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (15,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (16,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (17,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (27,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (28,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (29,5);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (4,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (5,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (6,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (16,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (17,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (18,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (28,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (29,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (30,6);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (5,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (6,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (7,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (17,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (18,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (19,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (29,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (30,7);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (6,8);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (7,8);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (8,8);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (18,8);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (19,8);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (20,8);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (30,8);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (7,9);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (8,9);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (9,9);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (19,9);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (20,9);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (21,9);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (8,10);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (9,10);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (10,10);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (20,10);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (21,10);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (22,10);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (9,11);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (10,11);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (11,11);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (21,11);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (22,11);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (23,11);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (10,12);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (11,12);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (12,12);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (22,12);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (23,12);
INSERT dbo.[APPLICANT_SKILL] ([applicant_id],[skill_id]) VALUES (24,12);
SET IDENTITY_INSERT dbo.[JOB_AD] ON;
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (1,1,N'Database Developer',1.0,NULL,6500.0,10700.0,N'Riyadh');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (2,2,N'Data Analyst',2.0,NULL,7000.0,11400.0,N'Jeddah');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (3,3,N'Software Engineer',3.0,NULL,7500.0,12100.0,NULL);
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (4,4,N'Project Coordinator',0.0,NULL,NULL,NULL,N'Madinah');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (5,5,N'Accountant',NULL,NULL,8500.0,13500.0,N'Abha');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (6,6,N'Network Engineer',2.0,NULL,9000.0,14200.0,NULL);
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (7,7,N'Security Analyst',3.0,NULL,9500.0,14900.0,N'Jeddah');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (8,8,N'Customer Support Specialist',0.0,NULL,NULL,NULL,N'Dammam');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (9,9,N'Business Analyst',1.0,NULL,10500.0,16300.0,NULL);
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (10,10,N'Backend Developer',NULL,NULL,11000.0,17000.0,N'Abha');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (11,11,N'Systems Administrator',3.0,NULL,11500.0,17700.0,N'Riyadh');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (12,12,N'Operations Analyst',0.0,NULL,NULL,NULL,NULL);
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (13,1,N'Junior Developer',1.0,NULL,12500.0,19100.0,N'Dammam');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (14,2,N'Reporting Specialist',2.0,NULL,13000.0,19800.0,N'Madinah');
INSERT dbo.[JOB_AD] ([job_ad_id],[representative_id],[title],[min_years_experience],[gender_criterion],[min_salary],[max_salary],[city_criterion]) VALUES (15,3,N'IT Support Specialist',NULL,NULL,13500.0,20500.0,NULL);
SET IDENTITY_INSERT dbo.[JOB_AD] OFF;
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (1,1);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (12,1);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (13,1);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (1,2);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (2,2);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (13,2);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (14,2);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (2,3);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (3,3);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (14,3);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (3,4);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (4,4);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (4,5);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (6,6);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (6,7);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (7,7);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (7,8);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (8,8);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (8,9);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (9,9);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (9,10);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (11,11);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (11,12);
INSERT dbo.[JOB_SKILL_REQUIREMENT] ([job_ad_id],[skill_id]) VALUES (12,12);
SET IDENTITY_INSERT dbo.[JOB_QUAL_REQUIREMENT] ON;
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (1,1,3,N'Computer Science');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (2,2,3,N'Business Administration');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (3,3,3,NULL);
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (4,3,4,N'Accounting');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (5,5,3,N'Engineering');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (6,6,3,NULL);
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (7,6,4,N'Computer Science');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (8,7,3,N'Business Administration');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (9,9,3,NULL);
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (10,9,4,N'Information Systems');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (11,10,3,N'Engineering');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (12,11,3,N'Computer Science');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (13,13,3,N'Accounting');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (14,14,3,N'Information Systems');
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (15,15,3,NULL);
INSERT dbo.[JOB_QUAL_REQUIREMENT] ([job_qual_requirement_id],[job_ad_id],[qualification_type_id],[required_major]) VALUES (16,15,4,N'Engineering');
SET IDENTITY_INSERT dbo.[JOB_QUAL_REQUIREMENT] OFF;
SET IDENTITY_INSERT dbo.[APPLICATION] ON;
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (1,1,1,N'2026-08-01T10:48:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (2,1,6,N'2026-08-06T13:23:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (3,2,2,N'2026-08-05T13:36:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (4,2,7,N'2026-08-10T08:11:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (5,3,3,N'2026-08-09T08:24:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (6,3,8,N'2026-08-14T10:59:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (7,4,4,N'2026-08-13T11:12:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (8,4,9,N'2026-08-18T13:47:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (9,5,5,N'2026-08-17T14:00:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (10,5,10,N'2026-08-22T08:35:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (11,6,6,N'2026-08-21T08:48:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (12,6,11,N'2026-08-26T11:23:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (13,7,7,N'2026-08-25T11:36:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (14,7,12,N'2026-08-30T14:11:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (15,8,8,N'2026-08-29T14:24:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (16,8,13,N'2026-07-30T08:59:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (17,9,9,N'2026-07-29T09:12:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (18,9,14,N'2026-08-03T11:47:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (19,10,10,N'2026-08-02T12:00:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (20,10,15,N'2026-08-07T14:35:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (21,11,11,N'2026-08-06T14:48:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (22,11,1,N'2026-08-31T09:38:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (23,12,12,N'2026-08-10T09:36:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (24,12,2,N'2026-07-31T12:26:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (25,13,13,N'2026-08-14T12:24:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (26,13,3,N'2026-08-04T15:14:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (27,14,14,N'2026-08-18T15:12:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (28,14,4,N'2026-08-08T10:02:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (29,15,15,N'2026-08-22T10:00:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (30,15,5,N'2026-08-12T12:50:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (31,16,1,N'2026-08-11T13:03:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (32,16,6,N'2026-08-16T15:38:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (33,17,2,N'2026-08-15T15:51:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (34,17,7,N'2026-08-20T10:26:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (35,18,3,N'2026-08-19T10:39:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (36,18,8,N'2026-08-24T13:14:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (37,19,4,N'2026-08-23T13:27:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (38,19,9,N'2026-08-28T08:02:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (39,20,5,N'2026-08-27T08:15:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (40,20,10,N'2026-07-28T10:50:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (41,21,6,N'2026-08-31T11:03:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (42,21,11,N'2026-08-01T13:38:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (43,22,7,N'2026-07-31T13:51:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (44,22,12,N'2026-08-05T08:26:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (45,23,8,N'2026-08-04T08:39:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (46,23,13,N'2026-08-09T11:14:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (47,24,9,N'2026-08-08T11:27:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (48,24,14,N'2026-08-13T14:02:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (49,25,10,N'2026-08-12T14:15:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (50,25,15,N'2026-08-17T08:50:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (51,26,11,N'2026-08-16T09:03:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (52,26,1,N'2026-08-06T11:53:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (53,27,12,N'2026-08-20T11:51:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (54,27,2,N'2026-08-10T14:41:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (55,28,13,N'2026-08-24T14:39:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (56,28,3,N'2026-08-14T09:29:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (57,29,14,N'2026-08-28T09:27:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (58,29,4,N'2026-08-18T12:17:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (59,30,15,N'2026-07-28T12:15:00');
INSERT dbo.[APPLICATION] ([application_id],[applicant_id],[job_ad_id],[submitted_at]) VALUES (60,30,5,N'2026-08-22T15:05:00');
SET IDENTITY_INSERT dbo.[APPLICATION] OFF;
SET IDENTITY_INSERT dbo.[APPLICATION_STATUS_EVENT] ON;
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (1,1,N'Submitted',N'2026-08-01T10:48:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (2,2,N'Submitted',N'2026-08-06T13:23:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (3,2,N'Screening',N'2026-08-09T13:23:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (4,3,N'Submitted',N'2026-08-05T13:36:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (5,3,N'Screening',N'2026-08-08T13:36:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (6,3,N'Rejected',N'2026-08-11T13:36:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (7,4,N'Submitted',N'2026-08-10T08:11:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (8,4,N'Withdrawn',N'2026-08-13T08:11:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (9,5,N'Submitted',N'2026-08-09T08:24:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (10,5,N'Screening',N'2026-08-12T08:24:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (11,5,N'Interviewing',N'2026-08-15T08:24:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (12,6,N'Submitted',N'2026-08-14T10:59:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (13,6,N'Screening',N'2026-08-17T10:59:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (14,6,N'Interviewing',N'2026-08-20T10:59:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (15,6,N'Hired',N'2026-08-23T10:59:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (16,7,N'Submitted',N'2026-08-13T11:12:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (17,8,N'Submitted',N'2026-08-18T13:47:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (18,8,N'Screening',N'2026-08-21T13:47:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (19,9,N'Submitted',N'2026-08-17T14:00:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (20,9,N'Screening',N'2026-08-20T14:00:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (21,9,N'Rejected',N'2026-08-23T14:00:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (22,10,N'Submitted',N'2026-08-22T08:35:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (23,10,N'Withdrawn',N'2026-08-25T08:35:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (24,11,N'Submitted',N'2026-08-21T08:48:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (25,11,N'Screening',N'2026-08-24T08:48:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (26,11,N'Interviewing',N'2026-08-27T08:48:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (27,12,N'Submitted',N'2026-08-26T11:23:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (28,12,N'Screening',N'2026-08-29T11:23:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (29,12,N'Interviewing',N'2026-09-01T11:23:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (30,12,N'Hired',N'2026-09-04T11:23:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (31,13,N'Submitted',N'2026-08-25T11:36:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (32,14,N'Submitted',N'2026-08-30T14:11:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (33,14,N'Screening',N'2026-09-02T14:11:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (34,15,N'Submitted',N'2026-08-29T14:24:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (35,15,N'Screening',N'2026-09-01T14:24:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (36,15,N'Rejected',N'2026-09-04T14:24:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (37,16,N'Submitted',N'2026-07-30T08:59:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (38,16,N'Withdrawn',N'2026-08-02T08:59:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (39,17,N'Submitted',N'2026-07-29T09:12:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (40,17,N'Screening',N'2026-08-01T09:12:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (41,17,N'Interviewing',N'2026-08-04T09:12:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (42,18,N'Submitted',N'2026-08-03T11:47:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (43,18,N'Screening',N'2026-08-06T11:47:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (44,18,N'Interviewing',N'2026-08-09T11:47:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (45,18,N'Hired',N'2026-08-12T11:47:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (46,19,N'Submitted',N'2026-08-02T12:00:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (47,20,N'Submitted',N'2026-08-07T14:35:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (48,20,N'Screening',N'2026-08-10T14:35:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (49,21,N'Submitted',N'2026-08-06T14:48:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (50,21,N'Screening',N'2026-08-09T14:48:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (51,21,N'Rejected',N'2026-08-12T14:48:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (52,22,N'Submitted',N'2026-08-31T09:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (53,22,N'Withdrawn',N'2026-09-03T09:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (54,23,N'Submitted',N'2026-08-10T09:36:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (55,23,N'Screening',N'2026-08-13T09:36:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (56,23,N'Interviewing',N'2026-08-16T09:36:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (57,24,N'Submitted',N'2026-07-31T12:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (58,24,N'Screening',N'2026-08-03T12:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (59,24,N'Interviewing',N'2026-08-06T12:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (60,24,N'Hired',N'2026-08-09T12:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (61,25,N'Submitted',N'2026-08-14T12:24:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (62,26,N'Submitted',N'2026-08-04T15:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (63,26,N'Screening',N'2026-08-07T15:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (64,27,N'Submitted',N'2026-08-18T15:12:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (65,27,N'Screening',N'2026-08-21T15:12:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (66,27,N'Rejected',N'2026-08-24T15:12:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (67,28,N'Submitted',N'2026-08-08T10:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (68,28,N'Withdrawn',N'2026-08-11T10:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (69,29,N'Submitted',N'2026-08-22T10:00:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (70,29,N'Screening',N'2026-08-25T10:00:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (71,29,N'Interviewing',N'2026-08-28T10:00:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (72,30,N'Submitted',N'2026-08-12T12:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (73,30,N'Screening',N'2026-08-15T12:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (74,30,N'Interviewing',N'2026-08-18T12:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (75,30,N'Hired',N'2026-08-21T12:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (76,31,N'Submitted',N'2026-08-11T13:03:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (77,32,N'Submitted',N'2026-08-16T15:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (78,32,N'Screening',N'2026-08-19T15:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (79,33,N'Submitted',N'2026-08-15T15:51:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (80,33,N'Screening',N'2026-08-18T15:51:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (81,33,N'Rejected',N'2026-08-21T15:51:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (82,34,N'Submitted',N'2026-08-20T10:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (83,34,N'Withdrawn',N'2026-08-23T10:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (84,35,N'Submitted',N'2026-08-19T10:39:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (85,35,N'Screening',N'2026-08-22T10:39:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (86,35,N'Interviewing',N'2026-08-25T10:39:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (87,36,N'Submitted',N'2026-08-24T13:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (88,36,N'Screening',N'2026-08-27T13:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (89,36,N'Interviewing',N'2026-08-30T13:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (90,36,N'Hired',N'2026-09-02T13:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (91,37,N'Submitted',N'2026-08-23T13:27:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (92,38,N'Submitted',N'2026-08-28T08:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (93,38,N'Screening',N'2026-08-31T08:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (94,39,N'Submitted',N'2026-08-27T08:15:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (95,39,N'Screening',N'2026-08-30T08:15:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (96,39,N'Rejected',N'2026-09-02T08:15:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (97,40,N'Submitted',N'2026-07-28T10:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (98,40,N'Withdrawn',N'2026-07-31T10:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (99,41,N'Submitted',N'2026-08-31T11:03:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (100,41,N'Screening',N'2026-09-03T11:03:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (101,41,N'Interviewing',N'2026-09-06T11:03:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (102,42,N'Submitted',N'2026-08-01T13:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (103,42,N'Screening',N'2026-08-04T13:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (104,42,N'Interviewing',N'2026-08-07T13:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (105,42,N'Hired',N'2026-08-10T13:38:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (106,43,N'Submitted',N'2026-07-31T13:51:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (107,44,N'Submitted',N'2026-08-05T08:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (108,44,N'Screening',N'2026-08-08T08:26:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (109,45,N'Submitted',N'2026-08-04T08:39:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (110,45,N'Screening',N'2026-08-07T08:39:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (111,45,N'Rejected',N'2026-08-10T08:39:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (112,46,N'Submitted',N'2026-08-09T11:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (113,46,N'Withdrawn',N'2026-08-12T11:14:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (114,47,N'Submitted',N'2026-08-08T11:27:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (115,47,N'Screening',N'2026-08-11T11:27:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (116,47,N'Interviewing',N'2026-08-14T11:27:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (117,48,N'Submitted',N'2026-08-13T14:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (118,48,N'Screening',N'2026-08-16T14:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (119,48,N'Interviewing',N'2026-08-19T14:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (120,48,N'Hired',N'2026-08-22T14:02:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (121,49,N'Submitted',N'2026-08-12T14:15:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (122,50,N'Submitted',N'2026-08-17T08:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (123,50,N'Screening',N'2026-08-20T08:50:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (124,51,N'Submitted',N'2026-08-16T09:03:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (125,51,N'Screening',N'2026-08-19T09:03:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (126,51,N'Rejected',N'2026-08-22T09:03:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (127,52,N'Submitted',N'2026-08-06T11:53:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (128,52,N'Withdrawn',N'2026-08-09T11:53:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (129,53,N'Submitted',N'2026-08-20T11:51:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (130,53,N'Screening',N'2026-08-23T11:51:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (131,53,N'Interviewing',N'2026-08-26T11:51:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (132,54,N'Submitted',N'2026-08-10T14:41:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (133,54,N'Screening',N'2026-08-13T14:41:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (134,54,N'Interviewing',N'2026-08-16T14:41:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (135,54,N'Hired',N'2026-08-19T14:41:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (136,55,N'Submitted',N'2026-08-24T14:39:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (137,56,N'Submitted',N'2026-08-14T09:29:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (138,56,N'Screening',N'2026-08-17T09:29:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (139,57,N'Submitted',N'2026-08-28T09:27:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (140,57,N'Screening',N'2026-08-31T09:27:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (141,57,N'Rejected',N'2026-09-03T09:27:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (142,58,N'Submitted',N'2026-08-18T12:17:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (143,58,N'Withdrawn',N'2026-08-21T12:17:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (144,59,N'Submitted',N'2026-07-28T12:15:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (145,59,N'Screening',N'2026-07-31T12:15:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (146,59,N'Interviewing',N'2026-08-03T12:15:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (147,60,N'Submitted',N'2026-08-22T15:05:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (148,60,N'Screening',N'2026-08-25T15:05:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (149,60,N'Interviewing',N'2026-08-28T15:05:00');
INSERT dbo.[APPLICATION_STATUS_EVENT] ([status_event_id],[application_id],[status],[changed_at]) VALUES (150,60,N'Hired',N'2026-08-31T15:05:00');
SET IDENTITY_INSERT dbo.[APPLICATION_STATUS_EVENT] OFF;
ENABLE TRIGGER dbo.tr_APPLICATION_initial_status ON dbo.APPLICATION;
COMMIT;
GO

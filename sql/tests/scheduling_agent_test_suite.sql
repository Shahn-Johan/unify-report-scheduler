-- ============================================================
--  SCHEDULING AGENT  |  COMPLETE TEST SUITE
--  Every meaningful combination of schedule, dispatch mode,
--  delivery method, email source, and resolver type.
--
--  RUN ORDER:
--    1. Section 0  -- prerequisite lookup objects
--    2. Section 1  -- frequency type tests        (5 schedules)
--    3. Section 2  -- dispatch mode tests         (3 schedules)
--    4. Section 3  -- delivery method tests       (3 schedules)
--    5. Section 4  -- email source tests          (4 schedules)
--    6. Section 5  -- resolver combination tests  (6 schedules)
--    7. Section 6  -- parameter-free tests        (2 schedules)
--    8. Section 7  -- test execution commands
-- ============================================================


-- ============================================================
--  SECTION 0  PREREQUISITE LOOKUP OBJECTS
--  Simulate the real tables with stub data so every resolver
--  type can be tested without needing production tables.
-- ============================================================

-- Stub table backing all views below
IF OBJECT_ID('dbo.TestEntity', 'U') IS NOT NULL DROP TABLE dbo.TestEntity;
CREATE TABLE dbo.TestEntity (
    EntityCode      NVARCHAR(50)    NOT NULL PRIMARY KEY,
    EntityName      NVARCHAR(255)   NOT NULL,
    EmailAddress    NVARCHAR(320)   NOT NULL,
    FolderPath      NVARCHAR(1000)  NOT NULL,
    FileName        NVARCHAR(500)   NOT NULL
);
GO

INSERT INTO dbo.TestEntity (EntityCode, EntityName, EmailAddress, FolderPath, FileName)
VALUES
    ('E001', 'Entity One',   'e001@test.com', '\\server\reports\E001\', 'E001_Report.xlsx'),
    ('E002', 'Entity Two',   'e002@test.com', '\\server\reports\E002\', 'E002_Report.xlsx'),
    ('E003', 'Entity Three', 'e003@test.com', '\\server\reports\E003\', 'E003_Report.xlsx');
GO

-- LOOKUP_VIEW for email (LookupKey + EmailAddress)
CREATE OR ALTER VIEW [schdl].[vw_TestEmail]
AS
    SELECT EntityCode AS LookupKey, EmailAddress FROM dbo.TestEntity;
GO

-- LOOKUP_VIEW for display name (LookupKey + DisplayName)
CREATE OR ALTER VIEW [schdl].[vw_TestDisplayName]
AS
    SELECT EntityCode AS LookupKey, EntityName AS DisplayName FROM dbo.TestEntity;
GO

-- LOOKUP_VIEW for folder path (LookupKey + FolderPath)
CREATE OR ALTER VIEW [schdl].[vw_TestFolderPath]
AS
    SELECT EntityCode AS LookupKey, FolderPath FROM dbo.TestEntity;
GO

-- LOOKUP_VIEW for filename (LookupKey + FileName)
CREATE OR ALTER VIEW [schdl].[vw_TestFileName]
AS
    SELECT EntityCode AS LookupKey, FileName FROM dbo.TestEntity;
GO

-- Combined view — all four resolvers from one view
CREATE OR ALTER VIEW [schdl].[vw_TestAll]
AS
    SELECT
        EntityCode  AS LookupKey,
        EmailAddress,
        EntityName  AS DisplayName,
        FolderPath,
        FileName
    FROM dbo.TestEntity;
GO

-- SCALAR_FN for email
CREATE OR ALTER FUNCTION [dbo].[fn_TestGetEmail]
(
    @EntityCode NVARCHAR(50)
)
RETURNS NVARCHAR(320)
AS
BEGIN
    DECLARE @Email NVARCHAR(320);
    SELECT @Email = EmailAddress FROM dbo.TestEntity WHERE EntityCode = @EntityCode;
    RETURN @Email;
END;
GO

-- SCALAR_FN for display name
CREATE OR ALTER FUNCTION [dbo].[fn_TestGetDisplayName]
(
    @EntityCode NVARCHAR(50)
)
RETURNS NVARCHAR(500)
AS
BEGIN
    DECLARE @Name NVARCHAR(500);
    SELECT @Name = EntityName FROM dbo.TestEntity WHERE EntityCode = @EntityCode;
    RETURN @Name;
END;
GO

-- SCALAR_FN for folder path
CREATE OR ALTER FUNCTION [dbo].[fn_TestGetFolderPath]
(
    @EntityCode NVARCHAR(50)
)
RETURNS NVARCHAR(1000)
AS
BEGIN
    DECLARE @Folder NVARCHAR(1000);
    SELECT @Folder = FolderPath FROM dbo.TestEntity WHERE EntityCode = @EntityCode;
    RETURN @Folder;
END;
GO


-- ============================================================
--  SECTION 1  FREQUENCY TYPE TESTS
--  One schedule per FrequencyType, all using BULK+STATIC
--  to keep delivery simple while testing the timing logic.
-- ============================================================

-- 1.1  DAILY
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Daily',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-FREQ-01 Daily at 07:00',
    @FrequencyType   = 'DAILY',
    @RunTime         = '07:00',
    @Subject         = 'Daily Test - {{TODAY}}',
    @BodyTemplate    = 'Daily report for {{TODAY}}.',
    @ParametersJson  = N'[
        {
            "name": "AsOfDate", "type": "date", "required": true, "sortOrder": 1,
            "value": "{{TODAY}}",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC", "bulkEmail": "test-daily@example.com"
            }
        }
    ]',
    @RecipientsJson  = N'[{"name":"Daily CC","email":"daily-cc@example.com","role":"CC"}]';
GO

-- 1.2  WEEKLY (Monday)
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Weekly',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-FREQ-02 Weekly Monday 08:00',
    @FrequencyType   = 'WEEKLY',
    @RunTime         = '08:00',
    @DayOfWeek       = 1,
    @Subject         = 'Weekly Test - {{PREV_WEEK_START}} to {{PREV_WEEK_END}}',
    @BodyTemplate    = 'Weekly report covering {{PREV_WEEK_START}} to {{PREV_WEEK_END}}.',
    @ParametersJson  = N'[
        {
            "name": "WeekStart", "type": "date", "required": true, "sortOrder": 1,
            "value": "{{PREV_WEEK_START}}",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC", "bulkEmail": "test-weekly@example.com"
            }
        },
        { "name": "WeekEnd", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_WEEK_END}}" }
    ]';
GO

-- 1.3  MONTHLY (1st of month)
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Monthly',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-FREQ-03 Monthly 1st at 06:00',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Monthly Test - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}',
    @BodyTemplate    = 'Monthly report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.',
    @ParametersJson  = N'[
        {
            "name": "StartDate", "type": "date", "required": true, "sortOrder": 1,
            "value": "{{PREV_MONTH_START}}",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC", "bulkEmail": "test-monthly@example.com"
            }
        },
        { "name": "EndDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 1.4  MONTHLY (last day of month)
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Monthly Last Day',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-FREQ-04 Monthly Last Day 23:00',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '23:00',
    @DayOfMonth      = -1,
    @Subject         = 'Month End Test - {{MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "ReportDate", "type": "date", "required": true, "sortOrder": 1,
            "value": "{{MONTH_END}}",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC", "bulkEmail": "test-monthend@example.com"
            }
        }
    ]';
GO

-- 1.5  ADHOC (fires once then disables)
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Adhoc',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-FREQ-05 Adhoc One Shot',
    @FrequencyType   = 'ADHOC',
    @Subject         = 'Adhoc Test - {{TODAY}}',
    @ParametersJson  = N'[
        {
            "name": "RunDate", "type": "date", "required": true, "sortOrder": 1,
            "value": "{{TODAY}}",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC", "bulkEmail": "test-adhoc@example.com"
            }
        }
    ]';
GO

-- 1.6  INTERVAL (every 60 minutes, 07:00–19:00 window)
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Interval',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-FREQ-06 Interval 60min 07:00-19:00',
    @FrequencyType   = 'INTERVAL',
    @IntervalMinutes = 60,
    @WindowStart     = '07:00',
    @WindowEnd       = '19:00',
    @Subject         = 'Interval Test - {{TODAY}}',
    @ParametersJson  = N'[
        {
            "name": "AsOf", "type": "date", "required": true, "sortOrder": 1,
            "value": "{{TODAY}}",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC", "bulkEmail": "test-interval@example.com"
            }
        }
    ]';
GO


-- ============================================================
--  SECTION 2  DISPATCH MODE TESTS
--  Tests BULK, INDIVIDUAL, BOTH — all using STATIC email
--  and LOOKUP_VIEW so both dispatch paths are exercised.
-- ============================================================

-- 2.1  BULK — all values in one request, one email
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Dispatch',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-DISP-01 COMBINED Mode',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Bulk Dispatch Test - {{PREV_MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC",
                "bulkEmail": "bulk-recipient@example.com"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]',
    @RecipientsJson  = N'[{"name":"Bulk BCC","email":"bulk-bcc@example.com","role":"BCC"}]';
GO

-- 2.2  INDIVIDUAL — one request per value, email resolved per value
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Dispatch',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-DISP-02 INDIVIDUAL Mode',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Individual Dispatch Test - {{PREV_MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource": "LOOKUP_VIEW",
                "emailSourceValue": "schdl.vw_TestEmail"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]',
    @RecipientsJson  = N'[{"name":"Ind CC","email":"individual-cc@example.com","role":"CC"}]';
GO

-- 2.3  BOTH — individual rows + one bulk row
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Dispatch',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-DISP-03 BOTH Mode',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Both Dispatch Test - {{PREV_MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "BOTH", "deliveryMethod": "EMAIL",
                "emailSource": "LOOKUP_VIEW",
                "emailSourceValue": "schdl.vw_TestEmail",
                "bulkEmail": "bulk-summary@example.com"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO


-- ============================================================
--  SECTION 3  DELIVERY METHOD TESTS
--  EMAIL only, FOLDER only, BOTH.
-- ============================================================

-- 3.1  EMAIL only delivery
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Delivery',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-DELIV-01 EMAIL Delivery',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Email Delivery Test - {{PREV_MONTH_END}}',
    @BodyTemplate    = 'Report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}} attached.',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource":            "LOOKUP_VIEW",
                "emailSourceValue":       "schdl.vw_TestEmail",
                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_TestDisplayName"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 3.2  FOLDER only delivery
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Delivery',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-DELIV-02 FOLDER Delivery',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = NULL,
    @BodyTemplate    = NULL,
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "FOLDER",
                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_TestDisplayName",
                "fileNameTemplate":       "Report_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx",
                "folderSource":           "LOOKUP_VIEW",
                "folderSourceValue":      "schdl.vw_TestFolderPath",
                "bulkFolderPath":         "\\server\reports\Bulk\"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 3.3  BOTH delivery — email AND folder drop per row
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Delivery',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-DELIV-03 BOTH Delivery',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Both Delivery Test - {{PREV_MONTH_END}}',
    @BodyTemplate    = 'Report attached and dropped to your folder.',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "BOTH", "deliveryMethod": "BOTH",
                "emailSource":            "LOOKUP_VIEW",
                "emailSourceValue":       "schdl.vw_TestEmail",
                "bulkEmail":              "bulk-both@example.com",
                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_TestDisplayName",
                "fileNameTemplate":       "Report_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx",
                "folderSource":           "LOOKUP_VIEW",
                "folderSourceValue":      "schdl.vw_TestFolderPath",
                "bulkFolderPath":         "\\server\reports\Bulk\"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]',
    @RecipientsJson  = N'[{"name":"Both CC","email":"both-cc@example.com","role":"CC"}]';
GO


-- ============================================================
--  SECTION 4  EMAIL SOURCE TESTS
--  One schedule per EmailSource type (STATIC, LOOKUP_VIEW,
--  SCALAR_FN, DYNAMIC_SQL). All INDIVIDUAL so every value
--  triggers a lookup.
-- ============================================================

-- 4.1  STATIC email — literal address, no lookup
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Email Source',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-ESRC-01 STATIC Email',
    @FrequencyType   = 'DAILY',
    @RunTime         = '07:00',
    @Subject         = 'Static Email Test - {{TODAY}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "COMBINED", "deliveryMethod": "EMAIL",
                "emailSource": "STATIC",
                "bulkEmail":   "static-recipient@example.com"
            }
        }
    ]';
GO

-- 4.2  LOOKUP_VIEW email — email resolved from view per value
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Email Source',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-ESRC-02 LOOKUP_VIEW Email',
    @FrequencyType   = 'DAILY',
    @RunTime         = '07:00',
    @Subject         = 'Lookup View Email Test - {{TODAY}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource":      "LOOKUP_VIEW",
                "emailSourceValue": "schdl.vw_TestEmail"
            }
        }
    ]';
GO

-- 4.3  SCALAR_FN email — email resolved via scalar function per value
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Email Source',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-ESRC-03 SCALAR_FN Email',
    @FrequencyType   = 'DAILY',
    @RunTime         = '07:00',
    @Subject         = 'Scalar Fn Email Test - {{TODAY}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource":      "SCALAR_FN",
                "emailSourceValue": "dbo.fn_TestGetEmail"
            }
        }
    ]';
GO

-- 4.4  DYNAMIC_SQL email — email resolved via inline SQL per value
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Email Source',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-ESRC-04 DYNAMIC_SQL Email',
    @FrequencyType   = 'DAILY',
    @RunTime         = '07:00',
    @Subject         = 'Dynamic SQL Email Test - {{TODAY}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource":      "DYNAMIC_SQL",
                "emailSourceValue": "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        }
    ]';
GO


-- ============================================================
--  SECTION 5  RESOLVER COMBINATION TESTS
--  DisplayName, FileName, FolderPath resolvers tested in
--  isolation and in combination.
-- ============================================================

-- 5.1  DisplayName only — LOOKUP_VIEW, appended to email subject
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Resolvers',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-RES-01 DisplayName LOOKUP_VIEW',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Resolver Test - {{PREV_MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource":            "LOOKUP_VIEW",
                "emailSourceValue":       "schdl.vw_TestEmail",
                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_TestDisplayName"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.2  FileName via SCALAR_FN
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Resolvers',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-RES-02 FileName SCALAR_FN',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Filename Scalar Test - {{PREV_MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource":      "LOOKUP_VIEW",
                "emailSourceValue": "schdl.vw_TestEmail",
                "fileNameSource":   "SCALAR_FN",
                "fileNameSourceValue": "dbo.fn_TestGetEmail"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.3  FileNameTemplate with {{DISPLAYNAME}} and {{TOKEN}}
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Resolvers',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-RES-03 FileNameTemplate',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'FileNameTemplate Test - {{PREV_MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "EMAIL",
                "emailSource":            "LOOKUP_VIEW",
                "emailSourceValue":       "schdl.vw_TestEmail",
                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_TestDisplayName",
                "fileNameTemplate":       "Report_{{DISPLAYNAME}}_{{PREV_MONTH_START}}_{{PREV_MONTH_END}}.xlsx"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.4  FolderPath via DYNAMIC_SQL
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Resolvers',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-RES-04 FolderPath DYNAMIC_SQL',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = NULL,
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "INDIVIDUAL", "deliveryMethod": "FOLDER",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS DisplayName FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "fileNameTemplate":       "Report_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx",
                "folderSource":           "DYNAMIC_SQL",
                "folderSourceValue":      "SELECT FolderPath FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "bulkFolderPath":         "\\server\reports\Bulk\"
            }
        },
        { "name": "ReportDate", "type": "date", "required": true, "sortOrder": 2,
          "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.5  All four resolvers from one combined view (EMAIL+FOLDER BOTH)
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Resolvers',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-RES-05 All Resolvers Combined View',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'All Resolvers Test - {{PREV_MONTH_END}}',
    @BodyTemplate    = 'Report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "BOTH", "deliveryMethod": "BOTH",
                "emailSource":            "LOOKUP_VIEW",
                "emailSourceValue":       "schdl.vw_TestAll",
                "bulkEmail":              "bulk-all@example.com",
                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_TestAll",
                "fileNameTemplate":       "Report_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx",
                "folderSource":           "LOOKUP_VIEW",
                "folderSourceValue":      "schdl.vw_TestAll",
                "bulkFolderPath":         "\\server\reports\Bulk\"
            }
        },
        { "name": "ReportDate",  "type": "date",   "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" },
        { "name": "StartDate",   "type": "date",   "required": true, "sortOrder": 3, "value": "{{PREV_MONTH_START}}" },
        { "name": "EntityType",  "type": "string", "required": true, "sortOrder": 4, "value": "ENTITY" },
        { "name": "PaymentTerms","type": "string", "required": true, "sortOrder": 5, "value": "0|1|2|3|4" }
    ]',
    @RecipientsJson  = N'[
        {"name":"CC Recipient", "email":"cc@example.com",  "role":"CC"},
        {"name":"BCC Audit",    "email":"bcc@example.com", "role":"BCC"}
    ]';
GO

-- 5.6  Multiple non-primary parameters with mixed types
--      Tests that string values like "0|1|2" never get date-resolved
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - Multi Param',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-RES-06 Multi Param Mixed Types',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00',
    @DayOfMonth      = 1,
    @Subject         = 'Multi Param Test - {{PREV_MONTH_END}}',
    @ParametersJson  = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "dispatch": {
                "isPrimary": true, "mode": "BOTH", "deliveryMethod": "EMAIL",
                "emailSource":      "LOOKUP_VIEW",
                "emailSourceValue": "schdl.vw_TestEmail",
                "bulkEmail":        "bulk-multi@example.com",
                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_TestDisplayName",
                "fileNameTemplate":       "MultiParam_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx"
            }
        },
        { "name": "DateFrom",    "type": "date",   "required": true,  "sortOrder": 2, "value": "{{PREV_MONTH_START}}" },
        { "name": "DateTo",      "type": "date",   "required": true,  "sortOrder": 3, "value": "{{PREV_MONTH_END}}" },
        { "name": "PaymentTerm", "type": "string", "required": true,  "sortOrder": 4, "value": "0|1|2|3|4" },
        { "name": "ProductID",   "type": "string", "required": true,  "sortOrder": 5, "value": "17110|16970" },
        { "name": "Year",        "type": "date",   "required": true,  "sortOrder": 6, "value": "{{YEAR}}" },
        { "name": "IsActive",    "type": "string", "required": false, "sortOrder": 7, "value": "1" }
    ]',
    @RecipientsJson  = N'[{"name":"Test CC","email":"testcc@example.com","role":"CC"}]';
GO


-- ============================================================
--  SECTION 6  PARAMETER-FREE TESTS
--  Reports that execute with no parameters at all.
-- ============================================================

-- 6.1  No parameters, EMAIL delivery, static recipient
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - No Params',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-NOPARAM-01 No Params Email',
    @FrequencyType   = 'DAILY',
    @RunTime         = '07:00',
    @Subject         = 'No Param Report - {{TODAY}}',
    @BodyTemplate    = 'Attached is the no-parameter report for {{TODAY}}.',
    @ParametersJson  = NULL,
    @RecipientsJson  = N'[
        {"name":"No Param TO",  "email":"noparam-to@example.com",  "role":"TO"},
        {"name":"No Param CC",  "email":"noparam-cc@example.com",  "role":"CC"},
        {"name":"No Param BCC", "email":"noparam-bcc@example.com", "role":"BCC"}
    ]';
GO

-- 6.2  No parameters, weekly, multiple TO recipients
EXEC schdl.usp_RegisterSchedule
    @DocumentName    = 'Test Report - No Params Weekly',
    @ReportEndpoint  = '/api/reports/generate',
    @ScheduleName    = 'TEST-NOPARAM-02 No Params Weekly Multiple TO',
    @FrequencyType   = 'WEEKLY',
    @RunTime         = '08:00',
    @DayOfWeek       = 1,
    @Subject         = 'Weekly No Param - {{PREV_WEEK_START}} to {{PREV_WEEK_END}}',
    @ParametersJson  = NULL,
    @RecipientsJson  = N'[
        {"name":"Recipient One", "email":"rec1@example.com", "role":"TO"},
        {"name":"Recipient Two", "email":"rec2@example.com", "role":"TO"},
        {"name":"Recipient Three","email":"rec3@example.com","role":"TO"}
    ]';
GO


-- ============================================================
--  SECTION 7  TEST EXECUTION COMMANDS
--  Run these to verify all schedules produce correct output.
--  usp_TestDispatch bypasses all timing gates.
-- ============================================================

-- ── Quick test: verify a single schedule ─────────────────────
-- EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-DISP-03 BOTH Mode';

-- ── Expected output checks after running usp_TestDispatch ────
-- TEST-DISP-01 COMBINED Mode        → 1 row,  DispatchType=BULK,       ToAddresses='bulk-recipient@example.com'
-- TEST-DISP-02 INDIVIDUAL Mode  → 3 rows, DispatchType=INDIVIDUAL, ToAddresses resolved per entity
-- TEST-DISP-03 BOTH Mode        → 4 rows (3 INDIVIDUAL + 1 BULK)
-- TEST-DELIV-02 FOLDER Delivery → 3 rows, FolderPath populated,    ToAddresses=''
-- TEST-DELIV-03 BOTH Delivery   → 4 rows, FolderPath + ToAddresses both populated
-- TEST-RES-03 FileNameTemplate  → FileName = 'Report_Entity One_2026-05-01_2026-05-31.xlsx' etc
-- TEST-RES-05 All Resolvers     → 4 rows, all columns populated:   DisplayName, FileName, ToAddresses, FolderPath
-- TEST-RES-06 Multi Param       → PaymentTerm values must be "0","1","2","3","4" NOT dates
-- TEST-NOPARAM-01               → 1 row,  parameters:[] in RequestJson
-- TEST-FREQ-05 Adhoc            → fires once, then IsActive=0

-- ── Run all test schedules in one batch ──────────────────────
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-FREQ-01 Daily at 07:00';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-FREQ-02 Weekly Monday 08:00';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-FREQ-03 Monthly 1st at 06:00';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-FREQ-04 Monthly Last Day 23:00';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-FREQ-05 Adhoc One Shot';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-FREQ-06 Interval 60min 07:00-19:00';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-DISP-01 COMBINED Mode';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-DISP-02 INDIVIDUAL Mode';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-DISP-03 BOTH Mode';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-DELIV-01 EMAIL Delivery';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-DELIV-02 FOLDER Delivery';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-DELIV-03 BOTH Delivery';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-ESRC-01 STATIC Email';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-ESRC-02 LOOKUP_VIEW Email';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-ESRC-03 SCALAR_FN Email';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-ESRC-04 DYNAMIC_SQL Email';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-RES-01 DisplayName LOOKUP_VIEW';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-RES-02 FileName SCALAR_FN';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-RES-03 FileNameTemplate';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-RES-04 FolderPath DYNAMIC_SQL';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-RES-05 All Resolvers Combined View';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-RES-06 Multi Param Mixed Types';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-NOPARAM-01 No Params Email';
EXEC schdl.usp_TestDispatch @ScheduleName = 'TEST-NOPARAM-02 No Params Weekly Multiple TO';


-- ── Verify gate logic with usp_GetDueSchedules ───────────────
-- Pass a timestamp that matches a specific schedule to verify
-- the gate diagnostic returns all Y for that schedule.

-- Should fire TEST-FREQ-01 (Daily at 07:00):
EXEC schdl.usp_GetDueSchedules @AsOf = '2026-06-09 07:00:00';

-- Should fire TEST-FREQ-02 (Weekly Monday 08:00) — find a Monday:
EXEC schdl.usp_GetDueSchedules @AsOf = '2026-06-09 08:00:00';

-- Should fire TEST-FREQ-03 (Monthly 1st at 06:00):
EXEC schdl.usp_GetDueSchedules @AsOf = '2026-07-01 06:00:00';

-- Should fire TEST-FREQ-04 (Monthly Last Day 23:00) — June 30:
EXEC schdl.usp_GetDueSchedules @AsOf = '2026-06-30 23:00:00';

-- Should fire TEST-FREQ-06 (Interval 60min 07:00-19:00):
EXEC schdl.usp_GetDueSchedules @AsOf = '2026-06-09 09:00:00';


-- ── Inspect results kept in DispatchQueue ────────────────────
-- Run with @KeepResults=1 then query for specific checks:

EXEC schdl.usp_TestDispatch
    @ScheduleName = 'TEST-RES-05 All Resolvers Combined View',
    @KeepResults  = 1;

SELECT
    QueueID, DispatchType, DeliveryMethod, DispatchKeyValue,
    DisplayName, FileName, ToAddresses, FolderPath,
    LEFT(RequestJson, 300) AS RequestJsonPreview
FROM schdl.DispatchQueue
WHERE Status = 'PENDING'
ORDER BY DispatchType DESC, DispatchKeyValue;

-- Clean up after inspection
-- DELETE FROM schdl.DispatchQueue WHERE Status = ''PENDING'';
-- DELETE FROM schdl.ExecutionLog  WHERE Status = ''PENDING'';

-- ── Verify date token resolution on every token ───────────────
SELECT
    TokenID, Token, Category, Description,
    schdl.fn_ResolveDateToken(Token, CAST('2026-06-09' AS DATE)) AS ResolvedFor_20260609,
    schdl.fn_ResolveDateToken(Token, CAST('2026-07-01' AS DATE)) AS ResolvedFor_20260701,
    schdl.fn_ResolveDateToken(Token, CAST('2026-12-31' AS DATE)) AS ResolvedFor_20261231
FROM schdl.DateToken
WHERE IsActive = 1
ORDER BY Category, TokenID;

-- ── Verify fn_FetchDocumentId for each registered document ───
SELECT
    DocumentName,
    schdl.fn_FetchDocumentId(DocumentName) AS ResolvedDocumentId,
    CASE WHEN schdl.fn_FetchDocumentId(DocumentName) IS NULL
         THEN ''WARNING: NULL - check fn_FetchDocumentId body''
         ELSE ''OK'' END AS Status
FROM schdl.Document
ORDER BY DocumentName;

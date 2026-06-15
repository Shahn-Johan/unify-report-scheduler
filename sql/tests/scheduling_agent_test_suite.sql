-- ============================================================
--  SCHEDULING AGENT v3  |  COMPLETE TEST SUITE
--  Every meaningful combination of schedule, dispatch mode,
--  delivery method, and resolver type.
--
--  RUN ORDER:
--    1. Section 0  -- prerequisite stub data
--    2. Section 1  -- frequency type tests        (6 schedules)
--    3. Section 2  -- dispatch mode tests         (3 schedules)
--    4. Section 3  -- delivery method tests       (3 schedules)
--    5. Section 4  -- email source tests          (3 schedules)
--    6. Section 5  -- resolver combination tests  (6 schedules)
--    7. Section 6  -- parameter-free tests        (2 schedules)
--    8. Section 7  -- test execution commands
-- ============================================================


-- ============================================================
--  SECTION 0  PREREQUISITE STUB DATA
--  dbo.TestEntity backs all DYNAMIC_SQL queries in this suite.
--  LOOKUP_VIEW and SCALAR_FN source types are not supported in
--  v3 — DYNAMIC_SQL queries reference dbo.TestEntity directly.
-- ============================================================

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


-- ============================================================
--  SECTION 1  FREQUENCY TYPE TESTS
--  One schedule per FrequencyType. All use COMBINED delivery
--  with a STATIC email address to isolate timing logic.
-- ============================================================

-- 1.1  DAILY
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Daily',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-FREQ-01 Daily at 07:00',
    @FrequencyType   = N'DAILY',
    @RunTime         = N'07:00',
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "test-daily@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Daily Test - {{TODAY}}"
    }',
    @ParametersJson = N'[
        { "name": "AsOfDate", "type": "string", "required": true, "sortOrder": 1, "value": "{{TODAY}}" }
    ]';
GO

-- 1.2  WEEKLY (Monday)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Weekly',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-FREQ-02 Weekly Monday 08:00',
    @FrequencyType   = N'WEEKLY',
    @RunTime         = N'08:00',
    @DayOfWeek       = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "test-weekly@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Weekly Test - {{PREV_WEEK_START}} to {{PREV_WEEK_END}}"
    }',
    @ParametersJson = N'[
        { "name": "WeekStart", "type": "string", "required": true, "sortOrder": 1, "value": "{{PREV_WEEK_START}}" },
        { "name": "WeekEnd",   "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_WEEK_END}}"   }
    ]';
GO

-- 1.3  MONTHLY (1st of month)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Monthly',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-FREQ-03 Monthly 1st at 06:00',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "test-monthly@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Monthly Test - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        { "name": "StartDate", "type": "string", "required": true, "sortOrder": 1, "value": "{{PREV_MONTH_START}}" },
        { "name": "EndDate",   "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}"   }
    ]';
GO

-- 1.4  MONTHLY (last day of month — DayOfMonth = -1)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Monthly Last Day',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-FREQ-04 Monthly Last Day 23:00',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'23:00',
    @DayOfMonth      = -1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "test-monthend@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Month End Test - {{MONTH_END}}"
    }',
    @ParametersJson = N'[
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 1, "value": "{{MONTH_END}}" }
    ]';
GO

-- 1.5  ADHOC (fires once then sets IsActive = 0)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Adhoc',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-FREQ-05 Adhoc One Shot',
    @FrequencyType   = N'ADHOC',
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "test-adhoc@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Adhoc Test - {{TODAY}}"
    }',
    @ParametersJson = N'[
        { "name": "RunDate", "type": "string", "required": true, "sortOrder": 1, "value": "{{TODAY}}" }
    ]';
GO

-- 1.6  INTERVAL (every 60 minutes, 07:00-19:00 window)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Interval',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-FREQ-06 Interval 60min 07:00-19:00',
    @FrequencyType   = N'INTERVAL',
    @IntervalMinutes = 60,
    @WindowStart     = N'07:00',
    @WindowEnd       = N'19:00',
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "test-interval@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Interval Test - {{TODAY}}"
    }',
    @ParametersJson = N'[
        { "name": "AsOf", "type": "string", "required": true, "sortOrder": 1, "value": "{{TODAY}}" }
    ]';
GO


-- ============================================================
--  SECTION 2  DISPATCH MODE TESTS
--  Tests COMBINED, INDIVIDUAL, BOTH dispatch modes.
-- ============================================================

-- 2.1  COMBINED -- all values in one request, one email
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Dispatch',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-DISP-01 COMBINED Mode',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "combined-recipient@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Combined Dispatch Test - {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        { "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1, "value": "E001|E002|E003" },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]',
    @RecipientsJson = N'[{ "email": "combined-bcc@example.com", "role": "BCC", "includeInFanOut": false }]';
GO

-- 2.2  INDIVIDUAL -- one request per value, email resolved per entity
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Dispatch',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-DISP-02 INDIVIDUAL Mode',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "fallback@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Individual Dispatch Test - {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":       true,
                "mode":            "INDIVIDUAL",
                "emailSource":     "DYNAMIC_SQL",
                "emailSourceValue":"SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]',
    @RecipientsJson = N'[{ "email": "individual-cc@example.com", "role": "CC", "includeInFanOut": true }]';
GO

-- 2.3  BOTH -- individual rows AND one combined row
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Dispatch',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-DISP-03 BOTH Mode',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "bulk-summary@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Both Dispatch Test - {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":       true,
                "mode":            "BOTH",
                "emailSource":     "DYNAMIC_SQL",
                "emailSourceValue":"SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO


-- ============================================================
--  SECTION 3  DELIVERY METHOD TESTS
--  EMAIL only, FOLDER only, BOTH.
-- ============================================================

-- 3.1  EMAIL only delivery
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Delivery',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-DELIV-01 EMAIL Delivery',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "fallback@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Email Delivery Test - {{PREV_MONTH_END}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}} attached."
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "INDIVIDUAL",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 3.2  FOLDER only delivery
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Delivery',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-DELIV-02 FOLDER Delivery',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "FOLDER",
        "folderSource":        "STATIC",
        "folderSourceValue":   "\\\\server\\reports\\combined",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "Report_Consolidated_{{PREV_MONTH_END}}.xlsx"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "INDIVIDUAL",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "Report_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx",
                "folderSource":           "DYNAMIC_SQL",
                "folderSourceValue":      "SELECT FolderPath FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 3.3  BOTH delivery -- email AND folder drop per row
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Delivery',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-DELIV-03 BOTH Delivery',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "BOTH",
        "emailSource":         "STATIC",
        "emailSourceValue":    "bulk-both@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Both Delivery Test - {{PREV_MONTH_END}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Report attached and dropped to your folder.",
        "folderSource":        "STATIC",
        "folderSourceValue":   "\\\\server\\reports\\combined"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "BOTH",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "folderSource":           "DYNAMIC_SQL",
                "folderSourceValue":      "SELECT FolderPath FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]',
    @RecipientsJson = N'[{ "email": "both-cc@example.com", "role": "CC", "includeInFanOut": true }]';
GO


-- ============================================================
--  SECTION 4  EMAIL SOURCE TESTS
--  STATIC and DYNAMIC_SQL -- the only supported source types.
--  LOOKUP_VIEW and SCALAR_FN are not supported in v3.
-- ============================================================

-- 4.1  STATIC email -- literal address, COMBINED (no fan-out)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Email Source',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-ESRC-01 STATIC Email',
    @FrequencyType   = N'DAILY',
    @RunTime         = N'07:00',
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "static-recipient@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Static Email Test - {{TODAY}}"
    }',
    @ParametersJson = N'[
        { "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1, "value": "E001|E002|E003" }
    ]';
GO

-- 4.2  DYNAMIC_SQL email -- resolved per entity via INDIVIDUAL fan-out
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Email Source',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-ESRC-02 DYNAMIC_SQL Email INDIVIDUAL',
    @FrequencyType   = N'DAILY',
    @RunTime         = N'07:00',
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "fallback@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Dynamic SQL Email Test - {{TODAY}}"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":       true,
                "mode":            "INDIVIDUAL",
                "emailSource":     "DYNAMIC_SQL",
                "emailSourceValue":"SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        }
    ]';
GO

-- 4.3  DYNAMIC_SQL email -- schedule-level query (COMBINED, no fan-out)
--      Tests that a SELECT returning one address is resolved at the schedule level.
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Email Source',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-ESRC-03 DYNAMIC_SQL Email COMBINED',
    @FrequencyType   = N'DAILY',
    @RunTime         = N'07:00',
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "DYNAMIC_SQL",
        "emailSourceValue":    "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''E001''",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Dynamic SQL Combined Email Test - {{TODAY}}"
    }',
    @ParametersJson = N'[
        { "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1, "value": "E001" }
    ]';
GO


-- ============================================================
--  SECTION 5  RESOLVER COMBINATION TESTS
--  DisplayName, FileName, FolderPath resolvers in isolation
--  and in combination. All use DYNAMIC_SQL source type.
-- ============================================================

-- 5.1  DisplayName DYNAMIC_SQL -- resolved per entity
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Resolvers',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-RES-01 DisplayName DYNAMIC_SQL',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "fallback@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Resolver Test - {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "INDIVIDUAL",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.2  FileName DYNAMIC_SQL -- per-entity filename from query
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Resolvers',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-RES-02 FileName DYNAMIC_SQL',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "fallback@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Filename Dynamic SQL Test - {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":         true,
                "mode":              "INDIVIDUAL",
                "emailSource":       "DYNAMIC_SQL",
                "emailSourceValue":  "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "fileNameSource":    "DYNAMIC_SQL",
                "fileNameSourceValue":"SELECT FileName FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.3  FileNameSource STATIC with {{DISPLAYNAME}} and {{TOKEN}}
--      Verifies {{DISPLAYNAME}} is resolved after fn_ResolveAllTokens.
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Resolvers',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-RES-03 FileName Static with Tokens',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "fallback@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Filename Token Test - {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "INDIVIDUAL",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "Report_{{DISPLAYNAME}}_{{PREV_MONTH_START}}_{{PREV_MONTH_END}}.xlsx"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.4  FolderPath DYNAMIC_SQL -- per-entity folder path
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Resolvers',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-RES-04 FolderPath DYNAMIC_SQL',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "FOLDER",
        "folderSource":        "STATIC",
        "folderSourceValue":   "\\\\server\\reports\\combined",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "Report_{{PREV_MONTH_END}}.xlsx"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "INDIVIDUAL",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "Report_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx",
                "folderSource":           "DYNAMIC_SQL",
                "folderSourceValue":      "SELECT FolderPath FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate", "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO

-- 5.5  All resolvers DYNAMIC_SQL -- email + displayname + filename + folder
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Resolvers',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-RES-05 All Resolvers DYNAMIC_SQL',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "BOTH",
        "emailSource":         "STATIC",
        "emailSourceValue":    "bulk-all@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "All Resolvers Test - {{PREV_MONTH_END}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.",
        "folderSource":        "STATIC",
        "folderSourceValue":   "\\\\server\\reports\\combined"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "BOTH",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "Report_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx",
                "folderSource":           "DYNAMIC_SQL",
                "folderSourceValue":      "SELECT FolderPath FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "subjectSource":          "DYNAMIC_SQL",
                "subjectSourceValue":     "SELECT ''Report for '' + EntityName + '' — {{PREV_MONTH_START}} to {{PREV_MONTH_END}}'' AS [Subject] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "bodySource":             "DYNAMIC_SQL",
                "bodySourceValue":        "SELECT ''Dear '' + EntityName + '', please find attached your monthly report.'' AS [Body] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''"
            }
        },
        { "name": "ReportDate",   "type": "string", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}"   },
        { "name": "StartDate",    "type": "string", "required": true, "sortOrder": 3, "value": "{{PREV_MONTH_START}}" },
        { "name": "EntityType",   "type": "string", "required": true, "sortOrder": 4, "value": "ENTITY"               },
        { "name": "PaymentTerms", "type": "string", "required": true, "sortOrder": 5, "value": "0|1|2|3|4"            }
    ]',
    @RecipientsJson = N'[
        { "email": "cc@example.com",  "role": "CC",  "includeInFanOut": true  },
        { "email": "bcc@example.com", "role": "BCC", "includeInFanOut": false }
    ]';
GO

-- 5.6  Multiple non-primary parameters with mixed types
--      Tests that string values like "0|1|2" are never date-resolved.
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - Multi Param',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-RES-06 Multi Param Mixed Types',
    @FrequencyType   = N'MONTHLY',
    @RunTime         = N'06:00',
    @DayOfMonth      = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "bulk-multi@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Multi Param Test - {{PREV_MONTH_END}}"
    }',
    @ParametersJson = N'[
        {
            "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
            "value": "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "BOTH",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT EmailAddress FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT EntityName AS [DisplayName] FROM dbo.TestEntity WHERE EntityCode = ''{VALUE}''",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "MultiParam_{{DISPLAYNAME}}_{{PREV_MONTH_END}}.xlsx"
            }
        },
        { "name": "DateFrom",    "type": "string", "required": true,  "sortOrder": 2, "value": "{{PREV_MONTH_START}}" },
        { "name": "DateTo",      "type": "string", "required": true,  "sortOrder": 3, "value": "{{PREV_MONTH_END}}"   },
        { "name": "PaymentTerm", "type": "string", "required": true,  "sortOrder": 4, "value": "0|1|2|3|4"            },
        { "name": "ProductID",   "type": "string", "required": true,  "sortOrder": 5, "value": "17110|16970"          },
        { "name": "Year",        "type": "string", "required": true,  "sortOrder": 6, "value": "{{YEAR}}"             },
        { "name": "IsActive",    "type": "string", "required": false, "sortOrder": 7, "value": "1"                    }
    ]',
    @RecipientsJson = N'[{ "email": "testcc@example.com", "role": "CC", "includeInFanOut": false }]';
GO


-- ============================================================
--  SECTION 6  PARAMETER-FREE TESTS
--  Reports that execute with no parameters at all.
--  TO address is always in @DispatchJson.emailSourceValue.
--  @RecipientsJson accepts CC and BCC only -- no TO role.
-- ============================================================

-- 6.1  No parameters, EMAIL, CC + BCC recipients
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - No Params',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-NOPARAM-01 No Params Email',
    @FrequencyType   = N'DAILY',
    @RunTime         = N'07:00',
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "noparam-to@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "No Param Report - {{TODAY}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Attached is the no-parameter report for {{TODAY}}."
    }',
    @ParametersJson = NULL,
    @RecipientsJson = N'[
        { "email": "noparam-cc@example.com",  "role": "CC",  "includeInFanOut": false },
        { "email": "noparam-bcc@example.com", "role": "BCC", "includeInFanOut": false }
    ]';
GO

-- 6.2  No parameters, weekly, multiple TO (comma-separated in emailSourceValue)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Test Report - No Params Weekly',
    @ReportEndpoint  = N'/api/reports/generate',
    @ScheduleName    = N'TEST-NOPARAM-02 No Params Weekly Multiple TO',
    @FrequencyType   = N'WEEKLY',
    @RunTime         = N'08:00',
    @DayOfWeek       = 1,
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "rec1@example.com,rec2@example.com,rec3@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Weekly No Param - {{PREV_WEEK_START}} to {{PREV_WEEK_END}}"
    }',
    @ParametersJson = NULL;
GO


-- ============================================================
--  SECTION 7  TEST EXECUTION COMMANDS
-- ============================================================

-- ── Quick test: verify a single schedule ─────────────────────
-- EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-DISP-03 BOTH Mode';

-- ── Expected output after running usp_TestDispatch ───────────
-- TEST-DISP-01 COMBINED Mode          → 1 row,  DispatchType=COMBINED, ToAddresses='combined-recipient@example.com'
-- TEST-DISP-02 INDIVIDUAL Mode        → 3 rows, DispatchType=INDIVIDUAL, ToAddresses resolved per entity
-- TEST-DISP-03 BOTH Mode              → 4 rows (3 INDIVIDUAL + 1 COMBINED)
-- TEST-DELIV-02 FOLDER Delivery       → 3 rows, FolderPath populated, ToAddresses=NULL
-- TEST-DELIV-03 BOTH Delivery         → 4 rows, FolderPath + ToAddresses both populated
-- TEST-RES-03 FileName Static Tokens  → FileName = 'Report_Entity One_<prev_month_start>_<prev_month_end>.xlsx'
-- TEST-RES-05 All Resolvers           → 4 rows, all resolver columns populated
-- TEST-RES-06 Multi Param             → PaymentTerm values = "0","1","2","3","4" (not date-resolved)
-- TEST-NOPARAM-01                     → 1 row, parameters:[] in RequestJson
-- TEST-FREQ-05 Adhoc                  → fires once, then IsActive=0

-- ── Run all test schedules ────────────────────────────────────
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-FREQ-01 Daily at 07:00';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-FREQ-02 Weekly Monday 08:00';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-FREQ-03 Monthly 1st at 06:00';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-FREQ-04 Monthly Last Day 23:00';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-FREQ-05 Adhoc One Shot';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-FREQ-06 Interval 60min 07:00-19:00';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-DISP-01 COMBINED Mode';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-DISP-02 INDIVIDUAL Mode';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-DISP-03 BOTH Mode';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-DELIV-01 EMAIL Delivery';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-DELIV-02 FOLDER Delivery';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-DELIV-03 BOTH Delivery';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-ESRC-01 STATIC Email';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-ESRC-02 DYNAMIC_SQL Email INDIVIDUAL';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-ESRC-03 DYNAMIC_SQL Email COMBINED';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-RES-01 DisplayName DYNAMIC_SQL';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-RES-02 FileName DYNAMIC_SQL';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-RES-03 FileName Static with Tokens';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-RES-04 FolderPath DYNAMIC_SQL';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-RES-05 All Resolvers DYNAMIC_SQL';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-RES-06 Multi Param Mixed Types';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-NOPARAM-01 No Params Email';
EXEC [schdl].[usp_TestDispatch] @ScheduleName = N'TEST-NOPARAM-02 No Params Weekly Multiple TO';


-- ── Verify gate logic with usp_GetDueSchedules ───────────────
-- Should fire TEST-FREQ-01 (Daily at 07:00):
EXEC [schdl].[usp_GetDueSchedules] @AsOf = '2026-06-09 07:00:00';

-- Should fire TEST-FREQ-02 (Weekly Monday 08:00) -- 2026-06-08 is a Monday:
EXEC [schdl].[usp_GetDueSchedules] @AsOf = '2026-06-08 08:00:00';

-- Should fire TEST-FREQ-03 (Monthly 1st at 06:00):
EXEC [schdl].[usp_GetDueSchedules] @AsOf = '2026-07-01 06:00:00';

-- Should fire TEST-FREQ-04 (Monthly Last Day 23:00) -- June 30:
EXEC [schdl].[usp_GetDueSchedules] @AsOf = '2026-06-30 23:00:00';

-- Should fire TEST-FREQ-06 (Interval 60min 07:00-19:00):
EXEC [schdl].[usp_GetDueSchedules] @AsOf = '2026-06-09 09:00:00';


-- ── Inspect kept results ──────────────────────────────────────
EXEC [schdl].[usp_TestDispatch]
    @ScheduleName = N'TEST-RES-05 All Resolvers DYNAMIC_SQL',
    @KeepResults  = 1;

SELECT
    QueueID, DispatchType, DeliveryMethod, DispatchKeyValue,
    DisplayName, FileName, ToAddresses, FolderPath,
    LEFT(RequestJson, 300) AS RequestJsonPreview
FROM [schdl].[DispatchQueue]
WHERE Status = 'PENDING'
ORDER BY DispatchType DESC, DispatchKeyValue;

-- Clean up after inspection:
-- DELETE FROM [schdl].[DispatchQueue] WHERE Status = 'PENDING';
-- DELETE FROM [schdl].[ExecutionLog]  WHERE Status = 'PENDING';


-- ── Verify date token resolution ─────────────────────────────
SELECT
    TokenID, Token, Category, Description,
    [schdl].[fn_ResolveDateToken](Token, CAST('2026-06-09' AS DATE)) AS ResolvedFor_20260609,
    [schdl].[fn_ResolveDateToken](Token, CAST('2026-07-01' AS DATE)) AS ResolvedFor_20260701,
    [schdl].[fn_ResolveDateToken](Token, CAST('2026-12-31' AS DATE)) AS ResolvedFor_20261231
FROM [schdl].[DateToken]
WHERE IsActive = 1
ORDER BY Category, TokenID;


-- ── Verify fn_FetchDocumentId for each registered schedule ───
SELECT
    s.ScheduleName,
    d.DocumentName,
    [schdl].[fn_FetchDocumentId](s.ScheduleID) AS ResolvedDocumentId,
    CASE
        WHEN [schdl].[fn_FetchDocumentId](s.ScheduleID) IS NULL
        THEN 'WARNING: NULL - check fn_FetchDocumentId body'
        ELSE 'OK'
    END AS Status
FROM [schdl].[Schedule]         s
JOIN [schdl].[ScheduleDocument] d ON d.ScheduleID = s.ScheduleID
ORDER BY s.ScheduleName;

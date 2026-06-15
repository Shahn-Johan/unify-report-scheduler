-- ============================================================
--  SCHEDULING AGENT v3  |  SAMPLE REGISTRATIONS
--
--  This file shows the v3 API shape with minimal examples.
--  For full, runnable samples with expected output shapes see:
--    sql/samples/register_schedule_sample.sql   (Samples A-E)
--    sql/samples/test_dispatch_sample.sql        (TestDispatch patterns)
--
--  v3 API changes from prior versions:
--    Removed proc params:  @Subject, @BodyTemplate
--    Removed source types: LOOKUP_VIEW, SCALAR_FN
--    New proc param:       @DispatchJson  -- schedule-level delivery config
--    JSON key renamed:     "dispatch"     -> "fanOut"
--    Mode renamed:         "BULK"         -> "COMBINED"
--    Field removed:        "bulkEmail"    -- TO address lives in @DispatchJson
--    Recipient roles:      CC and BCC only -- TO is not a valid role
-- ============================================================


-- ============================================================
--  EXAMPLE 1  COMBINED delivery  |  STATIC email
--  Single email to one address. No fan-out.
-- ============================================================

EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'My Report',
    @ReportEndpoint  = N'api/reports/my-report',

    @ScheduleName    = N'My Report — Daily 07:00',
    @FrequencyType   = N'DAILY',
    @RunTime         = N'07:00',

    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "reports@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "My Report — {{TODAY}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Please find attached.",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "MyReport_{{TODAY}}.xlsx"
    }',

    @ParametersJson = N'[
        {
            "name":      "ReportDate",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "{{TODAY}}"
        }
    ]';
GO


-- ============================================================
--  EXAMPLE 2  BOTH dispatch  |  full DYNAMIC_SQL  |  valueQuery
--  Fan-out per primary parameter; COMBINED row also produced.
--  All DYNAMIC_SQL queries target dbo.Lookup (sGroup / sDBValue /
--  sDescription / iindex). Adjust table/column names to match
--  your environment.
--
--  Column aliases used by the proc (required when column name differs):
--    emailSourceValue          → AS [EmailAddress]
--    displayNameSourceValue    → [DisplayName]  (AS keyword optional)
--    subjectSourceValue        → AS [Subject]
--    bodySourceValue           → AS [Body]
--    valueQuery                → AS [Value]
-- ============================================================

EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Some Document Name',
    @ReportEndpoint  = N'/api/reports/generate',

    @ScheduleName    = N'Some Document Name — Monthly',
    @FrequencyType   = 'MONTHLY',
    @RunTime         = '06:00:00',
    @DayOfMonth      = 1,

    -- Schedule-level delivery: BOTH (email + folder)
    -- Email resolved from Lookup; subject/filename/folder STATIC with tokens
    @DispatchJson = N'{
        "deliveryMethod":      "BOTH",
        "emailSource":         "DYNAMIC_SQL",
        "emailSourceValue":    "SELECT REPLACE(sDescription, '' '','''') + ''@gmail.com'' AS [EmailAddress]\nFROM Lookup \nWHERE sGroup = ''BordereauxReports'' AND iindex in (0,1)",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "{{REPORTNAME}} Executed on {{TODAY}}",
        "bodySource":          "DYNAMIC_SQL",
        "bodySourceValue":     "SELECT ''Please find attached some report: {{REPORTNAME}} relevant for your Company because of reasons x y and zzzz'' AS [Body]",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "{{REPORTNAME}}_{{TODAY}}.xlsx",
        "folderSource":        "STATIC",
        "folderSourceValue":   "\\\\SomeServer\\{{REPORTNAME}}\\{{YEAR}}\\{{MONTH_START}}\\"
    }',

    -- Primary parameter drives fan-out; valueQuery loads values at dispatch time
    @ParametersJson = N'[
        {
            "name":      "BrokerRelationshipManager",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "BRM001",
            "valueQuery":"SELECT sDBValue AS [Value] \nFROM Lookup \nWHERE sGroup = ''BordereauxReports''",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "BOTH",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT sDBValue + ''@gmail.com'' AS [EmailAddress] \nFROM Lookup \nWHERE sGroup = ''BordereauxReports'' \nAND sDbValue = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT sDescription [DisplayName] \nFROM Lookup \nWHERE sGroup = ''BordereauxReports'' \nAND sDbValue = ''{VALUE}''",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "{{REPORTNAME}}_{{DISPLAYNAME}}_{{TODAY}}.xlsx",
                "folderSource":           "STATIC",
                "folderSourceValue":      "\\\\SomeServer\\{{REPORTNAME}}\\{{YEAR}}\\{{MONTH_START}}\\",
                "subjectSource":          "DYNAMIC_SQL",
                "subjectSourceValue":     "SELECT REPLACE(sDBValue, '' '','''') + '' Some subject for {{REPORTNAME}}''  AS [Subject]\nFROM Lookup \nWHERE sGroup = ''BordereauxReports'' AND sDbValue = ''{VALUE}''",
                "bodySource":             "STATIC",
                "bodySourceValue":        "This is the fanout Email Body {{REPORTNAME}} {{DISPLAYNAME}}"
            }
        },
        {"name": "Brokerage",                "type": "string", "required": true, "sortOrder": 2, "value": "39398|38|39399|39|39400"},
        {"name": "Administrator_HeadOffice", "type": "string", "required": true, "sortOrder": 3, "value": "39323|2|41085|3|39324"},
        {"name": "CaptureDateTo",            "type": "date",   "required": true, "sortOrder": 4, "value": "{{TODAY}}"},
        {"name": "PaymentTerm",              "type": "string", "required": true, "sortOrder": 5, "value": "0|1|3|4|2"},
        {"name": "Product",                  "type": "string", "required": true, "sortOrder": 6, "value": "17110|16970"},
        {"name": "CapturedDateFrom",         "type": "date",   "required": true, "sortOrder": 7, "value": "{{PREV_MONTH_START}}"}
    ]',

    @RecipientsJson = N'[
        {"email": "Combined@gmail.om",  "role": "CC", "includeInFanOut": false},
        {"email": "Fanout@gmail.com",   "role": "CC", "includeInFanOut": true }
    ]';
GO


-- ============================================================
--  DIAGNOSTIC QUERIES
-- ============================================================

-- All registered schedules
SELECT
    s.ScheduleID,
    s.ScheduleName,
    s.FrequencyType,
    s.DeliveryMethod,
    s.EmailSource,
    s.EmailSourceValue,
    s.IsActive,
    s.NextRunAt,
    d.DocumentName,
    d.ReportEndpoint
FROM [schdl].[Schedule]         s
JOIN [schdl].[ScheduleDocument] d ON d.ScheduleID = s.ScheduleID
ORDER BY s.ScheduleName;
GO

-- Parameters and dispatch config for one schedule
DECLARE @Name NVARCHAR(200) = N'Entity Report — Monthly';

SELECT
    dp.ParameterName,
    dp.DataType,
    dp.IsRequired,
    dp.SortOrder,
    sp.ParameterValue,
    sp.ParameterValueQuery,
    CASE WHEN dc.IsPrimaryDispatchKey = 1 THEN 'PRIMARY' ELSE '' END AS Role,
    dc.DispatchMode,
    dc.EmailSource,
    dc.EmailSourceValue,
    dc.DisplayNameSource,
    dc.DisplayNameSourceValue,
    dc.FileNameSource,
    dc.FileNameSourceValue
FROM [schdl].[Schedule]                              s
JOIN [schdl].[ScheduleDocumentParameter]             dp ON dp.ScheduleID = s.ScheduleID
LEFT JOIN [schdl].[ScheduleParameter]                sp ON sp.ScheduleParameterID = dp.ScheduleParameterID
                                                       AND sp.ScheduleID = s.ScheduleID
LEFT JOIN [schdl].[ScheduleParameterDispatchConfig]  dc ON dc.ScheduleParameterID = dp.ScheduleParameterID
                                                       AND dc.ScheduleID = s.ScheduleID
WHERE s.ScheduleName = @Name
ORDER BY dp.SortOrder;
GO

-- Standing recipients
SELECT
    s.ScheduleName,
    sr.RecipientEmail,
    sr.RecipientRole,
    sr.IncludeInFanOut
FROM [schdl].[ScheduleStandingRecipient] sr
JOIN [schdl].[Schedule]                  s  ON s.ScheduleID = sr.ScheduleID
ORDER BY s.ScheduleName, sr.RecipientRole;
GO

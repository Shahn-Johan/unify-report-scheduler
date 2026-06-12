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
--  EXAMPLE 2  INDIVIDUAL fan-out  |  DYNAMIC_SQL email per entity
--  One INDIVIDUAL email per entity code + one COMBINED summary.
-- ============================================================

EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Entity Report',
    @ReportEndpoint  = N'api/reports/entity-report',

    @ScheduleName    = N'Entity Report — Monthly',
    @FrequencyType   = N'MONTHLY',
    @DayOfMonth      = 1,
    @RunTime         = N'06:00',

    -- Schedule-level: provides COMBINED row delivery + fallback for INDIVIDUAL
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "combined@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Monthly Entity Report — {{PREV_MONTH_START}} to {{PREV_MONTH_END}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "See attached.",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "EntityReport_Consolidated_{{PREV_MONTH_START}}.xlsx"
    }',

    @ParametersJson = N'[
        {
            "name":      "EntityCode",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "E001|E002|E003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "BOTH",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT EmailAddress FROM dbo.Entities WHERE code = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT name FROM dbo.Entities WHERE code = ''{VALUE}''",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "EntityReport_{{DISPLAYNAME}}_{{PREV_MONTH_START}}.xlsx"
            }
        },
        {
            "name":      "ReportDate",
            "type":      "string",
            "required":  true,
            "sortOrder": 2,
            "value":     "{{PREV_MONTH_END}}"
        }
    ]',

    @RecipientsJson = N'[
        { "email": "manager@example.com", "role": "CC",  "includeInFanOut": true  },
        { "email": "audit@example.com",   "role": "BCC", "includeInFanOut": false }
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

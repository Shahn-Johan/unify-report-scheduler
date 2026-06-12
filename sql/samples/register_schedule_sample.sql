-- =============================================================================
-- register_schedule_sample.sql
-- Full-featured EXEC [schdl].[usp_RegisterSchedule] sample — v3 API
-- Demonstrates: BOTH delivery, DYNAMIC_SQL email, per-entity overrides for
-- subject/body/filename/folder, multiple non-primary parameters, date tokens,
-- CC/BCC with IncludeInFanOut variants.
-- =============================================================================
-- IMPORTANT: Do NOT use scheduling_agent_samples.sql or scheduling_agent_test_suite.sql
-- as reference — both are stale (old @Subject/@BodyTemplate API + LOOKUP_VIEW/SCALAR_FN).
-- =============================================================================

-- -------------------------------------------------------------------------
-- SAMPLE A — Monthly entity report with full fan-out (EMAIL + FOLDER)
--
-- Scenario:
--   • Sends a monthly Excel report to each entity individually (INDIVIDUAL rows)
--   • Also produces a COMBINED summary row for the operations mailbox
--   • Delivers to FOLDER as well (BOTH)
--   • CC a manager on every individual email; CC audit mailbox on combined only
--   • Per-entity: email, display name, filename, folder path, subject, body
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_RegisterSchedule]
    -- Document
    @DocumentName    = N'Monthly Entity Report',
    @ReportEndpoint  = N'api/reports/monthly-entity',
    @OutputFormat    = N'xlsx',
    @Language        = 1,
    @Confidentiality = N'normal',

    -- Schedule
    @ScheduleName    = N'Monthly Entity Report — 1st of month',
    @FrequencyType   = N'MONTHLY',
    @DayOfMonth      = 1,
    @RunTime         = N'06:30',
    @StartDate       = N'2025-01-01',

    -- Delivery config (schedule-level: BOTH = email + folder)
    @DispatchJson = N'{
        "deliveryMethod":      "BOTH",
        "emailSource":         "STATIC",
        "emailSourceValue":    "operations@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Monthly Entity Report — {{PREV_MONTH_START}} to {{PREV_MONTH_END}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Please find attached the consolidated monthly entity report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "EntityReport_Consolidated_{{PREV_MONTH_START}}.xlsx",
        "folderSource":        "STATIC",
        "folderSourceValue":   "\\\\fileserver\\reports\\monthly\\consolidated"
    }',

    -- Parameters
    @ParametersJson = N'[
        {
            "name":      "EntityCode",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "ENTITY_A|ENTITY_B|ENTITY_C",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "BOTH",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT email FROM dbo.Entities WHERE code = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT name FROM dbo.Entities WHERE code = ''{VALUE}''",
                "subjectSource":          "STATIC",
                "subjectSourceValue":     "{{DISPLAYNAME}} — Monthly Report {{PREV_MONTH_START}} to {{PREV_MONTH_END}}",
                "bodySource":             "STATIC",
                "bodySourceValue":        "Dear {{DISPLAYNAME}},\n\nPlease find attached your monthly report for the period {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.",
                "fileNameSource":         "STATIC",
                "fileNameSourceValue":    "EntityReport_{{DISPLAYNAME}}_{{PREV_MONTH_START}}.xlsx",
                "folderSource":           "DYNAMIC_SQL",
                "folderSourceValue":      "SELECT folder_path FROM dbo.Entities WHERE code = ''{VALUE}''"
            }
        },
        {
            "name":      "ReportStartDate",
            "type":      "string",
            "required":  true,
            "sortOrder": 2,
            "value":     "{{PREV_MONTH_START}}"
        },
        {
            "name":      "ReportEndDate",
            "type":      "string",
            "required":  true,
            "sortOrder": 3,
            "value":     "{{PREV_MONTH_END}}"
        }
    ]',

    -- Standing CC/BCC recipients
    @RecipientsJson = N'[
        { "email": "manager@example.com",  "role": "CC",  "includeInFanOut": true  },
        { "email": "audit@example.com",    "role": "CC",  "includeInFanOut": false },
        { "email": "archive@example.com",  "role": "BCC", "includeInFanOut": false }
    ]';
-- Expected rows from usp_TestDispatch:
--   3 × INDIVIDUAL rows (one per EntityCode pipe-segment)
--     DispatchType    = INDIVIDUAL
--     ToAddresses     = per-entity email from DYNAMIC_SQL
--     CcAddresses     = manager@example.com  (IncludeInFanOut=1)
--     BccAddresses    = NULL                 (IncludeInFanOut=0 for BCC)
--     DispatchKeyValue= ENTITY_A / ENTITY_B / ENTITY_C
--     DisplayName     = per-entity name from DYNAMIC_SQL
--     FileName        = EntityReport_<DisplayName>_<PREV_MONTH_START>.xlsx
--     FolderPath      = per-entity folder from DYNAMIC_SQL
--   1 × COMBINED row
--     DispatchType    = COMBINED
--     ToAddresses     = operations@example.com
--     CcAddresses     = manager@example.com + audit@example.com (all CC)
--     BccAddresses    = archive@example.com (all BCC)
--     DispatchKeyValue= NULL
--     FileName        = EntityReport_Consolidated_<PREV_MONTH_START>.xlsx
--     FolderPath      = \\fileserver\reports\monthly\consolidated
GO


-- -------------------------------------------------------------------------
-- SAMPLE B — Daily report, EMAIL only, no fan-out, single static recipient
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Daily Sales Summary',
    @ReportEndpoint  = N'api/reports/daily-sales',

    @ScheduleName    = N'Daily Sales Summary — 07:00',
    @FrequencyType   = N'DAILY',
    @RunTime         = N'07:00',

    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "sales-team@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Daily Sales Summary — {{TODAY}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Attached: daily sales report for {{TODAY}}.",
        "fileNameSource":       "STATIC",
        "fileNameSourceValue":  "SalesSummary_{{TODAY}}.xlsx"
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


-- -------------------------------------------------------------------------
-- SAMPLE C — Weekly report, FOLDER delivery only, DYNAMIC_SQL folder path
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Weekly KPI Report',
    @ReportEndpoint  = N'api/reports/weekly-kpi',

    @ScheduleName    = N'Weekly KPI Report — Monday 08:00',
    @FrequencyType   = N'WEEKLY',
    @DayOfWeek       = 1,   -- Monday
    @RunTime         = N'08:00',

    @DispatchJson = N'{
        "deliveryMethod":  "FOLDER",
        "folderSource":    "STATIC",
        "folderSourceValue": "\\\\fileserver\\reports\\weekly\\kpi",
        "fileNameSource":   "STATIC",
        "fileNameSourceValue": "WeeklyKPI_{{PREV_WEEK_START}}_to_{{PREV_WEEK_END}}.xlsx"
    }',

    @ParametersJson = N'[
        {
            "name":      "WeekStart",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "{{PREV_WEEK_START}}"
        },
        {
            "name":      "WeekEnd",
            "type":      "string",
            "required":  true,
            "sortOrder": 2,
            "value":     "{{PREV_WEEK_END}}"
        }
    ]';
GO


-- -------------------------------------------------------------------------
-- SAMPLE D — ADHOC one-shot, INDIVIDUAL only (no COMBINED row)
--            Email resolved by DYNAMIC_SQL on each fan-out value
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Ad-hoc Client Statement',
    @ReportEndpoint  = N'api/reports/client-statement',

    @ScheduleName    = N'Client Statement — Ad-hoc 2025-06',
    @FrequencyType   = N'ADHOC',

    -- Schedule-level email is required by schema but not used for INDIVIDUAL delivery;
    -- set it to a fallback/catch-all address.
    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "noreply@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Your Statement — {{TODAY}}",
        "bodySource":          "STATIC",
        "bodySourceValue":     "Please find attached your statement.",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "Statement_{{DISPLAYNAME}}_{{TODAY}}.pdf"
    }',

    @ParametersJson = N'[
        {
            "name":      "ClientID",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "C001|C002|C003",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "INDIVIDUAL",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT contact_email FROM dbo.Clients WHERE client_id = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT client_name FROM dbo.Clients WHERE client_id = ''{VALUE}''"
            }
        },
        {
            "name":      "StatementDate",
            "type":      "string",
            "required":  true,
            "sortOrder": 2,
            "value":     "{{TODAY}}"
        }
    ]';
-- No @RecipientsJson — no standing CC/BCC recipients for this schedule.
GO


-- -------------------------------------------------------------------------
-- SAMPLE E — INTERVAL schedule (every 30 min, 06:00–18:00 window)
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName     = N'Intraday Position Report',
    @ReportEndpoint   = N'api/reports/intraday-position',

    @ScheduleName     = N'Intraday Position — Every 30min',
    @FrequencyType    = N'INTERVAL',
    @IntervalMinutes  = 30,
    @WindowStart      = N'06:00',
    @WindowEnd        = N'18:00',

    @DispatchJson = N'{
        "deliveryMethod":      "EMAIL",
        "emailSource":         "STATIC",
        "emailSourceValue":    "trading-desk@example.com",
        "subjectSource":       "STATIC",
        "subjectSourceValue":  "Intraday Position — {{TODAY}}",
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "IntradayPosition_{{TODAY}}.xlsx"
    }',

    @ParametersJson = N'[
        {
            "name":      "AsOfDate",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "{{TODAY}}"
        }
    ]';
GO


-- -------------------------------------------------------------------------
-- Admin: verify registrations
-- -------------------------------------------------------------------------
SELECT
    s.ScheduleID,
    s.ScheduleName,
    s.FrequencyType,
    s.DeliveryMethod,
    d.DocumentName,
    d.ReportEndpoint,
    s.IsActive,
    s.NextRunAt
FROM [schdl].[Schedule]         s
JOIN [schdl].[ScheduleDocument] d ON d.ScheduleID = s.ScheduleID
ORDER BY s.ScheduleName;

-- View parameters for a specific schedule
SELECT
    dp.ParameterName,
    dp.DataType,
    dp.IsRequired,
    dp.SortOrder,
    sp.ParameterValue,
    sp.ParameterValueQuery,
    CASE WHEN dc.IsPrimaryDispatchKey = 1 THEN 'PRIMARY' ELSE '' END AS IsPrimary,
    dc.DispatchMode,
    dc.EmailSource,
    dc.EmailSourceValue,
    dc.DisplayNameSource,
    dc.DisplayNameSourceValue,
    dc.FileNameSource,
    dc.FileNameSourceValue,
    dc.SubjectSource,
    dc.SubjectSourceValue
FROM [schdl].[Schedule]                         s
JOIN [schdl].[ScheduleDocument]                 d  ON d.ScheduleID = s.ScheduleID
JOIN [schdl].[ScheduleDocumentParameter]        dp ON dp.ScheduleID = s.ScheduleID
LEFT JOIN [schdl].[ScheduleParameter]           sp ON sp.ScheduleParameterID = dp.ScheduleParameterID
                                                  AND sp.ScheduleID = s.ScheduleID
LEFT JOIN [schdl].[ScheduleParameterDispatchConfig] dc ON dc.ScheduleParameterID = dp.ScheduleParameterID
                                                       AND dc.ScheduleID = s.ScheduleID
WHERE s.ScheduleName = N'Monthly Entity Report — 1st of month'
ORDER BY dp.SortOrder;

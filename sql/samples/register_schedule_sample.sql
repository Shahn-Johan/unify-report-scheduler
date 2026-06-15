-- =============================================================================
-- register_schedule_sample.sql
-- Full-featured EXEC [schdl].[usp_RegisterSchedule] samples — v3 API
-- See also: scheduling_agent_samples.sql (quick-reference),
--           test_dispatch_sample.sql (TestDispatch patterns + expected output)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- REQUIRED COLUMN ALIASES FOR DYNAMIC_SQL SELECT STATEMENTS
--
--   The proc wraps each *SourceValue as a subquery and reads a fixed column.
--   Always alias to the name listed below when your table column differs:
--
--     emailSourceValue          → AS [EmailAddress]
--     folderSourceValue         → AS [FolderPath]
--     fileNameSourceValue       → AS [FileName]
--     displayNameSourceValue    → AS [DisplayName]
--     subjectSourceValue        → AS [Subject]
--     bodySourceValue           → AS [Body]
--     valueQuery                → AS [Value]   (aggregated via STRING_AGG)
--
--   {VALUE} in fanOut queries is replaced with each fan-out value before exec.
--   deliveryMethod is NOT a valid key in the fanOut block — put it in @DispatchJson.
-- ─────────────────────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────────────────────
-- SAMPLE A — Full DYNAMIC_SQL, BOTH delivery, valueQuery fan-out
--
-- Scenario:
--   • MONTHLY — 1st of each month
--   • Sends an individual Excel report to each entity (INDIVIDUAL rows)
--     plus a COMBINED summary row for the operations mailbox
--   • Delivers to EMAIL + FOLDER (BOTH)
--   • ALL delivery fields resolved at runtime via DYNAMIC_SQL from dbo.Entities
--   • Entity list loaded at dispatch time via valueQuery (not a static pipe list)
--   • CC manager on every individual email; CC audit mailbox on combined only
--
-- dbo.Entities columns used: entity_code, display_name, email, folder_path
-- ─────────────────────────────────────────────────────────────────────────────
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

    -- ALL schedule-level delivery fields resolved via DYNAMIC_SQL
    @DispatchJson = N'{
        "deliveryMethod":      "BOTH",
        "emailSource":         "DYNAMIC_SQL",
        "emailSourceValue":    "SELECT email AS [EmailAddress] FROM dbo.Entities WHERE group_id = ''monthly-report'' AND row_type = ''combined''",
        "subjectSource":       "DYNAMIC_SQL",
        "subjectSourceValue":  "SELECT ''Monthly Entity Report — {{PREV_MONTH_START}} to {{PREV_MONTH_END}}'' AS [Subject] FROM dbo.Entities WHERE group_id = ''monthly-report'' AND row_type = ''combined''",
        "bodySource":          "DYNAMIC_SQL",
        "bodySourceValue":     "SELECT ''Please find attached the consolidated monthly entity report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.'' AS [Body] FROM dbo.Entities WHERE group_id = ''monthly-report'' AND row_type = ''combined''",
        "fileNameSource":      "DYNAMIC_SQL",
        "fileNameSourceValue": "SELECT ''EntityReport_Consolidated_{{PREV_MONTH_START}}.xlsx'' AS [FileName] FROM dbo.Entities WHERE group_id = ''monthly-report'' AND row_type = ''combined''",
        "folderSource":        "DYNAMIC_SQL",
        "folderSourceValue":   "SELECT folder_path AS [FolderPath] FROM dbo.Entities WHERE group_id = ''monthly-report'' AND row_type = ''combined''"
    }',

    @ParametersJson = N'[
        {
            "name":      "EntityCode",
            "type":      "string",
            "required":  true,
            "sortOrder": 1,
            "value":     "DYNAMIC",
            "valueQuery":"SELECT entity_code AS [Value] FROM dbo.Entities WHERE group_id = ''monthly-report'' AND row_type = ''individual'' ORDER BY sort_order",
            "fanOut": {
                "isPrimary":              true,
                "mode":                   "BOTH",
                "emailSource":            "DYNAMIC_SQL",
                "emailSourceValue":       "SELECT email AS [EmailAddress] FROM dbo.Entities WHERE entity_code = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT display_name AS [DisplayName] FROM dbo.Entities WHERE entity_code = ''{VALUE}''",
                "subjectSource":          "DYNAMIC_SQL",
                "subjectSourceValue":     "SELECT ''{{DISPLAYNAME}} — Monthly Report {{PREV_MONTH_START}} to {{PREV_MONTH_END}}'' AS [Subject] FROM dbo.Entities WHERE entity_code = ''{VALUE}''",
                "bodySource":             "DYNAMIC_SQL",
                "bodySourceValue":        "SELECT ''Dear {{DISPLAYNAME}}, please find attached your monthly report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.'' AS [Body] FROM dbo.Entities WHERE entity_code = ''{VALUE}''",
                "fileNameSource":         "DYNAMIC_SQL",
                "fileNameSourceValue":    "SELECT ''EntityReport_{{DISPLAYNAME}}_{{PREV_MONTH_START}}.xlsx'' AS [FileName] FROM dbo.Entities WHERE entity_code = ''{VALUE}''",
                "folderSource":           "DYNAMIC_SQL",
                "folderSourceValue":      "SELECT folder_path AS [FolderPath] FROM dbo.Entities WHERE entity_code = ''{VALUE}''"
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
-- Expected rows from usp_TestDispatch (assumes dbo.Entities is populated):
--   N × INDIVIDUAL rows (one per entity_code from valueQuery)
--     DispatchType    = INDIVIDUAL
--     ToAddresses     = per-entity email from DYNAMIC_SQL
--     CcAddresses     = manager@example.com  (IncludeInFanOut=1)
--     BccAddresses    = NULL                 (IncludeInFanOut=0 for BCC)
--     DispatchKeyValue= each entity_code value
--     DisplayName     = per-entity display_name from DYNAMIC_SQL
--     FileName        = EntityReport_<DisplayName>_<PREV_MONTH_START>.xlsx
--     FolderPath      = per-entity folder_path from DYNAMIC_SQL
--   1 × COMBINED row
--     DispatchType    = COMBINED
--     ToAddresses     = combined email from DYNAMIC_SQL
--     CcAddresses     = manager@example.com + audit@example.com (all CC)
--     BccAddresses    = archive@example.com (all BCC)
--     DispatchKeyValue= NULL
--     FileName        = EntityReport_Consolidated_<PREV_MONTH_START>.xlsx
--     FolderPath      = combined folder_path from DYNAMIC_SQL
GO


-- ─────────────────────────────────────────────────────────────────────────────
-- SAMPLE B — Daily report, EMAIL only, no fan-out, single static recipient
-- ─────────────────────────────────────────────────────────────────────────────
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
        "fileNameSource":      "STATIC",
        "fileNameSourceValue": "SalesSummary_{{TODAY}}.xlsx"
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


-- ─────────────────────────────────────────────────────────────────────────────
-- SAMPLE C — Weekly report, FOLDER delivery only, static path
-- ─────────────────────────────────────────────────────────────────────────────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Weekly KPI Report',
    @ReportEndpoint  = N'api/reports/weekly-kpi',

    @ScheduleName    = N'Weekly KPI Report — Monday 08:00',
    @FrequencyType   = N'WEEKLY',
    @DayOfWeek       = 1,   -- Monday
    @RunTime         = N'08:00',

    @DispatchJson = N'{
        "deliveryMethod":    "FOLDER",
        "folderSource":      "STATIC",
        "folderSourceValue": "\\\\fileserver\\reports\\weekly\\kpi",
        "fileNameSource":    "STATIC",
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


-- ─────────────────────────────────────────────────────────────────────────────
-- SAMPLE D — ADHOC one-shot, INDIVIDUAL only (no COMBINED row)
--            Per-entity email and displayName resolved via DYNAMIC_SQL
-- ─────────────────────────────────────────────────────────────────────────────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = N'Ad-hoc Client Statement',
    @ReportEndpoint  = N'api/reports/client-statement',

    @ScheduleName    = N'Client Statement — Ad-hoc 2025-06',
    @FrequencyType   = N'ADHOC',

    -- Schedule-level email is the fallback; INDIVIDUAL rows use per-entity resolver
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
                "emailSourceValue":       "SELECT contact_email AS [EmailAddress] FROM dbo.Clients WHERE client_id = ''{VALUE}''",
                "displayNameSource":      "DYNAMIC_SQL",
                "displayNameSourceValue": "SELECT client_name AS [DisplayName] FROM dbo.Clients WHERE client_id = ''{VALUE}''"
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


-- ─────────────────────────────────────────────────────────────────────────────
-- SAMPLE E — INTERVAL schedule (every 30 min, 06:00–18:00 window)
-- ─────────────────────────────────────────────────────────────────────────────
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


-- ─────────────────────────────────────────────────────────────────────────────
-- Admin: verify registrations
-- ─────────────────────────────────────────────────────────────────────────────
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

-- View parameters and dispatch config for a specific schedule
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

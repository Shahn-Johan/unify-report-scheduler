-- ============================================================
--  SCHEDULING AGENT  |  SAMPLE OBJECTS & REGISTRATION CALLS
--
--  PURPOSE
--  ───────
--  This file provides ready-to-adapt samples for every
--  external object the scheduling agent can reference:
--
--    1. fn_FetchDocumentId  — your environment's document lookup
--    2. Email source objects — one sample per EmailSource type:
--         LOOKUP_VIEW   schdl.vw_EmailLookup
--         SCALAR_FN     dbo.fn_GetEmailByKey
--         DYNAMIC_SQL   (no object needed — inline SQL)
--    3. usp_RegisterSchedule calls — one per pattern
--
--  ADAPT and run what you need. Nothing here is mandatory —
--  use whichever EmailSource type fits each report.
-- ============================================================


-- ============================================================
--  SECTION 1  fn_FetchDocumentId
--  Resolves the API documentId for a DocumentName at runtime.
--  Already created by the main script — UPDATE the body only.
-- ============================================================

--  The function is already in the schema. To point it at a
--  different table or add environment branching, ALTER it:

ALTER FUNCTION [schdl].[fn_FetchDocumentId]
(
    @DocumentName NVARCHAR(255)
)
RETURNS NVARCHAR(100)
AS
BEGIN
    DECLARE @ID NVARCHAR(100);

    -- ── Your actual query here ────────────────────────────────
    -- Must set @ID from whatever table/view holds document IDs.
    -- The function receives @DocumentName (the stable human name
    -- stored in schdl.Document.DocumentName).

    -- Example A: custom catalogue table
    SELECT TOP 1 @ID = CAST(CAST(iDocumentID AS BIGINT) AS NVARCHAR(100))
    FROM   dbo.Document
    WHERE  sName    = @DocumentName
      AND  bEnabled = 1;

    -- Example B: SSRS ReportServer (uncomment to use)
    -- SELECT TOP 1 @ID = CAST(ItemID AS NVARCHAR(100))
    -- FROM   ReportServer.dbo.Catalog
    -- WHERE  Name = @DocumentName
    --   AND  Type = 2;  -- 2 = Report

    -- Example C: environment-aware (DEV vs PROD table)
    -- SELECT TOP 1 @ID =
    --     CASE
    --         WHEN DB_NAME() LIKE '%DEV%'
    --         THEN CAST(DevDocID  AS NVARCHAR(100))
    --         ELSE CAST(ProdDocID AS NVARCHAR(100))
    --     END
    -- FROM dbo.DocumentMap
    -- WHERE DocumentName = @DocumentName;

    RETURN @ID;
END;
GO


-- ============================================================
--  SECTION 2  EMAIL SOURCE OBJECTS
--
--  Create whichever objects match your EmailSource choice.
--  You do NOT need all of them — only the ones you use.
-- ============================================================

-- ─── 2.1  LOOKUP_VIEW  ───────────────────────────────────────
--
--  Used when: emailSource = "LOOKUP_VIEW"
--  Contract : must expose exactly LookupKey, EmailAddress
--  Wire up  : emailSourceValue = "schdl.vw_BRMEmail"
--             (or whatever name you give the view)
--
--  The engine runs:
--    SELECT TOP 1 EmailAddress FROM <view>
--    WHERE LookupKey = '<dispatch value>'
--
--  Create one view per entity type that needs individual emails.

-- BRM example
CREATE OR ALTER VIEW [schdl].[vw_BRMEmail]
AS
    -- Replace with your actual BRM / user table
    SELECT
        sBRMCode        AS LookupKey,      -- must match the dispatch parameter values
        sEmailAddress   AS EmailAddress
    FROM dbo.BrokerRelationshipManager
    WHERE bActive = 1;
GO

-- Brokerage example (if you ever fan-out on Brokerage)
CREATE OR ALTER VIEW [schdl].[vw_BrokerageEmail]
AS
    SELECT
        CAST(iBrokerageID AS NVARCHAR(50)) AS LookupKey,
        sContactEmail                      AS EmailAddress
    FROM dbo.Brokerage
    WHERE bActive = 1;
GO

-- Administrator / Head Office example
CREATE OR ALTER VIEW [schdl].[vw_AdminEmail]
AS
    SELECT
        CAST(iAdminID AS NVARCHAR(50))  AS LookupKey,
        sEmailAddress                   AS EmailAddress
    FROM dbo.Administrator
    WHERE bEnabled = 1;
GO


-- ─── 2.2  SCALAR_FN  ─────────────────────────────────────────
--
--  Used when: emailSource = "SCALAR_FN"
--  Contract : fn(@Value NVARCHAR(500)) RETURNS NVARCHAR(320)
--  Wire up  : emailSourceValue = "dbo.fn_GetBrokerEmail"
--
--  Use this when the lookup logic is more complex than a
--  single-table view — joins, fallback logic, etc.

CREATE OR ALTER FUNCTION [dbo].[fn_GetBrokerEmail]
(
    @BrokerCode NVARCHAR(50)
)
RETURNS NVARCHAR(320)
AS
BEGIN
    DECLARE @Email NVARCHAR(320);

    -- Primary contact email
    SELECT TOP 1 @Email = sEmailAddress
    FROM   dbo.Broker
    WHERE  sBrokerCode = @BrokerCode
      AND  bActive     = 1;

    -- Fallback: head office email if no direct match
    IF @Email IS NULL
        SELECT TOP 1 @Email = sDefaultEmail
        FROM   dbo.BrokerDefaults
        WHERE  bIsActive = 1;

    RETURN @Email;
END;
GO

-- Administrator scalar function example
CREATE OR ALTER FUNCTION [dbo].[fn_GetAdminEmail]
(
    @AdminID NVARCHAR(50)
)
RETURNS NVARCHAR(320)
AS
BEGIN
    DECLARE @Email NVARCHAR(320);

    SELECT TOP 1 @Email = sEmailAddress
    FROM   dbo.Administrator
    WHERE  iAdminID = TRY_CAST(@AdminID AS INT)
      AND  bEnabled = 1;

    RETURN @Email;
END;
GO


-- ─── 2.3  DYNAMIC_SQL  ───────────────────────────────────────
--
--  Used when: emailSource = "DYNAMIC_SQL"
--  No object needed — the SQL is stored inline in the
--  dispatch config via emailSourceValue in the JSON.
--
--  Rules:
--    • Must return a column named EmailAddress
--    • Use {VALUE} where the dispatch parameter value goes
--    • Single-quote any string literals with doubled quotes: ''
--
--  Examples stored in the JSON parameter block:

--  Simple lookup:
--    "SELECT sEmail AS EmailAddress
--     FROM dbo.Staff WHERE sStaffCode = ''{VALUE}''"

--  With join:
--    "SELECT b.sEmail AS EmailAddress
--     FROM dbo.BrokerBranch bb
--     JOIN dbo.Broker b ON b.iBrokerID = bb.iBrokerID
--     WHERE bb.iBranchCode = ''{VALUE}'' AND bb.bActive = 1"

--  Numeric key (cast {VALUE} to int):
--    "SELECT sContactEmail AS EmailAddress
--     FROM dbo.Administrator
--     WHERE iAdminID = CAST(''{VALUE}'' AS INT)"


-- ============================================================
--  SECTION 3  REGISTRATION EXAMPLES
--  Copy, adapt, and run the block that matches your report.
-- ============================================================

-- ─── 3.1  LOOKUP_VIEW — email per BRM, plus one bulk ─────────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'BRM Production Report',
    @ReportEndpoint = '/api/reports/generate',
    @OutputFormat   = 'xlsx',

    @ScheduleName   = 'BRM Production Report - Monthly',
    @FrequencyType  = 'MONTHLY',
    @RunTime        = '06:00',
    @DayOfMonth     = 1,
    @Subject        = 'BRM Production Report - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}',
    @BodyTemplate   = 'Please find attached your production report for the previous month.',

    @ParametersJson = N'[
        {
            "name": "BrokerRelationshipManager",
            "type": "string", "required": true, "sortOrder": 1,
            "value": "BRM001|BRM002|BRM003|BRM004|BRM005|BRM006|BRM007|BRM008",
            "dispatch": {
                "isPrimary":        true,
                "mode":             "BOTH",
                "emailSource":      "LOOKUP_VIEW",
                "emailSourceValue": "schdl.vw_BRMEmail",
                "bulkEmail":        "reports-bulk@example.com"
            }
        },
        { "name": "Brokerage",                "type": "string", "required": true, "sortOrder": 2, "value": "39398|38|39399|39|39400" },
        { "name": "Administrator_HeadOffice", "type": "string", "required": true, "sortOrder": 3, "value": "39323|2|41085|3|39324" },
        { "name": "CaptureDateTo",            "type": "date",   "required": true, "sortOrder": 4, "value": "{{PREV_MONTH_END}}" },
        { "name": "PaymentTerm",              "type": "string", "required": true, "sortOrder": 5, "value": "0|1|3|4|2" },
        { "name": "Product",                  "type": "string", "required": true, "sortOrder": 6, "value": "17110|16970" },
        { "name": "CapturedDateFrom",         "type": "date",   "required": true, "sortOrder": 7, "value": "{{PREV_MONTH_START}}" }
    ]',
    @RecipientsJson = N'[
        {"name": "Reports Admin", "email": "reports-admin@example.com", "role": "CC"}
    ]';
GO


-- ─── 3.2  SCALAR_FN — email per Broker, individuals only ─────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Broker Monthly Statement',
    @ReportEndpoint = '/api/reports/generate',
    @OutputFormat   = 'pdf',

    @ScheduleName   = 'Broker Monthly Statement - Monthly',
    @FrequencyType  = 'MONTHLY',
    @RunTime        = '05:30',
    @DayOfMonth     = 1,
    @Subject        = 'Your Statement - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}',
    @BodyTemplate   = 'Please find your statement for {{PREV_MONTH_START}} to {{PREV_MONTH_END}} attached.',

    @ParametersJson = N'[
        {
            "name": "BrokerageID",
            "type": "string", "required": true, "sortOrder": 1,
            "value": "39398|38|39399|39|39400",
            "dispatch": {
                "isPrimary":        true,
                "mode":             "INDIVIDUAL",
                "emailSource":      "SCALAR_FN",
                "emailSourceValue": "dbo.fn_GetBrokerEmail"
            }
        },
        { "name": "StatementDate", "type": "date", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" }
    ]';
GO


-- ─── 3.3  DYNAMIC_SQL — email per Admin, individuals only ────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Administrator Summary',
    @ReportEndpoint = '/api/reports/generate',

    @ScheduleName   = 'Administrator Summary - Weekly',
    @FrequencyType  = 'WEEKLY',
    @RunTime        = '08:00',
    @DayOfWeek      = 1,
    @Subject        = 'Weekly Admin Summary - {{PREV_WEEK_START}} to {{PREV_WEEK_END}}',
    @BodyTemplate   = 'Attached is the weekly summary for {{PREV_WEEK_START}} to {{PREV_WEEK_END}}.',

    @ParametersJson = N'[
        {
            "name": "Administrator_HeadOffice",
            "type": "string", "required": true, "sortOrder": 1,
            "value": "39323|2|41085|3|39324",
            "dispatch": {
                "isPrimary":        true,
                "mode":             "INDIVIDUAL",
                "emailSource":      "DYNAMIC_SQL",
                "emailSourceValue": "SELECT sEmailAddress AS EmailAddress FROM dbo.Administrator WHERE iAdminID = CAST(''{VALUE}'' AS INT) AND bEnabled = 1"
            }
        },
        { "name": "WeekEndDate", "type": "date", "required": true, "sortOrder": 2, "value": "{{PREV_WEEK_END}}" }
    ]';
GO


-- ─── 3.4  STATIC email — bulk only, no fan-out ───────────────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Daily Exception Report',
    @ReportEndpoint = '/api/reports/generate',

    @ScheduleName   = 'Daily Exception Report - 07:00',
    @FrequencyType  = 'DAILY',
    @RunTime        = '07:00',
    @Subject        = 'Daily Exception Report - {{TODAY}}',
    @BodyTemplate   = 'Attached is the exception report for {{TODAY-1}}.',

    @ParametersJson = N'[
        {
            "name": "AsOfDate",
            "type": "date", "required": true, "sortOrder": 1,
            "value": "{{TODAY-1}}",
            "dispatch": {
                "isPrimary":   true,
                "mode":        "BULK",
                "emailSource": "STATIC",
                "bulkEmail":   "it-alerts@example.com"
            }
        }
    ]',
    @RecipientsJson = N'[
        {"name": "IT Manager", "email": "it-mgr@example.com", "role": "CC"}
    ]';
GO


-- ─── 3.5  INTERVAL schedule — every 4 hours, 06:00–18:00 ─────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Intraday Position Report',
    @ReportEndpoint = '/api/reports/generate',

    @ScheduleName   = 'Intraday Position - Every 4 Hours',
    @FrequencyType  = 'INTERVAL',
    @IntervalMinutes = 240,
    @WindowStart    = '06:00',
    @WindowEnd      = '18:00',
    @Subject        = 'Intraday Position - {{TODAY}}',
    @BodyTemplate   = 'Current intraday position report attached.',

    @ParametersJson = N'[
        {
            "name": "AsOfDateTime",
            "type": "date", "required": true, "sortOrder": 1,
            "value": "{{TODAY}}",
            "dispatch": {
                "isPrimary":   true,
                "mode":        "BULK",
                "emailSource": "STATIC",
                "bulkEmail":   "trading-desk@example.com"
            }
        }
    ]';
GO


-- ─── 3.6  ADHOC — one-shot, fires once then disables itself ──
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Year End Summary',
    @ReportEndpoint = '/api/reports/generate',

    @ScheduleName   = 'Year End Summary - Adhoc Run',
    @FrequencyType  = 'ADHOC',
    @Subject        = 'Year End Summary - {{PREV_YEAR}}',
    @BodyTemplate   = 'Attached is the year end summary for {{PREV_YEAR}}.',

    @ParametersJson = N'[
        {
            "name": "ReportYear",
            "type": "string", "required": true, "sortOrder": 1,
            "value": "{{PREV_YEAR}}",
            "dispatch": {
                "isPrimary":   true,
                "mode":        "BULK",
                "emailSource": "STATIC",
                "bulkEmail":   "finance@example.com"
            }
        },
        { "name": "StartDate", "type": "date", "required": true, "sortOrder": 2, "value": "{{PREV_YEAR_START}}" },
        { "name": "EndDate",   "type": "date", "required": true, "sortOrder": 3, "value": "{{PREV_YEAR_END}}" }
    ]';
GO


-- ============================================================
--  SECTION 4  QUICK DIAGNOSTICS
-- ============================================================

-- Verify fn_FetchDocumentId resolves correctly
-- SELECT schdl.fn_FetchDocumentId('BRM Production Report') AS ResolvedDocumentId;

-- Verify a view returns the right shape
-- SELECT TOP 5 LookupKey, EmailAddress FROM schdl.vw_BRMEmail;

-- Verify a scalar function resolves
-- SELECT dbo.fn_GetBrokerEmail('39398') AS Email;

-- Run a test dispatch (bypasses all schedule gates)
-- EXEC schdl.usp_TestDispatch @ScheduleName = 'BRM Production Report - Monthly';

-- Check all tokens resolve correctly for today
-- SELECT TokenID, Token, Category, Description,
--        schdl.fn_ResolveDateToken(Token, CAST(GETDATE() AS DATE)) AS ResolvedToday
-- FROM   schdl.DateToken
-- WHERE  IsActive = 1
-- ORDER  BY Category, TokenID;

-- Check dispatch config for all documents
-- SELECT d.DocumentName, dp.ParameterName, dc.DispatchMode,
--        dc.EmailSource, dc.EmailSourceValue, dc.BulkEmailAddress
-- FROM   schdl.ParameterDispatchConfig dc
-- JOIN   schdl.DocumentParameter dp ON dp.ParameterID = dc.ParameterID
-- JOIN   schdl.Document          d  ON d.ReportID     = dp.ReportID
-- ORDER  BY d.DocumentName, dp.SortOrder;


-- ─── 3.7  FOLDER DROP — individual folder per BRM ────────────
--  Resolves a folder path per BRM value from a lookup view.
--  FileName overridden using a template with date tokens and DisplayName.
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'BRM Production Report',
    @ReportEndpoint = '/api/reports/generate',
    @OutputFormat   = 'xlsx',

    @ScheduleName   = 'BRM Production Report - Monthly Folder Drop',
    @FrequencyType  = 'MONTHLY',
    @RunTime        = '06:00',
    @DayOfMonth     = 1,
    @Subject        = NULL,   -- no email subject needed for folder drop
    @BodyTemplate   = NULL,

    @ParametersJson = N'[
        {
            "name": "BrokerRelationshipManager",
            "type": "string", "required": true, "sortOrder": 1,
            "value": "BRM001|BRM002|BRM003|BRM004|BRM005|BRM006|BRM007|BRM008",
            "dispatch": {
                "isPrimary":            true,
                "mode":                 "INDIVIDUAL",
                "deliveryMethod":       "FOLDER",

                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_BRMDisplayName",

                "fileNameTemplate":       "BRM_{{DISPLAYNAME}}_{{PREV_MONTH_START}}_{{PREV_MONTH_END}}.xlsx",

                "folderSource":           "LOOKUP_VIEW",
                "folderSourceValue":      "schdl.vw_BRMFolderPath"
            }
        },
        { "name": "CaptureDateTo",    "type": "date",   "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" },
        { "name": "CapturedDateFrom", "type": "date",   "required": true, "sortOrder": 3, "value": "{{PREV_MONTH_START}}" }
    ]';
GO


-- ─── 3.8  BOTH delivery — email + folder drop per BRM ────────
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'BRM Production Report',
    @ReportEndpoint = '/api/reports/generate',
    @OutputFormat   = 'xlsx',

    @ScheduleName   = 'BRM Production Report - Monthly Email and Folder',
    @FrequencyType  = 'MONTHLY',
    @RunTime        = '06:00',
    @DayOfMonth     = 1,
    @Subject        = 'BRM Production Report - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}',
    @BodyTemplate   = 'Please find attached your production report for {{PREV_MONTH_START}} to {{PREV_MONTH_END}}.',

    @ParametersJson = N'[
        {
            "name": "BrokerRelationshipManager",
            "type": "string", "required": true, "sortOrder": 1,
            "value": "BRM001|BRM002|BRM003|BRM004|BRM005|BRM006|BRM007|BRM008",
            "dispatch": {
                "isPrimary":            true,
                "mode":                 "BOTH",
                "deliveryMethod":       "BOTH",

                "emailSource":            "LOOKUP_VIEW",
                "emailSourceValue":       "schdl.vw_BRMEmail",
                "bulkEmail":              "reports-bulk@example.com",

                "displayNameSource":      "LOOKUP_VIEW",
                "displayNameSourceValue": "schdl.vw_BRMDisplayName",

                "fileNameTemplate":       "BRM_{{DISPLAYNAME}}_{{PREV_MONTH_START}}_{{PREV_MONTH_END}}.xlsx",

                "folderSource":           "LOOKUP_VIEW",
                "folderSourceValue":      "schdl.vw_BRMFolderPath",
                "bulkFolderPath":         "\\server\reports\BRM\Bulk\"
            }
        },
        { "name": "CaptureDateTo",    "type": "date",   "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" },
        { "name": "CapturedDateFrom", "type": "date",   "required": true, "sortOrder": 3, "value": "{{PREV_MONTH_START}}" }
    ]',
    @RecipientsJson = N'[
        {"name": "Reports Admin", "email": "reports-admin@example.com", "role": "CC"}
    ]';
GO


-- ============================================================
--  SECTION 5  SAMPLE LOOKUP VIEWS FOR NEW RESOLVERS
-- ============================================================

-- DisplayName view — exposes entity name per dispatch key
CREATE OR ALTER VIEW [schdl].[vw_BRMDisplayName]
AS
    SELECT
        sBRMCode    AS LookupKey,
        sFullName   AS DisplayName       -- column name must be DisplayName
    FROM dbo.BrokerRelationshipManager
    WHERE bActive = 1;
GO

-- FolderPath view — exposes folder drop path per dispatch key
CREATE OR ALTER VIEW [schdl].[vw_BRMFolderPath]
AS
    SELECT
        sBRMCode        AS LookupKey,
        sReportFolder   AS FolderPath    -- column name must be FolderPath
    FROM dbo.BrokerRelationshipManager
    WHERE bActive = 1;
GO

-- Combined view — all four resolvers in one view
-- Use this when Email, DisplayName, FileName, and FolderPath
-- all come from the same table. Reference it in each sourceValue.
CREATE OR ALTER VIEW [schdl].[vw_BRMAll]
AS
    SELECT
        sBRMCode        AS LookupKey,
        sEmailAddress   AS EmailAddress,   -- for emailSourceValue
        sFullName       AS DisplayName,    -- for displayNameSourceValue
        sReportFolder   AS FolderPath      -- for folderSourceValue
    FROM dbo.BrokerRelationshipManager
    WHERE bActive = 1;
GO

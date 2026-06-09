-- ============================================================
--  SCHEDULING AGENT  v3  |  SQL Server (T-SQL)
--  DROP AND CREATE SCRIPT
--
--  Drops all sched schema objects in FK-safe reverse order,
--  then recreates everything cleanly from scratch.
--  Safe to run repeatedly against any environment.
-- ============================================================


-- ============================================================
--  SECTION 0  DROP  (reverse dependency order)
-- ============================================================

-- Procedures
IF OBJECT_ID('[schdl].[usp_UpdateDispatchStatus]', 'P')  IS NOT NULL DROP PROCEDURE [schdl].[usp_UpdateDispatchStatus];
IF OBJECT_ID('[schdl].[usp_GetDueSchedules]',       'P')  IS NOT NULL DROP PROCEDURE [schdl].[usp_GetDueSchedules];
IF OBJECT_ID('[schdl].[usp_BuildDispatchQueue]',    'P')  IS NOT NULL DROP PROCEDURE [schdl].[usp_BuildDispatchQueue];
IF OBJECT_ID('[schdl].[usp_TestDispatch]',           'P')  IS NOT NULL DROP PROCEDURE [schdl].[usp_TestDispatch];
IF OBJECT_ID('[schdl].[usp_GetScheduleJson]',        'P')  IS NOT NULL DROP PROCEDURE [schdl].[usp_GetScheduleJson];
IF OBJECT_ID('[schdl].[usp_RegisterSchedule]',      'P')  IS NOT NULL DROP PROCEDURE [schdl].[usp_RegisterSchedule];
GO

-- Functions (after procs that reference them)
IF OBJECT_ID('[schdl].[fn_FetchDocumentId]',  'FN') IS NOT NULL DROP FUNCTION [schdl].[fn_FetchDocumentId];
IF OBJECT_ID('[schdl].[fn_ResolveDateToken]', 'FN') IS NOT NULL DROP FUNCTION [schdl].[fn_ResolveDateToken];
GO

-- Tables (children before parents to satisfy FK constraints)
IF OBJECT_ID('[schdl].[DispatchQueue]',           'U') IS NOT NULL DROP TABLE [schdl].[DispatchQueue];
IF OBJECT_ID('[schdl].[ExecutionLog]',            'U') IS NOT NULL DROP TABLE [schdl].[ExecutionLog];
IF OBJECT_ID('[schdl].[ScheduleRecipient]',       'U') IS NOT NULL DROP TABLE [schdl].[ScheduleRecipient];
IF OBJECT_ID('[schdl].[ScheduleParameter]',       'U') IS NOT NULL DROP TABLE [schdl].[ScheduleParameter];
IF OBJECT_ID('[schdl].[ParameterDispatchConfig]', 'U') IS NOT NULL DROP TABLE [schdl].[ParameterDispatchConfig];
IF OBJECT_ID('[schdl].[DocumentParameter]',       'U') IS NOT NULL DROP TABLE [schdl].[DocumentParameter];
IF OBJECT_ID('[schdl].[Schedule]',                'U') IS NOT NULL DROP TABLE [schdl].[Schedule];
IF OBJECT_ID('[schdl].[Recipient]',               'U') IS NOT NULL DROP TABLE [schdl].[Recipient];
IF OBJECT_ID('[schdl].[Document]',                'U') IS NOT NULL DROP TABLE [schdl].[Document];
IF OBJECT_ID('[schdl].[DateToken]',               'U') IS NOT NULL DROP TABLE [schdl].[DateToken];
GO

-- ============================================================
--  SECTION 1  DDL
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'schdl')
    EXEC('CREATE SCHEMA [schdl]');
GO

-- 1.1  DateToken reference table
--
--  Complete catalogue of every supported date token.
--  TokenID is for reference and admin queries only.
--  Always use the {{TOKEN}} string in ScheduleParameter.ParameterValue.
--
--  Always use the {{TOKEN}} string in parameter values.
--  TokenID is for reference and admin queries only.
--
--  Dynamic offsets {{TODAY-N}} / {{TODAY+N}} (any N) are
--  resolved inline by fn_ResolveDateToken and do not need
--  a row here.
CREATE TABLE [schdl].[DateToken] (
    TokenID     INT             IDENTITY(1,1) PRIMARY KEY,
    Token       NVARCHAR(100)   NOT NULL UNIQUE,
    Description NVARCHAR(500)   NOT NULL,
    Category    NVARCHAR(50)    NOT NULL
        CHECK (Category IN ('TODAY','WEEK','MONTH','QUARTER','YEAR')),
    IsActive    BIT             NOT NULL DEFAULT 1
);
GO

INSERT INTO [schdl].[DateToken] (Token, Description, Category) VALUES
('{{TODAY}}',             'Current execution date (YYYY-MM-DD)',           'TODAY'),
('{{TODAY-1}}',           'Yesterday: 1 day before execution date',        'TODAY'),
('{{TODAY-7}}',           '7 days before execution date',                  'TODAY'),
('{{TODAY-14}}',          '14 days before execution date',                 'TODAY'),
('{{TODAY-30}}',          '30 days before execution date',                 'TODAY'),
('{{TODAY-90}}',          '90 days before execution date',                 'TODAY'),
('{{TODAY+1}}',           'Tomorrow: 1 day after execution date',          'TODAY'),
('{{TODAY+7}}',           '7 days after execution date',                   'TODAY'),
('{{WEEK_START}}',        'Monday of the current week',                    'WEEK'),
('{{WEEK_END}}',          'Sunday of the current week',                    'WEEK'),
('{{PREV_WEEK_START}}',   'Monday of the previous week',                   'WEEK'),
('{{PREV_WEEK_END}}',     'Sunday of the previous week',                   'WEEK'),
('{{MONTH_START}}',       'First day of the current month',                'MONTH'),
('{{MONTH_END}}',         'Last day of the current month',                 'MONTH'),
('{{PREV_MONTH_START}}',  'First day of the previous month',               'MONTH'),
('{{PREV_MONTH_END}}',    'Last day of the previous month',                'MONTH'),
('{{NEXT_MONTH_START}}',  'First day of the next month',                   'MONTH'),
('{{NEXT_MONTH_END}}',    'Last day of the next month',                    'MONTH'),
('{{QUARTER_START}}',     'First day of the current calendar quarter',     'QUARTER'),
('{{QUARTER_END}}',       'Last day of the current calendar quarter',      'QUARTER'),
('{{PREV_QUARTER_START}}','First day of the previous calendar quarter',    'QUARTER'),
('{{PREV_QUARTER_END}}',  'Last day of the previous calendar quarter',     'QUARTER'),
('{{YEAR}}',              'Current 4-digit year (e.g. 2026)',              'YEAR'),
('{{YEAR_START}}',        'First day of the current year (1 Jan)',         'YEAR'),
('{{YEAR_END}}',          'Last day of the current year (31 Dec)',         'YEAR'),
('{{PREV_YEAR}}',         'Previous 4-digit year (e.g. 2025)',             'YEAR'),
('{{PREV_YEAR_START}}',   'First day of the previous year (1 Jan)',        'YEAR'),
('{{PREV_YEAR_END}}',     'Last day of the previous year (31 Dec)',        'YEAR');
GO


-- 1.2  Document catalogue
--  DocumentName is the stable env-agnostic key used everywhere.
--  The actual documentId sent in RequestJson is never stored --
--  it is fetched live at dispatch time by fn_FetchDocumentId.
--  ReportID is the internal surrogate key for this row only.
CREATE TABLE [schdl].[Document] (
    ReportID                INT             IDENTITY(1,1) PRIMARY KEY,
    DocumentName            NVARCHAR(255)   NOT NULL UNIQUE,
    ReportEndpoint          NVARCHAR(500)   NOT NULL,
    Description             NVARCHAR(1000)  NULL,
    DefaultOutputFormat     NVARCHAR(20)    NOT NULL DEFAULT 'xlsx',
    DefaultLanguage         INT             NOT NULL DEFAULT 1,
    DefaultConfidentiality  NVARCHAR(50)    NOT NULL DEFAULT 'normal',
    IsActive                BIT             NOT NULL DEFAULT 1,
    CreatedAt               DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    ModifiedAt              DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);
GO


-- 1.4  Document parameters
CREATE TABLE [schdl].[DocumentParameter] (
    ParameterID     INT             IDENTITY(1,1) PRIMARY KEY,
    ReportID        INT             NOT NULL REFERENCES [schdl].[Document](ReportID),
    ParameterName   NVARCHAR(100)   NOT NULL,
    DataType        NVARCHAR(50)    NOT NULL DEFAULT 'string',
    IsRequired      BIT             NOT NULL DEFAULT 1,
    DefaultValue    NVARCHAR(500)   NULL,
    SortOrder       INT             NOT NULL DEFAULT 0,
    CONSTRAINT UQ_DocumentParameter UNIQUE (ReportID, ParameterName)
);
GO


-- 1.5  Parameter dispatch config
--
--  One row per parameter that drives fan-out or delivery routing.
--  Parameters with no row here are passed through unchanged.
--
--  DispatchMode
--    COMBINED    all values bundled into one report, delivered to combined destination
--    INDIVIDUAL  one report per value, destination resolved per value
--    BOTH        produces INDIVIDUAL rows AND one BULK row
--
--  DeliveryMethod
--    EMAIL       resolve email address, send via email
--    FOLDER      resolve folder path, drop file to location
--    BOTH        do both email send and folder drop per row
--
--  All four sources (STATIC / LOOKUP_VIEW / SCALAR_FN / DYNAMIC_SQL)
--  apply identically to Email, Folder, and DisplayName / FileName resolvers.
--
--  Source pattern     SourceValue
--  ─────────────────  ──────────────────────────────────────────────
--  STATIC             literal value  e.g. "\server
eports\BRM"
--  LOOKUP_VIEW        "schdl.vw_BRMFolder"
--                     View must expose: LookupKey, <TargetColumn>
--  SCALAR_FN          "dbo.fn_GetBRMFolder"
--                     fn(@Value NVARCHAR(500)) RETURNS NVARCHAR target
--  DYNAMIC_SQL        SQL with {VALUE} placeholder
--                     Must return column named per target (see below)
--
--  Column naming convention for LOOKUP_VIEW / DYNAMIC_SQL:
--    Email resolver   → EmailAddress
--    DisplayName      → DisplayName   (used as email display name / attachment prefix)
--    FileName         → FileName      (overrides the report filename)
--    FolderPath       → FolderPath    (destination folder for file drop)
CREATE TABLE [schdl].[ParameterDispatchConfig] (
    ConfigID                INT             IDENTITY(1,1) PRIMARY KEY,
    ParameterID             INT             NOT NULL UNIQUE
        REFERENCES [schdl].[DocumentParameter](ParameterID),
    IsPrimaryDispatchKey    BIT             NOT NULL DEFAULT 0,
    DispatchMode            NVARCHAR(12)    NOT NULL DEFAULT 'COMBINED'
        CHECK (DispatchMode IN ('COMBINED','INDIVIDUAL','BOTH')),

    -- Email delivery (fan-out per-entity resolver)
    -- Delivery method is set at the Schedule level, not here.
    -- Per-entity email resolver (fan-out only)
    -- For combined/bulk email address, see Schedule.EmailSourceValue
    EmailSource             NVARCHAR(20)    NOT NULL DEFAULT 'STATIC'
        CHECK (EmailSource IN ('STATIC','LOOKUP_VIEW','SCALAR_FN','DYNAMIC_SQL')),
    EmailSourceValue        NVARCHAR(1000)  NULL,

    -- Display name resolver (email To name / attachment filename prefix)
    -- Resolved value appended to filename: "BRM001 - Report.xlsx"
    DisplayNameSource       NVARCHAR(20)    NULL
        CHECK (DisplayNameSource IN ('STATIC','LOOKUP_VIEW','SCALAR_FN','DYNAMIC_SQL')),
    DisplayNameSourceValue  NVARCHAR(1000)  NULL,

    -- File name override (overrides the default report filename per dispatch row)
    -- When NULL the report API filename is used unchanged
    FileNameSource          NVARCHAR(20)    NULL
        CHECK (FileNameSource IN ('STATIC','LOOKUP_VIEW','SCALAR_FN','DYNAMIC_SQL')),
    FileNameSourceValue     NVARCHAR(1000)  NULL,
    FileNameTemplate        NVARCHAR(500)   NULL,   -- e.g. 'BRM_{{PREV_MONTH_END}}_{{DISPLAYNAME}}.xlsx'
                                                    -- {{DISPLAYNAME}}    replaced with resolved Entity Label (see DisplayNameSource config)
                                                    -- {{REPORTNAME}}   replaced with DocumentName
                                                    -- {{TOKEN}}        replaced with resolved date token

    -- Folder drop delivery
    -- Per-entity folder resolver (fan-out only)
    -- For combined/bulk folder path, see Schedule.FolderSourceValue
    FolderSource            NVARCHAR(20)    NULL
        CHECK (FolderSource IN ('STATIC','LOOKUP_VIEW','SCALAR_FN','DYNAMIC_SQL')),
    FolderSourceValue       NVARCHAR(1000)  NULL
);
GO


-- 1.6  Schedule definitions
CREATE TABLE [schdl].[Schedule] (
    ScheduleID      INT             IDENTITY(1,1) PRIMARY KEY,
    ScheduleName    NVARCHAR(255)   NOT NULL UNIQUE,
    ReportID        INT             NOT NULL REFERENCES [schdl].[Document](ReportID),
    FrequencyType   NVARCHAR(20)    NOT NULL
        CHECK (FrequencyType IN ('DAILY','WEEKLY','MONTHLY','ADHOC','INTERVAL')),
    RunTime         TIME            NULL,
    DayOfWeek       TINYINT         NULL,   -- 0=Sun ... 6=Sat
    DayOfMonth      SMALLINT        NULL,   -- 1-31  |  -1=last day of month
    IntervalMinutes INT             NULL,
    WindowStart     TIME            NULL,
    WindowEnd       TIME            NULL,
    NextRunAt       DATETIME2       NULL,
    StartDate       DATE            NOT NULL DEFAULT '2000-01-01',
    EndDate         DATE            NULL,
    IsActive        BIT             NOT NULL DEFAULT 1,
    Subject         NVARCHAR(500)   NULL,
    BodyTemplate    NVARCHAR(MAX)   NULL,
    --
    -- Schedule-level delivery configuration
    -- These apply to the combined/bulk row and to all rows when fan-out is not active.
    -- Fan-out per-entity resolvers live in ParameterDispatchConfig.
    --
    DeliveryMethod          NVARCHAR(10)   NOT NULL DEFAULT 'EMAIL'
        CHECK (DeliveryMethod IN ('EMAIL','FOLDER','BOTH')),
    -- Combined email recipient
    EmailSource             NVARCHAR(20)   NULL
        CHECK (EmailSource IN ('STATIC','LOOKUP_VIEW','SCALAR_FN','DYNAMIC_SQL')),
    EmailSourceValue        NVARCHAR(1000) NULL,
    -- File name override (applies to combined row; fan-out rows may override per-entity)
    FileNameTemplate        NVARCHAR(500)  NULL,
    FileNameSource          NVARCHAR(20)   NULL
        CHECK (FileNameSource IN ('STATIC','LOOKUP_VIEW','SCALAR_FN','DYNAMIC_SQL')),
    FileNameSourceValue     NVARCHAR(1000) NULL,
    -- Folder drop destination (combined row)
    FolderSource            NVARCHAR(20)   NULL
        CHECK (FolderSource IN ('STATIC','LOOKUP_VIEW','SCALAR_FN','DYNAMIC_SQL')),
    FolderSourceValue       NVARCHAR(1000) NULL,
    --
    CreatedAt       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    ModifiedAt      DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);
GO


-- 1.7  Schedule parameter values
--
--  Two ways to supply values — use ONE per parameter row:
--
--  a) ParameterValue  (static)
--     Literal, pipe-delimited, or token string resolved at runtime.
--     Examples:
--       "39398"                    literal
--       "BRM001|BRM002|BRM003"     pipe-delimited multi-value
--       "{{PREV_MONTH_END}}"       date token
--       "{{PREV_MONTH_START}}|{{TODAY}}"  mixed
--
--  b) ParameterValueQuery  (dynamic)
--     A SQL SELECT that returns one column named [Value].
--     Executed at dispatch time — results are joined as
--     pipe-delimited values, exactly as if you had typed them
--     in ParameterValue.
--     The query runs in the context of the scheduling DB.
--     Example:
--       SELECT sBRMCode AS [Value]
--       FROM   dbo.BrokerRelationshipManager
--       WHERE  bActive = 1
--       ORDER  BY sBRMCode
--
--  If ParameterValueQuery is populated it takes precedence
--  over ParameterValue. ParameterValue is still required
--  (set it to a placeholder like 'DYNAMIC') so the NOT NULL
--  constraint is satisfied.
CREATE TABLE [schdl].[ScheduleParameter] (
    ScheduleParamID      INT             IDENTITY(1,1) PRIMARY KEY,
    ScheduleID           INT             NOT NULL REFERENCES [schdl].[Schedule](ScheduleID),
    ParameterID          INT             NOT NULL REFERENCES [schdl].[DocumentParameter](ParameterID),
    ParameterValue       NVARCHAR(MAX)   NOT NULL,        -- static value(s); set 'DYNAMIC' when using query
    ParameterValueQuery  NVARCHAR(MAX)   NULL,            -- optional SQL SELECT returning [Value] column
    CONSTRAINT UQ_ScheduleParam UNIQUE (ScheduleID, ParameterID)
);
GO


-- 1.8  Recipients
CREATE TABLE [schdl].[Recipient] (
    RecipientID     INT             IDENTITY(1,1) PRIMARY KEY,
    RecipientName   NVARCHAR(255)   NOT NULL,
    EmailAddress    NVARCHAR(320)   NOT NULL UNIQUE,
    IsActive        BIT             NOT NULL DEFAULT 1,
    CreatedAt       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE [schdl].[ScheduleRecipient] (
    ScheduleRecipientID INT  IDENTITY(1,1) PRIMARY KEY,
    ScheduleID          INT  NOT NULL REFERENCES [schdl].[Schedule](ScheduleID),
    RecipientID         INT  NOT NULL REFERENCES [schdl].[Recipient](RecipientID),
    RecipientRole       NVARCHAR(10) NOT NULL DEFAULT 'TO'
        CHECK (RecipientRole IN ('TO','CC','BCC')),
    CONSTRAINT UQ_SchedRecipient UNIQUE (ScheduleID, RecipientID, RecipientRole)
);
GO


-- 1.9  Execution log
CREATE TABLE [schdl].[ExecutionLog] (
    LogID        BIGINT          IDENTITY(1,1) PRIMARY KEY,
    ScheduleID   INT             NOT NULL REFERENCES [schdl].[Schedule](ScheduleID),
    ExecutedAt   DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    Status       NVARCHAR(20)    NOT NULL DEFAULT 'PENDING'
        CHECK (Status IN ('PENDING','SUCCESS','FAILED','SKIPPED')),
    ErrorMessage NVARCHAR(MAX)   NULL,
    ProcessedAt  DATETIME2       NULL
);
GO


-- 1.10  Dispatch queue  (one row per delivery action)
CREATE TABLE [schdl].[DispatchQueue] (
    QueueID          BIGINT          IDENTITY(1,1) PRIMARY KEY,
    LogID            BIGINT          NOT NULL REFERENCES [schdl].[ExecutionLog](LogID),
    ScheduleID       INT             NOT NULL REFERENCES [schdl].[Schedule](ScheduleID),
    DispatchType     NVARCHAR(12)    NOT NULL CHECK (DispatchType IN ('INDIVIDUAL','COMBINED')),
    DeliveryMethod   NVARCHAR(10)    NOT NULL DEFAULT 'EMAIL'
        CHECK (DeliveryMethod IN ('EMAIL','FOLDER','BOTH')),
    DispatchKeyValue NVARCHAR(500)   NULL,
    -- Resolved entity display name (e.g. 'Broker ABC')
    DisplayName      NVARCHAR(500)   NULL,
    -- Resolved filename (overrides API default when not NULL)
    FileName         NVARCHAR(500)   NULL,
    RequestJson      NVARCHAR(MAX)   NOT NULL,
    -- Email delivery fields
    ToAddresses      NVARCHAR(MAX)   NULL,
    CcAddresses      NVARCHAR(MAX)   NULL,
    BccAddresses     NVARCHAR(MAX)   NULL,
    EmailSubject     NVARCHAR(500)   NULL,
    EmailBody        NVARCHAR(MAX)   NULL,
    -- Folder drop fields
    FolderPath       NVARCHAR(1000)  NULL,
    Status           NVARCHAR(20)    NOT NULL DEFAULT 'PENDING'
        CHECK (Status IN ('PENDING','SENT','FAILED','SKIPPED')),
    CreatedAt        DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    ProcessedAt      DATETIME2       NULL,
    ErrorMessage     NVARCHAR(MAX)   NULL
);
GO

-- ============================================================
--  SECTION 2  SCALAR FUNCTIONS
-- ============================================================

-- 2.1  fn_ResolveDateToken
--
--  Resolves a date token to a YYYY-MM-DD string.
--  Accepts:
--    {{TOKEN}}    string from schdl.DateToken
--    "16"         TokenID integer (looked up → Token → resolved)
--    {{TODAY-N}}  dynamic offset, any N
--    {{TODAY+N}}  dynamic offset, any N
--    anything else returned unchanged (literal pass-through)
--
--  Pipe-delimited values are NOT split here.
--  The caller splits on | and calls this per segment.
--
--  Full token list: SELECT * FROM schdl.DateToken
CREATE FUNCTION [schdl].[fn_ResolveDateToken]
(
    @RawValue NVARCHAR(500),
    @AsOfDate DATE = NULL
)
RETURNS NVARCHAR(500)
AS
BEGIN
    DECLARE @Today  DATE          = ISNULL(@AsOfDate, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @Result NVARCHAR(500) = LTRIM(RTRIM(@RawValue));

    -- Token strings only. Use {{TOKEN}} syntax exclusively.
    -- TokenID integers are not supported as parameter values.
    -- Plain integers and all non-{{...}} values pass through unchanged.

    -- Dynamic negative offset  {{TODAY-N}}
    --   {{TODAY-1}}  →  prefix '{{TODAY-' = 8 chars, suffix '}}' = 2 chars
    --   N starts at position 9, length = LEN - 10
    IF @Result LIKE '{{TODAY-[0-9]%}}'
    BEGIN
        DECLARE @Neg INT = TRY_CAST(SUBSTRING(@Result, 9, LEN(@Result) - 10) AS INT);
        IF @Neg IS NOT NULL RETURN CONVERT(NVARCHAR(20), DATEADD(DAY, -@Neg, @Today), 23);
    END;

    -- Dynamic positive offset  {{TODAY+N}}
    --   {{TODAY+1}}  →  prefix '{{TODAY+' = 8 chars, suffix '}}' = 2 chars
    --   N starts at position 9, length = LEN - 10
    IF @Result LIKE '{{TODAY+[0-9]%}}'
    BEGIN
        DECLARE @Pos INT = TRY_CAST(SUBSTRING(@Result, 9, LEN(@Result) - 10) AS INT);
        IF @Pos IS NOT NULL RETURN CONVERT(NVARCHAR(20), DATEADD(DAY, @Pos, @Today), 23);
    END;

    -- TODAY
    IF @Result = '{{TODAY}}'           RETURN CONVERT(NVARCHAR(20),@Today,23);

    -- Current week  (Mon=start, Sun=end)
    IF @Result = '{{WEEK_START}}'
        RETURN CONVERT(NVARCHAR(20),DATEADD(DAY,1-DATEPART(WEEKDAY,@Today),@Today),23);
    IF @Result = '{{WEEK_END}}'
        RETURN CONVERT(NVARCHAR(20),DATEADD(DAY,7-DATEPART(WEEKDAY,@Today),@Today),23);

    -- Previous week
    IF @Result = '{{PREV_WEEK_START}}'
        RETURN CONVERT(NVARCHAR(20),DATEADD(DAY,1-DATEPART(WEEKDAY,@Today)-7,@Today),23);
    IF @Result = '{{PREV_WEEK_END}}'
        RETURN CONVERT(NVARCHAR(20),DATEADD(DAY,7-DATEPART(WEEKDAY,@Today)-7,@Today),23);

    -- Current month
    IF @Result = '{{MONTH_START}}'
        RETURN CONVERT(NVARCHAR(20),DATEFROMPARTS(YEAR(@Today),MONTH(@Today),1),23);
    IF @Result = '{{MONTH_END}}'
        RETURN CONVERT(NVARCHAR(20),EOMONTH(@Today),23);

    -- Previous month
    IF @Result = '{{PREV_MONTH_START}}'
        RETURN CONVERT(NVARCHAR(20),
            DATEFROMPARTS(YEAR(DATEADD(MONTH,-1,@Today)),MONTH(DATEADD(MONTH,-1,@Today)),1),23);
    IF @Result = '{{PREV_MONTH_END}}'
        RETURN CONVERT(NVARCHAR(20),EOMONTH(DATEADD(MONTH,-1,@Today)),23);

    -- Next month
    IF @Result = '{{NEXT_MONTH_START}}'
        RETURN CONVERT(NVARCHAR(20),
            DATEFROMPARTS(YEAR(DATEADD(MONTH,1,@Today)),MONTH(DATEADD(MONTH,1,@Today)),1),23);
    IF @Result = '{{NEXT_MONTH_END}}'
        RETURN CONVERT(NVARCHAR(20),EOMONTH(DATEADD(MONTH,1,@Today)),23);

    -- Current quarter
    IF @Result = '{{QUARTER_START}}'
    BEGIN
        DECLARE @QS DATE = DATEFROMPARTS(YEAR(@Today),((MONTH(@Today)-1)/3)*3+1,1);
        RETURN CONVERT(NVARCHAR(20),@QS,23);
    END;
    IF @Result = '{{QUARTER_END}}'
    BEGIN
        DECLARE @QE DATE = EOMONTH(DATEFROMPARTS(YEAR(@Today),((MONTH(@Today)-1)/3)*3+3,1));
        RETURN CONVERT(NVARCHAR(20),@QE,23);
    END;

    -- Previous quarter
    IF @Result = '{{PREV_QUARTER_START}}'
    BEGIN
        DECLARE @PQS DATE =
            DATEADD(MONTH,-3,DATEFROMPARTS(YEAR(@Today),((MONTH(@Today)-1)/3)*3+1,1));
        RETURN CONVERT(NVARCHAR(20),@PQS,23);
    END;
    IF @Result = '{{PREV_QUARTER_END}}'
    BEGIN
        DECLARE @PQE DATE = EOMONTH(DATEADD(MONTH,-1,
            DATEFROMPARTS(YEAR(@Today),((MONTH(@Today)-1)/3)*3+1,1)));
        RETURN CONVERT(NVARCHAR(20),@PQE,23);
    END;

    -- Current year
    IF @Result = '{{YEAR}}'       RETURN CAST(YEAR(@Today) AS NVARCHAR(10));
    IF @Result = '{{YEAR_START}}' RETURN CONVERT(NVARCHAR(20),DATEFROMPARTS(YEAR(@Today),1,1),23);
    IF @Result = '{{YEAR_END}}'   RETURN CONVERT(NVARCHAR(20),DATEFROMPARTS(YEAR(@Today),12,31),23);

    -- Previous year
    IF @Result = '{{PREV_YEAR}}'
        RETURN CAST(YEAR(@Today)-1 AS NVARCHAR(10));
    IF @Result = '{{PREV_YEAR_START}}'
        RETURN CONVERT(NVARCHAR(20),DATEFROMPARTS(YEAR(@Today)-1,1,1),23);
    IF @Result = '{{PREV_YEAR_END}}'
        RETURN CONVERT(NVARCHAR(20),DATEFROMPARTS(YEAR(@Today)-1,12,31),23);

    -- Not a token -- return unchanged
    RETURN @Result;
END;
GO


-- 2.2  fn_FetchDocumentId
--
--  Resolves the API documentId for a given DocumentName.
--  This function contains NO stored mappings -- it queries
--  whatever system owns the document catalogue live.
--
--  IMPLEMENT ONCE PER ENVIRONMENT -- replace the SELECT body
--  with the query that fetches documentId from your source.
--
--  Input  : @DocumentName  NVARCHAR(255)
--  Output : NVARCHAR(100)  -- the documentId to send in RequestJson
--           Returns NULL when no match found (dispatch row
--           will be inserted with an empty documentId and
--           flagged in the log for investigation).
--
--  ── Example sources ──────────────────────────────────────────
--  Your own catalogue table:
--    SELECT TOP 1 @ID = CAST(DocID AS NVARCHAR(100))
--    FROM dbo.ReportCatalogue
--    WHERE DocumentName = @DocumentName AND IsActive = 1
--
--  SSRS ReportServer database:
--    SELECT TOP 1 @ID = CAST(ItemID AS NVARCHAR(100))
--    FROM ReportServer.dbo.Catalog
--    WHERE Name = @DocumentName AND Type = 2
--
--  Any linked server, synonym, or view works here.
-- ─────────────────────────────────────────────────────────────
CREATE FUNCTION [schdl].[fn_FetchDocumentId]
(
    @DocumentName NVARCHAR(255)
)
RETURNS NVARCHAR(100)
AS
BEGIN
    DECLARE @ID NVARCHAR(100);

    SELECT TOP 1 @ID = CAST(CAST(iDocumentID AS BIGINT) AS NVARCHAR(100))
    FROM   dbo.Document
    WHERE  sName     = @DocumentName
      AND  bEnabled  = 1;

    RETURN @ID;
END;
GO


-- 2.3  fn_ResolveEmail REMOVED
--
--  sp_executesql cannot be called from a scalar function.
--  Email resolution is handled inline in usp_BuildDispatchQueue
--  via the usp_ResolveEmail helper procedure (see Section 4).

-- ============================================================
--  SECTION 3  SETUP PROC  --  usp_RegisterSchedule
--
--  Single entry point. One call defines or updates everything.
--  Re-runnable (full UPSERT on every object).
--
--  PARAMETER QUICK REFERENCE
--  ─────────────────────────────────────────────────────────
--  @DocumentName       Stable name -- drives live documentId
--                      resolution at runtime via the resolver
--  @ReportEndpoint     API URL path
--  @OutputFormat       xlsx | pdf | csv          (def: xlsx)
--  @Language           language code             (def: 1)
--  @Confidentiality    confidentiality label      (def: normal)
--
--  @ScheduleName       Unique label for this schedule
--  @FrequencyType      DAILY | WEEKLY | MONTHLY | ADHOC | INTERVAL
--  @RunTime            'HH:MM'
--  @DayOfWeek          0=Sun ... 6=Sat            (WEEKLY)
--  @DayOfMonth         1-31 | -1=last day         (MONTHLY)
--  @IntervalMinutes                               (INTERVAL)
--  @WindowStart/End    'HH:MM' window             (INTERVAL)
--  @StartDate          default today
--  @EndDate            NULL = no expiry
--  @Subject            email subject  (tokens supported)
--  @BodyTemplate       email body     (tokens supported)
--
--  @DispatchJson       Schedule-level delivery config (separate from fan-out):
--  {
--    "deliveryMethod":    "EMAIL | FOLDER | BOTH",
--    "emailSource":       "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
--    "emailSourceValue":  "address | view | fn | sql",
--    "folderSource":      "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
--    "folderSourceValue": "path | view | fn | sql",
--    "fileNameTemplate":  "{{REPORTNAME}}_{{PREV_MONTH_END}}",
--    "fileNameSource":    "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
--    "fileNameSourceValue": "value | view | fn | sql"
--  }
--
--  @ParametersJson     JSON array. Each element:
--  {
--    "name":       "ParameterName",
--    "type":       "string | date | int",
--    "required":   true,
--    "sortOrder":  1,
--    "value":      "BRM001|BRM002"       pipe-delimited OR token string
--    "valueQuery": "SELECT v AS [Value] FROM ..."   optional dynamic query
--
--    "fanOut": {                         OPTIONAL — only on the primary dispatch parameter
--      "mode":                  "INDIVIDUAL | BOTH",
--      "emailSource":           "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
--      "emailSourceValue":      "...",
--      "displayNameSource":     "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
--      "displayNameSourceValue":"...",
--      "fileNameTemplate":      "{{REPORTNAME}}_{{DISPLAYNAME}}_{{PREV_MONTH_END}}",
--      "fileNameSource":        "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
--      "fileNameSourceValue":   "...",
--      "folderSource":          "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
--      "folderSourceValue":     "..."
--    }
--  }
--
--  @RecipientsJson     JSON array for CC/BCC (TO resolved via @DispatchJson):
--  [{"name":"x","email":"x@x.com","role":"CC|BCC"}]
-- ============================================================
CREATE PROCEDURE [schdl].[usp_RegisterSchedule]
    @DocumentName       NVARCHAR(255),
    @ReportEndpoint     NVARCHAR(500),
    @OutputFormat       NVARCHAR(20)    = 'xlsx',
    @Language           INT             = 1,
    @Confidentiality    NVARCHAR(50)    = 'normal',
    @ScheduleName       NVARCHAR(255),
    @FrequencyType      NVARCHAR(20),
    @RunTime            TIME            = NULL,
    @DayOfWeek          TINYINT         = NULL,
    @DayOfMonth         SMALLINT        = NULL,
    @IntervalMinutes    INT             = NULL,
    @WindowStart        TIME            = NULL,
    @WindowEnd          TIME            = NULL,
    @StartDate          DATE            = NULL,
    @EndDate            DATE            = NULL,
    @Subject            NVARCHAR(500)   = NULL,
    @BodyTemplate       NVARCHAR(MAX)   = NULL,
    @DispatchJson       NVARCHAR(MAX)   = NULL,   -- schedule-level delivery config
    @ParametersJson     NVARCHAR(MAX)   = NULL,
    @RecipientsJson     NVARCHAR(MAX)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    -- 1. UPSERT Document
    DECLARE @DocID INT;

    IF EXISTS (SELECT 1 FROM [schdl].[Document] WHERE DocumentName = @DocumentName)
        UPDATE [schdl].[Document]
        SET    ReportEndpoint = @ReportEndpoint, DefaultOutputFormat = @OutputFormat,
               DefaultLanguage = @Language, DefaultConfidentiality = @Confidentiality,
               ModifiedAt = SYSUTCDATETIME()
        WHERE  DocumentName = @DocumentName;
    ELSE
        INSERT INTO [schdl].[Document]
            (DocumentName,ReportEndpoint,DefaultOutputFormat,DefaultLanguage,DefaultConfidentiality)
        VALUES (@DocumentName,@ReportEndpoint,@OutputFormat,@Language,@Confidentiality);

    SELECT @DocID = ReportID FROM [schdl].[Document] WHERE DocumentName = @DocumentName;

    -- 2. UPSERT Parameters + Dispatch Config
    DECLARE
        @pName NVARCHAR(100), @pType NVARCHAR(50), @pRequired BIT,
        @pSort INT, @pDefault NVARCHAR(500), @pValue NVARCHAR(MAX),
        @pJson NVARCHAR(MAX),
        @pValueQuery NVARCHAR(MAX),
        @pVQ2 NVARCHAR(MAX),
        @pHasDispatch BIT,          @pIsPrimary BIT,
        @pMode NVARCHAR(12),
        @pEmailSrc NVARCHAR(20),    @pEmailSrcVal NVARCHAR(1000),
        @pDisplayNameSrc NVARCHAR(20),    @pDisplayNameSrcVal NVARCHAR(1000),
        @pFileNameSrc NVARCHAR(20),       @pFileNameSrcVal NVARCHAR(1000),
        @pFileNameTemplate NVARCHAR(500),
        @pFolderSrc NVARCHAR(20),         @pFolderSrcVal NVARCHAR(1000),
        @pParamID INT,
        @pIndex INT = 0, @pCount INT;

    SELECT @pCount = COUNT(*) FROM OPENJSON(@ParametersJson);

    WHILE @pIndex < @pCount
    BEGIN
        SET @pJson = JSON_QUERY(@ParametersJson,'$['+CAST(@pIndex AS NVARCHAR)+']');

        SET @pName        = JSON_VALUE(@pJson,'$.name');
        SET @pType        = ISNULL(JSON_VALUE(@pJson,'$.type'),'string');
        SET @pRequired    = ISNULL(TRY_CAST(JSON_VALUE(@pJson,'$.required') AS BIT),1);
        SET @pSort        = ISNULL(TRY_CAST(JSON_VALUE(@pJson,'$.sortOrder') AS INT),@pIndex+1);
        SET @pDefault     = JSON_VALUE(@pJson,'$.defaultValue');
        SET @pValue       = JSON_VALUE(@pJson,'$.value');
        SET @pValueQuery = JSON_VALUE(@pJson,'$.valueQuery');
        -- fanOut block on a parameter = per-entity fan-out config only
        -- delivery method and combined config are on the Schedule via @DispatchJson
        SET @pHasDispatch = CASE WHEN JSON_QUERY(@pJson,'$.fanOut') IS NOT NULL THEN 1 ELSE 0 END;
        SET @pIsPrimary         = ISNULL(TRY_CAST(JSON_VALUE(@pJson,'$.fanOut.isPrimary') AS BIT),0);
        SET @pMode              = ISNULL(JSON_VALUE(@pJson,'$.fanOut.mode'),'INDIVIDUAL');
        SET @pEmailSrc          = ISNULL(JSON_VALUE(@pJson,'$.fanOut.emailSource'),'STATIC');
        SET @pEmailSrcVal       = JSON_VALUE(@pJson,'$.fanOut.emailSourceValue');
        SET @pDisplayNameSrc    = JSON_VALUE(@pJson,'$.fanOut.displayNameSource');
        SET @pDisplayNameSrcVal = JSON_VALUE(@pJson,'$.fanOut.displayNameSourceValue');
        SET @pFileNameSrc       = JSON_VALUE(@pJson,'$.fanOut.fileNameSource');
        SET @pFileNameSrcVal    = JSON_VALUE(@pJson,'$.fanOut.fileNameSourceValue');
        SET @pFileNameTemplate  = JSON_VALUE(@pJson,'$.fanOut.fileNameTemplate');
        SET @pFolderSrc         = JSON_VALUE(@pJson,'$.fanOut.folderSource');
        SET @pFolderSrcVal      = JSON_VALUE(@pJson,'$.fanOut.folderSourceValue');

        IF EXISTS (SELECT 1 FROM [schdl].[DocumentParameter]
                   WHERE ReportID=@DocID AND ParameterName=@pName)
            UPDATE [schdl].[DocumentParameter]
            SET    DataType=@pType,IsRequired=@pRequired,DefaultValue=@pDefault,SortOrder=@pSort
            WHERE  ReportID=@DocID AND ParameterName=@pName;
        ELSE
            INSERT INTO [schdl].[DocumentParameter]
                (ReportID,ParameterName,DataType,IsRequired,DefaultValue,SortOrder)
            VALUES (@DocID,@pName,@pType,@pRequired,@pDefault,@pSort);

        SELECT @pParamID=ParameterID FROM [schdl].[DocumentParameter]
        WHERE  ReportID=@DocID AND ParameterName=@pName;

        -- If this parameter no longer has a dispatch block, remove any stale config
        IF @pHasDispatch=0
            DELETE FROM [schdl].[ParameterDispatchConfig] WHERE ParameterID=@pParamID;

        -- If this parameter no longer has a dispatch block, remove any stale config
        -- so old delivery method / mode settings don't carry forward on re-register
        IF @pHasDispatch=0
            DELETE FROM [schdl].[ParameterDispatchConfig] WHERE ParameterID=@pParamID;

        IF @pHasDispatch=1
        BEGIN
            IF EXISTS (SELECT 1 FROM [schdl].[ParameterDispatchConfig] WHERE ParameterID=@pParamID)
                UPDATE [schdl].[ParameterDispatchConfig]
                SET    IsPrimaryDispatchKey  = @pIsPrimary,
                       DispatchMode          = @pMode,
                       EmailSource           = @pEmailSrc,
                       EmailSourceValue      = @pEmailSrcVal,
                       DisplayNameSource     = @pDisplayNameSrc,
                       DisplayNameSourceValue= @pDisplayNameSrcVal,
                       FileNameSource        = @pFileNameSrc,
                       FileNameSourceValue   = @pFileNameSrcVal,
                       FileNameTemplate      = @pFileNameTemplate,
                       FolderSource          = @pFolderSrc,
                       FolderSourceValue     = @pFolderSrcVal
                WHERE  ParameterID=@pParamID;
            ELSE
                INSERT INTO [schdl].[ParameterDispatchConfig]
                    (ParameterID,IsPrimaryDispatchKey,DispatchMode,
                     EmailSource,EmailSourceValue,
                     DisplayNameSource,DisplayNameSourceValue,
                     FileNameSource,FileNameSourceValue,FileNameTemplate,
                     FolderSource,FolderSourceValue)
                VALUES(@pParamID,@pIsPrimary,@pMode,
                       @pEmailSrc,@pEmailSrcVal,
                       @pDisplayNameSrc,@pDisplayNameSrcVal,
                       @pFileNameSrc,@pFileNameSrcVal,@pFileNameTemplate,
                       @pFolderSrc,@pFolderSrcVal);
        END;

        SET @pIndex += 1;
    END;

    -- 3. UPSERT Schedule
    DECLARE @ScheduleID INT;
    SET @StartDate = ISNULL(@StartDate, CAST('2000-01-01' AS DATE));

    -- Parse @DispatchJson into schedule-level delivery variables
    DECLARE
        @sDeliveryMethod     NVARCHAR(10)   = ISNULL(JSON_VALUE(@DispatchJson,'$.deliveryMethod'),'EMAIL'),
        @sEmailSource        NVARCHAR(20)   = JSON_VALUE(@DispatchJson,'$.emailSource'),
        @sEmailSourceValue   NVARCHAR(1000) = JSON_VALUE(@DispatchJson,'$.emailSourceValue'),
        @sFileNameTemplate   NVARCHAR(500)  = JSON_VALUE(@DispatchJson,'$.fileNameTemplate'),
        @sFileNameSource     NVARCHAR(20)   = JSON_VALUE(@DispatchJson,'$.fileNameSource'),
        @sFileNameSourceValue NVARCHAR(1000)= JSON_VALUE(@DispatchJson,'$.fileNameSourceValue'),
        @sFolderSource       NVARCHAR(20)   = JSON_VALUE(@DispatchJson,'$.folderSource'),
        @sFolderSourceValue  NVARCHAR(1000) = JSON_VALUE(@DispatchJson,'$.folderSourceValue');

    IF EXISTS (SELECT 1 FROM [schdl].[Schedule] WHERE ScheduleName=@ScheduleName)
        UPDATE [schdl].[Schedule]
        SET    ReportID=@DocID,FrequencyType=@FrequencyType,RunTime=@RunTime,
               DayOfWeek=@DayOfWeek,DayOfMonth=@DayOfMonth,IntervalMinutes=@IntervalMinutes,
               WindowStart=@WindowStart,WindowEnd=@WindowEnd,StartDate=@StartDate,
               EndDate=@EndDate,Subject=@Subject,BodyTemplate=@BodyTemplate,
               DeliveryMethod=@sDeliveryMethod,
               EmailSource=@sEmailSource,EmailSourceValue=@sEmailSourceValue,
               FileNameTemplate=@sFileNameTemplate,FileNameSource=@sFileNameSource,
               FileNameSourceValue=@sFileNameSourceValue,
               FolderSource=@sFolderSource,FolderSourceValue=@sFolderSourceValue,
               NextRunAt=NULL,
               ModifiedAt=SYSUTCDATETIME()
        WHERE  ScheduleName=@ScheduleName;
    ELSE
        INSERT INTO [schdl].[Schedule]
            (ScheduleName,ReportID,FrequencyType,RunTime,DayOfWeek,DayOfMonth,
             IntervalMinutes,WindowStart,WindowEnd,StartDate,EndDate,Subject,BodyTemplate,
             DeliveryMethod,EmailSource,EmailSourceValue,
             FileNameTemplate,FileNameSource,FileNameSourceValue,
             FolderSource,FolderSourceValue)
        VALUES
            (@ScheduleName,@DocID,@FrequencyType,@RunTime,@DayOfWeek,@DayOfMonth,
             @IntervalMinutes,@WindowStart,@WindowEnd,@StartDate,@EndDate,@Subject,@BodyTemplate,
             @sDeliveryMethod,@sEmailSource,@sEmailSourceValue,
             @sFileNameTemplate,@sFileNameSource,@sFileNameSourceValue,
             @sFolderSource,@sFolderSourceValue);

    SELECT @ScheduleID=ScheduleID FROM [schdl].[Schedule] WHERE ScheduleName=@ScheduleName;

    -- 4. UPSERT Schedule Parameter Values
    SET @pIndex=0;
    WHILE @pIndex < @pCount
    BEGIN
        SET @pJson  = JSON_QUERY(@ParametersJson,'$['+CAST(@pIndex AS NVARCHAR)+']');
        SET @pName  = JSON_VALUE(@pJson,'$.name');
        SET @pValue = JSON_VALUE(@pJson,'$.value');

        IF @pValue IS NOT NULL
        BEGIN
            SELECT @pParamID=ParameterID FROM [schdl].[DocumentParameter]
            WHERE  ReportID=@DocID AND ParameterName=@pName;

            -- Re-read valueQuery from JSON in this second pass
            SET @pVQ2 = JSON_VALUE(
                JSON_QUERY(@ParametersJson,'$['+CAST(@pIndex AS NVARCHAR)+']'),
                '$.valueQuery');

            IF EXISTS (SELECT 1 FROM [schdl].[ScheduleParameter]
                       WHERE ScheduleID=@ScheduleID AND ParameterID=@pParamID)
                UPDATE [schdl].[ScheduleParameter]
                SET    ParameterValue      = @pValue,
                       ParameterValueQuery = @pVQ2
                WHERE  ScheduleID=@ScheduleID AND ParameterID=@pParamID;
            ELSE
                INSERT INTO [schdl].[ScheduleParameter]
                    (ScheduleID, ParameterID, ParameterValue, ParameterValueQuery)
                VALUES(@ScheduleID, @pParamID, @pValue, @pVQ2);
        END;
        SET @pIndex+=1;
    END;

    -- 5. UPSERT Static Recipients
    IF @RecipientsJson IS NOT NULL AND @RecipientsJson <> '[]'
    BEGIN
        DECLARE
            @rName NVARCHAR(255),@rEmail NVARCHAR(320),@rRole NVARCHAR(10),
            @rID INT,@rIndex INT=0,@rCount INT,
            @rJson NVARCHAR(MAX);

        SELECT @rCount=COUNT(*) FROM OPENJSON(@RecipientsJson);

        WHILE @rIndex < @rCount
        BEGIN
            SET @rJson =
                JSON_QUERY(@RecipientsJson,'$['+CAST(@rIndex AS NVARCHAR)+']');
            SET @rName  = JSON_VALUE(@rJson,'$.name');
            SET @rEmail = JSON_VALUE(@rJson,'$.email');
            SET @rRole  = ISNULL(JSON_VALUE(@rJson,'$.role'),'TO');

            IF EXISTS (SELECT 1 FROM [schdl].[Recipient] WHERE EmailAddress=@rEmail)
                SELECT @rID=RecipientID FROM [schdl].[Recipient] WHERE EmailAddress=@rEmail;
            ELSE
            BEGIN
                INSERT INTO [schdl].[Recipient](RecipientName,EmailAddress) VALUES(@rName,@rEmail);
                SET @rID=SCOPE_IDENTITY();
            END;

            IF NOT EXISTS (SELECT 1 FROM [schdl].[ScheduleRecipient]
                           WHERE ScheduleID=@ScheduleID AND RecipientID=@rID AND RecipientRole=@rRole)
                INSERT INTO [schdl].[ScheduleRecipient](ScheduleID,RecipientID,RecipientRole)
                VALUES(@ScheduleID,@rID,@rRole);

            SET @rIndex+=1;
        END;
    END;

    COMMIT TRANSACTION;

    -- Return summary
    SELECT
        d.ReportID, d.DocumentName, d.ReportEndpoint,
        s.ScheduleID, s.ScheduleName, s.FrequencyType,
        s.RunTime, s.DayOfWeek, s.DayOfMonth, s.IntervalMinutes, s.NextRunAt,
        (SELECT COUNT(*) FROM [schdl].[ScheduleParameter]  WHERE ScheduleID=s.ScheduleID) AS ParameterCount,
        (SELECT COUNT(*) FROM [schdl].[ScheduleRecipient]  WHERE ScheduleID=s.ScheduleID) AS RecipientCount,
        (SELECT COUNT(*) FROM [schdl].[ParameterDispatchConfig] dc
            JOIN [schdl].[DocumentParameter] dp ON dp.ParameterID=dc.ParameterID
         WHERE dp.ReportID=d.ReportID)                                                 AS DispatchConfigCount,
        [schdl].[fn_FetchDocumentId](d.DocumentName)                                    AS ResolvedDocumentId
    FROM [schdl].[Document] d
    JOIN [schdl].[Schedule] s ON s.ReportID=d.ReportID
    WHERE d.DocumentName=@DocumentName AND s.ScheduleName=@ScheduleName;
END;
GO

-- ============================================================
--  SECTION 4  EXECUTION ENGINE
-- ============================================================

-- 4.1  usp_BuildDispatchQueue
--  Internal. Called by usp_GetDueSchedules per due schedule.
--  Builds DispatchQueue rows: one per email to send.
CREATE PROCEDURE [schdl].[usp_BuildDispatchQueue]
    @ScheduleID INT,
    @LogID      BIGINT,
    @AsOf       DATETIME2 = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(ISNULL(@AsOf,SYSUTCDATETIME()) AS DATE);

    DECLARE
        @DocID INT, @DocumentName NVARCHAR(255),
        @OutputFormat NVARCHAR(20), @Language INT,
        @Confidentiality NVARCHAR(50),
        @EmailSubject NVARCHAR(500), @EmailBody NVARCHAR(MAX),
        -- Schedule-level delivery config (from @DispatchJson at register time)
        @sDeliveryMethod      NVARCHAR(10),
        @sEmailSource         NVARCHAR(20),
        @sEmailSourceValue    NVARCHAR(1000),
        @sFileNameTemplate    NVARCHAR(500),
        @sFileNameSource      NVARCHAR(20),
        @sFileNameSourceValue NVARCHAR(1000),
        @sFolderSource        NVARCHAR(20),
        @sFolderSourceValue   NVARCHAR(1000);

    SELECT
        @DocID                = d.ReportID,
        @DocumentName         = d.DocumentName,
        @OutputFormat         = d.DefaultOutputFormat,
        @Language             = d.DefaultLanguage,
        @Confidentiality      = d.DefaultConfidentiality,
        @EmailSubject         = s.Subject,
        @EmailBody            = s.BodyTemplate,
        @sDeliveryMethod      = ISNULL(s.DeliveryMethod, 'EMAIL'),
        @sEmailSource         = s.EmailSource,
        @sEmailSourceValue    = s.EmailSourceValue,
        @sFileNameTemplate    = s.FileNameTemplate,
        @sFileNameSource      = s.FileNameSource,
        @sFileNameSourceValue = s.FileNameSourceValue,
        @sFolderSource        = s.FolderSource,
        @sFolderSourceValue   = s.FolderSourceValue
    FROM [schdl].[Schedule] s
    JOIN [schdl].[Document] d ON d.ReportID=s.ReportID
    WHERE s.ScheduleID=@ScheduleID;

    -- Resolve {{REPORTNAME}} in Subject and BodyTemplate first.
    -- This is not a date token — it resolves to the DocumentName.
    IF @EmailSubject  LIKE '%{{REPORTNAME}}%'
        SET @EmailSubject  = REPLACE(@EmailSubject,  '{{REPORTNAME}}', @DocumentName);
    IF @EmailBody LIKE '%{{REPORTNAME}}%'
        SET @EmailBody = REPLACE(@EmailBody, '{{REPORTNAME}}', @DocumentName);

    -- Resolve date tokens in Subject and BodyTemplate.
    -- Iterates every active token and replaces any occurrence in the strings.
    -- Only tokens that actually appear are touched; others are skipped cheaply.
    DECLARE @tkToken NVARCHAR(100), @tkResolved NVARCHAR(500);

    DECLARE tk CURSOR LOCAL FAST_FORWARD FOR
        SELECT Token,
               [schdl].[fn_ResolveDateToken](Token, @Today)
        FROM   [schdl].[DateToken]
        WHERE  IsActive = 1;

    OPEN tk; FETCH NEXT FROM tk INTO @tkToken, @tkResolved;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @EmailSubject LIKE '%' + @tkToken + '%'
            SET @EmailSubject = REPLACE(@EmailSubject, @tkToken, @tkResolved);
        IF @EmailBody LIKE '%' + @tkToken + '%'
            SET @EmailBody = REPLACE(@EmailBody, @tkToken, @tkResolved);
        FETCH NEXT FROM tk INTO @tkToken, @tkResolved;
    END;
    CLOSE tk; DEALLOCATE tk;

    -- Resolve documentId live
    DECLARE @ResolvedDocId NVARCHAR(100) = [schdl].[fn_FetchDocumentId](@DocumentName);

    -- Step 1: Shred each parameter's pipe-delimited value into individual token segments,
    --         resolve each segment, then re-aggregate back to a pipe-delimited string.
    --         Done in a separate temp table to avoid nested aggregate errors.
    -- Resolve dynamic parameter values where ParameterValueQuery is set.
    -- Execute each query and collect results as a pipe-delimited string,
    -- then use that in place of the static ParameterValue.
    DROP TABLE IF EXISTS #DynVals;
    CREATE TABLE #DynVals (
        ParameterID     INT           NOT NULL,
        ResolvedValue   NVARCHAR(MAX) NOT NULL
    );

    DECLARE
        @dvParamID  INT,
        @dvQuery    NVARCHAR(MAX),
        @dvStatic   NVARCHAR(MAX),
        @dvResult   NVARCHAR(MAX),
        @aggSQL     NVARCHAR(MAX);

    DECLARE dv_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT sp.ParameterID, sp.ParameterValueQuery, sp.ParameterValue
        FROM   [schdl].[ScheduleParameter] sp
        WHERE  sp.ScheduleID          = @ScheduleID
          AND  sp.ParameterValueQuery IS NOT NULL
          AND  LTRIM(RTRIM(sp.ParameterValueQuery)) <> '';

    OPEN dv_cur; FETCH NEXT FROM dv_cur INTO @dvParamID, @dvQuery, @dvStatic;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @dvResult = NULL;

        -- Execute the query and aggregate results into a pipe-delimited string
        SET @aggSQL =
            N'SELECT @r = STRING_AGG([Value], ''|'') FROM (' + @dvQuery + N') AS _q';

        BEGIN TRY
            EXEC sp_executesql @aggSQL,
                N'@r NVARCHAR(MAX) OUTPUT',
                @r = @dvResult OUTPUT;
        END TRY
        BEGIN CATCH
            -- If query fails, fall back to static value and log the error
            SET @dvResult = @dvStatic;
            INSERT INTO [schdl].[ExecutionLog] (ScheduleID, Status, ErrorMessage)
            VALUES (@ScheduleID, 'SKIPPED',
                'ParameterValueQuery failed for ParameterID ' + CAST(@dvParamID AS NVARCHAR)
                + ': ' + ERROR_MESSAGE());
        END CATCH;

        INSERT INTO #DynVals (ParameterID, ResolvedValue)
        VALUES (@dvParamID, ISNULL(@dvResult, @dvStatic));

        FETCH NEXT FROM dv_cur INTO @dvParamID, @dvQuery, @dvStatic;
    END;
    CLOSE dv_cur; DEALLOCATE dv_cur;

    -- Pre-join #DynVals so the resolved value is available before CROSS APPLY.
    -- STRING_SPLIT cannot reference a column from a later JOIN —
    -- the value must be determined before the APPLY executes.
    DROP TABLE IF EXISTS #Raw;
    SELECT
        dp.ParameterID,
        dp.ParameterName,
        dp.DataType,
        dp.IsRequired,
        dp.SortOrder,
        ISNULL(dc.IsPrimaryDispatchKey, 0)      AS IsPrimary,
        ISNULL(dc.DispatchMode,   'INDIVIDUAL') AS DispatchMode,
        ISNULL(dc.EmailSource,    'STATIC')     AS EmailSource,
        dc.EmailSourceValue,
        dc.DisplayNameSource,
        dc.DisplayNameSourceValue,
        dc.FileNameSource,
        dc.FileNameSourceValue,
        dc.FileNameTemplate,
        dc.FolderSource,
        dc.FolderSourceValue,
        CASE
            WHEN dp.DataType = 'date'
            THEN [schdl].[fn_ResolveDateToken](TRIM(seg.value), @Today)
            ELSE TRIM(seg.value)
        END                                                     AS ResolvedSegment
    INTO #Raw
    FROM   [schdl].[ScheduleParameter]            sp
    JOIN   [schdl].[DocumentParameter]            dp  ON dp.ParameterID  = sp.ParameterID
    LEFT   JOIN [schdl].[ParameterDispatchConfig]  dc ON dc.ParameterID  = dp.ParameterID
    -- Resolve the effective value (dynamic overrides static) BEFORE STRING_SPLIT
    CROSS  APPLY (
        SELECT ISNULL(dv.ResolvedValue, sp.ParameterValue) AS EffectiveValue
        FROM   (SELECT NULL AS _) AS _dummy
        LEFT   JOIN #DynVals dv ON dv.ParameterID = sp.ParameterID
    ) ev
    CROSS  APPLY STRING_SPLIT(ev.EffectiveValue, '|') seg
    WHERE  sp.ScheduleID = @ScheduleID;

    DROP TABLE IF EXISTS #DynVals;

    -- Step 2: Re-aggregate resolved segments back into one pipe-delimited ResolvedValue per parameter
    DROP TABLE IF EXISTS #P;
    SELECT
        ParameterID,
        ParameterName,
        DataType,
        IsRequired,
        SortOrder,
        IsPrimary,
        DispatchMode,
        EmailSource,
        EmailSourceValue,
        DisplayNameSource,
        DisplayNameSourceValue,
        FileNameSource,
        FileNameSourceValue,
        FileNameTemplate,
        FolderSource,
        FolderSourceValue,
        STRING_AGG(ResolvedSegment, '|') WITHIN GROUP (ORDER BY ResolvedSegment) AS ResolvedValue
    INTO #P
    FROM  #Raw
    GROUP BY ParameterID, ParameterName, DataType, IsRequired, SortOrder,
             IsPrimary, DispatchMode,
             EmailSource, EmailSourceValue,
             DisplayNameSource, DisplayNameSourceValue,
             FileNameSource, FileNameSourceValue, FileNameTemplate,
             FolderSource, FolderSourceValue;

    DROP TABLE IF EXISTS #Raw;

    -- ── Schedule-level CC / BCC (needed in both branches below) ──
    DECLARE @Cc NVARCHAR(MAX) = (
        SELECT STRING_AGG(r.EmailAddress, ',') WITHIN GROUP (ORDER BY r.EmailAddress)
        FROM   [schdl].[ScheduleRecipient] sr
        JOIN   [schdl].[Recipient]         r  ON r.RecipientID = sr.RecipientID
        WHERE  sr.ScheduleID   = @ScheduleID
          AND  sr.RecipientRole = 'CC'
          AND  r.IsActive       = 1);

    DECLARE @Bcc NVARCHAR(MAX) = (
        SELECT STRING_AGG(r.EmailAddress, ',') WITHIN GROUP (ORDER BY r.EmailAddress)
        FROM   [schdl].[ScheduleRecipient] sr
        JOIN   [schdl].[Recipient]         r  ON r.RecipientID = sr.RecipientID
        WHERE  sr.ScheduleID   = @ScheduleID
          AND  sr.RecipientRole = 'BCC'
          AND  r.IsActive       = 1);

    -- ── NO PARAMETERS — emit one BULK row with parameters:[] ─────
    IF NOT EXISTS (SELECT 1 FROM #P)
    BEGIN
        DECLARE
            @npTo       NVARCHAR(MAX),
            @npFolder   NVARCHAR(1000),
            @npFileName NVARCHAR(500),
            @npTok      NVARCHAR(100),
            @npRes      NVARCHAR(500),
            @npLvSQL    NVARCHAR(600),
            @npSfSQL    NVARCHAR(600),
            @npDynSQL   NVARCHAR(2000);

        -- Resolve combined email TO from Schedule delivery config
        IF @sDeliveryMethod IN ('EMAIL','BOTH')
        BEGIN
            IF @sEmailSource = 'STATIC'
                SET @npTo = @sEmailSourceValue;
            ELSE IF @sEmailSource = 'LOOKUP_VIEW'
            BEGIN
                SET @npLvSQL = N'SELECT TOP 1 @e = EmailAddress FROM '
                    + @sEmailSourceValue + N' WHERE LookupKey = @v';
                EXEC sp_executesql @npLvSQL,
                    N'@v NVARCHAR(500), @e NVARCHAR(MAX) OUTPUT',
                    @v = @DocumentName, @e = @npTo OUTPUT;
            END
            ELSE IF @sEmailSource = 'SCALAR_FN'
            BEGIN
                SET @npSfSQL = N'SELECT @e = ' + @sEmailSourceValue + N'(@v)';
                EXEC sp_executesql @npSfSQL,
                    N'@v NVARCHAR(500), @e NVARCHAR(MAX) OUTPUT',
                    @v = @DocumentName, @e = @npTo OUTPUT;
            END
            ELSE IF @sEmailSource = 'DYNAMIC_SQL'
            BEGIN
                SET @npDynSQL = N'SELECT TOP 1 @e = EmailAddress FROM ('
                    + @sEmailSourceValue + N') AS _q';
                EXEC sp_executesql @npDynSQL,
                    N'@e NVARCHAR(MAX) OUTPUT', @e = @npTo OUTPUT;
            END;
            -- Append static TO recipients from ScheduleRecipient
            SELECT @npTo = ISNULL(NULLIF(@npTo,'') + ',', '')
                + ISNULL(STRING_AGG(r.EmailAddress, ','),'')
            FROM   [schdl].[ScheduleRecipient] sr
            JOIN   [schdl].[Recipient] r ON r.RecipientID = sr.RecipientID
            WHERE  sr.ScheduleID = @ScheduleID AND sr.RecipientRole = 'TO' AND r.IsActive = 1;
        END;

        -- Resolve folder path from Schedule delivery config
        IF @sDeliveryMethod IN ('FOLDER','BOTH')
        BEGIN
            IF @sFolderSource = 'STATIC'
                SET @npFolder = @sFolderSourceValue;
            ELSE IF @sFolderSource = 'LOOKUP_VIEW'
            BEGIN
                SET @npLvSQL = N'SELECT TOP 1 @e = FolderPath FROM '
                    + @sFolderSourceValue + N' WHERE LookupKey = @v';
                EXEC sp_executesql @npLvSQL,
                    N'@v NVARCHAR(500), @e NVARCHAR(1000) OUTPUT',
                    @v = @DocumentName, @e = @npFolder OUTPUT;
            END
            ELSE IF @sFolderSource = 'SCALAR_FN'
            BEGIN
                SET @npSfSQL = N'SELECT @e = ' + @sFolderSourceValue + N'(@v)';
                EXEC sp_executesql @npSfSQL,
                    N'@v NVARCHAR(500), @e NVARCHAR(1000) OUTPUT',
                    @v = @DocumentName, @e = @npFolder OUTPUT;
            END
            ELSE IF @sFolderSource = 'DYNAMIC_SQL'
            BEGIN
                SET @npDynSQL = N'SELECT TOP 1 @e = FolderPath FROM ('
                    + @sFolderSourceValue + N') AS _q';
                EXEC sp_executesql @npDynSQL,
                    N'@e NVARCHAR(1000) OUTPUT', @e = @npFolder OUTPUT;
            END;
        END;

        -- Resolve filename from Schedule delivery config (template takes priority over source)
        IF @sFileNameTemplate IS NOT NULL
        BEGIN
            SET @npFileName = @sFileNameTemplate;
            SET @npFileName = REPLACE(@npFileName, '{{REPORTNAME}}', @DocumentName);
            SET @npFileName = REPLACE(@npFileName, '{{DISPLAYNAME}}', '');
            DECLARE npt CURSOR LOCAL FAST_FORWARD FOR
                SELECT Token, [schdl].[fn_ResolveDateToken](Token, @Today)
                FROM   [schdl].[DateToken] WHERE IsActive = 1;
            OPEN npt; FETCH NEXT FROM npt INTO @npTok, @npRes;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @npFileName LIKE '%' + @npTok + '%'
                    SET @npFileName = REPLACE(@npFileName, @npTok, @npRes);
                FETCH NEXT FROM npt INTO @npTok, @npRes;
            END;
            CLOSE npt; DEALLOCATE npt;
        END
        ELSE IF @sFileNameSource = 'STATIC'
            SET @npFileName = @sFileNameSourceValue;

        DECLARE @npReqJson NVARCHAR(MAX) =
            '{"documentId":"'    + ISNULL(@ResolvedDocId,'') +
            '","outputFormat":"' + @OutputFormat +
            '","language":'      + CAST(@Language AS NVARCHAR) +
            ',"parameters":[]'   +
            ',"confidentiality":"' + @Confidentiality + '"}';

        INSERT INTO [schdl].[DispatchQueue]
            (LogID,ScheduleID,DispatchType,DeliveryMethod,DispatchKeyValue,
             DisplayName,FileName,RequestJson,
             ToAddresses,CcAddresses,BccAddresses,EmailSubject,EmailBody,
             FolderPath)
        VALUES
            (@LogID,@ScheduleID,'COMBINED',@sDeliveryMethod,NULL,
             NULL,@npFileName,@npReqJson,
             ISNULL(@npTo,''),@Cc,@Bcc,@EmailSubject,@EmailBody,
             @npFolder);

        RETURN;  -- nothing more to do
    END;

    -- ── HAS PARAMETERS — normal fan-out path ─────────────────────

    -- Identify primary dispatch parameter
    DECLARE
        @PrimID         INT,              @PrimName       NVARCHAR(100),
        @PrimMode       NVARCHAR(12),
        @PrimEmailSrc   NVARCHAR(20),     @PrimEmailSrcVal NVARCHAR(1000),
        @PrimDNSrc      NVARCHAR(20),     @PrimDNSrcVal   NVARCHAR(1000),
        @PrimFNSrc      NVARCHAR(20),     @PrimFNSrcVal   NVARCHAR(1000),
        @PrimFNTemplate NVARCHAR(500),
        @PrimFolderSrc  NVARCHAR(20),     @PrimFolderSrcVal NVARCHAR(1000);

    -- Delivery method and combined config come from Schedule, not ParameterDispatchConfig
    -- @sDeliveryMethod, @sEmailSource, @sFolderSource etc already loaded above

    SELECT TOP 1
        @PrimID          = ParameterID,     @PrimName        = ParameterName,
        @PrimMode        = DispatchMode,
        @PrimEmailSrc    = EmailSource,     @PrimEmailSrcVal = EmailSourceValue,
        @PrimDNSrc       = DisplayNameSource, @PrimDNSrcVal  = DisplayNameSourceValue,
        @PrimFNSrc       = FileNameSource,  @PrimFNSrcVal    = FileNameSourceValue,
        @PrimFNTemplate  = FileNameTemplate,
        @PrimFolderSrc   = FolderSource,    @PrimFolderSrcVal = FolderSourceValue
    FROM #P WHERE IsPrimary=1;

    -- Default: first parameter if no explicit primary
    IF @PrimID IS NULL
        SELECT TOP 1
            @PrimID=ParameterID, @PrimName=ParameterName,
            @PrimMode='INDIVIDUAL'
        FROM #P ORDER BY SortOrder;

    -- Individual dispatch values (one row per pipe segment of the primary parameter)
    DROP TABLE IF EXISTS #PV;
    SELECT TRIM(value) AS DispatchValue
    INTO   #PV
    FROM   #P
    CROSS  APPLY STRING_SPLIT(ResolvedValue, '|')
    WHERE  ParameterID = @PrimID;

    -- Step 3: Pre-build the JSON values array for each non-primary parameter.
    --         STRING_AGG is kept flat (no bracket wrapping inside it) to satisfy
    --         the SQL Server rule against aggregates containing expressions with
    --         aggregates. The brackets are applied via UPDATE after the INSERT.
    DROP TABLE IF EXISTS #NP;
    SELECT
        p.ParameterID,
        p.ParameterName,
        p.DataType,
        p.IsRequired,
        p.SortOrder,
        p.ResolvedValue,
        STRING_AGG('"' + STRING_ESCAPE(TRIM(seg.value), 'json') + '"', ',')
            WITHIN GROUP (ORDER BY seg.value)             AS ValuesJson
    INTO #NP
    FROM   #P                                           p
    CROSS  APPLY STRING_SPLIT(p.ResolvedValue, '|')    seg
    WHERE  p.ParameterID <> @PrimID
    GROUP BY p.ParameterID, p.ParameterName, p.DataType,
             p.IsRequired, p.SortOrder, p.ResolvedValue;

    -- Wrap with [ ] now that we are outside the aggregate expression
    UPDATE #NP SET ValuesJson = '[' + ValuesJson + ']';

    -- Step 4: Build the non-primary parameter JSON array from #NP
    DECLARE @NonPrimArray NVARCHAR(MAX);
    SELECT @NonPrimArray = STRING_AGG(
        '{"name":"'   + STRING_ESCAPE(ParameterName, 'json') +
        '","type":"'  + DataType +
        '","values":' + ValuesJson +
        ',"multiple":'+ CASE WHEN ResolvedValue LIKE '%|%' THEN 'true' ELSE 'false' END +
        ',"required":'+ CASE WHEN IsRequired = 1 THEN 'true' ELSE 'false' END + '}',
        ','
    ) WITHIN GROUP (ORDER BY SortOrder)
    FROM #NP;

    DROP TABLE IF EXISTS #NP;

    -- INDIVIDUAL rows
    IF @PrimMode IN ('INDIVIDUAL','BOTH')
    BEGIN
        DECLARE
            @iVal          NVARCHAR(500),
            @iEmail        NVARCHAR(320),
            @iDisplayName  NVARCHAR(500),
            @iFileName     NVARCHAR(500),
            @iFolderPath   NVARCHAR(1000),
            @iSafeVal      NVARCHAR(500),
            @iDynSQL       NVARCHAR(2000),
            @iPrimJson     NVARCHAR(MAX),
            @iReqJson      NVARCHAR(MAX),
            @lvEmailSQL    NVARCHAR(600),
            @sfEmailSQL    NVARCHAR(600),
            @lvDNSQL       NVARCHAR(600),
            @sfDNSQL       NVARCHAR(600),
            @lvFNSQL       NVARCHAR(600),
            @sfFNSQL       NVARCHAR(600),
            @lvFolSQL      NVARCHAR(600),
            @sfFolSQL      NVARCHAR(600),
            @fnTok         NVARCHAR(100),
            @fnRes         NVARCHAR(500);

        DECLARE ic CURSOR LOCAL FAST_FORWARD FOR SELECT DispatchValue FROM #PV;
        OPEN ic; FETCH NEXT FROM ic INTO @iVal;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @iSafeVal = REPLACE(@iVal, N'''', N'''''');

            -- ── Resolve Email ───────────────────────────────────────
            SET @iEmail = NULL;
            IF @sDeliveryMethod IN ('EMAIL','BOTH')
            BEGIN
                IF @PrimEmailSrc = 'STATIC'
                    SET @iEmail = @PrimEmailSrcVal;
                ELSE IF @PrimEmailSrc = 'LOOKUP_VIEW'
                BEGIN
                    SET @lvEmailSQL =
                        N'SELECT TOP 1 @e = EmailAddress FROM '
                        + @PrimEmailSrcVal + N' WHERE LookupKey = @v';
                    EXEC sp_executesql @lvEmailSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(320) OUTPUT',
                        @v=@iVal, @e=@iEmail OUTPUT;
                END
                ELSE IF @PrimEmailSrc = 'SCALAR_FN'
                BEGIN
                    SET @sfEmailSQL =
                        N'SELECT @e = ' + @PrimEmailSrcVal + N'(@v)';
                    EXEC sp_executesql @sfEmailSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(320) OUTPUT',
                        @v=@iVal, @e=@iEmail OUTPUT;
                END
                ELSE IF @PrimEmailSrc = 'DYNAMIC_SQL'
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = EmailAddress FROM ('
                        + REPLACE(@PrimEmailSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL,
                        N'@e NVARCHAR(320) OUTPUT', @e=@iEmail OUTPUT;
                END;
            END;

            -- ── Resolve DisplayName ─────────────────────────────────
            SET @iDisplayName = NULL;
            IF @PrimDNSrc IS NOT NULL
            BEGIN
                IF @PrimDNSrc = 'STATIC'
                    SET @iDisplayName = @PrimDNSrcVal;
                ELSE IF @PrimDNSrc = 'LOOKUP_VIEW'
                BEGIN
                    SET @lvDNSQL =
                        N'SELECT TOP 1 @e = DisplayName FROM '
                        + @PrimDNSrcVal + N' WHERE LookupKey = @v';
                    EXEC sp_executesql @lvDNSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(500) OUTPUT',
                        @v=@iVal, @e=@iDisplayName OUTPUT;
                END
                ELSE IF @PrimDNSrc = 'SCALAR_FN'
                BEGIN
                    SET @sfDNSQL =
                        N'SELECT @e = ' + @PrimDNSrcVal + N'(@v)';
                    EXEC sp_executesql @sfDNSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(500) OUTPUT',
                        @v=@iVal, @e=@iDisplayName OUTPUT;
                END
                ELSE IF @PrimDNSrc = 'DYNAMIC_SQL'
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = DisplayName FROM ('
                        + REPLACE(@PrimDNSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL,
                        N'@e NVARCHAR(500) OUTPUT', @e=@iDisplayName OUTPUT;
                END;
            END;

            -- ── Resolve FileName ────────────────────────────────────
            -- Priority: FileNameTemplate (with {{DISPLAYNAME}} + {{TOKEN}} substitution)
            --           → FileNameSource resolver
            --           → NULL (Flowgear uses API default)
            SET @iFileName = NULL;
            IF @PrimFNTemplate IS NOT NULL
            BEGIN
                SET @iFileName = @PrimFNTemplate;
                -- Replace {{REPORTNAME}} with DocumentName
                IF @iFileName LIKE '%{{REPORTNAME}}%'
                    SET @iFileName = REPLACE(@iFileName, '{{REPORTNAME}}', @DocumentName);
                -- Replace {{DISPLAYNAME}} with resolved display name
                IF @iDisplayName IS NOT NULL
                    SET @iFileName = REPLACE(@iFileName, '{{DISPLAYNAME}}', @iDisplayName);
                -- Replace any {{TOKEN}} in the template
                -- @fnTok, @fnRes declared above
                DECLARE fnt CURSOR LOCAL FAST_FORWARD FOR
                    SELECT Token, [schdl].[fn_ResolveDateToken](Token, @Today)
                    FROM   [schdl].[DateToken] WHERE IsActive = 1;
                OPEN fnt; FETCH NEXT FROM fnt INTO @fnTok, @fnRes;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    IF @iFileName LIKE '%' + @fnTok + '%'
                        SET @iFileName = REPLACE(@iFileName, @fnTok, @fnRes);
                    FETCH NEXT FROM fnt INTO @fnTok, @fnRes;
                END;
                CLOSE fnt; DEALLOCATE fnt;
            END
            ELSE IF @PrimFNSrc IS NOT NULL
            BEGIN
                IF @PrimFNSrc = 'STATIC'
                    SET @iFileName = @PrimFNSrcVal;
                ELSE IF @PrimFNSrc = 'LOOKUP_VIEW'
                BEGIN
                    SET @lvFNSQL =
                        N'SELECT TOP 1 @e = FileName FROM '
                        + @PrimFNSrcVal + N' WHERE LookupKey = @v';
                    EXEC sp_executesql @lvFNSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(500) OUTPUT',
                        @v=@iVal, @e=@iFileName OUTPUT;
                END
                ELSE IF @PrimFNSrc = 'SCALAR_FN'
                BEGIN
                    SET @sfFNSQL =
                        N'SELECT @e = ' + @PrimFNSrcVal + N'(@v)';
                    EXEC sp_executesql @sfFNSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(500) OUTPUT',
                        @v=@iVal, @e=@iFileName OUTPUT;
                END
                ELSE IF @PrimFNSrc = 'DYNAMIC_SQL'
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = FileName FROM ('
                        + REPLACE(@PrimFNSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL,
                        N'@e NVARCHAR(500) OUTPUT', @e=@iFileName OUTPUT;
                END;
            END;

            -- ── Resolve FolderPath ──────────────────────────────────
            SET @iFolderPath = NULL;
            IF @sDeliveryMethod IN ('FOLDER','BOTH') AND @PrimFolderSrc IS NOT NULL
            BEGIN
                IF @PrimFolderSrc = 'STATIC'
                    SET @iFolderPath = @PrimFolderSrcVal;
                ELSE IF @PrimFolderSrc = 'LOOKUP_VIEW'
                BEGIN
                    SET @lvFolSQL =
                        N'SELECT TOP 1 @e = FolderPath FROM '
                        + @PrimFolderSrcVal + N' WHERE LookupKey = @v';
                    EXEC sp_executesql @lvFolSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(1000) OUTPUT',
                        @v=@iVal, @e=@iFolderPath OUTPUT;
                END
                ELSE IF @PrimFolderSrc = 'SCALAR_FN'
                BEGIN
                    SET @sfFolSQL =
                        N'SELECT @e = ' + @PrimFolderSrcVal + N'(@v)';
                    EXEC sp_executesql @sfFolSQL,
                        N'@v NVARCHAR(500), @e NVARCHAR(1000) OUTPUT',
                        @v=@iVal, @e=@iFolderPath OUTPUT;
                END
                ELSE IF @PrimFolderSrc = 'DYNAMIC_SQL'
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = FolderPath FROM ('
                        + REPLACE(@PrimFolderSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL,
                        N'@e NVARCHAR(1000) OUTPUT', @e=@iFolderPath OUTPUT;
                END;
            END;

            -- ── Build RequestJson and insert ────────────────────────
            SET @iPrimJson =
                '{"name":"'  + STRING_ESCAPE(@PrimName,'json') +
                '","type":"string","values":["' + STRING_ESCAPE(@iVal,'json') +
                '"],"multiple":false,"required":true}';

            SET @iReqJson =
                '{"documentId":"'    + ISNULL(@ResolvedDocId,'') +
                '","outputFormat":"' + @OutputFormat +
                '","language":'      + CAST(@Language AS NVARCHAR) +
                ',"parameters":['    + @iPrimJson + ISNULL(',' + @NonPrimArray,'') +
                '],"confidentiality":"' + @Confidentiality + '"}';

            INSERT INTO [schdl].[DispatchQueue]
                (LogID,ScheduleID,DispatchType,DeliveryMethod,DispatchKeyValue,
                 DisplayName,FileName,RequestJson,
                 ToAddresses,CcAddresses,BccAddresses,EmailSubject,EmailBody,
                 FolderPath)
            VALUES
                (@LogID,@ScheduleID,'INDIVIDUAL',@sDeliveryMethod,@iVal,
                 @iDisplayName,@iFileName,@iReqJson,
                 ISNULL(@iEmail,''),@Cc,@Bcc,@EmailSubject,@EmailBody,
                 @iFolderPath);

            FETCH NEXT FROM ic INTO @iVal;
        END;
        CLOSE ic; DEALLOCATE ic;
    END;

    -- BULK row
    IF @PrimMode IN ('COMBINED','BOTH')
    BEGIN
        DECLARE @bVals      NVARCHAR(MAX),
                @bPrimJson  NVARCHAR(MAX),
                @bReqJson   NVARCHAR(MAX),
                @bTo        NVARCHAR(MAX),
                @bFileName  NVARCHAR(500),
                @bFolder    NVARCHAR(1000),
                @bsTok      NVARCHAR(100),
                @bsRes      NVARCHAR(500),
                @bfTok      NVARCHAR(100),
                @bfRes      NVARCHAR(500),
                @lvBulkSQL  NVARCHAR(600),
                @sfBulkSQL  NVARCHAR(600),
                @dyBulkSQL  NVARCHAR(2000),
                @lvBFolSQL  NVARCHAR(600),
                @sfBFolSQL  NVARCHAR(600),
                @dyBFolSQL  NVARCHAR(2000);

        -- Build the JSON values array from all dispatch values
        SELECT @bVals = '[' + STRING_AGG('"' + STRING_ESCAPE(DispatchValue,'json') + '"', ',') + ']'
        FROM   #PV;

        SET @bPrimJson =
            '{"name":"'   + STRING_ESCAPE(@PrimName,'json') +
            '","type":"string","values":' + @bVals +
            ',"multiple":true,"required":true}';

        SET @bReqJson =
            '{"documentId":"'    + ISNULL(@ResolvedDocId,'') +
            '","outputFormat":"' + @OutputFormat +
            '","language":'      + CAST(@Language AS NVARCHAR) +
            ',"parameters":['    + @bPrimJson + ISNULL(',' + @NonPrimArray,'') +
            '],"confidentiality":"' + @Confidentiality + '"}';

        -- Resolve combined/bulk email TO from Schedule delivery config
        SET @bTo = NULL;
        IF @sEmailSource = 'STATIC'
            SET @bTo = @sEmailSourceValue;
        ELSE IF @sEmailSource = 'LOOKUP_VIEW'
        BEGIN
            SET @lvBulkSQL = N'SELECT TOP 1 @e = EmailAddress FROM '
                + @sEmailSourceValue + N' WHERE LookupKey = @v';
            EXEC sp_executesql @lvBulkSQL, N'@v NVARCHAR(500), @e NVARCHAR(320) OUTPUT',
                @v = @DocumentName, @e = @bTo OUTPUT;
        END
        ELSE IF @sEmailSource = 'SCALAR_FN'
        BEGIN
            SET @sfBulkSQL = N'SELECT @e = ' + @sEmailSourceValue + N'(@v)';
            EXEC sp_executesql @sfBulkSQL, N'@v NVARCHAR(500), @e NVARCHAR(320) OUTPUT',
                @v = @DocumentName, @e = @bTo OUTPUT;
        END
        ELSE IF @sEmailSource = 'DYNAMIC_SQL'
        BEGIN
            SET @dyBulkSQL = N'SELECT TOP 1 @e = EmailAddress FROM ('
                + @sEmailSourceValue + N') AS _q';
            EXEC sp_executesql @dyBulkSQL, N'@e NVARCHAR(320) OUTPUT', @e = @bTo OUTPUT;
        END;
        -- Also append static TO recipients from ScheduleRecipient
        SELECT @bTo = ISNULL(NULLIF(@bTo,'') + ',', '')
            + ISNULL(STRING_AGG(r.EmailAddress, ','),'')
        FROM   [schdl].[ScheduleRecipient] sr
        JOIN   [schdl].[Recipient] r ON r.RecipientID = sr.RecipientID
        WHERE  sr.ScheduleID = @ScheduleID AND sr.RecipientRole = 'TO' AND r.IsActive = 1;

        -- Resolve combined/bulk filename from Schedule delivery config
        -- Priority: schedule FileNameTemplate > schedule FileNameSource > param-level template
        SET @bFileName = NULL;
        IF @sFileNameTemplate IS NOT NULL
        BEGIN
            SET @bFileName = @sFileNameTemplate;
            SET @bFileName = REPLACE(@bFileName, '{{REPORTNAME}}', @DocumentName);
            SET @bFileName = REPLACE(@bFileName, '{{DISPLAYNAME}}', '');
            -- @bsTok, @bsRes declared in BULK section
            DECLARE bst CURSOR LOCAL FAST_FORWARD FOR
                SELECT Token, [schdl].[fn_ResolveDateToken](Token, @Today)
                FROM   [schdl].[DateToken] WHERE IsActive = 1;
            OPEN bst; FETCH NEXT FROM bst INTO @bsTok, @bsRes;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @bFileName LIKE '%' + @bsTok + '%'
                    SET @bFileName = REPLACE(@bFileName, @bsTok, @bsRes);
                FETCH NEXT FROM bst INTO @bsTok, @bsRes;
            END;
            CLOSE bst; DEALLOCATE bst;
        END
        ELSE IF @sFileNameSource = 'STATIC'
            SET @bFileName = @sFileNameSourceValue;
        ELSE IF @PrimFNTemplate IS NOT NULL
        BEGIN
            SET @bFileName = @PrimFNTemplate;
            -- Replace {{REPORTNAME}} with DocumentName
            IF @bFileName LIKE '%{{REPORTNAME}}%'
                SET @bFileName = REPLACE(@bFileName, '{{REPORTNAME}}', @DocumentName);
            SET @bFileName = REPLACE(@bFileName, '{{{DISPLAYNAME}}}', '');
            -- @bfTok, @bfRes declared in BULK section
            DECLARE bft CURSOR LOCAL FAST_FORWARD FOR
                SELECT Token, [schdl].[fn_ResolveDateToken](Token, @Today)
                FROM   [schdl].[DateToken] WHERE IsActive = 1;
            OPEN bft; FETCH NEXT FROM bft INTO @bfTok, @bfRes;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @bFileName LIKE '%' + @bfTok + '%'
                    SET @bFileName = REPLACE(@bFileName, @bfTok, @bfRes);
                FETCH NEXT FROM bft INTO @bfTok, @bfRes;
            END;
            CLOSE bft; DEALLOCATE bft;
        END
        ELSE IF @PrimFNSrc = 'STATIC'
            SET @bFileName = @PrimFNSrcVal;

        -- Resolve combined/bulk folder path from Schedule delivery config
        SET @bFolder = NULL;
        IF @sFolderSource = 'STATIC'
            SET @bFolder = @sFolderSourceValue;
        ELSE IF @sFolderSource = 'LOOKUP_VIEW'
        BEGIN
            SET @lvBFolSQL = N'SELECT TOP 1 @e = FolderPath FROM '
                + @sFolderSourceValue + N' WHERE LookupKey = @v';
            EXEC sp_executesql @lvBFolSQL, N'@v NVARCHAR(500), @e NVARCHAR(1000) OUTPUT',
                @v = @DocumentName, @e = @bFolder OUTPUT;
        END
        ELSE IF @sFolderSource = 'SCALAR_FN'
        BEGIN
            SET @sfBFolSQL = N'SELECT @e = ' + @sFolderSourceValue + N'(@v)';
            EXEC sp_executesql @sfBFolSQL, N'@v NVARCHAR(500), @e NVARCHAR(1000) OUTPUT',
                @v = @DocumentName, @e = @bFolder OUTPUT;
        END
        ELSE IF @sFolderSource = 'DYNAMIC_SQL'
        BEGIN
            SET @dyBFolSQL = N'SELECT TOP 1 @e = FolderPath FROM ('
                + @sFolderSourceValue + N') AS _q';
            EXEC sp_executesql @dyBFolSQL, N'@e NVARCHAR(1000) OUTPUT', @e = @bFolder OUTPUT;
        END;

        INSERT INTO [schdl].[DispatchQueue]
            (LogID,ScheduleID,DispatchType,DeliveryMethod,DispatchKeyValue,
             DisplayName,FileName,RequestJson,
             ToAddresses,CcAddresses,BccAddresses,EmailSubject,EmailBody,
             FolderPath)
        VALUES
            (@LogID,@ScheduleID,'COMBINED',@sDeliveryMethod,NULL,
             NULL,@bFileName,@bReqJson,
             ISNULL(@bTo,''),@Cc,@Bcc,@EmailSubject,@EmailBody,
             @bFolder);
    END;
END;
GO


-- 4.2  usp_GetDueSchedules  (Flowgear calls this on its cron)
CREATE PROCEDURE [schdl].[usp_GetDueSchedules]
    @AsOf DATETIME2 = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2=ISNULL(@AsOf,SYSUTCDATETIME());
    DECLARE @Today DATE=CAST(@Now AS DATE);
    DECLARE @NowTime TIME=CAST(@Now AS TIME);
    DECLARE @DOW TINYINT=DATEPART(WEEKDAY,@Now)-1;
    DECLARE @DOM SMALLINT=DAY(@Now);
    DECLARE @LastDOM SMALLINT=DAY(EOMONTH(@Now));

    -- Diagnostic: shows every active schedule and which gates pass/fail.
    -- Useful when testing with @AsOf to understand why a schedule is skipped.
    SELECT
        s.ScheduleID,
        s.ScheduleName,
        s.FrequencyType,
        s.StartDate,
        s.EndDate,
        s.NextRunAt,
        s.RunTime,
        s.DayOfMonth,
        s.DayOfWeek,
        s.IsActive,
        CAST(@Today AS NVARCHAR)                                        AS AsOfDate,
        CAST(@NowTime AS NVARCHAR)                                      AS AsOfTime,
        CASE WHEN s.IsActive = 1 THEN 'Y' ELSE 'N' END                 AS Gate_IsActive,
        CASE WHEN @Today BETWEEN s.StartDate
                             AND ISNULL(s.EndDate,'9999-12-31')
             THEN 'Y' ELSE 'N' END                                     AS Gate_DateRange,
        CASE WHEN s.NextRunAt IS NULL OR s.NextRunAt <= @Now
             THEN 'Y' ELSE 'N' END                                     AS Gate_NextRunAt,
        CASE
            WHEN s.FrequencyType='DAILY'
             AND CAST(s.RunTime AS TIME) <= @NowTime                    THEN 'Y'
            WHEN s.FrequencyType='WEEKLY'
             AND s.DayOfWeek=@DOW
             AND CAST(s.RunTime AS TIME) <= @NowTime                    THEN 'Y'
            WHEN s.FrequencyType='MONTHLY'
             AND (s.DayOfMonth=@DOM OR (s.DayOfMonth=-1 AND @DOM=@LastDOM))
             AND CAST(s.RunTime AS TIME) <= @NowTime                    THEN 'Y'
            WHEN s.FrequencyType='ADHOC'                                THEN 'Y'
            WHEN s.FrequencyType='INTERVAL'
             AND (s.WindowStart IS NULL OR @NowTime >= s.WindowStart)
             AND (s.WindowEnd   IS NULL OR @NowTime <= s.WindowEnd)     THEN 'Y'
            ELSE 'N'
        END                                                             AS Gate_Frequency
    FROM [schdl].[Schedule] s
    ORDER BY s.ScheduleName;

    DROP TABLE IF EXISTS #Due;
    SELECT s.ScheduleID INTO #Due FROM [schdl].[Schedule] s
    WHERE  s.IsActive=1
      AND  @Today BETWEEN s.StartDate AND ISNULL(s.EndDate,'9999-12-31')
      AND  (s.NextRunAt IS NULL OR s.NextRunAt<=@Now)
      AND  (
             (s.FrequencyType='DAILY'    AND CAST(s.RunTime AS TIME)<=@NowTime)
          OR (s.FrequencyType='WEEKLY'   AND s.DayOfWeek=@DOW AND CAST(s.RunTime AS TIME)<=@NowTime)
          OR (s.FrequencyType='MONTHLY'  AND (s.DayOfMonth=@DOM OR (s.DayOfMonth=-1 AND @DOM=@LastDOM))
                                         AND CAST(s.RunTime AS TIME)<=@NowTime)
          OR  s.FrequencyType='ADHOC'
          OR (s.FrequencyType='INTERVAL'
              AND (s.WindowStart IS NULL OR @NowTime>=s.WindowStart)
              AND (s.WindowEnd   IS NULL OR @NowTime<=s.WindowEnd))
           );

    INSERT INTO [schdl].[ExecutionLog](ScheduleID,Status) SELECT ScheduleID,'PENDING' FROM #Due;

    UPDATE s SET NextRunAt=CASE s.FrequencyType
        WHEN 'DAILY'    THEN DATEADD(DAY,1,@Now)
        WHEN 'WEEKLY'   THEN DATEADD(DAY,7,@Now)
        WHEN 'MONTHLY'  THEN DATEADD(MONTH,1,@Now)
        WHEN 'ADHOC'    THEN NULL
        WHEN 'INTERVAL' THEN DATEADD(MINUTE,s.IntervalMinutes,@Now)
        END, ModifiedAt=@Now
    FROM [schdl].[Schedule] s JOIN #Due d ON d.ScheduleID=s.ScheduleID;

    UPDATE s SET IsActive=0,ModifiedAt=@Now
    FROM [schdl].[Schedule] s JOIN #Due d ON d.ScheduleID=s.ScheduleID
    WHERE s.FrequencyType='ADHOC';

    DECLARE @sID INT,@lID BIGINT;
    DECLARE sc CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.ScheduleID,
               (SELECT MAX(LogID) FROM [schdl].[ExecutionLog]
                WHERE ScheduleID=d.ScheduleID AND Status='PENDING')
        FROM #Due d;
    OPEN sc; FETCH NEXT FROM sc INTO @sID,@lID;
    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC [schdl].[usp_BuildDispatchQueue] @ScheduleID=@sID,@LogID=@lID,@AsOf=@Now;
        FETCH NEXT FROM sc INTO @sID,@lID;
    END;
    CLOSE sc; DEALLOCATE sc;

    SELECT
        dq.QueueID,dq.LogID,dq.ScheduleID,
        s.ScheduleName,d.DocumentName,d.ReportEndpoint,
        dq.DispatchType,dq.DispatchKeyValue,dq.RequestJson,
        dq.ToAddresses,dq.CcAddresses,dq.BccAddresses,
        dq.EmailSubject,dq.EmailBody
    FROM [schdl].[DispatchQueue] dq
    JOIN [schdl].[Schedule] s ON s.ScheduleID=dq.ScheduleID
    JOIN [schdl].[Document] d ON d.ReportID=s.ReportID
    WHERE dq.Status='PENDING'
    ORDER BY dq.ScheduleID,dq.DispatchType DESC,dq.DispatchKeyValue;
END;
GO


-- 4.3  usp_UpdateDispatchStatus  (Flowgear calls after each send)
CREATE PROCEDURE [schdl].[usp_UpdateDispatchStatus]
    @QueueID      BIGINT,
    @Status       NVARCHAR(20),   -- SENT | FAILED | SKIPPED
    @ErrorMessage NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE [schdl].[DispatchQueue]
    SET    Status=@Status,ErrorMessage=@ErrorMessage,ProcessedAt=SYSUTCDATETIME()
    WHERE  QueueID=@QueueID;

    UPDATE el SET
        el.Status=CASE WHEN EXISTS(SELECT 1 FROM [schdl].[DispatchQueue] d2
                                   WHERE d2.LogID=el.LogID AND d2.Status='FAILED')
                       THEN 'FAILED' ELSE 'SUCCESS' END,
        el.ProcessedAt=SYSUTCDATETIME()
    FROM [schdl].[ExecutionLog] el
    JOIN [schdl].[DispatchQueue] dq ON dq.LogID=el.LogID
    WHERE dq.QueueID=@QueueID
      AND NOT EXISTS(SELECT 1 FROM [schdl].[DispatchQueue] d3
                     WHERE d3.LogID=el.LogID AND d3.Status='PENDING');
END;
GO


-- 4.4  usp_TestDispatch
--
--  Runs the full dispatch pipeline for a named schedule
--  WITHOUT checking FrequencyType, RunTime, DayOfWeek,
--  DayOfMonth, NextRunAt, or IsActive.
--
--  Use this to verify fan-out, email resolution, token
--  resolution, and RequestJson shape at any time of day
--  on any environment -- including before fn_FetchDocumentId
--  is wired up (documentId will be blank in the JSON, which
--  is expected until the resolver is configured).
--
--  Does NOT advance NextRunAt or alter IsActive.
--  Rows inserted into DispatchQueue are cleaned up at the
--  end unless @KeepResults = 1.
--
--  Usage:
--    EXEC schdl.usp_TestDispatch @ScheduleName = 'BRM Production Report - Monthly';
--    EXEC schdl.usp_TestDispatch @ScheduleName = 'BRM Production Report - Monthly', @KeepResults = 1;
CREATE PROCEDURE [schdl].[usp_TestDispatch]
    @ScheduleName   NVARCHAR(255),
    @AsOf           DATETIME2   = NULL,
    @KeepResults    BIT         = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ScheduleID INT;
    SELECT  @ScheduleID = ScheduleID
    FROM    [schdl].[Schedule]
    WHERE   ScheduleName = @ScheduleName;

    IF @ScheduleID IS NULL
    BEGIN
        SELECT 'ERROR'                                    AS Result,
               'Schedule not found: ' + @ScheduleName   AS Message;
        RETURN;
    END;

    INSERT INTO [schdl].[ExecutionLog] (ScheduleID, Status)
    VALUES (@ScheduleID, 'PENDING');

    DECLARE @LogID BIGINT = SCOPE_IDENTITY();

    EXEC [schdl].[usp_BuildDispatchQueue]
        @ScheduleID = @ScheduleID,
        @LogID      = @LogID,
        @AsOf       = @AsOf;

    SELECT
        dq.QueueID,
        dq.DispatchType,
        dq.DeliveryMethod,
        dq.DispatchKeyValue,
        dq.DisplayName,
        dq.FileName,
        dq.ToAddresses,
        dq.CcAddresses,
        dq.BccAddresses,
        dq.EmailSubject,
        dq.EmailBody,
        dq.FolderPath,
        dq.RequestJson
    FROM  [schdl].[DispatchQueue] dq
    WHERE dq.LogID = @LogID
    ORDER BY dq.DispatchType DESC, dq.DispatchKeyValue;

    IF @KeepResults = 0
    BEGIN
        DELETE FROM [schdl].[DispatchQueue] WHERE LogID = @LogID;
        DELETE FROM [schdl].[ExecutionLog]  WHERE LogID = @LogID;
    END;
END;
GO


-- 4.5  usp_GetScheduleJson
--
--  Reads a registered schedule and reconstructs the exact JSON and
--  EXEC statement needed to re-register it. Useful for editing an
--  existing schedule in the HTML builder or auditing live config.
--
--  Returns one row:
--    ScheduleName   — schedule display name
--    DocumentName   — document/report name
--    DispatchJson   — @DispatchJson value (delivery config)
--    ParametersJson — @ParametersJson value (incl. fanOut block where present)
--    RecipientsJson — @RecipientsJson value (static recipients)
--    RegisterSQL    — ready-to-run EXEC usp_RegisterSchedule call
--
--  Usage:
--    EXEC schdl.usp_GetScheduleJson @ScheduleName = 'BRM Production Report - Monthly';
CREATE PROCEDURE [schdl].[usp_GetScheduleJson]
    @ScheduleName NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @ScheduleID             INT,
        @DocumentName           NVARCHAR(255),
        @ReportEndpoint         NVARCHAR(500),
        @OutputFormat           NVARCHAR(20),
        @Language               INT,
        @Confidentiality        NVARCHAR(50),
        @FrequencyType          NVARCHAR(20),
        @RunTime                TIME,
        @DayOfWeek              TINYINT,
        @DayOfMonth             SMALLINT,
        @IntervalMinutes        INT,
        @WindowStart            TIME,
        @WindowEnd              TIME,
        @StartDate              DATE,
        @EndDate                DATE,
        @Subject                NVARCHAR(500),
        @BodyTemplate           NVARCHAR(MAX),
        @DeliveryMethod         NVARCHAR(10),
        @EmailSource            NVARCHAR(20),
        @EmailSourceValue       NVARCHAR(1000),
        @FileNameTemplate       NVARCHAR(500),
        @FileNameSource         NVARCHAR(20),
        @FileNameSourceValue    NVARCHAR(1000),
        @FolderSource           NVARCHAR(20),
        @FolderSourceValue      NVARCHAR(1000);

    SELECT
        @ScheduleID          = s.ScheduleID,
        @DocumentName        = d.DocumentName,
        @ReportEndpoint      = d.ReportEndpoint,
        @OutputFormat        = d.DefaultOutputFormat,
        @Language            = d.DefaultLanguage,
        @Confidentiality     = d.DefaultConfidentiality,
        @FrequencyType       = s.FrequencyType,
        @RunTime             = s.RunTime,
        @DayOfWeek           = s.DayOfWeek,
        @DayOfMonth          = s.DayOfMonth,
        @IntervalMinutes     = s.IntervalMinutes,
        @WindowStart         = s.WindowStart,
        @WindowEnd           = s.WindowEnd,
        @StartDate           = s.StartDate,
        @EndDate             = s.EndDate,
        @Subject             = s.Subject,
        @BodyTemplate        = s.BodyTemplate,
        @DeliveryMethod      = ISNULL(s.DeliveryMethod, 'EMAIL'),
        @EmailSource         = s.EmailSource,
        @EmailSourceValue    = s.EmailSourceValue,
        @FileNameTemplate    = s.FileNameTemplate,
        @FileNameSource      = s.FileNameSource,
        @FileNameSourceValue = s.FileNameSourceValue,
        @FolderSource        = s.FolderSource,
        @FolderSourceValue   = s.FolderSourceValue
    FROM [schdl].[Schedule] s
    JOIN [schdl].[Document] d ON d.ReportID = s.ReportID
    WHERE s.ScheduleName = @ScheduleName;

    IF @ScheduleID IS NULL
    BEGIN
        SELECT 'ERROR'                                    AS Result,
               'Schedule not found: ' + @ScheduleName    AS Message;
        RETURN;
    END;

    -- Build @DispatchJson
    DECLARE @DispatchJson NVARCHAR(MAX) = '{';
    SET @DispatchJson += '"deliveryMethod":"' + STRING_ESCAPE(@DeliveryMethod,'json') + '"';
    IF @EmailSource IS NOT NULL
        SET @DispatchJson += ',"emailSource":"'         + STRING_ESCAPE(@EmailSource,'json')      + '"';
    IF @EmailSourceValue IS NOT NULL
        SET @DispatchJson += ',"emailSourceValue":"'    + STRING_ESCAPE(@EmailSourceValue,'json')  + '"';
    IF @FileNameTemplate IS NOT NULL
        SET @DispatchJson += ',"fileNameTemplate":"'    + STRING_ESCAPE(@FileNameTemplate,'json')  + '"';
    IF @FileNameSource IS NOT NULL
        SET @DispatchJson += ',"fileNameSource":"'      + STRING_ESCAPE(@FileNameSource,'json')    + '"';
    IF @FileNameSourceValue IS NOT NULL
        SET @DispatchJson += ',"fileNameSourceValue":"' + STRING_ESCAPE(@FileNameSourceValue,'json') + '"';
    IF @FolderSource IS NOT NULL
        SET @DispatchJson += ',"folderSource":"'        + STRING_ESCAPE(@FolderSource,'json')     + '"';
    IF @FolderSourceValue IS NOT NULL
        SET @DispatchJson += ',"folderSourceValue":"'   + STRING_ESCAPE(@FolderSourceValue,'json') + '"';
    SET @DispatchJson += '}';

    -- Build @ParametersJson — one element per ScheduleParameter row
    DECLARE @ParametersJson NVARCHAR(MAX) = '';
    DECLARE
        @pID            INT,
        @pName          NVARCHAR(100),
        @pType          NVARCHAR(50),
        @pRequired      BIT,
        @pSort          INT,
        @pValue         NVARCHAR(MAX),
        @pVQ            NVARCHAR(MAX),
        @pHasDC         BIT,
        @pIsPrimary     BIT,
        @pMode          NVARCHAR(12),
        @pEmailSrc      NVARCHAR(20),
        @pEmailSrcVal   NVARCHAR(1000),
        @pDNSrc         NVARCHAR(20),
        @pDNSrcVal      NVARCHAR(1000),
        @pFNSrc         NVARCHAR(20),
        @pFNSrcVal      NVARCHAR(1000),
        @pFNTemplate    NVARCHAR(500),
        @pFolSrc        NVARCHAR(20),
        @pFolSrcVal     NVARCHAR(1000),
        @pFirst         BIT = 1,
        @pChunk         NVARCHAR(MAX);

    DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            dp.ParameterID,
            dp.ParameterName,
            dp.DataType,
            dp.IsRequired,
            dp.SortOrder,
            sp.ParameterValue,
            sp.ParameterValueQuery,
            CASE WHEN dc.ConfigID IS NOT NULL THEN 1 ELSE 0 END,
            ISNULL(dc.IsPrimaryDispatchKey, 0),
            dc.DispatchMode,
            dc.EmailSource,
            dc.EmailSourceValue,
            dc.DisplayNameSource,
            dc.DisplayNameSourceValue,
            dc.FileNameSource,
            dc.FileNameSourceValue,
            dc.FileNameTemplate,
            dc.FolderSource,
            dc.FolderSourceValue
        FROM [schdl].[ScheduleParameter] sp
        JOIN [schdl].[DocumentParameter] dp ON dp.ParameterID = sp.ParameterID
        LEFT JOIN [schdl].[ParameterDispatchConfig] dc ON dc.ParameterID = dp.ParameterID
        WHERE sp.ScheduleID = @ScheduleID
        ORDER BY dp.SortOrder;

    OPEN pc;
    FETCH NEXT FROM pc INTO
        @pID, @pName, @pType, @pRequired, @pSort, @pValue, @pVQ,
        @pHasDC, @pIsPrimary, @pMode,
        @pEmailSrc, @pEmailSrcVal, @pDNSrc, @pDNSrcVal,
        @pFNSrc, @pFNSrcVal, @pFNTemplate, @pFolSrc, @pFolSrcVal;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @pFirst = 0 SET @ParametersJson += ',';
        SET @pFirst = 0;

        SET @pChunk  = '{';
        SET @pChunk += '"name":"'      + STRING_ESCAPE(@pName,'json')  + '"';
        SET @pChunk += ',"type":"'     + STRING_ESCAPE(@pType,'json')  + '"';
        SET @pChunk += ',"required":'  + CASE WHEN @pRequired = 1 THEN 'true' ELSE 'false' END;
        SET @pChunk += ',"sortOrder":' + CAST(@pSort AS NVARCHAR);
        SET @pChunk += ',"value":"'    + STRING_ESCAPE(ISNULL(@pValue,''),'json') + '"';
        IF @pVQ IS NOT NULL
            SET @pChunk += ',"valueQuery":"' + STRING_ESCAPE(@pVQ,'json') + '"';

        -- Emit fanOut block only for the primary dispatch key
        IF @pHasDC = 1 AND @pIsPrimary = 1
        BEGIN
            SET @pChunk += ',"fanOut":{';
            SET @pChunk += '"isPrimary":true';
            SET @pChunk += ',"mode":"' + STRING_ESCAPE(ISNULL(@pMode,'INDIVIDUAL'),'json') + '"';
            IF @pEmailSrc IS NOT NULL
                SET @pChunk += ',"emailSource":"'            + STRING_ESCAPE(@pEmailSrc,'json')    + '"';
            IF @pEmailSrcVal IS NOT NULL
                SET @pChunk += ',"emailSourceValue":"'       + STRING_ESCAPE(@pEmailSrcVal,'json') + '"';
            IF @pDNSrc IS NOT NULL
                SET @pChunk += ',"displayNameSource":"'      + STRING_ESCAPE(@pDNSrc,'json')       + '"';
            IF @pDNSrcVal IS NOT NULL
                SET @pChunk += ',"displayNameSourceValue":"' + STRING_ESCAPE(@pDNSrcVal,'json')    + '"';
            IF @pFNTemplate IS NOT NULL
                SET @pChunk += ',"fileNameTemplate":"'       + STRING_ESCAPE(@pFNTemplate,'json')  + '"';
            IF @pFNSrc IS NOT NULL
                SET @pChunk += ',"fileNameSource":"'         + STRING_ESCAPE(@pFNSrc,'json')       + '"';
            IF @pFNSrcVal IS NOT NULL
                SET @pChunk += ',"fileNameSourceValue":"'    + STRING_ESCAPE(@pFNSrcVal,'json')    + '"';
            IF @pFolSrc IS NOT NULL
                SET @pChunk += ',"folderSource":"'           + STRING_ESCAPE(@pFolSrc,'json')      + '"';
            IF @pFolSrcVal IS NOT NULL
                SET @pChunk += ',"folderSourceValue":"'      + STRING_ESCAPE(@pFolSrcVal,'json')   + '"';
            SET @pChunk += '}';
        END;

        SET @pChunk += '}';
        SET @ParametersJson += @pChunk;

        FETCH NEXT FROM pc INTO
            @pID, @pName, @pType, @pRequired, @pSort, @pValue, @pVQ,
            @pHasDC, @pIsPrimary, @pMode,
            @pEmailSrc, @pEmailSrcVal, @pDNSrc, @pDNSrcVal,
            @pFNSrc, @pFNSrcVal, @pFNTemplate, @pFolSrc, @pFolSrcVal;
    END;
    CLOSE pc; DEALLOCATE pc;

    SET @ParametersJson = '[' + @ParametersJson + ']';

    -- Build @RecipientsJson from ScheduleRecipient (all static recipients)
    DECLARE @RecipientsJson NVARCHAR(MAX);
    SELECT @RecipientsJson =
        ISNULL(
            '[' +
            STRING_AGG(
                '{"name":"'   + STRING_ESCAPE(ISNULL(r.RecipientName,''),'json') +
                '","email":"' + STRING_ESCAPE(r.EmailAddress,'json') +
                '","role":"'  + sr.RecipientRole + '"}',
                ','
            ) WITHIN GROUP (ORDER BY sr.RecipientRole, r.EmailAddress)
            + ']',
        '[]')
    FROM [schdl].[ScheduleRecipient] sr
    JOIN [schdl].[Recipient] r ON r.RecipientID = sr.RecipientID
    WHERE sr.ScheduleID = @ScheduleID AND r.IsActive = 1;

    -- Build RegisterSQL — ready-to-run EXEC call
    DECLARE @RegisterSQL NVARCHAR(MAX);
    SET @RegisterSQL  = 'EXEC [schdl].[usp_RegisterSchedule]' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @DocumentName    = N''' + REPLACE(@DocumentName,   '''','''''') + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @ReportEndpoint  = N''' + REPLACE(@ReportEndpoint, '''','''''') + ''',' + CHAR(13)+CHAR(10);
    IF @OutputFormat <> 'xlsx'
        SET @RegisterSQL += '    @OutputFormat    = '''  + @OutputFormat + ''',' + CHAR(13)+CHAR(10);
    IF @Language <> 1
        SET @RegisterSQL += '    @Language        = '    + CAST(@Language AS NVARCHAR) + ',' + CHAR(13)+CHAR(10);
    IF @Confidentiality <> 'normal'
        SET @RegisterSQL += '    @Confidentiality = '''  + @Confidentiality + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @ScheduleName    = N''' + REPLACE(@ScheduleName,   '''','''''') + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @FrequencyType   = '''  + @FrequencyType + ''',' + CHAR(13)+CHAR(10);
    IF @RunTime IS NOT NULL
        SET @RegisterSQL += '    @RunTime         = ''' + CONVERT(NVARCHAR(8),@RunTime,108)     + ''',' + CHAR(13)+CHAR(10);
    IF @DayOfWeek IS NOT NULL
        SET @RegisterSQL += '    @DayOfWeek       = '   + CAST(@DayOfWeek AS NVARCHAR)  + ',' + CHAR(13)+CHAR(10);
    IF @DayOfMonth IS NOT NULL
        SET @RegisterSQL += '    @DayOfMonth      = '   + CAST(@DayOfMonth AS NVARCHAR) + ',' + CHAR(13)+CHAR(10);
    IF @IntervalMinutes IS NOT NULL
        SET @RegisterSQL += '    @IntervalMinutes = '   + CAST(@IntervalMinutes AS NVARCHAR) + ',' + CHAR(13)+CHAR(10);
    IF @WindowStart IS NOT NULL
        SET @RegisterSQL += '    @WindowStart     = ''' + CONVERT(NVARCHAR(8),@WindowStart,108) + ''',' + CHAR(13)+CHAR(10);
    IF @WindowEnd IS NOT NULL
        SET @RegisterSQL += '    @WindowEnd       = ''' + CONVERT(NVARCHAR(8),@WindowEnd,108)   + ''',' + CHAR(13)+CHAR(10);
    IF @StartDate IS NOT NULL AND @StartDate <> '2000-01-01'
        SET @RegisterSQL += '    @StartDate       = ''' + CONVERT(NVARCHAR(10),@StartDate,23)  + ''',' + CHAR(13)+CHAR(10);
    IF @EndDate IS NOT NULL
        SET @RegisterSQL += '    @EndDate         = ''' + CONVERT(NVARCHAR(10),@EndDate,23)    + ''',' + CHAR(13)+CHAR(10);
    IF @Subject IS NOT NULL
        SET @RegisterSQL += '    @Subject         = N''' + REPLACE(@Subject,      '''','''''') + ''',' + CHAR(13)+CHAR(10);
    IF @BodyTemplate IS NOT NULL
        SET @RegisterSQL += '    @BodyTemplate    = N''' + REPLACE(@BodyTemplate, '''','''''') + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @DispatchJson    = N''' + REPLACE(@DispatchJson,    '''','''''') + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @ParametersJson  = N''' + REPLACE(@ParametersJson, '''','''''') + '''';
    IF @RecipientsJson <> '[]'
        SET @RegisterSQL += ',' + CHAR(13)+CHAR(10)
            + '    @RecipientsJson  = N''' + REPLACE(@RecipientsJson, '''','''''') + '''';
    SET @RegisterSQL += ';';

    SELECT
        @ScheduleName    AS ScheduleName,
        @DocumentName    AS DocumentName,
        @DispatchJson    AS DispatchJson,
        @ParametersJson  AS ParametersJson,
        @RecipientsJson  AS RecipientsJson,
        @RegisterSQL     AS RegisterSQL;
END;
GO


-- ============================================================
--  SECTION 5  ENVIRONMENT SETUP
--
--  Edit schdl.fn_FetchDocumentId (Section 2.2) once to point
--  at your document catalogue.  That is the only change needed
--  per environment.  No table rows, no INSERT statements.
-- ============================================================

-- ============================================================
--  SECTION 6  SAMPLE REGISTRATIONS
--  One EXEC per schedule. Everything in one call.
-- ============================================================

-- A2: BRM Production Report — values driven by live query
--     The list of active BRM codes is fetched from the database
--     at dispatch time. No hardcoding needed — new BRMs are
--     picked up automatically on the next run.
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'BRM Production Report',
    @ReportEndpoint = '/api/reports/generate',
    @OutputFormat   = 'xlsx',
    @ScheduleName   = 'BRM Production Report - Monthly Dynamic',
    @FrequencyType  = 'MONTHLY',
    @RunTime        = '06:00',
    @DayOfMonth     = 1,
    @Subject        = 'BRM Production Report - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}',
    @BodyTemplate   = 'Please find attached your production report for the previous month.',
    @ParametersJson = N'[
        {
            "name": "BrokerRelationshipManager",
            "type": "string", "required": true, "sortOrder": 1,
            "value":      "DYNAMIC",
            "valueQuery": "SELECT sBRMCode AS [Value] FROM dbo.BrokerRelationshipManager WHERE bActive = 1 ORDER BY sBRMCode",
            "dispatch": {
                "isPrimary":        true,
                "mode":             "BOTH",
                "emailSource":      "LOOKUP_VIEW",
                "emailSourceValue": "schdl.vw_BRMEmail",
                "bulkEmail":        "reports-bulk@example.com"
            }
        },
        { "name": "CaptureDateTo",    "type": "date", "required": true, "sortOrder": 2, "value": "{{PREV_MONTH_END}}" },
        { "name": "CapturedDateFrom", "type": "date", "required": true, "sortOrder": 3, "value": "{{PREV_MONTH_START}}" }
    ]';
GO


-- A: BRM Production Report  (BOTH -- individual per BRM + one bulk)
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
            "name":"BrokerRelationshipManager","type":"string","required":true,"sortOrder":1,
            "value":"BRM001|BRM002|BRM003|BRM004|BRM005|BRM006|BRM007|BRM008",
            "dispatch":{
                "isPrimary":true,"mode":"BOTH",
                "emailSource":"LOOKUP_VIEW","emailSourceValue":"schdl.vw_BRMEmail",
                "bulkEmail":"reports-bulk@example.com"
            }
        },
        {"name":"Brokerage",                "type":"string","required":true,"sortOrder":2,"value":"39398|38|39399|39|39400"},
        {"name":"Administrator_HeadOffice", "type":"string","required":true,"sortOrder":3,"value":"39323|2|41085|3|39324"},
        {"name":"CaptureDateTo",            "type":"date",  "required":true,"sortOrder":4,"value":"{{PREV_MONTH_END}}"},
        {"name":"PaymentTerm",              "type":"string","required":true,"sortOrder":5,"value":"0|1|3|4|2"},
        {"name":"Product",                  "type":"string","required":true,"sortOrder":6,"value":"17110|16970"},
        {"name":"CapturedDateFrom",         "type":"date",  "required":true,"sortOrder":7,"value":"{{PREV_MONTH_START}}"}
    ]',
    @RecipientsJson = N'[{"name":"Reports Admin","email":"reports-admin@example.com","role":"CC"}]';
GO

-- B: Daily Exception  (BULK, STATIC email)
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
            "name":"AsOfDate","type":"date","required":true,"sortOrder":1,
            "value":"{{TODAY-1}}",
            "dispatch":{"isPrimary":true,"mode":"COMBINED","emailSource":"STATIC","bulkEmail":"it-alerts@example.com"}
        }
    ]',
    @RecipientsJson = N'[{"name":"IT Manager","email":"it-mgr@example.com","role":"CC"}]';
GO

-- C: Broker Statement  (INDIVIDUAL, email from scalar function)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Broker Monthly Statement',
    @ReportEndpoint = '/api/reports/generate',
    @ScheduleName   = 'Broker Monthly Statement - Monthly',
    @FrequencyType  = 'MONTHLY',
    @RunTime        = '05:30',
    @DayOfMonth     = 1,
    @Subject        = 'Your Statement - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}',
    @ParametersJson = N'[
        {
            "name":"BrokerageID","type":"string","required":true,"sortOrder":1,
            "value":"39398|38|39399|39|39400",
            "dispatch":{"isPrimary":true,"mode":"INDIVIDUAL","emailSource":"SCALAR_FN","emailSourceValue":"dbo.fn_GetBrokerEmail"}
        },
        {"name":"StatementDate","type":"date","required":true,"sortOrder":2,"value":"{{PREV_MONTH_END}}"}
    ]';
GO

-- D: Admin Summary  (INDIVIDUAL, email from inline SQL)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Administrator Summary',
    @ReportEndpoint = '/api/reports/generate',
    @ScheduleName   = 'Administrator Summary - Weekly',
    @FrequencyType  = 'WEEKLY',
    @RunTime        = '08:00',
    @DayOfWeek      = 1,
    @Subject        = 'Weekly Admin Summary - {{PREV_WEEK_START}} to {{PREV_WEEK_END}}',
    @ParametersJson = N'[
        {
            "name":"Administrator_HeadOffice","type":"string","required":true,"sortOrder":1,
            "value":"39323|2|41085|3|39324",
            "dispatch":{
                "isPrimary":true,"mode":"INDIVIDUAL","emailSource":"DYNAMIC_SQL",
                "emailSourceValue":"SELECT ContactEmail AS EmailAddress FROM dbo.Administrator WHERE AdminID = ''{VALUE}''"
            }
        },
        {"name":"WeekEndDate","type":"date","required":true,"sortOrder":2,"value":"{{PREV_WEEK_END}}"}
    ]';
GO

-- ============================================================
--  SECTION 7  ADMIN REFERENCE QUERIES
-- ============================================================

-- All date tokens with values resolved for today
-- SELECT   dt.TokenID, dt.Token, dt.Category, dt.Description,
--          schdl.fn_ResolveDateToken(dt.Token, CAST(GETDATE() AS DATE)) AS ResolvedToday
-- FROM     schdl.DateToken dt
-- WHERE    dt.IsActive = 1
-- ORDER BY dt.Category, dt.TokenID;

-- All schedules with live-resolved documentId
-- SELECT   d.DocumentName,
--          s.ScheduleName,
--          s.FrequencyType,
--          s.NextRunAt,
--          s.IsActive,
--          schdl.fn_FetchDocumentId(d.DocumentName) AS ResolvedDocumentId
-- FROM     schdl.Schedule  s
-- JOIN     schdl.Document  d  ON d.ReportID = s.ReportID
-- ORDER BY s.NextRunAt;

-- All dispatch configs per document
-- SELECT   d.DocumentName,
--          dp.ParameterName,
--          dp.SortOrder,
--          dc.IsPrimaryDispatchKey,
--          dc.DispatchMode,
--          dc.EmailSource,
--          dc.EmailSourceValue,
--          dc.BulkEmailAddress
-- FROM     schdl.ParameterDispatchConfig  dc
-- JOIN     schdl.DocumentParameter        dp ON dp.ParameterID = dc.ParameterID
-- JOIN     schdl.Document                 d  ON d.ReportID     = dp.ReportID
-- ORDER BY d.DocumentName, dp.SortOrder;

-- All schedules with their parameter values
-- SELECT   d.DocumentName,
--          s.ScheduleName,
--          dp.ParameterName,
--          sp.ParameterValue,
--          schdl.fn_ResolveDateToken(sp.ParameterValue, CAST(GETDATE() AS DATE)) AS ResolvedToday
-- FROM     schdl.ScheduleParameter  sp
-- JOIN     schdl.DocumentParameter  dp ON dp.ParameterID = sp.ParameterID
-- JOIN     schdl.Schedule           s  ON s.ScheduleID  = sp.ScheduleID
-- JOIN     schdl.Document           d  ON d.ReportID    = s.ReportID
-- ORDER BY d.DocumentName, s.ScheduleName, dp.SortOrder;

-- Schedule recipients
-- SELECT   s.ScheduleName,
--          r.RecipientName,
--          r.EmailAddress,
--          sr.RecipientRole
-- FROM     schdl.ScheduleRecipient  sr
-- JOIN     schdl.Schedule           s  ON s.ScheduleID  = sr.ScheduleID
-- JOIN     schdl.Recipient          r  ON r.RecipientID = sr.RecipientID
-- WHERE    r.IsActive = 1
-- ORDER BY s.ScheduleName, sr.RecipientRole;

-- Recent dispatch queue
-- SELECT   TOP 50
--          dq.QueueID,
--          s.ScheduleName,
--          d.DocumentName,
--          dq.DispatchType,
--          dq.DispatchKeyValue,
--          dq.ToAddresses,
--          dq.Status,
--          dq.CreatedAt,
--          dq.ProcessedAt,
--          dq.ErrorMessage
-- FROM     schdl.DispatchQueue  dq
-- JOIN     schdl.Schedule       s  ON s.ScheduleID = dq.ScheduleID
-- JOIN     schdl.Document       d  ON d.ReportID   = s.ReportID
-- ORDER BY dq.CreatedAt DESC;

-- Execution log summary
-- SELECT   el.LogID,
--          s.ScheduleName,
--          el.ExecutedAt,
--          el.Status,
--          el.ProcessedAt,
--          el.ErrorMessage,
--          COUNT(dq.QueueID)                                    AS TotalRows,
--          SUM(CASE WHEN dq.Status = 'SENT'    THEN 1 ELSE 0 END) AS Sent,
--          SUM(CASE WHEN dq.Status = 'FAILED'  THEN 1 ELSE 0 END) AS Failed,
--          SUM(CASE WHEN dq.Status = 'PENDING' THEN 1 ELSE 0 END) AS Pending
-- FROM     schdl.ExecutionLog   el
-- JOIN     schdl.Schedule       s  ON s.ScheduleID = el.ScheduleID
-- LEFT JOIN schdl.DispatchQueue dq ON dq.LogID     = el.LogID
-- GROUP BY el.LogID, s.ScheduleName, el.ExecutedAt, el.Status, el.ProcessedAt, el.ErrorMessage
-- ORDER BY el.ExecutedAt DESC;

-- Test run without advancing NextRunAt
-- EXEC schdl.usp_GetDueSchedules @AsOf='2026-06-01 06:00:00';

-- ============================================================
--  FLOWGEAR CALL SEQUENCE
--  1. EXEC schdl.usp_GetDueSchedules
--     Returns N rows, one per email to send
--  2. For each row:
--     a. POST RequestJson to ReportEndpoint
--     b. Send email: To=ToAddresses, CC=CcAddresses, BCC=BccAddresses
--        Subject=EmailSubject, Body=EmailBody, Attach=report from (a)
--     c. EXEC schdl.usp_UpdateDispatchStatus
--            @QueueID=row.QueueID, @Status='SENT'|'FAILED',
--            @ErrorMessage=NULL|'<error detail>'
-- ============================================================

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
IF OBJECT_ID('[schdl].[fn_FetchDocumentId]',    'FN') IS NOT NULL DROP FUNCTION [schdl].[fn_FetchDocumentId];
IF OBJECT_ID('[schdl].[fn_ResolveAllTokens]',   'FN') IS NOT NULL DROP FUNCTION [schdl].[fn_ResolveAllTokens];
IF OBJECT_ID('[schdl].[fn_ResolveDateToken]',   'FN') IS NOT NULL DROP FUNCTION [schdl].[fn_ResolveDateToken];
GO

-- Tables (children before parents to satisfy FK constraints)
IF OBJECT_ID('[schdl].[DispatchQueue]',              'U') IS NOT NULL DROP TABLE [schdl].[DispatchQueue];
IF OBJECT_ID('[schdl].[ExecutionLog]',               'U') IS NOT NULL DROP TABLE [schdl].[ExecutionLog];
IF OBJECT_ID('[schdl].[ScheduleStandingRecipient]',  'U') IS NOT NULL DROP TABLE [schdl].[ScheduleStandingRecipient];
IF OBJECT_ID('[schdl].[ScheduleRecipient]',          'U') IS NOT NULL DROP TABLE [schdl].[ScheduleRecipient];
IF OBJECT_ID('[schdl].[ScheduleParameter]',          'U') IS NOT NULL DROP TABLE [schdl].[ScheduleParameter];
IF OBJECT_ID('[schdl].[ParameterDispatchConfig]',    'U') IS NOT NULL DROP TABLE [schdl].[ParameterDispatchConfig];
IF OBJECT_ID('[schdl].[DocumentParameter]',          'U') IS NOT NULL DROP TABLE [schdl].[DocumentParameter];
IF OBJECT_ID('[schdl].[Schedule]',                   'U') IS NOT NULL DROP TABLE [schdl].[Schedule];
IF OBJECT_ID('[schdl].[Document]',                   'U') IS NOT NULL DROP TABLE [schdl].[Document];
IF OBJECT_ID('[schdl].[DateToken]',                  'U') IS NOT NULL DROP TABLE [schdl].[DateToken];
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
    CreatedAt               DATETIME2       NOT NULL DEFAULT GETDATE(),
    ModifiedAt              DATETIME2       NOT NULL DEFAULT GETDATE()
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
--  Two source modes apply to all resolver fields (Email, Folder, FileName, DisplayName, Subject, Body):
--
--  Source pattern     SourceValue
--  ─────────────────  ──────────────────────────────────────────────
--  STATIC             literal value — tokens ({{REPORTNAME}} etc.) resolved at dispatch time
--  DYNAMIC_SQL        SQL SELECT with {VALUE} placeholder (replaced with fan-out value at runtime)
--                     Must return a single column with the required alias (see below)
--
--  Required column aliases for DYNAMIC_SQL:
--    Email resolver   → EmailAddress   (multiple rows STRING_AGG'd comma-separated)
--    DisplayName      → DisplayName
--    FileName         → FileName
--    FolderPath       → FolderPath
--    Subject          → Subject
--    Body             → Body
CREATE TABLE [schdl].[ParameterDispatchConfig] (
    ConfigID                INT             IDENTITY(1,1) PRIMARY KEY,
    ParameterID             INT             NOT NULL UNIQUE
        REFERENCES [schdl].[DocumentParameter](ParameterID),
    IsPrimaryDispatchKey    BIT             NOT NULL DEFAULT 0,
    DispatchMode            NVARCHAR(12)    NOT NULL DEFAULT 'COMBINED'
        CHECK (DispatchMode IN ('COMBINED','INDIVIDUAL','BOTH')),

    -- Per-entity email resolver (fan-out only)
    EmailSource             NVARCHAR(20)    NOT NULL DEFAULT 'STATIC'
        CHECK (EmailSource IN ('STATIC','DYNAMIC_SQL')),
    EmailSourceValue        NVARCHAR(MAX)   NULL,

    -- Display name resolver
    DisplayNameSource       NVARCHAR(20)    NULL
        CHECK (DisplayNameSource IN ('STATIC','DYNAMIC_SQL')),
    DisplayNameSourceValue  NVARCHAR(MAX)   NULL,

    -- File name override — Source/Value pattern, tokens supported in static value
    -- Tokens: {{DISPLAYNAME}} {{REPORTNAME}} {{DATE_TOKEN}}
    FileNameSource          NVARCHAR(20)    NULL
        CHECK (FileNameSource IN ('STATIC','DYNAMIC_SQL')),
    FileNameSourceValue     NVARCHAR(MAX)   NULL,

    -- Per-entity folder resolver (optional — NULL inherits Schedule.FolderSourceValue)
    FolderSource            NVARCHAR(20)    NULL
        CHECK (FolderSource IN ('STATIC','DYNAMIC_SQL')),
    FolderSourceValue       NVARCHAR(MAX)   NULL,

    -- Per-entity subject override (optional — NULL falls back to Schedule.SubjectSourceValue)
    SubjectSource           NVARCHAR(20)    NULL
        CHECK (SubjectSource IN ('STATIC','DYNAMIC_SQL')),
    SubjectSourceValue      NVARCHAR(MAX)   NULL,

    -- Per-entity body override (optional — NULL falls back to Schedule.BodySourceValue)
    BodySource              NVARCHAR(20)    NULL
        CHECK (BodySource IN ('STATIC','DYNAMIC_SQL')),
    BodySourceValue         NVARCHAR(MAX)   NULL
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
    --
    -- Schedule-level delivery configuration
    -- Source/Value pattern throughout: Source = 'STATIC' or 'DYNAMIC_SQL'
    -- Value = the static string or the SQL query depending on Source
    --
    DeliveryMethod          NVARCHAR(10)   NOT NULL DEFAULT 'EMAIL'
        CHECK (DeliveryMethod IN ('EMAIL','FOLDER','BOTH')),
    -- Combined email recipient (TO address)
    -- DYNAMIC_SQL may return multiple rows — STRING_AGG'd into comma-separated string
    EmailSource             NVARCHAR(20)   NULL
        CHECK (EmailSource IN ('STATIC','DYNAMIC_SQL')),
    EmailSourceValue        NVARCHAR(MAX)  NULL,
    -- Email subject
    SubjectSource           NVARCHAR(20)   NULL
        CHECK (SubjectSource IN ('STATIC','DYNAMIC_SQL')),
    SubjectSourceValue      NVARCHAR(MAX)  NULL,
    -- Email body
    BodySource              NVARCHAR(20)   NULL
        CHECK (BodySource IN ('STATIC','DYNAMIC_SQL')),
    BodySourceValue         NVARCHAR(MAX)  NULL,
    -- File name (applies to combined row; fan-out rows may override per-entity)
    FileNameSource          NVARCHAR(20)   NULL
        CHECK (FileNameSource IN ('STATIC','DYNAMIC_SQL')),
    FileNameSourceValue     NVARCHAR(MAX)  NULL,
    -- Folder drop destination (combined row)
    FolderSource            NVARCHAR(20)   NULL
        CHECK (FolderSource IN ('STATIC','DYNAMIC_SQL')),
    FolderSourceValue       NVARCHAR(MAX)  NULL,
    --
    CreatedAt       DATETIME2       NOT NULL DEFAULT GETDATE(),
    ModifiedAt      DATETIME2       NOT NULL DEFAULT GETDATE()
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


-- 1.8  Recipients (flat — one row per schedule+email, no shared address book)
-- Standing CC/BCC recipients — static email addresses only.
-- The main TO recipient lives on Schedule.EmailSourceValue.
-- These are fixed addresses included on every delivery for this schedule.
CREATE TABLE [schdl].[ScheduleStandingRecipient] (
    StandingRecipientID  INT             IDENTITY(1,1) PRIMARY KEY,
    ScheduleID           INT             NOT NULL
        REFERENCES [schdl].[Schedule](ScheduleID),
    EmailAddress         NVARCHAR(320)   NOT NULL,
    RecipientRole        NVARCHAR(5)     NOT NULL
        CHECK (RecipientRole IN ('CC','BCC')),
    IncludeInFanOut      BIT             NOT NULL DEFAULT 0
);
GO


-- 1.9  Execution log
CREATE TABLE [schdl].[ExecutionLog] (
    LogID        BIGINT          IDENTITY(1,1) PRIMARY KEY,
    ScheduleID   INT             NOT NULL REFERENCES [schdl].[Schedule](ScheduleID),
    ExecutedAt   DATETIME2       NOT NULL DEFAULT GETDATE(),
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
        CHECK (Status IN ('PENDING','SENT','SUCCESS','FAILED','SKIPPED')),
    CreatedAt        DATETIME2       NOT NULL DEFAULT GETDATE(),
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
    DECLARE @Today  DATE          = ISNULL(@AsOfDate, CAST(GETDATE() AS DATE));
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


-- 2.2  fn_ResolveAllTokens
--
--  Resolves {{REPORTNAME}} and all date/offset tokens in a single string.
--  Use this in usp_BuildDispatchQueue to resolve FolderPath, FileName,
--  EmailSubject, EmailBody, and DisplayName without opening a cursor per field.
CREATE FUNCTION [schdl].[fn_ResolveAllTokens]
(
    @Input       NVARCHAR(MAX),
    @AsOfDate    DATE,
    @ReportName  NVARCHAR(255)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @Input IS NULL RETURN NULL;
    DECLARE @Result NVARCHAR(MAX) = @Input;

    -- {{REPORTNAME}}
    SET @Result = REPLACE(@Result, '{{REPORTNAME}}', ISNULL(@ReportName,''));

    -- TODAY
    SET @Result = REPLACE(@Result, '{{TODAY}}',
        CONVERT(NVARCHAR(10), @AsOfDate, 23));

    -- Current week  (Mon=start, Sun=end)
    SET @Result = REPLACE(@Result, '{{WEEK_START}}',
        CONVERT(NVARCHAR(10), DATEADD(DAY, 2-DATEPART(WEEKDAY,@AsOfDate), @AsOfDate), 23));
    SET @Result = REPLACE(@Result, '{{WEEK_END}}',
        CONVERT(NVARCHAR(10), DATEADD(DAY, 8-DATEPART(WEEKDAY,@AsOfDate), @AsOfDate), 23));

    -- Previous week
    SET @Result = REPLACE(@Result, '{{PREV_WEEK_START}}',
        CONVERT(NVARCHAR(10), DATEADD(DAY, -5-DATEPART(WEEKDAY,@AsOfDate), @AsOfDate), 23));
    SET @Result = REPLACE(@Result, '{{PREV_WEEK_END}}',
        CONVERT(NVARCHAR(10), DATEADD(DAY,  1-DATEPART(WEEKDAY,@AsOfDate), @AsOfDate), 23));

    -- Current month
    SET @Result = REPLACE(@Result, '{{MONTH_START}}',
        CONVERT(NVARCHAR(10), DATEFROMPARTS(YEAR(@AsOfDate),MONTH(@AsOfDate),1), 23));
    SET @Result = REPLACE(@Result, '{{MONTH_END}}',
        CONVERT(NVARCHAR(10), EOMONTH(@AsOfDate), 23));

    -- Previous month
    SET @Result = REPLACE(@Result, '{{PREV_MONTH_START}}',
        CONVERT(NVARCHAR(10),
            DATEFROMPARTS(YEAR(DATEADD(MONTH,-1,@AsOfDate)),
                          MONTH(DATEADD(MONTH,-1,@AsOfDate)),1), 23));
    SET @Result = REPLACE(@Result, '{{PREV_MONTH_END}}',
        CONVERT(NVARCHAR(10), EOMONTH(DATEADD(MONTH,-1,@AsOfDate)), 23));

    -- Next month
    SET @Result = REPLACE(@Result, '{{NEXT_MONTH_START}}',
        CONVERT(NVARCHAR(10),
            DATEFROMPARTS(YEAR(DATEADD(MONTH,1,@AsOfDate)),
                          MONTH(DATEADD(MONTH,1,@AsOfDate)),1), 23));
    SET @Result = REPLACE(@Result, '{{NEXT_MONTH_END}}',
        CONVERT(NVARCHAR(10), EOMONTH(DATEADD(MONTH,1,@AsOfDate)), 23));

    -- Current quarter
    SET @Result = REPLACE(@Result, '{{QUARTER_START}}',
        CONVERT(NVARCHAR(10),
            DATEFROMPARTS(YEAR(@AsOfDate),
                ((DATEPART(QUARTER,@AsOfDate)-1)*3)+1, 1), 23));
    SET @Result = REPLACE(@Result, '{{QUARTER_END}}',
        CONVERT(NVARCHAR(10),
            EOMONTH(DATEFROMPARTS(YEAR(@AsOfDate),
                DATEPART(QUARTER,@AsOfDate)*3, 1)), 23));

    -- Previous quarter
    SET @Result = REPLACE(@Result, '{{PREV_QUARTER_START}}',
        CONVERT(NVARCHAR(10),
            DATEFROMPARTS(
                YEAR(DATEADD(QUARTER,-1,@AsOfDate)),
                ((DATEPART(QUARTER,DATEADD(QUARTER,-1,@AsOfDate))-1)*3)+1,
                1), 23));
    SET @Result = REPLACE(@Result, '{{PREV_QUARTER_END}}',
        CONVERT(NVARCHAR(10),
            EOMONTH(DATEFROMPARTS(
                YEAR(DATEADD(QUARTER,-1,@AsOfDate)),
                DATEPART(QUARTER,DATEADD(QUARTER,-1,@AsOfDate))*3,
                1)), 23));

    -- Year
    SET @Result = REPLACE(@Result, '{{YEAR}}',       CAST(YEAR(@AsOfDate)   AS NVARCHAR(4)));
    SET @Result = REPLACE(@Result, '{{YEAR_START}}',
        CAST(YEAR(@AsOfDate) AS NVARCHAR(4)) + '-01-01');
    SET @Result = REPLACE(@Result, '{{YEAR_END}}',
        CAST(YEAR(@AsOfDate) AS NVARCHAR(4)) + '-12-31');
    SET @Result = REPLACE(@Result, '{{PREV_YEAR}}',  CAST(YEAR(@AsOfDate)-1 AS NVARCHAR(4)));
    SET @Result = REPLACE(@Result, '{{PREV_YEAR_START}}',
        CAST(YEAR(@AsOfDate)-1 AS NVARCHAR(4)) + '-01-01');
    SET @Result = REPLACE(@Result, '{{PREV_YEAR_END}}',
        CAST(YEAR(@AsOfDate)-1 AS NVARCHAR(4)) + '-12-31');

    -- Dynamic offset tokens {{TODAY-N}} and {{TODAY+N}}
    DECLARE @i INT = 1;
    WHILE @i <= 365
    BEGIN
        IF @Result LIKE '%{{TODAY-' + CAST(@i AS NVARCHAR) + '}}%'
            SET @Result = REPLACE(@Result,
                '{{TODAY-' + CAST(@i AS NVARCHAR) + '}}',
                CONVERT(NVARCHAR(10), DATEADD(DAY,-@i,@AsOfDate), 23));
        IF @Result LIKE '%{{TODAY+' + CAST(@i AS NVARCHAR) + '}}%'
            SET @Result = REPLACE(@Result,
                '{{TODAY+' + CAST(@i AS NVARCHAR) + '}}',
                CONVERT(NVARCHAR(10), DATEADD(DAY,@i,@AsOfDate), 23));
        IF @Result NOT LIKE '%{{TODAY%' BREAK;
        SET @i = @i + 1;
    END;

    RETURN @Result;
END;
GO


-- 2.3  fn_FetchDocumentId
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
--  Subject/Body are in @DispatchJson as subjectSource/subjectSourceValue, bodySource/bodySourceValue
--
--  @DispatchJson       Schedule-level delivery config (separate from fan-out):
--  {
--    "deliveryMethod":    "EMAIL | FOLDER | BOTH",
--    "emailSource":       "STATIC | DYNAMIC_SQL",
--    "emailSourceValue":  "address | view | fn | sql",
--    "folderSource":      "STATIC | DYNAMIC_SQL",
--    "folderSourceValue": "path | view | fn | sql",
--    "fileNameTemplate":  "{{REPORTNAME}}_{{PREV_MONTH_END}}",
--    "fileNameSource":    "STATIC | DYNAMIC_SQL",
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
--      "emailSource":           "STATIC | DYNAMIC_SQL",
--      "emailSourceValue":      "...",
--      "displayNameSource":     "STATIC | DYNAMIC_SQL",
--      "displayNameSourceValue":"...",
--      "fileNameTemplate":      "{{REPORTNAME}}_{{DISPLAYNAME}}_{{PREV_MONTH_END}}",
--      "fileNameSource":        "STATIC | DYNAMIC_SQL",
--      "fileNameSourceValue":   "...",
--      "folderSource":          "STATIC | DYNAMIC_SQL",
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
    @DispatchJson       NVARCHAR(MAX)   = NULL,   -- schedule-level delivery config
    @ParametersJson     NVARCHAR(MAX)   = NULL,
    @RecipientsJson     NVARCHAR(MAX)   = NULL    -- CC/BCC standing recipients only
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
               ModifiedAt = GETDATE()
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
        @pEmailSrc NVARCHAR(20),    @pEmailSrcVal NVARCHAR(MAX),
        @pDisplayNameSrc NVARCHAR(20),    @pDisplayNameSrcVal NVARCHAR(MAX),
        @pFileNameSrc NVARCHAR(20),       @pFileNameSrcVal NVARCHAR(MAX),
        @pFolderSrc NVARCHAR(20),         @pFolderSrcVal NVARCHAR(MAX),
        @pSubjectSrc NVARCHAR(20),        @pSubjectSrcVal NVARCHAR(MAX),
        @pBodySrc NVARCHAR(20),           @pBodySrcVal NVARCHAR(MAX),
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
        SET @pValueQuery  = JSON_VALUE(@pJson,'$.valueQuery');

        SET @pHasDispatch = CASE WHEN JSON_QUERY(@pJson,'$.fanOut') IS NOT NULL THEN 1 ELSE 0 END;
        SET @pIsPrimary         = ISNULL(TRY_CAST(JSON_VALUE(@pJson,'$.fanOut.isPrimary') AS BIT),0);
        SET @pMode              = ISNULL(JSON_VALUE(@pJson,'$.fanOut.mode'),'INDIVIDUAL');
        SET @pEmailSrc          = ISNULL(JSON_VALUE(@pJson,'$.fanOut.emailSource'),'STATIC');
        SET @pEmailSrcVal       = JSON_VALUE(@pJson,'$.fanOut.emailSourceValue');
        SET @pDisplayNameSrc    = JSON_VALUE(@pJson,'$.fanOut.displayNameSource');
        SET @pDisplayNameSrcVal = JSON_VALUE(@pJson,'$.fanOut.displayNameSourceValue');
        SET @pFileNameSrc       = JSON_VALUE(@pJson,'$.fanOut.fileNameSource');
        SET @pFileNameSrcVal    = JSON_VALUE(@pJson,'$.fanOut.fileNameSourceValue');
        -- Backward compat: fileNameTemplate maps to STATIC fileNameSource
        IF @pFileNameSrc IS NULL AND JSON_VALUE(@pJson,'$.fanOut.fileNameTemplate') IS NOT NULL
        BEGIN
            SET @pFileNameSrc    = 'STATIC';
            SET @pFileNameSrcVal = JSON_VALUE(@pJson,'$.fanOut.fileNameTemplate');
        END;
        SET @pFolderSrc         = JSON_VALUE(@pJson,'$.fanOut.folderSource');
        SET @pFolderSrcVal      = JSON_VALUE(@pJson,'$.fanOut.folderSourceValue');
        SET @pSubjectSrc        = JSON_VALUE(@pJson,'$.fanOut.subjectSource');
        SET @pSubjectSrcVal     = JSON_VALUE(@pJson,'$.fanOut.subjectSourceValue');
        SET @pBodySrc           = JSON_VALUE(@pJson,'$.fanOut.bodySource');
        SET @pBodySrcVal        = JSON_VALUE(@pJson,'$.fanOut.bodySourceValue');

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
                       FolderSource          = @pFolderSrc,
                       FolderSourceValue     = @pFolderSrcVal,
                       SubjectSource         = @pSubjectSrc,
                       SubjectSourceValue    = @pSubjectSrcVal,
                       BodySource            = @pBodySrc,
                       BodySourceValue       = @pBodySrcVal
                WHERE  ParameterID=@pParamID;
            ELSE
                INSERT INTO [schdl].[ParameterDispatchConfig]
                    (ParameterID,IsPrimaryDispatchKey,DispatchMode,
                     EmailSource,EmailSourceValue,
                     DisplayNameSource,DisplayNameSourceValue,
                     FileNameSource,FileNameSourceValue,
                     FolderSource,FolderSourceValue,
                     SubjectSource,SubjectSourceValue,
                     BodySource,BodySourceValue)
                VALUES(@pParamID,@pIsPrimary,@pMode,
                       @pEmailSrc,@pEmailSrcVal,
                       @pDisplayNameSrc,@pDisplayNameSrcVal,
                       @pFileNameSrc,@pFileNameSrcVal,
                       @pFolderSrc,@pFolderSrcVal,
                       @pSubjectSrc,@pSubjectSrcVal,
                       @pBodySrc,@pBodySrcVal);
        END;

        SET @pIndex += 1;
    END;

    -- 3. UPSERT Schedule
    DECLARE @ScheduleID INT;
    SET @StartDate = ISNULL(@StartDate, CAST('2000-01-01' AS DATE));

    -- Parse @DispatchJson into schedule-level delivery variables
    DECLARE
        @sDeliveryMethod      NVARCHAR(10)   = ISNULL(JSON_VALUE(@DispatchJson,'$.deliveryMethod'),'EMAIL'),
        @sEmailSource         NVARCHAR(20)   = ISNULL(JSON_VALUE(@DispatchJson,'$.emailSource'),'STATIC'),
        @sEmailSourceValue    NVARCHAR(MAX)  = JSON_VALUE(@DispatchJson,'$.emailSourceValue'),
        @sSubjectSource       NVARCHAR(20)   = ISNULL(JSON_VALUE(@DispatchJson,'$.subjectSource'),'STATIC'),
        @sSubjectSourceValue  NVARCHAR(MAX)  = JSON_VALUE(@DispatchJson,'$.subjectSourceValue'),
        @sBodySource          NVARCHAR(20)   = ISNULL(JSON_VALUE(@DispatchJson,'$.bodySource'),'STATIC'),
        @sBodySourceValue     NVARCHAR(MAX)  = JSON_VALUE(@DispatchJson,'$.bodySourceValue'),
        @sFileNameSource      NVARCHAR(20)   = JSON_VALUE(@DispatchJson,'$.fileNameSource'),
        @sFileNameSourceValue NVARCHAR(MAX)  = JSON_VALUE(@DispatchJson,'$.fileNameSourceValue'),
        @sFolderSource        NVARCHAR(20)   = JSON_VALUE(@DispatchJson,'$.folderSource'),
        @sFolderSourceValue   NVARCHAR(MAX)  = JSON_VALUE(@DispatchJson,'$.folderSourceValue');

    IF EXISTS (SELECT 1 FROM [schdl].[Schedule] WHERE ScheduleName=@ScheduleName)
        UPDATE [schdl].[Schedule]
        SET    ReportID=@DocID,FrequencyType=@FrequencyType,RunTime=@RunTime,
               DayOfWeek=@DayOfWeek,DayOfMonth=@DayOfMonth,IntervalMinutes=@IntervalMinutes,
               WindowStart=@WindowStart,WindowEnd=@WindowEnd,StartDate=@StartDate,
               EndDate=@EndDate,
               DeliveryMethod=@sDeliveryMethod,
               EmailSource=@sEmailSource,EmailSourceValue=@sEmailSourceValue,
               SubjectSource=@sSubjectSource,SubjectSourceValue=@sSubjectSourceValue,
               BodySource=@sBodySource,BodySourceValue=@sBodySourceValue,
               FileNameSource=@sFileNameSource,FileNameSourceValue=@sFileNameSourceValue,
               FolderSource=@sFolderSource,FolderSourceValue=@sFolderSourceValue,
               NextRunAt=NULL,
               ModifiedAt=GETDATE()
        WHERE  ScheduleName=@ScheduleName;
    ELSE
        INSERT INTO [schdl].[Schedule]
            (ScheduleName,ReportID,FrequencyType,RunTime,DayOfWeek,DayOfMonth,
             IntervalMinutes,WindowStart,WindowEnd,StartDate,EndDate,
             DeliveryMethod,EmailSource,EmailSourceValue,
             SubjectSource,SubjectSourceValue,
             BodySource,BodySourceValue,
             FileNameSource,FileNameSourceValue,
             FolderSource,FolderSourceValue)
        VALUES
            (@ScheduleName,@DocID,@FrequencyType,@RunTime,@DayOfWeek,@DayOfMonth,
             @IntervalMinutes,@WindowStart,@WindowEnd,@StartDate,@EndDate,
             @sDeliveryMethod,@sEmailSource,@sEmailSourceValue,
             @sSubjectSource,@sSubjectSourceValue,
             @sBodySource,@sBodySourceValue,
             @sFileNameSource,@sFileNameSourceValue,
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

    -- 5. Standing Recipients (CC/BCC only) — delete and re-insert
    DELETE FROM [schdl].[ScheduleStandingRecipient] WHERE ScheduleID = @ScheduleID;

    IF @RecipientsJson IS NOT NULL AND @RecipientsJson <> '[]'
    BEGIN
        DECLARE
            @rEmail  NVARCHAR(320),
            @rRole   NVARCHAR(5),
            @rFanOut BIT,
            @rIndex  INT = 0,
            @rCount  INT;

        SELECT @rCount = COUNT(*) FROM OPENJSON(@RecipientsJson);

        WHILE @rIndex < @rCount
        BEGIN
            SET @rEmail  = JSON_VALUE(@RecipientsJson, '$['+CAST(@rIndex AS NVARCHAR)+'].email');
            SET @rRole   = ISNULL(JSON_VALUE(@RecipientsJson, '$['+CAST(@rIndex AS NVARCHAR)+'].role'), 'CC');
            SET @rFanOut = ISNULL(
                TRY_CAST(JSON_VALUE(@RecipientsJson, '$['+CAST(@rIndex AS NVARCHAR)+'].includeInFanOut') AS BIT),
                0);

            -- Only CC/BCC go in ScheduleStandingRecipient
            IF @rEmail IS NOT NULL AND LTRIM(RTRIM(@rEmail)) <> '' AND @rRole IN ('CC','BCC')
                INSERT INTO [schdl].[ScheduleStandingRecipient]
                    (ScheduleID, EmailAddress, RecipientRole, IncludeInFanOut)
                VALUES
                    (@ScheduleID, @rEmail, @rRole, @rFanOut);

            SET @rIndex = @rIndex + 1;
        END;
    END;

    COMMIT TRANSACTION;

    -- Return summary
    SELECT
        d.ReportID, d.DocumentName, d.ReportEndpoint,
        s.ScheduleID, s.ScheduleName, s.FrequencyType,
        s.RunTime, s.DayOfWeek, s.DayOfMonth, s.IntervalMinutes, s.NextRunAt,
        (SELECT COUNT(*) FROM [schdl].[ScheduleParameter]         WHERE ScheduleID=s.ScheduleID) AS ParameterCount,
        (SELECT COUNT(*) FROM [schdl].[ScheduleStandingRecipient] WHERE ScheduleID=s.ScheduleID) AS RecipientCount,
        (SELECT COUNT(*) FROM [schdl].[ParameterDispatchConfig] dc
            JOIN [schdl].[DocumentParameter] dp ON dp.ParameterID=dc.ParameterID
         WHERE dp.ReportID=d.ReportID)                                                           AS DispatchConfigCount,
        [schdl].[fn_FetchDocumentId](d.DocumentName)                                             AS ResolvedDocumentId
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
    DECLARE @Today DATE = CAST(ISNULL(@AsOf,GETDATE()) AS DATE);

    DECLARE
        @DocID INT, @DocumentName NVARCHAR(255),
        @OutputFormat NVARCHAR(20), @Language INT,
        @Confidentiality NVARCHAR(50),
        -- Schedule-level delivery config
        @sDeliveryMethod      NVARCHAR(10),
        @sEmailSource         NVARCHAR(20),
        @sEmailSourceValue    NVARCHAR(MAX),
        @sSubjectSource       NVARCHAR(20),
        @sSubjectSourceValue  NVARCHAR(MAX),
        @sBodySource          NVARCHAR(20),
        @sBodySourceValue     NVARCHAR(MAX),
        @sFileNameSource      NVARCHAR(20),
        @sFileNameSourceValue NVARCHAR(MAX),
        @sFolderSource        NVARCHAR(20),
        @sFolderSourceValue   NVARCHAR(MAX);

    SELECT
        @DocID                = d.ReportID,
        @DocumentName         = d.DocumentName,
        @OutputFormat         = d.DefaultOutputFormat,
        @Language             = d.DefaultLanguage,
        @Confidentiality      = d.DefaultConfidentiality,
        @sDeliveryMethod      = ISNULL(s.DeliveryMethod, 'EMAIL'),
        @sEmailSource         = s.EmailSource,
        @sEmailSourceValue    = s.EmailSourceValue,
        @sSubjectSource       = s.SubjectSource,
        @sSubjectSourceValue  = s.SubjectSourceValue,
        @sBodySource          = s.BodySource,
        @sBodySourceValue     = s.BodySourceValue,
        @sFileNameSource      = s.FileNameSource,
        @sFileNameSourceValue = s.FileNameSourceValue,
        @sFolderSource        = s.FolderSource,
        @sFolderSourceValue   = s.FolderSourceValue
    FROM [schdl].[Schedule] s
    JOIN [schdl].[Document] d ON d.ReportID=s.ReportID
    WHERE s.ScheduleID=@ScheduleID;

    -- Resolve DocumentID
    DECLARE @ResolvedDocId NVARCHAR(100) = [schdl].[fn_FetchDocumentId](@DocumentName);

    -- ── Helper: resolve a single string field (STATIC or DYNAMIC_SQL) ─────────
    -- Used inline below for each field. No cursor needed for single-value fields.

    -- ── Step 1: Resolve dynamic parameter values ───────────────────────────────
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
        SET @aggSQL =
            N'SELECT @r = STRING_AGG([Value], ''|'')' +
            N' WITHIN GROUP (ORDER BY [Value]) FROM (' + @dvQuery + N') AS _q';
        BEGIN TRY
            EXEC sp_executesql @aggSQL, N'@r NVARCHAR(MAX) OUTPUT', @r = @dvResult OUTPUT;
        END TRY
        BEGIN CATCH
            -- Dynamic query failed — fail entire schedule
            UPDATE [schdl].[ExecutionLog]
            SET    Status='FAILED',
                   ErrorMessage='ParameterValueQuery failed for ParameterID '
                       + CAST(@dvParamID AS NVARCHAR) + ': ' + ERROR_MESSAGE()
            WHERE  LogID=@LogID;
            DELETE FROM [schdl].[DispatchQueue] WHERE LogID=@LogID;
            RETURN;
        END CATCH;

        IF @dvResult IS NULL
        BEGIN
            UPDATE [schdl].[ExecutionLog]
            SET    Status='FAILED',
                   ErrorMessage='ParameterValueQuery returned no rows for ParameterID '
                       + CAST(@dvParamID AS NVARCHAR)
            WHERE  LogID=@LogID;
            DELETE FROM [schdl].[DispatchQueue] WHERE LogID=@LogID;
            RETURN;
        END;

        INSERT INTO #DynVals (ParameterID, ResolvedValue) VALUES (@dvParamID, @dvResult);
        FETCH NEXT FROM dv_cur INTO @dvParamID, @dvQuery, @dvStatic;
    END;
    CLOSE dv_cur; DEALLOCATE dv_cur;

    -- ── Step 2: Resolve and shred parameter values ────────────────────────────
    DROP TABLE IF EXISTS #Raw;
    SELECT
        dp.ParameterID,
        dp.ParameterName,
        dp.DataType,
        dp.IsRequired,
        dp.SortOrder,
        ISNULL(dc.IsPrimaryDispatchKey, 0)      AS IsPrimary,
        ISNULL(dc.DispatchMode, 'COMBINED')     AS DispatchMode,
        dc.EmailSource,         dc.EmailSourceValue,
        dc.DisplayNameSource,   dc.DisplayNameSourceValue,
        dc.FileNameSource,      dc.FileNameSourceValue,
        dc.FolderSource,        dc.FolderSourceValue,
        dc.SubjectSource,       dc.SubjectSourceValue,
        dc.BodySource,          dc.BodySourceValue,
        CASE
            WHEN dp.DataType = 'date'
            THEN [schdl].[fn_ResolveDateToken](TRIM(seg.value), @Today)
            ELSE TRIM(seg.value)
        END                                       AS ResolvedSegment
    INTO #Raw
    FROM   [schdl].[ScheduleParameter]            sp
    JOIN   [schdl].[DocumentParameter]            dp  ON dp.ParameterID  = sp.ParameterID
    LEFT   JOIN [schdl].[ParameterDispatchConfig]  dc ON dc.ParameterID  = dp.ParameterID
    CROSS  APPLY (
        SELECT ISNULL(dv.ResolvedValue, sp.ParameterValue) AS EffectiveValue
        FROM   (SELECT NULL AS _) AS _dummy
        LEFT   JOIN #DynVals dv ON dv.ParameterID = sp.ParameterID
    ) ev
    CROSS  APPLY STRING_SPLIT(ev.EffectiveValue, '|') seg
    WHERE  sp.ScheduleID = @ScheduleID;

    DROP TABLE IF EXISTS #DynVals;

    DROP TABLE IF EXISTS #P;
    SELECT
        ParameterID, ParameterName, DataType, IsRequired, SortOrder,
        IsPrimary, DispatchMode,
        EmailSource,       EmailSourceValue,
        DisplayNameSource, DisplayNameSourceValue,
        FileNameSource,    FileNameSourceValue,
        FolderSource,      FolderSourceValue,
        SubjectSource,     SubjectSourceValue,
        BodySource,        BodySourceValue,
        STRING_AGG(ResolvedSegment, '|') WITHIN GROUP (ORDER BY ResolvedSegment) AS ResolvedValue
    INTO #P
    FROM  #Raw
    GROUP BY ParameterID, ParameterName, DataType, IsRequired, SortOrder,
             IsPrimary, DispatchMode,
             EmailSource, EmailSourceValue,
             DisplayNameSource, DisplayNameSourceValue,
             FileNameSource, FileNameSourceValue,
             FolderSource, FolderSourceValue,
             SubjectSource, SubjectSourceValue,
             BodySource, BodySourceValue;

    DROP TABLE IF EXISTS #Raw;

    -- ── Standing CC/BCC recipients ────────────────────────────────────────────
    DECLARE
        @CcAll    NVARCHAR(MAX),  @CcFanOut  NVARCHAR(MAX),
        @BccAll   NVARCHAR(MAX),  @BccFanOut NVARCHAR(MAX);

    SELECT @CcAll    = STRING_AGG(EmailAddress, ',') WITHIN GROUP (ORDER BY EmailAddress)
    FROM   [schdl].[ScheduleStandingRecipient]
    WHERE  ScheduleID = @ScheduleID AND RecipientRole = 'CC';

    SELECT @CcFanOut = STRING_AGG(EmailAddress, ',') WITHIN GROUP (ORDER BY EmailAddress)
    FROM   [schdl].[ScheduleStandingRecipient]
    WHERE  ScheduleID = @ScheduleID AND RecipientRole = 'CC' AND IncludeInFanOut = 1;

    SELECT @BccAll   = STRING_AGG(EmailAddress, ',') WITHIN GROUP (ORDER BY EmailAddress)
    FROM   [schdl].[ScheduleStandingRecipient]
    WHERE  ScheduleID = @ScheduleID AND RecipientRole = 'BCC';

    SELECT @BccFanOut = STRING_AGG(EmailAddress, ',') WITHIN GROUP (ORDER BY EmailAddress)
    FROM   [schdl].[ScheduleStandingRecipient]
    WHERE  ScheduleID = @ScheduleID AND RecipientRole = 'BCC' AND IncludeInFanOut = 1;

    -- ── Inline resolver helper (used multiple times below) ────────────────────
    -- Resolves a STATIC or DYNAMIC_SQL source into a string value.
    -- @src, @srcVal in → @out out. {VALUE} substituted with @fanoutVal if provided.
    -- After resolution, fn_ResolveAllTokens is applied and {{DISPLAYNAME}} substituted.

    -- ── NO PARAMETERS — emit one COMBINED row ─────────────────────────────────
    IF NOT EXISTS (SELECT 1 FROM #P)
    BEGIN
        DECLARE
            @npTo       NVARCHAR(MAX),
            @npSubject  NVARCHAR(MAX),
            @npBody     NVARCHAR(MAX),
            @npFolder   NVARCHAR(MAX),
            @npFileName NVARCHAR(MAX),
            @npDynSQL   NVARCHAR(MAX);

        -- Resolve TO email
        IF @sDeliveryMethod IN ('EMAIL','BOTH')
        BEGIN
            IF @sEmailSource = 'STATIC'
                SET @npTo = @sEmailSourceValue;
            ELSE IF @sEmailSource = 'DYNAMIC_SQL' AND ISNULL(@sEmailSourceValue,'') <> ''
            BEGIN
                -- STRING_AGG handles both single and multiple row results
                SET @npDynSQL = N'SELECT @e = STRING_AGG(EmailAddress, '','') WITHIN GROUP (ORDER BY EmailAddress) FROM (' + @sEmailSourceValue + N') AS _q';
                EXEC sp_executesql @npDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@npTo OUTPUT;
            END;
        END;

        -- Resolve Subject
        IF @sSubjectSource = 'STATIC'
            SET @npSubject = @sSubjectSourceValue;
        ELSE IF @sSubjectSource = 'DYNAMIC_SQL' AND ISNULL(@sSubjectSourceValue,'') <> ''
        BEGIN
            SET @npDynSQL = N'SELECT TOP 1 @e = Subject FROM (' + @sSubjectSourceValue + N') AS _q';
            EXEC sp_executesql @npDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@npSubject OUTPUT;
        END;

        -- Resolve Body
        IF @sBodySource = 'STATIC'
            SET @npBody = @sBodySourceValue;
        ELSE IF @sBodySource = 'DYNAMIC_SQL' AND ISNULL(@sBodySourceValue,'') <> ''
        BEGIN
            SET @npDynSQL = N'SELECT TOP 1 @e = Body FROM (' + @sBodySourceValue + N') AS _q';
            EXEC sp_executesql @npDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@npBody OUTPUT;
        END;

        -- Resolve FileName
        IF @sFileNameSource = 'STATIC'
            SET @npFileName = @sFileNameSourceValue;
        ELSE IF @sFileNameSource = 'DYNAMIC_SQL' AND ISNULL(@sFileNameSourceValue,'') <> ''
        BEGIN
            SET @npDynSQL = N'SELECT TOP 1 @e = FileName FROM (' + @sFileNameSourceValue + N') AS _q';
            EXEC sp_executesql @npDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@npFileName OUTPUT;
        END;

        -- Resolve FolderPath
        IF @sFolderSource = 'STATIC'
            SET @npFolder = @sFolderSourceValue;
        ELSE IF @sFolderSource = 'DYNAMIC_SQL' AND ISNULL(@sFolderSourceValue,'') <> ''
        BEGIN
            SET @npDynSQL = N'SELECT TOP 1 @e = FolderPath FROM (' + @sFolderSourceValue + N') AS _q';
            EXEC sp_executesql @npDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@npFolder OUTPUT;
        END;

        -- Apply token resolution to all string fields
        SET @npSubject  = [schdl].[fn_ResolveAllTokens](@npSubject,  @Today, @DocumentName);
        SET @npBody     = [schdl].[fn_ResolveAllTokens](@npBody,     @Today, @DocumentName);
        SET @npFileName = [schdl].[fn_ResolveAllTokens](@npFileName, @Today, @DocumentName);
        SET @npFolder   = [schdl].[fn_ResolveAllTokens](@npFolder,   @Today, @DocumentName);

        DECLARE @npReqJson NVARCHAR(MAX) =
            '{"documentId":"' + ISNULL(@ResolvedDocId,'') +
            '","outputFormat":"' + @OutputFormat +
            '","language":' + CAST(@Language AS NVARCHAR) +
            ',"parameters":[]' +
            ',"confidentiality":"' + @Confidentiality + '"}'  ;

        INSERT INTO [schdl].[DispatchQueue]
            (LogID,ScheduleID,DispatchType,DeliveryMethod,DispatchKeyValue,
             DisplayName,FileName,RequestJson,
             ToAddresses,CcAddresses,BccAddresses,EmailSubject,EmailBody,FolderPath)
        VALUES
            (@LogID,@ScheduleID,'COMBINED',@sDeliveryMethod,NULL,
             NULL,@npFileName,@npReqJson,
             ISNULL(@npTo,''),@CcAll,@BccAll,@npSubject,@npBody,@npFolder);

        UPDATE [schdl].[ExecutionLog] SET Status='PENDING' WHERE LogID=@LogID;
        RETURN;
    END;

    -- ── HAS PARAMETERS ────────────────────────────────────────────────────────

    DECLARE
        @PrimID         INT,  @PrimName       NVARCHAR(100),
        @PrimMode       NVARCHAR(12),
        @PrimEmailSrc   NVARCHAR(20),  @PrimEmailSrcVal   NVARCHAR(MAX),
        @PrimDNSrc      NVARCHAR(20),  @PrimDNSrcVal      NVARCHAR(MAX),
        @PrimFNSrc      NVARCHAR(20),  @PrimFNSrcVal      NVARCHAR(MAX),
        @PrimFolSrc     NVARCHAR(20),  @PrimFolSrcVal     NVARCHAR(MAX),
        @PrimSubjSrc    NVARCHAR(20),  @PrimSubjSrcVal    NVARCHAR(MAX),
        @PrimBodySrc    NVARCHAR(20),  @PrimBodySrcVal    NVARCHAR(MAX);

    SELECT TOP 1
        @PrimID        = ParameterID,   @PrimName      = ParameterName,
        @PrimMode      = DispatchMode,
        @PrimEmailSrc  = EmailSource,   @PrimEmailSrcVal   = EmailSourceValue,
        @PrimDNSrc     = DisplayNameSource, @PrimDNSrcVal  = DisplayNameSourceValue,
        @PrimFNSrc     = FileNameSource,    @PrimFNSrcVal  = FileNameSourceValue,
        @PrimFolSrc    = FolderSource,      @PrimFolSrcVal = FolderSourceValue,
        @PrimSubjSrc   = SubjectSource,     @PrimSubjSrcVal= SubjectSourceValue,
        @PrimBodySrc   = BodySource,        @PrimBodySrcVal= BodySourceValue
    FROM #P WHERE IsPrimary=1;

    IF @PrimID IS NULL
    BEGIN
        SELECT TOP 1
            @PrimID   = ParameterID,
            @PrimName = ParameterName
        FROM #P ORDER BY SortOrder;
        SET @PrimMode = 'COMBINED';
    END;

    DROP TABLE IF EXISTS #PV;
    SELECT TRIM(value) AS DispatchValue
    INTO   #PV
    FROM   #P
    CROSS  APPLY STRING_SPLIT(ResolvedValue, '|')
    WHERE  ParameterID = @PrimID;

    -- Build non-primary parameter JSON
    DROP TABLE IF EXISTS #NP;
    SELECT
        p.ParameterID, p.ParameterName, p.DataType, p.IsRequired, p.SortOrder, p.ResolvedValue,
        STRING_AGG('"' + STRING_ESCAPE(TRIM(seg.value), 'json') + '"', ',')
            WITHIN GROUP (ORDER BY seg.value) AS ValuesJson
    INTO #NP
    FROM   #P p
    CROSS  APPLY STRING_SPLIT(p.ResolvedValue, '|') seg
    WHERE  p.ParameterID <> @PrimID
    GROUP BY p.ParameterID, p.ParameterName, p.DataType, p.IsRequired, p.SortOrder, p.ResolvedValue;

    UPDATE #NP SET ValuesJson = '[' + ValuesJson + ']';

    DECLARE @NonPrimArray NVARCHAR(MAX);
    SELECT @NonPrimArray = STRING_AGG(
        '{"name":"' + STRING_ESCAPE(ParameterName, 'json') +
        '","type":"' + DataType +
        '","values":' + ValuesJson +
        ',"multiple":' + CASE WHEN ResolvedValue LIKE '%|%' THEN 'true' ELSE 'false' END +
        ',"required":' + CASE WHEN IsRequired=1 THEN 'true' ELSE 'false' END + '}',
        ','
    ) WITHIN GROUP (ORDER BY SortOrder)
    FROM #NP;
    DROP TABLE IF EXISTS #NP;

    -- ── INDIVIDUAL rows ───────────────────────────────────────────────────────
    IF @PrimMode IN ('INDIVIDUAL','BOTH')
    BEGIN
        DECLARE
            @iVal         NVARCHAR(500),
            @iSafeVal     NVARCHAR(500),
            @iEmail       NVARCHAR(MAX),
            @iDisplayName NVARCHAR(MAX),
            @iFileName    NVARCHAR(MAX),
            @iFolderPath  NVARCHAR(MAX),
            @iSubject     NVARCHAR(MAX),
            @iBody        NVARCHAR(MAX),
            @iDynSQL      NVARCHAR(MAX),
            @iPrimJson    NVARCHAR(MAX),
            @iReqJson     NVARCHAR(MAX);

        DECLARE ic CURSOR LOCAL FAST_FORWARD FOR SELECT DispatchValue FROM #PV;
        OPEN ic; FETCH NEXT FROM ic INTO @iVal;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @iSafeVal = REPLACE(@iVal, N'''', N'''''');

            -- Resolve Email
            SET @iEmail = NULL;
            IF @sDeliveryMethod IN ('EMAIL','BOTH')
            BEGIN
                IF @PrimEmailSrc = 'STATIC'
                    SET @iEmail = @PrimEmailSrcVal;
                ELSE IF @PrimEmailSrc = 'DYNAMIC_SQL' AND ISNULL(@PrimEmailSrcVal,'') <> ''
                BEGIN
                    -- STRING_AGG to handle multiple rows returned by the query
                    SET @iDynSQL = N'SELECT @e = STRING_AGG(EmailAddress, '','') WITHIN GROUP (ORDER BY EmailAddress) FROM (' +
                        REPLACE(@PrimEmailSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iEmail OUTPUT;
                END;
            END;

            -- Resolve DisplayName
            SET @iDisplayName = NULL;
            IF @PrimDNSrc = 'STATIC' SET @iDisplayName = @PrimDNSrcVal;
            ELSE IF @PrimDNSrc = 'DYNAMIC_SQL' AND ISNULL(@PrimDNSrcVal,'') <> ''
            BEGIN
                SET @iDynSQL = N'SELECT TOP 1 @e = DisplayName FROM (' +
                    REPLACE(@PrimDNSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iDisplayName OUTPUT;
            END;

            -- Resolve FileName
            SET @iFileName = NULL;
            IF @PrimFNSrc = 'STATIC'
            BEGIN
                SET @iFileName = @PrimFNSrcVal;
                -- Apply {{DISPLAYNAME}} substitution to static filename
                SET @iFileName = REPLACE(@iFileName, '{{DISPLAYNAME}}', ISNULL(@iDisplayName,''));
                SET @iFileName = [schdl].[fn_ResolveAllTokens](@iFileName, @Today, @DocumentName);
            END
            ELSE IF @PrimFNSrc = 'DYNAMIC_SQL' AND ISNULL(@PrimFNSrcVal,'') <> ''
            BEGIN
                SET @iDynSQL = N'SELECT TOP 1 @e = FileName FROM (' +
                    REPLACE(@PrimFNSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iFileName OUTPUT;
                IF @iFileName IS NOT NULL
                    SET @iFileName = [schdl].[fn_ResolveAllTokens](@iFileName, @Today, @DocumentName);
            END;
            -- Fallback: use schedule-level filename for individual rows if no per-entity filename
            IF @iFileName IS NULL AND @sFileNameSource IS NOT NULL
            BEGIN
                IF @sFileNameSource = 'STATIC'
                BEGIN
                    SET @iFileName = @sFileNameSourceValue;
                    SET @iFileName = REPLACE(@iFileName, '{{DISPLAYNAME}}', ISNULL(@iDisplayName,''));
                    SET @iFileName = [schdl].[fn_ResolveAllTokens](@iFileName, @Today, @DocumentName);
                END
                ELSE IF @sFileNameSource = 'DYNAMIC_SQL' AND ISNULL(@sFileNameSourceValue,'') <> ''
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = FileName FROM (' +
                        REPLACE(@sFileNameSourceValue, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iFileName OUTPUT;
                    IF @iFileName IS NOT NULL
                        SET @iFileName = [schdl].[fn_ResolveAllTokens](@iFileName, @Today, @DocumentName);
                END;
            END;

            -- Resolve FolderPath (per-entity, with fallback to schedule-level)
            SET @iFolderPath = NULL;
            IF @sDeliveryMethod IN ('FOLDER','BOTH')
            BEGIN
                IF @PrimFolSrc = 'STATIC'
                    SET @iFolderPath = @PrimFolSrcVal;
                ELSE IF @PrimFolSrc = 'DYNAMIC_SQL' AND ISNULL(@PrimFolSrcVal,'') <> ''
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = FolderPath FROM (' +
                        REPLACE(@PrimFolSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iFolderPath OUTPUT;
                END;
                -- Fallback to schedule-level folder (INHERIT mode)
                IF @iFolderPath IS NULL AND @sFolderSource IS NOT NULL
                BEGIN
                    IF @sFolderSource = 'STATIC'
                        SET @iFolderPath = @sFolderSourceValue;
                    ELSE IF @sFolderSource = 'DYNAMIC_SQL' AND ISNULL(@sFolderSourceValue,'') <> ''
                    BEGIN
                        SET @iDynSQL = N'SELECT TOP 1 @e = FolderPath FROM (' +
                            REPLACE(@sFolderSourceValue, '{VALUE}', @iSafeVal) + N') AS _q';
                        EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iFolderPath OUTPUT;
                    END;
                END;
                IF @iFolderPath IS NOT NULL
                    SET @iFolderPath = [schdl].[fn_ResolveAllTokens](@iFolderPath, @Today, @DocumentName);
            END;

            -- Resolve Subject (per-entity override, fallback to schedule-level)
            SET @iSubject = NULL;
            IF @PrimSubjSrc = 'STATIC'
                SET @iSubject = @PrimSubjSrcVal;
            ELSE IF @PrimSubjSrc = 'DYNAMIC_SQL' AND ISNULL(@PrimSubjSrcVal,'') <> ''
            BEGIN
                SET @iDynSQL = N'SELECT TOP 1 @e = Subject FROM (' +
                    REPLACE(@PrimSubjSrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iSubject OUTPUT;
            END;
            -- Fallback to schedule-level subject
            IF @iSubject IS NULL
            BEGIN
                IF @sSubjectSource = 'STATIC'
                    SET @iSubject = @sSubjectSourceValue;
                ELSE IF @sSubjectSource = 'DYNAMIC_SQL' AND ISNULL(@sSubjectSourceValue,'') <> ''
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = Subject FROM (' +
                        REPLACE(@sSubjectSourceValue, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iSubject OUTPUT;
                END;
            END;

            -- Resolve Body (per-entity override, fallback to schedule-level)
            SET @iBody = NULL;
            IF @PrimBodySrc = 'STATIC'
                SET @iBody = @PrimBodySrcVal;
            ELSE IF @PrimBodySrc = 'DYNAMIC_SQL' AND ISNULL(@PrimBodySrcVal,'') <> ''
            BEGIN
                SET @iDynSQL = N'SELECT TOP 1 @e = Body FROM (' +
                    REPLACE(@PrimBodySrcVal, '{VALUE}', @iSafeVal) + N') AS _q';
                EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iBody OUTPUT;
            END;
            IF @iBody IS NULL
            BEGIN
                IF @sBodySource = 'STATIC'
                    SET @iBody = @sBodySourceValue;
                ELSE IF @sBodySource = 'DYNAMIC_SQL' AND ISNULL(@sBodySourceValue,'') <> ''
                BEGIN
                    SET @iDynSQL = N'SELECT TOP 1 @e = Body FROM (' +
                        REPLACE(@sBodySourceValue, '{VALUE}', @iSafeVal) + N') AS _q';
                    EXEC sp_executesql @iDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@iBody OUTPUT;
                END;
            END;

            -- Apply token resolution + {{DISPLAYNAME}} substitution to subject/body
            SET @iSubject = [schdl].[fn_ResolveAllTokens](@iSubject, @Today, @DocumentName);
            SET @iSubject = REPLACE(@iSubject, '{{DISPLAYNAME}}', ISNULL(@iDisplayName,''));
            SET @iBody    = [schdl].[fn_ResolveAllTokens](@iBody,    @Today, @DocumentName);
            SET @iBody    = REPLACE(@iBody,    '{{DISPLAYNAME}}', ISNULL(@iDisplayName,''));

            -- Build RequestJson
            SET @iPrimJson =
                '{"name":"' + STRING_ESCAPE(@PrimName,'json') +
                '","type":"string","values":["' + STRING_ESCAPE(@iVal,'json') +
                '"],"multiple":false,"required":true}';

            SET @iReqJson =
                '{"documentId":"' + ISNULL(@ResolvedDocId,'') +
                '","outputFormat":"' + @OutputFormat +
                '","language":' + CAST(@Language AS NVARCHAR) +
                ',"parameters":[' + @iPrimJson + ISNULL(',' + @NonPrimArray,'') +
                '],"confidentiality":"' + @Confidentiality + '"}';

            INSERT INTO [schdl].[DispatchQueue]
                (LogID,ScheduleID,DispatchType,DeliveryMethod,DispatchKeyValue,
                 DisplayName,FileName,RequestJson,
                 ToAddresses,CcAddresses,BccAddresses,EmailSubject,EmailBody,FolderPath)
            VALUES
                (@LogID,@ScheduleID,'INDIVIDUAL',@sDeliveryMethod,@iVal,
                 @iDisplayName,@iFileName,@iReqJson,
                 ISNULL(@iEmail,''),@CcFanOut,@BccFanOut,@iSubject,@iBody,@iFolderPath);

            FETCH NEXT FROM ic INTO @iVal;
        END;
        CLOSE ic; DEALLOCATE ic;
    END;

    -- ── COMBINED row ──────────────────────────────────────────────────────────
    IF @PrimMode IN ('COMBINED','BOTH')
    BEGIN
        DECLARE
            @bVals     NVARCHAR(MAX),
            @bPrimJson NVARCHAR(MAX),
            @bReqJson  NVARCHAR(MAX),
            @bTo       NVARCHAR(MAX),
            @bFileName NVARCHAR(MAX),
            @bFolder   NVARCHAR(MAX),
            @bSubject  NVARCHAR(MAX),
            @bBody     NVARCHAR(MAX),
            @bDynSQL   NVARCHAR(MAX);

        SELECT @bVals = '[' + STRING_AGG('"' + STRING_ESCAPE(DispatchValue,'json') + '"', ',') + ']' FROM #PV;

        SET @bPrimJson =
            '{"name":"' + STRING_ESCAPE(@PrimName,'json') +
            '","type":"string","values":' + @bVals +
            ',"multiple":true,"required":true}';

        SET @bReqJson =
            '{"documentId":"' + ISNULL(@ResolvedDocId,'') +
            '","outputFormat":"' + @OutputFormat +
            '","language":' + CAST(@Language AS NVARCHAR) +
            ',"parameters":[' + @bPrimJson + ISNULL(',' + @NonPrimArray,'') +
            '],"confidentiality":"' + @Confidentiality + '"}';

        -- Resolve combined email
        SET @bTo = NULL;
        IF @sDeliveryMethod IN ('EMAIL','BOTH')
        BEGIN
            IF @sEmailSource = 'STATIC'
                SET @bTo = @sEmailSourceValue;
            ELSE IF @sEmailSource = 'DYNAMIC_SQL' AND ISNULL(@sEmailSourceValue,'') <> ''
            BEGIN
                SET @bDynSQL = N'SELECT @e = STRING_AGG(EmailAddress, '','') WITHIN GROUP (ORDER BY EmailAddress) FROM (' + @sEmailSourceValue + N') AS _q';
                EXEC sp_executesql @bDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@bTo OUTPUT;
            END;
        END;

        -- Resolve combined subject
        SET @bSubject = NULL;
        IF @sSubjectSource = 'STATIC'      SET @bSubject = @sSubjectSourceValue;
        ELSE IF @sSubjectSource = 'DYNAMIC_SQL' AND ISNULL(@sSubjectSourceValue,'') <> ''
        BEGIN
            SET @bDynSQL = N'SELECT TOP 1 @e = Subject FROM (' + @sSubjectSourceValue + N') AS _q';
            EXEC sp_executesql @bDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@bSubject OUTPUT;
        END;

        -- Resolve combined body
        SET @bBody = NULL;
        IF @sBodySource = 'STATIC'      SET @bBody = @sBodySourceValue;
        ELSE IF @sBodySource = 'DYNAMIC_SQL' AND ISNULL(@sBodySourceValue,'') <> ''
        BEGIN
            SET @bDynSQL = N'SELECT TOP 1 @e = Body FROM (' + @sBodySourceValue + N') AS _q';
            EXEC sp_executesql @bDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@bBody OUTPUT;
        END;

        -- Resolve combined filename
        SET @bFileName = NULL;
        IF @sFileNameSource = 'STATIC'
        BEGIN
            SET @bFileName = @sFileNameSourceValue;
            SET @bFileName = REPLACE(@bFileName, '{{DISPLAYNAME}}', '');
            SET @bFileName = [schdl].[fn_ResolveAllTokens](@bFileName, @Today, @DocumentName);
        END
        ELSE IF @sFileNameSource = 'DYNAMIC_SQL' AND ISNULL(@sFileNameSourceValue,'') <> ''
        BEGIN
            SET @bDynSQL = N'SELECT TOP 1 @e = FileName FROM (' + @sFileNameSourceValue + N') AS _q';
            EXEC sp_executesql @bDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@bFileName OUTPUT;
            IF @bFileName IS NOT NULL
                SET @bFileName = [schdl].[fn_ResolveAllTokens](@bFileName, @Today, @DocumentName);
        END;
        -- Fallback: per-entity filename for combined (strip {{DISPLAYNAME}})
        IF @bFileName IS NULL AND @PrimFNSrc IS NOT NULL
        BEGIN
            IF @PrimFNSrc = 'STATIC'
            BEGIN
                SET @bFileName = REPLACE(@PrimFNSrcVal, '{{DISPLAYNAME}}', '');
                SET @bFileName = [schdl].[fn_ResolveAllTokens](@bFileName, @Today, @DocumentName);
            END;
        END;

        -- Resolve combined folder
        SET @bFolder = NULL;
        IF @sDeliveryMethod IN ('FOLDER','BOTH')
        BEGIN
            IF @sFolderSource = 'STATIC'
                SET @bFolder = @sFolderSourceValue;
            ELSE IF @sFolderSource = 'DYNAMIC_SQL' AND ISNULL(@sFolderSourceValue,'') <> ''
            BEGIN
                SET @bDynSQL = N'SELECT TOP 1 @e = FolderPath FROM (' + @sFolderSourceValue + N') AS _q';
                EXEC sp_executesql @bDynSQL, N'@e NVARCHAR(MAX) OUTPUT', @e=@bFolder OUTPUT;
            END;
            IF @bFolder IS NOT NULL
                SET @bFolder = [schdl].[fn_ResolveAllTokens](@bFolder, @Today, @DocumentName);
        END;

        -- Apply token resolution to subject/body
        SET @bSubject = [schdl].[fn_ResolveAllTokens](@bSubject, @Today, @DocumentName);
        SET @bBody    = [schdl].[fn_ResolveAllTokens](@bBody,    @Today, @DocumentName);

        INSERT INTO [schdl].[DispatchQueue]
            (LogID,ScheduleID,DispatchType,DeliveryMethod,DispatchKeyValue,
             DisplayName,FileName,RequestJson,
             ToAddresses,CcAddresses,BccAddresses,EmailSubject,EmailBody,FolderPath)
        VALUES
            (@LogID,@ScheduleID,'COMBINED',@sDeliveryMethod,NULL,
             NULL,@bFileName,@bReqJson,
             ISNULL(@bTo,''),@CcAll,@BccAll,@bSubject,@bBody,@bFolder);
    END;

    UPDATE [schdl].[ExecutionLog] SET Status='PENDING' WHERE LogID=@LogID;
END;
GO


-- 4.2  usp_GetDueSchedules  (Flowgear calls this on its cron)
CREATE PROCEDURE [schdl].[usp_GetDueSchedules]
    @AsOf DATETIME2 = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2=ISNULL(@AsOf,GETDATE());
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
        s.ScheduleName,dq.DeliveryMethod,d.DocumentName,d.ReportEndpoint,
        dq.DispatchType,dq.DispatchKeyValue,dq.RequestJson,
        dq.ToAddresses,dq.CcAddresses,dq.BccAddresses,
        dq.EmailSubject,dq.EmailBody,dq.FolderPath, dq.FileName
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
    @Status       NVARCHAR(20),   -- SENT | SUCCESS | FAILED | SKIPPED
    @ErrorMessage NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE [schdl].[DispatchQueue]
    SET    Status=@Status,ErrorMessage=@ErrorMessage,ProcessedAt=GETDATE()
    WHERE  QueueID=@QueueID;

    UPDATE el SET
        el.Status=CASE WHEN EXISTS(SELECT 1 FROM [schdl].[DispatchQueue] d2
                                   WHERE d2.LogID=el.LogID AND d2.Status='FAILED')
                       THEN 'FAILED' ELSE 'SUCCESS' END,
        el.ProcessedAt=GETDATE()
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
        @DeliveryMethod         NVARCHAR(10),
        @EmailSource            NVARCHAR(20),
        @EmailSourceValue       NVARCHAR(MAX),
        @SubjectSource          NVARCHAR(20),
        @SubjectSourceValue     NVARCHAR(MAX),
        @BodySource             NVARCHAR(20),
        @BodySourceValue        NVARCHAR(MAX),
        @FileNameSource         NVARCHAR(20),
        @FileNameSourceValue    NVARCHAR(MAX),
        @FolderSource           NVARCHAR(20),
        @FolderSourceValue      NVARCHAR(MAX);

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
        @DeliveryMethod      = ISNULL(s.DeliveryMethod, 'EMAIL'),
        @EmailSource         = s.EmailSource,
        @EmailSourceValue    = s.EmailSourceValue,
        @SubjectSource       = s.SubjectSource,
        @SubjectSourceValue  = s.SubjectSourceValue,
        @BodySource          = s.BodySource,
        @BodySourceValue     = s.BodySourceValue,
        @FileNameSource      = s.FileNameSource,
        @FileNameSourceValue = s.FileNameSourceValue,
        @FolderSource        = s.FolderSource,
        @FolderSourceValue   = s.FolderSourceValue
    FROM [schdl].[Schedule] s
    JOIN [schdl].[Document] d ON d.ReportID = s.ReportID
    WHERE s.ScheduleName = @ScheduleName;

    IF @ScheduleID IS NULL
    BEGIN
        SELECT 'ERROR' AS Result, 'Schedule not found: ' + @ScheduleName AS Message;
        RETURN;
    END;

    -- Build @DispatchJson
    DECLARE @DispatchJson NVARCHAR(MAX) = '{';
    SET @DispatchJson += '"deliveryMethod":"' + STRING_ESCAPE(@DeliveryMethod,'json') + '"';
    IF @EmailSource IS NOT NULL
        SET @DispatchJson += ',"emailSource":"' + STRING_ESCAPE(@EmailSource,'json') + '"';
    IF @EmailSourceValue IS NOT NULL
        SET @DispatchJson += ',"emailSourceValue":"' + STRING_ESCAPE(@EmailSourceValue,'json') + '"';
    IF @SubjectSource IS NOT NULL
        SET @DispatchJson += ',"subjectSource":"' + STRING_ESCAPE(@SubjectSource,'json') + '"';
    IF @SubjectSourceValue IS NOT NULL
        SET @DispatchJson += ',"subjectSourceValue":"' + STRING_ESCAPE(@SubjectSourceValue,'json') + '"';
    IF @BodySource IS NOT NULL
        SET @DispatchJson += ',"bodySource":"' + STRING_ESCAPE(@BodySource,'json') + '"';
    IF @BodySourceValue IS NOT NULL
        SET @DispatchJson += ',"bodySourceValue":"' + STRING_ESCAPE(@BodySourceValue,'json') + '"';
    IF @FileNameSource IS NOT NULL
        SET @DispatchJson += ',"fileNameSource":"' + STRING_ESCAPE(@FileNameSource,'json') + '"';
    IF @FileNameSourceValue IS NOT NULL
        SET @DispatchJson += ',"fileNameSourceValue":"' + STRING_ESCAPE(@FileNameSourceValue,'json') + '"';
    IF @FolderSource IS NOT NULL
        SET @DispatchJson += ',"folderSource":"' + STRING_ESCAPE(@FolderSource,'json') + '"';
    IF @FolderSourceValue IS NOT NULL
        SET @DispatchJson += ',"folderSourceValue":"' + STRING_ESCAPE(@FolderSourceValue,'json') + '"';
    SET @DispatchJson += '}';

    -- Build @ParametersJson
    DECLARE @ParametersJson NVARCHAR(MAX) = '';
    DECLARE
        @pID INT, @pName NVARCHAR(100), @pType NVARCHAR(50), @pRequired BIT,
        @pSort INT, @pValue NVARCHAR(MAX), @pVQ NVARCHAR(MAX),
        @pHasDC BIT, @pIsPrimary BIT, @pMode NVARCHAR(12),
        @pEmailSrc NVARCHAR(20),   @pEmailSrcVal NVARCHAR(MAX),
        @pDNSrc NVARCHAR(20),      @pDNSrcVal NVARCHAR(MAX),
        @pFNSrc NVARCHAR(20),      @pFNSrcVal NVARCHAR(MAX),
        @pFolSrc NVARCHAR(20),     @pFolSrcVal NVARCHAR(MAX),
        @pSubjSrc NVARCHAR(20),    @pSubjSrcVal NVARCHAR(MAX),
        @pBodySrc NVARCHAR(20),    @pBodySrcVal NVARCHAR(MAX),
        @pFirst BIT = 1,           @pChunk NVARCHAR(MAX);

    DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            dp.ParameterID, dp.ParameterName, dp.DataType, dp.IsRequired, dp.SortOrder,
            sp.ParameterValue, sp.ParameterValueQuery,
            CASE WHEN dc.ConfigID IS NOT NULL THEN 1 ELSE 0 END,
            ISNULL(dc.IsPrimaryDispatchKey, 0), dc.DispatchMode,
            dc.EmailSource, dc.EmailSourceValue,
            dc.DisplayNameSource, dc.DisplayNameSourceValue,
            dc.FileNameSource, dc.FileNameSourceValue,
            dc.FolderSource, dc.FolderSourceValue,
            dc.SubjectSource, dc.SubjectSourceValue,
            dc.BodySource, dc.BodySourceValue
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
        @pFNSrc, @pFNSrcVal, @pFolSrc, @pFolSrcVal,
        @pSubjSrc, @pSubjSrcVal, @pBodySrc, @pBodySrcVal;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @pFirst = 0 SET @ParametersJson += ',';
        SET @pFirst = 0;

        SET @pChunk  = '{';
        SET @pChunk += '"name":"' + STRING_ESCAPE(@pName,'json') + '"';
        SET @pChunk += ',"type":"' + STRING_ESCAPE(@pType,'json') + '"';
        SET @pChunk += ',"required":' + CASE WHEN @pRequired=1 THEN 'true' ELSE 'false' END;
        SET @pChunk += ',"sortOrder":' + CAST(@pSort AS NVARCHAR);
        SET @pChunk += ',"value":"' + STRING_ESCAPE(ISNULL(@pValue,''),'json') + '"';
        IF @pVQ IS NOT NULL
            SET @pChunk += ',"valueQuery":"' + STRING_ESCAPE(@pVQ,'json') + '"';

        IF @pHasDC = 1 AND @pIsPrimary = 1
        BEGIN
            SET @pChunk += ',"fanOut":{';
            SET @pChunk += '"isPrimary":true';
            SET @pChunk += ',"mode":"' + STRING_ESCAPE(ISNULL(@pMode,'INDIVIDUAL'),'json') + '"';
            IF @pEmailSrc IS NOT NULL
                SET @pChunk += ',"emailSource":"' + STRING_ESCAPE(@pEmailSrc,'json') + '"';
            IF @pEmailSrcVal IS NOT NULL
                SET @pChunk += ',"emailSourceValue":"' + STRING_ESCAPE(@pEmailSrcVal,'json') + '"';
            IF @pDNSrc IS NOT NULL
                SET @pChunk += ',"displayNameSource":"' + STRING_ESCAPE(@pDNSrc,'json') + '"';
            IF @pDNSrcVal IS NOT NULL
                SET @pChunk += ',"displayNameSourceValue":"' + STRING_ESCAPE(@pDNSrcVal,'json') + '"';
            IF @pFNSrc IS NOT NULL
                SET @pChunk += ',"fileNameSource":"' + STRING_ESCAPE(@pFNSrc,'json') + '"';
            IF @pFNSrcVal IS NOT NULL
                SET @pChunk += ',"fileNameSourceValue":"' + STRING_ESCAPE(@pFNSrcVal,'json') + '"';
            IF @pFolSrc IS NOT NULL
                SET @pChunk += ',"folderSource":"' + STRING_ESCAPE(@pFolSrc,'json') + '"';
            IF @pFolSrcVal IS NOT NULL
                SET @pChunk += ',"folderSourceValue":"' + STRING_ESCAPE(@pFolSrcVal,'json') + '"';
            IF @pSubjSrc IS NOT NULL
                SET @pChunk += ',"subjectSource":"' + STRING_ESCAPE(@pSubjSrc,'json') + '"';
            IF @pSubjSrcVal IS NOT NULL
                SET @pChunk += ',"subjectSourceValue":"' + STRING_ESCAPE(@pSubjSrcVal,'json') + '"';
            IF @pBodySrc IS NOT NULL
                SET @pChunk += ',"bodySource":"' + STRING_ESCAPE(@pBodySrc,'json') + '"';
            IF @pBodySrcVal IS NOT NULL
                SET @pChunk += ',"bodySourceValue":"' + STRING_ESCAPE(@pBodySrcVal,'json') + '"';
            SET @pChunk += '}';
        END;

        SET @pChunk += '}';
        SET @ParametersJson += @pChunk;

        FETCH NEXT FROM pc INTO
            @pID, @pName, @pType, @pRequired, @pSort, @pValue, @pVQ,
            @pHasDC, @pIsPrimary, @pMode,
            @pEmailSrc, @pEmailSrcVal, @pDNSrc, @pDNSrcVal,
            @pFNSrc, @pFNSrcVal, @pFolSrc, @pFolSrcVal,
            @pSubjSrc, @pSubjSrcVal, @pBodySrc, @pBodySrcVal;
    END;
    CLOSE pc; DEALLOCATE pc;

    SET @ParametersJson = '[' + @ParametersJson + ']';

    -- Build @RecipientsJson from ScheduleStandingRecipient (CC/BCC only)
    DECLARE @RecipientsJson NVARCHAR(MAX);
    SELECT @RecipientsJson =
        ISNULL(
            '[' +
            STRING_AGG(
                '{"email":"' + STRING_ESCAPE(EmailAddress,'json') +
                '","role":"' + RecipientRole +
                '","includeInFanOut":' + CASE WHEN IncludeInFanOut=1 THEN 'true' ELSE 'false' END + '}',
                ','
            ) WITHIN GROUP (ORDER BY RecipientRole, EmailAddress)
            + ']',
        '[]')
    FROM [schdl].[ScheduleStandingRecipient]
    WHERE ScheduleID = @ScheduleID;

    -- Build RegisterSQL
    DECLARE @RegisterSQL NVARCHAR(MAX);
    SET @RegisterSQL  = 'EXEC [schdl].[usp_RegisterSchedule]' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @DocumentName    = N''' + REPLACE(@DocumentName,   '''','''''') + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @ReportEndpoint  = N''' + REPLACE(@ReportEndpoint, '''','''''') + ''',' + CHAR(13)+CHAR(10);
    IF @OutputFormat <> 'xlsx'
        SET @RegisterSQL += '    @OutputFormat    = ''' + @OutputFormat + ''',' + CHAR(13)+CHAR(10);
    IF @Language <> 1
        SET @RegisterSQL += '    @Language        = ' + CAST(@Language AS NVARCHAR) + ',' + CHAR(13)+CHAR(10);
    IF @Confidentiality <> 'normal'
        SET @RegisterSQL += '    @Confidentiality = ''' + @Confidentiality + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @ScheduleName    = N''' + REPLACE(@ScheduleName,   '''','''''') + ''',' + CHAR(13)+CHAR(10);
    SET @RegisterSQL += '    @FrequencyType   = ''' + @FrequencyType + ''',' + CHAR(13)+CHAR(10);
    IF @RunTime IS NOT NULL
        SET @RegisterSQL += '    @RunTime         = ''' + CONVERT(NVARCHAR(8),@RunTime,108) + ''',' + CHAR(13)+CHAR(10);
    IF @DayOfWeek IS NOT NULL
        SET @RegisterSQL += '    @DayOfWeek       = ' + CAST(@DayOfWeek AS NVARCHAR) + ',' + CHAR(13)+CHAR(10);
    IF @DayOfMonth IS NOT NULL
        SET @RegisterSQL += '    @DayOfMonth      = ' + CAST(@DayOfMonth AS NVARCHAR) + ',' + CHAR(13)+CHAR(10);
    IF @IntervalMinutes IS NOT NULL
        SET @RegisterSQL += '    @IntervalMinutes = ' + CAST(@IntervalMinutes AS NVARCHAR) + ',' + CHAR(13)+CHAR(10);
    IF @WindowStart IS NOT NULL
        SET @RegisterSQL += '    @WindowStart     = ''' + CONVERT(NVARCHAR(8),@WindowStart,108) + ''',' + CHAR(13)+CHAR(10);
    IF @WindowEnd IS NOT NULL
        SET @RegisterSQL += '    @WindowEnd       = ''' + CONVERT(NVARCHAR(8),@WindowEnd,108) + ''',' + CHAR(13)+CHAR(10);
    IF @StartDate IS NOT NULL AND @StartDate <> '2000-01-01'
        SET @RegisterSQL += '    @StartDate       = ''' + CONVERT(NVARCHAR(10),@StartDate,23) + ''',' + CHAR(13)+CHAR(10);
    IF @EndDate IS NOT NULL
        SET @RegisterSQL += '    @EndDate         = ''' + CONVERT(NVARCHAR(10),@EndDate,23) + ''',' + CHAR(13)+CHAR(10);
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


/*
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
    @DispatchJson   = N'{"deliveryMethod":"BOTH",
                "emailSource":"STATIC","emailSourceValue":"reports-bulk@example.com",
                "subjectSource":"STATIC","subjectSourceValue":"BRM Production Report - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}",
                "bodySource":"STATIC","bodySourceValue":"Please find attached your production report for the previous month."}',
    @ParametersJson = N'[
        {
            "name": "BrokerRelationshipManager",
            "type": "string", "required": true, "sortOrder": 1,
            "value":      "DYNAMIC",
            "valueQuery": "SELECT sBRMCode AS [Value] FROM dbo.BrokerRelationshipManager WHERE bActive = 1 ORDER BY sBRMCode",
            "fanOut": {
                "isPrimary":        true,
                "mode":             "BOTH",
                "emailSource":      "DYNAMIC_SQL",
                "emailSourceValue": "SELECT EmailAddress FROM dbo.BrokerRelationshipManager WHERE sBRMCode = '{VALUE}'"
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
    @DispatchJson   = N'{"deliveryMethod":"BOTH",
                "emailSource":"STATIC","emailSourceValue":"reports-bulk@example.com",
                "subjectSource":"STATIC","subjectSourceValue":"BRM Production Report - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}",
                "bodySource":"STATIC","bodySourceValue":"Please find attached your production report for the previous month."}',
    @ParametersJson = N'[
        {"name":"BrokerRelationshipManager","type":"string","required":true,"sortOrder":1,
            "value":"BRM001|BRM002|BRM003|BRM004|BRM005|BRM006|BRM007|BRM008",
            "fanOut":{"isPrimary":true,"mode":"BOTH",
                "emailSource":"DYNAMIC_SQL",
                "emailSourceValue":"SELECT EmailAddress FROM dbo.BrokerRelationshipManager WHERE sBRMCode = '{VALUE}'"}},
        {"name":"Brokerage",                "type":"string","required":true,"sortOrder":2,"value":"39398|38|39399|39|39400"},
        {"name":"Administrator_HeadOffice", "type":"string","required":true,"sortOrder":3,"value":"39323|2|41085|3|39324"},
        {"name":"CaptureDateTo",            "type":"date",  "required":true,"sortOrder":4,"value":"{{PREV_MONTH_END}}"},
        {"name":"PaymentTerm",              "type":"string","required":true,"sortOrder":5,"value":"0|1|3|4|2"},
        {"name":"Product",                  "type":"string","required":true,"sortOrder":6,"value":"17110|16970"},
        {"name":"CapturedDateFrom",         "type":"date",  "required":true,"sortOrder":7,"value":"{{PREV_MONTH_START}}"}
    ]',
    @RecipientsJson = N'[{"email":"reports-admin@example.com","role":"CC","includeInFanOut":false}]';
GO

-- B: Daily Exception  (BULK, STATIC email)
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName   = 'Daily Exception Report',
    @ReportEndpoint = '/api/reports/generate',
    @ScheduleName   = 'Daily Exception Report - 07:00',
    @FrequencyType  = 'DAILY',
    @RunTime        = '07:00',
    @Subject        = 'Daily Exception Report - {{TODAY}}',
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
            "fanOut":{"isPrimary":true,"mode":"INDIVIDUAL","emailSource":"DYNAMIC_SQL","emailSourceValue":"SELECT EmailAddress FROM dbo.BrokerRelationshipManager WHERE sBRMCode = '{VALUE}'"}
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
--          sr.EmailAddress,
--          sr.RecipientRole,
--          sr.IncludeInFanOut
-- FROM     schdl.ScheduleStandingRecipient  sr
-- JOIN     schdl.Schedule           s  ON s.ScheduleID  = sr.ScheduleID
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
*/
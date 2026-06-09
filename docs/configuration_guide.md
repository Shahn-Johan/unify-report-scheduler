# Scheduling Agent — Configuration Guide

A step-by-step reference for deploying, configuring, and registering
schedules with the SQL Server scheduling agent.

---

## What this system does

Flowgear calls one stored procedure on a cron trigger.
It gets back a flat result set — one row per email to send.
Each row contains a fully built `RequestJson` ready to POST
to the report API, plus resolved recipient addresses.
No branching or ID lookups needed in Flowgear.

```
Flowgear cron trigger
        │
        ▼
EXEC schdl.usp_GetDueSchedules
        │  ├─ resolves documentId      via schdl.fn_FetchDocumentId
        │  ├─ resolves date tokens     via schdl.fn_ResolveDateToken
        │  ├─ resolves email addresses via LOOKUP_VIEW / SCALAR_FN / DYNAMIC_SQL
        │  └─ builds RequestJson per dispatch row
        ▼
Result set: one row per email
        │
        ▼
Flowgear per row:
  1. POST RequestJson → ReportEndpoint   (get report file)
  2. Send email       → ToAddresses / CcAddresses / BccAddresses
  3. EXEC schdl.usp_UpdateDispatchStatus @QueueID, 'SENT'|'FAILED'
```

---

## Step 1 — Deploy the schema

Run `scheduling_agent_v3.sql` against your target database.
The script is a full drop-and-create — safe to re-run at any time.

It creates the following objects in the `sched` schema:

**Tables**

| Table | Purpose |
|---|---|
| `schdl.DateToken` | Reference table of all supported `{{TOKEN}}` strings |
| `schdl.Document` | Catalogue of reportable documents (env-agnostic names) |
| `schdl.DocumentParameter` | Parameter definitions per document |
| `schdl.ParameterDispatchConfig` | Fan-out and email source config per parameter |
| `schdl.Schedule` | Schedule definitions (timing, frequency) |
| `schdl.ScheduleParameter` | Runtime parameter values per schedule |
| `schdl.Recipient` | Static recipient addresses |
| `schdl.ScheduleRecipient` | TO / CC / BCC assignments per schedule |
| `schdl.ExecutionLog` | One row per scheduler execution |
| `schdl.DispatchQueue` | One row per email to send, per execution |

**Functions**

| Function | Purpose |
|---|---|
| `schdl.fn_FetchDocumentId` | Resolves DocumentName → documentId (you implement the body) |
| `schdl.fn_ResolveDateToken` | Resolves `{{TOKEN}}` strings to date values |

**Procedures**

| Procedure | Purpose |
|---|---|
| `schdl.usp_RegisterSchedule` | Single setup call — defines everything for a schedule |
| `schdl.usp_BuildDispatchQueue` | Internal — builds dispatch rows for one schedule |
| `schdl.usp_GetDueSchedules` | Called by Flowgear — returns all due dispatch rows |
| `schdl.usp_UpdateDispatchStatus` | Called by Flowgear — marks each row SENT or FAILED |
| `schdl.usp_TestDispatch` | Test a schedule without affecting live state |

---

## Step 2 — Implement fn_FetchDocumentId

This is the **only function you must customise**.
It maps a `DocumentName` to the `documentId` value the report API expects.
The body is intentionally left as a stub — replace it once per environment.

```sql
ALTER FUNCTION [schdl].[fn_FetchDocumentId]
(
    @DocumentName NVARCHAR(255)
)
RETURNS NVARCHAR(100)
AS
BEGIN
    DECLARE @ID NVARCHAR(100);

    -- Replace with your actual query
    SELECT TOP 1 @ID = CAST(CAST(iDocumentID AS BIGINT) AS NVARCHAR(100))
    FROM   dbo.Document
    WHERE  sName    = @DocumentName
      AND  bEnabled = 1;

    RETURN @ID;
END;
```

**Rules:**
- Receives `@DocumentName` — the same string you pass to `usp_RegisterSchedule`
- Must return `NVARCHAR(100)` — the documentId sent in `RequestJson`
- Returning `NULL` is safe — the dispatch row will have `"documentId":""` and can be investigated via the queue
- Can point at any source: your own table, SSRS `ReportServer.dbo.Catalog`, a linked server, a synonym

**Verify:**
```sql
SELECT schdl.fn_FetchDocumentId('BRM Production Report') AS ResolvedDocumentId;
```

---

## Step 3 — Create email source objects

Each report parameter that drives fan-out needs an `EmailSource`.
Only create the objects that match the source types you will use.

### Option A — STATIC

No object required. The address is stored directly in the dispatch config.
Use for bulk-only reports where there is one fixed recipient.

```json
"dispatch": {
    "isPrimary":   true,
    "mode":        "BULK",
    "emailSource": "STATIC",
    "bulkEmail":   "reports@example.com"
}
```

---

### Option B — LOOKUP_VIEW

Create a view that exposes exactly `LookupKey` and `EmailAddress`.
The engine matches `LookupKey` against each dispatch parameter value.

```sql
CREATE OR ALTER VIEW [schdl].[vw_BRMEmail]
AS
    SELECT
        sBRMCode      AS LookupKey,      -- must match your parameter values exactly
        sEmailAddress AS EmailAddress
    FROM dbo.BrokerRelationshipManager
    WHERE bActive = 1;
```

```json
"dispatch": {
    "isPrimary":        true,
    "mode":             "BOTH",
    "emailSource":      "LOOKUP_VIEW",
    "emailSourceValue": "schdl.vw_BRMEmail",
    "bulkEmail":        "reports-bulk@example.com"
}
```

**Rules:**
- View can live in any schema — specify fully e.g. `schdl.vw_BRMEmail`
- `LookupKey` is always compared as `NVARCHAR` — cast numeric IDs to string if needed
- Create one view per entity type (BRM, Brokerage, Administrator, etc.)

**Verify:**
```sql
SELECT TOP 5 LookupKey, EmailAddress FROM schdl.vw_BRMEmail;
```

---

### Option C — SCALAR_FN

Create a scalar function that receives a parameter value and returns an email.
Use when the lookup needs joins, fallback logic, or conditional routing.

```sql
CREATE OR ALTER FUNCTION [dbo].[fn_GetBrokerEmail]
(
    @BrokerCode NVARCHAR(50)
)
RETURNS NVARCHAR(320)
AS
BEGIN
    DECLARE @Email NVARCHAR(320);

    SELECT TOP 1 @Email = sEmailAddress
    FROM   dbo.Broker
    WHERE  sBrokerCode = @BrokerCode
      AND  bActive     = 1;

    -- Optional fallback
    IF @Email IS NULL
        SELECT TOP 1 @Email = sDefaultEmail
        FROM   dbo.BrokerDefaults
        WHERE  bIsActive = 1;

    RETURN @Email;
END;
```

```json
"dispatch": {
    "isPrimary":        true,
    "mode":             "INDIVIDUAL",
    "emailSource":      "SCALAR_FN",
    "emailSourceValue": "dbo.fn_GetBrokerEmail"
}
```

**Rules:**
- Signature must be `fn(@Value NVARCHAR(500)) RETURNS NVARCHAR(320)` — parameter name can differ, types must match
- Can live in any schema — specify fully e.g. `dbo.fn_GetBrokerEmail`
- Cannot use `EXEC` or `sp_executesql` inside the function body (SQL Server restriction on scalar functions)
- Return `NULL` if no match — the `ToAddresses` field will be empty for that row

**Verify:**
```sql
SELECT dbo.fn_GetBrokerEmail('39398') AS Email;
```

---

### Option D — DYNAMIC_SQL

No object required. Write the lookup SQL inline in the JSON config.
Use `{VALUE}` as the placeholder — it is replaced with the parameter value at runtime.

```json
"dispatch": {
    "isPrimary":        true,
    "mode":             "INDIVIDUAL",
    "emailSource":      "DYNAMIC_SQL",
    "emailSourceValue": "SELECT sEmailAddress AS EmailAddress FROM dbo.Administrator WHERE iAdminID = CAST(''{VALUE}'' AS INT) AND bEnabled = 1"
}
```

**Rules:**
- Must return a column named `EmailAddress`
- Escape single quotes by doubling them: `''` not `\'`
- Wrap numeric keys: `CAST(''{VALUE}'' AS INT)`
- Keep it simple — complex logic belongs in a `SCALAR_FN` instead


---

## Step 3b — Delivery method and resolved fields

Every dispatch parameter can now carry up to four resolved values per row:

| Resolved field | Column in DispatchQueue | Purpose |
|---|---|---|
| Email address | `ToAddresses` | Who receives the email |
| Display name | `DisplayName` | Entity name — used in filename templates and email display |
| File name | `FileName` | Overrides the report API's default filename when not NULL |
| Folder path | `FolderPath` | Destination for file drop delivery |

All four follow the exact same four-source pattern (`STATIC` / `LOOKUP_VIEW` / `SCALAR_FN` / `DYNAMIC_SQL`). The column name exposed by a view or dynamic SQL must match the target:

| Resolver | View / SQL must expose column |
|---|---|
| `emailSourceValue` | `EmailAddress` |
| `displayNameSourceValue` | `DisplayName` |
| `fileNameSourceValue` | `FileName` |
| `folderSourceValue` | `FolderPath` |

### DeliveryMethod

Controls what gets populated in the dispatch row:

| DeliveryMethod | What is resolved | Use case |
|---|---|---|
| `EMAIL` | Email + DisplayName + FileName | Send email with attachment |
| `FOLDER` | FolderPath + DisplayName + FileName | Drop file to network/cloud folder |
| `BOTH` | All of the above | Email the recipient AND drop to their folder |

### FileNameTemplate

The most flexible option for controlling filenames. Set `fileNameTemplate` in the dispatch block and it overrides the API default filename for every row.

Two placeholder types are supported inside the template:

| Placeholder | Replaced with |
|---|---|
| `{DISPLAYNAME}` | The resolved DisplayName for that row |
| `{{ANY_TOKEN}}` | Any date token from `schdl.DateToken` |

Example:
```
"fileNameTemplate": "BRM_{DISPLAYNAME}_{{PREV_MONTH_START}}_{{PREV_MONTH_END}}.xlsx"
```

Resolves to: `BRM_Broker ABC_2026-05-01_2026-05-31.xlsx` per individual row.

For the BULK row, `{DISPLAYNAME}` is replaced with an empty string.

If you only need a static filename or a simple date-stamped name without a display name, use `fileNameSource` + `fileNameSourceValue` instead.

### Sample views for folder and display name resolution

Create one view per entity type. All four resolvers can point at the same view if it exposes all the columns:

```sql
-- All-in-one view — reference it for email, displayName, and folderPath
CREATE OR ALTER VIEW [schdl].[vw_BRMAll]
AS
    SELECT
        sBRMCode        AS LookupKey,
        sEmailAddress   AS EmailAddress,
        sFullName       AS DisplayName,
        sReportFolder   AS FolderPath
    FROM dbo.BrokerRelationshipManager
    WHERE bActive = 1;
```

Then in the dispatch block:
```json
"emailSourceValue":       "schdl.vw_BRMAll",
"displayNameSourceValue": "schdl.vw_BRMAll",
"folderSourceValue":      "schdl.vw_BRMAll"
```

Each resolver runs `SELECT TOP 1 <TargetColumn> FROM <view> WHERE LookupKey = '<value>'`
so pointing multiple resolvers at the same view causes three lightweight lookups against the same indexed key — perfectly acceptable.

### Flowgear handling of new columns

The result set from `usp_GetDueSchedules` now includes:

| New column | Use in Flowgear |
|---|---|
| `DeliveryMethod` | Branch: if `EMAIL` or `BOTH` → send email; if `FOLDER` or `BOTH` → write file to `FolderPath` |
| `DisplayName` | Use as the email recipient display name or as part of the attachment label |
| `FileName` | When not NULL — use as the attachment filename instead of the API default |
| `FolderPath` | When not NULL — write the report file to this location |


---

## Step 4 — Register a schedule

Everything is defined in a single call.
Re-running the same call updates the existing schedule (full UPSERT).
`NextRunAt` is reset to NULL on every update so the schedule is always ready to fire.

```sql
EXEC schdl.usp_RegisterSchedule
    @DocumentName   = 'BRM Production Report',   -- drives fn_FetchDocumentId
    @ReportEndpoint = '/api/reports/generate',
    @OutputFormat   = 'xlsx',                     -- xlsx | pdf | csv  (default xlsx)
    @Language       = 1,                          -- default 1
    @Confidentiality = 'normal',                  -- default normal
    @ScheduleName   = 'BRM Production Report - Monthly',
    @FrequencyType  = 'MONTHLY',
    @RunTime        = '06:00',
    @DayOfMonth     = 1,
    @Subject        = 'BRM Report - {{PREV_MONTH_START}} to {{PREV_MONTH_END}}',
    @BodyTemplate   = 'Please find attached your report.',
    @ParametersJson = N'[...]',                   -- optional — omit for parameter-free reports
    @RecipientsJson = N'[...]';                   -- optional — static TO/CC/BCC
```

### Frequency types

| FrequencyType | Required extra params | Notes |
|---|---|---|
| `DAILY` | `@RunTime` | Fires every day at RunTime |
| `WEEKLY` | `@RunTime`, `@DayOfWeek` | 0=Sun 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat |
| `MONTHLY` | `@RunTime`, `@DayOfMonth` | 1–31, or `-1` for last day of month |
| `ADHOC` | none | Fires once on next trigger, then disables itself |
| `INTERVAL` | `@IntervalMinutes` | Optional `@WindowStart` / `@WindowEnd` to restrict to a time window |

---

## Step 5 — Define parameters

`@ParametersJson` is a JSON array. Omit it entirely for parameter-free reports
— the `RequestJson` will contain `"parameters":[]`.

### Parameter object fields

```json
{
    "name":      "BrokerRelationshipManager",
    "type":      "string",
    "required":  true,
    "sortOrder": 1,
    "value":     "BRM001|BRM002|BRM003",
    "dispatch": { ... }
}
```

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Exact parameter name as the report API expects it |
| `type` | Yes | `string` \| `date` \| `int` |
| `required` | No | Default `true` |
| `sortOrder` | No | Position in the `RequestJson` parameters array |
| `value` | Yes | See value formats below |
| `dispatch` | No | Omit for pass-through parameters — they are included in every row unchanged |

### Value formats

| Format | Example | Notes |
|---|---|---|
| Literal | `"39398"` | Passed through as-is |
| Pipe-delimited | `"BRM001\|BRM002\|BRM003"` | Multiple values for one parameter |
| Date token | `"{{PREV_MONTH_END}}"` | Only resolved on `date` type parameters |
| Mixed | `"{{PREV_MONTH_START}}\|{{TODAY}}"` | Each segment resolved independently |

**Important:** Date token resolution only applies to parameters with `"type": "date"`.
String and integer parameters always pass through unchanged —
so `PaymentTerm` values like `"0|1|2|3|4"` are never misinterpreted as tokens.

### Dispatch object fields

```json
"dispatch": {
    "isPrimary":        true,
    "mode":             "BOTH",
    "emailSource":      "LOOKUP_VIEW",
    "emailSourceValue": "schdl.vw_BRMEmail",
    "bulkEmail":        "reports-bulk@example.com"
}
```

| Field | Required | Description |
|---|---|---|
| `isPrimary` | Yes | `true` on exactly **one** parameter per report — this drives the fan-out |
| `mode` | Yes | `BULK` \| `INDIVIDUAL` \| `BOTH` |
| `deliveryMethod` | No | `EMAIL` (default) \| `FOLDER` \| `BOTH` |
| `emailSource` | Depends | Required when deliveryMethod is `EMAIL` or `BOTH` |
| `emailSourceValue` | Depends | Required for `LOOKUP_VIEW`, `SCALAR_FN`, `DYNAMIC_SQL` |
| `bulkEmail` | For BULK/BOTH email | Static address for the bulk email row |
| `displayNameSource` | No | Resolves entity display name — same four-source pattern |
| `displayNameSourceValue` | Depends | Source object / SQL for display name |
| `fileNameTemplate` | No | Template string with `{DISPLAYNAME}` and `{{TOKEN}}` placeholders |
| `fileNameSource` | No | Alternative to template — resolves filename directly |
| `fileNameSourceValue` | Depends | Source object / SQL for filename |
| `folderSource` | Depends | Required when deliveryMethod is `FOLDER` or `BOTH` |
| `folderSourceValue` | Depends | Source object / SQL for folder path |
| `bulkFolderPath` | For BULK/BOTH folder | Static folder path for the bulk folder-drop row |

### DispatchMode behaviour

| Mode | Output |
|---|---|
| `BULK` | One dispatch row. All primary parameter values in one `RequestJson`. Email = `bulkEmail` + schedule TO recipients |
| `INDIVIDUAL` | One dispatch row per primary parameter value. Each `RequestJson` contains only that one value. Email resolved per value via EmailSource |
| `BOTH` | All INDIVIDUAL rows plus one BULK row |

---

## Step 6 — Define static recipients

`@RecipientsJson` adds static TO, CC, or BCC recipients to the schedule.
These appear on every dispatch row regardless of fan-out mode.

```json
[
    {"name": "Reports Admin", "email": "reports-admin@example.com", "role": "CC"},
    {"name": "Audit Log",     "email": "audit@example.com",         "role": "BCC"}
]
```

| Role | Behaviour |
|---|---|
| `TO` | Added to `ToAddresses` on BULK rows. INDIVIDUAL rows use the resolved email as TO — schedule TO recipients are not added to individual rows |
| `CC` | Added to `CcAddresses` on every row |
| `BCC` | Added to `BccAddresses` on every row |

---

## Step 7 — Date tokens

Use `{{TOKEN}}` in any `value` field with `"type": "date"`,
and in `@Subject` / `@BodyTemplate`.
Tokens resolve against the actual execution date at runtime.

| Token | Resolves to |
|---|---|
| `{{TODAY}}` | Execution date |
| `{{TODAY-1}}` | Yesterday |
| `{{TODAY-7}}` | 7 days ago |
| `{{TODAY-N}}` | N days before execution date (any N) |
| `{{TODAY+1}}` | Tomorrow |
| `{{TODAY+N}}` | N days after execution date (any N) |
| `{{WEEK_START}}` | Monday of current week |
| `{{WEEK_END}}` | Sunday of current week |
| `{{PREV_WEEK_START}}` | Monday of previous week |
| `{{PREV_WEEK_END}}` | Sunday of previous week |
| `{{MONTH_START}}` | First day of current month |
| `{{MONTH_END}}` | Last day of current month |
| `{{PREV_MONTH_START}}` | First day of previous month |
| `{{PREV_MONTH_END}}` | Last day of previous month |
| `{{NEXT_MONTH_START}}` | First day of next month |
| `{{NEXT_MONTH_END}}` | Last day of next month |
| `{{QUARTER_START}}` | First day of current quarter |
| `{{QUARTER_END}}` | Last day of current quarter |
| `{{PREV_QUARTER_START}}` | First day of previous quarter |
| `{{PREV_QUARTER_END}}` | Last day of previous quarter |
| `{{YEAR}}` | Current 4-digit year |
| `{{YEAR_START}}` | 1 Jan of current year |
| `{{YEAR_END}}` | 31 Dec of current year |
| `{{PREV_YEAR}}` | Previous 4-digit year |
| `{{PREV_YEAR_START}}` | 1 Jan of previous year |
| `{{PREV_YEAR_END}}` | 31 Dec of previous year |

**View all tokens with today's resolved values:**
```sql
SELECT TokenID, Token, Category, Description,
       schdl.fn_ResolveDateToken(Token, CAST(GETDATE() AS DATE)) AS ResolvedToday
FROM   schdl.DateToken
WHERE  IsActive = 1
ORDER  BY Category, TokenID;
```

---

## Step 8 — Test before going live

### Test a specific schedule (safest — bypasses all gates)

Does not advance `NextRunAt` or change `IsActive`.
Cleans up test rows from `DispatchQueue` automatically.

```sql
-- Returns the full dispatch output including RequestJson
EXEC schdl.usp_TestDispatch
    @ScheduleName = 'BRM Production Report - Monthly';

-- Keep rows in DispatchQueue for further inspection
EXEC schdl.usp_TestDispatch
    @ScheduleName = 'BRM Production Report - Monthly',
    @KeepResults  = 1;
```

### Test the live schedule gate logic

Simulates a Flowgear trigger as of a specific date and time.
Returns two result sets:

1. **Diagnostic** — every schedule with Y/N for each gate
2. **Dispatch queue** — rows that would be sent (if all gates pass)

```sql
EXEC schdl.usp_GetDueSchedules @AsOf = '2026-06-01 06:00:00';
```

**Diagnostic columns:**

| Column | Meaning | Fix if N |
|---|---|---|
| `Gate_IsActive` | Schedule is enabled | Re-register the schedule or set `IsActive = 1` directly |
| `Gate_DateRange` | AsOf date is within StartDate–EndDate | Re-register — `StartDate` resets to `2000-01-01` |
| `Gate_NextRunAt` | NextRunAt is NULL or in the past | Re-register — `NextRunAt` resets to NULL |
| `Gate_Frequency` | Day/time conditions match FrequencyType | Check RunTime, DayOfMonth, DayOfWeek match your @AsOf value |

All four must be `Y` for a schedule to produce dispatch rows.

---

## Step 9 — Flowgear workflow

Flowgear needs to do three things per trigger:

```
1. Execute:  EXEC schdl.usp_GetDueSchedules
             → First result set:  diagnostic (gate Y/N per schedule)
             → Second result set: dispatch rows (one per email)

2. For each dispatch row:
   a. POST row.RequestJson  →  row.ReportEndpoint
      Response: report file (base64 or download URL)

   b. Send email:
        To      = row.ToAddresses       (comma-separated)
        CC      = row.CcAddresses
        BCC     = row.BccAddresses
        Subject = row.EmailSubject      (tokens already resolved)
        Body    = row.EmailBody
        Attach  = report from step (a)

   c. Execute:  EXEC schdl.usp_UpdateDispatchStatus
                    @QueueID      = row.QueueID,
                    @Status       = 'SENT',   -- or 'FAILED'
                    @ErrorMessage = NULL       -- or '<error detail>'
```

No branching, no ID resolution, no token replacement needed in Flowgear.
Everything is resolved server-side before the result set is returned.

---

## Step 10 — Monitoring

```sql
-- Recent executions with sent/failed counts
SELECT   el.LogID,
         s.ScheduleName,
         el.ExecutedAt,
         el.Status,
         COUNT(dq.QueueID)                                       AS TotalRows,
         SUM(CASE WHEN dq.Status = 'SENT'    THEN 1 ELSE 0 END) AS Sent,
         SUM(CASE WHEN dq.Status = 'FAILED'  THEN 1 ELSE 0 END) AS Failed,
         SUM(CASE WHEN dq.Status = 'PENDING' THEN 1 ELSE 0 END) AS Pending
FROM     schdl.ExecutionLog    el
JOIN     schdl.Schedule        s  ON s.ScheduleID = el.ScheduleID
LEFT JOIN schdl.DispatchQueue  dq ON dq.LogID     = el.LogID
GROUP BY el.LogID, s.ScheduleName, el.ExecutedAt, el.Status, el.ProcessedAt
ORDER BY el.ExecutedAt DESC;

-- Inspect a failed dispatch row
SELECT   dq.QueueID, s.ScheduleName, dq.DispatchType,
         dq.DispatchKeyValue, dq.ToAddresses,
         dq.RequestJson, dq.ErrorMessage
FROM     schdl.DispatchQueue dq
JOIN     schdl.Schedule      s ON s.ScheduleID = dq.ScheduleID
WHERE    dq.Status = 'FAILED'
ORDER BY dq.CreatedAt DESC;

-- All schedules and their current state
SELECT   d.DocumentName,
         s.ScheduleName,
         s.FrequencyType,
         s.RunTime,
         s.DayOfMonth,
         s.DayOfWeek,
         s.IsActive,
         s.NextRunAt,
         schdl.fn_FetchDocumentId(d.DocumentName) AS ResolvedDocumentId
FROM     schdl.Schedule  s
JOIN     schdl.Document  d ON d.ReportID = s.ReportID
ORDER BY s.ScheduleName;
```

---

## Quick reference — common issues

| Symptom | Cause | Fix |
|---|---|---|
| `usp_GetDueSchedules` returns 0 dispatch rows | `Gate_DateRange = N` | Re-register — StartDate resets to 2000-01-01 |
| | `Gate_NextRunAt = N` | Re-register — NextRunAt resets to NULL |
| | `Gate_Frequency = N` | Check RunTime / DayOfMonth / DayOfWeek match your @AsOf |
| `"documentId":""` in RequestJson | `fn_FetchDocumentId` returns NULL | Verify DocumentName exactly matches source table |
| Integer param values resolved to dates | Parameter type set to `"date"` | Change `"type"` to `"string"` for non-date parameters |
| `ToAddresses` empty on INDIVIDUAL rows | View / function returned NULL | Check LookupKey matches exactly — comparison is NVARCHAR |
| Subject / body tokens not resolved | Token not in `schdl.DateToken` | Check token spelling — must match exactly including `{{` and `}}` |
| Parameter-free report produces no rows | `@ParametersJson` passed as `'[]'` | Omit the parameter entirely — pass `NULL` or leave it out |

# Execution Flow — Scheduling Agent v3

Complete walkthrough of the dispatch pipeline from registration to delivery.

---

## 1. Registration

A schedule is registered once (or re-registered to update it) by calling `usp_RegisterSchedule`.

```sql
EXEC [schdl].[usp_RegisterSchedule]
    @DocumentName    = 'My Report',
    @ReportEndpoint  = 'api/reports/my-report',
    @ScheduleName    = 'My Report — Daily',
    @FrequencyType   = 'DAILY',
    @RunTime         = '07:00',
    @DispatchJson    = N'{ "deliveryMethod": "EMAIL", "emailSource": "STATIC",
                           "emailSourceValue": "reports@example.com",
                           "subjectSource": "STATIC",
                           "subjectSourceValue": "My Report {{TODAY}}" }',
    @ParametersJson  = N'[{ "name": "StartDate", "type": "string", "value": "{{PREV_MONTH_START}}" }]';
```

### Write order (Section 3 of deploy script)

1. `Schedule` — UPSERT by `ScheduleName`. This is the root; all other tables FK to it.
2. `ScheduleDocument` — UPSERT by `ScheduleID`. Stores `DocumentName`, `ReportEndpoint`, format defaults.
3. `ScheduleDocumentParameter` — UPSERT per parameter by `(ScheduleID, ParameterName)`. Stores metadata (type, required, sort order).
4. `ScheduleParameterDispatchConfig` — UPSERT if the parameter has a `fanOut` block; DELETE if it was removed.
5. `ScheduleParameter` — UPSERT per parameter by `(ScheduleID, ScheduleParameterID)`. Stores the value/query.
6. `ScheduleStandingRecipient` — DELETE all for `ScheduleID`, then INSERT from `@RecipientsJson`.

Re-running the same call is safe (idempotent UPSERT on all tables).

### @DispatchJson keys

```json
{
  "deliveryMethod":      "EMAIL | FOLDER | BOTH",
  "emailSource":         "STATIC | DYNAMIC_SQL",
  "emailSourceValue":    "literal address, or SELECT returning one address",
  "subjectSource":       "STATIC | DYNAMIC_SQL",
  "subjectSourceValue":  "subject with optional {{TOKEN}} values",
  "bodySource":          "STATIC | DYNAMIC_SQL",
  "bodySourceValue":     "plain text body",
  "fileNameSource":      "STATIC | DYNAMIC_SQL",
  "fileNameSourceValue": "filename.xlsx or SELECT",
  "folderSource":        "STATIC | DYNAMIC_SQL",
  "folderSourceValue":   "\\\\server\\share\\path or SELECT"
}
```

### @ParametersJson — parameter with fan-out block

```json
[
  {
    "name": "EntityCode", "type": "string", "required": true, "sortOrder": 1,
    "value": "A|B|C",
    "fanOut": {
      "isPrimary": true,
      "mode": "INDIVIDUAL",
      "emailSource": "DYNAMIC_SQL",
      "emailSourceValue": "SELECT email FROM entities WHERE code = '{VALUE}'",
      "displayNameSource": "DYNAMIC_SQL",
      "displayNameSourceValue": "SELECT name FROM entities WHERE code = '{VALUE}'",
      "fileNameSource": "STATIC",
      "fileNameSourceValue": "Report_{{DISPLAYNAME}}_{{TODAY}}.xlsx"
    }
  }
]
```

### @RecipientsJson — CC/BCC only

```json
[
  { "email": "manager@example.com", "role": "CC", "includeInFanOut": true },
  { "email": "audit@example.com",   "role": "BCC", "includeInFanOut": false }
]
```

`role` must be `CC` or `BCC` — never `TO`. TO is always resolved from `Schedule.EmailSourceValue`.

---

## 2. Scheduling gates (usp_GetDueSchedules)

Flowgear calls `EXEC [schdl].[usp_GetDueSchedules]` on a cron (e.g. every 5 minutes).

### Result set 1 — diagnostic

All active schedules with gate evaluation columns:

| Column | Meaning |
|---|---|
| `Gate_IsActive` | `Y` if `IsActive = 1` |
| `Gate_DateRange` | `Y` if today is within `StartDate`/`EndDate` |
| `Gate_NextRunAt` | `Y` if `NextRunAt IS NULL OR CAST(NextRunAt AS DATE) <= @Today` |
| `Gate_Frequency` | `Y` if frequency-specific time/day check passes |

A schedule fires only when all four gates are `Y`.

### NextRunAt gate — date vs datetime comparison

`NextRunAt` stores a **flat date** for DAILY/WEEKLY/MONTHLY (no time component) and a **full DATETIME2** for INTERVAL. The gate compares differently:

- Non-INTERVAL: `CAST(s.NextRunAt AS DATE) <= @Today` — date-only comparison avoids false negatives from time-of-day drift
- INTERVAL: `s.NextRunAt <= @Now` — full datetime comparison for sub-day precision

### Frequency gate logic

| FrequencyType | Gate condition |
|---|---|
| `DAILY` | `RunTime <= current time` |
| `WEEKLY` | `DayOfWeek = current DOW` AND `RunTime <= current time` |
| `MONTHLY` | `(DayOfMonth = current DOM OR (DayOfMonth = -1 AND today is last day))` AND `RunTime <= current time` |
| `ADHOC` | Always passes |
| `INTERVAL` | Window check: `current time BETWEEN WindowStart AND WindowEnd` AND `NextRunAt IS NULL OR @Now >= NextRunAt` |

### Side effects when a schedule fires

1. INSERT into `ExecutionLog` (Status=`PENDING`)
2. Advance `Schedule.NextRunAt` via `fn_CalcNextRunAt(FrequencyType, DayOfWeek, DayOfMonth, IntervalMinutes, @Now)` — correct next occurrence for every frequency type
3. For ADHOC schedules: set `IsActive = 0`
4. Call `usp_BuildDispatchQueue(@ScheduleID, @LogID)` — builds all DispatchQueue rows

### fn_CalcNextRunAt — NextRunAt calculation

Used by both `usp_RegisterSchedule` (on INSERT and UPDATE) and `usp_GetDueSchedules` (after firing).

`[schdl].[fn_CalcNextRunAt](@FrequencyType, @DayOfWeek, @DayOfMonth, @IntervalMinutes, @AsOf DATETIME2) RETURNS DATETIME2`

| FrequencyType | Result |
|---|---|
| `DAILY` | Next calendar day — `CAST(DATEADD(DAY, 1, @Today) AS DATETIME2)` |
| `WEEKLY` | Next occurrence of `@DayOfWeek`; same weekday = next week (never today) |
| `MONTHLY` | Target day of next month; `-1` = last day; clamped if month is shorter |
| `INTERVAL` | `DATEADD(MINUTE, @IntervalMinutes, @AsOf)` — time-aware, no date truncation |
| `ADHOC` | `NULL` |

### Result set 2 — PENDING dispatch rows

After all due schedules are processed, returns all rows from `DispatchQueue` WHERE `Status = 'PENDING'`. Columns include `QueueID`, `LogID`, `ScheduleID`, `ScheduleName`, `DeliveryMethod`, `DocumentName`, `ReportEndpoint`, `DispatchType`, `DispatchKeyValue`, `RequestJson`, `ToAddresses`, `CcAddresses`, `BccAddresses`, `EmailSubject`, `EmailBody`, `FolderPath`, `FileName`.

---

## 3. Dispatch queue building (usp_BuildDispatchQueue)

Called internally by `usp_GetDueSchedules`. Can also be called by `usp_TestDispatch`.

### NextRunAt on registration

`usp_RegisterSchedule` calls `fn_CalcNextRunAt` on both INSERT and UPDATE so `NextRunAt` is always set correctly when a schedule is first created or when its frequency definition changes.

### Step 1 — Resolve dynamic parameter values

For each `ScheduleParameter` row WHERE `ParameterValueQuery IS NOT NULL`:

```sql
SET @aggSQL = N'SELECT @r = STRING_AGG([Value], ''|'') FROM (' + @dvQuery + N') AS _q';
EXEC sp_executesql @aggSQL, N'@r NVARCHAR(MAX) OUTPUT', @r = @dvResult OUTPUT;
```

The executed SQL sees separator `'|'` — the `''|''` in the N-string literal is two single-quotes around `|`, which collapse to one quote each when the string is evaluated. Results go into `#DynVals`.

### Step 2 — Shred parameter values

```sql
FROM   [schdl].[ScheduleParameter]                   sp
JOIN   [schdl].[ScheduleDocumentParameter]            dp
          ON dp.ScheduleParameterID = sp.ScheduleParameterID
         AND dp.ScheduleID          = @ScheduleID          -- ← schedule isolation
LEFT   JOIN [schdl].[ScheduleParameterDispatchConfig] dc
          ON dc.ScheduleParameterID = dp.ScheduleParameterID
         AND dc.ScheduleID          = @ScheduleID          -- ← schedule isolation
CROSS  APPLY STRING_SPLIT(ev.EffectiveValue, '|') seg
WHERE  sp.ScheduleID = @ScheduleID
```

`AND ScheduleID = @ScheduleID` on both JOINs is mandatory — without it, shared `ScheduleDocumentParameter` rows from other schedules could contaminate the result set.

Date tokens in static values are resolved here via `fn_ResolveDateToken`.

### Step 3 — Collect standing recipients

```sql
SELECT @CcAll    = STRING_AGG(EmailAddress, ',') WHERE RecipientRole='CC'
SELECT @CcFanOut = STRING_AGG(EmailAddress, ',') WHERE RecipientRole='CC' AND IncludeInFanOut=1
SELECT @BccAll   = STRING_AGG(EmailAddress, ',') WHERE RecipientRole='BCC'
SELECT @BccFanOut= STRING_AGG(EmailAddress, ',') WHERE RecipientRole='BCC' AND IncludeInFanOut=1
```

### Step 4 — No-parameter path

If `#P` is empty (no parameters registered): emit one COMBINED row using schedule-level resolvers. `CcAddresses = @CcAll`, `BccAddresses = @BccAll`. FileName last-resort: `@DefaultFileName` = `DocumentName + '.' + LOWER(OutputFormat)`.

### Step 5 — INDIVIDUAL rows (cursor over primary parameter values)

For each pipe-segment of the primary parameter's value:

1. **Resolve email** (if `DeliveryMethod IN ('EMAIL','BOTH')`)
   - STATIC: use `EmailSourceValue` as-is
   - DYNAMIC_SQL: `REPLACE(EmailSourceValue, '{VALUE}', @iSafeVal)` → sp_executesql

2. **Resolve display name**
   - STATIC or DYNAMIC_SQL with `{VALUE}` replacement
   - Apply `fn_ResolveAllTokens(@iDisplayName, @Today, @DocumentName)`

3. **Resolve file name** (per-entity first, then schedule-level fallback, then default)
   - If per-entity `FileNameSource IS NOT NULL`: resolve it
   - Else if schedule-level `FileNameSource IS NOT NULL`: resolve it
   - After resolution: `fn_ResolveAllTokens(...)` then `REPLACE(..., '{{DISPLAYNAME}}', @iDisplayName)`
   - **Last-resort fallback** (when neither per-entity nor schedule-level FileName is configured): `DocumentName + '_' + DispatchValue + '.' + LOWER(OutputFormat)` — unique per entity (e.g. `Some Report_E001.xlsx`)

4. **Resolve folder path** (per-entity first, then schedule-level fallback, only if FOLDER or BOTH)
   - Same per-entity/fallback pattern; `fn_ResolveAllTokens` applied (no `{{DISPLAYNAME}}` on folder)

5. **Resolve subject** (per-entity first, then `@EmailSubject` pre-resolved at proc start)
   - `@iSubject = ISNULL(@iSubject_resolved, @EmailSubject)` — schedule-level is the fallback
   - Then: `fn_ResolveAllTokens(...)` + `REPLACE(..., '{{DISPLAYNAME}}', @iDisplayName)`

6. **Resolve body** (same pattern as subject)

7. **INSERT into DispatchQueue**
   - `DispatchType = 'INDIVIDUAL'`
   - `CcAddresses = @CcFanOut` (standing CC with `IncludeInFanOut=1`)
   - `BccAddresses = @BccFanOut`

### @iSafeVal — SQL injection escaping

```sql
SET @iSafeVal = REPLACE(@iVal, N'''', N'''''');
-- 4-quote find = one literal '
-- 6-quote replace = two '' (escaped quote)
```

This escapes the fan-out value before embedding it in dynamic SQL strings.

### Step 6 — COMBINED row

If `DispatchMode IN ('COMBINED','BOTH')`:
- Emit one COMBINED row with schedule-level resolvers
- `ToAddresses` = schedule-level email resolution
- `EmailSubject` = `@EmailSubject` (pre-resolved at proc start)
- `EmailBody` = `@EmailBody` (pre-resolved at proc start)
- `CcAddresses = @CcAll` (all standing CC recipients)
- `BccAddresses = @BccAll`
- `DispatchKeyValue = NULL`
- **FileName last-resort**: if schedule-level `FileNameSource` is NULL or resolves to NULL → `@DefaultFileName` = `DocumentName + '.' + LOWER(OutputFormat)` (e.g. `Some Report.xlsx`)

---

## 4. Token resolution

### fn_ResolveDateToken

Resolves a single `{{TOKEN}}` string. Returns the date value for:
- `{{TODAY}}`, `{{TODAY-N}}`, `{{TODAY+N}}` (N = any integer)
- `{{WEEK_START}}`, `{{WEEK_END}}`, `{{PREV_WEEK_START}}`, `{{PREV_WEEK_END}}`
- `{{MONTH_START}}`, `{{MONTH_END}}`, `{{PREV_MONTH_START}}`, `{{PREV_MONTH_END}}`
- `{{NEXT_MONTH_START}}`, `{{NEXT_MONTH_END}}`
- `{{QUARTER_START}}`, `{{QUARTER_END}}`, `{{PREV_QUARTER_START}}`, `{{PREV_QUARTER_END}}`
- `{{YEAR}}`, `{{YEAR_START}}`, `{{YEAR_END}}`, `{{PREV_YEAR}}`, `{{PREV_YEAR_START}}`, `{{PREV_YEAR_END}}`

### fn_ResolveAllTokens

Applies `fn_ResolveDateToken` to every `{{TOKEN}}` occurrence in a string. Also resolves `{{REPORTNAME}}` (the document name). Does **not** replace `{{DISPLAYNAME}}` — that is done explicitly after `fn_ResolveAllTokens` using `REPLACE`.

### Token resolution order (INDIVIDUAL rows)

1. Dynamic SQL queries are executed first (with `{VALUE}` substituted)
2. `fn_ResolveAllTokens` applied to the resolved string
3. `{{DISPLAYNAME}}` replaced last (after fn_ResolveAllTokens)

---

## 5. Flowgear consumption (usp_GetDueSchedules → usp_UpdateDispatchStatus)

### Flowgear call sequence

1. SQL Query node: `EXEC [schdl].[usp_GetDueSchedules]`
   - Result set 1: diagnostic (optional — log or discard)
   - Result set 2: PENDING dispatch rows → ForEach iterator

2. For each row in result set 2:
   - Check `DeliveryMethod` (`EMAIL`, `FOLDER`, or `BOTH`)
   - If EMAIL or BOTH: POST `RequestJson` to report API with `ToAddresses`, `CcAddresses`, `BccAddresses`, `EmailSubject`, `EmailBody`
   - If FOLDER or BOTH: write file to `FolderPath` / `FileName`
   - Call `EXEC [schdl].[usp_UpdateDispatchStatus] @QueueID = ..., @Status = 'SUCCESS'`
   - On failure: `@Status = 'FAILED', @ErrorMessage = '...'`

3. `usp_UpdateDispatchStatus` also rolls up log status:
   - When all DispatchQueue rows for a LogID are no longer PENDING: sets `ExecutionLog.Status` to `SUCCESS` or `FAILED`

---

## 6. Test dispatch (usp_TestDispatch)

Bypasses all scheduling gates. Use for validating a registered schedule before go-live.

```sql
EXEC [schdl].[usp_TestDispatch]
    @ScheduleName = 'My Report — Daily',
    @AsOf         = '2025-06-01 07:05:00',  -- optional: simulate a specific time
    @KeepResults  = 1;                       -- 1 = leave rows in DispatchQueue+ExecutionLog
```

Behaviour:
- Inserts a `PENDING` ExecutionLog row
- Calls `usp_BuildDispatchQueue` directly
- SELECTs from DispatchQueue WHERE `LogID = @LogID`
- If `@KeepResults = 0` (default): DELETEs the ExecutionLog and DispatchQueue rows after SELECT
- Does **not** advance `NextRunAt`; does **not** set ADHOC schedules inactive

---

## 7. Round-trip — HTML builder ↔ database

1. **HTML → SQL**: `syncCore()` generates `EXEC [schdl].[usp_RegisterSchedule]` string
2. **SQL → DB**: run the generated EXEC statement
3. **DB → SQL**: `EXEC [schdl].[usp_GetScheduleJson] @ScheduleName = '...'` returns `RegisterSQL` column
4. **SQL → HTML**: paste `RegisterSQL` into the load panel textarea, click Load — `loadSchedule()` parses it and pre-fills all form fields

`usp_GetScheduleJson` reads `Schedule` + `ScheduleDocument`, iterates parameters via cursor (with `AND ScheduleID = @ScheduleID` filters on both joins), and reconstructs the full `EXEC` string with `@DispatchJson` and `@ParametersJson` (including `fanOut` block for the primary parameter).

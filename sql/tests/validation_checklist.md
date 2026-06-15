# Validation Checklist — Scheduling Agent v3

Manual QA checklist. Run after deploying `scheduling_agent_v3.sql` to a new environment.

---

## 1. Deploy script

- [ ] Run `sql/deploy/scheduling_agent_v3.sql` on the target database — zero errors
- [ ] Re-run the script (idempotent test) — zero errors on second run
- [ ] Confirm schema exists: `SELECT SCHEMA_ID('schdl')` returns non-NULL
- [ ] Confirm all tables exist:
  ```sql
  SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID('schdl') ORDER BY name;
  -- Expected: DateToken, DispatchQueue, ExecutionLog, Schedule,
  --           ScheduleDocument, ScheduleDocumentParameter,
  --           ScheduleParameterDispatchConfig, ScheduleParameter,
  --           ScheduleStandingRecipient
  ```
- [ ] Confirm all procedures exist: `usp_RegisterSchedule`, `usp_BuildDispatchQueue`, `usp_GetDueSchedules`, `usp_UpdateDispatchStatus`, `usp_TestDispatch`, `usp_GetScheduleJson`
- [ ] Confirm all functions exist: `fn_ResolveDateToken`, `fn_ResolveAllTokens`, `fn_FetchDocumentId`, `fn_CalcNextRunAt`
- [ ] `DateToken` table is populated: `SELECT COUNT(*) FROM [schdl].[DateToken]` returns 23

---

## 2. fn_FetchDocumentId

- [ ] Implement the real body for `[schdl].[fn_FetchDocumentId](@ScheduleID INT)`:
  - Verify column names: `dbo.Document` uses `sName` (not `Name`) and `bEnabled` (not `IsEnabled`)
  - If the column names differ, update the function body before proceeding
- [ ] Test: register a schedule for a known document, then run:
  ```sql
  SELECT [schdl].[fn_FetchDocumentId](
      (SELECT ScheduleID FROM [schdl].[Schedule] WHERE ScheduleName = 'Your Test Schedule')
  )
  -- Must return a non-NULL value
  ```

---

## 3. Registration (usp_RegisterSchedule)

Run `sql/samples/register_schedule_sample.sql` Sample A, then verify:

- [ ] `SELECT * FROM [schdl].[Schedule] WHERE ScheduleName = 'Monthly Entity Report — 1st of month'`
  - `DeliveryMethod = 'BOTH'`
  - `EmailSource = 'DYNAMIC_SQL'`, `EmailSourceValue` is a SELECT statement (not a literal address)
  - `SubjectSource = 'DYNAMIC_SQL'`, `SubjectSourceValue` is a SELECT statement
  - `BodySource = 'DYNAMIC_SQL'`, `BodySourceValue` is a SELECT statement
  - `FileNameSource = 'DYNAMIC_SQL'`, `FileNameSourceValue` is a SELECT statement
  - `FolderSource = 'DYNAMIC_SQL'`, `FolderSourceValue` is a SELECT statement
- [ ] `SELECT * FROM [schdl].[ScheduleDocument]` — row exists for that ScheduleID
- [ ] `SELECT * FROM [schdl].[ScheduleDocumentParameter]` — 3 rows (EntityCode, ReportStartDate, ReportEndDate)
- [ ] `SELECT * FROM [schdl].[ScheduleParameterDispatchConfig]` — 1 row (EntityCode only, IsPrimaryDispatchKey=1, DispatchMode=BOTH)
- [ ] `SELECT * FROM [schdl].[ScheduleParameter]` — 3 rows; EntityCode row has `ParameterValue='DYNAMIC'` and `ParameterValueQuery` is non-NULL
- [ ] `SELECT * FROM [schdl].[ScheduleStandingRecipient]` — 3 rows (1 CC IncludeInFanOut=1, 1 CC IncludeInFanOut=0, 1 BCC)

Re-register the same schedule (idempotent test):

- [ ] Re-run EXEC usp_RegisterSchedule with the same `@ScheduleName` — zero errors
- [ ] Row counts remain the same (UPSERT, not INSERT)

---

## 4. usp_TestDispatch — dispatch queue correctness

Run `EXEC [schdl].[usp_TestDispatch] @ScheduleName = 'Monthly Entity Report — 1st of month', @AsOf = '2025-06-01 06:30', @KeepResults = 1`

> **Note**: Sample A uses DYNAMIC_SQL for all fields against `dbo.Entities`. This test requires `fn_FetchDocumentId` to return a non-NULL value and `dbo.Entities` to be populated with rows matching the `group_id = 'monthly-report'` filter. Adjust queries to match your environment, or change the sample to use STATIC sources for testing without a real entities table.

- [ ] INDIVIDUAL rows (one per entity returned by `valueQuery`):
  - [ ] `DispatchType = 'INDIVIDUAL'`
  - [ ] `DeliveryMethod = 'BOTH'`
  - [ ] `ToAddresses` is non-NULL (resolved from `email AS [EmailAddress]` DYNAMIC_SQL)
  - [ ] `CcAddresses` = `manager@example.com` only (IncludeInFanOut=1 filter)
  - [ ] `BccAddresses` is NULL (BCC has IncludeInFanOut=0)
  - [ ] `DispatchKeyValue` = each `entity_code` value from `valueQuery`
  - [ ] `DisplayName` is non-NULL (resolved from `display_name AS [DisplayName]`)
  - [ ] `FileName` contains `{{DISPLAYNAME}}` resolved (not literal `{{DISPLAYNAME}}`)
  - [ ] `FileName` contains `2025-05-01` (PREV_MONTH_START relative to @AsOf)
  - [ ] `FolderPath` is non-NULL (per-entity `folder_path AS [FolderPath]`)
  - [ ] `EmailSubject` contains resolved DisplayName and `2025-05-01 to 2025-05-31`
- [ ] COMBINED row:
  - [ ] `DispatchType = 'COMBINED'`
  - [ ] `DispatchKeyValue` is NULL
  - [ ] `ToAddresses` is non-NULL (resolved from `email AS [EmailAddress]` where `row_type = 'combined'`)
  - [ ] `CcAddresses` = `manager@example.com,audit@example.com` (all CC)
  - [ ] `BccAddresses = 'archive@example.com'` (all BCC)
  - [ ] `FileName = 'EntityReport_Consolidated_2025-05-01.xlsx'`
  - [ ] `FolderPath` is non-NULL (resolved from `folder_path AS [FolderPath]` where `row_type = 'combined'`)

Clean up: run the cleanup block from `test_dispatch_sample.sql`.

---

## 5. usp_TestDispatch — no fan-out (COMBINED only)

Run Sample B (Daily Sales Summary):

- [ ] Result set contains exactly 1 row
- [ ] `DispatchType = 'COMBINED'`
- [ ] `ToAddresses = 'sales-team@example.com'`
- [ ] `CcAddresses` is NULL
- [ ] `FileName` contains today's date (or @AsOf date) with no `{{TODAY}}` literal

---

## 6. usp_TestDispatch — INDIVIDUAL only (no COMBINED)

Run Sample D (Ad-hoc Client Statement with `mode = 'INDIVIDUAL'`):

- [ ] Result set contains exactly 3 rows (one per ClientID)
- [ ] `DispatchType = 'INDIVIDUAL'` on all rows
- [ ] No COMBINED row (mode is INDIVIDUAL, not BOTH)
- [ ] `ToAddresses` resolved per client

---

## 7. Date token resolution

Create a schedule with date tokens in Subject and FileName, then run `usp_TestDispatch`:

- [ ] `{{TODAY}}` resolves to YYYY-MM-DD format
- [ ] `{{PREV_MONTH_START}}` resolves to first day of previous month
- [ ] `{{PREV_MONTH_END}}` resolves to last day of previous month
- [ ] `{{TODAY-7}}` resolves to 7 days before today (test offset tokens)
- [ ] `{{TODAY+3}}` resolves to 3 days after today (test positive offset)
- [ ] `{{DISPLAYNAME}}` in FileName resolves to the entity name (not the literal string)
- [ ] No `{{TOKEN}}` literals remain in any resolved field — all replaced

---

## 8. usp_GetScheduleJson — round-trip

Run `EXEC [schdl].[usp_GetScheduleJson] @ScheduleName = 'Monthly Entity Report — 1st of month'`:

- [ ] Returns exactly 1 row
- [ ] `RegisterSQL` column is a valid `EXEC [schdl].[usp_RegisterSchedule]` statement
- [ ] `DispatchJson` column is valid JSON (`ISJSON(DispatchJson) = 1`)
- [ ] `ParametersJson` column is valid JSON
- [ ] `DispatchJson` contains `subjectSource`/`subjectSourceValue` (not `subjectTemplate`)
- [ ] `DispatchJson` contains `bodySource`/`bodySourceValue` (not `bodyTemplate`)
- [ ] `ParametersJson` contains `fanOut` key (not `dispatch`) for the primary parameter
- [ ] `fanOut` block contains `subjectSource`, `bodySource`, `fileNameSource` keys

Copy-paste `RegisterSQL` into a new query window and run it:

- [ ] Zero errors
- [ ] Row counts in all tables unchanged (idempotent re-register)
- [ ] `usp_TestDispatch` output is identical after round-trip

---

## 9. usp_GetScheduleJson — HTML round-trip

- [ ] Open `tools/schedule_builder.html` in a browser
- [ ] Copy the `RegisterSQL` output from step 8 into the Load panel textarea
- [ ] Click Load — all steps should pre-fill with the saved schedule values
- [ ] Verify: DocumentName, ScheduleName, FrequencyType, RunTime match
- [ ] Verify: Delivery group shows correct emailSource/subjectSource/bodySource values
- [ ] Verify: Fan-out section shows EntityCode as primary parameter
- [ ] Verify: CC/BCC recipient list shows all 3 recipients with correct roles
- [ ] Generate SQL again — compare to original. Output should be functionally identical.

---

## 10. fn_CalcNextRunAt — NextRunAt calculation

```sql
-- DAILY: must return tomorrow's date
SELECT [schdl].[fn_CalcNextRunAt]('DAILY', NULL, NULL, NULL, '2025-06-12 07:00:00');
-- Expected: 2025-06-13 00:00:00.000

-- WEEKLY: DayOfWeek=1 (Monday) from Thursday 2025-06-12 → next Monday 2025-06-16
SELECT [schdl].[fn_CalcNextRunAt]('WEEKLY', 1, NULL, NULL, '2025-06-12 07:00:00');
-- Expected: 2025-06-16 00:00:00.000

-- WEEKLY: same weekday (Thursday=4) → next week, not today
SELECT [schdl].[fn_CalcNextRunAt]('WEEKLY', 4, NULL, NULL, '2025-06-12 07:00:00');
-- Expected: 2025-06-19 00:00:00.000 (not 2025-06-12)

-- MONTHLY: DayOfMonth=1 from 2025-06-12 → 2025-07-01
SELECT [schdl].[fn_CalcNextRunAt]('MONTHLY', NULL, 1, NULL, '2025-06-12 07:00:00');
-- Expected: 2025-07-01 00:00:00.000

-- MONTHLY: DayOfMonth=-1 (last day) → last day of next month
SELECT [schdl].[fn_CalcNextRunAt]('MONTHLY', NULL, -1, NULL, '2025-06-12 07:00:00');
-- Expected: 2025-07-31 00:00:00.000

-- INTERVAL: 30 minutes from reference point
SELECT [schdl].[fn_CalcNextRunAt]('INTERVAL', NULL, NULL, 30, '2025-06-12 07:00:00');
-- Expected: 2025-06-12 07:30:00.000

-- ADHOC: returns NULL
SELECT [schdl].[fn_CalcNextRunAt]('ADHOC', NULL, NULL, NULL, '2025-06-12 07:00:00');
-- Expected: NULL
```

- [ ] DAILY returns next calendar day (no time component)
- [ ] WEEKLY never returns today even when the weekday matches
- [ ] MONTHLY -1 returns last day of next month
- [ ] MONTHLY clamps to last day when target day > days in month (e.g. day=31 in Feb)
- [ ] INTERVAL returns @AsOf + IntervalMinutes (time-aware, not truncated to date)
- [ ] ADHOC returns NULL

## 11. usp_GetDueSchedules — gate evaluation

Run against a schedule whose gates should all be Y:

```sql
EXEC [schdl].[usp_GetDueSchedules]
    @AsOf = '2025-06-01 06:31:00';  -- after RunTime, on DayOfMonth=1
```

- [ ] Result set 1 shows `Gate_IsActive = Y`, `Gate_DateRange = Y`, `Gate_NextRunAt = Y`, `Gate_Frequency = Y` for the test schedule
- [ ] `Gate_NextRunAt` uses `CAST(NextRunAt AS DATE) <= @Today` (not DATETIME2 comparison) — verify by registering a schedule and checking that a NextRunAt of `'2025-06-01 23:59:00'` still shows `Gate_NextRunAt = Y` at `@AsOf = '2025-06-01 06:31:00'`
- [ ] INTERVAL schedule: `Gate_Frequency` checks `@Now >= NextRunAt` (full datetime, not date-only)
- [ ] Result set 2 contains PENDING rows for the test schedule
- [ ] `NextRunAt` on `Schedule` is advanced after the call (via `fn_CalcNextRunAt`)
- [ ] Running again immediately: `Gate_NextRunAt = N` (not re-fired within the same window)

---

## 12. usp_UpdateDispatchStatus

After running with `@KeepResults = 1`:

```sql
EXEC [schdl].[usp_UpdateDispatchStatus]
    @QueueID      = <QueueID from DispatchQueue>,
    @Status       = 'SUCCESS';
```

- [ ] `DispatchQueue` row: `Status = 'SUCCESS'`, `ProcessedAt` is non-NULL
- [ ] If all rows for that `LogID` are now non-PENDING: `ExecutionLog.Status` updated to `SUCCESS`
- [ ] Test failure path: `@Status = 'FAILED', @ErrorMessage = 'Test error'`
  - [ ] `DispatchQueue` row: `Status = 'FAILED'`, `ErrorMessage` non-NULL
  - [ ] `ExecutionLog.Status = 'FAILED'` once all rows are processed

---

## 13. HTML builder — functional checks

- [ ] Open `tools/schedule_builder.html` in a browser (Chrome/Edge recommended)
- [ ] Step 1: enter a document name, select format/language/confidentiality
- [ ] Step 2: set FrequencyType to each value — verify correct sub-fields show/hide
- [ ] Step 3: add a parameter, set value to `{{TODAY}}` via drag-and-drop from sidebar
- [ ] Step 3: add a second parameter with a DYNAMIC_SQL query — verify badge appears
- [ ] Step 4: set Delivery to BOTH — verify both Email and Folder groups appear
- [ ] Step 4: open Email group, enter a static email address, subject, body
- [ ] Step 4: add a CC recipient with IncludeInFanOut checked, and a BCC recipient
- [ ] Step 5: set Fan-out to INDIVIDUAL, select primary parameter — verify FAN-OUT badge on param card
- [ ] Step 5: open Per-entity Email group, set DYNAMIC_SQL email source
- [ ] Generated SQL: verify `@DispatchJson` and `@ParametersJson` are valid JSON (`Copy` then validate)
- [ ] Generated SQL: confirm no `*Template` keys — only `*Source`/`*SourceValue`
- [ ] Generated SQL: confirm `fanOut` key (not `dispatch`) in `@ParametersJson`
- [ ] Generated SQL: confirm `@RecipientsJson` includes all CC/BCC entries

---

## 14. ADHOC schedule deactivation

Register an ADHOC schedule, run `usp_GetDueSchedules`:

- [ ] Schedule fires in result set 2
- [ ] After firing: `[schdl].[Schedule]` row has `IsActive = 0`
- [ ] Running `usp_GetDueSchedules` again: schedule does NOT appear in result set 2

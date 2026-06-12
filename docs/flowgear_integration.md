# Flowgear Integration Guide

## 1. Overview

The scheduling agent is designed to require **zero branching logic** inside Flowgear. All resolution — parameter values, fan-out entities, email addresses, folder paths, filename templates, token substitution — happens server-side inside `usp_GetDueSchedules`. Flowgear's only job is to iterate the result and deliver each row.

The trigger model:

1. Flowgear calls `EXEC schdl.usp_GetDueSchedules` on a cron schedule.
2. The proc returns two result sets.
3. Flowgear logs result set 1 (diagnostic) and iterates result set 2 (dispatch rows).
4. For each dispatch row, Flowgear POSTs `RequestJson` to the report API, delivers the output (email and/or folder), then calls `usp_UpdateDispatchStatus` with the outcome.
5. No conditional logic is needed beyond checking whether result set 2 is empty.

---

## Live Workflow Reference

A working reference implementation of this integration is available in Flowgear:

**Workflow:** Flowgear - DocGen - Report Scheduler  
**Direct link:** https://app.flowgear.net/#t-genasfem/sites/042f65fe-2723-47c4-9547-a967fec24357/workflows/3568c03f-ac1b-4870-bbb2-f471e1399445/design

This workflow implements the full dispatch loop described in this document.
Import the workflow definition (`docs/flowgear_workflow.json`) into your Flowgear site to use it as a starting point.

---

## 2. Cron trigger

Configure the Flowgear cron trigger to match the most frequent schedule registered:

| Schedule types in use | Recommended trigger frequency |
|---|---|
| DAILY / WEEKLY / MONTHLY only | Fixed time daily (e.g. 06:00) |
| INTERVAL schedules | Every 5–15 minutes |
| Mix of INTERVAL and fixed | Every 5–15 minutes |

The proc handles its own gate logic. Calling it more frequently than needed is safe — it simply returns an empty result set 2 when nothing is due. The gates checked per schedule are:

- **Gate_IsActive** — schedule is enabled (`IsActive = 1`)
- **Gate_DateRange** — execution date is within the schedule's start/end window
- **Gate_NextRunAt** — current time has reached or passed `NextRunAt`
- **Gate_Frequency** — frequency type and day/time constraints are satisfied

All four gates must pass (`'Y'`) before a schedule produces dispatch rows.

---

## 3. Step 1 — Execute usp_GetDueSchedules

```sql
EXEC schdl.usp_GetDueSchedules
```

To test with a specific date/time:

```sql
EXEC schdl.usp_GetDueSchedules @AsOf = '2026-07-01 06:00:00'
```

### Result set 1 — Diagnostic

Always returned. Use for logging and monitoring. **Do not iterate this result set for delivery.**

| Column | Description |
|---|---|
| `ScheduleID` | Internal schedule identifier |
| `ScheduleName` | Human-readable schedule name |
| `FrequencyType` | DAILY / WEEKLY / MONTHLY / INTERVAL / ADHOC |
| `IsActive` | Whether the schedule is enabled |
| `Gate_IsActive` | Y / N — active gate |
| `Gate_DateRange` | Y / N — date range gate |
| `Gate_NextRunAt` | Y / N — timing gate |
| `Gate_Frequency` | Y / N — frequency/day gate |
| `AsOfDate` | Date used for gate evaluation |
| `AsOfTime` | Time used for gate evaluation |

All four `Gate_` columns must be `'Y'` for a schedule to produce rows in result set 2.

### Result set 2 — Dispatch rows

One row per delivery action. If this result set has zero rows, nothing is due — end the workflow.

| Column | Description |
|---|---|
| `QueueID` | Unique identifier — pass back to `usp_UpdateDispatchStatus` |
| `ScheduleID` | Which schedule this row belongs to |
| `ScheduleName` | Human-readable schedule name |
| `DocumentName` | Report document name |
| `ReportEndpoint` | API path to POST `RequestJson` to |
| `DispatchType` | `INDIVIDUAL` (one entity) or `COMBINED` (all entities) |
| `DeliveryMethod` | `EMAIL`, `FOLDER`, or `BOTH` |
| `DispatchKeyValue` | Fan-out value for this row (e.g. entity code); NULL for COMBINED |
| `DisplayName` | Resolved entity label; NULL for COMBINED |
| `FileName` | Resolved filename override; NULL if the report API provides the filename |
| `RequestJson` | Fully built JSON — POST this directly to `ReportEndpoint` |
| `ToAddresses` | Comma-separated TO email addresses |
| `CcAddresses` | Comma-separated CC email addresses (may be empty) |
| `BccAddresses` | Comma-separated BCC email addresses (may be empty) |
| `EmailSubject` | Resolved subject with all tokens substituted |
| `EmailBody` | Resolved body with all tokens substituted |
| `FolderPath` | Resolved folder path; NULL if `DeliveryMethod = 'EMAIL'` |

---

## 4. Step 2 — For each dispatch row

Flowgear iterates result set 2. Each row is processed independently. A failure on one row must not stop the batch — always continue to the next row.

### What the SQL engine resolves before Flowgear sees the row

All field resolution happens server-side in `usp_BuildDispatchQueue`. Flowgear receives fully resolved values — it does not need to apply fallbacks or token substitution. The rules the engine uses:

**Fallback chain** — for INDIVIDUAL fan-out rows, each field tries the per-entity resolver first and falls back to the schedule-level value if the per-entity resolver is not configured:

| DispatchQueue field | Per-entity source (ParameterDispatchConfig) | Fallback (Schedule table) |
|---|---|---|
| `ToAddresses` | `EmailSourceValue` | — (required for INDIVIDUAL rows) |
| `FolderPath` | `FolderSourceValue` | `FolderSourceValue` |
| `FileName` | `FileNameSourceValue` | `FileNameSourceValue` |
| `EmailSubject` | `SubjectSourceValue` | `SubjectSourceValue` |
| `EmailBody` | `BodySourceValue` | `BodySourceValue` |

`DisplayName` is resolved from `ParameterDispatchConfig.DisplayNameSourceValue` and is
available as the `{{DISPLAYNAME}}` token in subject, body, and filename templates.

**CcAddresses routing:**

| DispatchType | CcAddresses content |
|---|---|
| `INDIVIDUAL` | Only standing recipients with `IncludeInFanOut = 1` |
| `COMBINED` | All standing CC recipients regardless of `IncludeInFanOut` |

BccAddresses follows the same split as CcAddresses. Neither CC nor BCC addresses ever
appear in `ToAddresses`.

**Overwrite risk when folder + filename are unresolved:**
If a fan-out schedule uses FOLDER delivery and no per-entity `FolderSourceValue` or
`FileNameSourceValue` is configured, all INDIVIDUAL rows will share the same `FolderPath`
and `FileName`. Each file write will overwrite the previous one. To avoid this, configure
per-entity `FileNameSourceValue` to include `{{DISPLAYNAME}}` or `{VALUE}` so each entity
produces a unique filename.

**Token resolution:**
`fn_ResolveAllTokens` is applied server-side to `EmailSubject`, `EmailBody`, `FileName`,
and `FolderPath` before rows are written to `DispatchQueue`. No `{{TOKEN}}` placeholders
remain in the result set — all are substituted with their resolved values.

---

### 4a. POST RequestJson to ReportEndpoint

```
Method:       POST
URL:          {row.ReportEndpoint}
Content-Type: application/json
Body:         {row.RequestJson}
```

The response contains the generated report file. Extract:
- The file content (base64-encoded or binary, depending on the API)
- The default filename from the response, if `row.FileName` is NULL

**On failure:** call `usp_UpdateDispatchStatus` with `@Status = 'FAILED'` and the error detail. Continue to the next row.

### 4b. If DeliveryMethod is EMAIL or BOTH — send email

| Field | Value |
|---|---|
| To | `row.ToAddresses` — split by comma if multiple recipients |
| CC | `row.CcAddresses` — split by comma if multiple; may be empty |
| BCC | `row.BccAddresses` — split by comma if multiple; may be empty |
| Subject | `row.EmailSubject` |
| Body | `row.EmailBody` |
| Attachment filename | `row.FileName` if not NULL, otherwise use filename from report API response |
| Attachment content | Report file from step 4a |

**On failure:** call `usp_UpdateDispatchStatus` with `@Status = 'FAILED'` and the error detail. Continue to the next row.

### 4c. If DeliveryMethod is FOLDER or BOTH — write file to folder

| Field | Value |
|---|---|
| Folder | `row.FolderPath` |
| Filename | `row.FileName` if not NULL, otherwise use filename from report API response |
| Content | Report file from step 4a |

The full file path is `row.FolderPath` + `row.FileName`. Check whether `FolderPath` already has a trailing backslash or forward slash before concatenating.

**On failure:** call `usp_UpdateDispatchStatus` with `@Status = 'FAILED'` and the error detail. Continue to the next row.

### 4d. Call usp_UpdateDispatchStatus

After each row is fully processed — whether success or failure:

```sql
EXEC schdl.usp_UpdateDispatchStatus
    @QueueID      = {row.QueueID},
    @Status       = 'SENT',    -- or 'SUCCESS' — both indicate successful delivery
    @ErrorMessage = NULL       -- or error detail string on failure
```

The reference Flowgear workflow uses `'SUCCESS'`; both `'SENT'` and `'SUCCESS'` are accepted values.

**This must be called for every row.** Rows that remain in `PENDING` status may be reprocessed on the next trigger run.

---

## 5. Step 3 — After all rows processed

No further action is required. The proc automatically:
- Advances `NextRunAt` on the schedule for DAILY / WEEKLY / MONTHLY / INTERVAL frequency types
- Sets `IsActive = 0` on ADHOC schedules after they fire

---

## 6. Error handling summary

| Scenario | Action |
|---|---|
| Result set 2 is empty | Nothing due — end workflow normally |
| Report API POST fails | Mark row FAILED, continue to next row |
| Email send fails | Mark row FAILED, continue to next row |
| Folder write fails | Mark row FAILED, continue to next row |
| `usp_GetDueSchedules` errors | Log the error; do not call `usp_UpdateDispatchStatus` |
| `DeliveryMethod = BOTH`, email succeeds but folder fails | Mark FAILED with folder error detail |

Never abort the entire batch due to a single row failing. Always call `usp_UpdateDispatchStatus` for every row that was attempted.

---

## 7. Monitoring

### Recent dispatch history

```sql
-- Execution summary with sent/failed counts
SELECT
    el.LogID,
    s.ScheduleName,
    el.ExecutedAt,
    el.Status,
    COUNT(dq.QueueID)                                                           AS TotalRows,
    SUM(CASE WHEN dq.Status IN ('SENT','SUCCESS') THEN 1 ELSE 0 END)           AS Sent,
    SUM(CASE WHEN dq.Status = 'FAILED'            THEN 1 ELSE 0 END)           AS Failed,
    SUM(CASE WHEN dq.Status = 'PENDING'           THEN 1 ELSE 0 END)           AS Pending
FROM      schdl.ExecutionLog   el
JOIN      schdl.Schedule       s  ON s.ScheduleID = el.ScheduleID
LEFT JOIN schdl.DispatchQueue  dq ON dq.LogID     = el.LogID
GROUP BY  el.LogID, s.ScheduleName, el.ExecutedAt, el.Status
ORDER BY  el.ExecutedAt DESC;
```

### Failed rows with error detail

```sql
SELECT
    dq.QueueID, s.ScheduleName, dq.DispatchType, dq.DeliveryMethod,
    dq.DispatchKeyValue, dq.ToAddresses, dq.FolderPath,
    dq.ErrorMessage, dq.CreatedAt
FROM     schdl.DispatchQueue dq
JOIN     schdl.Schedule      s  ON s.ScheduleID = dq.ScheduleID
WHERE    dq.Status = 'FAILED'
ORDER BY dq.CreatedAt DESC;
```

---

## 8. Flowgear node sequence

This is the actual node sequence from the reference workflow (see **Live Workflow Reference** above).

```
1. Start
   └─ Cron trigger
   └─ Last_Error_Info output carries forward to the error handler

2. Microsoft SQL Query — "EXEC schdl.usp_GetDueSchedules"
   └─ Query: EXEC schdl.usp_GetDueSchedules
   └─ Output: ResultXml
        ResultXml.Table  → diagnostic result set (log only)
        ResultXml.Table1 → dispatch rows (iterate this)

3. If — "Any Report Is Due"
   └─ Input:      ResultXml.Table1
   └─ Expression: Value <> ""
   └─ True  → proceed to For Each
   └─ False → end workflow (nothing due)

4. For Each
   └─ SourceDocument: ResultXml.Table1
   └─ Path:           [*]   (every dispatch row)
   └─ ChunkSize:      1     (one row at a time)
   └─ Outputs: Item (current row), ItemIndex, ItemCount

5. Formatter — "Get The DocGen Request Json"
   └─ Expression: RequestJson   (field from current Item)
   └─ Escaping:   JSON
   └─ Cleans the RequestJson string before passing to the API

6. Genasys SKi API — "Generate Report"
   └─ OperationId: (report generation operation)
   └─ Request:     Formatter.Result
   └─ Returns a job/report ID
   └─ On error → ERROR HANDLER PATH

7. Genasys SKi API — "Fetch Report"
   └─ OperationId: (report fetch operation)
   └─ Request:     report ID from step 6 response
   └─ Returns the generated report file (binary/base64)
   └─ On error → ERROR HANDLER PATH

8. Choose — "Dispatch Method"
   └─ Expression: DeliveryMethod   (from current ForEach Item)
   └─ EMAIL  → node 9a (Single Email)
   └─ FOLDER → node 9b (File Copy)
   └─ BOTH   → node 9a then node 9b
   └─ Error  → ERROR HANDLER PATH

9a. Single Email  [EMAIL and BOTH branches]
    └─ Recipients:     Item.ToAddresses
    └─ RecipientsCC:   Item.CcAddresses
    └─ RecipientsBCC:  Item.BccAddresses
    └─ Subject:        Item.EmailSubject
    └─ Body:           Item.EmailBody
    └─ Attachment:     Genasys SKi API "Fetch Report" Response
    └─ AttachmentName: Item.FileName
    └─ On success → node 10 (Mark As Successful)
    └─ On error   → ERROR HANDLER PATH

9b. File Copy  [FOLDER branch, also follows 9a for BOTH]
    └─ SourcePath:      Genasys SKi API "Fetch Report" Response
    └─ DestinationPath: Item.FolderPath
    └─ On success → node 10 (Mark As Successful)
    └─ On error   → ERROR HANDLER PATH

10. Microsoft SQL Query — "Mark As Successful"
    └─ EXEC schdl.usp_UpdateDispatchStatus
         @QueueID      = Item.QueueID
         @Status       = 'SUCCESS'
         @ErrorMessage = NULL

━━━ ERROR HANDLER PATH (shared by all error outputs) ━━━

    Replace — "Grab Last Error"
    └─ Input: Start.Last_Error_Info
    └─ Replaces single quotes with '' for SQL safety

    Formatter — "Capture Error"
    └─ Formats the cleaned error message string

    Microsoft SQL Query — "Mark As Failed"
    └─ EXEC schdl.usp_UpdateDispatchStatus
         @QueueID      = Item.QueueID   (from ForEach)
         @Status       = 'FAILED'
         @ErrorMessage = Formatter.Result

11. End
```

Every node's Error output routes to the shared error handler, which calls `usp_UpdateDispatchStatus` with `@Status = 'FAILED'`. This ensures every row receives a status update even on failure, and the ForEach continues to the next row.

---

## 9. Testing without Flowgear

Before wiring Flowgear, verify dispatch output directly in SSMS using `usp_TestDispatch`. This bypasses all timing gates and writes directly to `DispatchQueue` with `Status = 'PENDING'`.

```sql
-- Run a test dispatch for a specific schedule
EXEC schdl.usp_TestDispatch
    @ScheduleName = 'Your Schedule Name',
    @KeepResults  = 1;

-- Inspect the queued rows
SELECT
    QueueID, DispatchType, DeliveryMethod, DispatchKeyValue,
    DisplayName, FileName, ToAddresses, CcAddresses,
    EmailSubject, FolderPath,
    LEFT(RequestJson, 500) AS RequestJsonPreview
FROM   schdl.DispatchQueue
WHERE  Status = 'PENDING'
ORDER  BY DispatchType DESC, DispatchKeyValue;

-- Clean up test rows when done
DELETE FROM schdl.DispatchQueue
WHERE  Status = 'PENDING';
```

Use `usp_TestDispatch` to confirm:
- The correct number of rows are produced (1 COMBINED, or N INDIVIDUAL + 1 COMBINED for fan-out)
- `ToAddresses`, `CcAddresses`, and `FolderPath` resolve to the expected values
- `RequestJson` contains the correct parameter values with all tokens substituted
- `EmailSubject` shows the resolved subject (no unresolved `{{...}}` tokens)

---

## 10. Implementation notes from the reference workflow

These notes come from the working Flowgear implementation (see **Live Workflow Reference**).

1. **Result set extraction** — The SQL Query node returns XML. The dispatch rows are in `Table1` (second result set); use expression `ResultXml.Table1` to extract them. The diagnostic `Table` (first result set) should be logged but not iterated.

2. **If check on Table1** — Before entering the ForEach, check that `Table1` is non-empty using expression `Value <> ""` on the Table1 data. If empty, end the workflow — there is nothing due.

3. **RequestJson escaping** — The ForEach `Item` contains `RequestJson` as a string field. Use a Formatter node with JSON escaping mode to clean it before passing to the API. This prevents escaping issues when the JSON contains nested quotes.

4. **Two API calls per row** — The Genasys API requires two sequential calls per report: one to **generate** (submit the job) and one to **fetch** (retrieve the file). The generate call returns a job/report ID; the fetch call uses that ID to retrieve the binary. Wire Generate → Fetch before branching on `DeliveryMethod`.

5. **FileName as attachment name** — `Item.FileName` from `DispatchQueue` is used directly as the email attachment filename. If `FileName` is NULL, use the filename returned by the report API response as fallback.

6. **Error handling is per-row** — Every node's Error output routes to the shared error handler, which calls `usp_UpdateDispatchStatus` with `@Status = 'FAILED'`. This ensures every row gets a status update even on failure, and the ForEach continues to the next row without stopping the batch.

7. **Single quotes in error messages** — Flowgear error messages may contain single quotes, which would break the SQL `UPDATE`. Use a Replace node (in the error handler path) to substitute `'` with `''` before passing to `usp_UpdateDispatchStatus`.

8. **Status value — SUCCESS vs SENT** — The reference workflow uses `'SUCCESS'` as the status for successfully processed rows. The SQL proc and `DispatchQueue` table both accept `'SENT'` and `'SUCCESS'` as equivalent success values. Either works; the reference workflow uses `'SUCCESS'`.

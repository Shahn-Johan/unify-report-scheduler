# Configuration Guide — Scheduling Agent v3

Complete reference for registering schedules via `usp_RegisterSchedule`.

---

## usp_RegisterSchedule — parameter reference

```sql
EXEC [schdl].[usp_RegisterSchedule]
    -- Document
    @DocumentName    NVARCHAR(255),      -- maps to fn_FetchDocumentId lookup
    @ReportEndpoint  NVARCHAR(500),      -- API path posted to by Flowgear
    @OutputFormat    NVARCHAR(50)  = NULL,
    @Language        INT           = NULL,
    @Confidentiality NVARCHAR(50)  = NULL,

    -- Schedule timing
    @ScheduleName    NVARCHAR(255),      -- unique key; re-running UPSERTs all rows
    @FrequencyType   NVARCHAR(20),       -- DAILY | WEEKLY | MONTHLY | INTERVAL | ADHOC
    @RunTime         NVARCHAR(5)  = NULL, -- 'HH:MM' — required for DAILY/WEEKLY/MONTHLY
    @DayOfWeek       TINYINT      = NULL, -- 1=Mon … 7=Sun — required for WEEKLY
    @DayOfMonth      SMALLINT     = NULL, -- 1-28 or -1 (last day) — required for MONTHLY
    @IntervalMinutes INT          = NULL, -- required for INTERVAL
    @WindowStart     NVARCHAR(5)  = NULL, -- 'HH:MM' — INTERVAL window open
    @WindowEnd       NVARCHAR(5)  = NULL, -- 'HH:MM' — INTERVAL window close
    @StartDate       DATE         = NULL, -- schedule active from (inclusive)
    @EndDate         DATE         = NULL, -- schedule active until (inclusive)

    -- Delivery + recipients
    @DispatchJson    NVARCHAR(MAX) = NULL, -- schedule-level delivery config (JSON)
    @ParametersJson  NVARCHAR(MAX) = NULL, -- parameter array with optional fanOut block
    @RecipientsJson  NVARCHAR(MAX) = NULL  -- CC/BCC standing recipients (JSON)
```

`NextRunAt` is set automatically via `fn_CalcNextRunAt` on every INSERT and UPDATE.

---

## @DispatchJson

Schedule-level delivery configuration. All keys are optional except `deliveryMethod`.

```json
{
  "deliveryMethod":      "EMAIL | FOLDER | BOTH",

  "emailSource":         "STATIC | DYNAMIC_SQL",
  "emailSourceValue":    "literal address, or SELECT returning one address",

  "subjectSource":       "STATIC | DYNAMIC_SQL",
  "subjectSourceValue":  "subject text — supports {{TOKEN}} placeholders",

  "bodySource":          "STATIC | DYNAMIC_SQL",
  "bodySourceValue":     "plain text body — supports {{TOKEN}} placeholders",

  "fileNameSource":      "STATIC | DYNAMIC_SQL",
  "fileNameSourceValue": "filename.xlsx — supports {{TOKEN}} placeholders",

  "folderSource":        "STATIC | DYNAMIC_SQL",
  "folderSourceValue":   "\\\\server\\share\\path or SELECT returning a path"
}
```

For COMBINED dispatch (no fan-out), `emailSourceValue` is the TO address.
For INDIVIDUAL/BOTH dispatch, `emailSourceValue` is the TO address of the COMBINED row. Per-entity TO comes from `fanOut.emailSourceValue`.

---

## @ParametersJson

Array of parameter objects. Each maps to one row in `ScheduleDocumentParameter` and `ScheduleParameter`.

```json
[
  {
    "name":      "EntityCode",
    "type":      "string",
    "required":  true,
    "sortOrder": 1,
    "value":     "E001|E002|E003",
    "fanOut": { }
  },
  {
    "name":      "ReportDate",
    "type":      "string",
    "required":  true,
    "sortOrder": 2,
    "value":     "{{PREV_MONTH_END}}"
  }
]
```

Pipe-separated `value` strings are shredded at dispatch time — each segment becomes one parameter value in the request JSON.

To supply values at runtime, use `parameterValueQuery` instead of `value`:

```json
{
  "name": "EntityCode",
  "type": "string",
  "parameterValueQuery": "SELECT EntityCode FROM dbo.Entities WHERE IsActive = 1"
}
```

The query executes at dispatch time; results are pipe-joined and treated identically to a static value.

### fanOut block

Marks one parameter as the primary dispatch key. Triggers per-entity row generation.

```json
"fanOut": {
  "isPrimary":              true,
  "mode":                   "INDIVIDUAL | BOTH",

  "emailSource":            "STATIC | DYNAMIC_SQL",
  "emailSourceValue":       "per-entity address, or SELECT with {VALUE} placeholder",

  "displayNameSource":      "STATIC | DYNAMIC_SQL",
  "displayNameSourceValue": "entity label — resolved value replaces {{DISPLAYNAME}}",

  "fileNameSource":         "STATIC | DYNAMIC_SQL",
  "fileNameSourceValue":    "per-entity filename — supports {{DISPLAYNAME}} and {{TOKEN}}",

  "folderSource":           "STATIC | DYNAMIC_SQL",
  "folderSourceValue":      "per-entity folder path",

  "subjectSource":          "STATIC | DYNAMIC_SQL",
  "subjectSourceValue":     "per-entity subject override",

  "bodySource":             "STATIC | DYNAMIC_SQL",
  "bodySourceValue":        "per-entity body override"
}
```

`mode = "INDIVIDUAL"` → N INDIVIDUAL rows only.
`mode = "BOTH"` → N INDIVIDUAL rows + 1 COMBINED row.

---

## Source types

Only two source types are supported:

| Source | `*SourceValue` content |
|---|---|
| `STATIC` | Literal string. `{{TOKEN}}` placeholders resolved at dispatch time. |
| `DYNAMIC_SQL` | `SELECT` statement. `{VALUE}` replaced with the fan-out value before execution. Returns a single scalar. |

**LOOKUP_VIEW and SCALAR_FN are not supported** — both patterns are replaced by DYNAMIC_SQL.

### DYNAMIC_SQL examples

Email from a table:
```json
"emailSource":      "DYNAMIC_SQL",
"emailSourceValue": "SELECT email FROM dbo.Entities WHERE code = '{VALUE}'"
```

Folder from a table:
```json
"folderSource":      "DYNAMIC_SQL",
"folderSourceValue": "SELECT folder_path FROM dbo.Entities WHERE code = '{VALUE}'"
```

Schedule-level dynamic email (no `{VALUE}` needed for COMBINED):
```json
"emailSource":      "DYNAMIC_SQL",
"emailSourceValue": "SELECT TOP 1 email FROM dbo.Config WHERE key = 'reports_to'"
```

---

## @RecipientsJson

Standing CC/BCC recipients added to every dispatch run for this schedule.
**TO is not a valid role** — TO always comes from `@DispatchJson.emailSourceValue`.

```json
[
  { "email": "manager@example.com", "role": "CC",  "includeInFanOut": true  },
  { "email": "audit@example.com",   "role": "CC",  "includeInFanOut": false },
  { "email": "archive@example.com", "role": "BCC", "includeInFanOut": false }
]
```

| Field | Values |
|---|---|
| `role` | `CC` or `BCC` only |
| `includeInFanOut` | `true` → on INDIVIDUAL rows (`@CcFanOut`); `false` → COMBINED row only (`@CcAll`) |

`ScheduleStandingRecipient` rows are DELETE + re-INSERT on every `usp_RegisterSchedule` call.

---

## Fallback chain (INDIVIDUAL rows)

Per-entity overrides tried first; schedule-level values are the fallback:

| Field | Per-entity resolver | Fallback |
|---|---|---|
| `ToAddresses` | `fanOut.emailSourceValue` | — (required for INDIVIDUAL) |
| `DisplayName` | `fanOut.displayNameSource/Value` | — (NULL if not set) |
| `FileName` | `fanOut.fileNameSource/Value` | `@DispatchJson.fileNameSourceValue` |
| `FolderPath` | `fanOut.folderSource/Value` | `@DispatchJson.folderSourceValue` |
| `EmailSubject` | `fanOut.subjectSource/Value` | `@DispatchJson.subjectSourceValue` |
| `EmailBody` | `fanOut.bodySource/Value` | `@DispatchJson.bodySourceValue` |
| `CcAddresses` | `@CcFanOut` (IncludeInFanOut=1) | — |
| `BccAddresses` | `@BccFanOut` (IncludeInFanOut=1) | — |

COMBINED rows always use schedule-level resolvers. `CcAddresses = @CcAll` (all CC recipients).

---

## Token resolution

`{{TOKEN}}` placeholders are replaced in all `*SourceValue` fields at dispatch time.

| Token | Resolves to |
|---|---|
| `{{TODAY}}` | Current date (YYYY-MM-DD) |
| `{{TODAY-N}}` / `{{TODAY+N}}` | N days before/after today |
| `{{WEEK_START}}` / `{{WEEK_END}}` | Monday/Sunday of current week |
| `{{PREV_WEEK_START}}` / `{{PREV_WEEK_END}}` | Monday/Sunday of prior week |
| `{{MONTH_START}}` / `{{MONTH_END}}` | First/last day of current month |
| `{{PREV_MONTH_START}}` / `{{PREV_MONTH_END}}` | First/last day of prior month |
| `{{NEXT_MONTH_START}}` / `{{NEXT_MONTH_END}}` | First/last day of next month |
| `{{QUARTER_START}}` / `{{QUARTER_END}}` | First/last day of current quarter |
| `{{PREV_QUARTER_START}}` / `{{PREV_QUARTER_END}}` | First/last day of prior quarter |
| `{{YEAR}}` / `{{YEAR_START}}` / `{{YEAR_END}}` | Current year / Jan 1 / Dec 31 |
| `{{PREV_YEAR}}` / `{{PREV_YEAR_START}}` / `{{PREV_YEAR_END}}` | Prior year values |
| `{{REPORTNAME}}` | The schedule's `DocumentName` |
| `{{DISPLAYNAME}}` | Resolved entity display name (replaced after all other tokens) |

**Resolution order:** Dynamic SQL executes first → `fn_ResolveAllTokens` → `{{DISPLAYNAME}}` replaced last.

---

## Frequency types

| FrequencyType | Required fields | NextRunAt behaviour |
|---|---|---|
| `DAILY` | `RunTime` | Next calendar day (date only, no time component) |
| `WEEKLY` | `RunTime`, `DayOfWeek` | Next occurrence of the weekday; same weekday = next week |
| `MONTHLY` | `RunTime`, `DayOfMonth` | Target day of next month; `-1` = last day; clamped to month length |
| `INTERVAL` | `IntervalMinutes`, `WindowStart`, `WindowEnd` | `DATEADD(MINUTE, IntervalMinutes, @Now)` — full datetime |
| `ADHOC` | None | `NULL`; `IsActive` set to `0` after first fire |

---

## fn_FetchDocumentId

```sql
[schdl].[fn_FetchDocumentId](@ScheduleID INT) RETURNS INT
```

Called internally by `usp_BuildDispatchQueue`. Looks up `DocumentName` from `ScheduleDocument` then queries `dbo.Document` for the document ID.

> **Environment note:** The function body queries `dbo.Document` using column names specific to the target environment. Verify that column names match before go-live and update the function body if they differ.

---

## Table reference

| Table | Purpose |
|---|---|
| `Schedule` | Root schedule definition — timing, delivery config, NextRunAt |
| `ScheduleDocument` | 1:1 with Schedule — document name, endpoint, format |
| `ScheduleDocumentParameter` | Parameter definitions per schedule |
| `ScheduleParameter` | Parameter values per schedule |
| `ScheduleParameterDispatchConfig` | Fan-out config per primary parameter per schedule |
| `ScheduleStandingRecipient` | CC/BCC standing recipients per schedule |
| `DateToken` | Reference table of all supported `{{TOKEN}}` strings |
| `ExecutionLog` | One row per scheduler execution |
| `DispatchQueue` | One row per delivery action per execution |

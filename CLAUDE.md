# CLAUDE.md — Scheduling Agent

> Auto-loaded by Claude Code at session start. Full architecture context — no re-explanation needed.

---

## Architecture

### Repo structure

```
unify-report-scheduler/
├── CLAUDE.md                               ← this file — read first
├── PLAN.md                                 ← implementation status
├── README.md                               ← quick-start
├── sql/
│   ├── deploy/
│   │   └── scheduling_agent_v3.sql         ← full drop-and-create deploy script (SOURCE OF TRUTH)
│   ├── samples/
│   │   ├── register_schedule_sample.sql    ← full-featured EXEC sample (v3 API)
│   │   ├── test_dispatch_sample.sql        ← TestDispatch call + expected output
│   │   └── scheduling_agent_samples.sql    ← ⚠ STALE — old API, do not use as reference
│   └── tests/
│       ├── validation_checklist.md         ← manual QA checklist
│       └── scheduling_agent_test_suite.sql ← ⚠ STALE — old API, do not use as reference
├── docs/
│   ├── flowgear_integration.md             ← Flowgear node sequence + dispatch behaviour (current)
│   ├── execution_flow.md                   ← complete dispatch pipeline walkthrough (current)
│   ├── html_builder.md                     ← HTML builder internals (current)
│   └── configuration_guide.md             ← ⚠ STALE — references old LOOKUP_VIEW/SCALAR_FN pattern
└── tools/
    └── schedule_builder.html               ← standalone HTML builder (SOURCE OF TRUTH)
```

### Two deliverables

| File | What it is |
|---|---|
| `sql/deploy/scheduling_agent_v3.sql` | Full drop-and-create T-SQL. Run this to deploy. Safe to re-run (idempotent). Schema: `[schdl]` |
| `tools/schedule_builder.html` | Single-file SPA. Open in any browser. No build step, no dependencies |

### How they interlock

- HTML `syncCore()` generates a valid `EXEC [schdl].[usp_RegisterSchedule]` statement
- `usp_GetScheduleJson` reads a live schedule and reconstructs the exact `RegisterSQL` to re-register it
- HTML `loadSchedule()` parses that `RegisterSQL` output back into `fieldState` / `rcpState`
- Round-trip: HTML → SQL → database → `usp_GetScheduleJson` → HTML

---

## SQL schema

### Tables (in DROP order — FK-safe reverse)

The v3 schema is **schedule-centric**: every schedule owns its own document config, parameter definitions, and dispatch config. There is no shared document catalogue.

| Table | Purpose |
|---|---|
| `DispatchQueue` | One row per delivery action per execution |
| `ExecutionLog` | One row per scheduler execution |
| `ScheduleStandingRecipient` | CC/BCC static recipients per schedule — **never TO** |
| `ScheduleRecipient` | DROP target only (legacy name) — not created in v3 |
| `ScheduleParameter` | Runtime parameter values per schedule |
| `ScheduleParameterDispatchConfig` | Fan-out and per-entity resolver config per parameter (was `ParameterDispatchConfig`) |
| `ParameterDispatchConfig` | DROP target only (legacy name) — not created in v3 |
| `ScheduleDocumentParameter` | Parameter definitions per schedule (was `DocumentParameter`) |
| `DocumentParameter` | DROP target only (legacy name) — not created in v3 |
| `ScheduleDocument` | 1:1 per-schedule document config: name, endpoint, format, language (was `Document`) |
| `Schedule` | Schedule definitions (timing + all delivery config columns) |
| `Document` | DROP target only (legacy name) — not created in v3 |
| `DateToken` | Reference table of all supported `{{TOKEN}}` strings |

### Source/Value pattern

**All** resolver fields use exactly two source types — no exceptions:

| Source | SourceValue content |
|---|---|
| `STATIC` | Literal string; `{{REPORTNAME}}` and date tokens resolved at runtime by `fn_ResolveAllTokens` |
| `DYNAMIC_SQL` | `SELECT` statement; `{VALUE}` placeholder replaced with fan-out value before execution |

> **LOOKUP_VIEW and SCALAR_FN are gone.** `configuration_guide.md` still mentions them — ignore that file for implementation. DYNAMIC_SQL replaces both.

### Schedule table delivery columns

All live on `Schedule` — never on `ScheduleParameterDispatchConfig`:

```
DeliveryMethod   NVARCHAR(10)   EMAIL | FOLDER | BOTH
EmailSource      NVARCHAR(20)   STATIC | DYNAMIC_SQL
EmailSourceValue NVARCHAR(MAX)
SubjectSource    NVARCHAR(20)   STATIC | DYNAMIC_SQL
SubjectSourceValue NVARCHAR(MAX)
BodySource       NVARCHAR(20)   STATIC | DYNAMIC_SQL
BodySourceValue  NVARCHAR(MAX)
FileNameSource   NVARCHAR(20)   STATIC | DYNAMIC_SQL
FileNameSourceValue NVARCHAR(MAX)
FolderSource     NVARCHAR(20)   STATIC | DYNAMIC_SQL
FolderSourceValue NVARCHAR(MAX)
```

### ScheduleDocument table (1:1 with Schedule)

```
ScheduleDocumentID  INT IDENTITY PK
ScheduleID          INT NOT NULL UNIQUE FK → Schedule
DocumentName        NVARCHAR(255) NOT NULL
ReportEndpoint      NVARCHAR(500) NOT NULL
DefaultOutputFormat NVARCHAR(20)  DEFAULT 'xlsx'
DefaultLanguage     INT           DEFAULT 1
DefaultConfidentiality NVARCHAR(50) DEFAULT 'normal'
```

### ScheduleDocumentParameter — parameter definitions (PK: ScheduleParameterID)

```
ScheduleParameterID  INT IDENTITY PK
ScheduleDocumentID   INT FK → ScheduleDocument
ScheduleID           INT FK → Schedule
ParameterName        NVARCHAR(100) NOT NULL
DataType             NVARCHAR(50)  DEFAULT 'string'
IsRequired           BIT           DEFAULT 1
SortOrder            INT           DEFAULT 0
UNIQUE (ScheduleID, ParameterName)
```

### ScheduleParameterDispatchConfig resolver columns

Per-entity overrides — resolve once per fan-out value, fall back to Schedule-level if NULL:

```
ConfigID             INT IDENTITY PK
ScheduleParameterID  INT FK → ScheduleDocumentParameter
ScheduleID           INT FK → Schedule
IsPrimaryDispatchKey BIT           DEFAULT 0
DispatchMode         NVARCHAR(12)  COMBINED | INDIVIDUAL | BOTH
EmailSource / EmailSourceValue         → ToAddresses (INDIVIDUAL rows)
DisplayNameSource / DisplayNameSourceValue → DisplayName → {{DISPLAYNAME}} token
FileNameSource / FileNameSourceValue   → FileName (falls back to Schedule.FileNameSourceValue)
FolderSource / FolderSourceValue       → FolderPath (falls back to Schedule.FolderSourceValue)
SubjectSource / SubjectSourceValue     → EmailSubject (falls back to Schedule.SubjectSourceValue)
BodySource / BodySourceValue           → EmailBody (falls back to Schedule.BodySourceValue)
UNIQUE (ScheduleID, ScheduleParameterID)
```

### ScheduleParameter — runtime values

```
ScheduleParamID     INT IDENTITY PK
ScheduleID          INT FK → Schedule
ScheduleParameterID INT FK → ScheduleDocumentParameter
ParameterValue      NVARCHAR(MAX) NOT NULL
ParameterValueQuery NVARCHAR(MAX) NULL   ← DYNAMIC_SQL query for runtime resolution
UNIQUE (ScheduleID, ScheduleParameterID)
```

### Standing recipients (ScheduleStandingRecipient)

- CC/BCC **only** — TO is always resolved from `Schedule.EmailSourceValue`
- `IncludeInFanOut` flag — when 1, the recipient is included on INDIVIDUAL rows (`@CcFanOut`)
- INDIVIDUAL rows: `CcAddresses = @CcFanOut`, COMBINED row: `CcAddresses = @CcAll`
- Neither `@CcFanOut` nor `@CcAll` ever goes to `ToAddresses`

### Functions

| Function | Section | Purpose |
|---|---|---|
| `fn_ResolveDateToken` | 2.1 | Resolves a single `{{TOKEN}}` or `{{TODAY±N}}` string to YYYY-MM-DD |
| `fn_ResolveAllTokens` | 2.2 | Applies `fn_ResolveDateToken` to every token in a full string; also resolves `{{REPORTNAME}}` |
| `fn_FetchDocumentId` | 2.3 | Looks up `DocumentName` from `ScheduleDocument` then queries `dbo.Document`; stub — implement per environment |
| `fn_CalcNextRunAt` | 2.4 | Calculates the correct next `NextRunAt` DATETIME2 given frequency + reference time |

### fn_CalcNextRunAt

`[schdl].[fn_CalcNextRunAt](@FrequencyType, @DayOfWeek, @DayOfMonth, @IntervalMinutes, @AsOf DATETIME2) RETURNS DATETIME2`

| FrequencyType | NextRunAt result |
|---|---|
| `DAILY` | Next calendar day (flat DATE, no time component) |
| `WEEKLY` | Next occurrence of `@DayOfWeek`; same weekday = next week, never today |
| `MONTHLY` | Target day of next month; `-1` = last day; clamped to last day if month is shorter |
| `INTERVAL` | `DATEADD(MINUTE, @IntervalMinutes, @AsOf)` — time-aware |
| `ADHOC` | Returns `NULL` |

Called by `usp_RegisterSchedule` (on both INSERT and UPDATE) and `usp_GetDueSchedules` (after firing).

### Stored procedures

| Proc | Section | Purpose |
|---|---|---|
| `usp_RegisterSchedule` | 3 | Full UPSERT — schedule + document + parameters + dispatch config + recipients; sets `NextRunAt` via `fn_CalcNextRunAt` |
| `usp_BuildDispatchQueue` | 4.1 | Internal — builds DispatchQueue rows for one schedule |
| `usp_GetDueSchedules` | 4.2 | Flowgear entry point — gate checks + dispatch rows (2 result sets); advances `NextRunAt` via `fn_CalcNextRunAt` |
| `usp_UpdateDispatchStatus` | 4.3 | Flowgear callback — marks rows SENT/SUCCESS/FAILED |
| `usp_TestDispatch` | 4.4 | Test helper — bypasses all gates, does NOT advance NextRunAt |
| `usp_GetScheduleJson` | 4.5 | Reads live schedule → reconstructs RegisterSQL for HTML round-trip |

### usp_RegisterSchedule — write order

Schedule is upserted **first** (it is the root FK target), then:

1. `[schdl].[Schedule]` — UPSERT by ScheduleName; sets `NextRunAt = fn_CalcNextRunAt(...)` on both INSERT and UPDATE
2. `[schdl].[ScheduleDocument]` — UPSERT by ScheduleID
3. `[schdl].[ScheduleDocumentParameter]` — UPSERT per parameter (by ScheduleID + ParameterName)
4. `[schdl].[ScheduleParameterDispatchConfig]` — UPSERT or DELETE per parameter
5. `[schdl].[ScheduleParameter]` — UPSERT per parameter (only if value is non-NULL)
6. `[schdl].[ScheduleStandingRecipient]` — DELETE all for ScheduleID, then INSERT

### usp_BuildDispatchQueue — dispatch flow

1. Resolve dynamic `ParameterValueQuery` rows → `#DynVals`
2. Shred all parameter values (date tokens resolved, pipe-split) → `#Raw` → `#P`
   - JOIN: `ScheduleParameter sp JOIN ScheduleDocumentParameter dp ON dp.ScheduleParameterID = sp.ScheduleParameterID AND dp.ScheduleID = @ScheduleID LEFT JOIN ScheduleParameterDispatchConfig dc ON dc.ScheduleParameterID = dp.ScheduleParameterID AND dc.ScheduleID = @ScheduleID`
   - The `AND ScheduleID = @ScheduleID` filters on **both** joins — prevents cross-schedule row contamination
3. Collect `@CcAll`, `@CcFanOut`, `@BccAll`, `@BccFanOut` from ScheduleStandingRecipient
4. If no primary parameter (IsPrimaryDispatchKey=1) → emit one COMBINED row using schedule-level resolvers
5. If INDIVIDUAL or BOTH → cursor over primary values, emit one INDIVIDUAL row per value:
   - Per-entity resolver tried first; schedule-level is the fallback for every field
   - `fn_ResolveAllTokens` applied after dynamic SQL resolution
   - `{{DISPLAYNAME}}` replaced after `fn_ResolveAllTokens`
   - INDIVIDUAL: `CcAddresses = @CcFanOut`
6. If COMBINED or BOTH → emit one COMBINED row using schedule-level resolvers. `CcAddresses = @CcAll`

---

## HTML Builder

### Layout (4-column CSS grid, rows: 52px header + 1fr content)

| Column | Element | Width |
|---|---|---|
| 1 | `#tok-side` — Token Reference sidebar | 220px |
| 2 | `#wizard` — Step wizard | 440px |
| 3 | `#obj-panel` — Object Builder | 1fr |
| 4 | `#sql-panel` — Generated SQL | 1fr |

### Steps

| Step | Config |
|---|---|
| Load panel (above Step 1) | Parses `RegisterSQL` from `usp_GetScheduleJson`, pre-fills all fields |
| Step 1 | DocumentName, OutputFormat, Language, Confidentiality + Import from Request JSON |
| Step 2 | ScheduleName, FrequencyType, RunTime, DayOfWeek, DayOfMonth, IntervalMinutes, WindowStart/End, StartDate/EndDate |
| Step 3 | Parameters — static values (pipe-delimited), date tokens, dynamic SQL queries |
| Step 4 | Delivery — EMAIL/FOLDER/BOTH + ob-group blocks (EMAIL group and FOLDER group) |
| Step 5 | Fan-out — NONE/INDIVIDUAL/BOTH + per-entity resolvers (email, folder, displayname, filename, subject, body) |

### State stores

```javascript
// Per-field source/value state — 11 keys
const fieldState = {
  'dlv-email':      { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-subject':    { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-body':       { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-filename':   { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-folder':     { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-email':       { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-subject':     { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-body':        { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-filename':    { mode:'parent', staticVal:'', dynamicVal:'' },  // ← parent default
  'fo-folder':      { mode:'parent', staticVal:'', dynamicVal:'' },  // ← parent default
  'fo-displayname': { mode:'static', staticVal:'', dynamicVal:'' },
};

// Recipient state — source of truth for CC/BCC standing recipients
let rcpState = []; // [{ role:'CC'|'BCC', email:'', includeInFanOut:false }]
```

### Module-level variables (key ones)

| Variable | Initial | Purpose |
|---|---|---|
| `params` | `[]` | Array of parameter objects |
| `pidx` | `0` | Auto-increment counter for parameter IDs |
| `delivery` | `'EMAIL'` | Current delivery mode |
| `fanout` | `'NONE'` | Current fan-out mode |
| `_foParamId` | `0` | Set by `syncCore()` — id of the fan-out primary param |
| `rcpState` | `[]` | CC/BCC recipients source of truth |
| `_obMouseDownInside` | `false` | Set `true` on mousedown inside `#obj-panel` |

`isEmail` / `isFolder` are **not** module-level — they are `const` locals hoisted to the top of `syncCore()`.

`_foParamId` is declared at module level but only written by `syncCore()`.

### Group-block pattern

1. `ob-group` div in wizard → `onclick="openDeliveryGroup('email'|'folder')"` or `openFanoutGroup('email'|'folder'|'displayname')`
2. These call `_openGroupInOB(key, label, contentFn)` → `openInObjectBuilder(config)`
3. `buildDeliveryGroupContent(group)` / `buildFanoutGroupContent(group)` return HTML for the OB panel
4. After render: `wireTokenDrop(obBody)` enables token drag-drop, `rcpRender()` populates recipient list
5. `updateGroupSummary()` + `updateAllTriggerSummaries()` refresh the muted value rows visible in the group

### syncCore — SQL output keys

`syncCore()` builds `@DispatchJson` and the `fanOut` block. **Key names are fixed** — do not use `*Template` variants:

```javascript
// @DispatchJson object — schedule-level delivery
{
  deliveryMethod: 'EMAIL|FOLDER|BOTH',
  emailSource: 'STATIC|DYNAMIC_SQL',
  emailSourceValue: '...',
  subjectSource: 'STATIC|DYNAMIC_SQL',        // ← NOT subjectTemplate
  subjectSourceValue: '...',
  bodySource: 'STATIC|DYNAMIC_SQL',           // ← NOT bodyTemplate
  bodySourceValue: '...',
  fileNameSource: 'STATIC|DYNAMIC_SQL',       // ← NOT fileNameTemplate
  fileNameSourceValue: '...',
  folderSource: 'STATIC|DYNAMIC_SQL',
  folderSourceValue: '...',
}

// fanOut block (on primary parameter)
{
  isPrimary: true,
  mode: 'INDIVIDUAL|BOTH',
  emailSource: '...', emailSourceValue: '...',
  displayNameSource: '...', displayNameSourceValue: '...',
  fileNameSource: '...', fileNameSourceValue: '...',     // ← NOT fileNameTemplate
  folderSource: '...', folderSourceValue: '...',
  subjectSource: '...', subjectSourceValue: '...',       // ← NOT subjectTemplate
  bodySource: '...', bodySourceValue: '...',             // ← NOT bodyTemplate
}
```

---

## Key Invariants — HTML (must never regress)

| Invariant | Detail |
|---|---|
| **Load panel z-index** | `.load-panel { z-index:20 }`, `.step-body { z-index:0 }` — prevents step content from occluding the load panel |
| **Empty state div id mismatch** | The empty-state div in `#obj-panel` has `id="obj-empty"` in the HTML. All JS calls use `getElementById('ob-empty')` with a null-safe guard `if (_oe)`. The null guard is load-bearing — do not remove it. Do not change the HTML id without also updating every JS call site. |
| **Null-safe getElementById** | All `getElementById('ob-*')` calls: `const _x = document.getElementById('ob-foo'); if (_x) _x.style...` — never assume present |
| **Click-away mousedown guard** | `_obMouseDownInside` is set `true` on `mousedown` inside `#obj-panel`. Click-away only fires if mousedown AND click both end outside OB. Prevents text-selection drag from closing OB. The flag is never reset — this is intentional. |
| **Click-away exclusions** | These areas never trigger close: `#obj-panel`, `#tok-side`, `#right-panel`/`#sql-panel`, `.load-panel`, `.step-header`, `.ob-trigger`. Note: `.ob-group` is NOT excluded — clicking another group validates and closes the current one. |
| **rcpState is authoritative** | `rcpState[]` is the single source of truth for recipients. `syncCore()` reads `getRecipients()` which reads `rcpState`, not the DOM |
| **No `*Template` keys in output** | `syncCore()` only emits `*Source` / `*SourceValue` keys — never `fileNameTemplate`, `subjectTemplate`, `bodyTemplate` |
| **fo-folder/fo-filename parent default** | Both initialise with `mode:'parent'` — "Use from Delivery" is the default |
| **updateOverwriteWarn() call sites** | Must be called: (a) inside `_openGroupInOB` after rendering, (b) inside `setFieldMode()` when `key === 'fo-folder'` or `key === 'fo-filename'`, (c) inside `updateGroupSummary()` |
| **_foParamId is module-level** | Declared `let _foParamId = 0` at module scope. Set only by `syncCore()`. Read by `renderParams()` to display the FAN-OUT badge. |
| **isEmail/isFolder in syncCore** | Both are `const` locals declared at the top of `syncCore()` — not module-level. Do not hoist them out. |
| **validateObjField routing order** | Group keys (`dlv-grp-*`, `fo-grp-*`) are checked before `startsWith('dlv-')` / `startsWith('fo-')` — if order were reversed, group validation would be skipped |
| **_runValidateDynSQL return** | Returns `true` when invalid (blocks click-away), `false`/`undefined` when valid |

---

## Key Invariants — SQL (must never regress)

| Invariant | Detail |
|---|---|
| **Schema name** | Always `[schdl]` — never `[sched]`, never `[dbo]` |
| **DROP block order** | Procedures → Functions → Tables in FK-safe reverse order. Functions: fn_FetchDocumentId → fn_ResolveAllTokens → fn_ResolveDateToken → fn_CalcNextRunAt. Tables: DispatchQueue → ExecutionLog → ScheduleStandingRecipient → ScheduleRecipient → ScheduleParameter → ScheduleParameterDispatchConfig → ParameterDispatchConfig → ScheduleDocumentParameter → DocumentParameter → ScheduleDocument → Schedule → Document → DateToken |
| **No DECLARE in loops** | Variables inside WHILE/CURSOR blocks must use `SET`, not `DECLARE` |
| **Schedule columns — no duplicates** | `SubjectSource`/`SubjectSourceValue` and `BodySource`/`BodySourceValue` appear exactly once on the Schedule table. Adding them again crashes the deploy |
| **ScheduleParameterDispatchConfig** has its own `SubjectSource`/`BodySource` | These are separate per-entity override columns — distinct from the same-named columns on Schedule |
| **STRING_AGG separator in N-string** | `SET @aggSQL = N'SELECT @r = STRING_AGG([Value], ''|'') FROM ...'` — `''|''` inside N-string produces `'|'` in executed SQL |
| **@iSafeVal pattern** | `SET @iSafeVal = REPLACE(@iVal, N'''', N'''''')` — 4-quote find = one `'`, 6-quote replace = two `''`. Standard SQL escaping for embedding a value in dynamic SQL |
| **Standing CC never in ToAddresses** | `@CcFanOut` → INDIVIDUAL `CcAddresses`, `@CcAll` → COMBINED `CcAddresses`. Neither ever appended to `ToAddresses` |
| **DeliveryMethod on Schedule** | `DeliveryMethod` lives on `[schdl].[Schedule]` — NOT on `ScheduleParameterDispatchConfig` |
| **fanOut JSON key** | The parameter-level fan-out block key is `fanOut` — NOT `dispatch` |
| **ScheduleID filters on both joins** | In `usp_BuildDispatchQueue` and `usp_GetScheduleJson`, joins to `ScheduleDocumentParameter` and `ScheduleParameterDispatchConfig` must include `AND dp.ScheduleID = @ScheduleID` and `AND dc.ScheduleID = @ScheduleID` — prevents cross-schedule row contamination |
| **fileNameTemplate backward compat** | In `usp_RegisterSchedule`: if `fileNameSource IS NULL` AND `fileNameTemplate IS NOT NULL` in the JSON → map to `STATIC` source + `fileNameTemplate` value. Applies at both dispatch-level and fanOut-level. |
| **fn_FetchDocumentId signature** | Takes `@ScheduleID INT` — NOT `@DocumentName`. Looks up `DocumentName` from `ScheduleDocument` then queries `dbo.Document`. |

---

## Quick reference — DispatchQueue columns

```
QueueID, LogID, ScheduleID,
DispatchType     INDIVIDUAL | COMBINED
DeliveryMethod   EMAIL | FOLDER | BOTH
DispatchKeyValue (fan-out value for INDIVIDUAL; NULL for COMBINED)
DisplayName      (resolved entity label)
FileName         (resolved filename override; NULL = use API default)
RequestJson
ToAddresses, CcAddresses, BccAddresses
EmailSubject, EmailBody
FolderPath
Status           PENDING | SENT | SUCCESS | FAILED | SKIPPED
CreatedAt, ProcessedAt, ErrorMessage
```

---

## Notes for next sessions

- `fn_FetchDocumentId` body queries `dbo.Document / sName / bEnabled` — verify column names match the actual target environment before go-live
- `docs/configuration_guide.md` is **stale**: references LOOKUP_VIEW/SCALAR_FN source options, old `@Subject`/`@BodyTemplate` proc parameters, `dispatch` JSON key (should be `fanOut`), `BULK` mode (should be `COMBINED`), and `Recipient`/`ScheduleRecipient` tables that no longer exist. Do not use as implementation reference.
- `sql/samples/scheduling_agent_samples.sql` and `sql/tests/scheduling_agent_test_suite.sql` are **stale** — both use the old API (`@Subject`/`@BodyTemplate`, `dispatch` key, LOOKUP_VIEW/SCALAR_FN, `BULK` mode). Use `sql/samples/register_schedule_sample.sql` instead.
- Source of truth for both deliverables is the committed repo — push `sql/deploy/scheduling_agent_v3.sql` and `tools/schedule_builder.html` after every significant change

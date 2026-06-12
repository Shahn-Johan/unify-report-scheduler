# Scheduling Agent — Project Plan

## What this is

A SQL Server scheduling agent that generates report requests and dispatches
them by email and/or folder drop on a defined schedule. Flowgear triggers it
on a cron and receives a flat result set — one row per delivery action — with
a fully built `RequestJson` ready to POST to the report API.

---

## Repository structure

```
unify-report-scheduler/
├── CLAUDE.md                              ← architecture + key invariants (auto-loaded by Claude Code)
├── PLAN.md                                ← this file
├── README.md                              ← quick-start
├── sql/
│   ├── deploy/
│   │   └── scheduling_agent_v3.sql        ← full drop-and-create deploy script
│   ├── samples/
│   │   └── scheduling_agent_samples.sql   ← sample registrations
│   └── tests/
│       └── scheduling_agent_test_suite.sql ← test schedules
├── docs/
│   ├── flowgear_integration.md            ← Flowgear node sequence + dispatch behaviour
│   └── configuration_guide.md            ← ⚠ STALE — references old LOOKUP_VIEW/SCALAR_FN architecture
└── tools/
    └── schedule_builder.html             ← standalone HTML builder tool
```

---

## Architecture (current — v3)

### Two-block dispatch design

`@DispatchJson` — schedule-level delivery config (separate proc parameter):
```json
{
  "deliveryMethod":     "EMAIL | FOLDER | BOTH",
  "emailSource":        "STATIC | DYNAMIC_SQL",
  "emailSourceValue":   "address or SELECT statement",
  "subjectSource":      "STATIC | DYNAMIC_SQL",
  "subjectSourceValue": "subject text or SELECT",
  "bodySource":         "STATIC | DYNAMIC_SQL",
  "bodySourceValue":    "body text or SELECT",
  "fileNameSource":     "STATIC | DYNAMIC_SQL",
  "fileNameSourceValue":"filename or SELECT",
  "folderSource":       "STATIC | DYNAMIC_SQL",
  "folderSourceValue":  "path or SELECT"
}
```

`fanOut` block — parameter-level fan-out config (nested inside `@ParametersJson`):
```json
{
  "isPrimary":              true,
  "mode":                   "INDIVIDUAL | BOTH",
  "emailSource":            "STATIC | DYNAMIC_SQL",
  "emailSourceValue":       "per-entity email or SELECT with {VALUE}",
  "displayNameSource":      "STATIC | DYNAMIC_SQL",
  "displayNameSourceValue": "entity label or SELECT with {VALUE}",
  "fileNameSource":         "STATIC | DYNAMIC_SQL",
  "fileNameSourceValue":    "per-entity filename or SELECT with {VALUE}",
  "folderSource":           "STATIC | DYNAMIC_SQL",
  "folderSourceValue":      "per-entity folder or SELECT with {VALUE}",
  "subjectSource":          "STATIC | DYNAMIC_SQL",
  "subjectSourceValue":     "per-entity subject or SELECT with {VALUE}",
  "bodySource":             "STATIC | DYNAMIC_SQL",
  "bodySourceValue":        "per-entity body or SELECT with {VALUE}"
}
```

Source types: **STATIC** (literal string) and **DYNAMIC_SQL** (`SELECT` with optional `{VALUE}` placeholder).
LOOKUP_VIEW and SCALAR_FN are removed — DYNAMIC_SQL covers both patterns.

### Recipients

`ScheduleStandingRecipient` table — CC/BCC only, never TO.
- `IncludeInFanOut = 1` → included on INDIVIDUAL rows (`@CcFanOut`)
- `IncludeInFanOut = 0` → included on COMBINED row only (`@CcAll`)
- TO address always comes from `Schedule.EmailSourceValue` (possibly per-entity override)

No `Recipient` or `ScheduleRecipient` tables — those were removed.

### Fallback chains (per field, INDIVIDUAL rows)

| Field | Per-entity resolver | Fallback |
|---|---|---|
| ToAddresses | `ParameterDispatchConfig.EmailSourceValue` | — (required for INDIVIDUAL) |
| FolderPath | `ParameterDispatchConfig.FolderSourceValue` | `Schedule.FolderSourceValue` |
| FileName | `ParameterDispatchConfig.FileNameSourceValue` | `Schedule.FileNameSourceValue` |
| EmailSubject | `ParameterDispatchConfig.SubjectSourceValue` | `Schedule.SubjectSourceValue` |
| EmailBody | `ParameterDispatchConfig.BodySourceValue` | `Schedule.BodySourceValue` |
| CcAddresses | `@CcFanOut` (IncludeInFanOut=1 standing recipients) | — |

---

## Deliverables status

| File | Purpose | Status |
|---|---|---|
| `sql/deploy/scheduling_agent_v3.sql` | Full schema + all stored procs | ✅ Complete |
| `tools/schedule_builder.html` | Visual HTML builder + load existing schedule | ✅ Complete |
| `docs/flowgear_integration.md` | Flowgear node sequence + dispatch behaviour | ✅ Current |
| `docs/configuration_guide.md` | Configuration reference | ⚠ Stale — references removed architecture |
| `sql/samples/scheduling_agent_samples.sql` | Sample registrations | ✅ Complete |
| `sql/tests/scheduling_agent_test_suite.sql` | Test schedules | ✅ Complete |

---

## Completed items

### SQL engine

- [x] All tables with Source/Value pattern (STATIC/DYNAMIC_SQL only — LOOKUP_VIEW/SCALAR_FN removed)
- [x] `ScheduleStandingRecipient` table (CC/BCC only, `IncludeInFanOut` flag) — replaces old `Recipient`/`ScheduleRecipient` model
- [x] `usp_RegisterSchedule` — parses `@DispatchJson` + `@ParametersJson` (with `fanOut` block) + `@RecipientsJson`; `fileNameTemplate` backward compat maps to STATIC source
- [x] `usp_BuildDispatchQueue` — INDIVIDUAL cursor with full fallback chain; STRING_AGG email resolution; `@CcFanOut`/`@CcAll` CC routing; `@iSafeVal` REPLACE escaping; `fn_ResolveAllTokens` applied after resolution
- [x] `usp_GetDueSchedules` — two result sets (diagnostic + dispatch rows); advances `NextRunAt`; sets ADHOC inactive after fire
- [x] `usp_UpdateDispatchStatus` — marks rows SENT/SUCCESS/FAILED
- [x] `usp_TestDispatch` — bypasses all gates; `@KeepResults=1` to preserve rows
- [x] `usp_GetScheduleJson` (Section 4.5) — reads live schedule and reconstructs full `RegisterSQL` string for HTML round-trip; includes `fanOut` block for `IsPrimaryDispatchKey=1` params
- [x] `fn_ResolveAllTokens` — resolves all `{{TOKEN}}` values via `DateToken` table + `fn_ResolveDateToken`
- [x] `fn_ResolveDateToken` — resolves named date tokens (TODAY, PREV_MONTH_END, etc.)
- [x] DROP block — correct FK-safe reverse order; covers old `ScheduleRecipient` for backward compat

### HTML builder

- [x] 4-panel layout (token sidebar | wizard | Object Builder | SQL output)
- [x] Steps 1-5 with all scheduling fields
- [x] `fieldState` / `rcpState` two-store pattern
- [x] Group-block pattern (delivery groups and fanout groups open in Object Builder panel)
- [x] `syncCore()` generates correct `EXEC [schdl].[usp_RegisterSchedule]` with Source/Value keys only — no `*Template` keys
- [x] `rcpState[]` as single source of truth for CC/BCC recipients
- [x] `fo-folder` / `fo-filename` default to `mode:'parent'` (Use from Delivery)
- [x] `updateOverwriteWarn()` fires on group open and on every mode change
- [x] Click-away guard (`_obMouseDownInside`) preventing accidental close on text-select drag
- [x] Load Schedule feature — parses `RegisterSQL` from `usp_GetScheduleJson` via `extractSqlParam()` regex and pre-fills all form fields
- [x] Load panel z-index:20 / step-body z-index:0 (prevents overlap)
- [x] Token drag-drop from sidebar to all inputs/textareas

---

## Pending items

### Must do before go-live

- [ ] **`fn_FetchDocumentId` — implement real body**
  Currently stubs out against `dbo.Document / sName / bEnabled`. Replace with
  actual table name and column names for the target environment before production use.

- [ ] **End-to-end Flowgear test**
  Register a test schedule, run `usp_GetDueSchedules` with `@AsOf`, verify both
  result sets, then run the actual Flowgear workflow end-to-end with the reference
  implementation (see `docs/flowgear_integration.md` § Live Workflow Reference).

- [ ] **Verify `usp_GetDueSchedules` result set shape matches Flowgear SQL Query node**
  Confirm column names in result set 2 match what the Flowgear ForEach node expects.
  Particularly: `ReportEndpoint`, `RequestJson`, `ToAddresses`, `CcAddresses`, `FolderPath`.

- [ ] **GitHub push**
  Push current `sql/deploy/scheduling_agent_v3.sql` and `tools/schedule_builder.html`
  to origin/main — these are the source of truth and must reflect the latest iterations.

### Should do

- [ ] **`docs/configuration_guide.md` — full rewrite**
  File is stale: references LOOKUP_VIEW/SCALAR_FN source options, old `@Subject`/
  `@BodyTemplate` proc parameters, and `Recipient`/`ScheduleRecipient` tables that
  no longer exist. Rewrite to match current Source/Value-only architecture.

- [ ] **Verify `{{TODAY-7}}` / `{{TODAY+3}}` offset token resolution**
  `fn_ResolveDateToken` handles dynamic offsets. Verify the regex pattern correctly
  handles both single-digit and multi-digit N values. Test with `usp_TestDispatch`
  using a schedule that includes offset date tokens in Subject or FileName.

- [ ] **Test suite document names**
  `scheduling_agent_test_suite.sql` registers against `Test Report - *` document
  names. Either create stub rows in `dbo.Document`, or update `fn_FetchDocumentId`
  to return a test ID for unknown document names, so the test suite can run cleanly.

### Nice to have

- [ ] **Builder — token preview**
  "Preview as of today" button that resolves all `{{TOKEN}}` values in the current
  Subject, Body, and FileName fields using today's date.

- [ ] **Builder — Step 5 validation**
  If fan-out mode is INDIVIDUAL or BOTH but no primary parameter is selected,
  show a blocking error before generating SQL.

---

## Testing checklist before go-live

- [ ] Deploy script runs with zero errors on target database
- [ ] `schdl.fn_FetchDocumentId('Your Document Name')` returns a non-NULL value
- [ ] `EXEC schdl.usp_TestDispatch @ScheduleName = '...'` produces correct rows
- [ ] COMBINED schedule: 1 row, correct `ToAddresses`, `CcAddresses = @CcAll`
- [ ] Fan-out schedule: N INDIVIDUAL rows + 1 COMBINED row; INDIVIDUAL `CcAddresses = @CcFanOut`
- [ ] `EXEC schdl.usp_GetScheduleJson @ScheduleName = '...'` round-trips to valid `RegisterSQL`
- [ ] `RegisterSQL` from above can be run as-is and produces the same schedule
- [ ] Dynamic parameter query (`ParameterValueQuery`) returns correct values at runtime
- [ ] `EXEC schdl.usp_GetDueSchedules @AsOf = '...'` — all 4 gates `Y` when expected
- [ ] Flowgear test trigger processes one row end-to-end (email or folder)

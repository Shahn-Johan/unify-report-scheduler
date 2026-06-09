# Scheduling Agent — Project Plan

## What this is

A SQL Server scheduling agent that generates report requests and dispatches
them by email and/or folder drop on a defined schedule. Flowgear triggers it
on a cron and receives a flat result set — one row per delivery action — with
a fully built `RequestJson` ready to POST to the report API.

---

## Repository structure

```
scheduling-agent/
├── PLAN.md                              ← this file
├── README.md                            ← setup + quick-start
├── sql/
│   ├── deploy/
│   │   └── scheduling_agent_v3.sql      ← full drop-and-create deploy script
│   ├── samples/
│   │   └── scheduling_agent_samples.sql ← sample registrations + lookup objects
│   └── tests/
│       └── scheduling_agent_test_suite.sql ← 24 test schedules, all combinations
├── docs/
│   └── configuration_guide.md           ← step-by-step configuration reference
└── tools/
    └── schedule_builder.html            ← standalone HTML schedule builder tool
```

---

## Deliverables status

| File | Purpose | Status |
|---|---|---|
| `sql/deploy/scheduling_agent_v3.sql` | Full schema + all stored procs | ✅ Complete |
| `sql/samples/scheduling_agent_samples.sql` | Sample registrations | ✅ Complete |
| `sql/tests/scheduling_agent_test_suite.sql` | Test suite | ✅ Complete |
| `docs/configuration_guide.md` | Configuration reference | ✅ Complete |
| `tools/schedule_builder.html` | Visual SQL builder | ✅ Complete |

---

## Key architecture decisions

### Two-block dispatch design

**`@DispatchJson`** (schedule-level, separate parameter):
```json
{
  "deliveryMethod":    "EMAIL | FOLDER | BOTH",
  "emailSource":       "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
  "emailSourceValue":  "address or object name",
  "folderSource":      "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
  "folderSourceValue": "path or object name",
  "fileNameTemplate":  "{{REPORTNAME}}_{{PREV_MONTH_END}}",
  "fileNameSource":    "STATIC | LOOKUP_VIEW | SCALAR_FN | DYNAMIC_SQL",
  "fileNameSourceValue": "object name"
}
```

**`fanOut`** block (on one parameter, fan-out only):
```json
{
  "isPrimary":             true,
  "mode":                  "INDIVIDUAL | BOTH",
  "emailSource":           "...",
  "emailSourceValue":      "...",
  "displayNameSource":     "...",
  "displayNameSourceValue":"...",
  "fileNameTemplate":      "{{REPORTNAME}}_{{DISPLAYNAME}}_{{PREV_MONTH_END}}",
  "folderSource":          "...",
  "folderSourceValue":     "..."
}
```

Delivery method is a **schedule-level concern**. Fan-out is a **parameter-level
concern**. They do not overlap.

### Schema: `[schdl]`

Delivery config lives on `Schedule` table. Fan-out per-entity resolvers live on
`ParameterDispatchConfig`. Dynamic parameter values live in `ScheduleParameter.ParameterValueQuery`.

---

## Known items for Claude Code to address

### P1 — Must fix before production

- [x] **`usp_BuildDispatchQueue` — INDIVIDUAL row email resolution**
  No-params branch now uses `@sDeliveryMethod` (was hard-coded `'EMAIL'`).
  Email, folder, and filename resolvers added — mirrors the COMBINED block logic.
  All four source types (STATIC / LOOKUP_VIEW / SCALAR_FN / DYNAMIC_SQL) covered.

- [x] **`usp_BuildDispatchQueue` — schedule `@bsTok`/`@bsRes` DECLARE**
  Added `@bsTok NVARCHAR(100)` and `@bsRes NVARCHAR(500)` to the BULK DECLARE
  block. Cursor `bst` (schedule filename template token pass) now has its
  FETCH targets declared.

- [ ] **`fn_FetchDocumentId` — implement body**
  The function body is a stub pointing at `dbo.Document` / `sName` / `bEnabled`.
  Replace with the actual table/column names for the target environment.
  See `docs/configuration_guide.md` Step 2.

- [ ] **`sched.vw_BRMEmail` and related lookup objects**
  Sample views and functions in `sql/samples/` reference `dbo.BrokerRelationshipManager`.
  Replace table and column names with actual schema objects.

### P2 — Should fix before go-live

- [ ] **Test suite registration names**
  `scheduling_agent_test_suite.sql` registers schedules against `Test Report - *`
  document names that don't exist in `dbo.Document`. Either create stub document
  rows or update `fn_FetchDocumentId` to return a test ID for unknown names.

- [ ] **Token `{{TODAY-7}}` / `{{TODAY+3}}` resolution**
  Dynamic offset tokens are resolved by `fn_ResolveDateToken` via regex pattern
  matching. Verify the regex handles single-digit and multi-digit N correctly.
  Add a test case to the test suite using `usp_TestDispatch` with `@AsOf`.

- [ ] **`ParameterDispatchConfig` table — remove `BulkFolderPath` column**
  This column was intended for combined delivery but has been moved to
  `Schedule.FolderSourceValue`. The column may still exist in the deployed
  schema from a previous run. The deploy script drops and recreates so this
  is handled on redeploy, but verify the `ParameterDispatchConfig` CREATE
  statement no longer includes it.

- [ ] **`usp_RegisterSchedule` — `@pDeliveryMethod` variable**
  Variable was removed from the DECLARE block but `ISNULL(dc.DeliveryMethod,'EMAIL')`
  may still appear in `#Raw` SELECT if any intermediate edits missed it.
  Run the full deploy script and verify no column-not-found errors.

- [ ] **`schedule_builder.html` — `@RecipientsJson` CC/BCC only**
  The builder now puts the combined TO address into `@DispatchJson` and
  `@RecipientsJson` is CC/BCC only. But the `addRecipient()` function still
  shows a TO option in the role dropdown. Either remove TO from the dropdown
  or add a note that TO is managed via `@DispatchJson`.

### P3 — Nice to have

- [ ] **Builder — import `@DispatchJson` from existing registration**
  The JSON import in Step 1 parses `RequestJson` to populate parameters.
  Add a second import that accepts the full `EXEC usp_RegisterSchedule` call
  and pre-fills all fields including dispatch and fan-out config.

- [ ] **Builder — preview resolved token values**
  Add a "Preview as of today" button that shows what all date tokens in the
  current Subject, Body, and FileName fields resolve to using today's date.

- [ ] **Builder — validation on Step 5**
  If fan-out mode is INDIVIDUAL or BOTH and no fan-out parameter is selected,
  show a blocking validation error before allowing SQL generation.

- [ ] **Flowgear workflow documentation**
  Add a `docs/flowgear_integration.md` that shows the exact node sequence:
  Execute → iterate result set → POST RequestJson → send/drop → update status.

---

## Steps to set up with Claude Code + GitHub

### 1. Create the GitHub repository

```bash
# On your machine or in Claude Code terminal
gh repo create scheduling-agent --private --description "SQL Server scheduling agent"
cd scheduling-agent
git init
```

Or create it manually at https://github.com/new and clone it.

### 2. Set up the folder structure

```bash
mkdir -p sql/deploy sql/samples sql/tests docs tools
```

### 3. Add all files

Copy the deliverables into the right locations:

```bash
# From wherever you downloaded them:
cp scheduling_agent_v3.sql          sql/deploy/
cp scheduling_agent_samples.sql     sql/samples/
cp scheduling_agent_test_suite.sql  sql/tests/
cp scheduling_agent_configuration_guide.md  docs/configuration_guide.md
cp schedule_builder.html            tools/
cp PLAN.md                          ./
```

### 4. Create README.md

````markdown
# Scheduling Agent

SQL Server scheduling agent. See [PLAN.md](PLAN.md) for architecture and
[docs/configuration_guide.md](docs/configuration_guide.md) for setup steps.

## Quick start

1. Run `sql/deploy/scheduling_agent_v3.sql` against your database
2. Implement `schdl.fn_FetchDocumentId` — see docs Step 2
3. Register a schedule — use `tools/schedule_builder.html` to generate SQL
4. Test: `EXEC schdl.usp_TestDispatch @ScheduleName = 'Your Schedule Name'`
5. Go live: configure Flowgear to call `EXEC schdl.usp_GetDueSchedules`

## Files

| Path | Purpose |
|---|---|
| `sql/deploy/scheduling_agent_v3.sql` | Full deploy script — run this first |
| `sql/samples/scheduling_agent_samples.sql` | Sample registrations to adapt |
| `sql/tests/scheduling_agent_test_suite.sql` | Test all combinations |
| `docs/configuration_guide.md` | Step-by-step configuration |
| `tools/schedule_builder.html` | Visual schedule builder (open in browser) |
````

### 5. Initial commit

```bash
git add .
git commit -m "feat: initial scheduling agent v3

- Full schema in [schdl] schema
- usp_RegisterSchedule with @DispatchJson + @ParametersJson/fanOut split
- usp_BuildDispatchQueue with delivery from Schedule table
- usp_GetDueSchedules with diagnostic result set
- usp_TestDispatch for gate-bypassed testing
- Dynamic parameter values via ParameterValueQuery
- 24-schedule test suite
- Visual schedule builder HTML tool
- Configuration guide"

git push -u origin main
```

### 6. Open in Claude Code

```bash
# Install Claude Code if not already installed
npm install -g @anthropic-ai/claude-code

# Open the project
cd scheduling-agent
claude
```

### 7. Prime Claude Code with the plan

Paste this into Claude Code to orient it:

```
Read PLAN.md and understand the project structure.
The primary SQL file is sql/deploy/scheduling_agent_v3.sql.
Start with the P1 items in the Known Items section.
Do not modify the schema without discussing the change — 
the deploy script is a full drop-and-create so any schema 
change affects all environments.
```

### 8. Suggested first Claude Code tasks

Work through these in order:

```
1. Verify usp_BuildDispatchQueue compiles cleanly — run the deploy 
   script and check for Msg 207 or Msg 208 errors.

2. Fix the @bsTok/@bsRes DECLARE issue in the BULK filename cursor.

3. Update fn_FetchDocumentId with the real document table query.

4. Run the test suite against a dev database and confirm all 24 
   schedules produce expected row counts in DispatchQueue.

5. Update sample views/functions to match real table names.
```

---

## Environment variables / config

None required in the SQL. The only environment-specific item is
`schdl.fn_FetchDocumentId` — everything else is self-contained.

For Flowgear:
- **Trigger**: cron, call `EXEC schdl.usp_GetDueSchedules`
- **Callback**: `EXEC schdl.usp_UpdateDispatchStatus @QueueID, @Status, @ErrorMessage`

---

## Testing checklist before go-live

- [ ] Deploy script runs with zero errors on target database
- [ ] `schdl.fn_FetchDocumentId('Your Document Name')` returns a non-NULL value
- [ ] `EXEC schdl.usp_TestDispatch @ScheduleName = '...'` produces correct rows
- [ ] `EXEC schdl.usp_GetDueSchedules @AsOf = '2026-07-01 06:00:00'` — all 4 gates Y
- [ ] Flowgear test trigger processes one row end-to-end
- [ ] Re-running `usp_RegisterSchedule` (upsert) updates all fields correctly
- [ ] Dynamic parameter query returns correct values
- [ ] Fan-out produces one row per entity with correct email/folder resolved

# Unify Report Scheduler

SQL Server scheduling agent for report generation and dispatch.

## Quick start

1. Run `sql/deploy/scheduling_agent_v3.sql` against your database
2. Implement `schdl.fn_FetchDocumentId` — see docs/configuration_guide.md Step 2
3. Open `tools/schedule_builder.html` in a browser to generate registration SQL
4. Test: `EXEC schdl.usp_TestDispatch @ScheduleName = 'Your Schedule Name'`
5. Go live: configure Flowgear to call `EXEC schdl.usp_GetDueSchedules`

## Files

| Path | Purpose |
|---|---|
| `sql/deploy/scheduling_agent_v3.sql` | Full deploy script |
| `sql/samples/scheduling_agent_samples.sql` | Sample registrations |
| `sql/tests/scheduling_agent_test_suite.sql` | Test all combinations |
| `docs/configuration_guide.md` | Step-by-step configuration |
| `tools/schedule_builder.html` | Visual schedule builder |
| `PLAN.md` | Architecture, known issues, Claude Code tasks |

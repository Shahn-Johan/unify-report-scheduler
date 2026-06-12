-- =============================================================================
-- test_dispatch_sample.sql
-- usp_TestDispatch call patterns + expected DispatchQueue output shapes
-- =============================================================================
-- usp_TestDispatch bypasses ALL scheduling gates (IsActive, NextRunAt, time
-- windows, date range). It does NOT advance NextRunAt and does NOT set ADHOC
-- schedules inactive. Safe to run repeatedly.
-- =============================================================================


-- -------------------------------------------------------------------------
-- BASIC: run with @KeepResults = 0 (default)
-- Rows are deleted after SELECT — nothing persists in DispatchQueue.
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_TestDispatch]
    @ScheduleName = N'Monthly Entity Report — 1st of month';


-- -------------------------------------------------------------------------
-- WITH @KeepResults = 1
-- Rows remain in DispatchQueue (Status = PENDING) and ExecutionLog.
-- Useful for manual inspection or Flowgear testing.
-- Remember to clean up afterwards (see cleanup block at bottom).
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_TestDispatch]
    @ScheduleName = N'Monthly Entity Report — 1st of month',
    @KeepResults  = 1;


-- -------------------------------------------------------------------------
-- WITH @AsOf — simulate a specific execution date/time
-- Token resolution uses @AsOf as "today" for all {{TODAY}}, {{PREV_MONTH_*}}, etc.
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_TestDispatch]
    @ScheduleName = N'Monthly Entity Report — 1st of month',
    @AsOf         = '2025-06-01 06:30:00',
    @KeepResults  = 0;


-- -------------------------------------------------------------------------
-- EXPECTED OUTPUT SHAPE — Monthly Entity Report (BOTH delivery, 3 entities)
--
-- Assumes:
--   EntityCode values: ENTITY_A|ENTITY_B|ENTITY_C
--   dbo.Entities rows: A→alice@example.com "Alice Corp"
--                      B→bob@example.com   "Bob Ltd"
--                      C→carol@example.com "Carol Inc"
--   @AsOf = '2025-06-01 06:30:00'  →  PREV_MONTH_START = '2025-05-01'
--                                      PREV_MONTH_END   = '2025-05-31'
--   Standing recipients:
--     CC  manager@example.com  IncludeInFanOut=1
--     CC  audit@example.com    IncludeInFanOut=0
--     BCC archive@example.com  IncludeInFanOut=0
-- -------------------------------------------------------------------------
/*
Expected result set (4 rows):

Row 1 — INDIVIDUAL for ENTITY_A
  DispatchType     = INDIVIDUAL
  DeliveryMethod   = BOTH
  DispatchKeyValue = ENTITY_A
  DisplayName      = Alice Corp
  ToAddresses      = alice@example.com
  CcAddresses      = manager@example.com          (IncludeInFanOut=1 only)
  BccAddresses     = NULL                         (BCC IncludeInFanOut=0, excluded from fanOut)
  EmailSubject     = Alice Corp — Monthly Report 2025-05-01 to 2025-05-31
  EmailBody        = Dear Alice Corp, ...
  FileName         = EntityReport_Alice Corp_2025-05-01.xlsx
  FolderPath       = (per-entity folder from dbo.Entities)
  Status           = PENDING

Row 2 — INDIVIDUAL for ENTITY_B
  DispatchKeyValue = ENTITY_B
  DisplayName      = Bob Ltd
  ToAddresses      = bob@example.com
  CcAddresses      = manager@example.com
  EmailSubject     = Bob Ltd — Monthly Report 2025-05-01 to 2025-05-31
  FileName         = EntityReport_Bob Ltd_2025-05-01.xlsx
  FolderPath       = (per-entity folder for ENTITY_B)

Row 3 — INDIVIDUAL for ENTITY_C
  DispatchKeyValue = ENTITY_C
  DisplayName      = Carol Inc
  ToAddresses      = carol@example.com
  CcAddresses      = manager@example.com
  EmailSubject     = Carol Inc — Monthly Report 2025-05-01 to 2025-05-31
  FileName         = EntityReport_Carol Inc_2025-05-01.xlsx

Row 4 — COMBINED
  DispatchType     = COMBINED
  DispatchKeyValue = NULL
  DisplayName      = NULL
  ToAddresses      = operations@example.com       (Schedule.EmailSourceValue)
  CcAddresses      = manager@example.com,audit@example.com  (all CC — @CcAll)
  BccAddresses     = archive@example.com          (all BCC — @BccAll)
  EmailSubject     = Monthly Entity Report — 2025-05-01 to 2025-05-31
  EmailBody        = Please find attached the consolidated monthly entity report...
  FileName         = EntityReport_Consolidated_2025-05-01.xlsx
  FolderPath       = \\fileserver\reports\monthly\consolidated
*/


-- -------------------------------------------------------------------------
-- EXPECTED OUTPUT SHAPE — Daily Sales Summary (no fan-out, single recipient)
--
-- Assumes @AsOf = '2025-06-12 07:05:00'  →  TODAY = '2025-06-12'
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_TestDispatch]
    @ScheduleName = N'Daily Sales Summary — 07:00',
    @AsOf         = '2025-06-12 07:05:00';

/*
Expected result set (1 row):

Row 1 — COMBINED (no primary dispatch key → single combined row)
  DispatchType     = COMBINED
  DeliveryMethod   = EMAIL
  DispatchKeyValue = NULL
  DisplayName      = NULL
  ToAddresses      = sales-team@example.com
  CcAddresses      = NULL
  BccAddresses     = NULL
  EmailSubject     = Daily Sales Summary — 2025-06-12
  FileName         = SalesSummary_2025-06-12.xlsx
  FolderPath       = NULL
  Status           = PENDING
*/


-- -------------------------------------------------------------------------
-- EXPECTED OUTPUT SHAPE — Ad-hoc Client Statement (INDIVIDUAL only, 3 clients)
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_TestDispatch]
    @ScheduleName = N'Client Statement — Ad-hoc 2025-06',
    @AsOf         = '2025-06-12 10:00:00';

/*
Expected result set (3 rows — INDIVIDUAL only, no COMBINED because mode=INDIVIDUAL):

Row 1 — INDIVIDUAL for C001
  DispatchType     = INDIVIDUAL
  DispatchKeyValue = C001
  ToAddresses      = (email from dbo.Clients WHERE client_id='C001')
  DisplayName      = (name from dbo.Clients WHERE client_id='C001')
  FileName         = Statement_<DisplayName>_2025-06-12.pdf
  EmailSubject     = Your Statement — 2025-06-12

Row 2 — INDIVIDUAL for C002
Row 3 — INDIVIDUAL for C003
*/


-- -------------------------------------------------------------------------
-- Verify a schedule's RegisterSQL for round-trip validation
-- Paste the RegisterSQL value into the HTML builder load panel to reload it.
-- -------------------------------------------------------------------------
EXEC [schdl].[usp_GetScheduleJson]
    @ScheduleName = N'Monthly Entity Report — 1st of month';
-- Returns: ScheduleName, DocumentName, DispatchJson, ParametersJson, RecipientsJson, RegisterSQL


-- -------------------------------------------------------------------------
-- Manual cleanup after @KeepResults = 1
-- -------------------------------------------------------------------------
-- Find and delete test rows left by @KeepResults = 1:
/*
DECLARE @TestLogID BIGINT;

SELECT TOP 1 @TestLogID = el.LogID
FROM [schdl].[ExecutionLog] el
JOIN [schdl].[Schedule]     s  ON s.ScheduleID = el.ScheduleID
WHERE s.ScheduleName = N'Monthly Entity Report — 1st of month'
  AND el.Status = 'PENDING'
ORDER BY el.LogID DESC;

DELETE FROM [schdl].[DispatchQueue]  WHERE LogID = @TestLogID;
DELETE FROM [schdl].[ExecutionLog]   WHERE LogID = @TestLogID;
*/

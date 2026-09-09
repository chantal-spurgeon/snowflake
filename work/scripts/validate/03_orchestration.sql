-- =====================================================================
-- Data Validation Framework — Orchestration
-- =====================================================================
USE SCHEMA DQ_FRAMEWORK;

-- ---------------------------------------------------------------------
-- 1. Sweep procedure: runs validation across every distinct table
--    that has active rules. This is what you actually schedule.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE RUN_ALL_VALIDATIONS()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
import json

def main(session):
    tables = session.sql("""
        SELECT DISTINCT TABLE_NAME
        FROM DQ_FRAMEWORK.VALIDATION_RULES
        WHERE IS_ACTIVE = TRUE
    """).collect()

    summary = []
    any_fail = False

    for t in tables:
        table_name = t['TABLE_NAME']
        result_json = session.call('DQ_FRAMEWORK.RUN_VALIDATION', table_name)
        try:
            result = json.loads(result_json)
            if result.get('overall_status') == 'FAIL':
                any_fail = True
            summary.append(result)
        except (json.JSONDecodeError, TypeError):
            summary.append({"table": table_name, "note": result_json})

    return json.dumps({"any_fail": any_fail, "results": summary})
$$;

-- ---------------------------------------------------------------------
-- 2. Task: run the sweep on a schedule, chained after ingestion.
--    Point PREDECESSOR at your actual load task, or use a CRON
--    schedule if validation runs independently of load timing.
-- ---------------------------------------------------------------------

-- Option A — chained after an ingestion task (recommended: validation
-- runs immediately once new data lands, and can gate what happens next)
-- CREATE OR REPLACE TASK DQ_FRAMEWORK.VALIDATE_AFTER_LOAD
--     WAREHOUSE = MY_WH
--     AFTER MY_DB.MY_SCHEMA.LOAD_TASK
-- AS
--     CALL DQ_FRAMEWORK.RUN_ALL_VALIDATIONS();

-- Option B — independent schedule
CREATE OR REPLACE TASK DQ_FRAMEWORK.VALIDATE_SCHEDULED
    WAREHOUSE = COMPUTE_WH          -- replace with your warehouse
    SCHEDULE = 'USING CRON 0 6 * * * UTC'   -- daily at 06:00 UTC; adjust as needed
AS
    CALL DQ_FRAMEWORK.RUN_ALL_VALIDATIONS();

-- Tasks are created suspended by default — resume when ready:
-- ALTER TASK DQ_FRAMEWORK.VALIDATE_SCHEDULED RESUME;

-- ---------------------------------------------------------------------
-- 3. Alerting: notify when a run fails. Uses Snowflake Alerts, which
--    can call a notification integration (email or webhook).
-- ---------------------------------------------------------------------

-- One-time setup of a notification integration (email example):
-- CREATE OR REPLACE NOTIFICATION INTEGRATION DQ_EMAIL_INT
--     TYPE = EMAIL
--     ENABLED = TRUE;

CREATE OR REPLACE ALERT DQ_FRAMEWORK.VALIDATION_FAILURE_ALERT
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '15 MINUTE'
    IF (EXISTS (
        SELECT 1 FROM DQ_FRAMEWORK.VALIDATION_RUNS
        WHERE OVERALL_STATUS = 'FAIL'
          AND FINISHED_AT >= DATEADD('minute', -15, CURRENT_TIMESTAMP())
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'DQ_EMAIL_INT',
            'data-team@yourcompany.com',
            'Snowflake Data Validation Failure',
            'One or more validation runs failed in the last 15 minutes. Check DQ_FRAMEWORK.VALIDATION_RESULTS.'
        );

-- ALTER ALERT DQ_FRAMEWORK.VALIDATION_FAILURE_ALERT RESUME;

-- ---------------------------------------------------------------------
-- 4. Gating pattern: if you want validation to actually block
--    downstream consumption (not just alert), have the consuming
--    task check VALIDATION_LATEST_STATUS before it runs, e.g.:
--
--    CREATE OR REPLACE TASK MY_DB.MY_SCHEMA.DOWNSTREAM_TASK
--        WAREHOUSE = MY_WH
--        AFTER DQ_FRAMEWORK.VALIDATE_SCHEDULED
--        WHEN SYSTEM$STREAM_HAS_DATA('...')  -- or a custom condition
--    AS
--        BEGIN
--            LET v_status STRING := (
--                SELECT OVERALL_STATUS FROM DQ_FRAMEWORK.VALIDATION_LATEST_STATUS
--                WHERE TABLE_NAME = 'MY_TABLE'
--            );
--            IF (v_status = 'FAIL') THEN
--                CALL SYSTEM$LOG('ERROR', 'Blocking downstream: validation failed');
--                -- raise or exit here to stop the chain
--            END IF;
--        END;
-- ---------------------------------------------------------------------

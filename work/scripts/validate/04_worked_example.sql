-- =====================================================================
-- Worked Example — proving the framework is dataset-agnostic
-- =====================================================================
-- Creates a toy "patient enrollment" table (deliberately seeded with
-- bad data), registers rules for it purely via metadata inserts,
-- runs the engine, and shows how to inspect results.

USE SCHEMA DQ_FRAMEWORK;

-- ---------------------------------------------------------------------
-- 1. Sample dataset with intentional data quality problems
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DQ_FRAMEWORK.SAMPLE_PATIENT_ENROLLMENT (
    PATIENT_ID    STRING,
    SITE_ID       STRING,
    ENROLL_DATE   DATE,
    AGE           NUMBER,
    STATUS        STRING,
    LOAD_TS       TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE DQ_FRAMEWORK.SAMPLE_SITES (
    SITE_ID   STRING,
    SITE_NAME STRING
);

INSERT INTO DQ_FRAMEWORK.SAMPLE_SITES VALUES
    ('S001','Austin Site'), ('S002','Barcelona Site');

INSERT INTO DQ_FRAMEWORK.SAMPLE_PATIENT_ENROLLMENT VALUES
    ('P0001','S001','2026-01-05', 34, 'ACTIVE',   CURRENT_TIMESTAMP()),
    ('P0002','S001','2026-01-06', 129,'ACTIVE',   CURRENT_TIMESTAMP()),  -- bad age (RANGE)
    ('P0003',NULL,  '2026-01-07', 45, 'ACTIVE',   CURRENT_TIMESTAMP()),  -- null site (NOT_NULL)
    ('P0004','S999','2026-01-08', 61, 'ACTIVE',   CURRENT_TIMESTAMP()),  -- orphan site (REFERENTIAL)
    ('P0001','S002','2026-01-09', 29, 'WITHDRAWN',CURRENT_TIMESTAMP()),  -- dup patient_id (UNIQUE)
    ('P0005','S002','2026-01-10', 52, 'BOGUS',    CURRENT_TIMESTAMP());  -- invalid status (ENUM)

-- ---------------------------------------------------------------------
-- 2. Register rules for this table — this is the ONLY dataset-specific
--    step. No new code, just metadata.
-- ---------------------------------------------------------------------
INSERT INTO DQ_FRAMEWORK.VALIDATION_RULES
    (DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, RULE_TYPE, RULE_PARAMS, SEVERITY, DESCRIPTION)
SELECT * FROM VALUES
    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', 'PATIENT_ID', 'NOT_NULL',
        PARSE_JSON('{}'), 'ERROR', 'Patient ID is required'),

    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', 'PATIENT_ID', 'UNIQUE',
        PARSE_JSON('{}'), 'ERROR', 'Patient ID must be unique'),

    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', 'SITE_ID', 'NOT_NULL',
        PARSE_JSON('{}'), 'ERROR', 'Site ID is required'),

    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', 'AGE', 'RANGE',
        PARSE_JSON('{"min": 0, "max": 110}'), 'ERROR', 'Age must be plausible'),

    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', 'STATUS', 'ENUM',
        PARSE_JSON('{"allowed": ["ACTIVE","WITHDRAWN","COMPLETED"]}'), 'WARN', 'Status must be a known value'),

    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', 'SITE_ID', 'REFERENTIAL',
        PARSE_JSON('{"ref_table": "DQ_FRAMEWORK.SAMPLE_SITES", "ref_col": "SITE_ID"}'),
        'ERROR', 'Site ID must exist in SAMPLE_SITES'),

    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', 'LOAD_TS', 'FRESHNESS',
        PARSE_JSON('{"max_lag_hours": 26}'), 'WARN', 'Load should be no more than ~1 day stale'),

    (CURRENT_DATABASE(), 'DQ_FRAMEWORK', 'SAMPLE_PATIENT_ENROLLMENT', NULL, 'ROW_COUNT_MIN',
        PARSE_JSON('{"min_rows": 1}'), 'ERROR', 'Table must not be empty')
AS t(DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, RULE_TYPE, RULE_PARAMS, SEVERITY, DESCRIPTION);

-- ---------------------------------------------------------------------
-- 3. Run it
-- ---------------------------------------------------------------------
CALL DQ_FRAMEWORK.RUN_VALIDATION('SAMPLE_PATIENT_ENROLLMENT');

-- Expect: UNIQUE, NOT_NULL(SITE_ID), RANGE, ENUM(warn), REFERENTIAL all FAIL/WARN;
-- NOT_NULL(PATIENT_ID), FRESHNESS, ROW_COUNT_MIN should PASS.

-- ---------------------------------------------------------------------
-- 4. Inspect results
-- ---------------------------------------------------------------------
SELECT * FROM DQ_FRAMEWORK.VALIDATION_LATEST_STATUS
WHERE TABLE_NAME = 'SAMPLE_PATIENT_ENROLLMENT';

SELECT RULE_TYPE, COLUMN_NAME, SEVERITY, STATUS, RECORDS_CHECKED, RECORDS_FAILED, FAIL_PCT, SAMPLE_FAILURES
FROM DQ_FRAMEWORK.VALIDATION_RESULTS
WHERE TABLE_NAME = 'SAMPLE_PATIENT_ENROLLMENT'
ORDER BY RESULT_ID DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- 5. Onboarding a second, totally different dataset takes only this
--    shape of insert — proving transferability. No engine changes.
-- ---------------------------------------------------------------------
-- INSERT INTO DQ_FRAMEWORK.VALIDATION_RULES
--     (DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, RULE_TYPE, RULE_PARAMS, SEVERITY, DESCRIPTION)
-- VALUES
--     (CURRENT_DATABASE(), 'RAW', 'ORDERS', 'ORDER_ID', 'NOT_NULL', PARSE_JSON('{}'), 'ERROR', NULL),
--     (CURRENT_DATABASE(), 'RAW', 'ORDERS', 'ORDER_TOTAL', 'RANGE', PARSE_JSON('{"min":0,"max":50000}'), 'ERROR', NULL);
-- CALL DQ_FRAMEWORK.RUN_VALIDATION('ORDERS');

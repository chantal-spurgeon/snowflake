# Snowflake Data Validation Framework

A metadata-driven validation engine: rules live in a config table, one generic
engine executes them against whatever table you point it at. Adding validation
for a new dataset means inserting rows, not writing new code.

## Files

| File | Purpose |
|---|---|
| `01_ddl_metadata_tables.sql` | Creates `VALIDATION_RULES`, `VALIDATION_RUNS`, `VALIDATION_RESULTS`, and a `VALIDATION_LATEST_STATUS` view |
| `02_engine_procedure.sql` | The Snowpark Python procedure `RUN_VALIDATION(table_name)` — the actual rule engine |
| `03_orchestration.sql` | `RUN_ALL_VALIDATIONS()` sweep procedure, a scheduled Task, and a failure Alert |
| `04_worked_example.sql` | A seeded sample table with deliberately bad data, rules registered purely via inserts, and expected results |

## Deploy order

1. Run `01_ddl_metadata_tables.sql` — creates the `DQ_FRAMEWORK` schema and metadata tables.
2. Run `02_engine_procedure.sql` — creates `RUN_VALIDATION`.
3. Run `03_orchestration.sql` — creates the sweep procedure, task, and alert.
   - Edit the warehouse name (`COMPUTE_WH`), notification integration, and email address before running the alert section.
   - Choose Option A (chained after your load task) or Option B (independent CRON schedule) for the task.
4. Run `04_worked_example.sql` to validate the deployment end-to-end.

## Onboarding a new dataset (the whole point)

```sql
INSERT INTO DQ_FRAMEWORK.VALIDATION_RULES
    (DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, RULE_TYPE, RULE_PARAMS, SEVERITY)
VALUES
    (CURRENT_DATABASE(), 'RAW', 'MY_NEW_TABLE', 'ID', 'NOT_NULL', PARSE_JSON('{}'), 'ERROR');

CALL DQ_FRAMEWORK.RUN_VALIDATION('MY_NEW_TABLE');
```

No engine code changes required for any of the built-in rule types.

## Supported rule types

- `NOT_NULL`, `UNIQUE`, `RANGE`, `REGEX`, `ENUM`
- `REFERENTIAL` — foreign-key style check against another table
- `FRESHNESS` — flags if the max timestamp in a column is older than an SLA
- `ROW_COUNT_MIN` — flags empty/near-empty loads
- `ROW_COUNT_DRIFT` — flags row count that deviates from a trailing average (catches silent upstream breakage; needs a few runs to build a baseline)
- `CUSTOM_SQL` — escape hatch: supply any SQL that returns a single `FAILS` count, for business rules too specific to templatize

## Extending with a new rule type

1. Add a branch in `build_check_sql()` in `02_engine_procedure.sql` (and optionally `build_sample_sql()` for triage samples).
2. Re-run `02_engine_procedure.sql` to redeploy the procedure — no changes needed to the metadata tables or any existing rule rows.

## Design notes

- **Severity tiers**: `ERROR` should gate downstream consumption; `WARN` logs and notifies but doesn't block. Enforce the gate in your downstream task by checking `VALIDATION_LATEST_STATUS` (pattern shown at the bottom of `03_orchestration.sql`).
- **Push-down execution**: all checks run as SQL inside Snowflake — no data leaves the warehouse, which matters in a regulated/compliance-sensitive environment.
- **Sampling, not just counts**: failed rules store a handful of offending rows in `SAMPLE_FAILURES` (VARIANT) so triage doesn't start from "142 rows failed" with nothing to look at.
- **Drift baseline**: `ROW_COUNT_DRIFT` reads its own history from `VALIDATION_RESULTS`, so it self-seeds — first run has no baseline and passes by default.

-- =====================================================================
-- Data Validation Framework — Rule Execution Engine
-- =====================================================================
-- Deploy as a Snowpark Python stored procedure. Call with either a
-- single table name or run it with no argument to sweep every active
-- table found in VALIDATION_RULES.

USE SCHEMA DQ_FRAMEWORK;

CREATE OR REPLACE PROCEDURE RUN_VALIDATION("P_TABLE" STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
import json
import uuid
from datetime import datetime

MAX_SAMPLE_ROWS = 5  # how many offending rows to store per failed rule


def qualify(db, sch, tbl):
    return f'"{db}"."{sch}"."{tbl}"'


def build_check_sql(rule, full_table):
    """Return SQL that yields a FAILS count for this rule, or None if
    the rule type needs no generic count (handled separately)."""
    rtype = rule['RULE_TYPE']
    col = rule['COLUMN_NAME']
    params = rule['RULE_PARAMS'] or {}

    if rtype == 'NOT_NULL':
        return f"SELECT COUNT(*) AS FAILS FROM {full_table} WHERE {col} IS NULL"

    if rtype == 'UNIQUE':
        return f"""
            SELECT COUNT(*) AS FAILS FROM (
                SELECT {col}, COUNT(*) AS CNT
                FROM {full_table}
                WHERE {col} IS NOT NULL
                GROUP BY {col}
                HAVING COUNT(*) > 1
            )
        """

    if rtype == 'RANGE':
        lo, hi = params.get('min'), params.get('max')
        conds = []
        if lo is not None:
            conds.append(f"{col} < {lo}")
        if hi is not None:
            conds.append(f"{col} > {hi}")
        cond = " OR ".join(conds) if conds else "FALSE"
        return f"SELECT COUNT(*) AS FAILS FROM {full_table} WHERE {col} IS NOT NULL AND ({cond})"

    if rtype == 'REGEX':
        pattern = params['pattern'].replace("'", "''")
        return f"""SELECT COUNT(*) AS FAILS FROM {full_table}
                   WHERE {col} IS NOT NULL AND NOT {col}::STRING RLIKE '{pattern}'"""

    if rtype == 'ENUM':
        allowed = ", ".join(f"'{v}'" for v in params['allowed'])
        return f"""SELECT COUNT(*) AS FAILS FROM {full_table}
                   WHERE {col} IS NOT NULL AND {col} NOT IN ({allowed})"""

    if rtype == 'REFERENTIAL':
        ref_table = params['ref_table']
        ref_col = params['ref_col']
        return f"""
            SELECT COUNT(*) AS FAILS
            FROM {full_table} t
            LEFT JOIN {ref_table} r ON t.{col} = r.{ref_col}
            WHERE t.{col} IS NOT NULL AND r.{ref_col} IS NULL
        """

    if rtype == 'FRESHNESS':
        max_lag = params['max_lag_hours']
        return f"""
            SELECT CASE WHEN DATEDIFF('hour', MAX({col}), CURRENT_TIMESTAMP()) > {max_lag}
                        THEN 1 ELSE 0 END AS FAILS
            FROM {full_table}
        """

    if rtype == 'ROW_COUNT_MIN':
        min_rows = params['min_rows']
        return f"""
            SELECT CASE WHEN COUNT(*) < {min_rows} THEN 1 ELSE 0 END AS FAILS
            FROM {full_table}
        """

    if rtype == 'CUSTOM_SQL':
        # Custom SQL must itself return a single FAILS column.
        return params['sql']

    return None  # ROW_COUNT_DRIFT handled separately (needs history)


def build_sample_sql(rule, full_table, key_cols_hint=None):
    """Best-effort SQL to pull a few sample failing rows for triage."""
    rtype = rule['RULE_TYPE']
    col = rule['COLUMN_NAME']
    params = rule['RULE_PARAMS'] or {}

    if rtype == 'NOT_NULL':
        return f"SELECT * FROM {full_table} WHERE {col} IS NULL LIMIT {MAX_SAMPLE_ROWS}"
    if rtype == 'UNIQUE':
        return f"""
            SELECT * FROM {full_table} WHERE {col} IN (
                SELECT {col} FROM {full_table}
                WHERE {col} IS NOT NULL GROUP BY {col} HAVING COUNT(*) > 1
            ) LIMIT {MAX_SAMPLE_ROWS}
        """
    if rtype == 'RANGE':
        lo, hi = params.get('min'), params.get('max')
        conds = []
        if lo is not None:
            conds.append(f"{col} < {lo}")
        if hi is not None:
            conds.append(f"{col} > {hi}")
        cond = " OR ".join(conds) if conds else "FALSE"
        return f"SELECT * FROM {full_table} WHERE {col} IS NOT NULL AND ({cond}) LIMIT {MAX_SAMPLE_ROWS}"
    if rtype == 'REGEX':
        pattern = params['pattern'].replace("'", "''")
        return f"""SELECT * FROM {full_table} WHERE {col} IS NOT NULL
                   AND NOT {col}::STRING RLIKE '{pattern}' LIMIT {MAX_SAMPLE_ROWS}"""
    if rtype == 'ENUM':
        allowed = ", ".join(f"'{v}'" for v in params['allowed'])
        return f"""SELECT * FROM {full_table} WHERE {col} IS NOT NULL
                   AND {col} NOT IN ({allowed}) LIMIT {MAX_SAMPLE_ROWS}"""
    if rtype == 'REFERENTIAL':
        ref_table = params['ref_table']
        ref_col = params['ref_col']
        return f"""
            SELECT t.* FROM {full_table} t
            LEFT JOIN {ref_table} r ON t.{col} = r.{ref_col}
            WHERE t.{col} IS NOT NULL AND r.{ref_col} IS NULL LIMIT {MAX_SAMPLE_ROWS}
        """
    return None  # no generic sample query for FRESHNESS / ROW_COUNT_* / CUSTOM_SQL


def evaluate_row_count_drift(session, full_table, params, rule_table_name):
    lookback = params.get('lookback_days', 7)
    max_pct = params.get('max_pct_change', 0.30)

    current = session.sql(f"SELECT COUNT(*) AS CNT FROM {full_table}").collect()[0]['CNT']

    hist_row = session.sql(f"""
        SELECT AVG(RECORDS_CHECKED) AS AVG_CNT
        FROM DQ_FRAMEWORK.VALIDATION_RESULTS
        WHERE TABLE_NAME = '{rule_table_name}'
          AND RULE_TYPE = 'ROW_COUNT_DRIFT'
          AND CHECK_TIMESTAMP >= DATEADD('day', -{lookback}, CURRENT_TIMESTAMP())
    """).collect()[0]['AVG_CNT']

    if hist_row is None or hist_row == 0:
        return 0, current, None  # no baseline yet; pass by default, record current as baseline

    pct_change = abs(current - hist_row) / hist_row
    fails = 1 if pct_change > max_pct else 0
    detail = {"current_count": current, "baseline_avg": float(hist_row), "pct_change": round(pct_change, 4)}
    return fails, current, detail


def main(session, p_table):
    run_id = str(uuid.uuid4())
    started_at = datetime.utcnow()

    rules = session.sql(f"""
        SELECT RULE_ID, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME,
               RULE_TYPE, RULE_PARAMS, SEVERITY
        FROM DQ_FRAMEWORK.VALIDATION_RULES
        WHERE TABLE_NAME = '{p_table}' AND IS_ACTIVE = TRUE
    """).collect()

    if not rules:
        return f"No active rules found for table {p_table}."

    passed = failed = warned = errored = 0

    for r in rules:
        rule = r.as_dict()
        params_raw = rule['RULE_PARAMS']
        rule['RULE_PARAMS'] = json.loads(params_raw) if isinstance(params_raw, str) else (params_raw or {})

        full_table = qualify(rule['DATABASE_NAME'], rule['SCHEMA_NAME'], rule['TABLE_NAME'])
        status = 'ERROR'
        fails = 0
        records_checked = None
        sample_json = None
        error_message = None

        try:
            if rule['RULE_TYPE'] == 'ROW_COUNT_DRIFT':
                fails, records_checked, detail = evaluate_row_count_drift(
                    session, full_table, rule['RULE_PARAMS'], rule['TABLE_NAME']
                )
                sample_json = json.dumps(detail) if detail else None
            else:
                check_sql = build_check_sql(rule, full_table)
                if check_sql is None:
                    raise ValueError(f"Unsupported RULE_TYPE: {rule['RULE_TYPE']}")

                fails = session.sql(check_sql).collect()[0]['FAILS']

                # Row count for context (skip extra scan for table-level rules already scanning full table)
                if rule['RULE_TYPE'] not in ('FRESHNESS', 'ROW_COUNT_MIN'):
                    records_checked = session.sql(f"SELECT COUNT(*) AS CNT FROM {full_table}").collect()[0]['CNT']

                if fails and fails > 0:
                    sample_sql = build_sample_sql(rule, full_table)
                    if sample_sql:
                        sample_rows = session.sql(sample_sql).collect()
                        sample_json = json.dumps([row.as_dict() for row in sample_rows], default=str)

            if fails and fails > 0:
                status = 'WARN' if rule['SEVERITY'] == 'WARN' else 'FAIL'
            else:
                status = 'PASS'

        except Exception as e:
            status = 'ERROR'
            error_message = str(e)

        if status == 'PASS':
            passed += 1
        elif status == 'WARN':
            warned += 1
        elif status == 'FAIL':
            failed += 1
        else:
            errored += 1

        fail_pct = None
        if records_checked and records_checked > 0 and fails is not None:
            fail_pct = round((fails / records_checked) * 100, 4)

        session.sql(f"""
            INSERT INTO DQ_FRAMEWORK.VALIDATION_RESULTS
                (RUN_ID, RULE_ID, TABLE_NAME, COLUMN_NAME, RULE_TYPE, SEVERITY,
                 RECORDS_CHECKED, RECORDS_FAILED, FAIL_PCT, STATUS, SAMPLE_FAILURES, ERROR_MESSAGE)
            SELECT
                '{run_id}', {rule['RULE_ID']}, '{rule['TABLE_NAME']}',
                {f"'{rule['COLUMN_NAME']}'" if rule['COLUMN_NAME'] else 'NULL'},
                '{rule['RULE_TYPE']}', '{rule['SEVERITY']}',
                {records_checked if records_checked is not None else 'NULL'},
                {fails if fails is not None else 'NULL'},
                {fail_pct if fail_pct is not None else 'NULL'},
                '{status}',
                {f"PARSE_JSON('{sample_json}')" if sample_json else 'NULL'},
                {f"'{error_message.replace(chr(39), chr(39)+chr(39))}'" if error_message else 'NULL'}
        """).collect()

    overall = 'FAIL' if failed > 0 else ('WARN' if warned > 0 else 'PASS')
    finished_at = datetime.utcnow()

    session.sql(f"""
        INSERT INTO DQ_FRAMEWORK.VALIDATION_RUNS
            (RUN_ID, TABLE_NAME, STARTED_AT, FINISHED_AT, RULES_EVALUATED,
             RULES_PASSED, RULES_FAILED, RULES_WARNED, OVERALL_STATUS)
        SELECT '{run_id}', '{p_table}', '{started_at.isoformat()}', '{finished_at.isoformat()}',
               {len(rules)}, {passed}, {failed}, {warned}, '{overall}'
    """).collect()

    return json.dumps({
        "run_id": run_id,
        "table": p_table,
        "rules_evaluated": len(rules),
        "passed": passed,
        "failed": failed,
        "warned": warned,
        "errored": errored,
        "overall_status": overall
    })
$$;

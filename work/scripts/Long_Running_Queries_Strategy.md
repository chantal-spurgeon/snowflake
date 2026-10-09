# Snowflake Technical Blueprint: Headless Automation Strategy for Long-Running Queries

## Executive Summary
Uncontrolled, long-running queries consume substantial virtual warehouse credits, degrade concurrent workload performance, and are often the result of unoptimized join patterns, missing filters, or warehouse sizing mismatches. This blueprint details a headless automation strategy that isolates, monitors, and alerts on queries exceeding specific execution thresholds entirely within Snowflake using **Snowpark Python Stored Procedures** and scheduled **Snowflake Tasks**.

---

## 1. Outbound Network & Security Integration
Because this monitoring strategy operates headlessly inside Snowflake's sandbox, it requires an Egress network integration to communicate with external notification routing endpoints (e.g., Slack, Microsoft Teams, Webhook integrations).

```sql
-- Step 1: Create an egress network rule for your webhook endpoint
CREATE OR REPLACE NETWORK RULE notification_egress_rule
  MODE = 'EGRESS'
  TYPE = 'HOST_PORT'
  VALUE_LIST = ('hooks.slack.com', 'outlook.office.com'); -- Expand with your target monitoring hosts

-- Step 2: Containerize the production webhook URL or API token inside a Snowflake secret
CREATE OR REPLACE SECRET notification_webhook_secret
  TYPE = 'GENERIC_STRING'
  SECRET_STRING = 'https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX';

-- Step 3: Bind the rule and secret into an isolated External Access Integration
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION query_monitor_external_integration
  ALLOWED_NETWORK_RULES = (notification_egress_rule)
  ALLOWED_SECRETS = (notification_webhook_secret)
  ENABLED = TRUE;
```

---

## 2. Snowpark Python Stored Procedure
The core evaluation logic runs natively in Python 3.10. It parses the global query history log for successful metadata signatures where total duration exceeds a specified operational baseline (e.g., queries running over 30 minutes / 1800 seconds).

```sql
CREATE OR REPLACE PROCEDURE monitor_long_running_queries_proc()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (query_monitor_external_integration)
SECRETS = ('webhook_url' = notification_webhook_secret)
HANDLER = 'evaluate_long_queries'
AS
$$
import _snowflake
import requests

def evaluate_long_queries(session):
    # Safely retrieve your integration URL from the masked secret vault
    target_webhook = _snowflake.get_generic_secret_string('webhook_url')
    
    # Target long queries from the account log over the trailing 60 minutes
    query_log_df = session.sql("""
        SELECT 
            query_id,
            warehouse_name,
            user_name,
            role_name,
            ROUND(total_elapsed_time / 1000, 2) as execution_time_seconds,
            ROUND(bytes_scanned / 1024 / 1024 / 1024, 2) as data_scanned_gb,
            partitions_scanned,
            partitions_total
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
          AND execution_status = 'SUCCESS'
          AND total_elapsed_time > 1800000 -- Threshold: 1,800,000 milliseconds (30 minutes)
          AND query_type IN ('SELECT', 'INSERT', 'UPDATE', 'MERGE', 'CREATE_TABLE_AS_SELECT')
        ORDER BY total_elapsed_time DESC
        LIMIT 5;
    """)
    
    records = query_log_df.collect()
    
    if not records:
        return "Operational Check: Zero long-running queries exceeded the 30-minute threshold over the past hour."
        
    # Construct alert payload strings
    alert_payload = ["*Headless Snowflake Warning: Long-Running Queries Detected (Past Hour)*"]
    for row in records:
        duration_min = round(row['EXECUTION_TIME_SECONDS'] / 60, 2)
        log_line = (f"• *Query ID*: `{row['QUERY_ID']}` | *WH*: `{row['WAREHOUSE_NAME']}`\n"
                    f"  *User/Role*: {row['USER_NAME']} ({row['ROLE_NAME']})\n"
                    f"  Duration: {duration_min} minutes | Scanned: {row['DATA_SCANNED_GB']} GB\n"
                    f"  Partitions: {row['PARTITIONS_SCANNED']} scanned out of {row['PARTITIONS_TOTAL']} total.")
        alert_payload.append(log_line)
        
    formatted_msg = {"text": "\n".join(alert_payload)}
    
    # Dispatch payload to external Slack/Teams monitoring channels
    response = requests.post(target_webhook, json=formatted_msg)
    
    if response.status_code == 200:
        return f"Alerting sequence complete. Dispatched {len(records)} query profiles."
    else:
        return f"Log parsed successfully, but webhook route failed with code: {response.status_code}"
$$;
```

---

## 3. Automation Task Deployment
Once the auditing procedure is compiled, wrap it in a root **Snowflake Task** configured to execute on a continuous cron window.

```sql
-- Establish an hourly cron execution cycle
CREATE OR REPLACE TASK task_monitor_long_running_queries
    WAREHOUSE = admin_wh -- Define your dedicated administrative operations warehouse
    SCHEDULE = 'USING CRON 5 * * * * UTC' -- Fires at minute 5 of every hour to account for latency
AS
    CALL monitor_long_running_queries_proc();

-- CRITICAL: Tasks are created in a SUSPENDED state by default. Activate the scheduler explicitly:
ALTER TASK task_monitor_long_running_queries RESUME;
```

---

## 4. Administrative Diagnostics and Auditing

### Inspecting Task Progress History
To ensure the headless framework is operating within normal parameters, audit your execution health using the following engine checks:

```sql
SELECT * 
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    task_name => 'TASK_MONITOR_LONG_RUNNING_QUERIES'
))
ORDER BY query_start_time DESC
LIMIT 10;
```

### Account-Level Role Privileges
Reading global execution footprints from `SNOWFLAKE.ACCOUNT_USAGE` views requires high-level data permissions. The administrative security role deploying this stack must possess the following grant:

```sql
GRANT IMPORTED PRIVILEGES ON DATABASE snowflake TO ROLE your_admin_role;
```

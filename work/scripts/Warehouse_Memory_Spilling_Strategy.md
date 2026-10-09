# Snowflake Monitoring Strategy: Warehouse Memory Spilling Automation

## Executive Summary
When an active query exhausts the native execution memory allocated to its virtual warehouse size, Snowflake is forced to spill rows to secondary storage. Data is dumped first to local disk (fast SSD) and then to remote storage (cloud object storage like Amazon S3 or Google Cloud Storage). This introducing a heavy performance penalty and drives up computing costs. 

This technical design outlines a fully automated, headless architecture using **Snowflake Tasks**, **Snowpark Python Stored Procedures**, and **External Access Integrations** to programmatic check and alert on remote storage spilling without requiring external servers or infrastructure.

---

## Architecture Blueprint

```
+-------------------------------------------------------------+
|                       SNOWFLAKE INTERNALS                    |
|                                                             |
|   +------------------+         +-------------------------+  |
|   |  Snowflake Task  | ------> | Snowpark Python Proc    |  |
|   |  (Hourly Cron)   |         | (Session-less Logic)    |  |
|   +------------------+         +-------------------------+  |
|                                             |               |
|                                             v               |
|                                +-------------------------+  |
|                                | External Network Access |  |
|                                | Integration / Secret    |  |
|                                +-------------------------+  |
+---------------------------------------------|---------------+
                                              |
                                              v (HTTPS Outbound)
                                 +-------------------------+
                                 |  Notification Endpoint  |
                                 |  (Slack / PagerDuty)    |
                                 +-------------------------+
```

---

## 1. Network Security Configuration

Because Snowflake runs in a protected multi-tenant sandbox environment, explicit outbound connection routing privileges must be provisioned before any code blocks can interact with third-party webhook APIs.

```sql
-- Step 1: Create an outbound firewall rule defining target host endpoints
CREATE OR REPLACE NETWORK RULE slack_network_rule
  MODE = 'EGRESS'
  TYPE = 'HOST_PORT'
  VALUE_LIST = ('hooks.slack.com:443');

-- Step 2: Encapsulate private authentication credentials safely in a secret manager
CREATE OR REPLACE SECRET slack_webhook_token
  TYPE = 'GENERIC_STRING'
  SECRET_STRING = 'https://hooks.slack.com/services/T00/B00/X000'; -- Replace with your actual secure Slack URL

-- Step 3: Bundle security structures into an active External Access Integration profile
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION monitoring_spill_integration
  ALLOWED_NETWORK_RULES = (slack_network_rule)
  ALLOWED_SECRETS = (slack_webhook_token)
  ENABLED = TRUE;
```

---

## 2. Snowpark Python Engine Deployment

The primary analytics layer runs isolated on Snowflake serverless engines. This procedure directly queries metadata tracking loops to discover queries spilling more than **10 GB of temporary rows** to remote cloud tiers.

```sql
CREATE OR REPLACE PROCEDURE monitor_memory_spilling_proc()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (monitoring_spill_integration)
SECRETS = ('slack_url' = slack_webhook_token)
HANDLER = 'run_spill_audit'
AS
$$
import _snowflake
import requests

def run_spill_audit(session):
    # Fetch webhook URL securely from the integrated Snowflake secret
    webhook_url = _snowflake.get_generic_secret_string('slack_url')
    
    # Query system telemetry schemas directly inside active context
    spill_df = session.sql("""
        SELECT 
            warehouse_name,
            query_id,
            user_name,
            ROUND(bytes_spilled_to_local_storage / 1024 / 1024 / 1024, 2) as local_spill_gb,
            ROUND(bytes_spilled_to_remote_storage / 1024 / 1024 / 1024, 2) as remote_spill_gb,
            total_elapsed_time / 1000 as total_duration_seconds
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
          AND bytes_spilled_to_remote_storage > 10737418240 -- Filter for > 10 GB Remote Spill
          AND execution_status = 'SUCCESS'
        ORDER BY bytes_spilled_to_remote_storage DESC
        LIMIT 5;
    """)
    
    results = spill_df.collect()
    
    if not results:
        return "No significant remote memory spilling detected over the last hour."
        
    # Build payload string using text blocks
    message_lines = ["*Headless Snowflake Alert: High Warehouse Memory Spilling Detected (Past Hour)*"]
    for row in results:
        line = (f"• *WH*: `{row['WAREHOUSE_NAME']}` | *User*: {row['USER_NAME']}
"
                f"  *Query ID*: `{row['QUERY_ID']}`
"
                f"  Local Spill: {row['LOCAL_SPILL_GB']} GB | Remote Spill: {row['REMOTE_SPILL_GB']} GB | Time: {row['TOTAL_DURATION_SECONDS']}s")
        message_lines.append(line)
        
    full_payload = {"text": "\n".join(message_lines)}
    
    # Execute the outbound webhook call
    response = requests.post(webhook_url, json=full_payload)
    
    if response.status_code == 200:
        return f"Successfully sent alert for {len(results)} spilling queries."
    else:
        return f"Query parsed but notification failed with status code: {response.status_code}"
$$;
```

---

## 3. Headless Automation & Task Scheduling

To guarantee continuous monitoring without operational overhead, the procedure is bound to an active system task wrapper scheduled via standardized cron logic.

```sql
-- Step 1: Instantiate the scheduled orchestration task
CREATE OR REPLACE TASK task_monitor_warehouse_spills
    WAREHOUSE = admin_wh                  -- Virtual warehouse powering the metadata scan
    SCHEDULE = 'USING CRON 0 * * * * UTC' -- Evaluates at minute 0 of every hour
AS
    CALL monitor_memory_spilling_proc();

-- Step 2: Transition the state constraint from SUSPENDED to active tracking
ALTER TASK task_monitor_warehouse_spills RESUME;
```

---

## 4. Administrative Diagnostics and Maintenance

Engineers can review task compliance and audit trailing run loops by exploring system information view tables:

```sql
-- Audit the trailing execution logs of the headless task engine
SELECT * 
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    task_name => 'TASK_MONITOR_WAREHOUSE_SPILLS'
))
ORDER BY query_start_time DESC;
```

### Required Infrastructure Permissions
To fetch performance profiles globally, the running role must possess `IMPORTED PRIVILEGES` on the parent global `SNOWFLAKE` share database.
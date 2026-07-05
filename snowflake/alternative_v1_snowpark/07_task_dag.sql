-- Orchestration: daily task DAG  extract -> load -> transform
USE ROLE SYSADMIN;
USE DATABASE STEAM;
USE SCHEMA OPS;

-- Root: pull from Steam API, land files in S3 (via stage). 06:00 UTC daily.
CREATE OR REPLACE TASK OPS.T1_EXTRACT_STEAM
  WAREHOUSE = STEAM_WH
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
AS
  CALL OPS.EXTRACT_STEAM(100);

-- Child: COPY INTO bronze tables
CREATE OR REPLACE TASK OPS.T2_LOAD_RAW
  WAREHOUSE = STEAM_WH
  AFTER OPS.T1_EXTRACT_STEAM
AS
  CALL OPS.LOAD_RAW();

-- Child: run dbt. Two options:
--
-- Option A (recommended): dbt Projects on Snowflake -- upload the dbt/ folder
-- as a DBT PROJECT object, then:
--
-- CREATE OR REPLACE TASK OPS.T3_DBT_RUN
--   WAREHOUSE = STEAM_WH
--   AFTER OPS.T2_LOAD_RAW
-- AS
--   EXECUTE DBT PROJECT STEAM.OPS.STEAM_DBT ARGS='run';
--
-- Option B: run `dbt build` externally (cron / GitHub Actions / dbt Cloud job)
-- scheduled shortly after the Snowflake DAG window.

-- Enable (children first, root last):
ALTER TASK OPS.T2_LOAD_RAW RESUME;
ALTER TASK OPS.T1_EXTRACT_STEAM RESUME;

-- Manual full-DAG trigger for testing:
-- EXECUTE TASK OPS.T1_EXTRACT_STEAM;
-- Monitor:
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY()) ORDER BY SCHEDULED_TIME DESC LIMIT 20;

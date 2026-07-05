-- OPTIONAL (v2, fully event-driven): run dbt when new bronze data arrives,
-- instead of on a clock. Requires dbt Projects on Snowflake; if you run dbt
-- from GitHub Actions on a schedule, skip this file.

-- ONE-TIME PREREQUISITES (as ACCOUNTADMIN) -- without these the task fails
-- with "Cannot execute task, EXECUTE TASK privilege must be granted":
--   USE ROLE ACCOUNTADMIN;
--   GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;
--   GRANT USAGE ON DBT PROJECT STEAM.OPS.STEAM_DBT TO ROLE SYSADMIN;

USE ROLE SYSADMIN;
USE DATABASE STEAM;
USE SCHEMA OPS;

-- Streams: change-tracking on the bronze tables. APPEND_ONLY is enough
-- (we only ever COPY new rows in).
CREATE OR REPLACE STREAM OPS.STR_MOST_PLAYED   ON TABLE RAW.MOST_PLAYED   APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM OPS.STR_PLAYER_COUNTS ON TABLE RAW.PLAYER_COUNTS APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM OPS.STR_REVIEWS       ON TABLE RAW.REVIEWS       APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM OPS.STR_APP_DETAILS   ON TABLE RAW.APP_DETAILS   APPEND_ONLY = TRUE;

-- Audit log; consuming the streams into it also advances their offsets
-- (a stream only resets when read inside a DML statement).
CREATE TABLE IF NOT EXISTS OPS.DBT_TRIGGER_LOG (
  triggered_at TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
  new_most_played INT, new_player_counts INT, new_reviews INT, new_app_details INT
);

CREATE OR REPLACE PROCEDURE OPS.RUN_DBT()
  RETURNS STRING
  LANGUAGE SQL
  EXECUTE AS CALLER   -- owner's-rights procs forbid SHOW commands, which dbt issues internally
AS
$$
BEGIN
  INSERT INTO OPS.DBT_TRIGGER_LOG (new_most_played, new_player_counts, new_reviews, new_app_details)
  SELECT
    (SELECT COUNT(*) FROM OPS.STR_MOST_PLAYED),
    (SELECT COUNT(*) FROM OPS.STR_PLAYER_COUNTS),
    (SELECT COUNT(*) FROM OPS.STR_REVIEWS),
    (SELECT COUNT(*) FROM OPS.STR_APP_DETAILS);

  -- Uncomment once the dbt project is uploaded as a DBT PROJECT object:
  -- EXECUTE DBT PROJECT STEAM.OPS.STEAM_DBT ARGS='build';

  RETURN 'dbt trigger fired';
END;
$$;

-- Triggered task: no schedule -- fires when a stream has data.
-- (60s minimum debounce via USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS;
-- raise it so one daily batch = roughly one dbt run, not one per pipe.)
CREATE OR REPLACE TASK OPS.T_DBT_ON_ARRIVAL
  WAREHOUSE = STEAM_WH
  USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 900
  WHEN SYSTEM$STREAM_HAS_DATA('OPS.STR_REVIEWS')
    OR SYSTEM$STREAM_HAS_DATA('OPS.STR_MOST_PLAYED')
    OR SYSTEM$STREAM_HAS_DATA('OPS.STR_PLAYER_COUNTS')
    OR SYSTEM$STREAM_HAS_DATA('OPS.STR_APP_DETAILS')
AS
  CALL OPS.RUN_DBT();

-- Enable when ready:
-- ALTER TASK OPS.T_DBT_ON_ARRIVAL RESUME;

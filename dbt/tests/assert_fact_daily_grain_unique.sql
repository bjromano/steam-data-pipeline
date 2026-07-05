-- Singular test: fact_daily_game_performance must be unique on (activity_date, game_key).
-- Replaces the dbt_utils.unique_combination_of_columns test so the project has
-- zero package dependencies (simplifies running dbt inside Snowflake).
-- A test passes when it returns zero rows.
select activity_date, game_key, count(*) as duplicate_rows
from {{ ref('fact_daily_game_performance') }}
group by activity_date, game_key
having count(*) > 1

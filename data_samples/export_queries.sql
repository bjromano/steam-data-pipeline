-- Run each query in Snowsight, then download the result grid as CSV
-- (download arrow, top-right of results) and save into data_samples/
-- with the filename noted above each query. Keep exports small (<1 MB)
-- so GitHub renders them as interactive tables.

USE ROLE SYSADMIN;
USE DATABASE STEAM;

-- ============================================================
-- 1) sample_daily_game_performance.csv  — the "money table"
--    One row per game per day: rank, CCU, review sentiment.
--    Served by the rpt_ reporting view (fact ⋈ dim, pre-joined).
-- ============================================================
SELECT *
FROM GOLD.RPT_DAILY_GAME_PERFORMANCE
ORDER BY activity_date DESC, chart_rank
LIMIT 300;

-- ============================================================
-- 2) sample_dim_game.csv — the dimension
--    Note has_store_page = FALSE rows (unlisted titles like
--    Deadlock): facts always resolve, gaps stay visible.
-- ============================================================
SELECT
    game_key,
    game_name,
    primary_developer,
    primary_publisher,
    primary_genre,
    is_free,
    price_currency,
    price_final,
    release_date,
    metacritic_score,
    total_recommendations,
    has_store_page
FROM GOLD.DIM_GAME
ORDER BY total_recommendations DESC NULLS LAST;

-- ============================================================
-- 3) sample_fact_review.csv — event-grain fact (no review text;
--    the pipeline keeps length/votes/playtime, not content)
-- ============================================================
SELECT
    review_id,
    game_key,
    review_date,
    review_language,
    is_positive,
    votes_up,
    votes_funny,
    playtime_at_review_hrs,
    steam_purchase,
    written_during_early_access,
    review_length_chars
FROM GOLD.FACT_REVIEW
ORDER BY votes_up DESC
LIMIT 200;

-- Reporting view: fact_daily_game_performance flattened with game attributes.
-- A thin consumption layer over the star — materialized as a VIEW so it can
-- never drift from dim_game (it re-joins on every read). BI tools and casual
-- users get one blessed flat dataset; the modeled core stays normalized.
{{ config(materialized='view') }}

select
    f.activity_date,
    f.chart_rank,
    f.last_week_rank,
    g.game_name,
    g.primary_developer,
    g.primary_publisher,
    g.primary_genre,
    g.is_free,
    g.has_store_page,
    f.peak_in_game,
    f.snapshot_player_count,
    f.reviews_total,
    f.reviews_positive,
    f.reviews_negative,
    round(f.positive_review_ratio, 3)     as positive_review_ratio,
    round(f.avg_weighted_vote_score, 3)   as avg_weighted_vote_score,
    f.median_playtime_at_review_min
from {{ ref('fact_daily_game_performance') }} f
join {{ ref('dim_game') }} g
    on g.game_key = f.game_key

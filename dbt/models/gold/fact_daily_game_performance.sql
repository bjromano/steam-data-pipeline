-- Grain: one row per game per day. Combines chart rank, peak CCU,
-- player-count snapshot, and that day's review activity.
with chart as (
    select chart_date, appid, chart_rank, last_week_rank, peak_in_game
    from {{ ref('silver_most_played') }}
),

counts as (
    select snapshot_date, appid, player_count
    from {{ ref('silver_player_counts') }}
),

review_agg as (
    select
        appid,
        created_at::date                              as review_date,
        count(*)                                      as reviews_total,
        sum(iff(voted_up, 1, 0))                      as reviews_positive,
        sum(iff(voted_up, 0, 1))                      as reviews_negative,
        avg(weighted_vote_score)                      as avg_weighted_vote_score,
        median(playtime_at_review_min)                as median_playtime_at_review_min
    from {{ ref('silver_reviews') }}
    group by 1, 2
)

select
    chart.chart_date                                  as activity_date,
    chart.appid                                       as game_key,
    chart.chart_rank,
    chart.last_week_rank,
    chart.peak_in_game,
    counts.player_count                               as snapshot_player_count,
    coalesce(review_agg.reviews_total, 0)             as reviews_total,
    coalesce(review_agg.reviews_positive, 0)          as reviews_positive,
    coalesce(review_agg.reviews_negative, 0)          as reviews_negative,
    review_agg.avg_weighted_vote_score,
    review_agg.median_playtime_at_review_min,
    div0(review_agg.reviews_positive, review_agg.reviews_total) as positive_review_ratio
from chart
left join counts
    on counts.appid = chart.appid and counts.snapshot_date = chart.chart_date
left join review_agg
    on review_agg.appid = chart.appid and review_agg.review_date = chart.chart_date

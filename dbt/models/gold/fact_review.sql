-- Grain: one row per review. Incremental on review_id.
{{ config(
    materialized='incremental',
    unique_key='review_id',
    incremental_strategy='merge'
) }}

select
    review_id,
    appid                        as game_key,
    author_steamid,
    created_at,
    created_at::date             as review_date,
    updated_at,
    review_language,
    voted_up                     as is_positive,
    iff(voted_up, 1, 0)          as positive_flag,
    votes_up,
    votes_funny,
    weighted_vote_score,
    comment_count,
    playtime_at_review_min,
    round(playtime_at_review_min / 60.0, 1) as playtime_at_review_hrs,
    author_playtime_forever_min,
    author_num_games_owned,
    author_num_reviews,
    steam_purchase,
    received_for_free,
    written_during_early_access,
    primarily_steam_deck,
    length(review_text)          as review_length_chars,
    extracted_at
from {{ ref('silver_reviews') }}

{% if is_incremental() %}
where extracted_at > (select coalesce(max(extracted_at), '1970-01-01'::timestamp_tz) from {{ this }})
{% endif %}

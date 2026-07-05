-- One row per review (deduped across runs; a review can be re-extracted
-- if updated or if runs overlap).
with src as (
    select
        payload:recommendationid::string                       as review_id,
        payload:appid::int                                     as appid,
        payload:author:steamid::string                         as author_steamid,
        payload:author:num_games_owned::int                    as author_num_games_owned,
        payload:author:num_reviews::int                        as author_num_reviews,
        payload:author:playtime_forever::int                   as author_playtime_forever_min,
        payload:author:playtime_at_review::int                 as playtime_at_review_min,
        payload:author:playtime_last_two_weeks::int            as playtime_last_two_weeks_min,
        payload:language::string                               as review_language,
        payload:review::string                                 as review_text,
        to_timestamp_tz(payload:timestamp_created::int)        as created_at,
        to_timestamp_tz(payload:timestamp_updated::int)        as updated_at,
        payload:voted_up::boolean                              as voted_up,
        payload:votes_up::int                                  as votes_up,
        payload:votes_funny::int                               as votes_funny,
        payload:weighted_vote_score::float                     as weighted_vote_score,
        payload:comment_count::int                             as comment_count,
        payload:steam_purchase::boolean                        as steam_purchase,
        payload:received_for_free::boolean                     as received_for_free,
        payload:written_during_early_access::boolean           as written_during_early_access,
        payload:primarily_steam_deck::boolean                  as primarily_steam_deck,
        payload:"_extracted_at"::timestamp_tz                  as extracted_at,
        _loaded_at
    from {{ source('steam_raw', 'REVIEWS') }}
)

select *
from src
qualify row_number() over (
    partition by review_id
    order by updated_at desc, extracted_at desc
) = 1

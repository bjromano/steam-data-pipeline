-- One row per game per extraction; downstream dim takes latest per appid.
with src as (
    select
        payload:appid::int                                  as appid,
        payload:success::boolean                            as fetch_success,
        payload:data:name::string                           as game_name,
        payload:data:type::string                           as app_type,
        payload:data:is_free::boolean                       as is_free,
        payload:data:developers                             as developers,
        payload:data:publishers                             as publishers,
        payload:data:genres                                 as genres,
        payload:data:categories                             as categories,
        payload:data:price_overview:currency::string        as price_currency,
        payload:data:price_overview:final::int / 100        as price_final,
        payload:data:price_overview:discount_percent::int   as discount_percent,
        payload:data:release_date:date::string              as release_date_raw,
        payload:data:metacritic:score::int                  as metacritic_score,
        payload:data:recommendations:total::int             as total_recommendations,
        payload:data:required_age::string                   as required_age,
        payload:data:short_description::string              as short_description,
        payload:"_extracted_at"::timestamp_tz               as extracted_at,
        _loaded_at
    from {{ source('steam_raw', 'APP_DETAILS') }}
)

select *
from src
where fetch_success
qualify row_number() over (
    partition by appid, extracted_at::date
    order by extracted_at desc
) = 1

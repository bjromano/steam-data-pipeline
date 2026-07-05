-- One row per game per extraction: daily top-100 chart snapshot.
with src as (
    select
        payload:appid::int                         as appid,
        payload:rank::int                          as chart_rank,
        payload:last_week_rank::int                as last_week_rank,
        payload:peak_in_game::int                  as peak_in_game,
        to_timestamp_tz(payload:rollup_date::int)  as rollup_date,
        payload:"_extracted_at"::timestamp_tz      as extracted_at,
        _file,
        _loaded_at
    from {{ source('steam_raw', 'MOST_PLAYED') }}
)

select *, extracted_at::date as chart_date
from src
qualify row_number() over (
    partition by appid, extracted_at::date
    order by extracted_at desc
) = 1

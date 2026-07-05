-- Point-in-time concurrent player count snapshots.
select
    payload:appid::int                     as appid,
    payload:player_count::int              as player_count,
    payload:result::int                    as api_result,
    payload:"_extracted_at"::timestamp_tz  as extracted_at,
    payload:"_extracted_at"::date          as snapshot_date,
    _loaded_at
from {{ source('steam_raw', 'PLAYER_COUNTS') }}
qualify row_number() over (
    partition by appid, snapshot_date
    order by extracted_at desc
) = 1

-- Game dimension. Spine = every game ever seen on the most-played chart, so
-- every fact row's game_key resolves even for games with no store page
-- (e.g. unlisted titles like Deadlock, where appdetails returns success=false).
-- Store attributes are left-joined; games without them get a placeholder name.
with game_spine as (
    select distinct appid
    from {{ ref('silver_most_played') }}
),

latest_details as (
    select *
    from {{ ref('silver_app_details') }}
    qualify row_number() over (partition by appid order by extracted_at desc) = 1
)

select
    s.appid                                        as game_key,
    coalesce(d.game_name, 'Unknown (' || s.appid || ')') as game_name,
    d.app_type,
    d.is_free,
    d.developers[0]::string                        as primary_developer,
    d.publishers[0]::string                        as primary_publisher,
    d.genres[0]:description::string                as primary_genre,
    d.genres,
    d.price_currency,
    d.price_final,
    d.discount_percent,
    try_to_date(d.release_date_raw, 'DD Mon, YYYY') as release_date,
    d.metacritic_score,
    d.total_recommendations,
    d.short_description,
    (d.appid is not null)                          as has_store_page,
    d.extracted_at                                 as attributes_as_of
from game_spine s
left join latest_details d
    on d.appid = s.appid

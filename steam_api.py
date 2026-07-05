"""
Shared Steam API extraction logic — the single source of truth.

Used by:
  extract_steam.py   (local CLI: testing and backfills)
  lambda/handler.py  (production: AWS Lambda)

The Snowpark proc (snowflake/05) embeds its own copy because stored procedure
code lives inside the SQL definition and can't import from this repo.

Every extractor returns a list of dicts, each stamped with _extracted_at and
_source metadata. Callers decide where the records go (local disk or S3).
"""

import json
import logging
import time
from datetime import datetime, timedelta, timezone

import requests
from requests.adapters import HTTPAdapter, Retry

log = logging.getLogger("steam_api")

MOST_PLAYED_URL = "https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/"
PLAYER_COUNT_URL = "https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/"
APP_DETAILS_URL = "https://store.steampowered.com/api/appdetails"
REVIEWS_URL = "https://store.steampowered.com/appreviews/{appid}"

REVIEW_LOOKBACK_HOURS = 24
SLEEP_BETWEEN_CALLS = 0.3   # polite delay for tolerant endpoints
SLEEP_APP_DETAILS = 1.6     # appdetails allows only ~200 requests / 5 min
MAX_REVIEW_PAGES_PER_APP = 100


def make_session() -> requests.Session:
    """HTTP session with retry/backoff on rate-limit and server errors."""
    s = requests.Session()
    retries = Retry(total=5, backoff_factor=2, status_forcelist=[429, 500, 502, 503, 504])
    s.mount("https://", HTTPAdapter(max_retries=retries))
    s.headers.update({"User-Agent": "steam-data-pipeline/2.0"})
    return s


def get_json(session: requests.Session, url: str, params: dict | None = None) -> dict:
    resp = session.get(url, params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def wrap(record: dict, source: str, extracted_at: str) -> dict:
    """Stamp a raw record with extraction metadata."""
    return {"_extracted_at": extracted_at, "_source": source, **record}


def to_ndjson(records: list[dict]) -> bytes:
    """One JSON object per line — the format the Snowflake stage expects."""
    return ("\n".join(json.dumps(r, ensure_ascii=False) for r in records) + "\n").encode()


def build_s3_key(dataset: str, extracted_at: str, part: int | None = None) -> str:
    """raw/<dataset>/ingest_date=YYYY-MM-DD/<dataset>_<timestamp>[_partNN].ndjson"""
    ts = datetime.fromisoformat(extracted_at)
    suffix = f"_part{part:02d}" if part is not None else ""
    return (f"raw/{dataset}/ingest_date={ts:%Y-%m-%d}/"
            f"{dataset}_{ts:%Y%m%dT%H%M%S}{suffix}.ndjson")


# ---------------------------------------------------------------------------
# Extractors
# ---------------------------------------------------------------------------

def extract_most_played(session, extracted_at: str, top_n: int = 100) -> list[dict]:
    """Top N games by concurrent players. This is the driver dataset:
    its appids scope every other extraction."""
    data = get_json(session, MOST_PLAYED_URL)
    response = data.get("response", {})
    ranks = response.get("ranks", [])[:top_n]
    if not ranks:
        raise RuntimeError(f"GetMostPlayedGames returned no ranks: {json.dumps(data)[:500]}")
    rollup_date = response.get("rollup_date")
    log.info("most_played: %d games", len(ranks))
    return [wrap({**r, "rollup_date": rollup_date}, "GetMostPlayedGames", extracted_at)
            for r in ranks]


def extract_player_counts(session, appids, extracted_at: str) -> list[dict]:
    """Point-in-time concurrent player count per game. Some apps (unlisted
    titles like Deadlock) return 404 -- logged and skipped, never fatal."""
    records = []
    for appid in appids:
        try:
            resp = get_json(session, PLAYER_COUNT_URL, params={"appid": appid}).get("response", {})
            records.append(wrap({"appid": appid,
                                 "player_count": resp.get("player_count"),
                                 "result": resp.get("result")},
                                "GetNumberOfCurrentPlayers", extracted_at))
        except Exception as e:
            log.warning("player_count failed for %s: %s", appid, e)
        time.sleep(SLEEP_BETWEEN_CALLS)
    log.info("player_counts: %d of %d games", len(records), len(appids))
    return records


def extract_reviews(session, appids, extracted_at: str) -> list[dict]:
    """All reviews created in the last REVIEW_LOOKBACK_HOURS.

    The API can't filter by time, so we page newest-first (filter=recent,
    cursor pagination) and stop once a page crosses the cutoff."""
    cutoff = datetime.fromisoformat(extracted_at) - timedelta(hours=REVIEW_LOOKBACK_HOURS)
    cutoff_ts = int(cutoff.timestamp())
    records = []
    for i, appid in enumerate(appids, 1):
        cursor, seen = "*", set()
        for _ in range(MAX_REVIEW_PAGES_PER_APP):
            try:
                data = get_json(session, REVIEWS_URL.format(appid=appid), params={
                    "json": 1, "filter": "recent", "language": "all",
                    "purchase_type": "all", "num_per_page": 100, "cursor": cursor})
            except Exception as e:
                log.warning("reviews failed for %s: %s", appid, e)
                break
            reviews = data.get("reviews", [])
            if not reviews:
                break
            crossed_cutoff = False
            for r in reviews:
                if r["recommendationid"] in seen:      # cursors can overlap
                    continue
                seen.add(r["recommendationid"])
                if r.get("timestamp_created", 0) < cutoff_ts:
                    crossed_cutoff = True
                    continue
                records.append(wrap({"appid": appid, **r}, "appreviews", extracted_at))
            next_cursor = data.get("cursor")
            if crossed_cutoff or not next_cursor or next_cursor == cursor:
                break
            cursor = next_cursor
            time.sleep(SLEEP_BETWEEN_CALLS)
        if i % 25 == 0:
            log.info("reviews: %d/%d apps, %d reviews so far", i, len(appids), len(records))
        time.sleep(SLEEP_BETWEEN_CALLS)
    log.info("reviews: %d total in last %dh", len(records), REVIEW_LOOKBACK_HOURS)
    return records


def extract_app_details(session, appids, extracted_at: str) -> list[dict]:
    """Store metadata per game (the dimension source). Failures are recorded
    with success=False so gaps are visible downstream, not silent."""
    records = []
    for i, appid in enumerate(appids, 1):
        try:
            entry = get_json(session, APP_DETAILS_URL,
                             params={"appids": appid, "l": "english"}).get(str(appid), {})
            records.append(wrap({"appid": appid,
                                 "success": entry.get("success", False),
                                 "data": entry.get("data") if entry.get("success") else None},
                                "appdetails", extracted_at))
        except Exception as e:
            records.append(wrap({"appid": appid, "success": False, "error": str(e)},
                                "appdetails", extracted_at))
        if i % 25 == 0:
            log.info("app_details: %d/%d", i, len(appids))
        time.sleep(SLEEP_APP_DETAILS)
    return records


# Registry used by the Lambda worker to route by dataset name
EXTRACTORS = {
    "player_counts": extract_player_counts,
    "reviews": extract_reviews,
    "app_details": extract_app_details,
}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

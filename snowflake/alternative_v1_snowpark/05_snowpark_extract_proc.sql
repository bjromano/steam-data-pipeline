-- Snowpark Python stored procedure: extracts from the Steam API and writes
-- NDJSON files to the external stage (which lives on your S3 bucket).
-- Same logic as extract_steam.py, but S3 writes go through the storage
-- integration -- no AWS keys stored in Snowflake.
USE ROLE SYSADMIN;
USE DATABASE STEAM;
USE SCHEMA OPS;

CREATE OR REPLACE PROCEDURE OPS.EXTRACT_STEAM(TOP_N INT DEFAULT 100)
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  EXTERNAL_ACCESS_INTEGRATIONS = (steam_api_int)
  HANDLER = 'run'
AS
$$
import io
import json
import time
from datetime import datetime, timedelta, timezone

import requests

MOST_PLAYED_URL = "https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/"
PLAYER_COUNT_URL = "https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/"
APP_DETAILS_URL = "https://store.steampowered.com/api/appdetails"
REVIEWS_URL = "https://store.steampowered.com/appreviews/{appid}"
STAGE = "@STEAM.OPS.STEAM_RAW_STAGE"


def get_json(session, url, params=None):
    r = session.get(url, params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def wrap(rec, source, ts):
    return {"_extracted_at": ts, "_source": source, **rec}


def put_ndjson(sf_session, records, dataset, run_ts):
    if not records:
        return 0
    body = ("\n".join(json.dumps(r, ensure_ascii=False) for r in records) + "\n").encode()
    path = (f"{STAGE}/{dataset}/ingest_date={run_ts:%Y-%m-%d}/"
            f"{dataset}_{run_ts:%Y%m%dT%H%M%S}.ndjson")
    sf_session.file.put_stream(io.BytesIO(body), path, auto_compress=False, overwrite=True)
    return len(records)


def run(sf_session, top_n):
    http = requests.Session()
    http.headers.update({"User-Agent": "steam-data-pipeline/1.0"})
    run_ts = datetime.now(timezone.utc)
    ts = run_ts.isoformat()
    counts = {}

    # 1. most played
    data = get_json(http, MOST_PLAYED_URL)
    resp = data.get("response", {})
    ranks = resp.get("ranks", [])[:top_n]
    if not ranks:
        raise RuntimeError("GetMostPlayedGames returned no ranks")
    rollup = resp.get("rollup_date")
    most_played = [wrap({**r, "rollup_date": rollup}, "GetMostPlayedGames", ts) for r in ranks]
    appids = [r["appid"] for r in ranks]
    counts["most_played"] = put_ndjson(sf_session, most_played, "most_played", run_ts)

    # 2. player count snapshots
    recs = []
    for appid in appids:
        try:
            d = get_json(http, PLAYER_COUNT_URL, params={"appid": appid}).get("response", {})
            recs.append(wrap({"appid": appid, "player_count": d.get("player_count"),
                              "result": d.get("result")}, "GetNumberOfCurrentPlayers", ts))
        except Exception:
            pass
        time.sleep(0.3)
    counts["player_counts"] = put_ndjson(sf_session, recs, "player_counts", run_ts)

    # 3. reviews in last 24h (cursor pagination, newest first)
    cutoff_ts = int((run_ts - timedelta(hours=24)).timestamp())
    recs = []
    for appid in appids:
        cursor, seen = "*", set()
        for _ in range(100):
            try:
                d = get_json(http, REVIEWS_URL.format(appid=appid), params={
                    "json": 1, "filter": "recent", "language": "all",
                    "purchase_type": "all", "num_per_page": 100, "cursor": cursor})
            except Exception:
                break
            reviews = d.get("reviews", [])
            if not reviews:
                break
            done = False
            for r in reviews:
                if r["recommendationid"] in seen:
                    continue
                seen.add(r["recommendationid"])
                if r.get("timestamp_created", 0) < cutoff_ts:
                    done = True
                    continue
                recs.append(wrap({"appid": appid, **r}, "appreviews", ts))
            nc = d.get("cursor")
            if done or not nc or nc == cursor:
                break
            cursor = nc
            time.sleep(0.3)
        time.sleep(0.3)
    counts["reviews"] = put_ndjson(sf_session, recs, "reviews", run_ts)

    # 4. app details (rate-limited endpoint, be slow)
    recs = []
    for appid in appids:
        try:
            entry = get_json(http, APP_DETAILS_URL,
                             params={"appids": appid, "l": "english"}).get(str(appid), {})
            recs.append(wrap({"appid": appid, "success": entry.get("success", False),
                              "data": entry.get("data") if entry.get("success") else None},
                             "appdetails", ts))
        except Exception as e:
            recs.append(wrap({"appid": appid, "success": False, "error": str(e)},
                             "appdetails", ts))
        time.sleep(1.6)
    counts["app_details"] = put_ndjson(sf_session, recs, "app_details", run_ts)

    return json.dumps(counts)
$$;

-- Smoke test (expect a JSON string of record counts; takes several minutes):
-- CALL OPS.EXTRACT_STEAM(100);

"""
AWS Lambda adapter for the Steam extraction (production path).
Extraction logic lives in steam_api.py, shared with the local CLI.

Fan-out design to stay far below Lambda's 15-minute cap:

  EventBridge cron sends {"task": "chart"} daily
    -> chart mode: fetch top-100, write to S3, then async-invoke THIS SAME
       FUNCTION once per (dataset, appid-chunk):
  {"task": "extract", "dataset": "reviews", "appids": [...], "run_ts": "...", "part": 0}
    -> worker mode: extract one dataset for one chunk, write to S3.

With CHUNK_SIZE=50: 6 parallel workers, worst one (~50 apps x 2s) ~3 min.

Env vars: S3_BUCKET (required), TOP_N (default 100), CHUNK_SIZE (default 50).
Deploy note: package steam_api.py alongside this file (see infra/lambda_setup.md).
"""

import json
import logging
import os

import boto3

import steam_api

logging.basicConfig()
log = logging.getLogger()
log.setLevel(logging.INFO)

S3_BUCKET = os.environ["S3_BUCKET"]
TOP_N = int(os.getenv("TOP_N", "100"))
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "50"))

s3 = boto3.client("s3")
lam = boto3.client("lambda")
session = steam_api.make_session()


def put_ndjson(records, dataset, extracted_at, part=None):
    if not records:
        log.warning("%s: no records, skipping", dataset)
        return None
    key = steam_api.build_s3_key(dataset, extracted_at, part)
    s3.put_object(Bucket=S3_BUCKET, Key=key, Body=steam_api.to_ndjson(records))
    log.info("%s: wrote %d records -> s3://%s/%s", dataset, len(records), S3_BUCKET, key)
    return key


def run_chart(context):
    """Fetch the driver dataset, then fan out one worker per dataset+chunk."""
    extracted_at = steam_api.utc_now_iso()
    most_played = steam_api.extract_most_played(session, extracted_at, top_n=TOP_N)
    put_ndjson(most_played, "most_played", extracted_at)

    appids = [r["appid"] for r in most_played]
    chunks = [appids[i:i + CHUNK_SIZE] for i in range(0, len(appids), CHUNK_SIZE)]

    invoked = 0
    for dataset in steam_api.EXTRACTORS:
        for part, chunk in enumerate(chunks):
            lam.invoke(
                FunctionName=context.function_name,
                InvocationType="Event",   # async fire-and-forget
                Payload=json.dumps({"task": "extract", "dataset": dataset,
                                    "appids": chunk, "run_ts": extracted_at, "part": part}))
            invoked += 1
    log.info("chart done: %d games, fanned out %d workers", len(appids), invoked)
    return {"status": "ok", "games": len(appids), "workers": invoked}


def run_worker(event):
    """Extract one dataset for one chunk of appids."""
    dataset, appids = event["dataset"], event["appids"]
    extracted_at, part = event["run_ts"], event.get("part")
    records = steam_api.EXTRACTORS[dataset](session, appids, extracted_at)
    key = put_ndjson(records, dataset, extracted_at, part)
    return {"status": "ok", "dataset": dataset, "part": part,
            "records": len(records), "key": key}


def lambda_handler(event, context):
    task = event.get("task", "chart")
    if task == "chart":
        return run_chart(context)
    if task == "extract":
        return run_worker(event)
    raise ValueError(f"unknown task: {task}")

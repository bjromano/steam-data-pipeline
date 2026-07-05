"""
Local CLI for the Steam extraction — testing and backfills.
Production runs on AWS Lambda (lambda/handler.py); both share steam_api.py.

Usage:
  python extract_steam.py                 # extract everything, upload to S3
  python extract_steam.py --dry-run       # write files to ./out instead of S3
  python extract_steam.py --datasets reviews player_counts

Env vars (via .env): AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET,
optionally AWS_REGION (default us-east-1), TOP_N (default 100).
"""

import argparse
import logging
import os
import sys
from pathlib import Path

import steam_api

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("extract_steam")

ALL_DATASETS = ["most_played", "player_counts", "reviews", "app_details"]


def upload(records, dataset, extracted_at, dry_run, bucket):
    if not records:
        log.warning("%s: no records, skipping upload", dataset)
        return
    body = steam_api.to_ndjson(records)
    key = steam_api.build_s3_key(dataset, extracted_at)
    if dry_run:
        path = Path("out") / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
        log.info("%s: wrote %d records -> %s", dataset, len(records), path)
    else:
        import boto3
        boto3.client("s3", region_name=os.getenv("AWS_REGION", "us-east-1")).put_object(
            Bucket=bucket, Key=key, Body=body)
        log.info("%s: uploaded %d records -> s3://%s/%s", dataset, len(records), bucket, key)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="write to ./out instead of S3")
    parser.add_argument("--datasets", nargs="+", default=ALL_DATASETS, choices=ALL_DATASETS)
    args = parser.parse_args()

    bucket = os.getenv("S3_BUCKET")
    if not args.dry_run and not bucket:
        sys.exit("S3_BUCKET env var required (or use --dry-run)")

    extracted_at = steam_api.utc_now_iso()
    session = steam_api.make_session()

    # most_played always runs: its appids scope everything else
    most_played = steam_api.extract_most_played(session, extracted_at,
                                                top_n=int(os.getenv("TOP_N", "100")))
    appids = [r["appid"] for r in most_played]
    if "most_played" in args.datasets:
        upload(most_played, "most_played", extracted_at, args.dry_run, bucket)

    for dataset in ["player_counts", "reviews", "app_details"]:
        if dataset in args.datasets:
            records = steam_api.EXTRACTORS[dataset](session, appids, extracted_at)
            upload(records, dataset, extracted_at, args.dry_run, bucket)

    log.info("done")


if __name__ == "__main__":
    main()

"""
fetch_trials.py — pull studies from the ClinicalTrials.gov v2 API to local NDJSON.

Lands the FULL raw payload. No parsing will happen here: transformation happens in Snowflake (ELT).

Usage:
    python scripts/fetch_trials.py
"""

import json
import time
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests


# CONFIG

BASE_URL = "https://clinicaltrials.gov/api/v2/studies"

QUERY_COND = "obesity"
FILTER_PHASE = None   # filter.phase is rejected by the live v2 API — phase is filtered in SQL
FILTER_STATUS = None                # e.g. "RECRUITING|COMPLETED", or None for all
STUDY_TYPE = None     # filter.advanced likewise — study type is filtered in SQL
SORT = "LastUpdatePostDate:desc"   # most recently updated first
MAX_STUDIES = 2000                 # hard cap so you can't runaway-fetch
PAGE_SIZE = 100                     # max 1000; 100 keeps progress legible
SLEEP_SECONDS = 0.25                # be a good citizen, no API key required

OUT_DIR = Path("data/raw")
# ============================================================


def build_params(page_token=None):
    params = {
        "query.cond": QUERY_COND,
        "pageSize": PAGE_SIZE,
        "format": "json",
        "countTotal": "true",
        
    }
    if FILTER_PHASE:
        params["filter.phase"] = FILTER_PHASE
    if FILTER_STATUS:
        params["filter.overallStatus"] = FILTER_STATUS
    if STUDY_TYPE:
        params["filter.advanced"] = f"AREA[StudyType]{STUDY_TYPE}"
    if page_token:
        params["pageToken"] = page_token
    if SORT:
        params["sort"] = SORT
    return params


def extract_nct_id(study):
    """Dig out the NCT ID. Returns None if the shape is unexpected."""
    try:
        return study["protocolSection"]["identificationModule"]["nctId"]
    except (KeyError, TypeError):
        return None


def fetch_all():
    batch_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / f"studies_{batch_id}.ndjson"

    session = requests.Session()
    session.headers.update({"User-Agent": "ct-eligibility-project/0.1"})

    page_token = None
    total_written = 0
    skipped = 0
    page_num = 0
    seen_ids = set()

    with out_path.open("w", encoding="utf-8") as f:
        while total_written < MAX_STUDIES:
            page_num += 1
            resp = session.get(BASE_URL, params=build_params(page_token), timeout=30)

            if resp.status_code != 200:
                print(f"\nHTTP {resp.status_code} on page {page_num}")
                print(resp.text[:500])
                sys.exit(1)

            data = resp.json()

            # First page: sanity-check the response shape and print the total.
            if page_num == 1:
                print(f"Response keys: {list(data.keys())}")
                print(f"Total matching studies: {data.get('totalCount', 'unknown')}")
                print(f"Fetching up to {MAX_STUDIES}...\n")

            studies = data.get("studies", [])
            if not studies:
                print("No studies returned — check your filters.")
                break

            for study in studies:
                if total_written >= MAX_STUDIES:
                    break
                nct_id = extract_nct_id(study)
                if not nct_id:
                    skipped += 1
                    continue
                if nct_id in seen_ids:          # defensive: API shouldn't do this
                    skipped += 1
                    continue
                seen_ids.add(nct_id)

                # One JSON object per line, good for streaming into snowflake
                record = {
                    "nct_id": nct_id,
                    "payload": study,
                    "source_batch": batch_id,
                }
                f.write(json.dumps(record) + "\n")
                total_written += 1

            print(f"  page {page_num:>3}  |  written: {total_written:>5}")

            page_token = data.get("nextPageToken")
            if not page_token:
                print("\nNo nextPageToken — reached the end of results.")
                break

            time.sleep(SLEEP_SECONDS)

    print(f"\nDone.")
    print(f"  file        : {out_path}")
    print(f"  studies     : {total_written}")
    print(f"  skipped     : {skipped}")
    print(f"  size        : {out_path.stat().st_size / 1_000_000:.1f} MB")
    print(f"  batch_id    : {batch_id}")
    return out_path


if __name__ == "__main__":
    fetch_all()

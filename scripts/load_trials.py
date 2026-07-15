"""
load_trials.py — land local NDJSON into Snowflake.

    PUT  -> stage (auto-gzip)
    COPY -> temporary landing table (one VARIANT per line)
    MERGE -> raw.studies_raw, keyed on nct_id

Idempotent: run it as many times as you like. Row count won't move once the
same batches are loaded.

Usage:
    py scripts/load_trials.py
"""

import sys
from pathlib import Path

from snow_connect import get_connection

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"

STAGE = "ct_trials.raw.trials_stage"
LANDING = "ct_trials.raw.studies_landing"
TARGET = "ct_trials.raw.studies_raw"


def run(cur, label, sql):
    print(f"\n--- {label} ---")
    cur.execute(sql)
    return cur.fetchall()


def main():
    files = sorted(RAW_DIR.glob("studies_*.ndjson"))
    if not files:
        print(f"No studies_*.ndjson found in {RAW_DIR}")
        print("Run: py scripts/fetch_trials.py")
        sys.exit(1)

    print(f"Found {len(files)} file(s) to load:")
    for f in files:
        print(f"  {f.name}  ({f.stat().st_size / 1_000_000:.1f} MB)")

    conn = get_connection()
    cur = conn.cursor()

    try:
        # Row count before, so we can prove idempotency.
        cur.execute(f"SELECT COUNT(*) FROM {TARGET}")
        before = cur.fetchone()[0]
        print(f"\n{TARGET} rows before: {before}")

        # ---- 1. PUT ----------------------------------------------------
        # as_posix() matters on Windows: PUT wants forward slashes.
        for f in files:
            uri = f"file://{f.as_posix()}"
            rows = run(cur, f"PUT {f.name}", f"""
                PUT '{uri}' @{STAGE}
                  AUTO_COMPRESS = TRUE
                  OVERWRITE = TRUE
            """)
            for r in rows:
                # (source, target, src_size, tgt_size, src_compression,
                #  tgt_compression, status, message)
                print(f"  {r[0]} -> {r[1]}  [{r[6]}]")

        # ---- 2. COPY INTO landing --------------------------------------
        run(cur, "CREATE landing table", f"""
            CREATE OR REPLACE TEMPORARY TABLE {LANDING} (record VARIANT)
        """)

        rows = run(cur, "COPY INTO landing", f"""
            COPY INTO {LANDING}
            FROM @{STAGE}
            FILE_FORMAT = (TYPE = JSON STRIP_OUTER_ARRAY = FALSE)
            PATTERN = '.*studies_.*[.]ndjson[.]gz'
            ON_ERROR = 'ABORT_STATEMENT'
        """)
        for r in rows:
            print(f"  {r}")

        cur.execute(f"SELECT COUNT(*) FROM {LANDING}")
        print(f"  landing rows: {cur.fetchone()[0]}")

        # ---- 3. MERGE --------------------------------------------------
        # QUALIFY is load-bearing. If two batches contain the same nct_id,
        # the source has duplicate join keys and MERGE fails outright with
        # "Duplicate row detected during DML action". Dedupe first, keeping
        # the newest batch per trial.
        rows = run(cur, "MERGE into studies_raw", f"""
            MERGE INTO {TARGET} AS t
            USING (
                SELECT
                    record:nct_id::STRING       AS nct_id,
                    record:payload              AS payload,
                    record:source_batch::STRING AS source_batch
                FROM {LANDING}
                QUALIFY ROW_NUMBER() OVER (
                    PARTITION BY record:nct_id::STRING
                    ORDER BY record:source_batch::STRING DESC
                ) = 1
            ) AS s
            ON t.nct_id = s.nct_id
            WHEN MATCHED THEN UPDATE SET
                t.payload      = s.payload,
                t.source_batch = s.source_batch,
                t.ingested_at  = CURRENT_TIMESTAMP()
            WHEN NOT MATCHED THEN INSERT (nct_id, payload, source_batch, ingested_at)
                VALUES (s.nct_id, s.payload, s.source_batch, CURRENT_TIMESTAMP())
        """)
        for r in rows:
            print(f"  inserted: {r[0]}, updated: {r[1]}")

        # ---- verify ----------------------------------------------------
        cur.execute(f"SELECT COUNT(*), COUNT(DISTINCT nct_id) FROM {TARGET}")
        total, distinct = cur.fetchone()

        print(f"\n{TARGET} rows after: {total}  (was {before})")
        print(f"  distinct nct_id  : {distinct}")
        if total != distinct:
            print("  WARNING: duplicates present — the MERGE key is wrong.")
        else:
            print("  no duplicates.")

    finally:
        conn.close()


if __name__ == "__main__":
    main()

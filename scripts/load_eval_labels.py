"""
load_eval_labels.py — load the hand-labeled CSV into Snowflake.

Reads eval/eval_labels.csv and writes ct_trials.eval.eval_labels, typed so
it can be joined against the model extraction for scoring.

    py scripts/load_eval_labels.py
"""

import csv
from pathlib import Path

from snow_connect import get_connection

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = PROJECT_ROOT / "eval" / "eval_labels.csv"

NUM_FIELDS = ["min_bmi", "max_bmi", "hba1c_threshold"]
BOOL_FIELDS = [
    "requires_diabetes", "excludes_diabetes",
    "excludes_prior_bariatric_surgery", "excludes_pregnancy",
]


def num(v):
    v = (v or "").strip()
    return float(v) if v else None


def boolean(v):
    v = (v or "").strip().upper()
    if v == "TRUE":
        return True
    if v == "FALSE":
        return False
    return None  # should not happen; flagged at load time


def main():
    if not CSV_PATH.exists():
        print(f"Not found: {CSV_PATH}")
        print("Rename your labeled file to eval/eval_labels.csv")
        raise SystemExit(1)

    rows = list(csv.DictReader(CSV_PATH.open(encoding="utf-8", newline="")))
    print(f"Read {len(rows)} labeled rows.")

    # validate booleans before touching Snowflake
    bad = [r["nct_id"] for r in rows
           for f in BOOL_FIELDS if boolean(r[f]) is None]
    if bad:
        print(f"WARNING: non-TRUE/FALSE boolean values in: {set(bad)}")

    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("""
            CREATE OR REPLACE TABLE ct_trials.eval.eval_labels (
                nct_id STRING,
                min_bmi FLOAT, max_bmi FLOAT, hba1c_threshold FLOAT,
                requires_diabetes BOOLEAN, excludes_diabetes BOOLEAN,
                excludes_prior_bariatric_surgery BOOLEAN, excludes_pregnancy BOOLEAN
            )
        """)
        cur.executemany(
            """INSERT INTO ct_trials.eval.eval_labels VALUES (%s,%s,%s,%s,%s,%s,%s,%s)""",
            [
                (
                    r["nct_id"],
                    num(r["min_bmi"]), num(r["max_bmi"]), num(r["hba1c_threshold"]),
                    boolean(r["requires_diabetes"]), boolean(r["excludes_diabetes"]),
                    boolean(r["excludes_prior_bariatric_surgery"]), boolean(r["excludes_pregnancy"]),
                )
                for r in rows
            ],
        )
        cur.execute("SELECT COUNT(*) FROM ct_trials.eval.eval_labels")
        print(f"Loaded {cur.fetchone()[0]} rows into eval.eval_labels")
    finally:
        conn.close()


if __name__ == "__main__":
    main()

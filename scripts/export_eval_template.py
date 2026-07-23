"""

Write the 30 eval trials to a CSV for hand-labeling.

Exports the criteria text and EMPTY label columns only. The model's answers are
deliberately left out: labels have to be made blind, or they anchor on the
model, the "ground truth" is contaminated, and the accuracy number means
nothing.

    python scripts/export_eval_template.py

"""

import csv
from pathlib import Path

from snow_connect import get_connection

PROJECT_ROOT = Path(__file__).resolve().parent.parent  # repo root, two levels up from this file
OUT = PROJECT_ROOT / "eval" / "eval_template.csv"      # CSV this script writes for the labeler to fill in

# the 7 facts to hand-label per trial (booleans get TRUE/FALSE, numbers get a
# value or a blank for "not stated")
LABEL_COLS = [
    "min_bmi",
    "max_bmi",
    "hba1c_threshold",
    "requires_diabetes",
    "excludes_diabetes",
    "excludes_prior_bariatric_surgery",
    "excludes_pregnancy",
]


def main():
    """Pull the eval trials from Snowflake and write them to the labeling CSV."""
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT nct_id, title, inclusion_text, exclusion_text
            FROM ct_trials.eval.eval_sample
            ORDER BY nct_id
        """)
        rows = cur.fetchall()
    finally:
        conn.close()

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            ["nct_id", "title", "inclusion_text", "exclusion_text"] + LABEL_COLS
        )
        for nct_id, title, incl, excl in rows:
            # write the trial text, then one empty cell per label for the human to fill
            w.writerow([nct_id, title, incl or "", excl or ""] + [""] * len(LABEL_COLS))

    print(f"Wrote {len(rows)} rows to {OUT}")
    print("\nLabeling instructions:")
    print("  * Booleans (requires_/excludes_*): type TRUE or FALSE")
    print("  * Numbers (min_bmi/max_bmi/hba1c_threshold): type the value,")
    print("    or LEAVE BLANK if the criteria don't state it.")
    print("  * Judge ONLY from the inclusion/exclusion text in the row.")
    print("  * Do this BEFORE running the extraction. Don't peek at model output.")


if __name__ == "__main__":
    main()

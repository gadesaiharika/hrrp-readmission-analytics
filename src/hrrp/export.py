"""Export the analytics views to CSV for Tableau Public.

Tableau Public cannot connect to a local PostgreSQL instance, so the published
dashboard is built on extracts. These are the exact views the dashboard uses —
regenerating them is how the published viz gets refreshed.
"""

from __future__ import annotations

import csv
from pathlib import Path

from . import db

VIEWS = [
    "vw_readmission_detail",
    "vw_hrrp_cohort_summary",
    "vw_readmission_monthly",
    "vw_payer_mix",
    "vw_provider_outliers",
    "vw_service_line_heatmap",
]


def export_views(conn, out_dir) -> dict:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    counts = {}
    for view in VIEWS:
        cols, rows = db.query(conn, f"SELECT * FROM {view}")
        path = out_dir / f"{view}.csv"
        with path.open("w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(cols)
            w.writerows(rows)
        counts[view] = len(rows)
    return counts

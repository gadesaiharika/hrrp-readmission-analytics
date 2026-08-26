"""Load Synthea-format CSVs into the raw_* staging tables.

Replaces the original `02_load_synthea.sh`. Same COPY semantics, but it runs on
Windows as well as macOS and Linux, and it reports per-table counts so a partial
load is obvious instead of silent.
"""

from __future__ import annotations

from pathlib import Path

# Parents before children, matching the order the ETL joins them.
LOAD_ORDER = [
    ("raw_organizations", "organizations.csv"),
    ("raw_providers",     "providers.csv"),
    ("raw_payers",        "payers.csv"),
    ("raw_patients",      "patients.csv"),
    ("raw_encounters",    "encounters.csv"),
    ("raw_conditions",    "conditions.csv"),
    ("raw_procedures",    "procedures.csv"),
]


def load_csvs(conn, csv_dir) -> dict:
    csv_dir = Path(csv_dir)
    if not csv_dir.is_dir():
        raise FileNotFoundError(f"CSV directory not found: {csv_dir}")

    counts = {}
    with conn.cursor() as cur:
        cur.execute(
            "TRUNCATE raw_patients, raw_encounters, raw_conditions, raw_procedures, "
            "raw_payers, raw_providers, raw_organizations RESTART IDENTITY"
        )
        for table, filename in LOAD_ORDER:
            path = csv_dir / filename
            if not path.exists():
                raise FileNotFoundError(
                    f"{filename} missing from {csv_dir}. "
                    "Run `python run.py --generate-only` first, or point --csv-dir "
                    "at a Synthea output/csv folder."
                )
            with path.open("r", encoding="utf-8", newline="") as fh:
                # COPY with a header row matches columns by position, so the
                # generator's header order must match the staging DDL exactly.
                cur.copy_expert(
                    f"COPY {table} FROM STDIN WITH (FORMAT CSV, HEADER true, NULL '')",
                    fh,
                )
            cur.execute(f"SELECT COUNT(*) FROM {table}")
            counts[table] = cur.fetchone()[0]
    conn.commit()
    return counts

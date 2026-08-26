#!/usr/bin/env python
"""
Build the whole readmission warehouse in one command.

    python run.py

Steps, in order:
    1. generate    synthetic Synthea-format CSVs (or use --csv-dir for real ones)
    2. create      the database if it does not exist
    3. stage       load the CSVs into raw_* tables
    4. build       dimensions and facts (02_etl_readmission.sql)
    5. scd2        apply an incremental patient extract to exercise Type 2
    6. views       create the reporting layer
    7. validate    run every integrity and business-logic check
    8. export      write dashboard extracts to data/exports/

Configure the connection in .env (copy .env.example). Nothing else is required —
no Synthea download, no Docker, no manual createdb.

Useful flags:
    --patients N     how many synthetic patients (default 3000 -> ~12k encounters)
    --seed N         change the seed to get a different but reproducible dataset
    --csv-dir PATH   use real Synthea output instead of the generator
    --generate-only  write the CSVs and stop
    --skip-generate  reuse whatever is already in data/csv/
    --validate-only  re-run the checks against an already-built warehouse
"""

from __future__ import annotations

import argparse
import sys
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "src"))

from hrrp import db, export, generate, load, validate  # noqa: E402

REPO = Path(__file__).parent
CSV_DIR = REPO / "data" / "csv"
EXPORT_DIR = REPO / "data" / "exports"


def banner(step: str, text: str):
    print(f"\n\033[1m[{step}]\033[0m {text}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--patients", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--csv-dir", type=Path, default=None,
                    help="use an existing Synthea output/csv directory")
    ap.add_argument("--generate-only", action="store_true")
    ap.add_argument("--skip-generate", action="store_true")
    ap.add_argument("--validate-only", action="store_true")
    args = ap.parse_args()

    started = time.time()

    if args.validate_only:
        with db.connect() as conn:
            _, failed = validate.run(conn)
        return 1 if failed else 0

    csv_dir = args.csv_dir or CSV_DIR

    # --- 1. generate -------------------------------------------------------
    if not args.csv_dir and not args.skip_generate:
        banner("1/8", f"Generating {args.patients:,} synthetic patients (seed {args.seed})")
        counts = generate.generate(csv_dir, args.patients, args.seed)
        for name, n in counts.items():
            print(f"       {name:<16} {n:>8,}")
        moved = generate.generate_updates(csv_dir, seed=args.seed + 1)
        print(f"       {'patients_updates':<16} {moved:>8,} patients moved")
    else:
        banner("1/8", f"Using CSVs from {csv_dir}")

    if args.generate_only:
        print(f"\nDone in {time.time() - started:.1f}s. CSVs in {csv_dir}")
        return 0

    # --- 2. database -------------------------------------------------------
    banner("2/8", "Ensuring database exists")
    cfg = db.settings()
    created = db.ensure_database()
    print(f"       {cfg['dbname']} @ {cfg['host']}:{cfg['port']} "
          f"({'created' if created else 'already present'})")

    with db.connect() as conn:
        # --- 3. stage ------------------------------------------------------
        banner("3/8", "Creating staging tables and loading CSVs")
        db.run_sql_file(conn, "01_create_staging.sql")
        for table, n in load.load_csvs(conn, csv_dir).items():
            print(f"       {table:<20} {n:>8,}")

        # --- 4. warehouse --------------------------------------------------
        banner("4/8", "Building dimensions and facts")
        db.run_sql_file(conn, "02_etl_readmission.sql")
        for table in ("DimPatient", "DimDiagnosis", "FactEncounter", "FactReadmission"):
            print(f"       {table:<20} {db.scalar(conn, f'SELECT COUNT(*) FROM {table}'):>8,}")

        # --- 5. SCD Type 2 -------------------------------------------------
        banner("5/8", "Applying incremental patient extract (SCD Type 2)")
        db.run_sql_file(conn, "03_scd2_apply_changes.sql")
        updates_csv = Path(csv_dir) / "patients_updates.csv"
        if updates_csv.exists():
            with conn.cursor() as cur, updates_csv.open(encoding="utf-8", newline="") as fh:
                cur.copy_expert(
                    "COPY raw_patients_updates FROM STDIN "
                    "WITH (FORMAT CSV, HEADER true, NULL '')", fh)
                cur.execute("SELECT * FROM scd2_apply_patient_changes(%s)",
                            (date.today(),))
                expired, inserted = cur.fetchone()
            conn.commit()
            versioned = db.scalar(conn, """
                SELECT COUNT(*) FROM (SELECT patient_id FROM DimPatient
                GROUP BY patient_id HAVING COUNT(*) > 1) v""")
            print(f"       expired {expired:,} rows, inserted {inserted:,} successors")
            print(f"       {versioned:,} patients now have version history")
        else:
            print("       no patients_updates.csv — skipping (Type 1 load only)")

        # --- 6. views ------------------------------------------------------
        banner("6/8", "Creating reporting views")
        db.run_sql_file(conn, "04_analytics_views.sql")
        print(f"       {len(export.VIEWS)} views created")

        # --- 7. validate ---------------------------------------------------
        banner("7/8", "Validating")
        _, failed = validate.run(conn)

        # --- 8. export -----------------------------------------------------
        banner("8/8", "Exporting dashboard extracts")
        for view, n in export.export_views(conn, EXPORT_DIR).items():
            print(f"       {view:<30} {n:>8,}")
        print(f"       -> {EXPORT_DIR}")

    elapsed = time.time() - started
    if failed:
        print(f"\n\033[31mFAILED\033[0m — {failed} validation check(s) failed "
              f"after {elapsed:.1f}s")
        return 1
    print(f"\n\033[32mOK\033[0m — warehouse built and validated in {elapsed:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())

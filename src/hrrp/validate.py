"""
Validation suite for the readmission warehouse.

Two kinds of check:

  VIOLATION  — a SQL query that returns rows only when something is wrong.
               Zero rows means the check passed. This is how the structural and
               business-logic rules are expressed.

  RANGE      — a scalar that has to land inside an expected band. Used where the
               right answer is "plausible" rather than "exact" — readmission
               rates, for instance, are whatever the data says, but a cohort rate
               of 0% or 90% means the pipeline is broken.

Every check names what it is protecting, because a failing check should tell you
what broke, not just that something did.

Run standalone:   python -m hrrp.validate
Exit code is 1 if any check fails, so this is CI-usable.
"""

from __future__ import annotations

import sys

from . import db

# --- VIOLATION checks: these queries must return zero rows -------------------

VIOLATION_CHECKS = [
    # ---- staging referential integrity ----
    ("staging: every encounter belongs to a known patient",
     """SELECT e."Id" FROM raw_encounters e
        LEFT JOIN raw_patients p ON p."Id" = e."PATIENT"
        WHERE p."Id" IS NULL"""),

    ("staging: every condition belongs to a known encounter",
     """SELECT c."ENCOUNTER" FROM raw_conditions c
        LEFT JOIN raw_encounters e ON e."Id" = c."ENCOUNTER"
        WHERE c."ENCOUNTER" <> '' AND e."Id" IS NULL"""),

    # ---- dimension grain and SCD Type 2 invariants ----
    ("DimPatient: exactly one current row per patient",
     """SELECT patient_id FROM DimPatient WHERE is_current
        GROUP BY patient_id HAVING COUNT(*) <> 1"""),

    ("DimPatient: SCD2 date ranges never overlap for a patient",
     """SELECT a.patient_id FROM DimPatient a
        JOIN DimPatient b
          ON a.patient_id = b.patient_id
         AND a.patient_key < b.patient_key
         AND a.effective_start_date
             < COALESCE(b.effective_end_date, DATE '9999-12-31')
         AND b.effective_start_date
             < COALESCE(a.effective_end_date, DATE '9999-12-31')"""),

    ("DimPatient: expired rows have an end date, current rows do not",
     """SELECT patient_key FROM DimPatient
        WHERE (is_current AND effective_end_date IS NOT NULL)
           OR (NOT is_current AND effective_end_date IS NULL)"""),

    ("DimDiagnosis: diagnosis_code is unique",
     """SELECT diagnosis_code FROM DimDiagnosis
        GROUP BY diagnosis_code HAVING COUNT(*) > 1"""),

    ("DimDate: no gaps in the calendar",
     """SELECT full_date FROM (
          SELECT full_date,
                 LEAD(full_date) OVER (ORDER BY full_date) AS nxt
          FROM DimDate
        ) g WHERE nxt IS NOT NULL AND nxt <> full_date + 1"""),

    # ---- fact grain ----
    ("FactEncounter: grain is one row per encounter",
     """SELECT encounter_id FROM FactEncounter
        GROUP BY encounter_id HAVING COUNT(*) > 1"""),

    ("FactReadmission: grain is one row per index admission",
     """SELECT index_encounter_key FROM FactReadmission
        GROUP BY index_encounter_key HAVING COUNT(*) > 1"""),

    # ---- referential integrity into the dimensions ----
    ("FactEncounter: no orphan patient keys",
     """SELECT f.encounter_key FROM FactEncounter f
        LEFT JOIN DimPatient d ON d.patient_key = f.patient_key
        WHERE d.patient_key IS NULL"""),

    ("FactEncounter: admit date resolves in DimDate",
     """SELECT f.encounter_key FROM FactEncounter f
        LEFT JOIN DimDate d ON d.date_key = f.admit_date_key
        WHERE d.date_key IS NULL"""),

    ("FactReadmission: only inpatient encounters are index admissions",
     """SELECT r.readmission_key FROM FactReadmission r
        JOIN FactEncounter e ON e.encounter_key = r.index_encounter_key
        WHERE e.encounter_class <> 'inpatient'"""),

    # ---- temporal sanity ----
    ("FactEncounter: discharge is never before admission",
     """SELECT encounter_key FROM FactEncounter
        WHERE discharge_datetime IS NOT NULL
          AND discharge_datetime < admit_datetime"""),

    ("FactEncounter: length of stay is never negative",
     "SELECT encounter_key FROM FactEncounter WHERE length_of_stay_days < 0"),

    # ---- the business rule the whole project rests on ----
    ("30-day window: is_30day_readmission implies a prior gap of 0-30 days",
     """SELECT readmission_key FROM FactReadmission
        WHERE is_30day_readmission
          AND (days_since_prior_discharge IS NULL
               OR days_since_prior_discharge < 0
               OR days_since_prior_discharge > 30)"""),

    ("30-day window: has_30day_readmit_after implies a forward gap of 0-30 days",
     """SELECT readmission_key FROM FactReadmission
        WHERE has_30day_readmit_after
          AND (days_to_next_admission IS NULL
               OR days_to_next_admission < 0
               OR days_to_next_admission > 30)"""),

    ("30-day window: a gap of 0-30 days is never left unflagged",
     """SELECT readmission_key FROM FactReadmission
        WHERE days_to_next_admission BETWEEN 0 AND 30
          AND NOT has_30day_readmit_after"""),

    ("30-day window: no readmission flag without a prior encounter",
     """SELECT readmission_key FROM FactReadmission
        WHERE is_30day_readmission AND prior_encounter_key IS NULL"""),

    # Replaces "HRRP cohort is always populated", which could never fail:
    # hrrp_condition is NOT NULL and the ETL COALESCEs to 'OTHER', so the query
    # had no way to return a row. Meanwhile the range check on cohort share
    # passed at 55.7% while half of COPD was being dropped into OTHER - a range
    # check cannot see a classifier that fails on some wordings of a condition.
    ("HRRP classification: no admission naming a target condition falls through to OTHER",
     """SELECT r.readmission_key FROM FactReadmission r
        JOIN FactEncounter e ON e.encounter_key = r.index_encounter_key
        JOIN DimDiagnosis dd ON dd.diagnosis_key = e.principal_diagnosis_key
        WHERE r.hrrp_condition = 'OTHER'
          AND (dd.description ILIKE '%obstructive%'
            OR dd.description ILIKE '%emphysema%'
            OR dd.description ILIKE '%chronic%bronchitis%'
            OR dd.description ILIKE '%heart failure%'
            OR dd.description ILIKE '%cardiac failure%'
            OR dd.description ILIKE '%myocardial infarction%'
            OR dd.description ILIKE '%pneumonia%')"""),
]


# --- RANGE checks: (label, sql returning one number, low, high, note) --------

RANGE_CHECKS = [
    ("FactEncounter row count", "SELECT COUNT(*) FROM FactEncounter",
     1000, 10_000_000, "warehouse is populated"),
    ("FactReadmission row count", "SELECT COUNT(*) FROM FactReadmission",
     100, 10_000_000, "inpatient admissions were classified"),
    ("Overall 30-day readmission rate %",
     """SELECT ROUND(100.0 * SUM(CASE WHEN has_30day_readmit_after THEN 1 ELSE 0 END)
                     / NULLIF(COUNT(*), 0), 2) FROM FactReadmission""",
     2.0, 40.0, "a rate outside this band means the window logic is wrong"),
    ("Share of admissions in a named HRRP cohort %",
     """SELECT ROUND(100.0 * SUM(CASE WHEN hrrp_condition <> 'OTHER' THEN 1 ELSE 0 END)
                     / NULLIF(COUNT(*), 0), 2) FROM FactReadmission""",
     20.0, 95.0, "cohort classification is actually matching diagnoses"),
]


def _reconciliation(conn):
    """Cross-foot the facts against staging.

    The readmission fact should contain exactly the inpatient encounters that
    have a discharge — no more, no fewer. This is the check that catches a join
    silently dropping or duplicating rows, which is the failure mode that does
    the most damage and shows up the least.
    """
    inpatient = db.scalar(conn, """
        SELECT COUNT(*) FROM FactEncounter
        WHERE encounter_class = 'inpatient' AND discharge_datetime IS NOT NULL""")
    readmit = db.scalar(conn, "SELECT COUNT(*) FROM FactReadmission")
    cohort_sum = db.scalar(conn, """
        SELECT COALESCE(SUM(n), 0) FROM (
          SELECT COUNT(*) AS n FROM FactReadmission GROUP BY hrrp_condition) s""")

    return [
        ("reconciliation: FactReadmission covers every discharged inpatient stay",
         inpatient == readmit, f"inpatient={inpatient:,}  factreadmission={readmit:,}"),
        ("reconciliation: cohort subtotals sum to the fact total",
         cohort_sum == readmit, f"cohorts={cohort_sum:,}  total={readmit:,}"),
    ]


def cohort_rates(conn):
    return db.query(conn, """
        SELECT hrrp_condition,
               COUNT(*) AS index_admissions,
               SUM(CASE WHEN has_30day_readmit_after THEN 1 ELSE 0 END) AS readmits,
               ROUND(100.0 * SUM(CASE WHEN has_30day_readmit_after THEN 1 ELSE 0 END)
                     / NULLIF(COUNT(*), 0), 2) AS rate_pct
        FROM FactReadmission
        GROUP BY hrrp_condition
        ORDER BY rate_pct DESC NULLS LAST""")


def run(conn, verbose: bool = True) -> tuple[int, int]:
    passed = failed = 0

    def report(label, ok, detail=""):
        nonlocal passed, failed
        if ok:
            passed += 1
            if verbose:
                print(f"  PASS  {label}")
        else:
            failed += 1
            print(f"  FAIL  {label}" + (f"   [{detail}]" if detail else ""))

    if verbose:
        print("\nStructural and business-logic checks")
    for label, sql in VIOLATION_CHECKS:
        rows = db.scalar(conn, f"SELECT COUNT(*) FROM ({sql}) v")
        report(label, rows == 0, f"{rows:,} violating rows")

    if verbose:
        print("\nReconciliation")
    for label, ok, detail in _reconciliation(conn):
        report(label, ok, detail)

    if verbose:
        print("\nRange checks")
    for label, sql, low, high, note in RANGE_CHECKS:
        value = db.scalar(conn, sql)
        ok = value is not None and low <= float(value) <= high
        report(f"{label} = {value}  (expect {low}-{high}: {note})", ok)

    if verbose:
        print("\n30-day readmission rate by HRRP cohort")
        cols, rows = cohort_rates(conn)
        print(f"    {'cohort':<12} {'admissions':>11} {'readmits':>9} {'rate':>7}")
        for cohort, n, re, rate in rows:
            print(f"    {cohort:<12} {n:>11,} {re:>9,} {str(rate) + '%':>7}")

    print(f"\n{passed} passed, {failed} failed")
    return passed, failed


def main():
    with db.connect() as conn:
        _, failed = run(conn)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

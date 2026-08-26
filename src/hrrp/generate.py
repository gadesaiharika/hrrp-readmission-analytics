"""
Synthetic encounter generator — emits Synthea's exact CSV contract.

Why this exists
---------------
The original pipeline required a Synthea run: install Java, clone the generator,
produce a few GB of CSVs, wait. That is a real barrier for anyone who wants to
look at this project, and it meant the repository could not be run as cloned.

This module writes the same seven CSV files with the same headers Synthea emits,
so `01_create_staging.sql` and `02_etl_readmission.sql` run **unchanged** against
either source. The pipeline does not know or care which one produced the files.

Everything is seeded, so the same seed always yields byte-identical CSVs and the
dashboard numbers in the README stay reproducible.

Clinical realism
----------------
Readmission propensity is set per HRRP cohort at roughly the published CMS
national range, so the resulting dashboard shows a plausible shape (heart failure
worst, joint replacement best) rather than uniform noise. The *observed* rate is
whatever the pipeline measures — this only sets the underlying propensity.

This is synthetic data. It contains no PHI and is not derived from any real
patient record.
"""

from __future__ import annotations

import csv
import random
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

# --- reference data ---------------------------------------------------------

# SNOMED-CT codes and descriptions as Synthea emits them. The ETL classifies
# HRRP cohorts by matching description text, so these strings must keep the
# keywords the SQL looks for ("myocardial infarction", "heart failure", etc.).
HRRP_DIAGNOSES = {
    "AMI":       [("22298006",  "Myocardial infarction"),
                  ("401303003", "Acute ST segment elevation myocardial infarction")],
    "HF":        [("84114007",  "Heart failure"),
                  ("88805009",  "Chronic congestive heart failure")],
    "PNEUMONIA": [("233604007", "Pneumonia"),
                  ("385093006", "Community acquired pneumonia")],
    "COPD":      [("87433001",  "Pulmonary emphysema"),
                  ("185086009", "Chronic obstructive bronchitis")],
    "CABG":      [("53741008",  "Coronary heart disease")],
    "THA_TKA":   [("239873007", "Osteoarthritis of knee"),
                  ("239872002", "Osteoarthritis of hip")],
}

# Procedures that define the two procedure-based cohorts.
HRRP_PROCEDURES = {
    "CABG":    [("232717009", "Coronary artery bypass grafting", 55000.0)],
    "THA_TKA": [("52734007",  "Total hip replacement",  32000.0),
                ("609588000", "Total knee replacement", 30000.0)],
}

# Non-HRRP principal diagnoses. Readmissions are frequently for a different
# cause than the index admission, so most readmits draw from this list.
OTHER_INPATIENT_DX = [
    ("91302008",  "Sepsis"),
    ("14669001",  "Acute renal failure syndrome"),
    ("34095006",  "Dehydration"),
    ("64572001",  "Gastrointestinal hemorrhage"),
    ("230690007", "Cerebrovascular accident"),
    ("36971009",  "Cellulitis"),
    ("68566005",  "Urinary tract infectious disease"),
    ("197927001", "Recurrent urinary tract infection"),
]

CHRONIC_DX = [
    ("44054006",  "Diabetes mellitus type 2"),
    ("59621000",  "Essential hypertension"),
    ("195967001", "Asthma"),
    ("15777000",  "Prediabetes"),
    ("162864005", "Body mass index 30+ - obesity"),
    ("55822004",  "Hyperlipidemia"),
    ("40055000",  "Chronic sinusitis"),
]

AMBULATORY_DX = [
    ("10509002",  "Acute bronchitis"),
    ("195662009", "Acute viral pharyngitis"),
    ("444814009", "Viral sinusitis"),
    ("241929008", "Acute allergic reaction"),
    ("283385000", "Laceration of thigh"),
]

# Roughly the published CMS national 30-day all-cause readmission bands.
# Heart failure highest, elective joint replacement lowest.
READMIT_PROPENSITY = {
    "HF":        0.24,
    "COPD":      0.22,
    "PNEUMONIA": 0.18,
    "AMI":       0.17,
    "CABG":      0.14,
    "THA_TKA":   0.06,
    "OTHER":     0.13,
}

# Typical length of stay per cohort, in days (mean, spread).
LOS_PROFILE = {
    "AMI": (5, 2), "HF": (5, 2), "PNEUMONIA": (5, 2),
    "COPD": (4, 2), "CABG": (9, 3), "THA_TKA": (3, 1), "OTHER": (4, 2),
}

# Encounter descriptions feed the ETL's service-line mapping, which keys off
# words like "cardio", "pulmonary", "joint", and "surgical".
INPATIENT_DESCRIPTION = {
    "AMI":       "Inpatient admission for cardiovascular condition",
    "HF":        "Inpatient admission for heart failure management",
    "PNEUMONIA": "Inpatient admission for respiratory infection",
    "COPD":      "Inpatient admission for chronic pulmonary disease",
    "CABG":      "Inpatient cardiac surgical admission",
    "THA_TKA":   "Inpatient orthopedic joint replacement admission",
    "OTHER":     "Inpatient hospital admission",
}

PAYERS = [
    ("Medicare",                 "GOVERNMENT"), ("Medicaid", "GOVERNMENT"),
    ("Blue Cross Blue Shield",   "PRIVATE"),    ("UnitedHealthcare", "PRIVATE"),
    ("Aetna",                    "PRIVATE"),    ("Cigna", "PRIVATE"),
    ("Humana",                   "PRIVATE"),    ("NO_INSURANCE", "NO_INSURANCE"),
]

FACILITIES = [
    ("Magnolia Regional Medical Center", "Starkville",  "MS", "39759"),
    ("Delta Valley Hospital",            "Jackson",     "MS", "39201"),
    ("Pine Belt Medical Center",         "Hattiesburg", "MS", "39401"),
    ("Gulf Coast General Hospital",      "Gulfport",    "MS", "39501"),
]

SPECIALTIES = ["CARDIOLOGY", "INTERNAL MEDICINE", "PULMONOLOGY",
               "ORTHOPEDIC SURGERY", "FAMILY PRACTICE", "GENERAL SURGERY",
               "HOSPITALIST", "NEPHROLOGY"]

CITIES = [("Starkville", "39759", "Oktibbeha"), ("Jackson", "39201", "Hinds"),
          ("Hattiesburg", "39401", "Forrest"),  ("Tupelo", "38801", "Lee"),
          ("Gulfport", "39501", "Harrison"),    ("Columbus", "39701", "Lowndes"),
          ("Meridian", "39301", "Lauderdale"),  ("Oxford", "38655", "Lafayette")]

RACES = ["white", "black", "asian", "native", "other"]
RACE_W = [0.55, 0.36, 0.04, 0.02, 0.03]
FIRST_M = ["James", "Robert", "Michael", "David", "William", "Joseph", "Thomas",
           "Charles", "Anthony", "Marcus", "Andre", "Terrell"]
FIRST_F = ["Mary", "Patricia", "Jennifer", "Linda", "Barbara", "Susan", "Jessica",
           "Sarah", "Karen", "Latoya", "Denise", "Yolanda"]
LAST = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Davis", "Miller",
        "Wilson", "Moore", "Taylor", "Thomas", "Jackson", "White", "Harris",
        "Boudreaux", "Nguyen", "Patel", "Ramirez"]

START_DATE = date(2023, 1, 1)
END_DATE = date(2025, 11, 30)   # leaves a 30-day forward window inside the data

CSV_HEADERS = {
    "patients": ["Id", "BIRTHDATE", "DEATHDATE", "SSN", "DRIVERS", "PASSPORT",
                 "PREFIX", "FIRST", "LAST", "SUFFIX", "MAIDEN", "MARITAL", "RACE",
                 "ETHNICITY", "GENDER", "BIRTHPLACE", "ADDRESS", "CITY", "STATE",
                 "COUNTY", "FIPS", "ZIP", "LAT", "LON", "HEALTHCARE_EXPENSES",
                 "HEALTHCARE_COVERAGE", "INCOME"],
    "encounters": ["Id", "START", "STOP", "PATIENT", "ORGANIZATION", "PROVIDER",
                   "PAYER", "ENCOUNTERCLASS", "CODE", "DESCRIPTION",
                   "BASE_ENCOUNTER_COST", "TOTAL_CLAIM_COST", "PAYER_COVERAGE",
                   "REASONCODE", "REASONDESCRIPTION"],
    "conditions": ["START", "STOP", "PATIENT", "ENCOUNTER", "SYSTEM", "CODE",
                   "DESCRIPTION"],
    "procedures": ["START", "STOP", "PATIENT", "ENCOUNTER", "SYSTEM", "CODE",
                   "DESCRIPTION", "BASE_COST", "REASONCODE", "REASONDESCRIPTION"],
    "payers": ["Id", "NAME", "OWNERSHIP", "ADDRESS", "CITY", "STATE_HEADQUARTERED",
               "ZIP", "PHONE", "AMOUNT_COVERED", "AMOUNT_UNCOVERED", "REVENUE",
               "COVERED_ENCOUNTERS", "UNCOVERED_ENCOUNTERS", "COVERED_MEDICATIONS",
               "UNCOVERED_MEDICATIONS", "COVERED_PROCEDURES", "UNCOVERED_PROCEDURES",
               "COVERED_IMMUNIZATIONS", "UNCOVERED_IMMUNIZATIONS", "UNIQUE_CUSTOMERS",
               "QOLS_AVG", "MEMBER_MONTHS"],
    "providers": ["Id", "ORGANIZATION", "NAME", "GENDER", "SPECIALITY", "ADDRESS",
                  "CITY", "STATE", "ZIP", "LAT", "LON", "ENCOUNTERS", "PROCEDURES"],
    "organizations": ["Id", "NAME", "ADDRESS", "CITY", "STATE", "ZIP", "LAT", "LON",
                      "PHONE", "REVENUE", "UTILIZATION"],
}


def _ts(d: date, hour: int, minute: int = 0) -> str:
    """Synthea writes ISO-8601 with a Z suffix."""
    return datetime(d.year, d.month, d.day, hour, minute).strftime("%Y-%m-%dT%H:%M:%SZ")


class Generator:
    def __init__(self, n_patients: int = 3000, seed: int = 42):
        self.n_patients = n_patients
        self.rng = random.Random(seed)
        self.rows = {k: [] for k in CSV_HEADERS}

    # --- reference tables ---------------------------------------------------

    def _build_reference(self):
        rng = self.rng
        self.orgs = []
        for name, city, state, zipc in FACILITIES:
            oid = str(uuid.UUID(int=rng.getrandbits(128)))
            self.orgs.append(oid)
            self.rows["organizations"].append([
                oid, name, f"{rng.randint(100, 9999)} Hospital Dr", city, state, zipc,
                round(rng.uniform(30.3, 34.9), 6), round(rng.uniform(-91.5, -88.2), 6),
                f"601-555-{rng.randint(1000, 9999)}", 0, 0,
            ])

        self.providers = []
        for i in range(40):
            pid = str(uuid.UUID(int=rng.getrandbits(128)))
            org = rng.choice(self.orgs)
            gender = rng.choice(["M", "F"])
            first = rng.choice(FIRST_M if gender == "M" else FIRST_F)
            self.providers.append(pid)
            self.rows["providers"].append([
                pid, org, f"{first} {rng.choice(LAST)}", gender,
                rng.choice(SPECIALTIES), f"{rng.randint(100, 9999)} Clinic Way",
                rng.choice(CITIES)[0], "MS", rng.choice(CITIES)[1],
                round(rng.uniform(30.3, 34.9), 6), round(rng.uniform(-91.5, -88.2), 6),
                0, 0,
            ])

        self.payers = []
        for name, ownership in PAYERS:
            pid = str(uuid.UUID(int=rng.getrandbits(128)))
            self.payers.append((pid, name))
            self.rows["payers"].append([
                pid, name, ownership, f"{rng.randint(100, 9999)} Insurance Blvd",
                rng.choice(CITIES)[0], "MS", rng.choice(CITIES)[1],
                f"800-555-{rng.randint(1000, 9999)}",
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ])

    def _pick_payer(self, age: int) -> str:
        """Medicare dominates over 65 — this is what makes the payer-mix view meaningful."""
        rng = self.rng
        if age >= 65:
            return rng.choices(self.payers, weights=[62, 6, 9, 8, 6, 4, 4, 1])[0][0]
        return rng.choices(self.payers, weights=[3, 18, 20, 17, 14, 11, 9, 8])[0][0]

    # --- per-encounter writers ---------------------------------------------

    def _encounter(self, pid, org, prov, payer, klass, start: date, stop: date,
                   code, description, cost, hours=(9, 14)):
        eid = str(uuid.UUID(int=self.rng.getrandbits(128)))
        covered = round(cost * self.rng.uniform(0.55, 0.92), 2)
        self.rows["encounters"].append([
            eid, _ts(start, hours[0]), _ts(stop, hours[1]), pid, org, prov, payer,
            klass, code, description, round(cost * 0.12, 2), round(cost, 2),
            covered, "", "",
        ])
        return eid

    def _condition(self, pid, eid, start: date, stop, code, desc):
        self.rows["conditions"].append([
            start.isoformat(), stop.isoformat() if stop else "",
            pid, eid, "http://snomed.info/sct", code, desc,
        ])

    def _procedure(self, pid, eid, start: date, code, desc, cost):
        self.rows["procedures"].append([
            _ts(start, 10), _ts(start, 13), pid, eid,
            "http://snomed.info/sct", code, desc, round(cost, 2), "", "",
        ])

    def _admission(self, pid, org, prov, payer, cohort, admit: date):
        """One inpatient stay: encounter + principal diagnosis + any procedure."""
        rng = self.rng
        mean, spread = LOS_PROFILE[cohort]
        los = max(1, int(rng.gauss(mean, spread)))
        discharge = admit + timedelta(days=los)

        base = {"CABG": 78000, "THA_TKA": 45000}.get(cohort, 14000)
        cost = base * rng.uniform(0.7, 1.5)

        eid = self._encounter(pid, org, prov, payer, "inpatient", admit, discharge,
                              "32485007", INPATIENT_DESCRIPTION[cohort], cost,
                              hours=(rng.randint(6, 20), rng.randint(9, 16)))

        if cohort == "OTHER":
            code, desc = rng.choice(OTHER_INPATIENT_DX)
        else:
            code, desc = rng.choice(HRRP_DIAGNOSES[cohort])
        self._condition(pid, eid, admit, discharge, code, desc)

        if cohort in HRRP_PROCEDURES:
            pcode, pdesc, pcost = rng.choice(HRRP_PROCEDURES[cohort])
            self._procedure(pid, eid, admit, pcode, pdesc, pcost)

        return eid, discharge

    # --- patient histories --------------------------------------------------

    def _patient(self):
        rng = self.rng
        pid = str(uuid.UUID(int=rng.getrandbits(128)))
        gender = rng.choice(["M", "F"])
        # Skew older: HRRP cohorts are overwhelmingly a Medicare population.
        age = int(min(95, max(19, rng.gauss(64, 17))))
        birth = date(END_DATE.year - age, rng.randint(1, 12), rng.randint(1, 28))
        city, zipc, county = rng.choice(CITIES)
        first = rng.choice(FIRST_M if gender == "M" else FIRST_F)

        self.rows["patients"].append([
            pid, birth.isoformat(), "",
            f"999-{rng.randint(10, 99)}-{rng.randint(1000, 9999)}", "", "",
            "Mr." if gender == "M" else "Ms.", first, rng.choice(LAST), "", "",
            rng.choice(["M", "S"]), rng.choices(RACES, weights=RACE_W)[0],
            rng.choices(["hispanic", "nonhispanic"], weights=[12, 88])[0], gender,
            f"{city}, Mississippi, US", f"{rng.randint(100, 9999)} Main St", city,
            "MS", county, f"28{rng.randint(100, 199)}", zipc,
            round(rng.uniform(30.3, 34.9), 6), round(rng.uniform(-91.5, -88.2), 6),
            round(rng.uniform(5000, 400000), 2), round(rng.uniform(2000, 300000), 2),
            round(rng.uniform(15000, 130000), 2),
        ])

        org = rng.choice(self.orgs)
        prov = rng.choice(self.providers)
        payer = self._pick_payer(age)
        span = (END_DATE - START_DATE).days

        # Ambulatory and wellness history — the bulk of encounter volume.
        for _ in range(rng.randint(1, 4)):
            d = START_DATE + timedelta(days=rng.randint(0, span))
            code, desc = rng.choice(AMBULATORY_DX + CHRONIC_DX)
            eid = self._encounter(pid, org, prov, payer,
                                  rng.choice(["wellness", "ambulatory", "outpatient"]),
                                  d, d, "162673000", "General examination of patient",
                                  rng.uniform(120, 900))
            self._condition(pid, eid, d, d + timedelta(days=rng.randint(20, 400)),
                            code, desc)

        # Emergency visits.
        for _ in range(rng.randint(0, 2)):
            d = START_DATE + timedelta(days=rng.randint(0, span))
            self._encounter(pid, org, prov, payer, "emergency", d, d,
                            "50849002", "Emergency room admission",
                            rng.uniform(900, 4200))

        # Inpatient admissions — likelihood rises steeply with age.
        p_admit = 0.10 + max(0.0, (age - 45)) * 0.011
        if rng.random() > min(p_admit, 0.72):
            return

        for _ in range(rng.choices([1, 2], weights=[80, 20])[0]):
            cohort = rng.choices(
                ["HF", "COPD", "PNEUMONIA", "AMI", "CABG", "THA_TKA", "OTHER"],
                weights=[17, 13, 15, 11, 5, 10, 29])[0]
            admit = START_DATE + timedelta(days=rng.randint(0, span - 60))
            _, discharge = self._admission(pid, org, prov, payer, cohort, admit)

            # The readmission itself. Most readmits present with a different
            # principal diagnosis than the index stay, which is why the cohort
            # denominators stay clean.
            if rng.random() < READMIT_PROPENSITY[cohort]:
                gap = rng.choices(range(1, 31),
                                  weights=[max(1, 31 - d) for d in range(1, 31)])[0]
                re_cohort = cohort if rng.random() < 0.35 else "OTHER"
                self._admission(pid, org, prov, payer, re_cohort,
                                discharge + timedelta(days=gap))
            elif rng.random() < 0.12:
                # A later, non-qualifying admission. Without these the LAG/LEAD
                # windows would only ever see readmissions, which would make the
                # 30-day logic untestable.
                self._admission(pid, org, prov, payer, "OTHER",
                                discharge + timedelta(days=rng.randint(31, 200)))

    # --- entry point --------------------------------------------------------

    def generate(self, out_dir: Path) -> dict:
        self._build_reference()
        for _ in range(self.n_patients):
            self._patient()

        out_dir.mkdir(parents=True, exist_ok=True)
        counts = {}
        for name, header in CSV_HEADERS.items():
            path = out_dir / f"{name}.csv"
            with path.open("w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh)
                w.writerow(header)
                w.writerows(self.rows[name])
            counts[name] = len(self.rows[name])
        return counts


def generate(out_dir, n_patients: int = 3000, seed: int = 42) -> dict:
    return Generator(n_patients, seed).generate(Path(out_dir))


def generate_updates(out_dir, move_rate: float = 0.08, seed: int = 43) -> int:
    """Write patients_updates.csv — the next extract, in which some patients moved.

    This is what exercises the SCD Type 2 merge. Without a second extract that
    actually differs, Type 2 columns are decoration; with one, you can show the
    version history and prove the ranges never overlap.

    A patient who moves gets a new city, state stays MS, and a matching ZIP, so
    the tracked-attribute comparison in 03_scd2_apply_changes.sql fires.
    """
    out_dir = Path(out_dir)
    rng = random.Random(seed)
    src = out_dir / "patients.csv"

    with src.open("r", encoding="utf-8", newline="") as fh:
        rows = list(csv.DictReader(fh))

    header = CSV_HEADERS["patients"]
    moved = 0
    out_rows = []
    for row in rows:
        if rng.random() < move_rate:
            city, zipc, county = rng.choice(
                [c for c in CITIES if c[0] != row["CITY"]])
            row = dict(row, CITY=city, ZIP=zipc, COUNTY=county,
                       ADDRESS=f"{rng.randint(100, 9999)} Oak St")
            moved += 1
        out_rows.append([row[h] for h in header])

    with (out_dir / "patients_updates.csv").open("w", newline="",
                                                 encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(out_rows)
    return moved

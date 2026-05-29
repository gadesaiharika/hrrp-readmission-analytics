# 30-Day Readmission Analytics & HRRP Risk Dashboard

End-to-end healthcare data analytics project: an ETL pipeline and Tableau dashboard that surface 30-day all-cause readmission patterns and estimated CMS HRRP penalty exposure across the six HRRP target conditions, built on Synthea synthetic patient data and a Caboodle-style dimensional model in PostgreSQL.

> **Status:** Portfolio project · Synthetic data only · No real PHI
> **Live dashboard:** https://public.tableau.com/app/profile/sai.harika.gade/viz/HRRPReadmissionAnalytics-30DayRiskDashboard/HRRPExecutiveDashboard
> **Author:** Sai Harika Gade · [LinkedIn](https://linkedin.com/in/saiharikagade) · gadesaiharika@gmail.com

---

## Table of Contents

1. [Business Problem](#business-problem)
2. [Tech Stack](#tech-stack)
3. [Repository Structure](#repository-structure)
4. [Data Source](#data-source)
5. [Data Architecture](#data-architecture)
6. [Setup Instructions](#setup-instructions)
7. [Key Calculations](#key-calculations)
8. [Dashboard](#dashboard)
9. [Findings & Insights](#findings--insights)
10. [Engineering Arc — Lessons Learned](#engineering-arc--lessons-learned)
11. [Limitations](#limitations)
12. [References](#references)

---

## Business Problem

Under the Centers for Medicare & Medicaid Services (CMS) **Hospital Readmissions Reduction Program (HRRP)**, U.S. hospitals are financially penalized — up to **3% of their base Medicare DRG payments** — when their 30-day all-cause readmission rates for six target conditions exceed risk-adjusted national benchmarks.

The six HRRP-monitored cohorts:

| Cohort | Description | Identification basis |
|---|---|---|
| **AMI** | Acute Myocardial Infarction | Principal diagnosis |
| **HF** | Heart Failure | Principal diagnosis |
| **PNEUMONIA** | Pneumonia | Principal diagnosis |
| **COPD** | Chronic Obstructive Pulmonary Disease | Principal diagnosis |
| **CABG** | Coronary Artery Bypass Graft | Procedure |
| **THA / TKA** | Total Hip / Knee Arthroplasty | Procedure |

Hospital Quality and Cogito teams need timely visibility into where readmissions are concentrating — by condition, by service line, by payer, and by provider — so case-management interventions can be targeted before the next CMS payment-year calculation locks in penalties. This dashboard provides that visibility, plus a configurable dollarized estimate of penalty exposure for executive communication.

---

## Tech Stack

| Layer | Tool |
|---|---|
| Synthetic data generation | [Synthea](https://synthea.mitre.org) (Java) |
| Storage / warehouse | PostgreSQL 17 |
| ETL | SQL (CTEs + window functions) |
| Modeling | Kimball-style star schema (Caboodle-style naming) |
| BI / visualization | Tableau Public |
| Documentation | Markdown |
| Version control | Git / GitHub |

---

## Repository Structure

```
.
├── README.md                       ← you are here
├── data_dictionary.md              ← table-by-table column reference
├── tableau_calculations.md         ← Tableau calculated fields and parameters
│
├── /sql
│   ├── 01_create_staging.sql       ← raw_* staging table DDL
│   ├── 02_load_synthea.sh          ← COPY commands to load Synthea CSVs
│   └── etl_readmission.sql         ← MAIN ETL pipeline (dims + facts + validation)
│
└── /tableau
    └── /screenshots                ← PNG exports of the dashboard
```

The Tableau workbook itself is published to Tableau Public (link above) rather than committed here, so recruiters can interact with the live dashboard directly.

---

## Data Source

Patient data is generated synthetically using [Synthea](https://synthea.mitre.org), an open-source synthetic patient simulator from MITRE. Synthea produces clinically realistic but **completely synthetic** patient histories — no real PHI, no HIPAA concerns, freely shareable.

This project uses a Synthea cohort of **12,000 patients** generated for Massachusetts. After date-filtering FactEncounter to the 2020–2025 reporting window, the warehouse contains **3,431 inpatient admissions** classified into HRRP cohorts plus an OTHER catch-all bucket.

---

## Data Architecture

### Star schema (Caboodle-style naming)

```
                              ┌────────────────────────┐
                              │     DimPatient         │  ◄── SCD Type 2 ready
                              │ patient_key (PK)       │      (effective_start/end,
                              │ patient_id (natural)   │       is_current)
                              │ demographics + SCD cols│
                              └───────────┬────────────┘
                                          │
   ┌─────────────────┐                    │              ┌────────────────────┐
   │   DimDate       │                    │              │   DimDiagnosis     │
   │ date_key (PK)   │                    │              │ diagnosis_key (PK) │
   │ calendar attrs  │                    │              │ SNOMED code        │
   └────────┬────────┘                    │              │ icd10_chapter      │
            │                             │              │ hrrp_condition     │
            │                             │              └──────────┬─────────┘
            │                             │                         │
            │     ┌───────────────────────▼───────────────────────┐ │
            └─────┤             FactEncounter                     │◄┘
                  │  encounter_key (PK)                           │
                  │  patient_key, payer_key, provider_key,        │
                  │  facility_key, principal_diagnosis_key (FKs)  │
                  │  admit_datetime, discharge_datetime           │
                  │  encounter_class, service_line, los, charges  │
                  └───────────────────────┬───────────────────────┘
                                          │
                            ┌─────────────▼──────────────┐
                            │     FactReadmission        │  ◄── grain = one inpatient
                            │ readmission_key (PK)       │      admission
                            │ index_encounter_key (FK)   │
                            │ hrrp_condition             │
                            │ LAG-derived columns        │  ── prior_encounter_key
                            │ LEAD-derived columns       │  ── next_encounter_key
                            │ is_30day_readmission       │
                            │ has_30day_readmit_after    │  ── HRRP numerator flag
                            └────────────────────────────┘

   Side dimensions: DimProvider · DimPayer · DimFacility
```

### Core ETL logic

`FactReadmission` is built by an `INSERT … SELECT` against a chain of five CTEs in `sql/etl_readmission.sql`:

1. **`inpatient_base`** — filter FactEncounter to inpatient encounters with valid discharges
2. **`encounter_procedures`** — aggregate procedure-based HRRP labels (CABG, THA/TKA) per encounter
3. **`encounter_classified`** — `COALESCE` resolves final HRRP label: diagnosis first, then procedure, then OTHER
4. **`windowed`** — `LAG()` and `LEAD()` over `(PARTITION BY patient_key ORDER BY admit_datetime)`
5. **`flagged`** — derive `is_30day_readmission` (backward-looking) and `has_30day_readmit_after` (forward-looking HRRP numerator flag)

### Why both LAG and LEAD?

- `LAG` answers *"Was this admission itself a readmission of a recent discharge?"* — populates `is_30day_readmission`.
- `LEAD` answers *"Was this admission followed by another within 30 days?"* — populates `has_30day_readmit_after`. This is the column SUM'd in the numerator of the HRRP rate calculation.

---

## Setup Instructions

```bash
# 1. Generate Synthea data
git clone https://github.com/synthetichealth/synthea.git
cd synthea
./run_synthea -p 12000 Massachusetts

# 2. Create the database
createdb readmission_db

# 3. Create staging tables and load Synthea CSVs
psql -d readmission_db -f sql/01_create_staging.sql
bash sql/02_load_synthea.sh ./synthea/output/csv

# 4. Build warehouse + facts
psql -d readmission_db -f sql/etl_readmission.sql

# 5. Export for Tableau
psql -d readmission_db -c \
  "\copy (SELECT * FROM vw_readmission_analytics) TO 'readmission_analytics.csv' WITH CSV HEADER;"
```

---

## Key Calculations

See `tableau_calculations.md` for the full reference. Highlights:

- **Readmission Rate** = `SUM(Readmitted) / SUM(Index Admission Count)`
- **Excess Readmissions** = `SUM(Readmitted) − (National Benchmark Rate × SUM(Index Admission Count))`
- **CMS HRRP Penalty Exposure** = `MAX(Excess Readmissions × Avg Medicare Payment × Penalty Factor, 0)`

The penalty exposure number is a deliberately simplified executive estimate — not the precise CMS formula, which applies a multiplicative reduction factor capped at 3% to all base operating DRG payments.

---

## Dashboard

The Tableau dashboard contains:

1. **Executive KPI tiles** — Total HRRP Index Admissions · Overall Readmission Rate · Estimated Penalty Exposure
2. **Readmission Rate Trends** — Line chart with monthly trend by HRRP cohort + national benchmark reference line
3. **Payer Mix of Readmissions** — Stacked bar showing payer breakdown for each cohort
4. **Service Line × HRRP Condition Heatmap** — Color-graded matrix with derived service line classification

Three parameters let executives model scenarios: National Benchmark Rate, Average Medicare Payment per Case, HRRP Penalty Factor.

**Live dashboard URL:** https://public.tableau.com/app/profile/sai.harika.gade/viz/HRRPReadmissionAnalytics-30DayRiskDashboard/HRRPExecutiveDashboard

---

## Findings & Insights

Across **3,431 inpatient admissions** in the 2020–2025 window, **251 (7.3%) resulted in 30-day readmissions**.

| HRRP cohort | Admissions | Readmissions | Rate |
|---|---|---|---|
| OTHER | 3,000 | 250 | 8.33% |
| PNEUMONIA | 190 | 1 | 0.53% |
| AMI | 138 | 0 | 0.00% |
| CABG | 93 | 0 | 0.00% |
| HF | 10 | 0 | 0.00% |

Key observations:

1. **The OTHER bucket carries nearly all of the readmission activity** — 250 of 251 30-day readmissions occurred in patients whose principal diagnosis did not map to any of the six HRRP cohorts. This is a Synthea data characteristic, not a methodology issue. Real Clarity / Caboodle implementations on production data would show a more balanced cohort distribution.
2. **The single HRRP-cohort readmission was a pneumonia case in April 2021** — surfaced clearly in the trend chart at ~12.5% for that month. This is exactly the kind of event a hospital Quality team would want flagged for case-management review.
3. **AMI, CABG, and HF cohorts had zero readmissions** — too few admissions in the synthetic cohort to produce signal. COPD and THA/TKA produced no admissions at all in the 2020–2025 window.

---

## Engineering Arc — Lessons Learned

This project went through three substantive diagnostic-and-refactor cycles. Each one reflects real data engineering work that arises on production Caboodle / Clarity pipelines.

### 1. Tableau extract staleness vs. database state

The initial dashboard showed **only 1 readmission** across the entire HRRP cohort, while the underlying PostgreSQL database held 251. Diagnosed by running parallel SQL queries directly against the database, then confirming the discrepancy was caused by Tableau reading a stale CSV exported before the ETL refactor. Resolved by removing and re-adding the data source connection in Tableau Public, forcing a fresh read.

**Lesson:** Always verify the data source layer before debugging the visualization layer. A two-minute diagnostic SQL query against the database can save hours of dashboard troubleshooting.

### 2. Principal diagnosis selection logic

After fixing the Tableau refresh, a follow-up diagnostic revealed that **92% of inpatient encounters were being assigned non-HRRP principal diagnoses** despite the patients having HRRP-classifiable conditions in their records. The cause: the original `principal_dx` CTE selected the earliest condition by start date as principal, which meant chronic-condition records (often recorded years before any individual admission) were incorrectly chosen as principal for acute hospitalizations.

Refactored the CTE in Section 7 of the ETL to prefer HRRP-classified diagnoses when present:

```sql
ORDER BY
  rc."ENCOUNTER",
  CASE WHEN dd.hrrp_condition IS NOT NULL THEN 0 ELSE 1 END,  -- HRRP dx wins
  rc."START",
  rc."CODE"
```

This mirrors how real hospital coders identify the principal diagnosis as the condition responsible for the admission, not whichever condition happened to be entered first in the patient's record.

**Lesson:** In dimensional modeling, the *selection logic* between fact and dimension is often more important than the dimension's content itself. The same DimDiagnosis table produces wildly different fact-level outcomes depending on how the principal is chosen.

### 3. Synthea SNOMED vocabulary coverage

Synthea uses many SNOMED descriptions per condition. The initial HRRP classification used a small set of ILIKE patterns that caught the canonical phrasings ("Heart failure", "Pneumonia") but missed Synthea-specific variants like "Chronic congestive heart failure (disorder)" and "Pulmonary emphysema". A diagnostic query against `raw_conditions` revealed the actual phrase frequencies, and ILIKE patterns were iteratively expanded in Section 6 of the ETL.

**Lesson:** When classifying clinical text, always run a frequency-counted diagnostic against the source vocabulary before writing matching rules. The rules you write should reflect the data's actual phrasing, not your assumptions about it.

---

## Limitations

- **Synthea's disease-progression models underrepresent 30-day readmissions.** Real Medicare HRRP cohorts run ~15% readmission rates; the synthetic cohort here yields ~0.5% for HRRP-specific conditions. Production analytics on real Clarity data would not have this limitation.
- **Simplified HRRP penalty formula.** The dashboard's penalty exposure tile is an illustrative executive estimate, not the precise CMS calculation, which applies a multiplicative reduction factor capped at 3% to base operating DRG payments.
- **No risk adjustment.** Production HRRP reporting risk-adjusts for case mix; this dashboard does not.
- **Rule-based principal diagnosis selection.** Real hospital implementations use billing-coded principal diagnosis flags assigned by professional coders. This project uses a rule-based proxy because Synthea does not emit principal diagnosis flags.
- **SCD Type 2 on DimPatient is implemented but not exercised.** The initial Synthea load creates only the current version of each patient.

---

## References

- [CMS HRRP Overview](https://www.cms.gov/medicare/payment/prospective-payment-systems/acute-inpatient-pps/hospital-readmissions-reduction-program-hrrp)
- [Synthea documentation](https://github.com/synthetichealth/synthea/wiki)
- Kimball, R. & Ross, M., *The Data Warehouse Toolkit*, 3rd ed.

---

## License

Code: MIT. Synthetic data: per Synthea license. No PHI is contained in this repository.

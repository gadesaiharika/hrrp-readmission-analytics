# Data Dictionary — 30-Day Readmission Analytics

This document defines every table and column in the warehouse, including grain, source mapping, and business rules. Match the naming convention of Epic's Caboodle data warehouse (Dim* / Fact*) so the schema feels familiar to anyone who has worked on Cogito.

## Table of Contents

1. [Conventions](#conventions)
2. [Staging tables](#staging-tables-raw_)
3. [Dimension tables](#dimension-tables)
   - [DimDate](#dimdate)
   - [DimPatient](#dimpatient)
   - [DimProvider](#dimprovider)
   - [DimPayer](#dimpayer)
   - [DimFacility](#dimfacility)
   - [DimDiagnosis](#dimdiagnosis)
4. [Fact tables](#fact-tables)
   - [FactEncounter](#factencounter)
   - [FactReadmission](#factreadmission)
5. [Analytical views](#analytical-views)

---

## Conventions

| Element | Convention |
|---|---|
| Surrogate key | `BIGSERIAL`, named `<table>_key` (e.g. `patient_key`) |
| Natural key | Native ID from the source system (e.g. `patient_id`, `encounter_id`) |
| Dates | Calendar dates stored as `INT` (YYYYMMDD) referencing `DimDate`; full timestamps stored separately |
| Booleans | `BOOLEAN`, true/false |
| Money | `NUMERIC(12,2)` in USD |
| HRRP cohort labels | One of: `AMI`, `HF`, `PNEUMONIA`, `COPD`, `CABG`, `THA_TKA`, `OTHER` |

---

## Staging tables (`raw_*`)

These are 1:1 loads of Synthea CSVs. Column names and types preserve Synthea's structure (note the quoted, mixed-case identifiers used by `COPY FROM`). Documenting them is not strictly necessary, but listing them helps reviewers trace lineage. See Synthea's [CSV file dictionary](https://github.com/synthetichealth/synthea/wiki/CSV-File-Data-Dictionary) for full column definitions.

| Staging table | Source CSV | Key columns used downstream |
|---|---|---|
| `raw_patients` | `patients.csv` | `"Id"`, `"BIRTHDATE"`, `"GENDER"`, `"RACE"`, `"ETHNICITY"`, `"CITY"`, `"STATE"`, `"ZIP"` |
| `raw_encounters` | `encounters.csv` | `"Id"`, `"START"`, `"STOP"`, `"PATIENT"`, `"PROVIDER"`, `"PAYER"`, `"ORGANIZATION"`, `"ENCOUNTERCLASS"`, `"DESCRIPTION"`, `"TOTAL_CLAIM_COST"` |
| `raw_conditions` | `conditions.csv` | `"ENCOUNTER"`, `"CODE"`, `"DESCRIPTION"`, `"START"` |
| `raw_procedures` | `procedures.csv` | `"ENCOUNTER"`, `"CODE"`, `"DESCRIPTION"` |
| `raw_payers` | `payers.csv` | `"Id"`, `"NAME"` |
| `raw_providers` | `providers.csv` | `"Id"`, `"NAME"`, `"SPECIALITY"`, `"ORGANIZATION"` |
| `raw_organizations` | `organizations.csv` | `"Id"`, `"NAME"`, `"CITY"`, `"STATE"` |

---

## Dimension tables

### `DimDate`
**Grain:** one row per calendar date, 2018–2030.

| Column | Type | Description |
|---|---|---|
| `date_key` | INT (PK) | Calendar date as YYYYMMDD integer (e.g. 20260615). Foreign key from all fact tables. |
| `full_date` | DATE | The actual date. |
| `year` | INT | Four-digit year. |
| `quarter` | INT | Calendar quarter, 1–4. |
| `month` | INT | Month number, 1–12. |
| `month_name` | VARCHAR(20) | Month name, e.g. "March". |
| `day` | INT | Day of month, 1–31. |
| `day_of_week` | INT | 0 = Sunday … 6 = Saturday. |
| `day_name` | VARCHAR(20) | Day name, e.g. "Tuesday". |

---

### `DimPatient`
**Grain:** one row per patient version (SCD Type 2). The current version has `is_current = TRUE` and `effective_end_date IS NULL`.

| Column | Type | Description | Source |
|---|---|---|---|
| `patient_key` | BIGSERIAL (PK) | Surrogate key. | — |
| `patient_id` | VARCHAR(50) | Natural key from Synthea. | `raw_patients."Id"` |
| `birth_date` | DATE | Date of birth. | `raw_patients."BIRTHDATE"` |
| `gender` | CHAR(1) | M / F. | `raw_patients."GENDER"` |
| `race` | VARCHAR(50) | Race category. | `raw_patients."RACE"` |
| `ethnicity` | VARCHAR(50) | Hispanic / Non-Hispanic. | `raw_patients."ETHNICITY"` |
| `city` | VARCHAR(100) | City of residence at this version. | `raw_patients."CITY"` |
| `state` | VARCHAR(50) | State. | `raw_patients."STATE"` |
| `zip_code` | VARCHAR(10) | ZIP code. | `raw_patients."ZIP"` |
| `effective_start_date` | DATE | Date this version became current. | Birth date for initial load. |
| `effective_end_date` | DATE | Date this version was superseded; NULL if current. | NULL for initial load. |
| `is_current` | BOOLEAN | TRUE for the active version only. | TRUE for initial load. |

**SCD Type 2 update rule:** when an attribute changes for a patient, expire the current row (`effective_end_date = today, is_current = FALSE`) and insert a new row.

---

### `DimProvider`
**Grain:** one row per clinician.

| Column | Type | Description | Source |
|---|---|---|---|
| `provider_key` | BIGSERIAL (PK) | Surrogate key. | — |
| `provider_id` | VARCHAR(50) | Natural key. | `raw_providers."Id"` |
| `provider_name` | VARCHAR(200) | Display name. | `raw_providers."NAME"` |
| `specialty` | VARCHAR(100) | Clinical specialty. | `raw_providers."SPECIALITY"` |
| `organization_id` | VARCHAR(50) | Org affiliation. | `raw_providers."ORGANIZATION"` |

---

### `DimPayer`
**Grain:** one row per insurance payer.

| Column | Type | Description | Source |
|---|---|---|---|
| `payer_key` | BIGSERIAL (PK) | Surrogate key. | — |
| `payer_id` | VARCHAR(50) | Natural key. | `raw_payers."Id"` |
| `payer_name` | VARCHAR(200) | Payer name. | `raw_payers."NAME"` |
| `payer_type` | VARCHAR(50) | One of Medicare / Medicaid / Commercial / Self-Pay. | Derived from `payer_name` keywords. |

---

### `DimFacility`
**Grain:** one row per facility (hospital, clinic, etc.).

| Column | Type | Description | Source |
|---|---|---|---|
| `facility_key` | BIGSERIAL (PK) | Surrogate key. | — |
| `facility_id` | VARCHAR(50) | Natural key. | `raw_organizations."Id"` |
| `facility_name` | VARCHAR(200) | Facility name. | `raw_organizations."NAME"` |
| `city` | VARCHAR(100) | City. | `raw_organizations."CITY"` |
| `state` | VARCHAR(50) | State. | `raw_organizations."STATE"` |

---

### `DimDiagnosis`
**Grain:** one row per distinct diagnosis code seen in `raw_conditions`.

| Column | Type | Description | Notes |
|---|---|---|---|
| `diagnosis_key` | BIGSERIAL (PK) | Surrogate key. | — |
| `diagnosis_code` | VARCHAR(20) | SNOMED code from Synthea. | Indexed. |
| `code_system` | VARCHAR(20) | Default `'SNOMED'`. | Future-proof for ICD-10 additions. |
| `description` | VARCHAR(500) | Human-readable description. | From Synthea. |
| `icd10_chapter` | VARCHAR(100) | Rollup category for charting. | Set by keyword matching during ETL. |
| `hrrp_condition` | VARCHAR(20) | One of `AMI` / `HF` / `PNEUMONIA` / `COPD`, or NULL. | Set by keyword matching; CABG / THA_TKA are procedure-based, set on FactReadmission instead. |

---

## Fact tables

### `FactEncounter`
**Grain:** one row per encounter.

| Column | Type | Description | Notes |
|---|---|---|---|
| `encounter_key` | BIGSERIAL (PK) | Surrogate key. | — |
| `encounter_id` | VARCHAR(50) | Natural key. | From `raw_encounters."Id"`. |
| `patient_key` | BIGINT (FK) | Patient at the time of encounter. | Joins DimPatient. |
| `provider_key` | BIGINT (FK) | Attending provider. | Nullable. |
| `payer_key` | BIGINT (FK) | Primary payer for the encounter. | Nullable. |
| `facility_key` | BIGINT (FK) | Facility where the encounter occurred. | Nullable. |
| `admit_date_key` | INT (FK) | Admission date. | → DimDate. |
| `discharge_date_key` | INT (FK) | Discharge date. | Nullable for open encounters. |
| `admit_datetime` | TIMESTAMP | Full admission timestamp. | Used by window functions. |
| `discharge_datetime` | TIMESTAMP | Full discharge timestamp. | Nullable. |
| `encounter_class` | VARCHAR(50) | inpatient / outpatient / emergency / ambulatory / wellness / urgentcare. | From Synthea. |
| `principal_diagnosis_key` | BIGINT (FK) | Principal diagnosis. | First condition starting on encounter date. |
| `length_of_stay_days` | NUMERIC(6,2) | discharge − admit in days. | Computed. |
| `total_charges` | NUMERIC(12,2) | Total claim cost. | From Synthea. |
| `service_line` | VARCHAR(100) | Cardiology / Pulmonology / Orthopedics / Surgery / Emergency / General Medicine. | Derived from encounter description and class. |

---

### `FactReadmission` *(core analytical fact)*
**Grain:** one row per **inpatient** admission (called the "index" admission), with both backward-looking and forward-looking readmission flags.

> **Why this grain?** It makes HRRP rate computation a clean SUM/COUNT against this single table. Denominator = COUNT(\*) WHERE `hrrp_condition` IN (six). Numerator = SUM(`has_30day_readmit_after`) over the same filter.

| Column | Type | Description | Notes |
|---|---|---|---|
| `readmission_key` | BIGSERIAL (PK) | Surrogate key. | — |
| `index_encounter_key` | BIGINT (FK) | The index inpatient admission this row represents. | → FactEncounter. |
| `patient_key` | BIGINT (FK) | Patient. | → DimPatient. |
| `index_admit_date_key` | INT (FK) | Date the index admission began. | → DimDate. |
| `index_discharge_date_key` | INT (FK) | Date the index admission ended. | → DimDate. Nullable. |
| `hrrp_condition` | VARCHAR(20) | Resolved HRRP cohort: AMI / HF / PNEUMONIA / COPD / CABG / THA_TKA / OTHER. | Diagnosis-based first, then procedure-based. |
| `index_payer_key` | BIGINT (FK) | Payer at the index admission. | → DimPayer. |
| `index_provider_key` | BIGINT (FK) | Attending at the index admission. | → DimProvider. |
| `index_facility_key` | BIGINT (FK) | Facility at the index admission. | → DimFacility. |
| `index_service_line` | VARCHAR(100) | Service line of the index admission. | Carried from FactEncounter. |
| `index_los_days` | NUMERIC(6,2) | Length of stay for the index admission. | — |
| `prior_encounter_key` | BIGINT (FK) | The previous inpatient encounter, via `LAG()`. | NULL if first stay. |
| `days_since_prior_discharge` | INT | Days between prior discharge and this admission. | NULL if no prior stay. |
| `is_30day_readmission` | BOOLEAN | TRUE if `days_since_prior_discharge` ∈ [0, 30]. | "Was THIS itself a readmission?" |
| `next_encounter_key` | BIGINT (FK) | The next inpatient encounter, via `LEAD()`. | NULL if last stay. |
| `days_to_next_admission` | INT | Days between this discharge and next admission. | NULL if no next stay. |
| `has_30day_readmit_after` | BOOLEAN | TRUE if `days_to_next_admission` ∈ [0, 30]. | **HRRP numerator flag.** |

### Window-function lineage (the columns that matter most)

| Output column | Window expression |
|---|---|
| `prior_encounter_key` | `LAG(encounter_key) OVER (PARTITION BY patient_key ORDER BY admit_datetime)` |
| `next_encounter_key`  | `LEAD(encounter_key) OVER (PARTITION BY patient_key ORDER BY admit_datetime)` |
| `days_since_prior_discharge` | derived from `LAG(discharge_datetime) OVER w` |
| `days_to_next_admission`     | derived from `LEAD(admit_datetime)    OVER w` |

---

## Analytical views

### `vw_readmission_analytics`
Denormalized join of `FactReadmission` with all relevant dimension attributes. Used as the data source for the Tableau extract. One row per inpatient admission.

| Column | Type | Source table |
|---|---|---|
| All `FactReadmission` columns | various | FactReadmission |
| `gender`, `race`, `ethnicity` | VARCHAR | DimPatient |
| `index_admit_date`, `admit_year`, `admit_quarter`, `admit_month` | DATE / INT | DimDate |
| `index_discharge_date` | DATE | DimDate |
| `payer_name`, `payer_type` | VARCHAR | DimPayer |
| `provider_name`, `specialty` | VARCHAR | DimProvider |
| `facility_name`, `facility_city`, `facility_state` | VARCHAR | DimFacility |

Export command:

```sql
\copy (SELECT * FROM vw_readmission_analytics) TO 'readmission_analytics.csv' WITH CSV HEADER;
```

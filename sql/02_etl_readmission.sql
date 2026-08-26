-- =====================================================================
-- 30-Day Readmission Analytics & HRRP Risk Dashboard
-- ETL Pipeline: Synthea raw CSVs → Caboodle-style star schema
--
-- Author: Sai Harika Gade
-- Database: PostgreSQL 14+
-- Source: Synthea synthetic patient generator (https://synthea.mitre.org)
--
-- Pipeline stages:
--   1. Load Synthea CSVs into raw_* staging tables (done outside this script)
--   2. Build dimension tables (DimPatient, DimDate, DimProvider, DimPayer,
--      DimFacility, DimDiagnosis)
--   3. Build FactEncounter (one row per encounter)
--   4. Build FactReadmission (one row per inpatient admission, with flags
--      for whether it was preceded or followed by a 30-day readmission)
--
-- HRRP cohorts implemented:
--   - AMI       (Acute Myocardial Infarction)        — diagnosis-based
--   - HF        (Heart Failure)                      — diagnosis-based
--   - PNEUMONIA (Pneumonia)                          — diagnosis-based
--   - COPD      (Chronic Obstructive Pulmonary Dz)   — diagnosis-based
--   - CABG      (Coronary Artery Bypass Graft)       — procedure-based
--   - THA_TKA   (Total Hip / Knee Arthroplasty)      — procedure-based
-- =====================================================================


-- =====================================================================
-- ASSUMED STAGING TABLES (created and loaded via COPY ... FROM CSV)
-- =====================================================================
-- raw_patients      ← patients.csv
-- raw_encounters    ← encounters.csv
-- raw_conditions    ← conditions.csv
-- raw_procedures    ← procedures.csv
-- raw_providers     ← providers.csv
-- raw_payers        ← payers.csv
-- raw_organizations ← organizations.csv
-- =====================================================================


-- =====================================================================
-- SECTION 1 — Dimension tables (DDL)
-- =====================================================================

DROP TABLE IF EXISTS FactReadmission, FactEncounter,
  DimPatient, DimDate, DimProvider, DimPayer, DimFacility, DimDiagnosis CASCADE;

CREATE TABLE DimDate (
  date_key      INT PRIMARY KEY,        -- YYYYMMDD as integer
  full_date     DATE NOT NULL,
  year          INT NOT NULL,
  quarter       INT NOT NULL,
  month         INT NOT NULL,
  month_name    VARCHAR(20) NOT NULL,
  day           INT NOT NULL,
  day_of_week   INT NOT NULL,
  day_name      VARCHAR(20) NOT NULL
);

CREATE TABLE DimPatient (
  patient_key            BIGSERIAL PRIMARY KEY,
  patient_id             VARCHAR(50) NOT NULL,   -- natural key from Synthea
  birth_date             DATE,
  gender                 CHAR(1),
  race                   VARCHAR(50),
  ethnicity              VARCHAR(50),
  city                   VARCHAR(100),
  state                  VARCHAR(50),
  zip_code               VARCHAR(10),
  effective_start_date   DATE NOT NULL,         -- SCD Type 2
  effective_end_date     DATE,
  is_current             BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX ix_dimpatient_natural ON DimPatient(patient_id, is_current);

CREATE TABLE DimProvider (
  provider_key   BIGSERIAL PRIMARY KEY,
  provider_id    VARCHAR(50) NOT NULL,
  provider_name  VARCHAR(200),
  specialty      VARCHAR(100),
  organization_id VARCHAR(50)
);

CREATE TABLE DimPayer (
  payer_key   BIGSERIAL PRIMARY KEY,
  payer_id    VARCHAR(50) NOT NULL,
  payer_name  VARCHAR(200),
  payer_type  VARCHAR(50)              -- Medicare / Medicaid / Commercial / Self-Pay
);

CREATE TABLE DimFacility (
  facility_key   BIGSERIAL PRIMARY KEY,
  facility_id    VARCHAR(50) NOT NULL,
  facility_name  VARCHAR(200),
  city           VARCHAR(100),
  state          VARCHAR(50)
);

CREATE TABLE DimDiagnosis (
  diagnosis_key    BIGSERIAL PRIMARY KEY,
  diagnosis_code   VARCHAR(20) NOT NULL,   -- SNOMED from Synthea
  code_system      VARCHAR(20) NOT NULL DEFAULT 'SNOMED',
  description      VARCHAR(500),
  icd10_chapter    VARCHAR(100),           -- roll-up for analytics
  hrrp_condition   VARCHAR(20)             -- AMI / HF / PNEUMONIA / COPD / NULL
);
CREATE INDEX ix_dimdx_code ON DimDiagnosis(diagnosis_code);


-- =====================================================================
-- SECTION 2 — Fact tables (DDL)
-- =====================================================================

CREATE TABLE FactEncounter (
  encounter_key            BIGSERIAL PRIMARY KEY,
  encounter_id             VARCHAR(50) NOT NULL,        -- natural key
  patient_key              BIGINT NOT NULL REFERENCES DimPatient(patient_key),
  provider_key             BIGINT REFERENCES DimProvider(provider_key),
  payer_key                BIGINT REFERENCES DimPayer(payer_key),
  facility_key             BIGINT REFERENCES DimFacility(facility_key),
  admit_date_key           INT NOT NULL REFERENCES DimDate(date_key),
  discharge_date_key       INT REFERENCES DimDate(date_key),
  admit_datetime           TIMESTAMP NOT NULL,
  discharge_datetime       TIMESTAMP,
  encounter_class          VARCHAR(50) NOT NULL,        -- inpatient / outpatient / etc.
  principal_diagnosis_key  BIGINT REFERENCES DimDiagnosis(diagnosis_key),
  length_of_stay_days      NUMERIC(6,2),
  total_charges            NUMERIC(12,2),
  service_line             VARCHAR(100)
);
CREATE INDEX ix_factenc_patient   ON FactEncounter(patient_key, admit_datetime);
CREATE INDEX ix_factenc_class     ON FactEncounter(encounter_class);

CREATE TABLE FactReadmission (
  readmission_key             BIGSERIAL PRIMARY KEY,
  index_encounter_key         BIGINT NOT NULL REFERENCES FactEncounter(encounter_key),
  patient_key                 BIGINT NOT NULL REFERENCES DimPatient(patient_key),
  index_admit_date_key        INT NOT NULL REFERENCES DimDate(date_key),
  index_discharge_date_key    INT REFERENCES DimDate(date_key),
  hrrp_condition              VARCHAR(20) NOT NULL,       -- AMI / HF / PNEUMONIA / COPD / CABG / THA_TKA / OTHER
  index_payer_key             BIGINT REFERENCES DimPayer(payer_key),
  index_provider_key          BIGINT REFERENCES DimProvider(provider_key),
  index_facility_key          BIGINT REFERENCES DimFacility(facility_key),
  index_service_line          VARCHAR(100),
  index_los_days              NUMERIC(6,2),
  -- Prior-discharge window (LAG)
  prior_encounter_key         BIGINT REFERENCES FactEncounter(encounter_key),
  days_since_prior_discharge  INT,
  is_30day_readmission        BOOLEAN NOT NULL DEFAULT FALSE,   -- THIS admission is a readmission of a prior discharge
  -- Forward-looking window (LEAD)
  next_encounter_key          BIGINT REFERENCES FactEncounter(encounter_key),
  days_to_next_admission      INT,
  has_30day_readmit_after     BOOLEAN NOT NULL DEFAULT FALSE    -- THIS admission was followed by a readmission
);
CREATE INDEX ix_factreadmit_hrrp ON FactReadmission(hrrp_condition);


-- =====================================================================
-- SECTION 3 — Populate DimDate (2018-2030)
-- =====================================================================

INSERT INTO DimDate (date_key, full_date, year, quarter, month, month_name,
                     day, day_of_week, day_name)
SELECT
  TO_CHAR(d, 'YYYYMMDD')::INT,
  d::DATE,
  EXTRACT(YEAR    FROM d)::INT,
  EXTRACT(QUARTER FROM d)::INT,
  EXTRACT(MONTH   FROM d)::INT,
  TO_CHAR(d, 'Month'),
  EXTRACT(DAY     FROM d)::INT,
  EXTRACT(DOW     FROM d)::INT,
  TO_CHAR(d, 'Day')
  FROM generate_series('2018-01-01'::date, '2030-12-31'::date, '1 day'::interval) AS d(d);


-- =====================================================================
-- SECTION 4 — Populate DimPatient (SCD Type 1 load; Type 2 logic below)
-- =====================================================================

INSERT INTO DimPatient (
  patient_id, birth_date, gender, race, ethnicity,
  city, state, zip_code, effective_start_date, effective_end_date, is_current
)
SELECT
  rp."Id",
  rp."BIRTHDATE"::DATE,
  rp."GENDER",
  rp."RACE",
  rp."ETHNICITY",
  rp."CITY",
  rp."STATE",
  rp."ZIP",
  rp."BIRTHDATE"::DATE,    -- assume current version effective since birth for first load
  NULL,
  TRUE
FROM raw_patients rp;

-- (When you later receive an updated patients file, run an UPSERT pattern:
--  expire the current row by setting effective_end_date and is_current=FALSE,
--  then INSERT a new current row. That gives you SCD Type 2.)


-- =====================================================================
-- SECTION 5 — Populate DimProvider, DimPayer, DimFacility
-- =====================================================================

INSERT INTO DimProvider (provider_id, provider_name, specialty, organization_id)
SELECT "Id", "NAME", "SPECIALITY", "ORGANIZATION"
FROM raw_providers;

INSERT INTO DimPayer (payer_id, payer_name, payer_type)
SELECT
  "Id",
  "NAME",
  CASE
    WHEN "NAME" ILIKE '%medicare%'   THEN 'Medicare'
    WHEN "NAME" ILIKE '%medicaid%'   THEN 'Medicaid'
    WHEN "NAME" ILIKE '%no_insurance%' OR "NAME" ILIKE '%self%' THEN 'Self-Pay'
    ELSE 'Commercial'
  END
FROM raw_payers;

INSERT INTO DimFacility (facility_id, facility_name, city, state)
SELECT "Id", "NAME", "CITY", "STATE"
FROM raw_organizations;


-- =====================================================================
-- SECTION 6 — Populate DimDiagnosis + assign HRRP condition flags
-- Synthea uses SNOMED-CT codes; we keep them as the natural code, classify
-- via description text (most defensible against Synthea version drift), and
-- assign a rough ICD-10 chapter for analytics rollups.
-- =====================================================================

INSERT INTO DimDiagnosis (diagnosis_code, code_system, description)
SELECT DISTINCT
  "CODE"::VARCHAR,
  'SNOMED',
  "DESCRIPTION"
FROM raw_conditions
WHERE "CODE" IS NOT NULL;


-- HRRP condition assignment (diagnosis-based)
UPDATE DimDiagnosis SET hrrp_condition = 'AMI'
WHERE description ILIKE '%myocardial infarction%'
   OR description ILIKE '%STEMI%'
   OR description ILIKE '%NSTEMI%';

UPDATE DimDiagnosis SET hrrp_condition = 'HF'
WHERE description ILIKE '%heart failure%'
   OR description ILIKE '%cardiac failure%';

UPDATE DimDiagnosis SET hrrp_condition = 'PNEUMONIA'
WHERE description ILIKE '%pneumonia%';

UPDATE DimDiagnosis SET hrrp_condition = 'COPD'
WHERE description ILIKE '%chronic obstructive pulmonary%'
   OR description ILIKE '%emphysema%'
   OR description ILIKE '%chronic bronchitis%';

UPDATE DimDiagnosis SET hrrp_condition = 'CABG'
WHERE description ILIKE '%coronary artery bypass%'
   OR description ILIKE '%CABG%';

UPDATE DimDiagnosis SET hrrp_condition = 'THA_TKA'
WHERE description ILIKE '%osteoarthritis of knee%'
   OR description ILIKE '%osteoarthritis of hip%';

-- ICD-10 chapter rollup (illustrative — extend as needed)
UPDATE DimDiagnosis SET icd10_chapter = 'Circulatory system'
WHERE hrrp_condition IN ('AMI','HF')
   OR description ILIKE '%hypertension%'
   OR description ILIKE '%stroke%'
   OR description ILIKE '%coronary%';

UPDATE DimDiagnosis SET icd10_chapter = 'Respiratory system'
WHERE hrrp_condition IN ('PNEUMONIA','COPD')
   OR description ILIKE '%asthma%'
   OR description ILIKE '%respiratory%';

UPDATE DimDiagnosis SET icd10_chapter = 'Endocrine/metabolic'
WHERE description ILIKE '%diabetes%' OR description ILIKE '%hypothyroid%';

UPDATE DimDiagnosis SET icd10_chapter = COALESCE(icd10_chapter, 'Other');


-- =====================================================================
-- SECTION 7 — Build FactEncounter
-- One row per encounter; principal diagnosis derived from the first
-- condition starting on the encounter date.
-- =====================================================================

INSERT INTO FactEncounter (
  encounter_id, patient_key, provider_key, payer_key, facility_key,
  admit_date_key, discharge_date_key, admit_datetime, discharge_datetime,
  encounter_class, principal_diagnosis_key, length_of_stay_days,
  total_charges, service_line
)
WITH principal_dx AS (
  -- Pick principal diagnosis per encounter:
  --   1. Prefer an HRRP-classified diagnosis if one exists for this encounter
  --      (mirrors how hospital coders identify the principal diagnosis as
  --      the condition responsible for the admission)
  --   2. Otherwise fall back to the earliest condition by start date
  --   3. Code value as final tiebreak
  SELECT DISTINCT ON (rc."ENCOUNTER")
    rc."ENCOUNTER"   AS encounter_id,
    dd.diagnosis_key
  FROM raw_conditions rc
  JOIN DimDiagnosis dd ON dd.diagnosis_code = rc."CODE"::VARCHAR
  ORDER BY
    rc."ENCOUNTER",
    CASE WHEN dd.hrrp_condition IS NOT NULL THEN 0 ELSE 1 END,
    rc."START",
    rc."CODE"
)

SELECT
  re."Id",
  dp.patient_key,
  dpr.provider_key,
  dpy.payer_key,
  df.facility_key,
  TO_CHAR(re."START"::DATE, 'YYYYMMDD')::INT,
  TO_CHAR(re."STOP"::DATE,  'YYYYMMDD')::INT,
  re."START"::TIMESTAMP,
  re."STOP"::TIMESTAMP,
  re."ENCOUNTERCLASS",
  pdx.diagnosis_key,
  ROUND( EXTRACT(EPOCH FROM (re."STOP"::TIMESTAMP - re."START"::TIMESTAMP)) / 86400.0, 2 ),
  re."TOTAL_CLAIM_COST"::NUMERIC,
  -- Service line: simple mapping from encounter description / class
  CASE
    WHEN re."DESCRIPTION" ILIKE '%cardio%' OR re."DESCRIPTION" ILIKE '%heart%' THEN 'Cardiology'
    WHEN re."DESCRIPTION" ILIKE '%respiratory%' OR re."DESCRIPTION" ILIKE '%pulmonary%' THEN 'Pulmonology'
    WHEN re."DESCRIPTION" ILIKE '%orthopedic%' OR re."DESCRIPTION" ILIKE '%joint%'      THEN 'Orthopedics'
    WHEN re."DESCRIPTION" ILIKE '%surgery%' OR re."DESCRIPTION" ILIKE '%surgical%'      THEN 'Surgery'
    WHEN re."ENCOUNTERCLASS" = 'emergency'                                              THEN 'Emergency'
    ELSE 'General Medicine'
  END
FROM raw_encounters re
JOIN DimPatient  dp  ON dp.patient_id = re."PATIENT" AND dp.is_current = TRUE
LEFT JOIN DimProvider dpr ON dpr.provider_id = re."PROVIDER"
LEFT JOIN DimPayer    dpy ON dpy.payer_id    = re."PAYER"
LEFT JOIN DimFacility df  ON df.facility_id  = re."ORGANIZATION"
LEFT JOIN principal_dx pdx ON pdx.encounter_id = re."Id"
WHERE re."START" >= '2020-01-01'
  AND re."START" <  '2026-01-01';


-- =====================================================================
-- SECTION 8 — Build FactReadmission
--
-- This is the core analytical transform. Logic:
--   1. Restrict to inpatient encounters with a valid discharge.
--   2. Resolve each encounter's HRRP condition:
--        - First check the principal diagnosis (DimDiagnosis.hrrp_condition)
--        - Then check procedures performed (CABG, THA/TKA)
--        - Otherwise label 'OTHER'
--   3. Use BOTH window functions over (PARTITION BY patient ORDER BY admit_datetime):
--        - LAG: prior discharge → days_since_prior_discharge → is_30day_readmission
--          (does THIS admission represent a readmission of a prior discharge?)
--        - LEAD: next admission → days_to_next_admission → has_30day_readmit_after
--          (was THIS admission followed by a readmission?  ← HRRP numerator flag)
--   4. Insert one row per inpatient admission.
--
-- HRRP rate, computed downstream:
--   rate = SUM(has_30day_readmit_after::INT) / COUNT(*)  WHERE hrrp_condition IN (...)
-- =====================================================================

INSERT INTO FactReadmission (
  index_encounter_key, patient_key,
  index_admit_date_key, index_discharge_date_key,
  hrrp_condition,
  index_payer_key, index_provider_key, index_facility_key,
  index_service_line, index_los_days,
  prior_encounter_key, days_since_prior_discharge, is_30day_readmission,
  next_encounter_key,  days_to_next_admission,    has_30day_readmit_after
)
WITH
-- CTE 1: Inpatient encounters with their diagnosis-based HRRP label
inpatient_base AS (
  SELECT
    fe.encounter_key,
    fe.patient_key,
    fe.admit_datetime,
    fe.discharge_datetime,
    fe.admit_date_key,
    fe.discharge_date_key,
    fe.payer_key,
    fe.provider_key,
    fe.facility_key,
    fe.service_line,
    fe.length_of_stay_days,
    dd.hrrp_condition AS dx_hrrp_condition
  FROM FactEncounter fe
  LEFT JOIN DimDiagnosis dd ON dd.diagnosis_key = fe.principal_diagnosis_key
  WHERE fe.encounter_class = 'inpatient'
    AND fe.discharge_datetime IS NOT NULL
),

-- CTE 2: Procedure-based HRRP labels (CABG, THA/TKA) per encounter
encounter_procedures AS (
  SELECT
    fe.encounter_key,
    MAX(CASE
      WHEN rp."DESCRIPTION" ILIKE '%coronary artery bypass%'
        OR rp."DESCRIPTION" ILIKE '%CABG%'
      THEN 'CABG'
    END) AS proc_cabg,
    MAX(CASE
      WHEN rp."DESCRIPTION" ILIKE '%total hip replacement%'
        OR rp."DESCRIPTION" ILIKE '%hip arthroplasty%'
        OR rp."DESCRIPTION" ILIKE '%total knee replacement%'
        OR rp."DESCRIPTION" ILIKE '%knee arthroplasty%'
      THEN 'THA_TKA'
    END) AS proc_tha_tka
  FROM FactEncounter fe
  JOIN raw_procedures rp ON rp."ENCOUNTER" = fe.encounter_id
  WHERE fe.encounter_class = 'inpatient'
  GROUP BY fe.encounter_key
),

-- CTE 3: Final HRRP classification per encounter
encounter_classified AS (
  SELECT
    ib.*,
    COALESCE(
      ib.dx_hrrp_condition,
      ep.proc_cabg,
      ep.proc_tha_tka,
      'OTHER'
    ) AS hrrp_condition
  FROM inpatient_base ib
  LEFT JOIN encounter_procedures ep ON ep.encounter_key = ib.encounter_key
),

-- CTE 4: Apply window functions to find prior discharge AND next admission
--        per patient. This is the heart of the readmission logic.
windowed AS (
  SELECT
    ec.*,
    -- LAG: prior inpatient discharge for THIS patient
    LAG(ec.encounter_key)      OVER w AS prior_encounter_key,
    LAG(ec.discharge_datetime) OVER w AS prior_discharge_datetime,
    -- LEAD: next inpatient admission for THIS patient
    LEAD(ec.encounter_key)     OVER w AS next_encounter_key,
    LEAD(ec.admit_datetime)    OVER w AS next_admit_datetime
  FROM encounter_classified ec
  WINDOW w AS (PARTITION BY ec.patient_key ORDER BY ec.admit_datetime)
),

-- CTE 5: Day deltas, computed ONCE.
--
-- These were previously derived twice: the reported day count used
-- ROUND(epoch/86400) while the flag compared the raw unrounded fraction to 30.
-- A gap of 30.4 days therefore reported as "30 days" while the flag read FALSE,
-- so filtering the dashboard on days_to_next_admission <= 30 returned a
-- different population than the headline readmission rate. Caught by
-- src/hrrp/validate.py ("a gap of 0-30 days is never left unflagged").
--
-- Now both the number and the flag come from the same column, so they cannot
-- disagree. Using date subtraction rather than timestamp arithmetic also makes
-- the window a calendar-day count, which is the CMS definition: a readmission
-- "within 30 days of discharge" means the 30th calendar day counts, regardless
-- of the hour of day either event happened to occur.
deltas AS (
  SELECT
    w.*,
    -- Whole calendar days from prior discharge to this admission.
    (w.admit_datetime::DATE - w.prior_discharge_datetime::DATE) AS days_since_prior_discharge,
    -- Whole calendar days from this discharge to the next admission.
    (w.next_admit_datetime::DATE - w.discharge_datetime::DATE)  AS days_to_next_admission
  FROM windowed w
),

-- CTE 6: Flags derived from those same deltas — single source of truth.
flagged AS (
  SELECT
    d.*,
    -- Is THIS admission a readmission of a prior discharge within 30 days?
    (d.days_since_prior_discharge IS NOT NULL
     AND d.days_since_prior_discharge BETWEEN 0 AND 30) AS is_30day_readmission,
    -- Was THIS admission followed by another inpatient admission within 30 days?
    -- This is the HRRP NUMERATOR flag for index admissions.
    (d.days_to_next_admission IS NOT NULL
     AND d.days_to_next_admission BETWEEN 0 AND 30)     AS has_30day_readmit_after
  FROM deltas d
)
SELECT
  encounter_key,                            -- index_encounter_key
  patient_key,
  admit_date_key,                           -- index_admit_date_key
  discharge_date_key,                       -- index_discharge_date_key
  hrrp_condition,
  payer_key,                                -- index_payer_key
  provider_key,                             -- index_provider_key
  facility_key,                             -- index_facility_key
  service_line,                             -- index_service_line
  length_of_stay_days,                      -- index_los_days
  prior_encounter_key,
  days_since_prior_discharge,
  is_30day_readmission,
  next_encounter_key,
  days_to_next_admission,
  has_30day_readmit_after
FROM flagged;


-- =====================================================================
-- SECTION 9 — Validation queries
-- Run these after the ETL to sanity-check the build before trusting it
-- in a dashboard.
-- =====================================================================

-- 9.1  Row counts
SELECT 'raw_encounters' AS t, COUNT(*) FROM raw_encounters UNION ALL
SELECT 'FactEncounter',    COUNT(*) FROM FactEncounter   UNION ALL
SELECT 'inpatient_only',   COUNT(*) FROM FactEncounter WHERE encounter_class='inpatient' UNION ALL
SELECT 'FactReadmission',  COUNT(*) FROM FactReadmission;

-- 9.2  HRRP cohort sizes (should be non-zero for at least AMI, HF, PNEUMONIA, COPD)
SELECT hrrp_condition,
       COUNT(*) AS index_admissions,
       SUM(CASE WHEN has_30day_readmit_after THEN 1 ELSE 0 END) AS readmissions_30d,
       ROUND(100.0 * SUM(CASE WHEN has_30day_readmit_after THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0), 2)
         AS readmission_rate_pct
FROM FactReadmission
GROUP BY hrrp_condition
ORDER BY index_admissions DESC;

-- 9.3  Spot-check the LAG / LEAD logic for one patient with multiple stays
SELECT patient_key, index_encounter_key,
       index_admit_date_key, index_discharge_date_key,
       prior_encounter_key, days_since_prior_discharge, is_30day_readmission,
       next_encounter_key,  days_to_next_admission,    has_30day_readmit_after
FROM FactReadmission
WHERE patient_key = (
  SELECT patient_key FROM FactReadmission
  GROUP BY patient_key
  HAVING COUNT(*) >= 3
  LIMIT 1
)
ORDER BY index_admit_date_key;

-- 9.4  Denormalized view for Tableau (export this as CSV for Tableau Public)
CREATE OR REPLACE VIEW vw_readmission_analytics AS
SELECT
  fr.readmission_key,
  fr.index_encounter_key,
  fr.hrrp_condition,
  fr.has_30day_readmit_after,
  fr.is_30day_readmission,
  fr.days_to_next_admission,
  fr.days_since_prior_discharge,
  fr.index_los_days,
  -- Patient
  dp.gender, dp.race, dp.ethnicity,
  -- Dates
  dd_adm.full_date  AS index_admit_date,
  dd_adm.year       AS admit_year,
  dd_adm.quarter    AS admit_quarter,
  dd_adm.month      AS admit_month,
  dd_dis.full_date  AS index_discharge_date,
  -- Payer
  dpy.payer_name, dpy.payer_type,
  -- Provider
  dpr.provider_name, dpr.specialty,
  -- Facility
  df.facility_name, df.city AS facility_city, df.state AS facility_state,
  -- Service line
  fr.index_service_line
FROM FactReadmission fr
LEFT JOIN DimPatient  dp     ON dp.patient_key = fr.patient_key
LEFT JOIN DimDate     dd_adm ON dd_adm.date_key = fr.index_admit_date_key
LEFT JOIN DimDate     dd_dis ON dd_dis.date_key = fr.index_discharge_date_key
LEFT JOIN DimPayer    dpy    ON dpy.payer_key   = fr.index_payer_key
LEFT JOIN DimProvider dpr    ON dpr.provider_key = fr.index_provider_key
LEFT JOIN DimFacility df     ON df.facility_key  = fr.index_facility_key;

-- Export for Tableau:
-- \copy (SELECT * FROM vw_readmission_analytics) TO 'readmission_analytics.csv' WITH CSV HEADER;

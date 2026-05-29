-- =====================================================================
-- 01_create_staging.sql
-- Raw staging tables for Synthea CSV ingestion (PostgreSQL 14+)
--
-- Column names use quoted MixedCase to preserve Synthea's CSV header
-- exactly, so `\copy ... CSV HEADER` matches columns by name.
-- Types are intentionally permissive (TEXT) where Synthea has changed
-- shape across versions; we cast in the ETL.
--
-- If your Synthea version emits a different column list, the load will
-- fail with a clear error — add/remove the column and re-run.
-- Verify your headers with:    head -1 patients.csv
-- =====================================================================

DROP TABLE IF EXISTS
  raw_patients, raw_encounters, raw_conditions, raw_procedures,
  raw_payers, raw_providers, raw_organizations
  CASCADE;

CREATE TABLE raw_patients (
  "Id"                  TEXT PRIMARY KEY,
  "BIRTHDATE"           DATE,
  "DEATHDATE"           DATE,
  "SSN"                 TEXT,
  "DRIVERS"             TEXT,
  "PASSPORT"            TEXT,
  "PREFIX"              TEXT,
  "FIRST"               TEXT,
  "LAST"                TEXT,
  "SUFFIX"              TEXT,
  "MAIDEN"              TEXT,
  "MARITAL"             TEXT,
  "RACE"                TEXT,
  "ETHNICITY"           TEXT,
  "GENDER"              TEXT,
  "BIRTHPLACE"          TEXT,
  "ADDRESS"             TEXT,
  "CITY"                TEXT,
  "STATE"               TEXT,
  "COUNTY"              TEXT,
  "FIPS"                TEXT,
  "ZIP"                 TEXT,
  "LAT"                 NUMERIC,
  "LON"                 NUMERIC,
  "HEALTHCARE_EXPENSES" NUMERIC,
  "HEALTHCARE_COVERAGE" NUMERIC,
  "INCOME"              NUMERIC
);

CREATE TABLE raw_encounters (
  "Id"                  TEXT PRIMARY KEY,
  "START"               TIMESTAMP,
  "STOP"                TIMESTAMP,
  "PATIENT"             TEXT,
  "ORGANIZATION"        TEXT,
  "PROVIDER"            TEXT,
  "PAYER"               TEXT,
  "ENCOUNTERCLASS"      TEXT,
  "CODE"                TEXT,
  "DESCRIPTION"         TEXT,
  "BASE_ENCOUNTER_COST" NUMERIC,
  "TOTAL_CLAIM_COST"    NUMERIC,
  "PAYER_COVERAGE"      NUMERIC,
  "REASONCODE"          TEXT,
  "REASONDESCRIPTION"   TEXT
);
CREATE INDEX ix_raw_enc_patient  ON raw_encounters("PATIENT");
CREATE INDEX ix_raw_enc_class    ON raw_encounters("ENCOUNTERCLASS");
CREATE INDEX ix_raw_enc_start    ON raw_encounters("START");

CREATE TABLE raw_conditions (
  "START"               DATE,
  "STOP"                DATE,
  "PATIENT"             TEXT,
  "ENCOUNTER"           TEXT,
  "SYSTEM"              TEXT,   -- recent Synthea versions include this; older do not
  "CODE"                TEXT,
  "DESCRIPTION"         TEXT
);
CREATE INDEX ix_raw_cond_encounter ON raw_conditions("ENCOUNTER");
CREATE INDEX ix_raw_cond_code      ON raw_conditions("CODE");

CREATE TABLE raw_procedures (
  "START"               TIMESTAMP,
  "STOP"                TIMESTAMP,
  "PATIENT"             TEXT,
  "ENCOUNTER"           TEXT,
  "SYSTEM"              TEXT,
  "CODE"                TEXT,
  "DESCRIPTION"         TEXT,
  "BASE_COST"           NUMERIC,
  "REASONCODE"          TEXT,
  "REASONDESCRIPTION"   TEXT
);
CREATE INDEX ix_raw_proc_encounter ON raw_procedures("ENCOUNTER");
CREATE INDEX ix_raw_proc_code      ON raw_procedures("CODE");

CREATE TABLE raw_payers (
  "Id"                       TEXT PRIMARY KEY,
  "NAME"                     TEXT,
  "OWNERSHIP"                TEXT,
  "ADDRESS"                  TEXT,
  "CITY"                     TEXT,
  "STATE_HEADQUARTERED"      TEXT,
  "ZIP"                      TEXT,
  "PHONE"                    TEXT,
  "AMOUNT_COVERED"           NUMERIC,
  "AMOUNT_UNCOVERED"         NUMERIC,
  "REVENUE"                  NUMERIC,
  "COVERED_ENCOUNTERS"       BIGINT,
  "UNCOVERED_ENCOUNTERS"     BIGINT,
  "COVERED_MEDICATIONS"      BIGINT,
  "UNCOVERED_MEDICATIONS"    BIGINT,
  "COVERED_PROCEDURES"       BIGINT,
  "UNCOVERED_PROCEDURES"     BIGINT,
  "COVERED_IMMUNIZATIONS"    BIGINT,
  "UNCOVERED_IMMUNIZATIONS"  BIGINT,
  "UNIQUE_CUSTOMERS"         BIGINT,
  "QOLS_AVG"                 NUMERIC,
  "MEMBER_MONTHS"            BIGINT
);

CREATE TABLE raw_providers (
  "Id"           TEXT PRIMARY KEY,
  "ORGANIZATION" TEXT,
  "NAME"         TEXT,
  "GENDER"       TEXT,
  "SPECIALITY"   TEXT,   -- yes, Synthea spells it "SPECIALITY"
  "ADDRESS"      TEXT,
  "CITY"         TEXT,
  "STATE"        TEXT,
  "ZIP"          TEXT,
  "LAT"          NUMERIC,
  "LON"          NUMERIC,
  "ENCOUNTERS"   BIGINT,
  "PROCEDURES"   BIGINT
);

CREATE TABLE raw_organizations (
  "Id"          TEXT PRIMARY KEY,
  "NAME"        TEXT,
  "ADDRESS"     TEXT,
  "CITY"        TEXT,
  "STATE"       TEXT,
  "ZIP"         TEXT,
  "LAT"         NUMERIC,
  "LON"         NUMERIC,
  "PHONE"       TEXT,
  "REVENUE"     NUMERIC,
  "UTILIZATION" BIGINT
);

-- Post-load sanity counts (run after \copy completes):
--   SELECT 'patients',      COUNT(*) FROM raw_patients      UNION ALL
--   SELECT 'encounters',    COUNT(*) FROM raw_encounters    UNION ALL
--   SELECT 'conditions',    COUNT(*) FROM raw_conditions    UNION ALL
--   SELECT 'procedures',    COUNT(*) FROM raw_procedures    UNION ALL
--   SELECT 'payers',        COUNT(*) FROM raw_payers        UNION ALL
--   SELECT 'providers',     COUNT(*) FROM raw_providers     UNION ALL
--   SELECT 'organizations', COUNT(*) FROM raw_organizations;

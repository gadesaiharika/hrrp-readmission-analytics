-- =====================================================================
-- 03_scd2_apply_changes.sql
-- Slowly Changing Dimension Type 2 — applied, not described.
--
-- The initial DimPatient load in 02_etl_readmission.sql is a Type 1 load: one
-- current row per patient. That is correct for a first load, but it leaves the
-- Type 2 columns (effective_start_date / effective_end_date / is_current)
-- unexercised. This script is the incremental merge that makes them real.
--
-- What Type 2 buys you here: an encounter from 2023 stays joined to where the
-- patient lived in 2023, even after they move. Without it, restating history is
-- unavoidable — every past readmission silently re-attributes to the new
-- address, and last quarter's regional numbers change out from under you.
--
-- Tracked attributes (a change to any of these opens a new version):
--     city, state, zip_code
-- Untracked (corrected in place, Type 1): birth_date, gender, race, ethnicity —
-- a change in these is a data-quality fix, not a real-world event to preserve.
--
-- Input:  raw_patients_updates, loaded from patients_updates.csv
-- Effect: expires changed current rows, inserts their successors
-- Idempotent: re-running with the same batch is a no-op, because after the
--             first pass no current row differs from the incoming one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Staging for the incremental extract. Same shape as raw_patients.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS raw_patients_updates CASCADE;

CREATE TABLE raw_patients_updates (
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


-- =====================================================================
-- The merge itself. Run after raw_patients_updates is loaded.
-- =====================================================================

-- The effective date of this batch. In a scheduled load this would come from
-- the extract's own timestamp; here it is the day the batch is applied.
CREATE OR REPLACE FUNCTION scd2_apply_patient_changes(p_effective_date DATE)
RETURNS TABLE(expired BIGINT, inserted BIGINT)
LANGUAGE plpgsql AS $$
DECLARE
  v_expired  BIGINT;
  v_inserted BIGINT;
BEGIN
  -- Step 1 — identify current rows whose tracked attributes changed.
  -- Captured up front, because step 2 flips is_current and the set would
  -- otherwise no longer be findable.
  CREATE TEMP TABLE scd2_changed ON COMMIT DROP AS
  SELECT d.patient_key, u."Id" AS patient_id
  FROM DimPatient d
  JOIN raw_patients_updates u ON u."Id" = d.patient_id
  WHERE d.is_current
    AND ( d.city     IS DISTINCT FROM u."CITY"
       OR d.state    IS DISTINCT FROM u."STATE"
       OR d.zip_code IS DISTINCT FROM u."ZIP" );

  -- Step 2 — close the outgoing version the day before the new one opens,
  -- so the two ranges abut without overlapping.
  UPDATE DimPatient d
     SET effective_end_date = p_effective_date - 1,
         is_current         = FALSE
    FROM scd2_changed c
   WHERE d.patient_key = c.patient_key;
  GET DIAGNOSTICS v_expired = ROW_COUNT;

  -- Step 3 — insert the successor version, open-ended and current.
  INSERT INTO DimPatient (
    patient_id, birth_date, gender, race, ethnicity,
    city, state, zip_code, effective_start_date, effective_end_date, is_current
  )
  SELECT u."Id", u."BIRTHDATE"::DATE, u."GENDER", u."RACE", u."ETHNICITY",
         u."CITY", u."STATE", u."ZIP", p_effective_date, NULL, TRUE
  FROM raw_patients_updates u
  JOIN scd2_changed c ON c.patient_id = u."Id";
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  -- Step 4 — Type 1 corrections for untracked attributes on patients whose
  -- tracked attributes did NOT change. These overwrite in place; no new version.
  UPDATE DimPatient d
     SET birth_date = u."BIRTHDATE"::DATE,
         gender     = u."GENDER",
         race       = u."RACE",
         ethnicity  = u."ETHNICITY"
    FROM raw_patients_updates u
   WHERE u."Id" = d.patient_id
     AND d.is_current
     AND NOT EXISTS (SELECT 1 FROM scd2_changed c WHERE c.patient_key = d.patient_key);

  RETURN QUERY SELECT v_expired, v_inserted;
END $$;


-- =====================================================================
-- Verification queries (also enforced by src/hrrp/validate.py)
-- =====================================================================
--
-- Exactly one current row per patient:
--   SELECT patient_id FROM DimPatient WHERE is_current
--   GROUP BY patient_id HAVING COUNT(*) <> 1;
--
-- Version history for a patient who moved:
--   SELECT patient_id, city, state, zip_code,
--          effective_start_date, effective_end_date, is_current
--   FROM DimPatient
--   WHERE patient_id IN (
--     SELECT patient_id FROM DimPatient GROUP BY patient_id HAVING COUNT(*) > 1
--   )
--   ORDER BY patient_id, effective_start_date;
--
-- No overlapping ranges (must return zero rows):
--   SELECT a.patient_id FROM DimPatient a
--   JOIN DimPatient b ON a.patient_id = b.patient_id AND a.patient_key < b.patient_key
--    AND a.effective_start_date < COALESCE(b.effective_end_date, DATE '9999-12-31')
--    AND b.effective_start_date < COALESCE(a.effective_end_date, DATE '9999-12-31');

-- =====================================================================
-- 04_analytics_views.sql
-- Reporting layer for the Tableau dashboard.
--
-- The dashboard connects to these views, not to the fact tables directly. That
-- keeps the join logic and the HRRP definitions in SQL under version control
-- rather than buried in Tableau calculated fields, where nobody can review them
-- and nothing can be tested.
--
-- vw_readmission_detail is deliberately built to be self-sufficient: it carries
-- the cohort label, the national benchmark, and a 0/1 readmission indicator on
-- every row. A BI tool can therefore build the entire dashboard from that one
-- extract — the readmission rate is just AVG(readmit_30d) — instead of needing
-- six separate data sources stitched together in the workbook.
-- =====================================================================

DROP VIEW IF EXISTS
  vw_readmission_detail, vw_hrrp_cohort_summary, vw_readmission_monthly,
  vw_payer_mix, vw_provider_outliers, vw_service_line_heatmap
  CASCADE;


-- ---------------------------------------------------------------------
-- Static reference dimension for the HRRP cohorts.
--
-- Previously the national benchmark rates were repeated as an inline VALUES
-- list in three separate views — three places to edit when CMS republishes,
-- and three chances to update two of them. One table, joined everywhere.
--
-- Rates are approximate CMS national figures, used as the dashboard comparison
-- line. Update here and every view follows.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS DimHrrpCohort CASCADE;

CREATE TABLE DimHrrpCohort (
  hrrp_condition     VARCHAR(20) PRIMARY KEY,
  cohort_label       VARCHAR(60) NOT NULL,
  national_rate_pct  NUMERIC(5,2) NOT NULL,
  identified_by      VARCHAR(20) NOT NULL,   -- diagnosis / procedure / fallback
  display_order      INT NOT NULL
);

INSERT INTO DimHrrpCohort VALUES
  ('HF',        'Heart failure',          21.50, 'diagnosis', 1),
  ('COPD',      'COPD',                   19.60, 'diagnosis', 2),
  ('PNEUMONIA', 'Pneumonia',              16.90, 'diagnosis', 3),
  ('AMI',       'Acute MI',               15.80, 'diagnosis', 4),
  ('CABG',      'CABG',                   12.80, 'procedure', 5),
  ('THA_TKA',   'Hip / knee replacement',  4.40, 'procedure', 6),
  ('OTHER',     'All other inpatient',    14.00, 'fallback',  7);


-- ---------------------------------------------------------------------
-- Row-level detail. One row per index inpatient admission, denormalised and
-- self-sufficient — this single extract can drive an entire dashboard.
-- ---------------------------------------------------------------------
CREATE VIEW vw_readmission_detail AS
SELECT
  r.readmission_key,
  r.hrrp_condition,
  c.cohort_label,
  c.national_rate_pct,
  -- Same benchmark as a fraction, so it shares an axis with AVG(readmit_30d).
  -- Without this, a benchmark reference line plots at 21.5 against bars near
  -- 0.21 and lands off the chart — the kind of unit mismatch that silently
  -- produces a wrong-looking dashboard rather than an error.
  ROUND(c.national_rate_pct / 100.0, 4)      AS national_rate,
  c.identified_by                            AS cohort_identified_by,
  c.display_order                            AS cohort_order,
  -- 0/1 rather than boolean: AVG() of this column IS the readmission rate, so
  -- a BI tool needs no calculated field to produce the headline number.
  CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END AS readmit_30d,
  CASE WHEN r.is_30day_readmission    THEN 1 ELSE 0 END AS is_readmit_of_prior,
  r.index_service_line                       AS service_line,
  r.index_los_days                           AS length_of_stay_days,
  r.days_to_next_admission,
  r.days_since_prior_discharge,
  d.full_date                                AS index_admit_date,
  MAKE_DATE(d.year, d.month, 1)              AS index_month_start,
  d.year                                     AS index_year,
  d.quarter                                  AS index_quarter,
  dd.full_date                               AS index_discharge_date,
  p.patient_id,
  p.gender,
  p.race,
  p.ethnicity,
  p.city                                     AS patient_city,
  p.state                                    AS patient_state,
  DATE_PART('year', AGE(d.full_date, p.birth_date))::INT AS age_at_admission,
  CASE
    WHEN DATE_PART('year', AGE(d.full_date, p.birth_date)) < 45 THEN 'Under 45'
    WHEN DATE_PART('year', AGE(d.full_date, p.birth_date)) < 65 THEN '45-64'
    WHEN DATE_PART('year', AGE(d.full_date, p.birth_date)) < 75 THEN '65-74'
    WHEN DATE_PART('year', AGE(d.full_date, p.birth_date)) < 85 THEN '75-84'
    ELSE '85+'
  END                                        AS age_band,
  pay.payer_name,
  pay.payer_type,
  prov.provider_name,
  prov.specialty                             AS provider_specialty,
  f.facility_name,
  e.total_charges
FROM FactReadmission r
JOIN FactEncounter e   ON e.encounter_key = r.index_encounter_key
JOIN DimDate       d   ON d.date_key      = r.index_admit_date_key
LEFT JOIN DimDate  dd  ON dd.date_key     = r.index_discharge_date_key
JOIN DimPatient    p   ON p.patient_key   = r.patient_key
LEFT JOIN DimHrrpCohort c ON c.hrrp_condition = r.hrrp_condition
LEFT JOIN DimPayer pay ON pay.payer_key   = r.index_payer_key
LEFT JOIN DimProvider prov ON prov.provider_key = r.index_provider_key
LEFT JOIN DimFacility f    ON f.facility_key    = r.index_facility_key;

COMMENT ON VIEW vw_readmission_detail IS
  'One row per index inpatient admission, denormalised and self-sufficient. '
  'Grain: index encounter. AVG(readmit_30d) is the 30-day readmission rate.';


-- ---------------------------------------------------------------------
-- The headline table: 30-day rate per HRRP cohort.
--
-- Penalty exposure is deliberately a simple illustrative model, not a
-- reproduction of the CMS payment formula. CMS uses risk-standardised ratios
-- against national benchmarks with a 3-year lookback; this is a linear
-- approximation for executive framing only, and the README says so.
-- ---------------------------------------------------------------------
CREATE VIEW vw_hrrp_cohort_summary AS
WITH base AS (
  SELECT
    r.hrrp_condition,
    c.cohort_label,
    c.national_rate_pct,
    c.display_order,
    COUNT(*)                                                     AS index_admissions,
    SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)   AS readmissions_30d,
    ROUND(AVG(r.index_los_days), 2)                              AS avg_los_days,
    ROUND(AVG(e.total_charges), 2)                               AS avg_charges
  FROM FactReadmission r
  JOIN FactEncounter e ON e.encounter_key = r.index_encounter_key
  LEFT JOIN DimHrrpCohort c ON c.hrrp_condition = r.hrrp_condition
  GROUP BY r.hrrp_condition, c.cohort_label, c.national_rate_pct, c.display_order
)
SELECT
  hrrp_condition,
  cohort_label,
  index_admissions,
  readmissions_30d,
  ROUND(100.0 * readmissions_30d / NULLIF(index_admissions, 0), 2) AS rate_pct,
  national_rate_pct,
  ROUND(100.0 * readmissions_30d / NULLIF(index_admissions, 0)
        - national_rate_pct, 2)                                   AS rate_vs_national,
  avg_los_days,
  avg_charges,
  -- Illustrative exposure: excess readmissions x average charge.
  ROUND(GREATEST(
    readmissions_30d - (national_rate_pct / 100.0 * index_admissions), 0
  ) * avg_charges, 0)                                             AS est_excess_cost,
  display_order
FROM base
ORDER BY rate_pct DESC NULLS LAST;

COMMENT ON VIEW vw_hrrp_cohort_summary IS
  'Rate per HRRP cohort vs national benchmark. est_excess_cost is an '
  'illustrative linear model, NOT the CMS payment-adjustment formula.';


-- ---------------------------------------------------------------------
-- Trend. Monthly rate, overall and per cohort.
-- ---------------------------------------------------------------------
CREATE VIEW vw_readmission_monthly AS
SELECT
  d.year,
  d.month,
  d.month_name,
  MAKE_DATE(d.year, d.month, 1)                                AS month_start,
  r.hrrp_condition,
  c.cohort_label,
  c.national_rate_pct,
  COUNT(*)                                                     AS index_admissions,
  SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)   AS readmissions_30d,
  ROUND(100.0 * SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2)                              AS rate_pct
FROM FactReadmission r
JOIN DimDate d ON d.date_key = r.index_admit_date_key
LEFT JOIN DimHrrpCohort c ON c.hrrp_condition = r.hrrp_condition
GROUP BY d.year, d.month, d.month_name, r.hrrp_condition,
         c.cohort_label, c.national_rate_pct
ORDER BY d.year, d.month, r.hrrp_condition;


-- ---------------------------------------------------------------------
-- Payer mix among readmitted patients — who bears the cost.
-- ---------------------------------------------------------------------
CREATE VIEW vw_payer_mix AS
SELECT
  pay.payer_name,
  pay.payer_type,
  r.hrrp_condition,
  c.cohort_label,
  COUNT(*)                                                     AS index_admissions,
  SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)   AS readmissions_30d,
  ROUND(100.0 * SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2)                              AS rate_pct,
  ROUND(SUM(e.total_charges), 2)                               AS total_charges
FROM FactReadmission r
JOIN FactEncounter e   ON e.encounter_key = r.index_encounter_key
LEFT JOIN DimPayer pay ON pay.payer_key   = r.index_payer_key
LEFT JOIN DimHrrpCohort c ON c.hrrp_condition = r.hrrp_condition
GROUP BY pay.payer_name, pay.payer_type, r.hrrp_condition, c.cohort_label;


-- ---------------------------------------------------------------------
-- Provider outliers, with case-mix context.
--
-- A raw provider rate is misleading — a cardiologist carrying mostly heart
-- failure will always look worse than an orthopedist carrying joint
-- replacements. `expected_rate_pct` weights each provider's own cohort mix by
-- the national rates, so the comparison is against what that provider's
-- panel would predict rather than a flat average.
-- ---------------------------------------------------------------------
CREATE VIEW vw_provider_outliers AS
WITH per_provider AS (
  SELECT
    prov.provider_key,
    prov.provider_name,
    prov.specialty,
    COUNT(*)                                                   AS index_admissions,
    SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END) AS readmissions_30d,
    AVG(c.national_rate_pct)                                   AS expected_rate_pct
  FROM FactReadmission r
  JOIN DimProvider prov ON prov.provider_key = r.index_provider_key
  LEFT JOIN DimHrrpCohort c ON c.hrrp_condition = r.hrrp_condition
  GROUP BY prov.provider_key, prov.provider_name, prov.specialty
)
SELECT
  provider_name,
  specialty,
  index_admissions,
  readmissions_30d,
  ROUND(100.0 * readmissions_30d / NULLIF(index_admissions, 0), 2) AS actual_rate_pct,
  ROUND(expected_rate_pct, 2)                                      AS expected_rate_pct,
  ROUND(100.0 * readmissions_30d / NULLIF(index_admissions, 0)
        - expected_rate_pct, 2)                                    AS excess_rate_pct
FROM per_provider
WHERE index_admissions >= 10          -- suppress small denominators
ORDER BY excess_rate_pct DESC NULLS LAST;

COMMENT ON VIEW vw_provider_outliers IS
  'Provider rate vs case-mix-adjusted expectation. Providers with fewer than 10 '
  'index admissions are excluded — small denominators produce meaningless rates.';


-- ---------------------------------------------------------------------
-- Service line x cohort heatmap source.
-- ---------------------------------------------------------------------
CREATE VIEW vw_service_line_heatmap AS
SELECT
  r.index_service_line                                         AS service_line,
  r.hrrp_condition,
  c.cohort_label,
  COUNT(*)                                                     AS index_admissions,
  SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)   AS readmissions_30d,
  ROUND(100.0 * SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2)                              AS rate_pct,
  ROUND(AVG(r.index_los_days), 2)                              AS avg_los_days
FROM FactReadmission r
LEFT JOIN DimHrrpCohort c ON c.hrrp_condition = r.hrrp_condition
GROUP BY r.index_service_line, r.hrrp_condition, c.cohort_label;

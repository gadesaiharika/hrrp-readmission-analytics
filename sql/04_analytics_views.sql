-- =====================================================================
-- 04_analytics_views.sql
-- Reporting layer for the Tableau dashboard.
--
-- The dashboard connects to these views, not to the fact tables directly. That
-- keeps the join logic and the HRRP definitions in SQL under version control
-- rather than buried in Tableau calculated fields, where nobody can review them
-- and nothing can be tested.
-- =====================================================================

DROP VIEW IF EXISTS
  vw_readmission_detail, vw_hrrp_cohort_summary, vw_readmission_monthly,
  vw_payer_mix, vw_provider_outliers, vw_service_line_heatmap
  CASCADE;


-- ---------------------------------------------------------------------
-- Row-level detail. One row per index inpatient admission, fully denormalised
-- for BI consumption.
-- ---------------------------------------------------------------------
CREATE VIEW vw_readmission_detail AS
SELECT
  r.readmission_key,
  r.hrrp_condition,
  r.index_service_line                       AS service_line,
  r.index_los_days                           AS length_of_stay_days,
  r.is_30day_readmission                     AS is_readmission_of_prior,
  r.has_30day_readmit_after                  AS had_readmit_within_30d,
  r.days_to_next_admission,
  r.days_since_prior_discharge,
  d.full_date                                AS index_admit_date,
  d.year                                     AS index_year,
  d.quarter                                  AS index_quarter,
  d.month                                    AS index_month,
  dd.full_date                               AS index_discharge_date,
  p.patient_id,
  p.gender,
  p.race,
  p.ethnicity,
  p.city                                     AS patient_city,
  p.state                                    AS patient_state,
  DATE_PART('year', AGE(d.full_date, p.birth_date))::INT AS age_at_admission,
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
LEFT JOIN DimPayer pay ON pay.payer_key   = r.index_payer_key
LEFT JOIN DimProvider prov ON prov.provider_key = r.index_provider_key
LEFT JOIN DimFacility f    ON f.facility_key    = r.index_facility_key;

COMMENT ON VIEW vw_readmission_detail IS
  'One row per index inpatient admission, denormalised for BI. Grain: index encounter.';


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
    hrrp_condition,
    COUNT(*)                                                     AS index_admissions,
    SUM(CASE WHEN has_30day_readmit_after THEN 1 ELSE 0 END)     AS readmissions_30d,
    ROUND(AVG(index_los_days), 2)                                AS avg_los_days,
    ROUND(AVG(e.total_charges), 2)                               AS avg_charges
  FROM FactReadmission r
  JOIN FactEncounter e ON e.encounter_key = r.index_encounter_key
  GROUP BY hrrp_condition
),
benchmarks(hrrp_condition, national_rate_pct) AS (
  -- Approximate CMS national rates, used as the comparison line on the dashboard.
  VALUES ('HF', 21.5), ('COPD', 19.6), ('PNEUMONIA', 16.9), ('AMI', 15.8),
         ('CABG', 12.8), ('THA_TKA', 4.4), ('OTHER', 14.0)
)
SELECT
  b.hrrp_condition,
  b.index_admissions,
  b.readmissions_30d,
  ROUND(100.0 * b.readmissions_30d / NULLIF(b.index_admissions, 0), 2) AS rate_pct,
  n.national_rate_pct,
  ROUND(100.0 * b.readmissions_30d / NULLIF(b.index_admissions, 0)
        - n.national_rate_pct, 2)                                     AS rate_vs_national,
  b.avg_los_days,
  b.avg_charges,
  -- Illustrative exposure: excess readmissions x average charge.
  ROUND(GREATEST(
    b.readmissions_30d - (n.national_rate_pct / 100.0 * b.index_admissions), 0
  ) * b.avg_charges, 0)                                               AS est_excess_cost
FROM base b
LEFT JOIN benchmarks n ON n.hrrp_condition = b.hrrp_condition
ORDER BY rate_pct DESC NULLS LAST;

COMMENT ON VIEW vw_hrrp_cohort_summary IS
  'Rate per HRRP cohort vs approximate national benchmark. est_excess_cost is an '
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
  COUNT(*)                                                     AS index_admissions,
  SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)   AS readmissions_30d,
  ROUND(100.0 * SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2)                              AS rate_pct
FROM FactReadmission r
JOIN DimDate d ON d.date_key = r.index_admit_date_key
GROUP BY d.year, d.month, d.month_name, r.hrrp_condition
ORDER BY d.year, d.month, r.hrrp_condition;


-- ---------------------------------------------------------------------
-- Payer mix among readmitted patients — who bears the cost.
-- ---------------------------------------------------------------------
CREATE VIEW vw_payer_mix AS
SELECT
  pay.payer_name,
  pay.payer_type,
  r.hrrp_condition,
  COUNT(*)                                                     AS index_admissions,
  SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)   AS readmissions_30d,
  ROUND(100.0 * SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2)                              AS rate_pct,
  ROUND(SUM(e.total_charges), 2)                               AS total_charges
FROM FactReadmission r
JOIN FactEncounter e   ON e.encounter_key = r.index_encounter_key
LEFT JOIN DimPayer pay ON pay.payer_key   = r.index_payer_key
GROUP BY pay.payer_name, pay.payer_type, r.hrrp_condition;


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
WITH benchmarks(hrrp_condition, national_rate_pct) AS (
  VALUES ('HF', 21.5), ('COPD', 19.6), ('PNEUMONIA', 16.9), ('AMI', 15.8),
         ('CABG', 12.8), ('THA_TKA', 4.4), ('OTHER', 14.0)
),
per_provider AS (
  SELECT
    prov.provider_key,
    prov.provider_name,
    prov.specialty,
    COUNT(*)                                                   AS index_admissions,
    SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END) AS readmissions_30d,
    SUM(n.national_rate_pct) / NULLIF(COUNT(*), 0)             AS expected_rate_pct
  FROM FactReadmission r
  JOIN DimProvider prov ON prov.provider_key = r.index_provider_key
  LEFT JOIN benchmarks n ON n.hrrp_condition = r.hrrp_condition
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
  COUNT(*)                                                     AS index_admissions,
  SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)   AS readmissions_30d,
  ROUND(100.0 * SUM(CASE WHEN r.has_30day_readmit_after THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2)                              AS rate_pct,
  ROUND(AVG(r.index_los_days), 2)                              AS avg_los_days
FROM FactReadmission r
GROUP BY r.index_service_line, r.hrrp_condition;

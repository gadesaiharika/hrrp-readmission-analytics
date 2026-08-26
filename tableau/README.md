# Tableau workbook

The dashboard is built on the CSV extracts written to `data/exports/` by `run.py`.

```bash
python run.py            # refreshes data/exports/*.csv
```

## Connect to one file

`vw_readmission_detail.csv` is built to be self-sufficient — 1,467 rows, one per index inpatient
admission, carrying the cohort label, the national benchmark, and a 0/1 readmission indicator on
every row. The whole dashboard can be built from it alone.

| Field | Use |
|---|---|
| `readmit_30d` | `AVG()` of this is the 30-day readmission rate. No calculated field needed. |
| `national_rate` | CMS benchmark as a fraction — shares an axis with the above |
| `national_rate_pct` | the same benchmark in percentage points. **Do not mix the two on one axis.** |
| `cohort_label` | display name for the HRRP cohort |
| `index_month_start` | first of the admission month, for a clean trend axis |
| `age_band` | Under 45 / 45-64 / 65-74 / 75-84 / 85+ |

`AVG(national_rate)` grouped by provider gives that provider's case-mix expectation, since the
benchmark rides on every row — which is what makes a fair provider comparison possible without a
second data source.

## The pre-aggregated views

Useful when you want the arithmetic already done, or for a second data source:

| Extract | Contents |
|---|---|
| `vw_hrrp_cohort_summary.csv` | rate vs benchmark per cohort, plus `est_excess_cost` |
| `vw_readmission_monthly.csv` | monthly rate by cohort |
| `vw_service_line_heatmap.csv` | service line x cohort |
| `vw_payer_mix.csv` | payer mix among readmitted patients |
| `vw_provider_outliers.csv` | case-mix-adjusted provider ranking |

`est_excess_cost` is computed in SQL, where it can be reviewed and tested. Sum the column — do not
rebuild the arithmetic in a calculated field.

Screenshots land here once the workbook is rebuilt against the current pipeline output.

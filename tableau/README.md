# Tableau workbook

The dashboard is built on the CSV extracts written to `data/exports/` by `run.py`.
Regenerate them, then refresh the workbook's data source:

```bash
python run.py            # writes data/exports/*.csv
```

| Extract | Feeds |
|---|---|
| `vw_hrrp_cohort_summary.csv` | cohort rate vs national benchmark, excess-cost estimate |
| `vw_readmission_monthly.csv` | rate trend |
| `vw_service_line_heatmap.csv` | service line x cohort heatmap |
| `vw_payer_mix.csv` | payer mix among readmitted patients |
| `vw_provider_outliers.csv` | case-mix-adjusted provider ranking |
| `vw_readmission_detail.csv` | row-level detail for drill-down |

Screenshots land here once the workbook is rebuilt against the current pipeline output.

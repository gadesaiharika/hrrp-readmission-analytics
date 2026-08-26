# Tableau Calculations Reference — Readmissions Dashboard

This document lists every calculated field and parameter used in the dashboard, in the order you should create them in Tableau.

The data source is the CSV exported from `vw_readmission_analytics` in PostgreSQL (one row per inpatient admission, with all dimension attributes already joined).

---

## A. Parameters (create these first)

Parameters are user-tunable values you reference in calculated fields. Tableau → Data pane → small dropdown arrow → Create Parameter.

### A1. National Benchmark Readmission Rate
- **Data type:** Float
- **Current value:** 0.15
- **Display format:** Percentage, 1 decimal place
- **Allowable values:** Range, 0.05 to 0.30, step 0.005
- **Purpose:** Lets executives slide the benchmark to model different scenarios.

### A2. Average Medicare Payment per Case (USD)
- **Data type:** Integer
- **Current value:** 14000
- **Display format:** Currency, 0 decimals
- **Allowable values:** Range, 5000 to 30000, step 500
- **Purpose:** Used in penalty exposure calculation.

### A3. HRRP Penalty Factor
- **Data type:** Float
- **Current value:** 1.00
- **Display format:** Number, 2 decimals
- **Allowable values:** Range, 0.50 to 3.00, step 0.05
- **Purpose:** Multiplier that lets you model worst-case (3% penalty cap) vs. baseline scenarios.

---

## B. Core calculated fields

### B1. HRRP Index Flag (boolean for filtering)
```
[Hrrp Condition] IN ('AMI','HF','PNEUMONIA','COPD','CABG','THA_TKA')
```
Used as a filter on every dashboard view that should show HRRP cohorts only.

### B2. Readmitted (numeric flag — used in aggregations)
```
IF [Has 30day Readmit After] THEN 1 ELSE 0 END
```
Aggregation: SUM.

### B3. Index Admission Count
```
1
```
Aggregation: SUM. Lets you compute `SUM([Readmitted]) / SUM([Index Admission Count])` cleanly.

### B4. Readmission Rate (the headline KPI)
```
SUM([Readmitted]) / SUM([Index Admission Count])
```
- Format → Number → Percentage, 1 decimal.
- This is what you put on the axis of every rate chart.

### B5. Expected Readmissions (denominator × benchmark)
```
SUM([Index Admission Count]) * [National Benchmark Rate]
```

### B6. Excess Readmissions (the executive number)
```
SUM([Readmitted]) - ([National Benchmark Rate] * SUM([Index Admission Count]))
```
A positive value means you are above the national average. Negative means below.

### B7. CMS HRRP Penalty Exposure — **the calculated field your résumé references**
```
IF [Hrrp Condition] IN ('AMI','HF','PNEUMONIA','COPD','CABG','THA_TKA') THEN
    MAX(
        ( SUM([Readmitted]) - [National Benchmark Rate] * SUM([Index Admission Count]) )
        * [Avg Medicare Payment per Case]
        * [HRRP Penalty Factor],
        0
    )
ELSE 0
END
```

**Plain-English translation of this formula:**
1. Only count HRRP-qualifying admissions (AMI, HF, etc.).
2. Compute *excess* readmissions = actual readmissions minus the number we would have expected at the national benchmark rate.
3. Multiply by average Medicare payment per case to convert excess readmissions into dollars.
4. Multiply by the penalty factor parameter to let executives model best/worst case.
5. Floor the result at zero — you cannot have a *negative* penalty.

> Important caveat to give in interviews: "This is a simplified illustrative model, not the precise CMS formula. The real HRRP penalty applies as a reduction factor to all base operating DRG payments, capped at 3% — but executives want a single dollar figure they can act on, so this approximation is what analytics teams typically present alongside the official numbers."

### B8. Readmission Rate vs. Benchmark (signed difference)
```
[Readmission Rate] - [National Benchmark Rate]
```
Format as percentage. Used for the variance column in tables and for coloring heatmaps.

### B9. Provider Volume Threshold
```
{ FIXED [Provider Name] : COUNT([Index Encounter Key]) } >= 20
```
A Level of Detail (LOD) expression that returns TRUE only for providers with ≥20 cases. Use as a filter on the Provider Outliers chart to remove noisy low-volume providers.

---

## C. Visual-specific setup

### Visual 1 — Readmission Rate Trends (Line Chart)

| Shelf       | Field                                          |
|-------------|-----------------------------------------------|
| Columns     | MONTH(Index Admit Date) — continuous          |
| Rows        | Readmission Rate                              |
| Color       | Hrrp Condition                                |
| Filter      | HRRP Index Flag = TRUE                        |

Add a reference line: Analytics pane → Reference Line → drag onto rate axis → Value = National Benchmark Rate parameter → Label = "CMS National Benchmark" → format dashed red.

### Visual 2 — Payer Mix of Readmissions (Stacked Bar)

| Shelf       | Field                                          |
|-------------|-----------------------------------------------|
| Rows        | Hrrp Condition                                |
| Columns     | SUM(Readmitted)                               |
| Color       | Payer Type                                    |
| Filter      | HRRP Index Flag = TRUE, Has 30day Readmit After = TRUE |

Right-click `SUM(Readmitted)` on Columns → Quick Table Calculation → Percent of Total → Compute Using → Table (across). Now each bar sums to 100% and shows the payer breakdown of the readmissions for each HRRP cohort.

### Visual 3 — Service Line × HRRP Condition Heatmap

| Shelf       | Field                                          |
|-------------|-----------------------------------------------|
| Rows        | Index Service Line                            |
| Columns     | Hrrp Condition                                |
| Marks card  | Mark type = Square                            |
| Color       | Readmission Rate                              |
| Label       | Readmission Rate (formatted as percentage)    |
| Filter      | HRRP Index Flag = TRUE                        |

Color → Edit Colors → diverging palette → set center value to the parameter `National Benchmark Rate` so anything green is below benchmark and red is above.

### Visual 4 — Provider Outliers (Scatter Plot with Control Limits)

| Shelf       | Field                                          |
|-------------|-----------------------------------------------|
| Columns     | SUM(Index Admission Count) — volume on X      |
| Rows        | Readmission Rate — rate on Y                  |
| Detail      | Provider Name                                 |
| Color       | Specialty                                     |
| Filter      | HRRP Index Flag = TRUE; Provider Volume Threshold = TRUE |

Add reference lines on the Y axis:
- Mean: AVG(Readmission Rate), label "Hospital Average".
- Upper control limit: AVG(Readmission Rate) + 2*STDEV(Readmission Rate), label "+2σ".
- Lower control limit: AVG(Readmission Rate) - 2*STDEV(Readmission Rate), label "-2σ".

Providers above the +2σ line are the statistical outliers worth investigating.

### Executive KPI tiles (Visual 0, for the top of the dashboard)

Create three single-number sheets:
1. **Total HRRP Index Admissions** — Text shelf: `SUM([Index Admission Count])`, filtered to HRRP Index Flag = TRUE.
2. **Overall HRRP Readmission Rate** — Text shelf: `[Readmission Rate]`, filtered to HRRP Index Flag = TRUE, formatted as percent.
3. **Estimated CMS Penalty Exposure** — Text shelf: `SUM([CMS HRRP Penalty Exposure])`, formatted as $ with thousands separator.

Drop all three into a horizontal container at the top of the dashboard.

---

## D. Dashboard assembly checklist

1. New Dashboard → Size: Automatic (or 1366×800 fixed for Tableau Public consistency).
2. Add the three KPI tiles in a horizontal container at the top.
3. Add Visual 1 (trend) below the KPIs, full width.
4. Add Visual 3 (heatmap) and Visual 2 (payer mix) side by side beneath the trend.
5. Add Visual 4 (provider scatter) below those, full width.
6. Add three parameter controls to the right margin: National Benchmark Rate, Avg Medicare Payment, HRRP Penalty Factor. These make the dashboard interactive for executives.
7. Add a dashboard-wide filter: HRRP Condition (multi-select).
8. Add a date range filter on Index Admit Date.
9. Test every filter and parameter — the penalty exposure tile should update live.
10. File → Save to Tableau Public → use the URL on your résumé and LinkedIn.

---

## E. Interview talking points anchored to specific calculations

- **B4 (Readmission Rate):** "Rate is SUM of the readmitted flag divided by SUM of the index admission count — both as aggregates so Tableau respects whichever level the user has filtered to."
- **B7 (CMS Penalty Exposure):** "Excess readmissions above the national benchmark, multiplied by average Medicare payment, multiplied by a configurable penalty factor. It's a simplified executive number, not the official CMS formula."
- **B9 (Provider Volume Threshold):** "LOD expression because the rate calculation aggregates to the provider level, but the filter needs the underlying case count. FIXED keeps that count stable as other filters change."

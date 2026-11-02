# LFDP: gap-definition sweep and field validation

Generated 2026-11-02 from `$PR_GAPS_DATA/runs/canopy/lfdp/sweeps/thr-1-1.5-2-3-4-5-8_conn-26-6/`
(`python/sweep.py`, `python/quadrat_gaps.py`, `scripts/06_lfdp_quadrat_validation.R`).
Gap runs: 26-connectivity `6dc2499bff8f73cf`, 6-connectivity `fc2811e5f3ddf6bd`;
distance cache `539478f9f020…` (9,036,855 2017 returns, LFDP + 50 m, EV1 5 Mar 2017 → 25 Apr 2018).
Default method (connected components), MIN_POINTS 10, 1 m voxels. Full tables beside this file:
`sweep_comparison.csv`, `quadrat_fit_stats.csv`, `sweep_runs.json`.

## 1. Gaps by threshold and connectivity (whole site, 25 ha)

| Threshold | Gaps (26 / 6) | Largest gap's share of gap volume (26 / 6) | Gap volume, 26 (m³) | Gaps ≥ 100 m³ (26 / 6) | Gaps ≥ 1,000 m³ (26 / 6) |
|---|---|---|---|---|---|
| 1 m | 1,899 / 6,311 | 97% / 88% | 940,538 | 16 / 86 | 1 / 10 |
| 1.5 m | 2,223 / 5,626 | 90% / 45% | 634,695 | 81 / 242 | 7 / 34 |
| 2 m | 2,131 / 4,176 | 35% / 8.7% | 423,545 | 219 / 363 | 37 / 61 |
| 3 m | 1,392 / 2,126 | 5.2% / 2.4% | 188,140 | 281 / 316 | 42 / 33 |
| 4 m | 909 / 1,175 | 3.1% / 3.0% | 81,954 | 182 / 184 | 9 / 9 |
| 5 m | 491 / 589 | 4.2% / 4.1% | 34,959 | 73 / 72 | 5 / 5 |
| 8 m | 43 / 49 | 21% / 21% | 3,458 | 8 / 8 | 0 / 0 |

Changed voxels link into one dominant component below 3 m with 26-connectivity (5.2% → 35% between 3 and 2 m)
and below 2 m with 6-connectivity (8.7% → 45% between 2 and 1.5 m). For reference, ground returns sit up to
0.77 m from their nearest 2018 return (p99; median 0.21 m), so 1–1.5 m is close to the sampling-noise floor.

## 2. Census damage explained by gap metrics, per quadrat (R², 26-connectivity)

Census: post-Maria LFDP stems with DBH ≥ 20 and a status (4,019 stems; ~10 per 20 m quadrat, ~40 per 40 m).
Stem loss = broken or uprooted, or dead / not found with no break recorded; basal-area loss weights it by
basal area. Gap area = share of the quadrat whose 1 m column holds a gap voxel; gap volume = gap voxels as a
share of the 2017 vegetation voxels in the quadrat. 400 20 m and 96 40 m quadrats.

| Threshold | 20 m: stem loss ~ area | 20 m: BA loss ~ area | 20 m: stem loss ~ volume | 20 m: BA loss ~ volume | 40 m: stem loss ~ area | 40 m: BA loss ~ area | 40 m: stem loss ~ volume | 40 m: BA loss ~ volume |
|---|---|---|---|---|---|---|---|---|
| 1 m | 0.30 | 0.21 | **0.36** | 0.27 | 0.51 | 0.36 | **0.50** | **0.41** |
| 1.5 m | 0.36 | 0.25 | 0.35 | 0.27 | 0.55 | 0.41 | 0.46 | 0.40 |
| 2 m | **0.38** | 0.29 | 0.33 | **0.27** | **0.56** | 0.44 | 0.42 | 0.39 |
| 3 m | 0.35 | **0.29** | 0.27 | 0.25 | 0.51 | **0.46** | 0.36 | 0.37 |
| 4 m | 0.27 | 0.24 | 0.19 | 0.19 | 0.40 | 0.39 | 0.28 | 0.30 |
| 5 m | 0.17 | 0.17 | 0.11 | 0.12 | 0.26 | 0.29 | 0.19 | 0.23 |
| 8 m | 0.03 | 0.04 | 0.02 | 0.03 | 0.08 | 0.13 | 0.07 | 0.12 |

Bold: best threshold for that column, judged at full precision, so a column can have
values that tie at two decimals with only one in bold (exact values in `quadrat_fit_stats.csv`). Largest R² difference between 26- and 6-connectivity over all of
these: 0.029.

## 3. Fits at 2 m, gap area (26-connectivity)

| Quadrats | Damage | Slope | Intercept | Mean gap area | Mean damage | Spearman ρ | R² |
|---|---|---|---|---|---|---|---|
| 20 m | stem loss | 0.80 | +3.13 | 53.0% | 45.4% | 0.62 | 0.38 |
| 20 m | basal-area loss | 0.79 | +1.90 | 53.0% | 43.8% | 0.54 | 0.29 |
| 40 m | stem loss | 0.89 | -1.18 | 52.2% | 45.2% | 0.75 | 0.56 |
| 40 m | basal-area loss | 0.90 | -3.62 | 52.2% | 43.2% | 0.66 | 0.44 |

## Caveats

- One site and one forest type (tabonuco wet forest); the census exists only here.
- Quadrats are spatially autocorrelated: R² and ρ describe agreement, not significance.
- 20 m quadrats hold ~10 qualifying stems, so their damage moves in ~10% steps.
- The census records stem-level outcomes for stems ≥ 20 DBH; lidar sees all canopy change, defoliation and
  branch loss on surviving trees included.
- BU and ADNF are whitespace-trimmed before classification (one stem is recorded as " B").

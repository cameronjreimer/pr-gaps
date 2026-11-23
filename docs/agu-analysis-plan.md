# AGU draft analysis plan

*Written 2026-11-23. The draft is due the week of 2026-11-30.*

**Inputs:**
- island run `df81889aa38eecef`, with 3 m gap objects (ADR 009);
- covariates per gap (M6, `gap_covariates.py`);
- the C-CAP forest mask, keeping gaps with forest fraction ≥ 0.5 (ADR 007);
- the area denominators in `runs/canopy/area/<id>/areas.csv`.

## Decisions (user, 2026-11-23)

- **"Largest" objects** are gaps with a footprint of **≥ 25 ha** (the M3 window size).
  The size fits are reported with and without them (ADR 009 *Outcome*).
- **Strata** group the Holdridge zones into four:
  - dry: Subtropical Dry;
  - moist: Subtropical Moist;
  - wet: Subtropical Wet and Rain;
  - montane: Lower Montane Wet and Rain.
- **The size variable** is `footprint_area_m2`, with volume as a backup.
- **QC-FAIL units are kept.** Their failures are all DTM / height-above-ground; C2C
  doesn't use the DTM.
- **Total gap area** is reported at both **2 m** (the extent product, ADR 009 rule 1)
  and **3 m** (the gap objects).
- **Gradients in step 4** are elevation, rainfall, slope and pre-storm canopy height.
  Rugosity is left out.

## Steps

0. **Analysis table** (`python/agu_table.py`).
   - Join the gaps to their covariates and keep `forest_ccap_frac` ≥ 0.5.
   - Add stratum, tile, `is_largest`, `main_pair_flagged` and `touches_coverage_edge`.
   - Writes `runs/canopy/island/<run>/analysis/gaps_<T>m.csv`.
1. **Total gap area** at 2 and 3 m.
   - Gap area = Σ footprint × C-CAP forest fraction.
   - Gap fraction = gap area ÷ C-CAP forest covered by both flights (`forest_ccap_ha`).
   - Island-wide and per stratum. The 2 m figure needs `gapcov` run at 2 m first.
2. **Size-distribution models** (`scripts/07_agu_fits.R`, which reuses `06_compare_fits.R`'s models).
   - One island-wide xmin (KS).
   - Candidates: power law, cutoff, log-normal, Weibull, exponential and piecewise.
   - Report ΔAIC, Akaike weights, log-likelihood gain per gap and Vuong tests, and plot
     the CCDF with each fit; with and without the gaps ≥ 25 ha.
3. **α by stratum.** A power law above the island xmin (held fixed), with a block
   bootstrap over 1 km tiles (200 replicates).
4. **α along gradients.** Five bins of equal count for each gradient; α per bin as in step 3.
5. **Figures:**
   - total gap area;
   - the CCDF with the fits;
   - α by stratum;
   - α along the gradients.

   One backup sensitivity excludes the gaps touching a coverage edge.

**Not in the draft:** spatial regression, the seeded split, the test between flights at
pair borders, and the recovery period.

## Status (2026-11-23)

- **Steps 0 and 1 at 3 m are done.** Outputs: `analysis/gaps_3m.csv` and `analysis/gap_area.csv`.
- **Step 1 at 2 m is done** (2026-11-23). The gap fraction of the C-CAP forest covered
  by both flights is 44.5% at 2 m (17,328 ha) and 26.9% at 3 m (10,487 ha).
  - Wet: 51.3% at 2 m, 31.9% at 3 m.
  - Moist: 44.0% and 26.6%.
  - Montane: 35.1% and 17.0%.
  - Dry: 14.0% and 7.1%.
- **Steps 2–4 are done** with `scripts/07_agu_fits.R` (200-replicate tile bootstrap, about
  1 min). Outputs are in `analysis/fits/`.
- **The island xmin is 311 m²,** so the fits describe only the 39,386 largest of the
  1,550,280 gaps in forest (2.5%).

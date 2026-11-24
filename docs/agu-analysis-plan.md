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

## xmin (user, 2026-11-24)

The KS estimate (311 m²) keeps only 2.5% of gaps. The size distribution bends, so the KS
distance keeps falling as xmin rises and the method moves into the far tail. Following the
user's choice, the fits were rerun at fixed xmin = 10 and 5 m², set by resolution
(`AGU_XMIN=… Rscript scripts/07_agu_fits.R`, outputs in `fits/xmin_<v>/`). A scan of α by
stratum and gradient over xmin = 5–311 m² was added as a sensitivity check
(`scripts/08_xmin_sensitivity.R`, outputs in `fits/xmin_sensitivity/`).

- **Best model:** lognormal at both 5 and 10 m². The power law is far behind
  (ΔAIC 48,712 at 5 m², 15,962 at 10 m²). Without gaps touching a coverage edge, Weibull
  is best at 10 m² and lognormal at 5 m².
- **α (tile bootstrap 95%),** xmin 10 / 5 m²:
  - all: 1.797 / 1.706;
  - dry: 1.852 / 1.731;
  - moist: 1.779 / 1.690;
  - wet: 1.802 / 1.714;
  - montane: 1.897 / 1.756.
- **The order holds at every xmin** (montane and dry steepest; moist and wet together),
  but the spread shrinks at low xmin.
- **Gradients at 10 m²:**
  - α is highest under the shortest canopy (2.01);
  - it is U-shaped with slope;
  - it rises weakly with elevation (1.77 → 1.83) and in the wettest quintile.
- **Local exponent of the lognormal,** α(x) = 1 + (ln x − μ)/σ², island-wide:
  - α(100 m²) = 1.81 at both xmin values;
  - α(10) ≈ 1.5 and α(1,000) ≈ 2.1–2.2.

  α(x) is a candidate α-like comparison when the lognormal fits best (not yet computed
  per stratum).

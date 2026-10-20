# Point-cloud gap pipeline (`canopy.py`): review against plan.md, revision, testing, CHM comparison, scale-up

**Date:** 2026-10-20
**Reviewed:** `canopy.py` (CloudComPy exact C2C → fixed-grid voxels → 3D components) and
*How the canopy gap pipeline works* (Canopy_pipeline.docx)
**Against:** [plan.md](plan.md), ADRs 005–008, `derived/inventory/`

---

## 0. Verdict

The script handles the engineering well. It caches the distances by their inputs, writes
outputs atomically and never overwrites a run, keeps source provenance, uses a fixed world
grid, has a both-flights coverage mask and states its limitations honestly. It can carry
the **detection stage** of plan §2.3. In its current form it can't produce the gaps the
chapter's questions (Q1–Q7) are about. It has four scientific problems, ranked by how much
damage each could do to the chapter:

1. **One-way NN distance erodes every gap by the threshold.** This makes the detection floor
   depend on gap size and canopy height, which is exactly the artefact Q2 has to rule out (§2.1 below).
2. **There's no observability test.** "Absent in 2018" and "not seen in 2018" look the same,
   so the 3D sub-canopy claim, which is the method's selling point, can't be supported yet (§2.2).
3. **The threshold is fixed and the minimum gap size is set in points.** That builds the
   density and registration confounds of plan §4 into the gap set (§2.3, §2.5).
4. **The unit is a 3D "changed-return support volume", not a canopy gap.** The size-frequency
   analysis needs a 2D gap with a vertical criterion (absolute vs relative, §3.3) and a uniform area floor (§2.5).
   The 3D product should stay, as a second product (§2.4).

On scale, the script runs one study area as one cloud. Running it once per campaign pair
would cost about 2.4× the compute and count gaps twice (§4.1). It needs a tile scheme with a
cross-tile merge. The fixed voxel grid makes that merge straightforward.

---

## 1. Fit against plan.md, requirement by requirement

| Plan requirement | Script today | Action |
|---|---|---|
| §2.3 absolute point-wise distance as **detector** | Exact one-way pre→post C2C, no model, no cap | Keep. Add the observability flag (§2.2) and an edge-recovery step (§2.1) |
| §2.3 separate **signed** loss/gain classifier | None. One-way pre→post is loss-directional by construction but blind to gain, and regrowth can mask loss | Add optional post→pre pass. Classify a gap as loss / lateral shift / mixed from both directions (§2.6). Required before any 2018→2020 run |
| §2.4 **spatially varying threshold** (registration residual + density) | Global 2 m / 5 m | Per-cell LoD surface (§2.3) |
| §2.5 **uniform minimum gap size** (area) | `MIN_POINTS=10`, `MIN_VOLUME=0`, so the floor depends on density | Area floor in m², held constant across strata (§2.5) |
| §3.3 **vertical criterion**, absolute vs relative | `MIN_HEIGHT` only filters points | Column-level criterion, both variants (§2.4) |
| §3.6 **tiles**, buffered, cross-tile merge | Single cloud, CloudComPy uint32 limit | Core + buffer tiles, global relabel on fixed grid (§4.2) |
| §2.6 validation: synthetic insertion, split-cloud, stable surfaces | Ground C2C percentiles only | Hooks for point removal / cloud splitting; validation runs (§3) |
| Week 2 **registration** assessment | Ground C2C median 0.21 / 0.27 m used as evidence of alignment | Not sufficient; see §2.3. ICP on ground and hard surfaces, slope-stratified residuals |
| §2.10 **area accounting** per stratum, travels with run | `valid.npy` per point only. No usable-area output | Write common-support raster + per-stratum area table per run (§4.4) |
| §2.11 pre-interval **forest mask** (ADR 007) | None | Apply Hansen mask at the column stage; record masked area |
| A.3 **manifest**: git commit, package versions, checksums, config hash | Input signatures + config hash; no git/versions | Add commit, package versions, host, wall time |
| A.1 config in `config/base.yaml`, sensitivity YAMLs | Constants edited in the file | YAML config + CLI (`--config`, `--tile`), constants become defaults |
| ADR 008 covariates sampled per gap polygon | `gaps.gpkg` footprints exist | Compatible once footprints are 2D gaps in EPSG:32161 |

---

## 2. Scientific revisions

### 2.1 Edge erosion: the detection floor depends on size and stature

For a pre point at height *h* above the surviving 2018 surface, *r* metres inside a gap
edge, the nearest 2018 point is either the ground or understory beneath it (≈ *h*) or the
surviving crown at the edge (≈ *r*). So *d* ≈ min(*h*, *r*), and a point is detected only
if **both** *h* ≥ T and *r* ≥ T. Consequences at T = 5 m:

- A gap is detected only in its interior eroded by T. A circular gap of radius 5 m (~80 m²)
  is invisible. One of radius 10 m shows (1 − T/R)² = 25% of its area.
- Pre canopy lower than T above the post surface is never detected. South-coast dry forest
  (≈5–8 m stature) is close to undetectable at 5 m, whatever the gap size. This is plan §4
  confound 3 coming in through the distance metric rather than a height rule.
- Area loss scales with perimeter, so small gaps shrink proportionally more. That steepens
  the fitted exponent and can create a **breakpoint near (2T)²**, which is the artefact Q2
  has to rule out.

The doc's 2 m result, one 4.3 ha component via edge and corner contacts, is the other side of
the same problem: a low T recovers edges but chains openings together.

**Fix: hysteresis delineation.** Use a high cut to decide *that* a gap exists and a low cut
to decide *where its edge is*:

1. Seeds: changed, observable points with *d* ≥ T_seed (e.g. 3–5 m, or k₁·LoD).
2. Grow from seeds across adjacent columns whose upper-canopy pre returns have *d* ≥ LoD
   (local, ~0.5–1.5 m) **or** whose post top height has dropped by the vertical criterion (§2.4).
3. Edge position is then set at LoD scale, not T scale, and is directly comparable to a CHM edge.

Measure the residual erosion with synthetic insertion (§3.3). The detection function must
be flat in size above the area floor, or the floor has to go up.

### 2.2 Observability: separate "gone" from "not seen"

A pre point far from every 2018 return can mean the material was removed, or it can mean
the 2018 pulses never reached that height (occluded by refoliated canopy, a different scan
angle or lower density). The coverage mask (≥1 return of each epoch per 1 m column) can't
tell these apart. That's why the script records `vertical_observation: not_established`.

**Fix.** While streaming the post cloud, also accumulate a sparse **post voxel occupancy
table** (ix, iy, iz → count, on the same fixed grid), plus per-column min/max z and count.
For each pre point, define

- `observed_empty` = the post column (1 m, optionally a 3×3 neighbourhood) has returns
  **below** z_pre − δ. Pulses passed through that height in 2018 and found nothing near it.
- `occluded` = the post column's lowest return is above z_pre − δ. No evidence either way.

Only `observed_empty` points can seed or grow gaps. Report the occluded fraction per gap and
per stratum. It is itself a density/stature diagnostic. This costs one extra pass over the
post points that `stream_epoch` already makes. The same table gives post top height per
column for §2.4 at no extra cost.

The LAS files are point format 1 (GPS time, scan angle, return number), so scan angle can
also be stored per column if occlusion needs to be modelled rather than flagged.

### 2.3 Spatially varying LoD and registration

**Ground C2C isn't a registration estimate.** On flat, densely sampled ground the NN distance
is close to the vertical offset but blind to horizontal offset. Under canopy, sparse ground
inflates it. The 0.21 / 0.27 m medians rule out gross misregistration at 5 m. They don't
support a 1–2 m LoD on steep montane slopes, which is where plan §4 confound 1 lives.

Registration:
- Per campaign pair: ICP (CloudComPy `ICP`, rigid, ground class + roofs/roads) on a few
  stable patches spread across slope classes. Record the transform and residuals. Apply the
  transform via `POST_TRANSFORM`, which already exists and already checks rigidity.
- Residual surface: ground C2C binned by 25–50 m cell and by slope class (from the DTM),
  giving σ_reg(cell). Test whether σ_reg correlates with slope (week-2 item).
- Cross-check vertical offset by differencing the 2017 and 2018 published DTMs on flat, open ground.

LoD per cell:
- σ_spacing(cell): the no-change NN distance distribution at the local post density. The most
  direct estimate is the split-cloud null (§3.2): the 95th percentile of half-A→half-B
  distances, modelled as a function of post returns per column and height.
- LoD(cell) = k · √(σ_reg² + σ_spacing²), with k fixed at the freeze. Store LoD per coverage
  cell beside `coverage.npy`, and per point as `lod.npy`.

### 2.4 From 3D support volumes to 2D canopy gaps (plus the 3D product)

Q1–Q7 and the comparison literature need **2D gap polygons with an area**. Add a column
stage after voxelisation, on the 1 m grid the voxels already use. Snap `GRID_ORIGIN` to the
G-LiHT CHM pixel grid so columns and CHM pixels coincide.

Per column, compute: pre top height (max pre HAG), post top height (from the post occupancy
table), the fraction of pre returns in the upper canopy layer that changed and are observable,
and the depth of change.

**Gap column**, both criteria implemented, one chosen at the freeze (plan §3.3):
- *Absolute (Brokaw-comparable):* post top HAG < h_abs (2 m; 5 m as sensitivity) **and**
  the column is a change seed or is grown from one (§2.1).
- *Relative:* post top HAG < r · pre top HAG (e.g. r = 0.5, set at freeze) **and** seeded/grown.

Then 2D connected components (8-connectivity, 4 as sensitivity), the **area floor**
(§2.5), and the forest mask. Each 2D gap carries its 3D attributes (changed voxel volume,
HAG range of loss, observed/occluded fractions) from the voxels in its columns.

**The 3D product is kept separately:** changed, observable voxels whose columns are *not*
gap columns are crown or branch loss beneath a surviving canopy, which a CHM can't see.
This is the doc's main argument for the approach. It becomes a reportable quantity per
stratum: sub-canopy loss volume per ha, and its share of all changed volume. It shouldn't be
folded into the size-frequency distribution.

Note plan §2.3's warning: if "post top height dropped" ends up doing most of the delineation,
the method has quietly become CHM-based. The CHM comparison (§5) measures this directly. Report
the share of gap area that came from seeds/point growth vs from the height criterion alone.

### 2.5 Minimum gap size and connectivity

- Replace `MIN_POINTS` / `MIN_VOLUME` with `MIN_AREA_M2` on the 2D gap, uniform across
  strata, matched to the literature (candidates 10, 25 m²; decide with the detection
  function). Keep a points floor only as a noise guard on 3D components (expressed as
  returns per m² relative to local density, not an absolute count).
- Connectivity: 8 for 2D gaps, with 4 as a sensitivity run. The doc already shows 26- vs
  6-connectivity changing the largest gap's share of volume from 35% to 9% at 2 m. Report
  the equivalent for 2D gaps and LoD-based growth.

### 2.6 Signed classification

For 2017→2018, pre→post is already loss-directional. Add a post→pre pass (same code with the
epochs swapped, run on the same tile) to label each gap:
- **loss**: pre→post changed, post→pre quiet
- **lateral shift / lean**: both directions changed in adjacent voxels, so a crown moved
  rather than vanished
- **gain**: post→pre only. Irrelevant to Maria but the core of 2018→2020 (Q8–Q10)

This is the asymmetric-distance idea plan §2.3 rejected as a *classifier* because of density
sensitivity. Using it only to label already-detected gaps, with density handled by the LoD,
answers that objection. Write that into the ADR.

### 2.7 Smaller correctness items

- **CRS.** Every LAS checked is EPSG:32620 (UTM 20N) with no vertical key (LAS 1.1, format 1,
  0.01 m scale). The whole island in one zone means `inspect_headers` won't fail, but the
  western end is ~4° from the central meridian (≈0.2% linear, 0.4% area inflation, E–W
  systematic). Reproject points to **EPSG:32161** at read time (in `stream_epoch`, before
  voxelisation) so areas match the inventory and the covariates (ADR 008).
- **HAG and datum.** The README says G-LiHT DTMs are EGM96. LAS z has no declared datum. Add a
  check that HAG of class-2 points has a median within ±0.3 m of 0 per tile, and fail loudly
  otherwise.
- **DTM per campaign.** At scale, merge each campaign's DTM strips with `terra::merge`, **not
  a VRT** (README: NaN NoData). Alternatively compute HAG from the class-2 points in the
  cloud. `sample_hag` reads the whole band into RAM, which is fine per tile.
- **Swath edges.** Erode the common-support mask by LoD near the post coverage boundary.
  One post return in an edge column isn't support.
- **Noise.** G-LiHT classes appear to be mostly 1/2, so high noise may be unflagged. Add a
  HAG ceiling (e.g. > 1.5 × local p99 canopy height excluded).
- **Speed.** `_write_gpkg` rasterises gap by gap and `hull_volume` loops in Python. Fine for
  LFDP, slow for millions of gaps. Polygonise once from a label raster per tile. Make the
  convex-hull volume optional.

---

## 3. Testing and validation

### 3.1 Unit and regression tests (`tests/`, no CloudComPy needed except where noted)

- **Synthetic clouds with known answers.** Flat ground plus a box canopy, then remove a
  cylinder of radius R from the "post" copy. Assert the gap polygon area is within one pixel
  ring of πR² after hysteresis. Assert that without hysteresis it equals the eroded value
  (this documents §2.1). Include a multi-layer case: remove a crown above an intact
  understory and assert a 3D-only detection with no 2D gap.
- **Exact C2C cross-check** (CloudComPy): on a 1–5 M point subsample, assert CloudComPy
  distances equal `scipy.spatial.cKDTree.query` to 1e-4 m. This confirms "exact, no model"
  and the global-shift handling.
- **Observability:** synthetic occluder above a removed layer, so the points are flagged
  `occluded` and never seed.
- **Tiling invariance:** run one area as 1 tile and as 4 buffered tiles. Gap tables must be
  identical after the global merge (§4.2).
- **Grid alignment:** voxel columns coincide with CHM pixels, with no half-pixel shift.
- **Regression:** freeze LFDP outputs at each tagged version. Any change to `gaps.csv` has to
  be explained in the commit.

### 3.2 Nulls: false-positive rate by stratum

- **Same-epoch real null.** Find pairs of *2017* campaigns that overlap (e.g.
  `PR_17March2017_BG_north_high_alt` vs `..._low_alt`, and the EV1/EV2 reflights on different
  March dates). These are days apart, with real acquisition differences (altitude, density,
  scan geometry) and essentially no real change, so they're a better null than split-cloud.
  Running pre→pre-alt through the full pipeline gives false gaps per km² and false gap
  area fraction. *To do: intersect 2017 footprints with each other. The pairs table only has
  cross-epoch pairs.*
- **Split-cloud.** Split one epoch by alternating pulse (GPS time parity of first returns),
  then run half A → half B. It runs at half density, so treat it as an upper bound (plan
  §2.6). It also provides σ_spacing for the LoD (§2.3).
- **Stable surfaces.** Roofs and roads from OSM or the PR building footprints. Registration
  residuals only.
- Stratify all three by slope class, post density decile, canopy height class and forest type.

### 3.3 Synthetic gap insertion: the detection function

- On no-change forest (checked as quiet in the null), delete **post** points inside
  gap-shaped polygons (circles plus a library of real CHM gap shapes) at log-spaced areas
  of 5–5,000 m². Variants: (a) everything above 1 m removed, (b) upper canopy only,
  (c) "debris": keep 20% of removed points scattered below 3 m.
- To keep C2C runs few, pack many non-overlapping insertions per tile (spacing > 2 × buffer)
  and do one C2C run per tile per replicate.
- Run **both** the point method and the CHM method on the modified post cloud (the CHM is
  rebuilt from the modified points, §5.1 B2). Output P(detect | area, stratum) and the
  recovered area ratio, for each method.
- Decision rule (pre-registered): the area floor is the smallest area where P(detect) ≥ 0.9
  in **every** stratum. If that exceeds the literature floor, resolve per plan §2.5.

### 3.4 Independent checks

- **LFDP census:** compare gap polygons with post-Maria stem damage/mortality records in the
  16 ha plot (plan's field check).
- **Orthophotos:** G-LiHT publishes `photography/orthomosaic`, not in the current download
  set. Pull them for the prototype sites only and visually audit a stratified random
  sample of ~100 gaps and ~100 method disagreements.

---

## 4. Scaling to all campaign pairs

### 4.1 Unit of work: tiles, not pairs

From `pr_repeat_campaign_pairs.csv`: **415 Maria pairs ≥ 25 ha**, among **138** 2017 and
**103** 2018 campaigns, with **199,354 ha** of summed pair overlap against 83,713 ha of
tier-1 2017 + 2018 epoch overlap. Processing pair by pair would compute about 2.4× the
necessary area. It would also double-count gaps wherever two 2017 flights cover the same
ground, and mix densities wherever strips overlap.

So the unit is a **processing tile** (1 km core on the 32161 grid, buffer per §4.2). For
each tile:
1. From the tier-2 CHM footprints (`--refine repeat` must be run first, ~3 h), list the 2017
   and 2018 campaigns covering the tile.
2. Pick **one primary pre and one primary post campaign** per tile, by most coverage of the
   tile, then same block name (deliberate reflight), then closest flight altitude AGL (from
   the metadata PDFs). Fill uncovered columns from the next campaign, and record the source
   campaign per 1 m column.
3. Don't merge same-epoch campaigns into one cloud. That doubles density in overlaps and
   reintroduces confound 2.
4. Write `tiles.csv`: tile id, primary/secondary campaigns, input LAS files, expected area.
   This becomes the job list. Strips (`lXsY`) and tiles (`cXrY`) both resolve to file lists.

The per-column source campaign also allows a campaign-pair random effect in the stats.

### 4.2 Buffers and cross-tile merge

- Pre points from the **core** only. Post reference = core + buffer B (≈ 30–50 m). Run C2C
  with `maxSearchDist = B` and mark distances ≥ B as censored at B. Thresholds and LoDs are
  well below B, so no decision changes, and the doc's reason for not capping (seeing the
  largest losses) still holds for anything under B.
- The fixed grid makes the merge exact: each tile writes its changed voxels and gap columns
  in global indices. Merge by union-find over **tile-boundary columns only** (labels inside
  a tile are already final). That avoids one island-wide sparse graph, which could reach
  ~10⁸ voxels.
- Verify with plan §3.6: double the tile size on a test area and confirm the size
  distribution doesn't change.

### 4.3 Execution

- One task = one tile: `canopy.py --config config/base.yaml --tile <id>`. Each task writes
  into its own directory with a `done` marker (the atomic-directory code already handles
  this). Run as a job array or a restartable queue on the server, and resubmit after
  wall-time kills.
- The distance cache stays per tile and its key (`cache_id`) stays as is. Gap parameter
  sweeps (sensitivity block) then reuse distances, so a sweep costs minutes.
- Benchmark first (plan week 1): wall time and peak RAM per km² for C2C on LFDP and FIA12.
  Multiply by the tier-2 area of 2017×2018 overlap (README estimate ≈ 30,000–40,000 ha,
  ≈ 300–400 tiles of 1 km²). If it doesn't fit with three weeks of slack, use the
  stratified watershed sample (§3.1 of plan).
- Storage: LAS stays gzipped (503 GB). `.las.gz` streams without scratch, so only LAZ needs
  `SCRATCH`. Per-tile caches hold float64 xyz + c2c + flags ≈ 45 B/pre point. Delete
  `xyz.npy` after gaps are frozen, or store it as float32 offsets from the tile origin.

### 4.4 Run outputs (Appendix A.2)

`runs/<date>_<name>_<hash>/`: `config.yaml`, `manifest.json` (git commit, package versions,
inputs, wall time), `tiles/` (per-tile outputs + logs), `gaps/` (merged 2D gaps GPKG in
32161, 3D sub-canopy loss table, per-gap covariate keys), `area/` (common-support ∩ forest
mask ∩ scope raster at 1 m + per-stratum hectares, including occluded and masked area). The
area files are the denominator Q4 needs, so they're produced in the same run as the gaps.

### 4.5 Recovery interval

Same code with epochs `2018_post → 2020_recovery` (53 pairs, 47 ≥ 25 ha). It needs the
post→pre direction (§2.6) as a primary output. Gate it at week 9 per plan §2.2.

---

## 5. Comparison with CHM gap delineation (Q11)

### 5.1 Baselines

- **B1 published:** G-LiHT 1 m CHMs (max height), strips merged with `terra::merge`.
  Cheap, so run it **island-wide early**. It's the fallback chapter if the point method
  isn't defensible (plan §7, last row).
- **B2 rebuilt:** CHMs built from the *same* classified, reprojected, registered points
  (lidR, pit-free or p99 per 1 m), on the voxel column grid. B2 isolates the change signal
  from processing differences, and it's the only CHM that can be rebuilt after synthetic
  insertion.

CHM gap rules, using the same mask, common support, area floor and connectivity as the
point method:
- *Static post-gap, new since 2017:* post CHM < h_abs **and** pre CHM ≥ h_abs (Brokaw-style;
  e.g. ForestGapR `getForestGaps` on each date, then difference).
- *ΔCHM:* pre − post ≥ X m (absolute) **or** ≥ r · pre (relative, matching §2.4).
- *Optionally,* ΔCHM ≥ LoD_chm, with LoD_chm from the same null data, so the CHM method gets
  the same spatially varying treatment and the comparison is fair.

### 5.2 Metrics

- **Pixel level** within common support: agreement, Cohen's κ, and omission/commission
  of each method against the other, by stratum.
- **Object level:** match gaps by IoU ≥ 0.5. Classify each as matched, split (1 → n),
  merged (n → 1), point-only or CHM-only. Plot by log area bin.
- **3D-only share:** fraction of point-method changed volume under a surviving post canopy
  (CHM can't see this by construction).
- **Distribution level:** MLE fits (Clauset-style) of each method's gap areas. Compare the
  exponent at a common x_min and the breakpoint location, with the block bootstrap by tile.
- **Q11 consistency criterion (pre-register):** for each method, the between-stratum spread
  of (a) false-positive rate from §3.2 and (b) detection-function midpoint from §3.3. The
  point method is "more consistent" only if both spreads are smaller, with bootstrap
  intervals not overlapping.
- **Visual audit** of a stratified random sample of disagreements (ortho + 3D `gaps.laz`).

### 5.3 Prototype sites for comparison and freeze

LFDP and FIA12 (existing), plus 4–6 tiles chosen to span the confounds: dry forest
(low stature), steep wet montane (slope × registration), karst, lowland secondary forest,
and one high/low-altitude same-day pair (density). Pick them from `pr_repeat_tiles.csv` ×
the forest-type layer before looking at any gap output.

---

## 6. Sequence

Effort is in focused hours. "Plan wk" maps to plan.md §5.

| # | Step | Depends on | Effort | Plan wk |
|---|---|---|---|---|
| 1 | Move `canopy.py` into the repo (`py/` or `src/detect/`), YAML config + CLI, manifest additions, reprojection to 32161, HAG check | – | 6–8 h | 7 |
| 2 | Unit tests §3.1, including CloudComPy vs cKDTree | 1 | 6 h | 7 |
| 3 | Post occupancy table → observability flag + post top height (§2.2) | 1 | 6–8 h | 4 |
| 4 | Registration: ICP per pair, slope-stratified residuals, DTM differencing (§2.3) | 1 | 8–10 h | 2 |
| 5 | Split-cloud + same-epoch nulls on prototypes → σ_spacing, LoD surface (§2.3, §3.2) | 3, 4 | 10 h | 5 |
| 6 | Column stage: abs + relative criteria, hysteresis growth, 2D components, area floor, 3D sub-canopy product (§2.1, §2.4, §2.5) | 3, 5 | 12–15 h | 4 |
| 7 | CHM baselines B1 (island-wide) and B2 (prototypes) (§5.1) | – (B1), 1 (B2) | 8 h | 4–5 |
| 8 | Synthetic insertion, both methods → detection functions, area floor (§3.3) | 6, 7 | 12 h | 5 |
| 9 | Comparison metrics on prototypes (§5.2) | 6, 7, 8 | 8 h | 5–6 |
| 10 | **Pre-specification + freeze** (vertical criterion, k, floor, connectivity) | 5, 8, 9 | 4 h | 6 |
| 11 | Tile assignment from tier-2 footprints (§4.1), benchmark, scope decision | `--refine repeat`, 1 | 6 h | 3, 7 |
| 12 | Tiled batch run + cross-tile merge + area accounting (§4.2–4.4) | 10, 11 | 10 h + compute | 8 |
| 13 | Post→pre pass, signed labels; recovery interval if gate passes (§2.6, §4.5) | 12 | 6 h | 9 |

Steps 4, 7 (B1) and 11 don't depend on the script revisions and can run in parallel with 1–3.

**On timing.** By plan.md's calendar (start late August), today is about week 8–9, so the
week-6 freeze has passed on paper. If time is short, the order to cut is: recovery interval
(13) → B2 beyond two sites → same-epoch null beyond one pair. Keep §2.1 (erosion) and §3.3
(detection function) whatever else goes. Without them Q2 has no answer.

---

## 7. Open questions

1. **Is the 3D product a headline or a supplement?** The doc frames 3D as the reason for the
   method. The plan's questions are all 2D size-frequency. This plan treats 3D sub-canopy
   loss as a separate reported quantity. If it should be a headline, it needs its own
   question in plan.md and its own null.
2. **Compute.** Which server and scheduler (paths suggest `/workdir`, `/ibstorage`), how many
   cores and how much RAM per node, any wall-time limit. This sets the tile size ceiling.
3. **Has anything been frozen?** If thresholds were already fixed in a dated pre-spec, LoD
   and hysteresis are a change that needs its own dated ADR.
4. **Forest-type layer** (plan §3.2): decided yet? Prototype selection (§5.3) depends on it.

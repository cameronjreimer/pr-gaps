# Scaling gap delineation to every 2017 → 2018 campaign on the HPC

**Date:** 2026-11-02
**Scope:** the Maria interval (2017_pre → 2018_post). The 2018 → 2020 recovery interval reuses
everything here with the epochs swapped (§9).
**Builds on:** [point-gaps-plan.md](point-gaps-plan.md) §4, ADRs [006](decisions/006-repeat-coverage-definition.md),
[007](decisions/007-forest-mask-source.md), [009](decisions/009-gap-definition-rule.md);
`python/README.md` (cluster setup, `run_canopy.sbatch`)

---

## 1. The job

| | 2017 | 2018 |
|---|---|---|
| Campaigns (in a pair with ≥ 25 ha overlap) | 138 | 103 |
| LAS files | 1,772 | 1,295 |
| Compressed LAS | 275 GB | 228 GB |
| Points (at EV1's 63 M points per GB) | ~17 billion | ~14 billion |
| Scheme | 125 strip (`lXsY`), 13 tiled (`cXrY`) | 98 strip, 5 tiled |

- **Overlap where both flights have CHM data:** 58,801 ha (`pr_repeat_summary_chm.csv`).
  That's 64× EV1's 926 ha. All 241 campaigns already have exact CHM footprints.
- **Campaign pairs:** 415, many-to-many (a median of 3 pairs per 2017 campaign). Summed pair
  overlap counts much of the ground two or three times.
- **2017 points to analyse:** at EV1's density, roughly 12–18 billion in the overlap, before
  removing ground flown twice.

What EV1 (untiled, 711 M points read) showed:

- **Reading compressed LAS was the slowest predictable step:** about 25 min, roughly 0.5 M
  points/s for one job.
- **The distance step needs 2017 points to have 2018 data nearby.** Points hundreds of
  metres from any 2018 return stalled it for hours. With the overlap study area, the run
  finished.
- **Peak memory was 48 GB untiled.** A 1 km tile needs a few GB.

## 2. Problems the prototype layout doesn't solve

1. **Strip files span many tiles.** 223 of 241 campaigns ship one file per flight strip,
   which can run for kilometres. A gzip file can't be read part-way, so a tile job would
   decompress every strip that touches it in full. A strip crossing 10 tiles would be
   read 10 times (plus neighbours for buffers). **Fix: retile once (§4.2).**
2. **Overlapping flights.** Where two 2017 campaigns cover the same ground, using both would
   count gaps twice and double the point density (confound 2). **Fix: each location gets
   exactly one 2017 → 2018 pair (§4.1).**
3. **Gaps crossing tile edges.** Per-tile labelling with per-tile minimum-size filters would
   split and drop edge gaps. **Fix: label after merging (§4.5).**
4. **Storage.** The prototype cache costs ~68 bytes per 2017 point, about 0.9 TB
   island-wide (§6).
5. **One global labelling step won't fit.** LFDP has 7,500 changed voxels per ha at 3 m.
   Island-wide that's ~440 M voxels at 3 m and ~1 billion at 2 m, too many for one sparse
   graph. **Fix: label per tile, then join across tile edges (§4.5).**

## 3. Decisions needed before building

| # | Decision | Recommendation | Why it has to come first |
|---|---|---|---|
| D1 | What 2018 information beyond the distances is needed (point-gaps-plan §2.2, §2.4)? | **Settled (2026-11-03).** 2018 canopy height, and observability above the 2018 canopy, come from the published 1 m 2018 CHM (compare each 2017 point's absolute z with CHM + 2018 DTM = DSM). **Observability under a surviving canopy**: step 1 now records the lowest 2018 return per 1 m column everywhere (`post_lowest_z.npy`; no measurable time, ~4 B/column, ~2–3 GB island-wide). The 26 m `height_pct` / density metrics are covariates (stature, penetration), too coarse for per-point observability | The observability rule itself (how far below counts, own column or neighbours) is a step-2 choice. If it enters the gap definition, ADR 009's tests must run with it, so decide before M3 |
| D2 | Cap the C2C search at the buffer width B (e.g. 50 m), flagging capped distances? | **Settled (2026-11-03): cap at 50 m**, implemented (`MAX_SEARCH_M`). Points with no 2018 return within 50 m get exactly 50.0; `check_run.py` reports their share | Tested: below the cap, distances match uncapped to float32 rounding; on LFDP (max 14.9 m) the capped distances are byte-identical. A synthetic case with points ~850 m from data ran in 0.15 s capped vs 11.4 s uncapped. Uncapped caches (LFDP, EV1) are still accepted for capped runs |
| D3 | Pair priority for overlapping flights (§4.1) | **Settled (2026-11-17): the default ranking** `-same_block,-overlap_ha,days_between` (same block name first, then larger pair overlap, then fewer days between flights), approved after review of the plan's `pairs` map. Flight altitude isn't in the inventory, so it isn't used | Decides which 2017 flight represents each location. The partition itself is cheap to recompute (vector work, minutes). Changing it after M4 means re-running step 1 for every unit whose pair changes; retiled buckets are per campaign and unaffected. Settle before M4 |
| D4 | Keep `source_c2c.bin` (CloudCompare file)? | **Settled (2026-11-03): dropped** (`SAVE_CC_BIN = False`) | A CloudCompare-format copy of the 2017 cloud with its distances, for viewing in the CloudCompare GUI. It duplicates `xyz.npy` + `c2c.npy`; nothing reads it. ~20 B/point (LFDP cache 642 → 461 MB), ~0.3 TB island-wide |
| D5 | Point labels for sensitivity runs | **Settled (2026-11-03): keep the distance caches, and point labels for every threshold run** | Storage is not limiting. The caches (per-point distances) are what allow any threshold to be computed later; labels are per-threshold outputs (4 B/point, ~54 GB each), recomputable from the caches in minutes per unit |
| D6 | ADR 009 tests (null, 25 ha windows) | Run during §7 milestones M1–M3 | Step 2's primary threshold is chosen by them; step 1 doesn't depend on them |
| D7 | Flagged pairs from island QC (§4.7, 2026-11-18) | **Settled (2026-11-18).** Rank 5 (`PR_14March2017_FIA11 → PR_28April2018_FIA11`): the lowest 2018 return in each column sat 42.00 m below the 2017 ground (EV1: −0.18 m), matching Puerto Rico's ~42 m geoid separation, so 2018 FIA11 is almost certainly in ellipsoidal heights. It is corrected by a constant **+41.82 m**, recorded in `derived/registration/vertical_offsets.csv` and applied by `units.py` to that campaign's 2018 points; only the affected units rebuild. The 16 other flagged pairs (ground C2C median 0.5–1 m, or ground height off ±0.3 m) are **kept and flagged**. `main_pair_flags` / `main_pair_flagged` are carried into the gap table, and one flagged pair goes into ADR 009's noise test in M3; M3 decides whether any are corrected or excluded. **Final (user, 2026-11-21): all 16 kept and flagged; none corrected or excluded.** Results are reported with and without them. The M3 noise test did not reach a flagged pair in any useful amount: only rank 149, as one EV1-null unit with 0.12 ha covered by both flights. 0.04% of 2 m gaps lie on flagged pairs | Rank 5 would otherwise make nearly every point a change. The moderate pairs matter at 2 m more than at 3 m, which ADR 009's noise test measures |

## 4. Design

### 4.1 Work units: one pair per location, cut into 1 km tiles

1. **Partition the overlap by pair.** Rank the 415 pairs by D3. The first pair owns its CHM
   overlap polygon, and each later pair owns its overlap minus everything already owned.
   The result is a set of non-overlapping pieces that together cover the 58,801 ha, each
   labelled with one 2017 campaign and one 2018 campaign.
2. **Cut into tiles:** a 1 km grid in EPSG:32620 (the LAS CRS) with edges on whole metres,
   so 1 m voxels never straddle a tile edge. Ownership is half-open
   (`xmin ≤ x < xmax`, `ymin ≤ y < ymax`), so each point and voxel belongs to exactly one
   tile.
3. **A work unit is one tile × one pair piece.** It records the tile ID, the pair, its piece
   polygon (core ∩ piece) and its area. Most tiles have one unit; tiles where ownership
   changes have two or three.
4. **Per unit:** analyse only the 2017 points of its 2017 campaign inside its polygon. Use
   as reference that pair's 2018 points within the polygon's bounding box + B, not clipped
   to the piece, as at LFDP.

Output: `work_units.gpkg` (polygons + attributes) and `work_units.csv`, which is the job
list. Map it and check it before anything runs.

**Built (`python/plan_units.py`, 2026-11-03).**
- **How ownership works:** each 1 m column goes to the best-ranked pair whose CHM overlap
  contains the column's centre. These are the same cells `canopy.py` uses for coverage.
  The rule is stored as per-tile ownership rasters (`ownership/<tile>.tif`, uint16 pair
  rank). A unit takes the 2017 points whose column it owns, so no point can fall into two
  units, even on a polygon boundary.
- **Outputs:** the unit polygons in `work_units.gpkg` are drawn from those rasters. Units
  go to `$PR_GAPS_DATA/interim/work_units/`.
- **Run time:** under 4 minutes locally.

First plan, with the default ranking (`-same_block,-overlap_ha,days_between`):

| | |
|---|---|
| Units | 2,440 units in 1,821 tiles. 1,444 tiles have one unit; at most 9 units share a tile |
| Pairs | 225 of the 415 pairs own ground. Same-block pairs own 54,770 ha |
| Unit size | median 15.6 ha. 480 units are under 1 ha (151 ha in total) |
| Coverage | 58,944.4 ha against the both-flights CHM overlap of 58,947.8 ha (both in EPSG:32620), a 3.4 ha shortfall |
| EV1 | `PR_5March2017_EV1 → PR_25April2018_EV1` owns all 926.18 ha of the untiled `ev1` study area, in 19 units |

- **Coverage shortfall:** the 3.4 ha are pairs under 25 ha plus 1 m rasterising.
  Measured in EPSG:32161, as in `pr_repeat_summary_chm.csv`, the same area is 0.25%
  smaller (58,800.9 ha).
- **The M2 test:** at the study-area edge, the untiled run clipped points to the polygon,
  while units clip by column centre. The tiling-invariance comparison should therefore
  drop the boundary columns.
- **Small units:** most of the units under 1 ha are real coverage edges, where only one
  pair has data. Folding them into another pair in the same tile (tried 2026-11-04)
  removed only 22 of the 377 multi-unit tiles, even at 10 ha. Instead, the planner packs
  units into array tasks of about `--job-ha` hectares (default 100), by pair and then by
  tile. This gives 764 tasks with a median of 2 units and 76 ha each. The `job` column of
  `work_units.csv` is the Slurm array index.
- **Pair borders:** there are about 251 km of borders between pairs inside tiles. That's
  an overestimate, because the 1 m cells turn diagonal edges into staircases. They fall
  in 335 tiles, and at most ~2,500 ha (4%) lie within 50 m of one. A gap that crosses a
  border is measured with different flights on each side.
  - **Detection can differ:** density, scan angle and registration all change at the
    border.
  - **Dates differ:** the two sides can have different flight dates.
  - **Possible seams:** a pair-level offset could show up as a straight-line seam in the
    gap map.
  - **Planned checks:**
    - record each gap's pair(s) and a `crosses_pair_border` flag;
    - QC the ground C2C median per pair;
    - in M3, run the lower-ranked pair over a strip of the higher pair's ground where
      both have data, and compare the two gap maps (a between-flight null, like ADR
      009's same-epoch null);
    - compare gap fractions in bands on either side of each border.
- **Altitude isn't available yet:** the "closer flight altitude" tie-breaker in D3 isn't
  in the inventory; it's only in the metadata PDFs. Add it as a column of `pairs.csv` and
  name it in `--rank`.

### 4.2 Retile once

*Design detailed 2026-11-16.*

**What it does.** A Slurm array runs one task per LAS file. Each task streams its file
once and writes the points into 1 km buckets per campaign. A unit then reads only the
buckets it needs, instead of whole strip files that can run for kilometres.

**Built (2026-11-16).** `python/retile.py`.
- **Commands:** `retile.py <campaign>/<file>` for a task, `--list-tasks` for the
  pending Maria files (3,067 in all), and `--check [--deep] CAMPAIGN`.
- **Tested locally:** on Guayama (2 strips) and EV1 c4r2.
  - Every dimension of every point is bit-identical to the raw file, matched through
    `source_index`.
  - Every point is in the right tile.
  - `--check --deep` finds each record exactly once.
  - Rerunning skips files that are done.
- **Speed:** ~1.2 M points/s on one core (33.4 M points in 30 s). That's ~7 CPU-hours
  island-wide.
- **Size:** ~6.3 bytes per point as LAZ, ~195 GB island-wide.

- **Scope: every LAS file of the Maria campaigns** (241 campaigns, 3,067 files), whether
  or not the current plan uses them.
  - This keeps the buckets independent of the pair ranking (D3), so re-ranking never
    means retiling again.
  - It costs a little disk for ground no pair owns. The quota isn't limiting.
- **Tiles:** the same 1 km grid as the work units, in EPSG:32620 with half-open edges:
  `tile = floor(x / 1000), floor(y / 1000)`. Every point lands in exactly one tile.
- **No write collisions:** neighbouring strips of one campaign cover the same tile. If
  tasks shared one file per tile, they would write to it at the same time. Instead each
  task writes its own part per tile:
  ```
  $PR_GAPS_DATA/interim/retiled/<campaign>/<tile>/<source-file-stem>.laz
  ```
  A unit reads every part in its tile folder.
- **Points and attributes kept:**
  - every point and every class, unchanged. The noise filters (classes 7/18) stay
    where they are now, in `canopy.py`;
  - the source point format, scale and offset, so coordinates are bit-identical to the
    raw file. The M2 tiling test depends on that;
  - two extra-byte fields, `source_file` (the file's index in a per-campaign file
    list, `retiled/<campaign>/files.csv`) and `source_index` (the record number in
    that file). These are what `canopy.py`'s cache stores, so per-unit caches keep
    pointing at the original LAS files. `check_run.py --compare` and the
    duplicate-point check depend on them.
- **Format:** LAZ through `lazrs`, written in chunks, with one writer open per tile the
  file touches (typically 5–30 for a strip).
- **Done marker:** each task writes `retiled/<campaign>/done/<source-file-stem>.json`
  last. It holds the source file's signature (size, mtime), its header point count, and
  the points written per tile. A resubmitted array skips files whose marker matches.
  A killed task leaves no marker, and its parts are overwritten on the rerun.
- **Checks:**
  - per file, the points written sum to the header count;
  - per campaign, the bucket totals equal the sum over its files;
  - `source_index` runs 0…n−1 exactly once per file, so no point is lost or duplicated.
- **Compute:** about 31 billion points at ~0.5 M points/s is ~18 CPU-hours. As an array
  (1 CPU, 4 GB per task) that's a few tens of minutes.
- **Disk:** ~250–310 GB on project storage (§6). It can be regenerated from `raw/`.
  Delete it after M5.

### 4.3 Per-campaign DTMs (for height above ground)

*Design detailed 2026-11-16.*

**What it does.** It gives each 2017 campaign a single DTM file. Height above ground
comes from the 2017 campaign's own DTM, as in the prototype. The inventory has a DTM for
all 114 2017 campaigns that own ground: one file each, 5.8 GB compressed in total.

| Campaign type | Count | DTM file | Preparation |
|---|---|---|---|
| Tiled (`cXrY`) | 12 | `lidar/geotiff/<campaign>_DTM.tif.gz`, already one mosaic | used as is (the download unzips it) |
| Strip (`lXsY`) | 102 | `lidar/geotiff/<campaign>_DTM.tar.gz`, one DTM per strip, plus a mosaic unless pruned | merge the strips, even when a published mosaic is there |

**Built (2026-11-16).** `python/campaign_dtm.py`. It's in Python rather than R, so the
cluster needs one environment, and its NaN handling is explicit.
- **Merge rule:** each cell takes the first strip, in file-name order, with a finite
  value. This is `terra::merge`'s rule. Strips that disagree where they overlap are
  counted.
- **Packed archives:** an archive the download left packed is unpacked next to it, and
  the archive is kept.
- **Output:**
  - merges go to `$PR_GAPS_DATA/interim/dtm/<campaign>_DTM.tif` (float32, `NaN`
    no-data, tiled, deflate);
  - `interim/dtm/index.csv` maps each campaign to the DTM to use, along with its valid
    cells and conflicts;
  - a campaign whose sources haven't changed is skipped on rerun.
- **Tested locally:** on 6 campaigns.
  - The merges of Guayama and campaign 53 match the published mosaics cell for cell,
    with identical valid cells, bounds and values.
  - The packed archive of campaign 111 unpacked and merged.
  - No strips overlapped or conflicted.
- **Published mosaics can't be trusted.** The mosaic of
  `PR_17March2017_BG_north_high_alt` is entirely NaN for every product (CHM, DTM, slope,
  aspect), while its 10 strips hold 6.3 M valid cells. That's 1 of the 10 campaigns with
  mosaics on disk locally. Hence the rule above: merge whenever strips exist, use a
  mosaic only when there are none, and fail on a DTM with no valid cells.
  The covariate helpers in `R/ingest/08_gliht_rasters.R` (`gl_gliht_raster`,
  `gl_chm_for_rugosity`) used to prefer the mosaic, and fell back to a VRT. Since
  2026-11-16 they follow the same rule through `gl_strip_raster`, using `terra::merge`,
  and stop on a raster with no data.
  - Tested: BG_north_high_alt now gives 6,293,522 DTM cells, the same as
    `campaign_dtm.py`.
  - Guayama's merged CHM matches its mosaic exactly.

- **Not a VRT:** G-LiHT stores no-data as `NaN`, which a VRT turns into data (README).
- **The 2018 DTMs aren't needed.** `sample_hag` reprojects points if a DTM's CRS
  differs.
- **Checks:**
  - every 2017 campaign with owned ground has a row in the index;
  - valid cells = summed strip valid cells − overlap (reported per campaign);
  - in step 1, the ground-return HAG median per unit is within ±0.3 m.
- **DTMs on the cluster:** `check_download.py --products dtm` (built) reports each 2017
  campaign as `mosaic`, `strips`, `archive` or missing. Fetch missing ones with
  `scripts/02_download.R --download all --products dtm`.

### 4.4 Step 1 per unit (`canopy.py --job`)

*Design detailed 2026-11-16.*

**Built (2026-11-17).** `python/units.py`, run as `canopy.py --job N` or `--unit ID`.
`canopy.py`'s `stream_epoch` gained two things: a domain given as a function (the
owned-column test) and a `keep` box for the reference. It also reads `source_file` /
`source_index` from bucket points.

The retiled parts carry no CRS record, so units use EPSG:32620 explicitly, the plan's
CRS.

Tested locally on the LFDP unit (`E0202_N2028_p030`, 95.3 ha, job 515):
- **Results:** 31.5 M 2017 points, 99.9% covered, no distance at the cap, ground HAG
  median +0.04 m.
- **Comparison:** `check_run.py units/E0202_N2028_p030 --compare lfdp` matched all
  9,036,855 LFDP points, with identical distances (max |difference| 0.000 m). That's the
  step-1 tiling test at LFDP scale.
- **Rerun:** reuses the cache in seconds.
- **The full M2 step-1 test** is `python/check_tiling.py <site>`. It matches every 2017
  point of the site cache with the pair's unit caches, by original file and record.
  - **Checks:** no point in two units; identical distances (site distances capped at
    50 m, like the units'); and no point inside the study area present on one side
    only. Points in columns touching the study-area boundary are reported separately.
  - **Local result:** passed for LFDP (`--units E0202_N2028_p030`) in 45 s.
  - **Cluster:** run it as `check_tiling.py ev1` for EV1's 19 units.
- **Time:** 14.7 min on 8 threads for 31.5 M points. Scaled to ~17 billion 2017 points,
  that's ~1,000 CPU-hours, or ~6–7 h at 20 jobs of 8 CPUs. That's longer than §5's
  estimate from the untiled run, because each unit reads a 50 m ring of 2018 points from
  neighbouring tiles. The M3 pilot measures it on the cluster.

**What it does.** It extends the current single-site run: same distance code, same cache
format and provenance. Only the inputs change, from site lists to plan units.

- **Invocation:**
  - `canopy.py --job N` runs every unit whose `job` is N in `work_units.csv`, one after
    another. This is the step-1 array.
  - `canopy.py --unit <id>` runs one unit, for debugging.
  - The plan directory comes from `PR_GAPS_PLAN` (default
    `$PR_GAPS_DATA/interim/work_units`).
- **2017 points:** the parts in `retiled/<campaign_pre>/<tile>/`. A point is kept if its
  1 m column `(floor(x), floor(y))` holds this unit's rank in `ownership/<tile>.tif`.
  The ownership mask replaces the prototype's study-area polygon, so ownership is exact
  at pair and tile edges.
- **2018 reference:** the parts in `retiled/<campaign_post>/<tile>/` for every tile that
  the unit's cell bounds plus 50 m (B) touch, usually 1–4 tiles. They are clipped to that
  box, not to the owned columns, so edge points find their true nearest 2018 neighbour,
  as in the prototype.
- **Coverage:** 1 m cells with both 2017 and 2018 returns of this pair, restricted to the
  unit's owned columns. Summed over units, this is the island's analysed area and the
  denominator for area accounting (§4.6).
- **Unchanged from the prototype:**
  - exact C2C capped at 50 m (D2);
  - the lowest 2018 return per column, kept for owned columns only;
  - HAG from `interim/dtm/<campaign_pre>_DTM.tif`.
- **Cache:** `$PR_GAPS_DATA/runs/canopy/units/<unit>/cache/`. Its identity adds three
  things to the current config hash:
  - the unit's pair and cell bounds;
  - a hash of its own owned-column mask, not the whole plan;
  - the signatures of the bucket parts it read.

  Re-ranking pairs (D3) then invalidates only the units whose columns actually changed.
  A complete cache is skipped on rerun.
- **Provenance:** `source_file` / `source_index` come from the bucket extra bytes and
  are mapped back to the original LAS paths. A unit cache therefore looks like a
  prototype cache, and `check_run.py` and `--compare` work on it unchanged.
- **Failures within a job:**
  - each unit is written atomically, as now;
  - if one unit fails, the job logs it, carries on with the rest, and exits non-zero at
    the end. A resubmit reruns only the incomplete units.
- **Edge cases:**
  - **No 2017 points in the owned columns** (a sliver at a data hole): write a complete
    cache with zero points, so it isn't retried forever.
  - **No 2018 return within 50 m:** points get 50.0 (D2), as now.
- **Resources:** 8 CPUs and 16 GB per task to start (§5). The pilot (M3) measures actual
  use.
- **The M2 test:** run tiled EV1, i.e. the 19 units of the EV1 pair (rank 30), and
  compare with the untiled `ev1` cache using `check_run.py --compare`. Leave out columns
  on the edge of the old study-area polygon, because the prototype clipped by polygon
  and units clip by column centre. Pass: every other shared point has the same distance
  to float32 rounding (≤ 1 mm), and no point is missing or appears twice.

### 4.5 Step 2: per unit, per tile, then joined

*Design detailed 2026-11-16.*

**Built (2026-11-17).** `python/island_gaps.py` (`voxels`, `label`, `join`, `points`,
`run`), registered in `status.py`, and `python/subset_plan.py` for test plans.

Tested locally on two neighbouring EV1 units (`E0202_N2028_p030`, `E0203_N2028_p030`),
against `canopy.analyze_threshold` run on both units' points as one cloud:
- **Gaps:** the same 11,615 gaps at 2 m (36 of them span both tiles) and 3,264 at 5 m
  (4 span both), with the same IDs.
- **Attributes:** identical to about 10⁻¹⁰ m (float summation order). The footprint
  polygons' areas equal `footprint_area_m2`.
- **Point labels:** every one identical.
- **Bug found and fixed:** two labels of one tile can share columns and still join
  through another tile. The join now counts multi-tile gaps' columns from a per-label
  column list (`columns.parquet`), instead of summing per-label counts.
- **Against LFDP's own run:** `check_tiling.py lfdp --gaps c2599daebbaa973e --island …`
  reproduced 2,035 of 2,131 gaps at 2 m and 469 of 491 at 5 m point for point. Every
  other gap touches the study-area edge; none differ away from it.
- **Speed:** `label` took ~1–2.5 min per tile for two thresholds, so roughly 4–5 min per
  tile for four.

**Decisions (2026-11-16):**
- **Pair borders:** a gap crossing one stays one gap. It records its pairs and a
  `crosses_pair_border` flag.
- **Edge gaps:** a gap cut off at the edge of the data is kept and flagged.
- **Island-wide outputs:** footprint polygons only. The convex-hull volume
  (`gap_volume_m3`) and the gap LAZ are dropped island-wide. The occupied-voxel volume
  stays. The prototype sites keep both, and gap LAZ can be made on demand for chosen
  tiles.

**Fixed by ADR 009 and D5:**
- **Thresholds:** voxel exports cover all four candidates, {2, 3, 4, 5} m, so the
  primary run and every sensitivity run (T ± 1, 6-connectivity, the extent product at
  2–3 m) come from the same exports.
- **Gap rules:** 26-connectivity, plain connected components, `MIN_POINTS` = 10, and the
  classes 2/7/18 excluded, as in the prototype.
- **Point labels:** kept for every threshold.
- **The seeded split:** run only on the 25 ha windows and on blocks that fit in one job.

#### Stages

| Stage | Array over | Reads | Writes |
|---|---|---|---|
| 2a. Unit voxels | step-1 jobs (764) | the unit cache | per-unit voxel tables, one per threshold; per-unit coverage columns |
| 2b. Tile labels | tiles (1,821) | the tile's unit voxels; coverage of the 3 × 3 tiles around it | local labels, per-label partial sums, edge voxels, footprint pieces |
| 2c. Join | one job per threshold | every tile's edge voxels and partial sums | global gap IDs, the gap table, footprint GeoPackages |
| 2d. Point labels | step-1 jobs (764) | the unit cache, the tile labels, the ID map | per-unit point labels with global gap IDs |

Outputs go under `$PR_GAPS_DATA/runs/canopy/island/<run-id>/`. The run ID hashes the
settings, the code version and the plan, as the prototype's run IDs do. Each stage writes
a done marker per task, so resubmits only run what's missing.

#### 2a. Unit voxels

- **Which points are changed:** at threshold T, a 2017 point is changed if it is
  covered, not class 2/7/18, and its distance is ≥ T. These are the same eligibility
  rules as `_eligibility`.
- **Voxels:** global 1 m indices, `(ix, iy, iz) = floor(xyz)` (origin 0,0,0), stored as
  int32. A column belongs to exactly one unit, so no voxel ever appears in two units and
  tile tables can simply be concatenated.
- **Per voxel and threshold:**
  - the point count;
  - the sum and max of the distances;
  - the count, sum, min and max of the heights above ground;
  - the sums of point x, y and z, measured from the tile corner so the sums stay
    precise.

  Every gap attribute is either a sum, a min or a max of these, so gap values combine
  exactly across tiles.
- **Coverage:** the unit's covered 1 m columns go into `coverage/<tile>.tif` (uint8),
  merged across all units in the tile. Stage 2b uses this to tell where the data ends.

#### 2b. Tile labels

- **Labelling:** concatenate the tile's unit voxels and label them with the existing
  26-connected `_components`. A tile at 2 m holds ~1–2 M voxels, a few seconds of work.
  The size filter is *not* applied yet: a small piece here may be part of a big gap in
  the next tile.
- **Per local label:**
  - partial sums: points, voxels, centroid sums, distance and height sums, min and max,
    bounds;
  - the number of footprint columns;
  - points per pair, so a gap knows which flights measured it.
- **Edge voxels:** voxels in the outermost ring of columns on each of the tile's four
  sides, with their local labels. With 26-connectivity, a voxel touches the 8
  neighbouring tiles, the diagonal ones included, so the corner columns matter.
- **Coverage edge:** a gap's column touches the edge of the data when one of its 8
  neighbouring columns in xy is uncovered. This is read from the 3 × 3 coverage tiles,
  so it works across tile edges. Record `edge_columns` per label.
- **Footprint pieces:** polygonise each label's occupied columns within the tile.

#### 2c. Join (one job per threshold)

- **Edges:** for each pair of tiles sharing a side or a corner, match their edge voxels
  with 26-connectivity. Each match links (tile, label) to (tile, label).
- **Union-find** over those links gives one global gap per connected group. This scales
  with tile-edge length (~1,821 tiles × ~4,000 edge columns), not with the island.
- **Global IDs:** gaps are numbered in a fixed order, by their lowest (ix, iy, iz) voxel,
  as `_number_by_first_cell` does. The same inputs therefore always give the same IDs.
  IDs are uint32, with 0 meaning "no gap".
- **Gap attributes:** combine the partial sums by global ID. Means come from summed sums
  and counts, and min, max and bounds combine directly. The result matches the
  prototype's attributes, except `gap_volume_m3`, which is dropped.
- **Pairs:** `n_pairs`, `main_pair_rank`, `main_pair_share` (the share of points from the
  main pair) and `crosses_pair_border` (true when `n_pairs` > 1).
- **Edge flag:** `touches_coverage_edge` and `edge_columns`.
- **Then the size filter:** gaps with fewer than 10 points are removed after the join,
  so a big gap cut by tile edges is never dropped piece by piece.
- **Summary:** per threshold, the number of gaps, the total voxel volume and the largest
  gap's share. The same summary is reported per 25 ha window for ADR 009's separation
  test.

#### 2d. Point labels

For each unit and threshold, map every changed point to its gap's global ID through
voxel → local label → global ID. Points in gaps removed by the size filter get 0. Write
`units/<unit>/labels_<T>m.npy` (uint32, aligned with the unit cache). That is ~4 bytes
per 2017 point per threshold, as in D5.

#### Exports

- **`gaps.parquet` per threshold:** the island-wide gap table, one row per gap.
- **Footprint GeoPackages per threshold:** one file per 2017 campaign block, with gaps
  assigned by their main pair. Footprints of gaps that cross tiles are dissolved from
  their pieces. They stay in EPSG:32620 with the same layer name (`footprints`) and
  attributes as now, so `scripts/04_gap_covariates.R` reads them unchanged.

#### Checks

- **Conservation:** per threshold, the points and voxels summed over all gaps (before
  the size filter) equal the totals summed over the unit voxel tables. The labelled
  points in 2d equal the gap table's point total.
- **No duplicates:** each (tile, label) maps to exactly one global gap.
- **The M2 test (with the step-1 test in §4.4):** run tiled EV1 through step 2 and
  compare with the untiled `ev1` gaps at 2 m and 5 m. Leave out gaps that touch the old
  study-area edge. Every other gap must have the same voxels, point count and attributes;
  only its ID may differ. This proves that a gap cut by tile edges is put back together
  exactly.

#### Resources (estimates until M3)

- **2a and 2d:** 2 CPUs and 8 GB per job.
- **2b:** 1–2 CPUs and 4 GB per tile.
- **2c:** 8 CPUs and up to 64 GB. About 8–9 M gaps at 2 m if EV1's density (133,765
  gaps on 926 ha) holds island-wide.

### 4.6 Post-processing (masking after C2C)

- **Forest fraction per gap:** C-CAP 2010 per ADR 007 (chosen 2026-11-23; Hansen kept for sensitivity). This
  extends `scripts/04_gap_covariates.R` with the pre-registered keep rule (e.g. forest
  fraction ≥ 0.5).
- **Covariates per gap:** via the existing script.
- **Area accounting:** both-flights coverage (from per-unit coverage cells) ∩ forest mask,
  per forest type. This is the denominator for gap density and damage per hectare
  (plan §2.10). It also records the area each step removes.
  - **Inputs:** the per-tile coverage rasters from step 2a (1 m, covered or not), the
    ownership rasters (which pair), the forest mask (Hansen per ADR 007, C-CAP for the
    comparison) and the forest-type layer the covariate script already uses
    (`interim/holdridge`).
  - **Method:** per tile, resample the mask and forest types to the 1 m grid by
    nearest neighbour, then count columns per pair × forest type × mask class. Sums
    are exact, because each column is owned once.
  - **Output:** `areas.csv` with one row per pair × forest type. Columns:
    - `owned_ha`, the work-unit area;
    - `covered_ha`, with both flights' returns;
    - `forest_ha`, covered and forest under Hansen;
    - `forest_ccap_ha`, covered and forest under C-CAP.

    Each column is the area left after one step, so the table records what each step
    removes. Summed by forest type, it gives the denominators.
  - **Script:** `python/area.py`, one job, run after `voxels`. It doesn't need the gap
    outputs.
  - **Built (2026-11-17)** as the workflow stage `area`, which runs after `step1`.
    - **Inputs:** coverage comes from the unit caches. Masks and zones are sampled at
      each column's centre: Hansen and C-CAP at 30 m, and Holdridge zones rasterised at
      10 m.
    - **Masks:** Hansen forest = treecover2000 ≥ `--treecover` (default 30%, ADR 007's
      placeholder) with no loss in 2001–2016. C-CAP forest = codes 9, 10, 11, 13, 16.
      Both are recorded, along with their intersection and union.
    - **Outputs:** `runs/canopy/area/<id>/areas.csv` (pair × forest type) and
      `areas_by_unit.csv`.
    - **Tested:** on the two EV1 units, 154.6 ha owned and 152.4 ha covered, in about
      2 s per unit (~1.5 h island-wide).

### 4.7 Quality control

- **Per unit:** `check_run.py` checks, plus the ground HAG median (±0.3 m) and the ground
  C2C median.
- **Island-wide:**
  - no `(file, record)` appears in two units;
  - per-unit 2017 point counts sum to the bucket totals;
  - every work unit has a complete cache and exports.
- **Maps:**
  - ground C2C median per tile (registration problems show up as blocks);
  - gap area fraction per tile;
  - the share of the largest gap per tile.
- **Spot checks:** a few dozen of the largest gaps against orthophotos.
- **Built (2026-11-17):** `python/island_qc.py`, the workflow stage `qc`.
  - **How it runs:** it reads each unit cache once, in parallel, and keeps 50,000
    sampled ground returns per unit for the pooled pair and tile figures.
  - **Output:** `runs/canopy/qc/<plan id>/`. Gap maps are added for every threshold
    whose join is finished. Run it after step 1 for the registration checks, and again
    after step 2.
  - **Dropped:** the "unit points sum to bucket totals" check, because units take only
    owned columns. The duplicate check (no record in two units, campaign by campaign)
    covers the same failure.
  - **Tested:** on the two EV1 units, both PASS. The EV1 pair's ground C2C median is
    0.21 m and its height median about 0, so nothing is flagged.
- **The island QC report** (`python/island_qc.py`, the last stage) collects all of the
  above into `qc/` under the run directory:
  - **`units.csv`:** the per-unit `check_run.py` results, one row per unit, with
    PASS/WARN/FAIL per check. It is the same check code, run on each unit cache.
  - **`pairs.csv`:** registration per pair: the ground-return C2C median and p95, the
    ground HAG median, the share of distances at the 50 m cap, and covered hectares.
  - **`tiles.gpkg`:** one polygon per tile, carrying the map values above. The gap
    fraction and largest-gap share come per threshold.
  - **`checks.txt`:** the island-wide checks, namely the conservation checks of §4.2
    and §4.5, no `(file, record)` in two units, and every task done with one code
    version.
- **Flags:** QC flags without excluding anything; excluding a pair or tile is a decision
  recorded in the plan, not something a script does.
  - **Registration:** a pair whose ground C2C median is over 0.5 m, or whose ground HAG
    median is outside ±0.3 m. For scale, LFDP and EV1 were 0.20–0.21 m and −0.05 m.
  - **Missing data:** a unit with more than 1% of its distances at the cap.
- **When to decide:** before the island-wide results are examined (M5). The
  between-flight test at pair borders (§4.1) reports here too, as `borders.csv`.

## 5. Slurm layout

Each stage is a job array (or a single job), chained with `--dependency=afterok`. Each
task is restartable through a done marker: a complete cache manifest or a finished
output. The files that run them are described in §5.1.

| Stage | Array over | Resources per task (estimate, set by M3) | Wall time |
|---|---|---|---|
| 0. Plan units | – (one job) | 4 cores, 16 GB | < 1 h |
| 1. Retile | 3,067 LAS files | 1 core, 4 GB | minutes each |
| 1b. DTM mosaics | 114 2017 campaigns | 1 core, 8 GB | minutes each |
| 2. Step 1 | 764 packed jobs (2,440 units) | 8 cores, 16 GB | minutes each |
| 3a. Unit voxels (2a) | 764 step-1 jobs | 2 cores, 8 GB | minutes |
| 3b. Tile labels (2b) | 1,821 tiles | 1–2 cores, 4 GB | seconds–minutes |
| 4. Join + exports (2c) | one job per threshold (4) | 8 cores, 64 GB | < 2 h |
| 4b. Point labels (2d) | 764 step-1 jobs | 2 cores, 8 GB | minutes |
| 5. Post-processing | blocks | 4 cores, 16 GB | < 1 h |

- **Nodes** (`sinfo`, 2026-11-03): partition `R128C40` (default) has 8 nodes with 40 CPUs
  and 128 GB each; `R256C128` has 2 nodes with 128 CPUs and 257 GB each. Neither has a
  time limit. On an `R128C40` node, cores bind before memory: at 8 cores and 16 GB per
  step-1 task, 5 tasks fit (80 GB). If the whole cluster were free, that would be 40 tasks
  on `R128C40` plus 32 on `R256C128`. The cluster is shared, so plan for less. Put the
  untiled or join jobs that need more than ~120 GB on `R256C128`.
- **Array limits** (`scontrol`, `sacctmgr`, 2026-11-03): `MaxArraySize` = 30001 (task IDs
  0–30000) and `MaxJobCount` = 50000 cluster-wide. There are no per-user `MaxJobs` /
  `MaxSubmit` limits. Every stage fits in one array (the largest is the 3,067-file
  retile). Use `--array=1-N%M` anyway to stay a good neighbour on a shared cluster:
  start with `%20` for step 1 and raise it if the queue is empty.
- **Benchmark:** `sacct` per stage gives time and memory per unit, which updates the table.
  - **Measured on the island run (M3, 2026-11-20).** These figures replace the estimates
    below. Sources: `status.csv` and `sacct` for the final arrays of plan `833917a203ca7ff1`
    (retile 793818; step1 797101/797294/798194; area 798184; voxels 798253; label 798254;
    join 798255; points 798256; qc 798257). Every task completed. Peak RSS is per task,
    from the `.batch` step.

    | Stage | Tasks | Requested | Wall median / p95 / max | Peak RSS median / p95 / max |
    |---|---|---|---|---|
    | retile | 3,066 | 1 CPU, 4 GB | 27 s / 62 s / 170 s | – / 0.45 / 0.51 GB |
    | step1 (≈3.2 units per job) | 764 | 8 CPUs, 16 GB | 164 s / 378 s / 861 s | 2.0 / 4.5 / 7.1 GB |
    | voxels | 764 | 2 CPUs, 8 GB | 67 s / 118 s / 241 s | 0.7 / 1.8 / 4.1 GB |
    | label | 1,821 | 2 CPUs, 4 GB | 40 s / 111 s / 202 s | 0.3 / 0.8 / 1.4 GB |
    | join (2 / 3 / 4 / 5 m) | 4 | 8 CPUs, 64 GB | 16.2 / 9.1 / 7.9 / 6.9 min | 22.8 / 10.9 / 6.1 / 3.7 GB |
    | points | 764 | 2 CPUs, 8 GB | 69 s / 115 s / 241 s | 0.7 / 1.7 / 3.5 GB |
    | area | 1 | 2 CPUs, 16 GB | 22.7 min | 1.1 GB |
    | qc | 1 | 8 CPUs, 64 GB | 48.2 min | 14.0 GB |

    - Per unit, step 1 takes 73 s median (p95 154 s) of an 8-CPU job.
    - Step 1 for the island took 287 allocated CPU-hours, against the 720 estimated
      below. CPU efficiency was a median 1.45 of 8 CPUs.
    - Every request is at least 2× the observed peak. `join` stays on `R128C40`: its peak
      is 23 GB at 2 m, far below ~120 GB.
    - `config.sh` could tighten some requests (step1 12 GB, join 48 GB, voxels/points
      1 CPU). It was left unchanged because the user decides that, and the cluster clone
      should not diverge.
  - **Untiled EV1** (job 792239, 2026-11-03): 926 ha, 16 CPUs, steps 1 and 2 in one job.
    It took 42 min and peaked at 42.8 GB. That is about 0.73 CPU-minutes and 46 MB per
    hectare.
  - **A 1 km² unit with a 50 m buffer** (121 ha read) scales to ~6 GB and ~5 min on 16
    CPUs. The 16 GB request leaves room for denser forest.
  - **Island scale:** 58,801 ha at that rate is about 720 CPU-hours. That is roughly 18 h
    on one `R128C40` node, or 4–5 h on four.
  - **Caveats:** these figures are an upper bound for step 1. The run read whole EV1
    files beyond the overlap, and they include step 2. The `EV1` backfill of the lowest
    2018 returns (job 792463) took 8.5 min and 3.4 GB.
- **Scheduler:** plain Slurm arrays with dependencies are enough. Snakemake would add file
  tracking but isn't needed at this size.

### 5.1 Workflow files

*Design detailed 2026-11-16.*

**Built (2026-11-16)** for the stages that exist (`retile`, `dtm`). The other stages are
listed, and submitting one reports "not built yet". Tested locally by running tasks
through `stage.sbatch` the way Slurm does:
- logs and attempt records were written per task;
- a failing task was recorded with its exit code;
- after two failures, `status.py --pending` held it back, and `--retry-failed` let it
  through;
- a `submit.sh --dry-run` built the right `sbatch` lines (3,064 pending retile tasks,
  `%40`).

Two differences from the design below:
- **Location:** task lists, logs, attempt records and `status.csv` live under
  `$PR_GAPS_WORKFLOW` (default `$PR_GAPS_DATA/workflow/`), not in a run directory.
- **Attempt records:** `stage.sbatch` appends a start record and an end record
  (exit code, commit, log) per task to `attempts/<stage>/<task>.jsonl`. `status.py`
  reads them alongside each stage's done markers.

```
workflow/
  config.sh        paths (PR_GAPS_DATA, PR_GAPS_GLIHT, PR_GAPS_PLAN), the run's thresholds,
                   and per-stage CPUs, memory, --time and concurrency (%M)
  env.sh           sourced by every stage: gcc/15.2.0, LD_LIBRARY_PATH, headless Qt,
                   the code-version check (§5.2)
  stage.sbatch     one generic array script: `stage.sbatch <stage>` runs task N from
                   tasks/<stage>.txt through the stage's command
  submit.sh        `submit.sh <stage>...` or `submit.sh all`: writes the pending task
                   lists and submits the arrays, chained with --dependency=afterok
python/status.py   reads the done markers of every stage → status.csv and a summary
```

- **Tasks are named, not numbered.** Before submitting, `status.py --pending <stage>`
  writes `tasks/<stage>.txt`: one unfinished task key per line (a LAS file, campaign,
  job number, tile or threshold). Array index N runs line N. A resubmit therefore covers
  only what's missing, and its indices never point at finished work.
- **Commands per stage:**

  | Stage | Task key | Command |
  |---|---|---|
  | `plan` | – | `plan_units.py` (run once by hand; a new plan needs `--force`) |
  | `retile` | LAS file | `retile.py <file>` |
  | `dtm` | 2017 campaigns | `campaign_dtm.py` (one job) |
  | `step1` | job number | `canopy.py --job N` |
  | `voxels` | job number | `island_gaps.py voxels --job N` |
  | `label` | tile | `island_gaps.py label --tile T` |
  | `join` | threshold | `island_gaps.py join --threshold T` |
  | `points` | job number | `island_gaps.py points --job N` |
  | `qc` | – | `island_qc.py` (§4.7) |

- **Chaining:** `retile` and `dtm` run side by side. Then `step1` → `voxels` → `label` →
  `join` → `points` → `qc`, each with `afterok` on the previous array. If any task fails,
  the next stage doesn't start. Fix the failure and run `submit.sh` again, and it resumes
  from the first unfinished stage.
- **Concurrency to start with:** `retile` %40 (I/O-bound), `dtm` %20, `step1` %20,
  `voxels` and `points` %40, `label` %80, `join` 4. Everything runs on the default
  `R128C40` partition. `join` moves to `R256C128` only if M3 shows it needs more than
  ~120 GB.
- **Time limits:** the partitions have none, so every stage sets `--time` at ~3× its
  expected task time (e.g. 4 h for `step1`). A hung task then fails visibly instead of
  holding a slot for days.
- **Retries:** none automatic. A failed task shows in `status.csv` with its log path,
  and the next `submit.sh` reruns it. A task that has failed twice is listed separately,
  so it gets investigated rather than resubmitted again.
- **Logs:** `logs/<stage>/<task-key>.<jobid>_<index>.out`, one per task, under
  `$PR_GAPS_WORKFLOW`.
- **`status.csv`:** one row per stage and task, with the state (done, failed, pending,
  running from `squeue`), the code version that produced it, its wall time and peak
  memory from `sacct`, and the log path. The same numbers feed the benchmarks in this
  section.

### 5.2 Code on the cluster

- **The cluster's `pr-gaps/` folder is a clone of the GitHub repo**
  (`cameronjreimer/pr-gaps`), as is the local one (confirmed 2026-11-16). Code reaches
  the cluster by committing and pushing here, then `git pull` there.
- **Version check:** `env.sh` refuses to start a stage if `python/`, `scripts/` or
  `workflow/` have uncommitted changes, and records `git rev-parse HEAD`.
- **Provenance:** that commit is written into every cache manifest, done marker and run
  ID. `status.py` flags any stage whose tasks were produced by more than one commit, so a
  mid-stage code change is caught before the outputs are combined.
- **The `.venv`** stays outside git, built by `init_env.sh` as now. `check_env.py` runs
  at the start of each stage.

## 6. Storage

| What | Size (estimate) | Where |
|---|---|---|
| Raw LAS | 503 GB | `/ibstorage/cam/G-LiHT/data/raw/gliht` (full download done), read-only |
| Retiled buckets | 250–310 GB | **project storage**, not scratch: the scratch purge policy is unknown, and losing the buckets mid-run would mean retiling again. Delete them after M5 |
| Per-unit distance caches | ~0.65 TB (~48 B/point; no `.bin`, D4) | project storage; expensive to recompute |
| Lowest 2018 return per column | ~2–3 GB | inside each cache |
| Point labels, every threshold run (D5) | ~54 GB per threshold | project storage |
| Voxel tables, all thresholds | tens of GB | project storage |
| Gap tables, GeoPackages, area accounting | a few GB | project storage, backed up |

The quota is not limiting (confirmed 2026-11-03). Total is about 1.5–2 TB with the
sensitivity set.

## 7. Milestones and gates

| # | Milestone | Gate before moving on |
|---|---|---|
| M0 | Done. D3 settled 2026-11-17. Done 2026-11-03: array limits and nodes read (§5); all 3,067 LAS files present (`check_download.py`). D1, D2, D4, D5 and storage are settled | – |
| M1 | Work-unit plan (§4.1) built and mapped | Units cover 58,801 ha exactly once; no 2017 location in two units |
| M2 | Retile, per-unit step 1, per-unit step 2 and join implemented | **Tiling invariance on EV1:** tiled EV1 reproduces the untiled `ev1` run. **Passed 2026-11-17** on the cluster: `check_tiling.py ev1` (step 1: identical distances, every point in exactly one unit) and `check_tiling.py ev1 --gaps e2adac6119af3dc7 --island dd6164997a92c379` (step 2 at 2 m and 5 m: every gap away from the study-area edge is the same set of points) |
| M3 | Pilot: 2–3 blocks, ~50–100 units in different forest types; same-epoch null; ADR 009's 25 ha windows | Per-unit time and memory benchmarked; null and windows give the ADR 009 values → ADR Accepted. **Tools built 2026-11-20:** `python/windows.py` (`select`, `null`, `report`); windows and nulls run as small plans through the same workflow (§7.1). **Done 2026-11-20/21:** windows and both nulls run; the report showed no candidate passing all tests (ADR 009 *Outcome*). The user chose T = 3 m on 2026-11-21, and ADR 009 is Accepted. Benchmarks are in §5 |
| M4 | Full step 1 (all units) | Every unit complete; QC maps (ground C2C per tile) show no registration blocks. **Done 2026-11-19:** all 764 jobs; QC 2,257 PASS / 138 WARN / 45 FAIL units (all DTM / height-above-ground, not registration); rank 5 corrected (D7) and verified after the rerun (ground_dz −0.18 m, ground C2C median 0.30 m, unflagged); 16 moderate pairs flagged; no 2017 record in two units; 55,763.9 of 58,944.4 owned ha covered |
| M5 | Step 2 + join: primary threshold, then the ADR 009 sensitivity set | `check_run`-style consistency; largest gap per tile within the separation test. **Run 2026-11-20** at all four candidates (2–5 m, island run `df81889aa38eecef`), since step 2 is cheap and the ADR picks among them. Only counts were checked (gaps fall with threshold; 0.04% of gaps on flagged pairs). **The gap results are not examined until ADR 009 is Accepted** (Accepted 2026-11-21, T = 3 m). **Consistency checks run 2026-11-21:** 0 FAIL. The checker is `/workdir/cr657/m3/check_island.py`, which is not in the repo. Results:
- **Completeness:** every unit, tile and join is complete, all from one commit (c2ba04f).
- **Conservation:** points and voxels match exactly across units, tile labels and join at all four thresholds, and the 3 m point labels equal the gap table's 1,450,667,656 points.
- **No duplicates:** object IDs are unique (1..1,805,219).
- **Attributes:** all sane. 11 gaps have no height above ground.
- **Thresholds:** gaps, points and voxels fall as T rises.
- **Separation per 1 km tile (3 m, gaps assigned by volume centroid):** 559 of 1,720 tiles pass, holding 31% of gap volume. The median largest-gap share is 15.3%.
  - The largest gap is 194 ha (7.67 M m³, 2.3% of island gap volume), on pair 19 (FIA36).
  - The biggest gaps are canopy-level sheets about 3.5 m deep, with mean HAG around 18 m, on unflagged pairs: widespread crown loss joined into one component, not ground or registration error.
  - Caveat: a gap spanning several tiles is counted whole in its centroid tile.
- **Flagged pairs:** 823 gaps (0.05%) lie on them. |
| M6 | Post-processing: forest mask, covariates, area accounting | Masked area per forest type recorded; mask comparison (ADR 007) written up. **Built 2026-11-21:** `gap_covariates.py` for the 3 m gap objects (§8). **Run 2026-11-23:** all 1,805,219 gaps, under commits 66a5734 and 4a4a2d5 (an int-cast fix for 66 tiles). **Mask chosen by the user on 2026-11-23: C-CAP 2010, keeping gaps with `forest_ccap_frac` ≥ 0.5** (ADR 007 *Outcome*). That keeps 85.9% of gaps and 92.4% of gap volume, but only 60.0% of gaps in dry forest. Area denominators use `forest_ccap_ha`. Gap-size fits are reported with and without the largest objects (ADR 009 *Outcome*) |

M4 can run while M3's ADR is being finalised, since step 1 doesn't depend on the threshold.

### 7.1 M3: windows and nulls (`python/windows.py`)

- **Windows** (`windows.py select`, run once): every 500 × 500 m quarter of a plan tile
  is a candidate. It is eligible when one pair owns ≥ 99% of it and no other pair owns any;
  the pair isn't QC-flagged and its unit passed QC; ≥ 80% is forest (Hansen or C-CAP, as
  `area.py`); and ≥ 90% lies in one stratum's Holdridge zones. Strata: dry (Subtropical
  Dry), moist (Subtropical Moist), wet (Subtropical Wet and Rain), montane (Lower Montane
  Wet and Rain). Three windows per stratum (EV1 excluded), at most one per pair, none
  touching another, plus three in EV1; seeded random draw (seed 20170920). It reads no
  gap output. A local trial on the plan (QC ignored) found 4 eligible dry windows in 3
  pairs, 9 montane in 4, and about 100 each for moist and wet: dry forest is thin because
  Hansen and C-CAP count little of the dry zone as forest. Decided 2026-11-20: dry uses the
  same rules as every stratum (three drawn from those eligible), not a lower forest share.
- **Nulls** (`windows.py null NAME PRE POST`): the plan's units whose 2017 flight is PRE,
  with another 2017 flight (POST) in place of the 2018 one. Same 2017 points, ownership and
  settings, so the null and Maria runs label the same points and are compared over the
  1 m columns both cover. Two: `ev1` (`PR_5March2017_EV1` vs `PR_15March2017_EV1`, 9 units)
  and `fia18` (`PR_12March2017_FIA18` vs `PR_14March2017_FIA18`, 46 units, another forest
  and block).
- Each is a plan folder run with `PR_GAPS_PLAN` and its own `PR_GAPS_WORKFLOW`. Unit IDs are
  prefixed (`W01_`, `null-ev1_`), so their caches never replace the full run's.
- **`windows.py report`** writes `runs/canopy/adr009/`: the largest gap's share of gap
  volume per window and threshold (separation), and null ÷ Maria gap area per threshold
  (noise), against the two limits.
Primary island-wide gap results (M5) are only examined after ADR 009 is Accepted.

## 8. Code to write

| Piece | Where | Notes |
|---|---|---|
| Work-unit planner | `python/plan_units.py` | **Done.** Footprints and pairs from `derived/inventory/` (§4.1) |
| Retiler | `python/retile.py` | **Built.** One LAS file per task (§4.2) |
| DTM mosaics | `python/campaign_dtm.py` | **Built.** §4.3; one job (114 small rasters) |
| Per-unit mode for `canopy.py` | `canopy.py` (`--job`, `--unit`) → `python/units.py` | **Built.** §4.4. Reuses `prepare` / `analyze_threshold`; ownership-mask clipping; bounding-box reference. The search cap (D2), dropped `.bin` (D4) and lowest 2018 return (D1) are already in `canopy.py` |
| Step 2: unit voxels, tile labels, join, point labels | **Built.** `python/island_gaps.py` (`voxels --job N`, `label --tile T`, `join --threshold T`, `points --job N`) | §4.5. Reuses `_components`, `_number_by_first_cell` and the attribute code from `canopy.py` |
| Area accounting | `python/area.py` | **Built.** §4.6. Coverage columns × pair × forest type × mask |
| Workflow + status | `workflow/` (`config.sh`, `env.sh`, `stage.sbatch`, `submit.sh`), `python/status.py` | **Built** for `retile` and `dtm` (§5.1). A stage is added by giving it a command in `stage.sbatch` and a task list and done test in `status.py` |
| QC report | `python/island_qc.py` | **Built.** §4.7. Reuses `check_run.py`'s checks per unit; pair, tile and island-wide tables |
| ADR 009 windows and nulls | `python/windows.py` | **Built.** §7.1. `select`, `null`, `report` |
| DTM check | `check_download.py --products dtm` | **Built.** §4.3 |
| Forest mask + covariates per gap | `python/gap_covariates.py` (`tile --tile T`, `combine`); workflow stages `gapcov` (per tile) and `gapcovjoin` | **Built 2026-11-21.** §4.6, M6. Every gap column is sampled at its centre, as `area.py` does. Per gap: forest fractions (Hansen at treecover 10, 30 and 50%; C-CAP; union and intersection at 30), Holdridge, C-CAP, GAP and Helmer modes, PRISM, and from the column's own 2017 campaign elevation, slope, aspect, CHM and 41 m rugosity. `combine` also writes `mask_comparison.csv` (ADR 007). No keep rule is applied. Tested on the window plan (15 tiles, 14,028 gaps, footprints match the gap table); 4–13 s and under 1 GB per tile |

**Build order:**
1. `check_download.py --products dtm` (built);
2. `retile.py` and `campaign_dtm.py` (built);
3. `canopy.py --job` (built; LFDP comparison passed) → **M2 step-1 test on EV1** (on the cluster);
4. `island_gaps.py` → **M2 step-2 test on EV1**;
5. `workflow/` and `status.py` (built). Each new stage is added to them as it is built;
6. `area.py` and `island_qc.py` (built), before M4.

## 9. Afterwards: the recovery interval

The same pipeline runs with 2018_post → 2020_recovery (53 pairs, 47 with ≥ 25 ha). It needs
the post→pre direction for gain (point-gaps-plan §2.6) and falls under the week-9 gate
(plan §2.2). The work-unit planner and retiled 2018 buckets are reused.

## 10. Open questions

Known (2026-11-03):
- Nodes and array limits are in §5.
- The storage quota is not limiting.
- The full download is in `/ibstorage/cam/G-LiHT/data/raw/gliht`, and `check_download.py`
  passes.
- The scratch purge policy is unknown, so nothing irreplaceable goes there.

Planning is complete as of 2026-11-16: every stage has a design, in §4.1–4.7 and §5.

Decisions still open. None blocks building M2.

1. **D3, the pair ranking:** settled 2026-11-17 (the default ranking; §3).
2. **Observability rule:** settled 2026-11-20. It does **not** enter the gap definition:
   gaps stay pure C2C, and observability (from the lowest 2018 return per column, D1) is
   reported per gap as a covariate or flag. So ADR 009's tests don't depend on it.
3. **ADR 009:** Accepted 2026-11-21 with T = 3 m for gap objects (the user's choice after M3: no candidate passed every test; see the ADR's *Outcome*). History:
   - the two 10% limits: confirmed 2026-11-20;
   - choose the 25 ha windows per forest type, dry forest included, before looking at
     their gaps;
   - set up the same-epoch null (`PR_5March2017_EV1` vs `PR_15March2017_EV1`). All of
     this happens in M3.
4. **The between-flight test at pair borders** (§4.1): which strip to use and what
   counts as a pass. Design it with M3.
5. **Flagged pairs** (§4.7, D7): rank 5 is corrected (+41.82 m). **Settled
   2026-11-21 (user):** the 16 moderate pairs are kept and flagged, with none corrected
   or excluded. Results are reported with and without them (`main_pair_flagged`).
   - No flagged-pair noise test was possible. Rank 149 was the only flagged pair in
     either null: one unit with 0.12 ha covered by both flights.
   - The decision rests on their small share: 0.04% of 2 m gaps.
6. **Benchmarks:** the untiled EV1 figures are in §5. M3 replaces them with per-unit
   measurements.

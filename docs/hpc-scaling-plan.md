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
   split and drop edge gaps. **Fix: label after merging (§4.4).**
4. **Storage.** The prototype cache costs ~68 bytes per 2017 point, about 0.9 TB
   island-wide (§6).
5. **One global labelling step won't fit.** LFDP has 7,500 changed voxels per ha at 3 m.
   Island-wide that's ~440 M voxels at 3 m and ~1 billion at 2 m, too many for one sparse
   graph. **Fix: label per tile, then join across tile edges (§4.4).**

## 3. Decisions needed before building

| # | Decision | Recommendation | Why it has to come first |
|---|---|---|---|
| D1 | What 2018 information beyond the distances is needed (point-gaps-plan §2.2, §2.4)? | **Settled (2026-11-03).** 2018 canopy height, and observability above the 2018 canopy, come from the published 1 m 2018 CHM (compare each 2017 point's absolute z with CHM + 2018 DTM = DSM). **Observability under a surviving canopy**: step 1 now records the lowest 2018 return per 1 m column everywhere (`post_lowest_z.npy`; no measurable time, ~4 B/column, ~2–3 GB island-wide). The 26 m `height_pct` / density metrics are covariates (stature, penetration), too coarse for per-point observability | The observability rule itself (how far below counts, own column or neighbours) is a step-2 choice. If it enters the gap definition, ADR 009's tests must run with it, so decide before M3 |
| D2 | Cap the C2C search at the buffer width B (e.g. 50 m), flagging capped distances? | **Settled (2026-11-03): cap at 50 m**, implemented (`MAX_SEARCH_M`). Points with no 2018 return within 50 m get exactly 50.0; `check_run.py` reports their share | Tested: below the cap, distances match uncapped to float32 rounding; on LFDP (max 14.9 m) the capped distances are byte-identical. A synthetic case with points ~850 m from data ran in 0.15 s capped vs 11.4 s uncapped. Uncapped caches (LFDP, EV1) are still accepted for capped runs |
| D3 | Pair priority for overlapping flights (§4.1) | Same block name first, then larger pair overlap, then closer flight altitude. **Under review** | Decides which 2017 flight represents each location. The partition itself is cheap to recompute (vector work, minutes). Changing it after M4 means re-running step 1 for every unit whose pair changes; retiled buckets are per campaign and unaffected. Settle before M4 |
| D4 | Keep `source_c2c.bin` (CloudCompare file)? | **Settled (2026-11-03): dropped** (`SAVE_CC_BIN = False`) | A CloudCompare-format copy of the 2017 cloud with its distances, for viewing in the CloudCompare GUI. It duplicates `xyz.npy` + `c2c.npy`; nothing reads it. ~20 B/point (LFDP cache 642 → 461 MB), ~0.3 TB island-wide |
| D5 | Point labels for sensitivity runs | **Settled (2026-11-03): keep the distance caches, and point labels for every threshold run** | Storage is not limiting. The caches (per-point distances) are what allow any threshold to be computed later; labels are per-threshold outputs (4 B/point, ~54 GB each), recomputable from the caches in minutes per unit |
| D6 | ADR 009 tests (null, 25 ha windows) | Run during §7 milestones M1–M3 | Step 2's primary threshold is chosen by them; step 1 doesn't depend on them |

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

### 4.2 Retile once

A Slurm array over the 3,067 LAS files. Each job streams one file once and writes its points
into per-campaign 1 km buckets: `$SCRATCH/retiled/<campaign>/<tile>.laz` (LAZ via `lazrs`).
It keeps only the attributes the pipeline uses: xyz, classification, and return number and
scan angle in case D1 is adopted. A unit then reads its 2017 bucket and the 3 × 3 2018
buckets around it.

- **Compute:** about 31 billion points at ~0.5 M points/s is ~18 core-hours, a few tens of
  minutes as an array.
- **Disk:** ~250–310 GB of LAZ on scratch. It can be regenerated from `raw/`.
- **Checks:** per-file point counts in = out, and no point written twice.

### 4.3 Step 1 per unit

`canopy.py --unit <id>`: an extension of the current single-site run, with the same cache
format and provenance.

- **2017 points:** the unit's bucket, clipped to its polygon with the half-open tile rule.
- **2018 reference:** the 3 × 3 buckets, clipped to the polygon's bounding box + B.
- **Distances:** C2C as now, capped at B if D2 is adopted.
- **HAG:** from that 2017 campaign's DTM. Merge its strips with `terra::merge` once per
  campaign, not with a VRT (README: NaN no-data).
- **Caching:** one cache per unit; a unit with a complete cache is skipped on rerun.

### 4.4 Step 2: per unit, then joined

1. **Per unit:** write changed voxels in global indices at every threshold in the run
   (primary plus sensitivity set): per-voxel point counts at each threshold, distance and
   HAG sums, min and max. No labelling or size filters yet.
2. **Label within each tile** using the existing labelling code.
3. **Join across tile edges:** compare only voxels in the outermost layer of each tile with
   their neighbours across the edge. Union-find over (tile, local label) pairs gives global
   gap IDs. This scales with tile-edge length, not with the island.
4. **Gap attributes:** combine per-tile partial sums by global ID. Means come from summed
   counts and sums. Only gaps that cross a tile edge need their voxels gathered for
   footprint and convex-hull volume.
5. **Apply the minimum-size filters** to the joined gaps.
6. **Exports:**
   - one GeoPackage of gap footprints per campaign block, reprojected to EPSG:32161 for the
     covariate scripts;
   - LAZ per tile;
   - the global gap table as Parquet.
7. **The seeded split** (an ADR 009 sensitivity run) needs growth across tile edges. Run it
   only on the prototype windows and whole blocks that fit one job, not island-wide.

### 4.5 Post-processing (masking after C2C)

- **Forest fraction per gap:** Hansen per ADR 007, plus C-CAP for the comparison. This
  extends `scripts/04_gap_covariates.R` with the pre-registered keep rule (e.g. forest
  fraction ≥ 0.5).
- **Covariates per gap:** via the existing script.
- **Area accounting:** both-flights coverage (from per-unit coverage cells) ∩ forest mask,
  per forest type. This is the denominator for gap density and damage per hectare
  (plan §2.10). It also records the area each step removes.

### 4.6 Quality control

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

## 5. Slurm layout

Six stages, each a job array chained with `--dependency=afterok`. Each array task is
restartable through a done marker: a complete cache manifest or a finished output.

| Stage | Array over | Resources per task (estimate, set by M3) | Wall time |
|---|---|---|---|
| 0. Plan units | – (one job) | 4 cores, 16 GB | < 1 h |
| 1. Retile | 3,067 LAS files | 1 core, 4 GB | minutes each |
| 2. Step 1 | ~1,000–1,500 units | 8 cores, 16 GB | minutes each |
| 3. Step 2 per unit | units | 2 cores, 8 GB | minutes |
| 4. Join + exports | one job per threshold | 8 cores, 64 GB | < 2 h |
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
- **Logs:** one log per task, named by unit ID.
- **Status:** a `status.csv` built from the done markers shows what's left. Resubmitting
  a stage only runs unfinished tasks.
- **Benchmark:** `sacct` per stage gives time and memory per unit, which updates the table.
- **Reuse:** every task loads the GCC module, sets `LD_LIBRARY_PATH` and uses headless Qt,
  as in `run_canopy.sbatch`.
- **Scheduler:** plain Slurm arrays with dependencies are enough. Snakemake would add file
  tracking but isn't needed at this size.

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
| M0 | D3 reviewed. Done 2026-11-03: array limits and nodes read (§5); all 3,067 LAS files present (`check_download.py`). D1, D2, D4, D5 and storage are settled | – |
| M1 | Work-unit plan (§4.1) built and mapped | Units cover 58,801 ha exactly once; no 2017 location in two units |
| M2 | Retile, per-unit step 1, per-unit step 2 and join implemented | **Tiling invariance on EV1:** tiled EV1 reproduces the untiled `ev1` run's gaps (same thresholds, same connectivity) up to float32 rounding (`check_run.py --compare` logic) |
| M3 | Pilot: 2–3 blocks, ~50–100 units in different forest types; same-epoch null; ADR 009's 25 ha windows | Per-unit time and memory benchmarked; null and windows give the ADR 009 values → ADR Accepted |
| M4 | Full step 1 (all units) | Every unit complete; QC maps (ground C2C per tile) show no registration blocks |
| M5 | Step 2 + join: primary threshold, then the ADR 009 sensitivity set | `check_run`-style consistency; largest gap per tile within the separation test |
| M6 | Post-processing: forest mask, covariates, area accounting | Masked area per forest type recorded; mask comparison (ADR 007) written up |

M4 can run while M3's ADR is being finalised, since step 1 doesn't depend on the threshold.
Primary island-wide gap results (M5) are only examined after ADR 009 is Accepted.

## 8. Code to write

| Piece | Where | Notes |
|---|---|---|
| Work-unit planner | `python/plan_units.py` | Footprints and pairs from `derived/inventory/` |
| Retiler | `python/retile.py` | One LAS file per task |
| Per-unit mode for `canopy.py` | `canopy.py` (`--unit`) | Reuses `prepare` / `analyze_threshold`; half-open clipping; bounding-box reference. The search cap (D2), dropped `.bin` (D4) and lowest 2018 return (D1) are already in `canopy.py` |
| Per-unit voxel export, cross-tile join, global attributes | `python/join_gaps.py` | Union-find over tile-edge voxels |
| Area accounting | `python/area.py` or R | Coverage cells ∩ forest mask per forest type |
| Slurm stage scripts + status | `workflow/` (plan Appendix A.1) | One `.sbatch` per stage, plus a submit script |
| QC report | extends `check_run.py` | Island-wide checks and per-tile maps |

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

1. **D3** is under review (§3).
2. **Benchmarks:** `sacct` Elapsed and MaxRSS from the untiled EV1 run. These replace the
   §5 estimates until M3.

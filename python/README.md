# Point-cloud gap pipeline (`canopy.py`)

This is the CloudComPy version of the change detector. It computes the exact one-way
nearest-neighbour distance (C2C) from each 2017 return to the 2018 cloud, caches it, then
groups returns at or above each threshold into fixed-grid 1 m voxels and connected 3D gaps.
The docstring at the top of `canopy.py` lists the outputs. The doc comments and
[docs/point-gaps-plan.md](../docs/point-gaps-plan.md) explain the method and the planned
revisions.

The method is unchanged from the server copy (`canopy (2).py`, 2026-10-20). Only the
settings block now follows this repository's path conventions, and a preflight check runs
before step 1. The revisions in the plan aren't made yet.

## Current setup: LFDP only

| Setting | Value |
|---|---|
| Site | `lfdp`: Luquillo Forest Dynamics Plot + 50 m buffer |
| Pre | `PR_5March2017_EV1` tiles `c4r2`, `c5r2` |
| Post | `PR_25April2018_EV1` tiles `c4r2`, `c5r2` |
| Study area | `sites/lfdp/lfdp_buf50.gpkg` (copy it in; see `sites/lfdp/README.md`) |
| DTM | `PR_5March2017_EV1_DTM.tif` (heights above ground) |
| Thresholds | 2 m, 5 m |

The plot falls in tiles `c4r2`/`c5r2` of both EV1 flights (`derived/inventory/pr_footprints.gpkg`,
layer `tiles`). The same tiles cover it in `PR_15March2017_EV1` (c4r2 only holds data) and
`PR_15March2020_EV1`. Strips `l0s14`/`l0s15` of `PR_11March2017_FIA30` → `PR_30April2018_FIA30`
are a second, independent 2017→2018 pair over the plot.

## Paths

| Variable | Default | Meaning |
|---|---|---|
| `PR_GAPS_DATA` | `../data` beside the repo | data root, same as the R code |
| `PR_GAPS_GLIHT` | `$PR_GAPS_DATA/raw/gliht` | campaign directories in server layout. On the server: `/ibstorage/shared/PR_NASA_GLiHT` |
| `PR_GAPS_DTM` | `$PR_GAPS_GLIHT/PR_5March2017_EV1/lidar/geotiff/PR_5March2017_EV1_DTM.tif` | unpacked DTM |
| `PR_GAPS_SCRATCH` | `/workdir/ogh6/tmp` | where `.laz.gz` expands; used only if it exists |

Outputs go to `$PR_GAPS_DATA/runs/canopy/<site>/`: the distance cache in `cache/`, and
`gaps/<run-id>/threshold_<t>m/` per gap run. Nothing is written into the repository.

## Running it

On the server:

```bash
source ~/cloudcompy_env.sh
export PR_GAPS_DATA=/path/to/pr_gaps_data
export PR_GAPS_GLIHT=/ibstorage/shared/PR_NASA_GLiHT
export PR_GAPS_DTM=/workdir/ogh6/ev1/PR_5March2017_EV1_DTM.tif
python python/canopy.py
```

Requirements: CloudComPy (installed from its own environment, not pip), plus the packages
in `requirements.txt`.

To fetch just the LFDP tiles into `$PR_GAPS_DATA` instead (≈2.1 GB of LAS + 2 DTMs, about
45 min at the server's ~0.75 MB/s), from the repository root in R:

```r
for (f in list.files("R", pattern = "[.]R$", recursive = TRUE, full.names = TRUE)) source(f)
state <- readRDS("derived/inventory/pr_gliht_state.rds")
plan <- gl_plan_download(state$inventory$files,
                         c("PR_5March2017_EV1", "PR_25April2018_EV1"),
                         products = c("las", "dtm"))
plan <- plan[plan$product == "dtm" | grepl("_c[45]r2[.]las[.]gz$", plan$name), ]
gl_run_download(plan, dry_run = FALSE)
```

## Changing site

Edit the settings block: `SITE`, `PRE`, `POST`, `STUDY_AREA`, `DTM`, `THRESHOLDS`. The FIA12
setup is kept there, commented out. `PRE`/`POST` accept files or campaign `lidar/las`
directories, and `TILE_FILTER` narrows a directory to some tiles. Each site gets its own
cache, and a cache is reused only when its inputs and step-1 settings are identical.

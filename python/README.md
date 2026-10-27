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

## Sites

Pick one with the `SITE = ...` line in the settings block, or with `PR_GAPS_SITE` without
editing the file. The default is `lfdp`.

| Site | Pre (5 Mar 2017) | Post | Study area | DTM | Thresholds |
|---|---|---|---|---|---|
| `lfdp` | `PR_5March2017_EV1` tiles `c4r2`, `c5r2` | `PR_25April2018_EV1` same tiles | `$PR_GAPS_DATA/interim/sites/lfdp/lfdp_buf50.gpkg`: plot + 50 m (25.05 ha) | 2017 EV1 | 2 m, 5 m |
| `ev1` | all 24 `PR_5March2017_EV1` tiles (384 M points) | all 22 `PR_25April2018_EV1` tiles (327 M) | none: whole tiles, clipped to both-flights coverage | 2017 EV1 | 2 m, 5 m |
| `fia12` | `PR_11March2017_FIA12` (23 tiles) | `PR_2May018_FIA12` | none | none | 5 m |

Each site gets its own cache and gap runs under `$PR_GAPS_DATA/runs/canopy/<site>/`.

The plot falls in tiles `c4r2`/`c5r2` of both EV1 flights (`derived/inventory/pr_footprints.gpkg`,
layer `tiles`). The same tiles cover it in `PR_15March2017_EV1` (c4r2 only holds data) and
`PR_15March2020_EV1`. Strips `l0s14`/`l0s15` of `PR_11March2017_FIA30` → `PR_30April2018_FIA30`
are a second, independent 2017→2018 pair over the plot.

The study area is derived from the unbuffered plot polygon `$PR_GAPS_DATA/raw/shapefiles/LFDP/LFDP.shp`
(16.05 ha, EPSG:32620) by

```bash
.venv/Scripts/python python/make_study_area.py
```

which dissolves it, buffers it by 50 m and writes the GeoPackage. Pass `SOURCE BUFFER_M OUTPUT`
for another site or buffer. An existing output is left alone unless you pass `--force`. Rewriting
it changes its mtime, which the distance cache is keyed on, so the cache would stop loading.
Only 2017 points inside the polygon are analysed. 2018 points from the whole tiles stay in the
reference, so edge points are compared with their true nearest neighbours.

## Paths

| Variable | Default | Meaning |
|---|---|---|
| `PR_GAPS_DATA` | `../data` beside the repo | data root, same as the R code |
| `PR_GAPS_GLIHT` | `$PR_GAPS_DATA/raw/gliht` | campaign directories in server layout. On the server: `/ibstorage/shared/PR_NASA_GLiHT` |
| `PR_GAPS_SITE` | `lfdp` | which entry of `SITES` to run, if the `SITE` line isn't edited |
| `PR_GAPS_DTM` | the site's DTM: `$PR_GAPS_GLIHT/PR_5March2017_EV1/lidar/geotiff/PR_5March2017_EV1_DTM.tif` for `lfdp`/`ev1` | replaces the selected site's DTM path; it must be the unpacked `.tif` |
| `PR_GAPS_THREADS` | `$SLURM_CPUS_PER_TASK`, else 16 | C2C threads; not part of the cache identity |
| `PR_GAPS_SCRATCH` | `/workdir/ogh6/tmp` | where `.laz.gz` expands; used only if it exists |

Outputs go to `$PR_GAPS_DATA/runs/canopy/<site>/`: the distance cache in `cache/`, and
`gaps/<run-id>/threshold_<t>m/` per gap run. Nothing is written into the repository.

## Environment

`init_env.ps1` (Windows) and `init_env.sh` (Linux) build a venv at `pr-gaps/.venv`
(override with `PR_GAPS_VENV`) containing CloudComPy and `requirements.txt`. Both are
safe to re-run: an environment that already passes `check_env.py` is left alone, and
`-Force` / `--force` rebuilds it.

CloudComPy isn't on PyPI, and its download page asks you to accept the GPL, so you
download the wheel yourself first. Get `cloudcompy-<version>-cp312-cp312-win_amd64.whl`
(or `...linux_x86_64.whl`) from the
[Windows](https://www.simulation.openfields.fr/index.php/cloudcompy-downloads/3-cloudcompy-binaries/13-experimental-pypi-wheels-install-with-pip/15-windows-wheel-files)
or [Linux](https://www.simulation.openfields.fr/index.php/cloudcompy-downloads/3-cloudcompy-binaries/13-experimental-pypi-wheels-install-with-pip/14-linux-wheel-files)
wheel page. Leave it in Downloads or `python/wheels/`, and the script finds it. The
venv uses whichever Python the wheel was built for (cp310–cp314), fetched by
[uv](https://docs.astral.sh/uv) if needed.

```powershell
powershell -ExecutionPolicy Bypass -File python\init_env.ps1
```

```bash
bash python/init_env.sh
```

`check_env.py` imports everything in the order `canopy.py` does, then runs
`canopy.exact_c2c` on a synthetic pair and compares it with scipy's exact
nearest-neighbour distances. Run it on its own to check any environment, including the
server's conda one.

**Windows import order.** The CloudComPy wheel bundles OpenSSL 3.6. Python's `hashlib`
loads Python's own older OpenSSL, and `canopy.py` and scipy both import `hashlib`. Windows
keeps whichever `libcrypto-3-x64.dll` loads first, so if `hashlib` comes first,
CloudComPy fails with `DLL load failed ... The specified procedure could not be found`.
`canopy.py` therefore imports CloudComPy before anything else on Windows. Any new script
that uses CloudComPy needs to do the same, or import `canopy` first.

## Running it

Locally, after `init_env.ps1` and the download below:

```powershell
.\.venv\Scripts\python.exe python\canopy.py
```

On the server:

```bash
source ~/cloudcompy_env.sh
export PR_GAPS_DATA=/path/to/pr_gaps_data
export PR_GAPS_GLIHT=/ibstorage/shared/PR_NASA_GLiHT
export PR_GAPS_DTM=/workdir/ogh6/ev1/PR_5March2017_EV1_DTM.tif
python python/canopy.py                  # PR_GAPS_SITE=ev1 for the whole block
```

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

### EV1 on a Linux HPC

```bash
cd pr-gaps
bash python/init_env.sh                  # or: source your CloudComPy env, then python python/check_env.py
export PR_GAPS_DATA=/path/to/pr_gaps_data
export PR_GAPS_GLIHT=/path/to/gliht      # holds PR_5March2017_EV1/ and PR_25April2018_EV1/
export PR_GAPS_DTM=/path/to/PR_5March2017_EV1_DTM.tif   # only if it isn't unpacked under PR_GAPS_GLIHT
PR_GAPS_SITE=ev1 .venv/bin/python python/canopy.py
```

Expected cost, scaled from LFDP (9.0 M 2017 points, about 1.5 min in total):

- **Memory:** CloudComPy holds both clouds and their search index in RAM during the
  distance step, roughly 15–20 GB for 711 M points, plus copies. Request at least 48 GB
  and preferably 64 GB.
- **Disk:** about 26 GB of distance cache in `runs/canopy/ev1/cache/`. That includes an
  optional `source_c2c.bin` CloudCompare file of about 7 GB, which you can delete after the
  run. Each threshold folder is a few GB more.
- **Time:** about 30–60 min. Reading the compressed LAS dominates step 1. In step 2, the
  per-gap convex hulls and GeoPackage outlines loop in Python, so expect minutes to tens of
  minutes at ~10⁵ gaps.
- **Threads:** under Slurm the thread count follows `--cpus-per-task`. Otherwise set
  `PR_GAPS_THREADS`.

If the run dies after step 1, run the same command again. A complete cache is reused, and
step 2 resumes whatever threshold folders and exports are missing. A run killed during
step 1 leaves a hidden `.cache-*` folder beside `cache/`, which you can delete.

## Adding a site

Add an entry to `SITES` in `canopy.py` with `pre`, `post`, `study_area`, `dtm` and
`thresholds`. `pre`/`post` accept LAS files or campaign `lidar/las` directories, and
`TILE_FILTER` narrows a directory to some tiles. A cache is reused only when its inputs
and step-1 settings are identical.

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
| `ev1` | all 24 `PR_5March2017_EV1` tiles (384 M points) | all 22 `PR_25April2018_EV1` tiles (327 M) | `$PR_GAPS_DATA/interim/sites/ev1/ev1_overlap.gpkg`: where both flights' CHMs have data (926 ha), from `make_overlap_area.py` | 2017 EV1 | 2 m, 5 m |
| `fia12` | `PR_11March2017_FIA12` (23 tiles) | `PR_2May018_FIA12` | none | none | 5 m |

Each site gets its own cache and gap runs under `$PR_GAPS_DATA/runs/canopy/<site>/`.

**Keep 2017 points near 2018 data.** The C2C search has no distance cap, so a 2017 point
far from every 2018 return makes CloudComPy search through all the empty space in
between. The first untiled `ev1` run had no study area: 28% of the 2017 area has no
2018 data, 176 ha of it more than 500 m away. It spent 3.5 h+ in C2C without finishing,
after about 40 min for everything else. Clip `pre` to the flights' overlap
(`make_overlap_area.py PRE POST OUTPUT`). This changes no gap, because the coverage mask
drops those points anyway.

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
| `PR_GAPS_CONNECTIVITY` | `26` | gap connectivity, `26` (faces, edges, corners) or `6` (faces only). A step-2 setting: the distance cache is reused, and each value gets its own `gaps/<run-id>/` |
| `PR_GAPS_SEED_THRESHOLD` | unset (off) | seeded split, e.g. `5`: at thresholds below it, gaps are split around the gaps found at it (see below). A step-2 setting; each value gets its own `gaps/<run-id>/` |
| `PR_GAPS_THREADS` | `$SLURM_CPUS_PER_TASK`, else 16 | C2C threads; not part of the cache identity |
| `PR_GAPS_SCRATCH` | `/workdir/ogh6/tmp` | where `.laz.gz` expands; used only if it exists |

Outputs go to `$PR_GAPS_DATA/runs/canopy/<site>/`: the distance cache in `cache/`, and
`gaps/<run-id>/threshold_<t>m/` per gap run. Nothing is written into the repository.

## Seeded split

At low thresholds, changed voxels form one connected web across much of the canopy. At
LFDP at 2 m, one 26-connected gap holds 35% of all gap volume, and in plan view nearly
10 ha of the 25 ha is one patch. Setting `PR_GAPS_SEED_THRESHOLD=5` splits that web
around the 5 m gaps:

1. **Cores.** The 5 m gaps are found inside the 2 m voxels exactly as a 5 m run would
   find them: same connectivity, `MIN_POINTS` counted on ≥ 5 m returns, `MIN_VOLUME`.
2. **Growth.** Every other 2 m voxel joins the core it reaches in the fewest steps
   through changed voxels. Growth runs from all cores at once, and ties go to the
   lower-numbered core, so the result is deterministic.
3. **Leftovers.** 2 m voxels connected to no core keep their ordinary connected component.
   The usual `MIN_POINTS`/`MIN_VOLUME` filters then apply to every gap.

So each gap is a core of severe loss plus the weaker change around it. Each 5 m gap ends
up whole in exactly one 2 m gap, and no 2 m gap holds two. Thresholds at or above the seed
are unaffected. Where two cores' halos meet, the boundary falls midway between them, which
is a convention rather than something the data show. Report it as such, and treat the
split as one gap definition among the alternatives for the size distribution.

LFDP at 2 m:

| | Gaps | Largest | Gap volume attached to a 5 m core |
|---|---|---|---|
| 26-connected | 2,131 | 35.1% of gap volume | – |
| 6-connected | 4,176 | 8.7% | – |
| seeded, 26-connected | 2,540 | 1.3% | 84% |
| seeded, 6-connected | 4,595 | 1.3% | 74% |

```bash
PR_GAPS_SEED_THRESHOLD=5 sbatch -J canopy-ev1-seed python/run_canopy.sbatch ev1
```

Each run's `run.json` records the rule under `segmentation`.

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

**Import order.** The CloudComPy wheels bundle OpenSSL 3.6, and a process keeps
whichever OpenSSL loads first. Python's `hashlib` (imported by `canopy.py` and scipy) and
GDAL (via rasterio) load an older one: Python's own on Windows, `/lib64/libcrypto.so.3`
on the cluster. If either comes first, CloudComPy fails, on Windows with
`DLL load failed ... The specified procedure could not be found`, on Linux with
``/lib64/libcrypto.so.3: version `OPENSSL_3.6.0' not found``. `canopy.py` therefore imports
CloudComPy before anything else. Any new script that uses CloudComPy needs to do the same,
or import `canopy` first.

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

**Older Linux systems (`GLIBCXX_3.4.32' not found`).** The Linux CloudComPy wheel needs
the C++ runtime from GCC 13.2 or newer. RHEL/Rocky 8-era clusters ship an older
`/lib64/libstdc++.so.6`. Either use an existing conda-based CloudComPy environment (it
ships its own runtime), or put a newer runtime first on the library path, both when
checking and in every job script:

```bash
module load gcc/13.2.0   # or any GCC >= 13.2 that 'module avail gcc' lists
export LD_LIBRARY_PATH="$(dirname "$(gcc -print-file-name=libstdc++.so.6)"):$LD_LIBRARY_PATH"
```

Without a suitable module, `micromamba create -p ~/libstdcxx -c conda-forge 'libstdcxx>=13.2'`
followed by `export LD_LIBRARY_PATH=~/libstdcxx/lib:$LD_LIBRARY_PATH` does the same.

**No display.** CloudComPy starts a Qt application on import. On Linux, `canopy.py` sets
`QT_QPA_PLATFORM=offscreen` (unless you set it yourself), so it runs in batch jobs and over
SSH sessions whose X11 forwarding has no X server behind it. Any other script that imports
CloudComPy directly needs the same setting.

### EV1 on a Linux HPC

```bash
cd pr-gaps
bash python/init_env.sh                  # or: source your CloudComPy env, then python python/check_env.py
export PR_GAPS_DATA=/path/to/pr_gaps_data
export PR_GAPS_GLIHT=/path/to/gliht      # holds PR_5March2017_EV1/ and PR_25April2018_EV1/
export PR_GAPS_DTM=/path/to/PR_5March2017_EV1_DTM.tif   # only if it isn't unpacked under PR_GAPS_GLIHT
PR_GAPS_SITE=ev1 .venv/bin/python python/canopy.py
```

Or as a Slurm job, which also loads GCC and sets the headless Qt platform. Set the two
paths at the top of the script first:

```bash
sbatch -J canopy-ev1 python/run_canopy.sbatch ev1
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

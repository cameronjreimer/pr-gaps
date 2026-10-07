# G-LiHT Puerto Rico — flight-path inventory and repeat-coverage overlay

Compiles every G-LiHT Puerto Rico acquisition into a searchable inventory, builds
coverage footprints for each one, and identifies where the
2017, 2018 and 2020 campaigns overlap. This is the week-1/week-3 machinery in the
project plan: bulk transfer path, flight metadata, and the usable-swath
inventory that sets spatial scope (§3.1).

Nothing is downloaded in bulk unless you ask for it. The default run touches only
directory listings and the small tile shapefiles (about 2 MB in total) and
ends with a *dry-run* download plan.

## Quick start

```bash
Rscript scripts/01_build_inventory.R --max 6      # smoke test on six campaigns
```

```bash
Rscript scripts/01_build_inventory.R              # full run
```

```bash
Rscript scripts/01_build_inventory.R --reuse --refine "re:_EV[0-9]"   # exact footprints, Luquillo blocks
```

Flags: `--max N` limits campaigns, `--refresh` ignores cached directory
listings, `--reuse` reloads the last footprint GeoPackage instead of rebuilding
it, `--refine <spec>` computes exact CHM footprints (see below).

The script locates the repository from its own path, so the working directory
does not matter. Requires R with `sf`, `terra`, `curl`, `jsonlite`, and
optionally `tigris` — used once to fetch Puerto Rico's coastline for the maps,
which are drawn without it if the package or the network is unavailable.

Bulk downloads go to `$PR_GAPS_DATA`, which defaults to the `data/` sibling of
this repository (`C:\Users\camer\Projects\G-LIHT\data`). Override it to put them
on another volume:

```powershell
[Environment]::SetEnvironmentVariable('PR_GAPS_DATA','D:\pr_gaps_data','User')
```

**Keep `PR_GAPS_DATA` out of OneDrive.** The footprint step writes ~1,500 small
shapefile components; with sync watching the folder, the step that normally
takes 7 minutes has been observed to take 20.

## What it produces

Small artefacts in `derived/inventory/` (committed):

| File | Contents |
|---|---|
| `pr_campaigns.csv` | one row per campaign: date, epoch, block, LAS scheme, file counts and sizes, metadata PDF URL |
| `pr_files.csv` | every downloadable file across the PR campaigns, with URL and size |
| `pr_footprints.gpkg` | layers `tiles`, `campaign_footprints` |
| `pr_footprint_summary.csv` | per-campaign footprint area and provenance |
| `pr_repeat_coverage.gpkg` | layers `epoch_coverage`, `repeat_coverage`, `repeat_tiles` |
| `pr_repeat_summary.csv` | hectares by which epochs cover them |
| `pr_repeat_tiles.csv` | per-tile overlap fraction against each epoch — the table to filter when choosing what to download |
| `pr_repeat_campaign_pairs.csv` | which flight overlaps which, with area, fraction and days between |
| `pr_inventory_by_epoch.csv` | campaigns, flight days, dates and area per epoch |
| `pr_footprints_chm.gpkg` | exact CHM footprints, for campaigns you have refined |
| `pr_footprint_summary_chm.csv`, `pr_repeat_summary_chm.csv` | the same, tabulated |
| `figures/` | coverage by epoch (one panel per epoch), and the repeat-coverage map |

`--max N` writes a partial inventory over these same paths, so re-run without it
before trusting `derived/inventory/`.

Bulk data goes to `$PR_GAPS_DATA/raw/gliht/<campaign>/...`, mirroring the server
layout, with `MANIFEST.csv` recording source URL, size, md5 and download time for
every file that lands there — whether it came from the download planner or from
the CHM refinement. Directory listings are cached under
`$PR_GAPS_DATA/cache/index` as JSON, so a re-run is offline and instant, and an
interrupted crawl resumes.

## What the inventory found

296 Puerto Rico campaigns, 7,478 catalogued files, 705 GB on the server.

| Epoch | Campaigns | Flight days | Dates | Tier-1 coverage (ha) |
|---|---|---|---|---|
| 2017_pre | 148 | 13 | 2017-03-01 → 03-17 | 135,279 |
| 2018_post | 120 | 9 | 2018-04-22 → 05-02 | 150,799 |
| 2020_recovery | 21 | 2 | 2020-03-15 → 03-16 | 34,557 |

(Epoch coverage is the dissolved union, so it is smaller than the sum of
campaign footprints — 189,424 ha in 2017 — by the amount the same-epoch flights
overlap each other.)

Tier-1 repeat coverage (upper bounds — see the two tiers below):

| Epochs | Area (ha) |
|---|---|
| 2017 + 2018 + 2020 | 28,402 |
| 2017 + 2018 | 83,713 |
| 2018 + 2020 | 6,018 |
| 2017 + 2020 | 137 |

291 of the 296 campaigns yielded a footprint. The other five
(`PR_15March2017_112`, `PR_26April2018_131`, `PR_27April2018_197`,
`PR_27April2018_198`, `PR_April2018_BG_all`) are empty directories on the
server — no LAS, no shapefile, no rasters.

242 campaigns carry ≥25 ha of 2017 × 2018 overlap. Their CHM + DTM + metadata is
17.9 GB. Most 2018 and 2020 flights were deliberate reflights of 2017 blocks, so
overlap fractions are mostly 1.00 — the pairs table shows 413-day and 1,109-day
intervals repeating cleanly across the FIA plot network.

## Downloading products

```r
## From the repository root:
for (f in list.files("R", pattern = "[.]R$", recursive = TRUE, full.names = TRUE)) source(f)
library(sf)

state <- readRDS("derived/inventory/pr_gliht_state.rds")

## Campaigns that carry Maria-interval repeat coverage
maria <- gl_repeat_campaigns(state$repeat_coverage$campaign_pairs,
                             "2017_pre", "2018_post", min_overlap_ha = 25)

plan <- gl_plan_download(state$inventory$files, maria,
                         products = c("chm", "dtm", "metadata"))
gl_run_download(plan, dry_run = TRUE)    # prints size by product
gl_run_download(plan, dry_run = FALSE)   # fetches
```

Products available: `chm`, `dtm`, `dsm`, `slope`, `las`, `metrics`, `metadata`,
`tiles_shp`. Downloads are restartable at file granularity — a file
already present at the published size is skipped, and every transfer is written
to `<name>.part` and renamed only on success, so an interrupted run never leaves
a truncated file that looks complete.

## How coverage is determined, and what that costs you

G-LiHT publishes, per campaign:

- `lidar/las/*.las.gz` — either one file per tile (`_c<col>r<row>.las.gz`) or one
  file per flight-line strip (`_l<line>s<strip>.las.gz`), depending on the
  campaign.
- `lidar/shp/*_tiles.shp` — geometry following the same scheme. For tiled
  campaigns it is a **complete rectangular grid** over the bounding box and most
  of its ~1 km tiles are empty (`PR_15March2017_EV1`: 40 tiles, 13 with data).
  For strip campaigns it is one polygon per strip, 1:1 with the delivered LAS
  (`PR_1March2017_FIA15`: 15 of 15 matched). Either way the polygons are matched
  to delivery by name, and `tile_source` records which case applied.
G-LiHT also publishes a `trajectory/shp/` per campaign, which this workflow
deliberately ignores: it is the **whole day's** ground track rather than that
block's, so every campaign flown on 2017-03-01 ships the same 533 km line and
`PR_15March2017_EV1`'s is 1,127 km against a ~13 km² block. It cannot be used to
derive coverage — buffering the full 2017 track by a 400 m swath implies 422,230
ha against the 189,424 ha actually flown, because the track includes ferry legs
and turns. See ADR 005.

So the footprint is built in two tiers:

**Tier 1 (default, cheap).** Published polygons ∩ delivered LAS names, recorded
in `pr_footprint_summary.csv` as `tile_source`:

- `las_tiles` — grid filtered to the tiles that hold data. Coarse at 1 km: a
  ~400 m swath crossing a tile diagonally still claims the whole tile.
- `las_strips` — per-strip polygons, 1:1 with delivery, but each envelopes its
  swath rather than tracing it.
- `tile_grid` — nothing matched; the whole grid, a hard upper bound.

All three overestimate. Check the column before quoting an area.

**Tier 2 (opt-in, exact).** `gl_step_refine_chm()` downloads the CHM for
selected campaigns and polygonises its non-NA extent. Run this for the campaigns
that actually enter the analysis, before any area accounting (§2.10 of the plan
makes density estimates only as good as the denominator).

```bash
Rscript scripts/01_build_inventory.R --reuse --refine "re:_EV[0-9]"    # Luquillo blocks, ~300 MB, ~2 min
Rscript scripts/01_build_inventory.R --reuse --refine repeat           # every repeat candidate, ~7 GB, ~3 h
```

Measured cost of the full refinement: downloads run at about 0.75 MB/s from the
G-LiHT server, so the 7 GB takes roughly 2.7 hours and dominates; tracing adds
25–40 minutes. It is restartable at file granularity, and refined footprints
accumulate across runs, so it can be done overnight or in batches.

Most CHMs arrive as a tar of per-strip GeoTIFFs that expand 7–17× when unpacked.
Those unpacked rasters are deleted as soon as the outline has been traced, which
holds the refinement to about 8 GB on disk rather than the 50–110 GB it would
otherwise leave behind. The archives are kept, so re-tracing costs ~3 seconds per
campaign. Pass `keep_unpacked = TRUE` to `gl_chm_footprint()` when inspecting a
footprint that looks wrong.

**The gap between the tiers is large, and it runs one way.** For the 14 Luquillo
EV campaigns the CHM footprint is 20–52% of the tile footprint (median ~0.39):

| Campaign | tile ha | CHM ha | ratio |
|---|---|---|---|
| PR_5March2017_EV2 | 3,491 | 1,559 | 0.45 |
| PR_5March2017_EV1 | 2,464 | 1,282 | 0.52 |
| PR_25April2018_EV1 | 2,259 | 1,097 | 0.49 |
| PR_17March2017_EV2 | 2,156 | 508 | 0.24 |
| PR_15March2017_EV1 | 1,335 | 268 | 0.20 |

Strip campaigns fare somewhat better but are still generous:
`PR_1March2017_FIA15` is 3,005 ha of strip polygons against 1,354 ha of CHM
(0.45).

Treat every tier-1 area in `pr_repeat_summary.csv` as an upper bound of roughly
this magnitude. The island-wide tier-1 figure of ~84,000 ha of 2017 × 2018
overlap is therefore consistent with a true value nearer 30,000–40,000 ha, but
only the refinement settles it. For the Luquillo EV blocks, where the
refinement has been run, the exact numbers are 1,710 ha covered by 2017 and 2018
and a further 858 ha covered by all three epochs.

A note on why the difference is so large: a G-LiHT swath is a few hundred metres
wide, the tiles are ~1 km, and the flight lines cross them diagonally. A single
strip through a tile claims the whole tile.

Also worth knowing: the metrics grids (`lidar/geotiff/metrics/`, 26 m, ~10 KB
each) look like a cheap footprint proxy and are not one — for
`PR_15March2017_EV1` they are valid over 136 ha against the CHM's 257 ha, so
they carry their own criterion, not a coverage mask.

## Known wrinkles in the published tree

Handled in code, listed here so the behaviour isn't mistaken for a bug:

- `PR_2May018_*` — the year is written `018`; parsed as 2018.
- `PR_March2020_EV1_all`, `PR_April2018_BG_all` and `PR_March2020_EV3_all` are
  pre-merged mosaics of the daily flights. They are inventoried but excluded
  from the repeat overlay (`is_mosaic`) so their area isn't counted twice.
- `PRF_transect_*_Jun2011` are pulse-repetition-frequency test transects, not
  Puerto Rico. Excluded.
- Shapefiles ship in three layouts: loose components, a `.zip`, or
  `shp/tiles/*_shp.tar.gz`. All three are handled.
- Rasters ship either as one mosaic (`_CHM.tif.gz`) or a tar of per-strip
  GeoTIFFs (`_CHM.tar.gz`). Both are handled.

## Layout

Following Appendix A of the plan: code and data live apart, and the repository
is the only thing under version control.

```
G-LIHT/
  pr-gaps/                       <- this repository
    scripts/01_build_inventory.R   driver
    R/ingest/00_config.R           paths, CRS, epochs, campaign filters
    R/ingest/00_helpers.R          small shared utilities (areas, stacking, filters)
    R/ingest/01_http.R             cached Apache index parsing, restartable downloads
    R/ingest/02_crawl.R            campaign + file inventory
    R/ingest/03_footprints.R       per-campaign coverage footprints
    R/ingest/05_download.R         download planning, execution, manifest
    R/ingest/06_refine_chm.R       exact footprints from CHM valid-data extent
    R/inventory/04_repeat.R        epoch overlay, repeat tiles, campaign pairs
    R/inventory/07_report.R        summary tables and figures
    R/inventory/08_basemap.R       Puerto Rico coastline for the maps
    derived/inventory/             committed outputs (CSV, GPKG, figures)
    docs/plan.md                   the 13-week plan
    docs/decisions/                ADRs, one per decision
  data/                          <- $PR_GAPS_DATA, never committed
    cache/index/                   directory listings
    raw/gliht/                     downloaded products + MANIFEST.csv
    interim/tile_shapefiles/       tile shapefiles, unpacked — regenerable
    interim/boundary/              Puerto Rico coastline — regenerable
    runs/                          per-run outputs (Appendix A.2)
```

Three tiers, each with a different claim on you:

- **`raw/`** is immutable (Appendix A.3). Everything in it is listed in
  `MANIFEST.csv` with its source URL, size, md5 and arrival time, so someone
  else can re-obtain it without this code. Safe to set read-only after ingest.
- **`interim/`** is reproducible from `raw/` plus the URLs in `pr_files.csv`, and
  is written to on any run — the published shapefiles arrive as a `.zip` and get
  unpacked here, which is why this is not raw data and not manifested. Safe to
  delete; the next run refetches it.
- **`cache/`** holds the parsed directory listings. Deleting it costs a re-crawl
  (~8 minutes), nothing more.

The empty `src/` siblings from Appendix A.1 (`align/`, `detect/`, `classify/`,
`delineate/`, `validate/`, `stats/`) are not created yet; add them under `R/` as
each is written.

Analysis CRS is EPSG:32161 (NAD83 / Puerto Rico & Virgin Is., metres). UTM is
the wrong choice here: the island straddles zones 19N/20N at longitude −66, and
the eastern sites (Luquillo, EV1–EV3) fall on the far side of that line from the
western ones.

Source: NASA G-LiHT, <https://glihtdata.gsfc.nasa.gov/files/G-LiHT/>.

# Covariate acquisition plan

**Date:** 2026-10-14
**Bears on:** §5 week 2 covariate stack, §3.2 forest type classification, §2.11
pre-interval land cover mask, Q3, Q6
**Decisions:** [007](decisions/007-forest-mask-source.md),
[008](decisions/008-covariate-sampling-per-gap.md)

What environmental covariates to fetch, from where, and what "done" means for
each. Planning only — nothing here is implemented yet.

## Scope

- **Unit of use: per gap.** Every covariate is a value looked up for each gap
  polygon. Layers are used at their native resolution; nothing is forced onto a
  common analysis grid (ADR 008).
- **Gap density per stratum (Q4) is out of scope for now**, so no layer has to
  support area-correct stratum denominators.
- **Extent: the main island only.** Each layer is fetched at its full published
  extent and never clipped at download — clipping would tie `raw/` to a
  footprint that changes when the CHM refinement runs.
- **Deferred:** forest age, prior land use (§3.4), topographic exposure,
  an island-wide external DEM, `height_pct` / `density_dec` metrics, drought.

## The stack

| Role | Layer | Source | Default |
|---|---|---|---|
| Forest mask | Hansen Global Forest Change: `treecover2000`, `lossyear`, `datamask` | UMD / GLAD | **default** (ADR 007) |
| Forest mask, comparison | NOAA C-CAP Puerto Rico 2010 (high-res and 30 m) | NOAA Digital Coast | compare later |
| Forest type candidate | Puerto Rico GAP land cover (Gould et al. 2008, ~2000 imagery), aggregated | USGS ScienceBase | §3.2 |
| Forest type candidate | Holdridge life zones (Ewel & Whitmore 1973) | USFS IITF | §3.2 |
| Forest type candidate | Land cover and forest formations circa 2000 (Kennaway & Helmer 2023, successor to Helmer et al. 2002) | USFS RDS-2023-0022 | §3.2 |
| Rainfall | PRISM Puerto Rico mean annual precipitation, 1963–1995 normals (no 1991–2020 exists) | PRISM / OSU | — |
| Temperature | PRISM Puerto Rico mean annual temperature, derived as (tmax + tmin) / 2, 1963–1995 | PRISM / OSU | — |
| Elevation, slope, aspect | 2017 G-LiHT `dtm`, `slope`, `aspect` | G-LiHT | already in `GL_DEFAULT_PRODUCTS` |
| Pre-Maria canopy height | 2017 G-LiHT `chm`; heterogeneity metrics derived later | G-LiHT | already in `GL_DEFAULT_PRODUCTS` |

All three forest-type candidates are fetched because §3.2 chooses between them
by which best explains pre-hurricane canopy structure, which needs all of them
in hand. Each passes the §3.2 criterion of independence from LiDAR structure.

Elevation comes only from the G-LiHT DTM: gaps exist only inside swaths, so the
DTM covers every gap. Its limit is the swath edge — neighbourhood terrain metrics
(TPI, large-window curvature, upslope area) would be truncated near it. Revisit
with an external DEM if exposure comes back.

## Acquisition

**Hybrid transport.** Sources with stable URLs (likely Hansen, PRISM, C-CAP) are
downloaded by script, reusing the restartable `.part`/rename download code in
`R/ingest/01_http.R`. Sources behind portals or terms pages (likely GAP,
Holdridge, Helmer) are downloaded by hand into `raw/covariates/<layer>/`, and a
script checksums and registers them.

**Source registry**, committed to the repository, one row per layer:

| Field | Contents |
|---|---|
| `layer` | short key, also the `raw/covariates/<layer>/` directory name |
| `role` | mask / forest_type / climate |
| `transport` | `scripted` or `manual` |
| `url` | download URL, or landing page for manual sources |
| `version`, `vintage` | product version; date of the imagery or normals period |
| `crs`, `resolution` | as published |
| `license` | terms of use |
| `citation_key`, `citation` | full reference to cite in the methods |
| `notes` | class legend location, units, caveats |

**Covariate manifest** at `$PR_GAPS_DATA/raw/covariates/MANIFEST.csv`, separate
from the G-LiHT manifest: one row per file with source URL, size, md5, arrival
time and `citation_key` back into the registry. `raw/covariates/` is read-only
after ingest (Appendix A.3).

## Harmonization

A copy of every layer goes to `$PR_GAPS_DATA/interim/covariates/` in
EPSG:32161, keeping roughly its native cell size:

- categorical rasters — nearest neighbour
- continuous rasters — bilinear
- vectors — reprojected directly

`raw/` stays the immutable source; `interim/covariates/` is regenerable from it.

## Acceptance check (per layer)

A layer is done when:

1. it opens;
2. its CRS is declared;
3. its extent covers the main-island repeat footprint
   (`derived/inventory/pr_repeat_coverage.gpkg`);
4. its class legend or units are recorded in the registry;
5. for the mask and forest-type layers, its vintage is confirmed earlier than
   September 2017 (§2.11).

## Source verification (2026-10-14)

| Layer | Finding | Transport |
|---|---|---|
| Hansen GFC | Current release is **GFC-2025-v1.13** (loss 2001–2025; v2.0 reprocessing announced, undated). Files are `https://storage.googleapis.com/earthenginepartners-hansen/GFC-2025-v1.13/Hansen_GFC-2025-v1.13_<layer>_20N_070W.tif`; granules are named by top-left corner, so `20N_070W` spans 10–20°N, 70–60°W and covers the main island. CC BY 4.0. | scripted |
| C-CAP | **2010 is the vintage**, in two forms: a high-resolution product from 2010 USACE imagery (InPort 48301; custom export from the Digital Coast Data Viewer, ID 6247) and a 30 m product (InPort 48300; also in the Caribbean bulk-download folder). Nothing between 2010 and Maria. | 30 m scripted; high-res manual |
| PR GAP land cover | USGS ScienceBase item `560c3b2de4b058f706e5411e`: 15 m, 70 classes, ~2000, GeoTIFF, public. Cite Gould et al. 2008, IITF-GTR-39. | scripted |
| Holdridge | USFS IITF zip of a geodatabase, 6 classes: `https://research.fs.usda.gov/sites/default/files/2026-07/iitf-pr_usvi_holdridgelifezones.zip`. Cite Ewel & Whitmore 1973, ITF-018. No licence stated. | scripted |
| Helmer forest types | No archived release of the 2002 map itself. The archived successor is **Kennaway & Helmer 2023, RDS-2023-0022** (doi:10.2737/RDS-2023-0022): land cover and forest formations circa 2000, from 1991 and 2000 Landsat, one 12.6 MB zip with a SHA-256 published. Two variants — with and without cloud forest split. Used in place of Helmer 2002. | scripted |
| PRISM | **No 1991–2020 normals for Puerto Rico** — only 1963–1995 (`prism.oregonstate.edu/public/pr/grids`). And **no `tmean`**: only `ppt`, `tmax`, `tmin`, so mean temperature is derived as (tmax + tmin) / 2, PRISM's own definition. | scripted |

Still to read from the downloaded metadata: C-CAP high-res cell size, RDS-2023-0022
resolution, PRISM PR resolution.

## Recorded for later

- **Drought.** Antecedent drought stress as a per-gap covariate: a
  water-deficit (or PDSI) anomaly over the 2014–2016 Caribbean drought,
  from TerraClimate (~4 km, monthly since 1958). Not redundant with mean
  rainfall, unlike a climatological aridity index. Resolution caveat: the
  island is roughly 40 × 15 cells, so neighbouring gaps mostly share a value.
  A long-term mean of a standardized index (SPI/SPEI/PDSI) is ~0 everywhere by
  construction and is not a usable covariate. Global SPEI at 0.5° is too coarse.
- **Collinearity.** Holdridge zones are defined by rainfall and temperature,
  and temperature tracks elevation. Keep all three so the redundancy can be
  shown rather than assumed.
- **Mask threshold.** The Hansen tree-cover threshold is an analysis-time
  choice; 30% is a placeholder. Open-canopied dry forest on the south coast may
  fall below it.
- **Hansen misses post-2000 regrowth** — see ADR 007; the C-CAP comparison
  measures how much it matters.

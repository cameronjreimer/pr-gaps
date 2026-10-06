## ---------------------------------------------------------------------------
## Configuration for the G-LiHT Puerto Rico flight-path inventory.
##
## Nothing here writes to the network or the disk; sourcing this file only
## defines paths and constants. See scripts/01_build_inventory.R for the driver.
## ---------------------------------------------------------------------------

## Root of the G-LiHT public file tree (Apache directory index).
GLIHT_BASE <- "https://glihtdata.gsfc.nasa.gov/files/G-LiHT/"

## Repository root. Set by scripts/01_build_inventory.R from its own location, so
## the workflow runs from any working directory. Override with PR_GAPS_CODE when
## sourcing R/ interactively from elsewhere.
gl_code_root <- function() {
  root <- getOption("pr_gaps.code_root", default = "")
  if (!nzchar(root)) root <- Sys.getenv("PR_GAPS_CODE", unset = "")
  if (!nzchar(root)) root <- getwd()
  normalizePath(root, winslash = "/", mustWork = FALSE)
}

## Data root. Bulk downloads never live in the code tree (plan, Appendix A.2:
## "Data root as an environment variable, never hardcoded paths"). The default
## is a `data/` sibling of the repository:
##   G-LIHT/pr-gaps/   <- this repo
##   G-LIHT/data/      <- $PR_GAPS_DATA
gl_data_root <- function() {
  root <- Sys.getenv("PR_GAPS_DATA", unset = "")
  if (!nzchar(root)) root <- file.path(dirname(gl_code_root()), "data")
  normalizePath(root, winslash = "/", mustWork = FALSE)
}

## Bulk downloads go to the data root. The inventory artefacts are small enough
## (~11 MB) to live in the repository, where git backs them up and records how
## they changed — a deliberate departure from Appendix A.2, which puts derived/
## in the data root. Run outputs, which are large, still go to runs/ there.
gl_paths <- function() {
  root <- gl_data_root()
  code <- gl_code_root()
  list(
    root      = root,
    cache     = file.path(root, "cache", "index"),      # parsed directory listings
    vector    = file.path(root, "raw", "gliht_vector"), # tile + trajectory shapefiles
    products  = file.path(root, "raw", "gliht"),        # CHM / DTM / LAS downloads
    runs      = file.path(root, "runs"),                # per-run outputs (A.2)
    out       = file.path(code, "derived", "inventory"),
    figures   = file.path(code, "derived", "inventory", "figures")
  )
}

gl_init_dirs <- function() {
  p <- gl_paths()
  for (d in p) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  invisible(p)
}

## Analysis CRS. NAD83 / Puerto Rico & Virgin Is. (EPSG:32161) — metres, one
## zone for the whole island. UTM is wrong here: Puerto Rico straddles 19N/20N
## at longitude -66, and the eastern sites (Luquillo, EV1/EV2/EV3) fall on the
## far side of that boundary from the western ones.
CRS_AREA <- 32161

## Campaign selection. "PR_" prefixed directories are the Puerto Rico flights.
## "PRF_transect_*" are pulse-repetition-frequency test transects from 2011,
## not Puerto Rico, and are excluded by the trailing underscore requirement.
CAMPAIGN_INCLUDE <- "^PR_"

## Campaigns whose names end in "_all" are pre-merged mosaics of the daily
## flights (e.g. PR_March2020_EV1_all). They duplicate coverage already present
## in the dated campaigns, so they are inventoried but excluded from the repeat
## overlay by default to avoid double counting.
MOSAIC_PATTERN <- "_all$"

## Acquisition epochs. The plan's core interval is 2017 -> 2018 (Maria);
## 2020 is the week-9 recovery go/no-go.
gl_epoch <- function(year) {
  out <- rep(NA_character_, length(year))
  out[year == 2017] <- "2017_pre"
  out[year == 2018] <- "2018_post"
  out[year == 2020] <- "2020_recovery"
  out[is.na(out) & !is.na(year)] <- paste0(year[is.na(out) & !is.na(year)], "_other")
  out
}

## Ordering used in tables and figures.
EPOCH_LEVELS <- c("2017_pre", "2018_post", "2020_recovery")

## How much of a tile another epoch must cover before that tile counts as
## reflown (see n_other_epochs in pr_repeat_tiles.csv).
## WHY not something stricter: at this stage the footprints themselves are only
## ~1 km accurate, so a tighter threshold would imply a precision the geometry
## does not have. The underlying fractions are written out alongside the count,
## so raising it later costs nothing.
REPEAT_TILE_THRESHOLD <- 0.5

## Subdirectories listed for every campaign. Keep this short — each entry is
## one HTTP request per campaign.
CAMPAIGN_SUBDIRS <- c(
  "lidar/las/",
  "lidar/shp/",
  "lidar/shp/tiles/",
  "lidar/geotiff/",
  "trajectory/shp/",
  "metadata/"
)

## HTTP politeness / robustness.
HTTP_RETRIES <- 3L
HTTP_PAUSE   <- 0.15   # seconds between requests
HTTP_TIMEOUT <- 120L   # seconds

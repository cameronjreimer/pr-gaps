## ---------------------------------------------------------------------------
## Puerto Rico gaps — attach covariate values to each gap.
##
## Reads the gap footprints that python/canopy.py writes
## ($PR_GAPS_DATA/runs/canopy/<site>/gaps/<run>/threshold_*m/gaps.gpkg, layer
## 'footprints', EPSG:32620) and summarizes each covariate within each gap:
##
##   interim/covariates/ (EPSG:32161; ADR 008)
##     ccap_code/_class    C-CAP 2010 30 m            mode of cells
##     gap_code/_class     PR GAP land cover ~2000    mode of cells
##     holdridge           Holdridge life zone        zone with the largest overlap
##     ppt_mm              PRISM 1963-1995            mean of cells (raw / 100)
##     tmax_c, tmin_c      PRISM 1963-1995            mean of cells (raw / 100)
##   raw/gliht/<2017 campaign>/lidar/geotiff/ (EPSG:32620, 1 m)
##     elev_m              DTM                        mean of cells
##     slope_deg           slope                      mean of cells
##     aspect_deg          aspect                     circular mean, 0-360
##     chm_mean_m/_max_m   CHM (pre-Maria canopy)     mean / max of cells
##
## Cells are terra::extract()'s default: those whose centre falls in the gap,
## and for a gap smaller than a cell (the median gap is ~8 m^2), the cell it
## sits in — so every gap gets a value. Cells are not weighted by area.
## WHY not extract(exact = TRUE): measured on the LFDP 2 m run (2,131 gaps) it
## changed nothing on the 1 m G-LiHT rasters (canopy.py's 1 m voxels share their
## grid, origin 0,0, so cells are wholly in or out), nothing on C-CAP or GAP
## modes, and PRISM by >1 mm for 43 gaps that straddle a 450 m cell (max 93 mm)
## — while taking ~90 s per coarse layer against under a second.
##
## Gaps are reprojected to 32161 for the interim layers (a vector transform,
## exact); the G-LiHT rasters are sampled in their own CRS, so nothing is
## resampled again. A covariate that does not cover a gap is NA.
##
## Usage:
##   Rscript scripts/04_gap_covariates.R --site lfdp        # newest run, all thresholds
##   Rscript scripts/04_gap_covariates.R --site lfdp --run c2599daebbaa973e
##
## Writes gaps_covariates.gpkg (footprints + columns) and gaps_covariates.csv
## next to each gaps.gpkg, overwriting earlier ones.
## ---------------------------------------------------------------------------

## --- Find the code (see 02_download.R) -------------------------------------
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
repo <- if (length(file_arg)) {
  dirname(dirname(normalizePath(sub("^--file=", "", file_arg[1]),
                                winslash = "/", mustWork = FALSE)))
} else {
  getwd()
}
options(pr_gaps.code_root = repo)
for (f in sort(list.files(file.path(repo, "R", "ingest"), pattern = "[.]R$",
                          full.names = TRUE))) {
  source(f)                   # gl_data_root, gl_msg, CRS_AREA, CCAP_CLASSES
}
suppressPackageStartupMessages({ library(sf); library(terra) })

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[i + 1]
}

## --- Which site, run and 2017 rasters ---------------------------------------
## The 2017 (pre-Maria) G-LiHT campaign whose DTM/slope/aspect/CHM cover each
## site in canopy.py's SITES. Add a row when a new site is run.
SITE_CAMPAIGN_2017 <- c(
  lfdp  = "PR_5March2017_EV1",
  ev1   = "PR_5March2017_EV1",
  fia12 = "PR_11March2017_FIA12"
)

site <- get_arg("--site", "lfdp")
if (!site %in% names(SITE_CAMPAIGN_2017)) {
  stop("unknown --site ", site, "; add it to SITE_CAMPAIGN_2017")
}
data_root <- gl_data_root()
gl_msg("data root: ", data_root)

runs_dir <- file.path(data_root, "runs", "canopy", site, "gaps")
run <- get_arg("--run", "")
if (!nzchar(run)) {
  ## Newest run that canopy.py finished (it writes run.json at the end).
  candidates <- list.files(runs_dir, pattern = "^run[.]json$", recursive = TRUE,
                           full.names = TRUE)
  if (!length(candidates)) stop("no finished gap runs under ", runs_dir)
  run <- basename(dirname(candidates[which.max(file.mtime(candidates))]))
}
gap_files <- Sys.glob(file.path(runs_dir, run, "threshold_*m", "gaps.gpkg"))
if (!length(gap_files)) stop("no threshold_*m/gaps.gpkg in ", file.path(runs_dir, run))
gl_msg(sprintf("site %s, run %s: %d threshold(s)", site, run, length(gap_files)))

## One raster per G-LiHT product. Campaigns are unpacked either to a single
## <campaign>_<P>.tif or to a <campaign>_<P>/ folder of strips plus a mosaic;
## use the mosaic when there is one, else stitch the strips with a VRT.
gliht_raster <- function(campaign, product) {
  dir <- file.path(data_root, "raw", "gliht", campaign, "lidar", "geotiff")
  single <- file.path(dir, sprintf("%s_%s.tif", campaign, product))
  if (file.exists(single)) return(rast(single))
  tifs <- list.files(file.path(dir, sprintf("%s_%s", campaign, product)),
                     pattern = "[.]tif$", full.names = TRUE)
  mosaic <- tifs[grepl("_mosaic_", basename(tifs))]
  if (length(mosaic)) return(rast(mosaic[1]))
  if (length(tifs)) return(vrt(tifs))
  stop("no ", product, " raster for ", campaign, " under ", dir,
       " — download it with scripts/02_download.R")
}
campaign <- SITE_CAMPAIGN_2017[[site]]
gliht <- lapply(c(dtm = "DTM", slope = "slope", aspect = "aspect", chm = "CHM"),
                function(p) gliht_raster(campaign, p))

## Interim covariates (ADR 008).
interim <- file.path(data_root, "interim", "covariates")
interim_raster <- function(layer, pattern) {
  f <- list.files(file.path(interim, layer), pattern = pattern, full.names = TRUE)
  if (!length(f)) stop("no ", layer, " raster matching ", pattern,
                       " — run 03_download_covars.R --reproject")
  rast(f[1])
}
ccap  <- interim_raster("ccap", "_32161[.]tif$")
gapcl <- interim_raster("gap_landcover", "_32161[.]tif$")
ppt   <- interim_raster("prism", "_ppt_.*_32161[.]tif$")
tmax  <- interim_raster("prism", "_tmax_.*_32161[.]tif$")
tmin  <- interim_raster("prism", "_tmin_.*_32161[.]tif$")
holdridge <- st_read(list.files(file.path(interim, "holdridge"), "[.]gpkg$",
                                full.names = TRUE)[1], quiet = TRUE)

## Class names for the categorical codes.
GAP_NAMES <- local({
  cl <- cats(gapcl)[[1]]
  setNames(as.character(cl[[2]]), cl[[1]])
})

## --- Summaries --------------------------------------------------------------
## Cell values in each gap, one row per (gap, cell). Every cell gets weight 1,
## so the summaries below are plain means and counts (see the header for why
## not area weights). raw = TRUE returns class codes, not the GAP raster's labels.
## Cropping the gaps' extent into memory first saves extract() going back to
## the 1 m EV1 mosaics on disk for every polygon.
cells <- function(r, polys) {
  v <- vect(polys)
  r <- crop(r[[1]], ext(v) + 2 * max(res(r)), snap = "out")
  if (prod(dim(r)[1:2]) < 5e7) r <- r * 1     # into memory, if it fits
  x <- as.data.frame(extract(r, v, raw = TRUE, ID = TRUE))  # raw: a matrix
  names(x) <- c("ID", "value")
  x$fraction <- 1
  x[!is.na(x$value), ]
}

## Each summary returns one value per gap (length n), NA where nothing was sampled.
by_gap <- function(x, n, fun) {
  out <- rep(NA_real_, n)
  if (!nrow(x)) return(out)
  s <- vapply(split(x, x$ID), fun, numeric(1))
  out[as.integer(names(s))] <- s
  out
}
weighted_mean <- function(x, n, scale = 1) {
  by_gap(x, n, function(d) sum(d$value * d$fraction) / sum(d$fraction)) * scale
}
weighted_mode <- function(x, n) {
  by_gap(x, n, function(d) {
    area <- tapply(d$fraction, d$value, sum)
    as.numeric(names(area)[which.max(area)])
  })
}
## Aspect is a direction: 350 and 10 average to 0, not 180.
circular_mean <- function(x, n) {
  by_gap(x, n, function(d) {
    rad <- d$value * pi / 180
    deg <- atan2(sum(sin(rad) * d$fraction), sum(cos(rad) * d$fraction)) * 180 / pi
    (deg + 360) %% 360
  })
}
cell_max <- function(x, n) by_gap(x, n, function(d) max(d$value))

## Holdridge is a vector: the zone covering most of each gap.
largest_zone <- function(polys) {
  out <- rep(NA_character_, nrow(polys))
  zones <- holdridge["LifeZonesDesc"]
  polys$.row <- seq_len(nrow(polys))
  hit <- suppressWarnings(st_intersection(polys[".row"], st_transform(zones, st_crs(polys))))
  if (!nrow(hit)) return(out)
  hit$area <- as.numeric(st_area(hit))
  hit <- st_drop_geometry(hit)
  hit <- hit[order(hit$.row, -hit$area), ]
  hit <- hit[!duplicated(hit$.row), ]
  out[hit$.row] <- as.character(hit$LifeZonesDesc)
  out
}

## --- Run each threshold -----------------------------------------------------
for (gap_file in gap_files) {
  out_dir <- dirname(gap_file)
  gaps <- st_read(gap_file, layer = "footprints", quiet = TRUE)
  n <- nrow(gaps)
  gl_msg(sprintf("%s: %d gaps", basename(out_dir), n))
  if (!n) next

  ## Interim layers in 32161; G-LiHT rasters in their own CRS.
  gaps_area <- st_transform(gaps, CRS_AREA)
  gaps_gliht <- st_transform(gaps, crs(gliht$dtm))

  ccap_code <- weighted_mode(cells(ccap, gaps_area), n)
  gap_code  <- weighted_mode(cells(gapcl, gaps_area), n)
  chm <- cells(gliht$chm, gaps_gliht)

  covars <- data.frame(
    object_id  = gaps$object_id,
    ccap_code  = ccap_code,
    ccap_class = unname(CCAP_CLASSES[as.character(ccap_code)]),
    gap_code   = gap_code,
    gap_class  = unname(GAP_NAMES[as.character(gap_code)]),
    holdridge  = largest_zone(gaps_area),
    ## PRISM grids are stored x100 (metadata units "mm*100"); see the registry.
    ppt_mm     = weighted_mean(cells(ppt,  gaps_area), n, scale = 0.01),
    tmax_c     = weighted_mean(cells(tmax, gaps_area), n, scale = 0.01),
    tmin_c     = weighted_mean(cells(tmin, gaps_area), n, scale = 0.01),
    elev_m     = weighted_mean(cells(gliht$dtm,   gaps_gliht), n),
    slope_deg  = weighted_mean(cells(gliht$slope, gaps_gliht), n),
    aspect_deg = circular_mean(cells(gliht$aspect, gaps_gliht), n),
    chm_mean_m = weighted_mean(chm, n),
    chm_max_m  = cell_max(chm, n),
    stringsAsFactors = FALSE
  )

  ## Keep canopy.py's attributes and geometry; covariates are appended.
  out <- cbind(gaps, covars[, -1])
  gpkg <- file.path(out_dir, "gaps_covariates.gpkg")
  if (file.exists(gpkg)) unlink(gpkg)
  st_write(out, gpkg, layer = "gaps_covariates", quiet = TRUE)
  write.csv(st_drop_geometry(out), file.path(out_dir, "gaps_covariates.csv"),
            row.names = FALSE)

  missing <- colSums(is.na(covars[, -1]))
  gl_msg(sprintf("  wrote %s; NA counts: %s", basename(gpkg),
                 paste(sprintf("%s=%d", names(missing), missing)[missing > 0],
                       collapse = ", ")))
}
gl_msg("done")

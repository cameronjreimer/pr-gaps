## ---------------------------------------------------------------------------
## 2017 G-LiHT rasters per gap-analysis site, and canopy rugosity from the CHM.
##
## Shared by scripts/03_download_covars.R (--rugosity) and
## scripts/04_gap_covariates.R. Nothing here runs when the file is sourced.
## ---------------------------------------------------------------------------

## The 2017 (pre-Maria) G-LiHT campaign whose DTM/slope/aspect/CHM cover each
## site in python/canopy.py's SITES. Add a row when a new site is run.
SITE_CAMPAIGN_2017 <- c(
  lfdp  = "PR_5March2017_EV1",
  ev1   = "PR_5March2017_EV1",
  fia12 = "PR_11March2017_FIA12"
)

## Where campaign folders live. PR_GAPS_GLIHT points elsewhere on the server,
## as it does for canopy.py.
gl_gliht_root <- function() {
  Sys.getenv("PR_GAPS_GLIHT", file.path(gl_data_root(), "raw", "gliht"))
}

## One raster per G-LiHT product. Campaigns are unpacked either to a single
## <campaign>_<P>.tif or to a <campaign>_<P>/ folder of strips plus a mosaic;
## use the mosaic when there is one, else stitch the strips with a VRT.
gl_gliht_raster <- function(campaign, product) {
  dir <- file.path(gl_gliht_root(), campaign, "lidar", "geotiff")
  single <- file.path(dir, sprintf("%s_%s.tif", campaign, product))
  if (file.exists(single)) return(terra::rast(single))
  tifs <- list.files(file.path(dir, sprintf("%s_%s", campaign, product)),
                     pattern = "[.]tif$", full.names = TRUE)
  mosaic <- tifs[grepl("_mosaic_", basename(tifs))]
  if (length(mosaic)) return(terra::rast(mosaic[1]))
  if (length(tifs)) return(terra::vrt(tifs))
  stop("no ", product, " raster for ", campaign, " under ", dir,
       " — download it with scripts/02_download.R")
}

## ---------------------------------------------------------------------------
## Canopy rugosity, following Han et al. 2026 (Global Change Biology, "Taller
## Trees Experienced Less Crown Damage During a Severe Hurricane in a Tropical
## Forest"). Their code (Zenodo 10.5281/zenodo.15097967,
## calculate_canopy_rugosity) takes the standard deviation (np.std, so the
## population SD) of 1 m 2017 CHM heights above 2 m within each 40 x 40 m
## quadrat.
##
## Two departures, both deliberate:
##   * A moving window centred on every cell instead of fixed quadrats, so each
##     gap gets the rugosity of its own surroundings. A centred window needs an
##     odd width: 41 x 41 cells (41 m), the nearest to their 40 m.
##   * Always the CHM. Their landscape-scale run passed the 2017 DSM to the same
##     function, which mixes terrain into the spread; their LFDP run used the
##     CHM, as the paper's text describes.
##
## Computed with separable box sums (sum, sum of squares, count of cells above
## 2 m), so the whole 41 M-cell EV1 mosaic takes ~1-2 min. Checked against a
## direct SD of each window: identical to 5 decimals.
##
## A window with no cell above 2 m gives NA, as in their code. Cells outside the
## CHM's data are NA. Windows at a swath edge use only the cells that have data.
## ---------------------------------------------------------------------------
RUGOSITY_WINDOW_M <- 41
RUGOSITY_MIN_HEIGHT_M <- 2

gl_canopy_rugosity <- function(chm, window = RUGOSITY_WINDOW_M,
                               min_height = RUGOSITY_MIN_HEIGHT_M, filename = "") {
  w <- round(window / terra::res(chm)[1])
  if (w %% 2 == 0) w <- w + 1                        # centred windows are odd
  box <- function(r) {                               # w x w sum, in two 1-D passes
    r <- terra::focal(r, matrix(1, 1, w), fun = "sum", fillvalue = 0)
    terra::focal(r, matrix(1, w, 1), fun = "sum", fillvalue = 0)
  }
  above <- !is.na(chm) & chm > min_height
  x <- terra::ifel(above, chm, 0)
  n   <- box(terra::ifel(above, 1, 0))
  s1  <- box(x)
  s2  <- box(x * x)
  m   <- s1 / n
  v   <- s2 / n - m * m
  v   <- terra::ifel(v < 0, 0, v)                    # rounding can dip below 0
  out <- terra::ifel(n > 0 & !is.na(chm), sqrt(v), NA)
  names(out) <- "rugosity_m"
  if (nzchar(filename)) {
    out <- terra::writeRaster(out, filename, overwrite = TRUE, datatype = "FLT4S",
                              gdal = c("COMPRESS=DEFLATE", "TILED=YES"))
  }
  out
}

## Every pre-Maria (2017) campaign folder under the G-LiHT root, plus the
## gap-analysis sites' campaigns. "_all" pre-merged mosaics are left out: they
## duplicate the dated flights (see MOSAIC_PATTERN in 00_config.R).
gl_campaigns_2017 <- function() {
  dirs <- basename(list.dirs(gl_gliht_root(), recursive = FALSE))
  dirs <- dirs[grepl(CAMPAIGN_INCLUDE, dirs) & !grepl(MOSAIC_PATTERN, dirs)]
  parsed <- gl_parse_campaign_name(dirs)
  sort(unique(c(dirs[!is.na(parsed$year) & parsed$year == 2017],
                unname(SITE_CAMPAIGN_2017))))
}

## The 2017 CHM to compute rugosity from. Prefers the unpacked raster (what
## 02_download.R leaves), and falls back to the packed archive as the G-LiHT
## server publishes it (<campaign>_CHM.tif.gz or .tar.gz), unpacked into
## `workdir` — the caller deletes that afterwards. NULL if there is neither.
gl_chm_for_rugosity <- function(campaign, workdir) {
  chm <- tryCatch(gl_gliht_raster(campaign, "CHM"), error = function(e) NULL)
  if (!is.null(chm)) return(chm)

  dir <- file.path(gl_gliht_root(), campaign, "lidar", "geotiff")
  packed <- file.path(dir, paste0(campaign, c("_CHM.tif.gz", "_CHM.tar.gz")))
  packed <- packed[file.exists(packed)]
  if (!length(packed)) return(NULL)

  dir.create(workdir, recursive = TRUE, showWarnings = FALSE)
  if (grepl("[.]tif[.]gz$", packed[1])) {
    tif <- file.path(workdir, sub("[.]gz$", "", basename(packed[1])))
    gl_gunzip(packed[1], tif)                       # 01_http.R
    return(terra::rast(tif))
  }
  gl_extract(packed[1], workdir)                    # 01_http.R
  tifs <- list.files(workdir, pattern = "[.]tif$", recursive = TRUE, full.names = TRUE)
  mosaic <- tifs[grepl("_mosaic_", basename(tifs))]
  if (length(mosaic)) terra::rast(mosaic[1]) else if (length(tifs)) terra::vrt(tifs) else NULL
}

## Where a campaign's rugosity raster lives. It stays in the campaign's own CRS
## and 1 m grid (unlike the EPSG:32161 interim layers): 04_gap_covariates.R
## samples it alongside the CHM it came from, so reprojecting would only blur it.
gl_rugosity_path <- function(campaign) {
  file.path(gl_data_root(), "interim", "covariates", "rugosity",
            sprintf("%s_CHM_rugosity_%dm.tif", campaign, RUGOSITY_WINDOW_M))
}

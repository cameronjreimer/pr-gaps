## ---------------------------------------------------------------------------
## Puerto Rico gaps — download the scripted covariate layers.
##
## Fetches what docs/covariates-plan.md lists as "scripted" transport, into
## $PR_GAPS_DATA/raw/covariates/<layer>/, and records each file in
## raw/covariates/MANIFEST.csv (URL, size, md5, arrival time, citation key).
## Nothing is clipped or reprojected here; harmonization is a later step.
##
## Not fetched, because the plan puts them elsewhere:
##   * 2017 G-LiHT dtm / slope / aspect / chm — already in GL_DEFAULT_PRODUCTS,
##     fetched by 02_download.R;
##
## Manual layers (transport = manual in docs/covariate-registry.csv) are not
## downloaded. Put the files in raw/covariates/<layer>/ by hand — currently
## ccap_high_res, a Digital Coast Data Viewer export (ID 6247) — and --download
## (or --register) checksums them into the manifest.
##
## Usage:
##   Rscript scripts/03_download_covars.R                 # dry run: lists files
##   Rscript scripts/03_download_covars.R --download      # fetch everything
##   Rscript scripts/03_download_covars.R --download --layers hansen,prism
##   Rscript scripts/03_download_covars.R --reproject     # raw/ -> interim/ EPSG:32161
##   Rscript scripts/03_download_covars.R --figures      # one map PNG per layer
##   (flags combine, e.g. --download --reproject --figures; --reproject needs
##    terra and sf, --figures also ggplot2, ggspatial, ragg, stringr, viridisLite)
##   Figures go to derived/covariates/figures/.
##
## Restartable: files already present are skipped. Exits 1 if any file failed.
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
  source(f)
}
stopifnot(requireNamespace("curl", quietly = TRUE))

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[i + 1]
}

## --- What to fetch ---------------------------------------------------------
## One row per file. `layer` is also the raw/covariates/ subdirectory, and the
## key into the source registry (docs/covariate-registry.csv), which holds the
## version, licence, citation and class-legend notes for each layer.
hansen_base <- paste0("https://storage.googleapis.com/earthenginepartners-hansen/",
                      "GFC-2025-v1.13/Hansen_GFC-2025-v1.13_")
prism_base  <- "https://prism.oregonstate.edu/normals_other/public/pr/grids/"
sb_file     <- "https://www.sciencebase.gov/catalog/file/get/560c3b2de4b058f706e5411e?f="

covar_file <- function(layer, url, name, unpack = FALSE) {
  data.frame(layer = layer, url = url, name = name, unpack = unpack,
             stringsAsFactors = FALSE)
}

prism_zip <- function(var) {
  name <- sprintf("PRISM_%s_pr_1963-1995_normal_450mM1_annual_asc.zip", var)
  covar_file("prism", paste0(prism_base, var, "/", name), name, unpack = TRUE)
}

COVAR_FILES <- rbind(
  ## Hansen GFC: granule 20N_070W covers the main island.
  covar_file("hansen", paste0(hansen_base, "treecover2000_20N_070W.tif"),
             "Hansen_GFC-2025-v1.13_treecover2000_20N_070W.tif"),
  covar_file("hansen", paste0(hansen_base, "lossyear_20N_070W.tif"),
             "Hansen_GFC-2025-v1.13_lossyear_20N_070W.tif"),
  covar_file("hansen", paste0(hansen_base, "datamask_20N_070W.tif"),
             "Hansen_GFC-2025-v1.13_datamask_20N_070W.tif"),

  ## C-CAP 2010, 30 m (InPort 48300).
  covar_file("ccap",
             paste0("https://chs.coast.noaa.gov/htdata/raster1/landcover/",
                    "bulkdownload/30m_lc/pr_2010_ccap_hr_land_cover20170214_30m.tif"),
             "pr_2010_ccap_hr_land_cover20170214_30m.tif"),

  ## PR GAP land cover (ScienceBase 560c3b2de4b058f706e5411e).
  covar_file("gap_landcover",
             paste0(sb_file, "__disk__da%2Fa9%2Fcf%2Fdaa9cfb5af0e5f616f1865973d855d0245368660"),
             "puertorico_gap_landcover2000.tif"),
  ## The .aux sidecar holds the class names (a raster attribute table); without
  ## it the GeoTIFF is bare integers. Keep it next to the .tif, same stem.
  covar_file("gap_landcover",
             paste0(sb_file, "__disk__0d%2F95%2F50%2F0d9550c0b042eba7a9039f9b74c2845a06dbad27"),
             "puertorico_gap_landcover2000.aux"),

  ## Holdridge life zones (geodatabase in a zip).
  covar_file("holdridge",
             "https://research.fs.usda.gov/sites/default/files/2026-07/iitf-pr_usvi_holdridgelifezones.zip",
             "iitf-pr_usvi_holdridgelifezones.zip", unpack = TRUE),

  ## Kennaway & Helmer 2023, RDS-2023-0022.
  covar_file("helmer_formations",
             "https://www.fs.usda.gov/rds/archive/products/RDS-2023-0022/RDS-2023-0022.zip",
             "RDS-2023-0022.zip", unpack = TRUE),

  ## PRISM annual normals. tmean is derived later as (tmax + tmin) / 2.
  prism_zip("ppt"), prism_zip("tmax"), prism_zip("tmin")
)

## Every layer fetched here must be in the registry, and each manifest row takes
## its citation_key from it — so a layer cannot be downloaded without being
## documented. Registry rows with no files here (ccap_hr is manual; the G-LiHT
## layers come from 02_download.R) are expected.
REGISTRY <- utils::read.csv(file.path(repo, "docs", "covariate-registry.csv"),
                            stringsAsFactors = FALSE)
unregistered <- setdiff(COVAR_FILES$layer, REGISTRY$layer)
if (length(unregistered)) {
  stop("layer(s) missing from docs/covariate-registry.csv: ",
       paste(unregistered, collapse = ", "))
}
COVAR_FILES$citation_key <- REGISTRY$citation_key[match(COVAR_FILES$layer,
                                                        REGISTRY$layer)]

layers <- get_arg("--layers", "")
if (nzchar(layers)) {
  wanted <- strsplit(layers, ",", fixed = TRUE)[[1]]
  unknown <- setdiff(wanted, REGISTRY$layer)
  if (length(unknown)) {
    stop("unknown layer(s): ", paste(unknown, collapse = ", "),
         " (choose from ", paste(REGISTRY$layer, collapse = ", "), ")")
  }
  COVAR_FILES <- COVAR_FILES[COVAR_FILES$layer %in% wanted, ]
}
COVAR_FILES$dest <- file.path(gl_data_root(), "raw", "covariates",
                              COVAR_FILES$layer, COVAR_FILES$name)
COVAR_MANIFEST <- file.path(gl_data_root(), "raw", "covariates", "MANIFEST.csv")

gl_msg("data root: ", gl_data_root())
gl_msg(sprintf("%d files across %d layers", nrow(COVAR_FILES),
               length(unique(COVAR_FILES$layer))))
do_download  <- "--download" %in% args
do_reproject <- "--reproject" %in% args
do_register  <- do_download || "--register" %in% args
do_figures   <- "--figures" %in% args
if (!do_download && !do_reproject && !do_register && !do_figures) {
  print(COVAR_FILES[, c("layer", "name")], row.names = FALSE)
  gl_msg("dry run — add --download to fetch, --reproject to harmonize, --figures to map")
  quit(status = 0)
}

## --- Fetch -----------------------------------------------------------------
## Same restartable .part/rename download as the G-LiHT files. Zips are kept
## after unpacking (they are small, and the archive is what a published checksum
## refers to); gl_download() sees the kept zip and skips it on re-runs.
failed <- character(0)
for (i in if (do_download) seq_len(nrow(COVAR_FILES)) else integer(0)) {
  item <- COVAR_FILES[i, ]
  already_held <- file.exists(item$dest)
  gl_msg(sprintf("[%d/%d] %s/%s%s", i, nrow(COVAR_FILES), item$layer, item$name,
                 if (already_held) " (held)" else ""))

  if (is.null(gl_try(gl_download(item$url, item$dest), item$name))) {
    failed <- c(failed, item$url)
    next
  }

  if (item$unpack) {
    gl_try(gl_extract(item$dest, dirname(item$dest)), item$name)
  }
  if (!already_held) {
    row <- gl_manifest_row(item$layer, item$name, item$url, item$dest)
    names(row)[names(row) == "campaign"] <- "layer"
    row$citation_key <- item$citation_key
    gl_append_manifest(row[, c("layer", "name", "url", "dest", "bytes", "md5",
                               "downloaded_utc", "citation_key")],
                       manifest_path = COVAR_MANIFEST)
  }
}

if (do_download) {
  gl_msg(sprintf("download done: %d failed", length(failed)))
  for (u in failed) cat("   ", u, "\n")
}

## --- Register manual layers --------------------------------------------------
## Files put in place by hand get the same manifest rows as downloaded ones. The
## manifest is keyed on `url`, and every file of a manual layer shares one
## landing page, so the file name is appended as a fragment to keep rows apart.
## Files already in the manifest are not re-hashed.
n_registered <- 0L
if (do_register) {
  manual <- REGISTRY[REGISTRY$transport == "manual", , drop = FALSE]
  if (nzchar(layers)) manual <- manual[manual$layer %in% strsplit(layers, ",")[[1]], ]
  known <- if (file.exists(COVAR_MANIFEST)) {
    utils::read.csv(COVAR_MANIFEST, stringsAsFactors = FALSE)$dest
  } else character(0)

  for (i in seq_len(nrow(manual))) {
    layer_dir <- file.path(gl_data_root(), "raw", "covariates", manual$layer[i])
    files <- list.files(layer_dir, recursive = TRUE)
    if (!length(files)) {
      gl_msg("manual layer ", manual$layer[i], ": nothing in ", layer_dir)
      next
    }
    files <- files[!file.path(layer_dir, files) %in% known]
    rows <- lapply(files, function(name) {
      row <- gl_manifest_row(manual$layer[i], name,
                             paste0(manual$url[i], "#", name),
                             file.path(layer_dir, name))
      names(row)[names(row) == "campaign"] <- "layer"
      row$citation_key <- manual$citation_key[i]
      row[, c("layer", "name", "url", "dest", "bytes", "md5", "downloaded_utc",
              "citation_key")]
    })
    gl_append_manifest(gl_stack(rows), manifest_path = COVAR_MANIFEST)
    n_registered <- n_registered + length(files)
  }
  gl_msg(sprintf("registered %d manual files", n_registered))
}

## --- Harmonize -------------------------------------------------------------
## covariates-plan.md, "Harmonization": a copy of every layer in EPSG:32161 at
## roughly its native cell size, under interim/covariates/. raw/ is untouched.
##   categorical rasters -> nearest neighbour; continuous -> bilinear;
##   vectors -> reprojected directly.
## Restartable: an output that already exists is skipped (delete it to redo).
##
## Four things worth knowing:
##   * The high-res C-CAP is four 2 m tiles in Conus Albers (EPSG:5070). They are
##     mosaicked and projected as one raster on a fixed 2 m grid, so there are
##     no seams or per-tile cell-size differences. Output is a single large
##     file, ccap_high_res_mosaic_32161.tif.
##   * Hansen is a 10 x 10 degree granule, mostly open ocean. Projecting all of
##     it would be slow and pointless, so it is cropped to PR_BBOX first. The
##     crop happens only in this interim copy; raw/ stays whole.
##   * The PRISM .asc grids ship with no CRS. They are assigned EPSG:4269
##     (NAD83 lat/lon), PRISM's documented datum; the difference from WGS84 is
##     about a metre, far below the 450 m cell.
##   * Holdridge is already NAD83(2011) / PR & VI (a 32161 variant) but is still
##     reprojected, so every vector in interim/ carries the same declared CRS.
PR_BBOX <- c(xmin = -68.0, xmax = -65.0, ymin = 17.5, ymax = 18.8)  # lon/lat

HARMONIZE <- data.frame(
  layer  = c("hansen", "hansen", "hansen", "ccap", "ccap_high_res",
             "gap_landcover", "helmer_formations", "prism", "holdridge"),
  ## regex on the path under raw/covariates/<layer>/
  find   = c("treecover2000.*[.]tif$", "lossyear.*[.]tif$", "datamask.*[.]tif$",
             "[.]tif$", "[.]tif$", "[.]tif$", "PR_Land_Cover_TIFF/.*[.]tif$",
             "[.]asc$", "[.]gdb$"),
  method = c("bilinear", "near", "near", "near", "near", "near", "near",
             "bilinear", "vector"),
  crop   = c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE),
  ## TRUE: all matching files are mosaicked and projected as one raster.
  mosaic = c(FALSE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE),
  ## Output cell size in metres; NA keeps terra's choice (about the native size).
  ## The high-res tiles come in slightly different sizes once each is projected
  ## alone, so the mosaic pins them to one 2 m grid.
  res    = c(NA, NA, NA, NA, 2, NA, NA, NA, NA),
  stringsAsFactors = FALSE
)

## `src` is one file, or several to be mosaicked: terra::vrt() lays them on a
## common grid without writing anything, and where tiles overlap the later one wins.
gl_harmonize_raster <- function(src, dest, method, crop, res = NA,
                                crs_if_missing = "EPSG:4269") {
  r <- if (length(src) > 1) terra::vrt(src) else terra::rast(src)
  ## Read the type now: a cropped raster is in memory-virtual form and reports
  ## none. Categorical output keeps the source integer type; bilinear needs floats.
  datatype <- if (method == "near") terra::datatype(r) else "FLT4S"
  if (terra::crs(r) == "") terra::crs(r) <- crs_if_missing
  if (crop) {
    box <- terra::project(terra::vect(terra::ext(PR_BBOX), crs = "EPSG:4326"),
                          terra::crs(r))
    r <- terra::crop(r, terra::ext(box), snap = "out")
  }
  target <- paste0("EPSG:", CRS_AREA)
  options <- c("COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=YES")
  if (is.na(res)) {
    terra::project(r, target, method = method, filename = dest,
                   datatype = datatype, overwrite = TRUE, gdal = options)
  } else {
    terra::project(r, target, method = method, res = res, filename = dest,
                   datatype = datatype, overwrite = TRUE, gdal = options)
  }
  invisible(dest)
}

gl_harmonize_vector <- function(src, dest) {
  layer_name <- sf::st_layers(src)$name[1]
  v <- sf::st_read(src, layer = layer_name, quiet = TRUE)
  v <- sf::st_transform(v, CRS_AREA)
  sf::st_write(v, dest, layer = layer_name, quiet = TRUE, delete_dsn = TRUE)
  invisible(dest)
}

n_harmonize_failed <- 0L
if (do_reproject) {
  stopifnot(requireNamespace("terra", quietly = TRUE),
            requireNamespace("sf", quietly = TRUE))
  raw_root <- file.path(gl_data_root(), "raw", "covariates")
  interim_root <- file.path(gl_data_root(), "interim", "covariates")

  for (i in seq_len(nrow(HARMONIZE))) {
    spec <- HARMONIZE[i, ]
    if (nzchar(layers) && !spec$layer %in% strsplit(layers, ",")[[1]]) next

    layer_dir <- file.path(raw_root, spec$layer)
    ## Match against the path under the layer directory, not just the file
    ## name, so a pattern can name the subdirectory it wants.
    candidates <- list.files(layer_dir, recursive = TRUE, include.dirs = TRUE)
    sources <- file.path(layer_dir, candidates[grepl(spec$find, candidates)])
    if (!length(sources)) {
      gl_msg("no raw files for ", spec$layer, " (", spec$find, ") — run --download")
      n_harmonize_failed <- n_harmonize_failed + 1L
      next
    }

    dir.create(file.path(interim_root, spec$layer), recursive = TRUE,
               showWarnings = FALSE)
    ## One job per file, or a single job for the whole set when mosaicking.
    jobs <- if (spec$mosaic) list(sources) else as.list(sources)
    for (src in jobs) {
      stem <- if (spec$mosaic) paste0(spec$layer, "_mosaic") else
        tools::file_path_sans_ext(basename(src))
      dest <- file.path(interim_root, spec$layer, paste0(
        stem, "_32161", if (spec$method == "vector") ".gpkg" else ".tif"))
      if (file.exists(dest)) { gl_msg("held: ", basename(dest)); next }

      gl_msg(sprintf("reproject [%s] %s%s", spec$method, basename(src[1]),
                     if (length(src) > 1) sprintf(" + %d more", length(src) - 1) else ""))
      partial <- paste0(dest, ".part")   # rename on success, as gl_download does
      partial <- sub("([.][^.]+)[.]part$", ".part\\1", partial)
      ok <- !is.null(gl_try(
        if (spec$method == "vector") gl_harmonize_vector(src, partial)
        else gl_harmonize_raster(src, partial, spec$method, spec$crop, spec$res),
        basename(src[1])))
      if (ok) {
        file.rename(partial, dest)
        ## GDAL may write a sidecar under the .part name; keep it with the output.
        sidecar <- paste0(partial, ".aux.xml")
        if (file.exists(sidecar)) file.rename(sidecar, paste0(dest, ".aux.xml"))
      } else {
        unlink(partial)
        n_harmonize_failed <- n_harmonize_failed + 1L
      }
    }
  }
  gl_msg(sprintf("reproject done: %d failed", n_harmonize_failed))
}

## --- Figures -----------------------------------------------------------------
## One map per harmonized layer, from interim/, with class legends or colour
## bars. Written to derived/covariates/figures/ (small, so it can be committed).
## Always redrawn — they are cheap next to the reprojection. See
## R/ingest/07_covariate_maps.R for what each one shows.
n_map_failed <- 0L
if (do_figures) {
  n_map_failed <- gl_covariate_maps(
    interim_root = file.path(gl_data_root(), "interim", "covariates"),
    raw_root     = file.path(gl_data_root(), "raw", "covariates"),
    out_dir      = file.path(repo, "derived", "covariates", "figures"),
    registry     = REGISTRY,
    boundary     = file.path(gl_data_root(), "interim", "boundary", "pr_main_island.gpkg"),
    layers      = if (nzchar(layers)) strsplit(layers, ",")[[1]] else NULL)
  gl_msg(sprintf("figures done: %d failed", n_map_failed))
}

quit(status = if (length(failed) || n_harmonize_failed || n_map_failed) 1 else 0)

## ---------------------------------------------------------------------------
## Step 5 (optional but important) — Exact footprints from the canopy height
## model.
##
## The footprints from step 2 are built from published polygons that are ~1 km
## across, so they overestimate: measured against the CHM, real coverage is
## 20-52% of the tile figure. The CHM itself settles the question, because a
## pixel has a height value exactly where the lidar saw the ground and is empty
## everywhere else. So: download the CHM, treat "has a value" as "was covered",
## and trace the outline of that.
##
## A CHM is roughly 7 MB gzipped per campaign, which makes this cheap for tens
## of campaigns and merely slow for hundreds. Run it for the campaigns that
## actually enter the analysis, before quoting any area.
##
## `cell_m` is the resolution the outline is traced at. The default of 10 m is
## a deliberate trade: 1 m is exact but slow, and coarser is faster and slightly
## generous around the edges.
##
## Produces:
##   derived/inventory/pr_footprints_chm.gpkg  layers: campaign_footprints_chm,
##                                             epoch_coverage_chm, repeat_chm
##   derived/inventory/pr_footprint_summary_chm.csv
##   derived/inventory/pr_repeat_summary_chm.csv
## ---------------------------------------------------------------------------

## Trace the outline of the pixels that have data in one raster.
##
## classify() replaces every actual height with 1 and leaves empty pixels empty,
## which turns the CHM into a plain yes/no coverage mask. aggregate(fun = "max")
## then coarsens it, keeping a block if ANY pixel in it had data, so the outline
## never shrinks below true coverage.
gl_raster_mask_polygons <- function(r, cell_m) {
  coarsen_by <- max(1, round(cell_m / mean(terra::res(r))))

  mask <- terra::classify(r, cbind(-Inf, Inf, 1L))
  if (coarsen_by > 1) {
    mask <- terra::aggregate(mask, fact = coarsen_by, fun = "max", na.rm = TRUE)
  }

  outline <- terra::as.polygons(mask, dissolve = TRUE)
  if (!length(outline)) return(NULL)
  outline <- outline[!is.na(terra::values(outline)[, 1]), ]   # drop the empty class
  if (!length(outline)) return(NULL)

  ## Hand the result over to sf and put it in the analysis CRS.
  outline <- sf::st_as_sf(outline)
  outline <- sf::st_transform(outline, CRS_AREA)
  sf::st_make_valid(outline)
}

## The exact covered area for one campaign.
##
## Handles both packagings: a single mosaic (_CHM.tif.gz), read straight out of
## the gzip by GDAL, and a tar of per-strip GeoTIFFs (_CHM.tar.gz), which has to
## be unpacked and traced strip by strip before the parts are merged.
gl_chm_footprint <- function(campaign, files, cell_m = 10) {
  chm <- files[files$campaign == campaign &
                 grepl("_CHM[.](tif|tar)[.]gz$", files$name), ]
  if (!nrow(chm)) return(NULL)

  local_path <- file.path(gl_paths()$products, campaign, chm$subdir[1], chm$name[1])
  gl_download(chm$url[1], local_path, chm$size_bytes[1])

  ## This writes into raw/, so it belongs in the manifest even though it did not
  ## come through the download planner.
  gl_append_manifest(gl_manifest_row(campaign, chm$name[1], chm$url[1],
                                     local_path, chm$modified[1]))

  if (grepl("[.]tar[.]gz$", local_path)) {
    unpacked_dir <- file.path(dirname(local_path),
                              sub("[.]tar[.]gz$", "", basename(local_path)))
    already_unpacked <- dir.exists(unpacked_dir) &&
      length(list.files(unpacked_dir, pattern = "[.]tif$", recursive = TRUE))
    if (!already_unpacked) gl_extract(local_path, unpacked_dir)

    strips <- list.files(unpacked_dir, pattern = "[.]tif$", recursive = TRUE,
                         full.names = TRUE)
    if (!length(strips)) return(NULL)

    ## Trace each strip separately, keeping geometry only: the strips carry
    ## different attribute values, which would stop them stacking together.
    strip_outlines <- list()
    for (strip in strips) {
      raster <- terra::rast(strip)
      traced <- gl_try(gl_raster_mask_polygons(raster, cell_m), basename(strip))
      if (is.null(traced)) next
      strip_outlines[[strip]] <- traced[, attr(traced, "sf_column")]
    }

    outline <- gl_stack(strip_outlines)
    if (is.null(outline)) return(NULL)
  } else {
    ## /vsigzip/ lets GDAL read the raster without unzipping it to disk first.
    raster <- terra::rast(paste0("/vsigzip/", normalizePath(local_path, winslash = "/")))
    outline <- gl_raster_mask_polygons(raster, cell_m)
    if (is.null(outline)) return(NULL)
  }

  footprint <- sf::st_sf(campaign    = campaign,
                         tile_source = "chm_mask",
                         geometry    = sf::st_union(sf::st_geometry(outline)))
  footprint$area_ha <- gl_area_ha(footprint)
  footprint
}

## Add previously refined campaigns back in, so results accumulate across runs:
## refine the Luquillo blocks today and more campaigns tomorrow, and the
## GeoPackage ends up holding both. Campaigns refined again in this run replace
## their older entry.
gl_carry_forward_refined <- function(footprints, gpkg_name) {
  gpkg <- file.path(gl_paths()$out, gpkg_name)
  if (!file.exists(gpkg)) return(footprints)

  previous <- tryCatch(sf::st_read(gpkg, "campaign_footprints_chm", quiet = TRUE),
                       error = function(e) NULL)
  if (is.null(previous) || !nrow(previous)) return(footprints)

  previous <- previous[!(previous$campaign %in% footprints$campaign), ]
  if (!nrow(previous)) return(footprints)

  previous <- gl_rename_geometry(previous, attr(footprints, "sf_column"))
  gl_msg(sprintf("carried %d previously refined campaigns forward", nrow(previous)))
  rbind(previous[, names(footprints)], footprints)
}

## Run step 5. `campaigns_subset` is normally the output of
## gl_repeat_campaigns() — the flights that actually overlap. Set
## overwrite = TRUE to discard earlier refinements instead of adding to them.
gl_step_refine_chm <- function(campaigns, files, campaigns_subset, cell_m = 10,
                               drop_mosaics = TRUE, overwrite = FALSE) {
  gl_init_dirs()

  outlines <- vector("list", length(campaigns_subset))
  for (i in seq_along(campaigns_subset)) {
    campaign <- campaigns_subset[i]
    gl_msg(sprintf("CHM footprint %d/%d: %s", i, length(campaigns_subset), campaign))
    outlines[[i]] <- gl_try(gl_chm_footprint(campaign, files, cell_m), campaign)
  }
  footprints <- gl_stack(outlines)
  if (is.null(footprints)) { gl_msg("no CHM footprints built"); return(NULL) }

  footprints <- gl_attach_metadata(footprints, campaigns)

  gpkg_name <- "pr_footprints_chm.gpkg"
  if (!overwrite) footprints <- gl_carry_forward_refined(footprints, gpkg_name)
  footprints <- footprints[order(footprints$date, footprints$campaign), ]

  ## Redo the epoch overlay on the exact footprints. These are the numbers to
  ## quote; the step-3 equivalents are upper bounds.
  epoch_cov <- gl_epoch_coverage(footprints, drop_mosaics)
  rep_cov   <- gl_repeat_coverage(epoch_cov)
  summary_table <- gl_repeat_summary_table(rep_cov)

  gl_write_gpkg(gpkg_name,
                list(campaign_footprints_chm = footprints,
                     epoch_coverage_chm = epoch_cov,
                     repeat_chm = rep_cov))

  gl_write_csv(summary_table, "pr_repeat_summary_chm.csv")
  gl_write_csv(sf::st_drop_geometry(footprints), "pr_footprint_summary_chm.csv")

  gl_msg("CHM-based repeat coverage (ha):")
  print(summary_table)

  list(footprints = footprints, epoch_coverage = epoch_cov,
       repeat_coverage = rep_cov, summary = summary_table)
}

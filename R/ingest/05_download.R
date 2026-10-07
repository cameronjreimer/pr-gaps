## ---------------------------------------------------------------------------
## Step 4 — Actually fetching data.
##
## Two functions on purpose: gl_plan_download() decides what would be fetched
## and how many gigabytes that is, and gl_run_download() does it. Seeing the
## size before committing matters here — the full Puerto Rico tree is 705 GB,
## and even the modest selections run to tens of GB.
##
## Downloads mirror the server's own layout under
## $PR_GAPS_DATA/raw/gliht/<campaign>/..., and every completed file is recorded
## in MANIFEST.csv with its source URL, size, checksum and time. That manifest
## is what makes the raw data re-obtainable without this code (plan, A.2).
## ---------------------------------------------------------------------------

## The products you can ask for. Each is a directory plus a filename pattern.
##
## WHY the directory is part of the definition rather than just the pattern:
## several names repeat across directories with different meanings. `_aspect`
## alone matches both <campaign>_aspect.tif.gz (1 m, from the DTM) and
## <campaign>_ground_aspect.tif.gz (26 m, in metrics/); `_chm_mean` likewise
## exists at both resolutions. Scoping by directory makes each product
## unambiguous instead of relying on ever-more-baroque regexes.
##
## Two packagings are in use and both have to be matched: a single mosaic
## GeoTIFF (<campaign>_CHM.tif.gz) and a tar of per-strip GeoTIFFs
## (<campaign>_CHM.tar.gz). Which one a campaign uses follows its LAS scheme.
GL_PRODUCTS <- list(
  ## --- lidar/geotiff/ : 1 m surfaces -------------------------------------
  chm          = list(subdir  = "lidar/geotiff/",
                      pattern = "_CHM[.](tif|tar)[.]gz$"),
  chm_rugosity = list(subdir  = "lidar/geotiff/",
                      pattern = "_chm_rugosity[.](tif|tar)[.]gz$"),
  dtm          = list(subdir  = "lidar/geotiff/",
                      pattern = "_DTM[.](tif|tar)[.]gz$"),
  slope        = list(subdir  = "lidar/geotiff/",
                      pattern = "_slope[.](tif|tar)[.]gz$"),
  aspect       = list(subdir  = "lidar/geotiff/",
                      pattern = "_aspect[.](tif|tar)[.]gz$"),
  ## DSM is omitted on purpose: DSM = CHM + DTM exactly (verified to 0.0000 m),
  ## so it is reconstructable from two products you already keep.
  dsm          = list(subdir  = "lidar/geotiff/",
                      pattern = "_DSM[.](tif|tar)[.]gz$"),

  ## --- lidar/geotiff/metrics/ : 26 m return statistics -------------------
  ## pulse_density is the nuisance variable for the point-density confound.
  pulse_density = list(subdir  = "lidar/geotiff/metrics/",
                       pattern = "_pulse_density[.](tif|tar)[.]gz$"),
  ## Height percentiles p10..p100 and density deciles d0..d9, all-returns
  ## stratum. The tree_, shrub_ and nmbu_tree_ strata are not included here.
  height_pct    = list(subdir  = "lidar/geotiff/metrics/",
                       pattern = "_all_p[0-9]+[.](tif|tar)[.]gz$"),
  density_dec   = list(subdir  = "lidar/geotiff/metrics/",
                       pattern = "_all_d[0-9]+[.](tif|tar)[.]gz$"),

  ## --- everything else ---------------------------------------------------
  las       = list(subdir  = "lidar/las/",
                   pattern = "[.]las[.]gz$"),        # by far the largest
  metadata  = list(subdir  = "metadata/",
                   pattern = "_metadata[.]pdf$"),    # altitude, scan angle, dates
  tiles_shp = list(subdir  = c("lidar/shp/", "lidar/shp/tiles/"),
                   pattern = "_tiles([.]zip|[.]shp|[.]shx|[.]dbf|[.]prj|_shp[.]tar[.]gz)$")
)

## Which rows of `files` belong to one named product.
gl_product_match <- function(files, product) {
  spec <- GL_PRODUCTS[[product]]
  files$subdir %in% spec$subdir & grepl(spec$pattern, files$name)
}

## Work out which files a request comes to, and where each would be saved.
## Nothing is fetched here.
gl_plan_download <- function(files, campaigns, products = GL_DEFAULT_PRODUCTS) {
  unknown <- setdiff(products, names(GL_PRODUCTS))
  if (length(unknown)) stop("unknown product(s): ", paste(unknown, collapse = ", "))

  wanted <- files[files$campaign %in% campaigns, , drop = FALSE]

  keep <- rep(FALSE, nrow(wanted))
  for (product in products) keep <- keep | gl_product_match(wanted, product)
  wanted <- wanted[keep, , drop = FALSE]
  if (!nrow(wanted)) return(wanted)

  ## sub() trims the subdirectory's trailing slash first: without it every path
  ## comes out with a doubled separator, which works but is then recorded that
  ## way in the manifest.
  wanted$dest <- file.path(gl_paths()$products, wanted$campaign,
                           sub("/+$", "", wanted$subdir), wanted$name)

  ## Label each file with the product it belongs to, for the size breakdown.
  ## Assigning in reverse order means the first matching product wins.
  wanted$product <- "other"
  for (product in rev(names(GL_PRODUCTS))) {
    wanted$product[gl_product_match(wanted, product)] <- product
  }

  wanted[order(wanted$campaign, wanted$subdir, wanted$name), ]
}

## How big the plan is, broken down by product.
gl_plan_size <- function(plan) {
  bytes_by_product <- split(plan$size_bytes, plan$product)
  products <- names(bytes_by_product)

  n_files <- integer(length(products))
  gigabytes <- numeric(length(products))
  for (i in seq_along(products)) {
    sizes <- bytes_by_product[[i]]
    n_files[i] <- length(sizes)
    gigabytes[i] <- round(sum(sizes, na.rm = TRUE) / 1024^3, 2)
  }

  data.frame(product = products, n_files = n_files, gb = gigabytes, row.names = NULL)
}

## Cut a plan down to a few campaigns, for a test transfer.
##
## WHY the smallest campaigns rather than the first N: a test run is there to
## prove that the fetching, the .part/rename restart and the manifest all work
## end to end, and any campaign demonstrates that equally well — so the ones
## worth picking are the ones that finish soonest. The spread is wide enough
## for this to matter: across the 241 campaigns in the Maria overlap the
## smallest plans to 77 MB and the largest to 11.5 GB, a factor of 150.
##
## Every product in the plan is kept, so the test exercises each one.
gl_plan_sample <- function(plan, n_campaigns) {
  if (!nrow(plan) || !is.finite(n_campaigns)) return(plan)

  bytes_by_campaign <- tapply(plan$size_bytes, plan$campaign, sum, na.rm = TRUE)
  smallest_first <- names(sort(bytes_by_campaign))
  keep <- head(smallest_first, max(0, n_campaigns))

  plan[plan$campaign %in% keep, , drop = FALSE]
}

## ---------------------------------------------------------------------------
## The manifest: one row per file pulled into raw/, with its source URL, size,
## checksum and the time it arrived. Appendix A.2 makes this the record that lets
## someone else re-obtain the raw data without this code.
##
## WHY these are separate from gl_run_download(): files reach raw/ by two
## routes — the download planner below, and the CHM refinement in
## 06_refine_chm.R — and both have to be recorded, or the manifest describes
## only part of what is on disk.
##
## Note that the tile shapefiles are NOT manifested. They live in interim/,
## are regenerable from the URLs in pr_files.csv, and are not raw data.
## ---------------------------------------------------------------------------

## Describe one file that has just been downloaded.
##
## `unpacked_to` is filled in afterwards, once the archive has been extracted:
## the row has to be built first, while the archive is still on disk, because
## its size and checksum cannot be recovered once it has been deleted.
gl_manifest_row <- function(campaign, name, url, dest,
                            server_modified = NA_character_, verify_md5 = TRUE,
                            unpacked_to = NA_character_) {
  data.frame(
    campaign        = campaign,
    name            = name,
    url             = url,
    dest            = dest,
    bytes           = file.size(dest),
    server_modified = server_modified,
    md5             = if (verify_md5) unname(tools::md5sum(dest)) else NA_character_,
    unpacked_to     = unpacked_to,
    downloaded_utc  = format(Sys.time(), tz = "UTC", usetz = TRUE),
    stringsAsFactors = FALSE
  )
}

## Merge rows into MANIFEST.csv. A new row replaces any older entry for the same
## URL, so re-downloading a file updates its record rather than duplicating it.
gl_append_manifest <- function(rows) {
  if (is.null(rows) || !nrow(rows)) return(invisible(NULL))

  manifest_path <- file.path(gl_paths()$products, "MANIFEST.csv")
  if (file.exists(manifest_path)) {
    previous <- utils::read.csv(manifest_path, stringsAsFactors = FALSE)
    previous <- previous[!(previous$url %in% rows$url), , drop = FALSE]

    ## A manifest written before a column existed is missing it. Give each side
    ## the other's columns as NA so the two can be stacked.
    for (column in setdiff(names(rows), names(previous))) previous[[column]] <- NA
    for (column in setdiff(names(previous), names(rows))) rows[[column]] <- NA

    rows <- rbind(previous[, names(rows), drop = FALSE], rows)
  }

  dir.create(dirname(manifest_path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(rows, manifest_path, row.names = FALSE)
  invisible(manifest_path)
}

## Carry out a plan.
##
## Defaults to a dry run, which prints the size and fetches nothing — call it
## again with dry_run = FALSE to transfer. The transfer is restartable: files we
## already hold are skipped (see gl_download), so re-running after an
## interruption picks up the remainder.
##
## `unpack` names the products whose archives are extracted and then deleted —
## see GL_UNPACK_PRODUCTS in 00_config.R for what that costs in disk. Pass
## character(0) to leave every download packed.
gl_run_download <- function(plan, dry_run = TRUE, verify_md5 = TRUE,
                            unpack = GL_UNPACK_PRODUCTS) {
  if (!nrow(plan)) { gl_msg("nothing to download"); return(invisible(NULL)) }

  sizes <- gl_plan_size(plan)
  gl_msg(sprintf("download plan: %d files, %.2f GB", nrow(plan),
                 sum(plan$size_bytes, na.rm = TRUE) / 1024^3))
  print(sizes)
  if (dry_run) {
    gl_msg("dry run — call gl_run_download(plan, dry_run = FALSE) to fetch")
    return(invisible(sizes))
  }

  ## Fetch each file, unpack it if it is one of the archived products, and
  ## describe what arrived. The manifest is written once at the end rather than
  ## per file, so a long plan does not rewrite the CSV hundreds of times.
  records <- vector("list", nrow(plan))
  n_unpacked <- 0L
  for (i in seq_len(nrow(plan))) {
    gl_msg(sprintf("[%d/%d] %s", i, nrow(plan), plan$name[i]))
    gl_download(plan$url[i], plan$dest[i], plan$size_bytes[i])

    ## A file we already held in unpacked form has no archive to measure, and
    ## its original row is already in the manifest — leave that row alone.
    if (!file.exists(plan$dest[i])) next

    row <- gl_manifest_row(plan$campaign[i], plan$name[i], plan$url[i],
                           plan$dest[i], plan$modified[i], verify_md5)

    if (plan$product[i] %in% unpack) {
      row$unpacked_to <- gl_unpack_archive(plan$dest[i])
      if (!is.na(row$unpacked_to)) n_unpacked <- n_unpacked + 1L
    }
    records[[i]] <- row
  }

  manifest_path <- gl_append_manifest(gl_stack(records))
  gl_msg(sprintf("downloaded %d files (%d unpacked); manifest: %s",
                 nrow(plan), n_unpacked, manifest_path))
  invisible(manifest_path)
}

## The campaigns holding repeat coverage between two epochs — the usual input to
## gl_plan_download(). Both flights of every qualifying pair are returned, since
## a comparison needs both dates.
gl_repeat_campaigns <- function(pairs, epoch_a, epoch_b, min_overlap_ha = 25) {
  if (is.null(pairs)) return(character(0))
  wanted_epochs <- c(epoch_a, epoch_b)
  selected <- pairs[pairs$epoch_a %in% wanted_epochs &
                      pairs$epoch_b %in% wanted_epochs &
                      pairs$overlap_ha >= min_overlap_ha, ]
  unique(c(selected$campaign_a, selected$campaign_b))
}

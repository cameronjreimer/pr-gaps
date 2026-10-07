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

## The products you can ask for, as patterns matching the published file names.
##
## Two packagings are in use across campaigns and both have to be matched: a
## single mosaic GeoTIFF (<campaign>_CHM.tif.gz) and a tar of per-strip GeoTIFFs
## (<campaign>_CHM.tar.gz).
GL_PRODUCTS <- list(
  chm       = "_CHM[.](tif|tar)[.]gz$",     # canopy height model
  dtm       = "_DTM[.](tif|tar)[.]gz$",     # bare-earth terrain
  dsm       = "_DSM[.](tif|tar)[.]gz$",     # top-of-surface
  slope     = "_slope[.](tif|tar)[.]gz$",
  las       = "[.]las[.]gz$",               # the point clouds; by far the largest
  metrics   = "^.*_all_(p[0-9]+|mean|qmean|kurt|d[0-9])[.]tif[.]gz$",
  metadata  = "_metadata[.]pdf$",           # flight altitude, scan angle, dates
  tiles_shp = "_tiles([.]zip|[.]shp|[.]shx|[.]dbf|[.]prj|_shp[.]tar[.]gz)$"
)

## Work out which files a request comes to, and where each would be saved.
## Nothing is fetched here.
gl_plan_download <- function(files, campaigns, products = c("chm", "dtm")) {
  unknown <- setdiff(products, names(GL_PRODUCTS))
  if (length(unknown)) stop("unknown product(s): ", paste(unknown, collapse = ", "))

  patterns <- unlist(GL_PRODUCTS[products], use.names = FALSE)
  wanted <- files[files$campaign %in% campaigns, , drop = FALSE]
  wanted <- wanted[grepl(paste(patterns, collapse = "|"), wanted$name), , drop = FALSE]
  if (!nrow(wanted)) return(wanted)

  wanted$dest <- file.path(gl_paths()$products, wanted$campaign, wanted$subdir,
                           wanted$name)

  ## Label each file with the product it belongs to, for the size breakdown.
  ## Assigning in reverse order means the first matching product wins, so a file
  ## matching two patterns is reported under the earlier one.
  wanted$product <- "other"
  for (product in rev(names(GL_PRODUCTS))) {
    wanted$product[grepl(GL_PRODUCTS[[product]], wanted$name)] <- product
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
gl_manifest_row <- function(campaign, name, url, dest,
                            server_modified = NA_character_, verify_md5 = TRUE) {
  data.frame(
    campaign        = campaign,
    name            = name,
    url             = url,
    dest            = dest,
    bytes           = file.size(dest),
    server_modified = server_modified,
    md5             = if (verify_md5) unname(tools::md5sum(dest)) else NA_character_,
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
    rows <- rbind(previous[!(previous$url %in% rows$url), ], rows)
  }

  dir.create(dirname(manifest_path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(rows, manifest_path, row.names = FALSE)
  invisible(manifest_path)
}

## Carry out a plan.
##
## Defaults to a dry run, which prints the size and fetches nothing — call it
## again with dry_run = FALSE to transfer. The transfer is restartable: files
## already present at the published size are skipped (see gl_download), so
## re-running after an interruption picks up the remainder.
gl_run_download <- function(plan, dry_run = TRUE, verify_md5 = TRUE) {
  if (!nrow(plan)) { gl_msg("nothing to download"); return(invisible(NULL)) }

  sizes <- gl_plan_size(plan)
  gl_msg(sprintf("download plan: %d files, %.2f GB", nrow(plan),
                 sum(plan$size_bytes, na.rm = TRUE) / 1024^3))
  print(sizes)
  if (dry_run) {
    gl_msg("dry run — call gl_run_download(plan, dry_run = FALSE) to fetch")
    return(invisible(sizes))
  }

  ## Fetch each file and describe what arrived. The manifest is written once at
  ## the end rather than per file, so a long plan does not rewrite the CSV
  ## hundreds of times.
  records <- vector("list", nrow(plan))
  for (i in seq_len(nrow(plan))) {
    gl_msg(sprintf("[%d/%d] %s", i, nrow(plan), plan$name[i]))
    gl_download(plan$url[i], plan$dest[i], plan$size_bytes[i])
    records[[i]] <- gl_manifest_row(plan$campaign[i], plan$name[i], plan$url[i],
                                    plan$dest[i], plan$modified[i], verify_md5)
  }

  manifest_path <- gl_append_manifest(gl_stack(records))
  gl_msg(sprintf("downloaded %d files; manifest: %s", nrow(plan), manifest_path))
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

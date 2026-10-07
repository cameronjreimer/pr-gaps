## ---------------------------------------------------------------------------
## G-LiHT Puerto Rico — flight-path inventory and repeat-coverage overlay.
##
## Answers three questions, in order:
##   1. What did G-LiHT fly over Puerto Rico, and what files exist?  (02_crawl)
##   2. What ground does each flight cover?                     (03_footprints)
##   3. Where did they fly the same ground more than once?          (04_repeat)
## and then reports the result and prints what downloading it would cost.
##
## Usage (from anywhere — the script locates the repository itself):
##   Rscript scripts/01_build_inventory.R              # full run
##   Rscript scripts/01_build_inventory.R --max 10     # smoke test, 10 campaigns
##   Rscript scripts/01_build_inventory.R --refresh    # ignore cached listings
##   Rscript scripts/01_build_inventory.R --reuse      # skip the crawl and the
##                                                     # footprint rebuild
##   Rscript scripts/01_build_inventory.R --refine repeat
##   Rscript scripts/01_build_inventory.R --reuse --download 2   # test transfer
##
## Bulk downloads go to $PR_GAPS_DATA (default: the `data/` sibling of this
## repository). Inventory artefacts go to derived/inventory/ and are committed.
##
## Nothing large is downloaded unless you ask: the default run fetches only
## directory listings and small shapefiles, and ends with a *dry-run* plan.
## --download N turns that into a real transfer of the N smallest campaigns,
## which is the way to test the download path without committing to 544 GB.
## ---------------------------------------------------------------------------

## --- Find the code ---------------------------------------------------------
## Work out where this repository is from the script's own path, so that the
## working directory does not matter. Rscript passes the path as "--file=...";
## when the file is sourced by hand instead, fall back to the current directory.
arguments <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", arguments, value = TRUE)

if (length(file_arg) > 0) {
  script_path <- sub("^--file=", "", file_arg[1])
  script_path <- normalizePath(script_path, winslash = "/", mustWork = FALSE)
  repo <- dirname(dirname(script_path))    # scripts/01_build_inventory.R -> repo
} else {
  repo <- getwd()
}
options(pr_gaps.code_root = repo)

r_dir <- file.path(repo, "R")
if (!dir.exists(r_dir)) {
  stop("cannot find R/ under '", repo, "'; set PR_GAPS_CODE to the repository root")
}

## Load every function. ingest/ comes before inventory/ because 00_config.R has
## to define the paths before anything else uses them.
for (subdir in c("ingest", "inventory")) {
  r_files <- list.files(file.path(r_dir, subdir), pattern = "[.]R$", full.names = TRUE)
  for (f in sort(r_files)) {
    source(f)
  }
}

suppressPackageStartupMessages(library(sf))
stopifnot(requireNamespace("curl", quietly = TRUE),
          requireNamespace("jsonlite", quietly = TRUE))

## --- Read the command line -------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[i + 1]
}
max_campaigns <- as.numeric(get_arg("--max", Inf))
refresh <- "--refresh" %in% args

gl_msg("data root: ", gl_data_root())

## --- Step 1: what exists ---------------------------------------------------
## The crawl makes no network requests on a repeat run — every directory listing
## was written to disk as JSON the first time it was read. What it still costs is
## re-opening and re-parsing ~1,800 of those files, about 50 seconds, to rebuild
## two tables that the last run already wrote out. --reuse skips that.
##
## --refresh and --max both change what a crawl would produce, so either one
## forces a real crawl regardless.
state_rds <- file.path(gl_paths()$out, "pr_gliht_state.rds")
reuse <- "--reuse" %in% args
previous <- NULL
if (reuse && !refresh && !is.finite(max_campaigns) && file.exists(state_rds)) {
  previous <- readRDS(state_rds)$inventory
}

if (!is.null(previous$files) && !is.null(previous$campaigns)) {
  inv <- previous
  gl_msg(sprintf("reusing inventory: %d files across %d campaigns (not re-crawled)",
                 nrow(inv$files), nrow(inv$campaigns)))
} else {
  inv <- gl_step_inventory(refresh = refresh, max_campaigns = max_campaigns)
}

## --- Step 2: flight paths and coverage footprints --------------------------
## Rebuilding reads ~300 small shapefiles and takes a few minutes even when the
## downloads are cached, so --reuse reloads the last GeoPackage instead.
fp_gpkg <- file.path(gl_paths()$out, "pr_footprints.gpkg")
if (reuse && file.exists(fp_gpkg)) {
  gl_msg("reusing ", fp_gpkg)
  fps <- list(tiles      = st_read(fp_gpkg, "tiles", quiet = TRUE),
              footprints = st_read(fp_gpkg, "campaign_footprints", quiet = TRUE))
} else {
  fps <- gl_step_footprints(inv$campaigns, inv$files)
}

## --- Step 3: repeat coverage -----------------------------------------------
rep <- gl_step_repeat(fps$tiles, fps$footprints)

## --- Step 4: tables and figures --------------------------------------------
gl_step_report(fps$footprints, rep$epoch_coverage, rep$repeat_coverage)

## --- Step 5: what a download would cost, and optionally a test transfer ----
## The 2017 -> 2018 (Hurricane Maria) interval is the chapter's core, so the
## plan is built against that overlap. The dry run fetches nothing.
maria <- gl_repeat_campaigns(rep$campaign_pairs, "2017_pre", "2018_post",
                             min_overlap_ha = 25)
gl_msg(sprintf("%d campaigns carry >=25 ha of 2017 x 2018 overlap", length(maria)))
plan <- gl_plan_download(inv$files, maria)      # GL_DEFAULT_PRODUCTS, see 00_config.R
gl_run_download(plan, dry_run = TRUE)

## --download turns the dry run into a real transfer, limited to a number of
## campaigns so the first one can be a test rather than a week of bandwidth:
##
##   --download 2       fetch the 2 smallest campaigns in the plan
##   --download all     fetch everything in it (544 GB — read the breakdown first)
##
## Files already on disk at the published size are skipped, so re-running after
## an interruption resumes, and raising the number adds campaigns to what is
## already there rather than starting over.
download_spec <- get_arg("--download", "")
if ("--download" %in% args && !nzchar(download_spec)) {
  stop("--download needs a number of campaigns, or 'all'")
}

if (nzchar(download_spec)) {

  if (identical(download_spec, "all")) {
    n_campaigns <- Inf
  } else {
    n_campaigns <- suppressWarnings(as.numeric(download_spec))
    if (is.na(n_campaigns)) stop("--download takes a number of campaigns, or 'all'")
  }

  test_plan <- gl_plan_sample(plan, n_campaigns)
  gl_msg(sprintf("downloading %d of %d campaigns: %d files, %.2f GB",
                 length(unique(test_plan$campaign)),
                 length(unique(plan$campaign)), nrow(test_plan),
                 sum(test_plan$size_bytes, na.rm = TRUE) / 1024^3))

  ## --prune-mosaics drops the redundant mosaic raster from each archive as it
  ## is unpacked. Off unless asked for; see GL_PRUNE_MOSAICS in 05_download.R,
  ## and gl_prune_all_mosaics() for rasters already on disk.
  gl_run_download(test_plan, dry_run = FALSE,
                  prune_mosaics = "--prune-mosaics" %in% args)
}

## --- Step 6 (opt-in): exact footprints from the CHM ------------------------
## Step 2's footprints are ~1 km granular and overestimate badly for single
## strips (PR_15March2017_EV1: 1,335 ha of tiles against 268 ha of CHM). Refine
## whichever campaigns matter before quoting any area.
##
##   --refine repeat        every campaign with 2017 x 2018 overlap (~7 GB)
##   --refine re:_EV[0-9]   campaigns matching a regex (the Luquillo blocks)
##   --refine A,B,C         a literal list
refine_spec <- get_arg("--refine", "")
refined <- NULL
if (nzchar(refine_spec)) {

  if (identical(refine_spec, "repeat")) {
    subset <- maria
  } else if (grepl("^re:", refine_spec)) {
    pattern <- sub("^re:", "", refine_spec)
    subset <- grep(pattern, inv$campaigns$campaign, value = TRUE)
  } else {
    subset <- strsplit(refine_spec, ",", fixed = TRUE)[[1]]
  }

  ## Mosaics duplicate ground already covered by the dated flights.
  mosaics <- inv$campaigns$campaign[inv$campaigns$is_mosaic]
  subset <- setdiff(subset, mosaics)
  gl_msg(sprintf("refining %d campaigns from their CHM", length(subset)))
  refined <- gl_step_refine_chm(inv$campaigns, inv$files, subset)
}

## Everything the run produced, for picking up interactively afterwards.
saveRDS(list(inventory = inv, footprints = fps, repeat_coverage = rep,
             maria_campaigns = maria, plan = plan, refined = refined),
        file.path(gl_paths()$out, "pr_gliht_state.rds"))
gl_msg("done — see derived/inventory/")

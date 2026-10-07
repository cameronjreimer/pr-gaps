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
##   Rscript scripts/01_build_inventory.R --reuse      # reload the last footprints
##   Rscript scripts/01_build_inventory.R --refine repeat
##
## Bulk downloads go to $PR_GAPS_DATA (default: the `data/` sibling of this
## repository). Inventory artefacts go to derived/inventory/ and are committed.
##
## Nothing large is downloaded unless you ask: the default run fetches only
## directory listings and small shapefiles, and ends with a *dry-run* plan.
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
inv <- gl_step_inventory(refresh = refresh, max_campaigns = max_campaigns)

## --- Step 2: flight paths and coverage footprints --------------------------
## Rebuilding reads ~300 small shapefiles and takes a few minutes even when the
## downloads are cached, so --reuse reloads the last GeoPackage instead.
fp_gpkg <- file.path(gl_paths()$out, "pr_footprints.gpkg")
if ("--reuse" %in% args && file.exists(fp_gpkg)) {
  gl_msg("reusing ", fp_gpkg)
  fps <- list(tiles      = st_read(fp_gpkg, "tiles", quiet = TRUE),
              footprints = st_read(fp_gpkg, "campaign_footprints", quiet = TRUE))
} else {
  fps <- gl_step_footprints(inv$campaigns, inv$files)
}

## --- Step 3: repeat coverage -----------------------------------------------
rep <- gl_step_repeat(fps$tiles, fps$footprints)

## --- Step 4: tables and figures --------------------------------------------
gl_step_report(fps$footprints, rep$epoch_coverage, rep$repeat_coverage,
               rep$campaign_pairs)

## --- Step 5: what a download would cost ------------------------------------
## The 2017 -> 2018 (Hurricane Maria) interval is the chapter's core, so the
## plan is built against that overlap. Nothing is fetched while dry_run = TRUE.
maria <- gl_repeat_campaigns(rep$campaign_pairs, "2017_pre", "2018_post",
                             min_overlap_ha = 25)
gl_msg(sprintf("%d campaigns carry >=25 ha of 2017 x 2018 overlap", length(maria)))
plan <- gl_plan_download(inv$files, maria)      # GL_DEFAULT_PRODUCTS, see 00_config.R
gl_run_download(plan, dry_run = TRUE)

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

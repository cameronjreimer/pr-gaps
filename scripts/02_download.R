## ---------------------------------------------------------------------------
## G-LiHT Puerto Rico — bulk download only.
##
## The download step of 01_build_inventory.R, without the crawl, footprints,
## reports and figures around it. Written for running on a cluster:
##   * it needs only the curl and jsonlite packages — no sf, terra or GDAL;
##   * it reads the inventory from derived/inventory/pr_gliht_state.rds, which
##     is gitignored, so copy that file over from wherever the inventory was
##     built;
##   * it refuses to run unless PR_GAPS_DATA is set, because the default data
##     root sits beside the repository — usually in a home directory whose
##     quota ~600 GB would overrun.
##
## Usage:
##   Rscript scripts/02_download.R                       # dry run: sizes only
##   Rscript scripts/02_download.R --download 2          # 2 smallest campaigns
##   Rscript scripts/02_download.R --download all \
##       --products chm,dtm,slope,aspect,pulse_density,metadata --prune-mosaics
##   Rscript scripts/02_download.R --download all --products las
##
## Restartable: re-run the same command after a wall-time kill and only what is
## missing is fetched. Exits with status 1 if any file failed to download.
## Run one copy at a time per data root — MANIFEST.csv is rewritten in place.
## ---------------------------------------------------------------------------

## --- Find the code (see 01_build_inventory.R) ------------------------------
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
repo <- if (length(file_arg)) {
  dirname(dirname(normalizePath(sub("^--file=", "", file_arg[1]),
                                winslash = "/", mustWork = FALSE)))
} else {
  getwd()
}
options(pr_gaps.code_root = repo)

## Only ingest/ — inventory/ is the spatial half, and is what needs sf.
for (f in sort(list.files(file.path(repo, "R", "ingest"), pattern = "[.]R$",
                          full.names = TRUE))) {
  source(f)
}
stopifnot(requireNamespace("curl", quietly = TRUE))

## --- Read the command line -------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[i + 1]
}

if (!nzchar(Sys.getenv("PR_GAPS_DATA"))) {
  stop("set PR_GAPS_DATA to the data root before downloading ",
       "(the default, beside the repository, is rarely where 600 GB should go)")
}
gl_msg("data root: ", gl_data_root())

products <- get_arg("--products", "")
products <- if (nzchar(products)) {
  strsplit(products, ",", fixed = TRUE)[[1]]
} else {
  GL_DEFAULT_PRODUCTS
}

## --- Build the plan --------------------------------------------------------
## The plan is rebuilt rather than taken from state$plan, whose destination
## paths point at whichever machine built the inventory.
state_rds <- file.path(gl_paths()$out, "pr_gliht_state.rds")
if (!file.exists(state_rds)) {
  stop("no ", state_rds, " — copy it from the machine that ran ",
       "01_build_inventory.R, or run that here first")
}
state <- readRDS(state_rds)
gl_msg(sprintf("%d campaigns carry >=25 ha of 2017 x 2018 overlap",
               length(state$maria_campaigns)))
plan <- gl_plan_download(state$inventory$files, state$maria_campaigns, products)

## --- Fetch -----------------------------------------------------------------
download_spec <- get_arg("--download", "")
if ("--download" %in% args && !nzchar(download_spec)) {
  stop("--download needs a number of campaigns, or 'all'")
}
if (!nzchar(download_spec)) {
  gl_run_download(plan, dry_run = TRUE)
  quit(status = 0)
}

n_campaigns <- if (identical(download_spec, "all")) Inf else
  suppressWarnings(as.numeric(download_spec))
if (is.na(n_campaigns)) stop("--download takes a number of campaigns, or 'all'")

plan <- gl_plan_sample(plan, n_campaigns)
failed <- gl_run_download(plan, dry_run = FALSE,
                          prune_mosaics = "--prune-mosaics" %in% args)
quit(status = if (NROW(failed)) 1 else 0)

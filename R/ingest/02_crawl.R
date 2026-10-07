## ---------------------------------------------------------------------------
## Step 1 — What exists on the server?
##
## Walks the G-LiHT file tree and writes down every Puerto Rico flight and every
## file belonging to it. Nothing is downloaded here except the directory pages
## themselves; the result is a catalogue you can filter before committing to any
## real transfer.
##
## Produces:
##   derived/inventory/pr_campaigns.csv  one row per flight, with dates and sizes
##   derived/inventory/pr_files.csv      one row per downloadable file
## ---------------------------------------------------------------------------

## Pull the date and site out of a campaign directory name.
##
## Names come in two shapes:
##   PR_<day><Month><year>_<block>   e.g. PR_15March2017_EV1
##   PR_<Month><year>_<block>        e.g. PR_March2020_EV1_all  (a merged mosaic)
##
## Two quirks in the published tree are handled here rather than being cleaned up
## later, because they only affect name parsing: one campaign group writes the
## year as "018" instead of "2018" (PR_2May018_*), and the mosaics have no day.
gl_parse_campaign_name <- function(x) {
  pattern <- "^PR_([0-9]{0,2})([A-Za-z]+)([0-9]{3,4})_(.+)$"
  matches <- regmatches(x, regexec(pattern, x))
  matched <- lengths(matches) == 5L               # whole match + 4 capture groups

  ## Lay the capture groups out as a character matrix, one row per name, so that
  ## unparseable names simply stay NA instead of needing a separate branch.
  groups <- matrix(NA_character_, nrow = length(x), ncol = 4)
  if (any(matched)) {
    ## Each match is c(whole match, day, month, year, block); drop column 1.
    matched_rows <- do.call(rbind, matches[matched])
    groups[matched, ] <- matched_rows[, -1, drop = FALSE]
  }

  ## "018" -> 2018. Any two-digit year in this dataset is a 2000s year.
  year <- suppressWarnings(as.integer(groups[, 3]))
  year[!is.na(year) & year < 100] <- year[!is.na(year) & year < 100] + 2000L

  ## Month names are spelled out ("March"), but accept abbreviations too.
  month <- match(tolower(groups[, 2]), tolower(month.name))
  month[is.na(month)] <- match(tolower(groups[is.na(month), 2]), tolower(month.abb))

  day <- suppressWarnings(as.integer(groups[, 1]))
  date <- rep(as.Date(NA), length(x))
  complete <- !is.na(day) & !is.na(month) & !is.na(year)
  date[complete] <- as.Date(sprintf("%04d-%02d-%02d",
                                    year[complete], month[complete], day[complete]))

  data.frame(
    campaign  = x,
    date      = date,
    year      = year,
    month     = month,
    block     = groups[, 4],
    is_mosaic = grepl(MOSAIC_PATTERN, x),
    parsed    = matched,
    stringsAsFactors = FALSE
  )
}

## How a campaign's point clouds are split up, read off the file names.
##
## Campaigns deliver LAS either one file per map tile (..._c<col>r<row>.las.gz)
## or one file per flight-line strip (..._l<line>s<strip>.las.gz). This matters
## well beyond naming: the shapefile of polygons follows the same scheme, so the
## scheme decides how the polygons have to be matched to real coverage in
## 03_footprints.R.
gl_las_scheme <- function(las_names) {
  if (any(grepl("_c[0-9]+r[0-9]+[.]las", las_names))) "cXrY"
  else if (any(grepl("_l[0-9]+s[0-9]+[.]las", las_names))) "lXsY"
  else "none"
}

## Every Puerto Rico campaign directory, dated and labelled with its epoch.
gl_list_campaigns <- function(refresh = FALSE) {
  root <- gl_index(GLIHT_BASE, refresh = refresh)
  directories <- grep(CAMPAIGN_INCLUDE, root$name[root$is_dir], value = TRUE)

  campaigns <- gl_parse_campaign_name(directories)
  campaigns$epoch <- gl_epoch(campaigns$year)
  campaigns$url <- paste0(GLIHT_BASE, campaigns$campaign, "/")
  campaigns[order(campaigns$date, campaigns$campaign), ]
}

## Every file inside one campaign, across the subdirectories listed in the
## config. Each subdirectory costs one request, which is why that list is short.
gl_crawl_campaign <- function(campaign, refresh = FALSE) {
  base <- paste0(GLIHT_BASE, campaign, "/")

  per_subdir <- list()
  for (subdir in CAMPAIGN_SUBDIRS) {
    listing <- gl_index(paste0(base, subdir), refresh = refresh)
    listing <- listing[!listing$is_dir, , drop = FALSE]   # files only
    if (!nrow(listing)) next

    listing$campaign <- campaign
    listing$subdir <- subdir
    per_subdir[[subdir]] <- listing[, c("campaign", "subdir", "name",
                                        "size_bytes", "modified", "url")]
  }

  gl_stack(per_subdir)
}

## Crawl every campaign in turn.
## Interrupting this is safe: each directory page is cached as it is read, so a
## restart picks up roughly where it left off rather than re-fetching everything.
gl_crawl_all <- function(campaigns, refresh = FALSE, max_campaigns = Inf) {
  names_to_crawl <- head(campaigns$campaign, max_campaigns)
  crawled <- vector("list", length(names_to_crawl))
  for (i in seq_along(names_to_crawl)) {
    if (i %% 20 == 1) {
      gl_msg(sprintf("crawling campaign %d/%d: %s",
                     i, length(names_to_crawl), names_to_crawl[i]))
    }
    crawled[[i]] <- gl_crawl_campaign(names_to_crawl[i], refresh = refresh)
  }
  gl_stack(crawled)
}

## One row describing what a single campaign holds. `f` is that campaign's slice
## of the file table.
gl_summarise_one_campaign <- function(campaign, f) {
  las <- f[f$subdir == "lidar/las/" & grepl("[.]las([.]gz)?$", f$name), ]
  rasters <- f[f$subdir == "lidar/geotiff/", ]

  ## Rasters ship either as one mosaic (_CHM.tif.gz) or as a tar of per-strip
  ## GeoTIFFs (_CHM.tar.gz), so both spellings have to be recognised.
  is_chm <- grepl("_CHM[.](tif|tar)", rasters$name)

  is_pdf <- f$subdir == "metadata/" & grepl("[.]pdf$", f$name)

  data.frame(
    campaign      = campaign,
    n_las         = nrow(las),
    las_gb        = round(sum(las$size_bytes, na.rm = TRUE) / 1024^3, 3),
    las_scheme    = gl_las_scheme(las$name),
    has_chm       = any(is_chm),
    has_dtm       = any(grepl("_DTM[.](tif|tar)", rasters$name)),
    chm_mb        = round(sum(rasters$size_bytes[is_chm], na.rm = TRUE) / 1024^2, 1),
    has_tiles_shp = any(grepl("_tiles([.]zip|[.]shp|_shp[.]tar[.]gz)$", f$name)),
    metadata_pdf  = paste(f$url[is_pdf], collapse = ";"),
    n_files       = nrow(f),
    total_gb      = round(sum(f$size_bytes, na.rm = TRUE) / 1024^3, 3),
    stringsAsFactors = FALSE
  )
}

## Roll the file list up to one row per campaign: what products exist, how big
## they are, and which LAS scheme was used. This is the table to read when
## deciding what is worth downloading.
gl_campaign_summary <- function(campaigns, files) {
  files_by_campaign <- split(files, files$campaign)

  per_campaign <- list()
  for (campaign in campaigns$campaign) {
    f <- files_by_campaign[[campaign]]
    if (is.null(f)) f <- files[0, ]           # a campaign whose directory is empty
    per_campaign[[campaign]] <- gl_summarise_one_campaign(campaign, f)
  }

  summary_rows <- gl_stack(per_campaign)
  merge(campaigns, summary_rows, by = "campaign", all.x = TRUE, sort = FALSE)
}

## Run step 1 and write its two tables.
gl_step_inventory <- function(refresh = FALSE, max_campaigns = Inf) {
  gl_init_dirs()

  campaigns <- gl_list_campaigns(refresh = refresh)
  gl_msg(sprintf("%d Puerto Rico campaigns in the G-LiHT tree (%d mosaics)",
                 nrow(campaigns), sum(campaigns$is_mosaic)))
  if (any(!campaigns$parsed)) {
    warning("unparsed campaign names: ",
            paste(campaigns$campaign[!campaigns$parsed], collapse = ", "))
  }
  if (is.finite(max_campaigns)) campaigns <- head(campaigns, max_campaigns)

  files <- gl_crawl_all(campaigns, refresh = refresh)
  campaigns <- gl_campaign_summary(campaigns, files)
  campaigns <- campaigns[order(campaigns$date, campaigns$campaign), ]

  gl_write_csv(files, "pr_files.csv")
  gl_write_csv(campaigns, "pr_campaigns.csv")
  gl_msg(sprintf("inventory: %d files, %.1f GB total, across %d campaigns",
                 nrow(files), sum(files$size_bytes, na.rm = TRUE) / 1024^3, nrow(campaigns)))

  list(campaigns = campaigns, files = files)
}

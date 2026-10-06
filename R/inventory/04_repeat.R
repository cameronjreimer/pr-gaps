## ---------------------------------------------------------------------------
## Step 3 — Which ground was flown more than once?
##
## Everything here is the same overlay looked at four ways, because four
## different questions get asked of it:
##
##   epoch_coverage   total area flown in each epoch      -> denominators
##   repeat_coverage  pieces labelled by which epochs cover them -> the map
##   repeat_tiles     per-tile overlap fractions          -> what to download
##   campaign_pairs   which individual flight pairs with which -> provenance
##
## The last one matters because the unit you actually download and process is a
## single flight, not an epoch.
##
## Produces:
##   derived/inventory/pr_repeat_coverage.gpkg   layers: epoch_coverage,
##                                               repeat_coverage, repeat_tiles
##   derived/inventory/pr_repeat_summary.csv
##   derived/inventory/pr_repeat_tiles.csv
##   derived/inventory/pr_repeat_campaign_pairs.csv
## ---------------------------------------------------------------------------

## Merge all of an epoch's campaign footprints into one polygon.
## The union matters: flights within an epoch overlap each other, so adding up
## their areas would count shared ground several times.
gl_epoch_coverage <- function(footprints, drop_mosaics = TRUE) {
  fp <- gl_analysis_subset(footprints, drop_mosaics)

  ## Known epochs first, in chronological order, then anything unexpected.
  present <- unique(fp$epoch)
  epochs <- c(intersect(EPOCH_LEVELS, present), setdiff(present, EPOCH_LEVELS))

  per_epoch <- list()
  for (epoch in epochs) {
    in_epoch <- fp[fp$epoch == epoch, ]

    merged_outline <- sf::st_union(sf::st_geometry(in_epoch))
    merged_outline <- sf::st_make_valid(merged_outline)

    per_epoch[[epoch]] <- sf::st_sf(epoch       = epoch,
                                    n_campaigns = nrow(in_epoch),
                                    date_min    = min(in_epoch$date, na.rm = TRUE),
                                    date_max    = max(in_epoch$date, na.rm = TRUE),
                                    geometry    = merged_outline)
  }

  coverage <- gl_stack(per_epoch)
  coverage$area_ha <- gl_area_ha(coverage)
  coverage
}

## Cut the epoch polygons against each other, so that every resulting piece is
## labelled with the full set of epochs covering it: "2017_pre", then
## "2017_pre + 2018_post", then all three, and so on.
##
## st_intersection() on a single object does exactly this, returning an
## `origins` column holding the row numbers that contributed to each piece.
gl_repeat_coverage <- function(epoch_cov) {
  overlay <- suppressWarnings(sf::st_intersection(epoch_cov))
  overlay <- gl_polygon_parts(overlay)

  ## Turn each piece's list of source row numbers into a readable label,
  ## e.g. rows 1 and 2 become "2017_pre + 2018_post".
  labels <- character(nrow(overlay))
  for (i in seq_len(nrow(overlay))) {
    source_rows <- overlay$origins[[i]]
    labels[i] <- paste(epoch_cov$epoch[source_rows], collapse = " + ")
  }

  overlay$epochs <- labels
  overlay$n_epochs <- lengths(overlay$origins)
  overlay$area_ha <- gl_area_ha(overlay)

  overlay <- overlay[, c("epochs", "n_epochs", "area_ha", "geometry")]
  overlay[order(-overlay$n_epochs, -overlay$area_ha), ]
}

## For every data-bearing tile, what fraction of it each epoch covers.
##
## This is the table to filter when choosing what to download: a 2017 tile whose
## frac_2018_post is 1 was completely reflown after the hurricane. The fractions
## are kept alongside the summary count so the "counts as reflown" threshold can
## be changed later without recomputing any geometry.
gl_repeat_tiles <- function(tiles, epoch_cov, drop_mosaics = TRUE) {
  tl <- gl_analysis_subset(tiles[tiles$in_footprint, ], drop_mosaics)
  tl$tile_id <- seq_len(nrow(tl))

  ## Intersect all tiles against one epoch's coverage at a time, then total the
  ## intersected area per tile. Clipping can split a tile into several pieces,
  ## which is why the areas are summed rather than taken singly.
  for (epoch in epoch_cov$epoch) {
    this_epoch <- sf::st_geometry(epoch_cov[epoch_cov$epoch == epoch, ])
    clipped <- gl_polygon_parts(
      suppressWarnings(sf::st_intersection(tl[, c("tile_id")], this_epoch)))

    ## Add up the pieces belonging to each tile.
    covered_ha <- rep(0, nrow(tl))
    if (nrow(clipped)) {
      piece_areas <- gl_area_ha(clipped)
      for (i in seq_along(piece_areas)) {
        tile <- clipped$tile_id[i]
        covered_ha[tile] <- covered_ha[tile] + piece_areas[i]
      }
    }

    ## Capped at 1: slivers of floating-point overshoot are not extra coverage.
    tl[[paste0("frac_", epoch)]] <- pmin(1, covered_ha / tl$area_ha)
  }

  ## How many OTHER epochs cover this tile. A tile always scores 1 against its
  ## own epoch — it is part of that epoch's coverage — so its own epoch is
  ## skipped rather than counted.
  tl$n_other_epochs <- 0L
  for (epoch in epoch_cov$epoch) {
    is_another_epoch <- tl$epoch != epoch
    is_reflown <- tl[[paste0("frac_", epoch)]] >= REPEAT_TILE_THRESHOLD
    tl$n_other_epochs <- tl$n_other_epochs + as.integer(is_another_epoch & is_reflown)
  }

  frac_cols <- paste0("frac_", epoch_cov$epoch)

  tl$tile_id <- NULL
  ## The geometry column is "geometry" when built in this session and "geom"
  ## when the GeoPackage is re-read with --reuse, so ask rather than assume.
  wanted <- c("campaign", "tile", "date", "epoch", "block", "las_scheme", "area_ha",
              frac_cols, "n_other_epochs", attr(tl, "sf_column"))
  tl[, intersect(wanted, names(tl))]
}

## One epoch's footprints, with every column suffixed "_a" or "_b".
## WHY: the two sides of an intersection would otherwise collide on column names
## like "campaign", and there would be no way to tell which flight was which.
gl_epoch_side <- function(fp, epoch, suffix) {
  side <- fp[fp$epoch == epoch, c("campaign", "date", "epoch", "area_ha")]
  names(side) <- c(paste0("campaign_", suffix),
                   paste0("date_", suffix),
                   paste0("epoch_", suffix),
                   paste0("area_ha_", suffix),
                   "geometry")
  sf::st_geometry(side) <- "geometry"
  side
}

## The overlapping flight pairs between two epochs.
gl_pairs_for_epochs <- function(fp, epoch_a, epoch_b, min_ha) {
  side_a <- gl_epoch_side(fp, epoch_a, "a")
  side_b <- gl_epoch_side(fp, epoch_b, "b")

  ## st_intersection finds every overlapping pair using a spatial index, rather
  ## than testing all combinations.
  overlaps <- suppressWarnings(sf::st_intersection(side_a, side_b))
  overlaps <- gl_polygon_parts(overlaps)
  if (!nrow(overlaps)) return(NULL)

  out <- sf::st_drop_geometry(overlaps)
  out$overlap_ha <- gl_area_ha(overlaps)
  out <- out[out$overlap_ha >= min_ha, ]        # drop edge-contact slivers
  if (!nrow(out)) return(NULL)

  ## Fractions say whether a flight was wholly or only partly reflown.
  out$frac_a <- out$overlap_ha / out$area_ha_a
  out$frac_b <- out$overlap_ha / out$area_ha_b
  out$days_between <- as.numeric(out$date_b - out$date_a)
  out
}

## Which individual flights overlap which, across epochs.
gl_campaign_pairs <- function(footprints, drop_mosaics = TRUE, min_ha = 1) {
  fp <- gl_analysis_subset(footprints, drop_mosaics)
  epochs <- unique(fp$epoch)
  if (length(epochs) < 2) return(NULL)

  ## Every combination of two different epochs: 1-2, 1-3, 2-3, and so on.
  per_epoch_pair <- list()
  for (i in seq_len(length(epochs) - 1)) {
    for (j in seq(i + 1, length(epochs))) {
      label <- paste(epochs[i], epochs[j])
      per_epoch_pair[[label]] <- gl_pairs_for_epochs(fp, epochs[i], epochs[j], min_ha)
    }
  }

  pairs <- gl_stack(per_epoch_pair)
  if (is.null(pairs)) return(NULL)
  pairs[order(-pairs$overlap_ha), ]
}

## Total the overlay's many small pieces into one row per epoch combination.
gl_repeat_summary_table <- function(rep_cov) {
  totals <- aggregate(area_ha ~ epochs + n_epochs,
                      data = sf::st_drop_geometry(rep_cov), FUN = sum)
  totals[order(-totals$n_epochs, -totals$area_ha), ]
}

## Run step 3 and write the GeoPackage and tables.
gl_step_repeat <- function(tiles, footprints, drop_mosaics = TRUE) {
  gl_init_dirs()

  epoch_cov <- gl_epoch_coverage(footprints, drop_mosaics)
  rep_cov   <- gl_repeat_coverage(epoch_cov)
  rep_tiles <- gl_repeat_tiles(tiles, epoch_cov, drop_mosaics)
  pairs     <- gl_campaign_pairs(footprints, drop_mosaics)
  summary_table <- gl_repeat_summary_table(rep_cov)

  gl_write_gpkg("pr_repeat_coverage.gpkg",
                list(epoch_coverage = epoch_cov,
                     repeat_coverage = rep_cov,
                     repeat_tiles = rep_tiles))

  gl_write_csv(summary_table, "pr_repeat_summary.csv")
  gl_write_csv(sf::st_drop_geometry(rep_tiles), "pr_repeat_tiles.csv")
  if (!is.null(pairs)) gl_write_csv(pairs, "pr_repeat_campaign_pairs.csv")

  gl_msg("coverage by epoch (ha):")
  print(sf::st_drop_geometry(epoch_cov)[, c("epoch", "n_campaigns", "area_ha")])
  gl_msg("repeat coverage (ha):")
  print(summary_table)

  list(epoch_coverage = epoch_cov, repeat_coverage = rep_cov,
       repeat_tiles = rep_tiles, campaign_pairs = pairs, summary = summary_table)
}

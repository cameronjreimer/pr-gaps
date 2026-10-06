## ---------------------------------------------------------------------------
## Step 6 — Summary table and maps.
##
## Produces:
##   derived/inventory/pr_inventory_by_epoch.csv
##   derived/inventory/figures/pr_coverage_by_epoch.png
##   derived/inventory/figures/pr_repeat_coverage.png
## ---------------------------------------------------------------------------

## One row summarising a single epoch. `rows` is that epoch's slice of the
## footprint table; `tracks` is the de-duplicated trajectory table, or NULL.
gl_summarise_epoch <- function(rows, tracks) {
  epoch <- rows$epoch[1]

  if (is.null(tracks)) {
    track_km <- NA_real_
  } else {
    this_epoch <- tracks$epoch == epoch
    track_km <- round(sum(tracks$length_km[this_epoch], na.rm = TRUE), 0)
  }

  data.frame(
    epoch         = epoch,
    n_campaigns   = nrow(rows),
    n_flight_days = length(unique(stats::na.omit(rows$date))),
    first_flight  = as.character(min(rows$date, na.rm = TRUE)),
    last_flight   = as.character(max(rows$date, na.rm = TRUE)),
    tile_area_ha  = round(sum(rows$area_ha), 0),
    day_track_km  = track_km,
    stringsAsFactors = FALSE
  )
}

## One row per epoch: how many flights, over how many days, covering how much.
##
## `trajectories` must be the de-duplicated day tracks from gl_step_footprints().
## Using the raw per-campaign copies would multiply each day's track length by
## the number of blocks flown that day, since they all ship the same track.
gl_inventory_by_epoch <- function(footprints, trajectories = NULL, drop_mosaics = TRUE) {
  fp <- sf::st_drop_geometry(footprints)
  fp <- gl_analysis_subset(fp, drop_mosaics)

  tracks <- NULL
  if (!is.null(trajectories)) tracks <- sf::st_drop_geometry(trajectories)

  rows_by_epoch <- split(fp, fp$epoch)

  per_epoch <- list()
  for (epoch in names(rows_by_epoch)) {
    per_epoch[[epoch]] <- gl_summarise_epoch(rows_by_epoch[[epoch]], tracks)
  }

  by_epoch <- gl_stack(per_epoch)
  by_epoch[order(match(by_epoch$epoch, EPOCH_LEVELS)), ]
}

## Colours used in both maps.
GL_EPOCH_COLOURS <- c("2017_pre" = "#3B7DD8", "2018_post" = "#D8762F",
                      "2020_recovery" = "#2F9E6B")
GL_TWO_EPOCH_COLOUR   <- "#D8762F"
GL_THREE_EPOCH_COLOUR <- "#7B2D8E"

## Map 1 — what each epoch covered, drawn semi-transparent so that ground flown
## in more than one epoch shows up darker.
gl_plot_epoch_map <- function(epoch_cov, path) {
  colours <- GL_EPOCH_COLOURS[epoch_cov$epoch]
  colours[is.na(colours)] <- "#888888"           # any unexpected epoch
  translucent <- grDevices::adjustcolor(colours, 0.55)

  grDevices::png(path, width = 2000, height = 1000, res = 150)
  ## Close the file even if the drawing below fails, so it is never left open.
  on.exit(grDevices::dev.off())
  graphics::par(mar = c(3, 3, 2, 1))

  plot(sf::st_geometry(epoch_cov), border = NA, col = translucent, axes = TRUE,
       main = "G-LiHT Puerto Rico lidar coverage by epoch (tile footprints)")
  labels <- paste0(epoch_cov$epoch, "  (", round(epoch_cov$area_ha), " ha)")
  graphics::legend("bottomleft", legend = labels, fill = translucent,
                   border = NA, bty = "n", cex = 0.9)

  invisible(path)
}

## Map 2 — the repeat overlay on top of all coverage, so ground flown once stays
## grey and reflown ground is coloured by how many epochs cover it.
gl_plot_repeat_map <- function(epoch_cov, rep_cov, path) {
  colours <- ifelse(rep_cov$n_epochs >= 3, GL_THREE_EPOCH_COLOUR,
                    GL_TWO_EPOCH_COLOUR)

  grDevices::png(path, width = 2000, height = 1000, res = 150)
  on.exit(grDevices::dev.off())
  graphics::par(mar = c(3, 3, 2, 1))

  plot(sf::st_geometry(epoch_cov), border = "grey70", col = "grey92", axes = TRUE,
       main = "Repeat lidar coverage, Puerto Rico")
  plot(sf::st_geometry(rep_cov), col = colours, border = NA, add = TRUE)
  graphics::legend("bottomleft",
                   legend = c("flown once", "2 epochs", "3 epochs"),
                   fill = c("grey92", GL_TWO_EPOCH_COLOUR, GL_THREE_EPOCH_COLOUR),
                   border = NA, bty = "n", cex = 0.9)

  invisible(path)
}

## Run step 6.
gl_step_report <- function(footprints, epoch_cov, rep_cov, pairs, trajectories = NULL,
                           drop_mosaics = TRUE) {
  paths <- gl_init_dirs()

  by_epoch <- gl_inventory_by_epoch(footprints, trajectories, drop_mosaics)
  gl_write_csv(by_epoch, "pr_inventory_by_epoch.csv")
  gl_msg("inventory by epoch:")
  print(by_epoch)

  epoch_map <- gl_plot_epoch_map(epoch_cov,
                                 file.path(paths$figures, "pr_coverage_by_epoch.png"))
  repeat_map <- gl_plot_repeat_map(epoch_cov, rep_cov,
                                   file.path(paths$figures, "pr_repeat_coverage.png"))
  figures <- c(epoch_map, repeat_map)
  gl_msg("figures written: ", paste(basename(figures), collapse = ", "))

  if (!is.null(pairs)) {
    gl_msg("largest campaign-level overlaps:")
    biggest <- utils::head(pairs, 15)
    print(biggest[, c("campaign_a", "campaign_b", "overlap_ha",
                      "frac_a", "frac_b", "days_between")])
  }

  invisible(list(inventory = by_epoch, figures = figures))
}

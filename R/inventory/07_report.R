## ---------------------------------------------------------------------------
## Step 6 — Summary table and maps.
##
## Produces:
##   derived/inventory/pr_inventory_by_epoch.csv
##   derived/inventory/figures/pr_coverage_by_epoch.png
##   derived/inventory/figures/pr_repeat_coverage.png
##
## The campaign-by-campaign overlap table is deliberately not printed here.
## Step 3 already writes every pair to pr_repeat_campaign_pairs.csv, which is
## easier to read than fifteen truncated rows scrolling past in a console.
## ---------------------------------------------------------------------------

## One row summarising a single epoch. `rows` is that epoch's slice of the
## footprint table.
gl_summarise_epoch <- function(rows) {
  data.frame(
    epoch         = rows$epoch[1],
    n_campaigns   = nrow(rows),
    n_flight_days = length(unique(stats::na.omit(rows$date))),
    first_flight  = as.character(min(rows$date, na.rm = TRUE)),
    last_flight   = as.character(max(rows$date, na.rm = TRUE)),
    tile_area_ha  = round(sum(rows$area_ha), 0),
    stringsAsFactors = FALSE
  )
}

## One row per epoch: how many flights, over how many days, covering how much.
gl_inventory_by_epoch <- function(footprints, drop_mosaics = TRUE) {
  fp <- sf::st_drop_geometry(footprints)
  fp <- gl_analysis_subset(fp, drop_mosaics)

  rows_by_epoch <- split(fp, fp$epoch)

  per_epoch <- list()
  for (epoch in names(rows_by_epoch)) {
    per_epoch[[epoch]] <- gl_summarise_epoch(rows_by_epoch[[epoch]])
  }

  by_epoch <- gl_stack(per_epoch)
  by_epoch[order(match(by_epoch$epoch, EPOCH_LEVELS)), ]
}

## ---------------------------------------------------------------------------
## Map colours.
##
## Epoch colours are categorical (they mean "which epoch", an identity), so they
## are three distinct hues taken in fixed order. Repeat-coverage colours are
## sequential (they mean "how many epochs", a count), so they are one hue going
## light to dark. Mixing those two jobs up is the usual way a map stops being
## readable.
## ---------------------------------------------------------------------------
GL_EPOCH_COLOURS <- c("2017_pre" = "#2a78d6",       # blue
                      "2018_post" = "#eb6834",      # orange
                      "2020_recovery" = "#1baf7a")  # aqua
GL_UNKNOWN_EPOCH_COLOUR <- "#898781"

GL_TWO_EPOCH_COLOUR   <- "#86b6ef"   # blue, light step
GL_THREE_EPOCH_COLOUR <- "#1c5cab"   # blue, dark step

GL_SURFACE <- "#fcfcfb"
GL_INK     <- "#0b0b0b"
GL_MUTED   <- "#898781"
GL_AXIS    <- "#c3c2b7"
GL_CONTEXT <- "#e1e0d9"              # recessive grey for "not this epoch"
GL_COAST   <- "#b9b8b0"              # the Puerto Rico coastline

## The extent both maps share: the coverage, plus the coastline when we have it.
gl_map_extent <- function(epoch_cov, boundary = NULL) {
  geometry <- sf::st_geometry(epoch_cov)
  if (!is.null(boundary)) {
    geometry <- c(geometry, sf::st_geometry(boundary))
  }
  sf::st_bbox(geometry)
}

## Draw the coastline, as a stroke with no fill.
## WHY no fill: the maps already use two greys for data (ground covered by
## another epoch, and ground flown once), and a third grey for land would be one
## ambiguous shade too many. An outline gives the geographic anchor without
## competing with anything in the legend.
gl_draw_coastline <- function(boundary) {
  if (is.null(boundary)) return(invisible(NULL))
  plot(sf::st_geometry(boundary), col = NA, border = GL_COAST, lwd = 0.8,
       add = TRUE)
}

## Open a PNG sized to the map's own shape, so the island is never squashed.
## `panels` is how many maps will be stacked vertically.
gl_open_map_png <- function(path, bbox, panels = 1, width = 1800) {
  shape <- as.numeric((bbox["ymax"] - bbox["ymin"]) / (bbox["xmax"] - bbox["xmin"]))
  panel_height <- width * shape + 70            # 70px for each panel's margins
  grDevices::png(path, width = width,
                 height = round(panels * panel_height + 90), res = 150)
  graphics::par(mfrow = c(panels, 1), mar = c(2, 2, 2, 1), oma = c(0, 0, 2.5, 0),
                bg = GL_SURFACE, fg = GL_AXIS, col.axis = GL_MUTED,
                col.main = GL_INK)
}

## Map 1 — one panel per epoch.
##
## WHY separate panels rather than three translucent layers on one map: with
## three overlapping epochs, blended fills produce colours that stand for
## combinations nobody chose and the legend cannot name — the previous version
## of this figure rendered most of the island in an unexplained brown, which was
## in fact 2017-and-2018 overlap. Here every colour on the page is in the legend.
## Where the epochs overlap is the job of map 2.
gl_plot_epoch_map <- function(epoch_cov, path, boundary = NULL) {
  epochs <- epoch_cov$epoch
  colours <- GL_EPOCH_COLOURS[epochs]
  colours[is.na(colours)] <- GL_UNKNOWN_EPOCH_COLOUR

  extent <- gl_map_extent(epoch_cov, boundary)
  gl_open_map_png(path, extent, panels = length(epochs))
  on.exit(grDevices::dev.off())

  for (i in seq_along(epochs)) {
    ## An empty plot of the full extent first, so all panels line up.
    plot(sf::st_as_sfc(extent), border = NA, col = NA, axes = TRUE)
    gl_draw_coastline(boundary)
    others <- epoch_cov[-i, ]
    if (nrow(others)) {
      plot(sf::st_geometry(others), border = NA, col = GL_CONTEXT, add = TRUE)
    }
    plot(sf::st_geometry(epoch_cov[i, ]), border = NA, col = colours[i],
         add = TRUE)

    area <- format(round(epoch_cov$area_ha[i]), big.mark = ",")
    graphics::legend("bottomleft", bty = "n", cex = 1.0, border = NA,
                     text.col = GL_INK, fill = c(colours[i], GL_CONTEXT),
                     legend = c(sprintf("%s  (%s ha)",
                                        gl_epoch_label(epochs[i]), area),
                                "other epochs"))
  }

  graphics::mtext("G-LiHT Puerto Rico lidar coverage by epoch (tile footprints)",
                  outer = TRUE, font = 2, cex = 1.0, col = GL_INK)
  invisible(path)
}

## Map 2 — how many epochs cover each piece of ground.
gl_plot_repeat_map <- function(epoch_cov, rep_cov, path, boundary = NULL) {
  ## rep_cov holds every piece of the overlay, including ground flown only once.
  ## Only the repeats are drawn; everything else stays in the grey base.
  repeats <- rep_cov[rep_cov$n_epochs >= 2, ]
  colours <- ifelse(repeats$n_epochs >= 3, GL_THREE_EPOCH_COLOUR,
                    GL_TWO_EPOCH_COLOUR)

  extent <- gl_map_extent(epoch_cov, boundary)
  gl_open_map_png(path, extent, panels = 1)
  on.exit(grDevices::dev.off())

  plot(sf::st_as_sfc(extent), border = NA, col = NA, axes = TRUE)
  gl_draw_coastline(boundary)
  plot(sf::st_geometry(epoch_cov), border = NA, col = GL_CONTEXT, add = TRUE)
  if (nrow(repeats)) {
    plot(sf::st_geometry(repeats), col = colours, border = NA, add = TRUE)
  }

  graphics::legend("bottomleft", bty = "n", cex = 1.0, border = NA,
                   text.col = GL_INK,
                   legend = c("flown once", "flown in 2 epochs",
                              "flown in all 3 epochs"),
                   fill = c(GL_CONTEXT, GL_TWO_EPOCH_COLOUR,
                            GL_THREE_EPOCH_COLOUR))
  graphics::mtext("Repeat lidar coverage, Puerto Rico",
                  outer = TRUE, font = 2, cex = 1.0, col = GL_INK)
  invisible(path)
}

## Run step 6.
gl_step_report <- function(footprints, epoch_cov, rep_cov, drop_mosaics = TRUE) {
  paths <- gl_init_dirs()

  by_epoch <- gl_inventory_by_epoch(footprints, drop_mosaics)
  gl_write_csv(by_epoch, "pr_inventory_by_epoch.csv")
  gl_msg("inventory by epoch:")
  print(by_epoch)

  ## Fetched once and shared by both maps; NULL if unavailable, in which case
  ## they are drawn without a coastline.
  boundary <- gl_pr_boundary()

  epoch_map <- gl_plot_epoch_map(epoch_cov,
                                 file.path(paths$figures, "pr_coverage_by_epoch.png"),
                                 boundary)
  repeat_map <- gl_plot_repeat_map(epoch_cov, rep_cov,
                                   file.path(paths$figures, "pr_repeat_coverage.png"),
                                   boundary)
  figures <- c(epoch_map, repeat_map)
  gl_msg("figures written: ", paste(basename(figures), collapse = ", "))

  invisible(list(inventory = by_epoch, figures = figures))
}

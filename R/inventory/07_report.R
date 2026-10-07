## ---------------------------------------------------------------------------
## Step 6 — Summary table and maps.
##
## Produces:
##   derived/inventory/pr_inventory_by_epoch.csv
##   derived/inventory/figures/pr_coverage_by_epoch.png
##   derived/inventory/figures/pr_repeat_coverage.png
##   derived/inventory/figures/pr_epoch_combinations.png
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
GL_ONE_EPOCH_COLOUR   <- "#8f8e86"   # neutral: covered, but never reflown

## The two epoch combinations the chapter is built on, spelled the way
## gl_repeat_coverage() labels them: chronological order, " + " separated.
## Built from EPOCH_LEVELS rather than written out as strings, so renaming an
## epoch cannot silently stop these matching anything.
GL_MARIA_COMBO    <- paste(EPOCH_LEVELS[1:2], collapse = " + ")
GL_RECOVERY_COMBO <- paste(EPOCH_LEVELS[1:3], collapse = " + ")

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
## `panels` is how many maps are drawn and `cols` how many sit side by side;
## the default of one column stacks them vertically.
##
## Returns TRUE when the device opened. A FALSE means the file could not be
## written — on Windows, almost always because it is open in an image viewer,
## which holds the file and makes png() fail with "unable to start png()
## device". That is a reason to skip one figure and say so, not to abandon a
## run that has already done several minutes of work, so the caller warns and
## carries on.
gl_open_map_png <- function(path, bbox, panels = 1, cols = 1, width = 1800) {
  shape <- as.numeric((bbox["ymax"] - bbox["ymin"]) / (bbox["xmax"] - bbox["xmin"]))
  rows <- ceiling(panels / cols)
  panel_height <- (width / cols) * shape + 70   # 70px for each panel's margins

  opened <- suppressWarnings(tryCatch({
    grDevices::png(path, width = width,
                   height = round(rows * panel_height + 90), res = 150)
    TRUE
  }, error = function(e) FALSE))

  if (!opened) {
    warning("could not write ", basename(path),
            " — if it is open in an image viewer, close it and re-run",
            call. = FALSE)
    return(FALSE)
  }

  graphics::par(mfrow = c(rows, cols), mar = c(2, 2, 2, 1), oma = c(0, 0, 2.5, 0),
                bg = GL_SURFACE, fg = GL_AXIS, col.axis = GL_MUTED,
                col.main = GL_INK)
  TRUE
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
  if (!gl_open_map_png(path, extent, panels = length(epochs))) return(invisible(NA_character_))
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

## Map 2 — the ground the chapter can actually use.
##
## WHY these three classes and not a count of epochs: counting treats
## 2018 + 2020 as equivalent to 2017 + 2018, and only one of those spans
## Hurricane Maria. The before/after comparison needs 2017 and 2018 together;
## adding 2020 turns that pair into a three-date recovery trajectory. Ground
## flown once, or reflown in some combination that misses 2017 or 2018, cannot
## answer either question, so it belongs in the grey base however many times it
## was overflown.
##
## Colour still runs light to dark with how much a piece supports, so this
## reads the same way as it did before: pale blue for the Maria pair, dark blue
## for the pair plus recovery.
gl_plot_repeat_map <- function(epoch_cov, rep_cov, path, boundary = NULL) {
  maria    <- rep_cov[rep_cov$epochs == GL_MARIA_COMBO, ]
  recovery <- rep_cov[rep_cov$epochs == GL_RECOVERY_COMBO, ]

  ## The overlay pieces are disjoint — they partition the covered ground — so
  ## their areas simply add, and "everything else" is the remainder.
  total_ha    <- sum(rep_cov$area_ha)
  maria_ha    <- sum(maria$area_ha)
  recovery_ha <- sum(recovery$area_ha)
  other_ha    <- total_ha - maria_ha - recovery_ha

  extent <- gl_map_extent(epoch_cov, boundary)
  if (!gl_open_map_png(path, extent, panels = 1)) return(invisible(NA_character_))
  on.exit(grDevices::dev.off())

  plot(sf::st_as_sfc(extent), border = NA, col = NA, axes = TRUE)
  gl_draw_coastline(boundary)

  ## Grey first, covering everything; then the two classes that matter, with the
  ## scarcer three-epoch ground drawn last so nothing can paint over it.
  plot(sf::st_geometry(epoch_cov), border = NA, col = GL_CONTEXT, add = TRUE)
  if (nrow(maria)) {
    plot(sf::st_geometry(maria), col = GL_TWO_EPOCH_COLOUR, border = NA, add = TRUE)
  }
  if (nrow(recovery)) {
    plot(sf::st_geometry(recovery), col = GL_THREE_EPOCH_COLOUR, border = NA,
         add = TRUE)
  }

  hectares <- function(x) format(round(x), big.mark = ",")
  graphics::legend(
    "bottomleft", bty = "n", cex = 1.0, border = NA, text.col = GL_INK,
    fill = c(GL_THREE_EPOCH_COLOUR, GL_TWO_EPOCH_COLOUR, GL_CONTEXT),
    legend = c(sprintf("%s  (%s ha)", gl_combo_label(GL_RECOVERY_COMBO),
                       hectares(recovery_ha)),
               sprintf("%s  (%s ha)", gl_combo_label(GL_MARIA_COMBO),
                       hectares(maria_ha)),
               sprintf("all other coverage  (%s ha)", hectares(other_ha))))

  graphics::mtext("Repeat lidar coverage spanning Hurricane Maria, Puerto Rico",
                  outer = TRUE, font = 2, cex = 1.0, col = GL_INK)
  invisible(path)
}

## Turn "2017_pre + 2018_post" into "2017 + 2018" for a figure.
gl_combo_label <- function(epochs) {
  parts <- strsplit(epochs, " + ", fixed = TRUE)[[1]]
  paste(gl_epoch_label(parts), collapse = " + ")
}

## Map 3 — one panel per unique combination of epochs.
##
## Map 2 answers "how many epochs?"; this one answers "which ones?". With three
## epochs there are seven possible answers, and that count is exactly why this
## is a panel per combination rather than seven fills on one map.
##
## WHY NOT seven colours on a single map: on a map any two patches can end up
## adjacent, so a palette has to separate every pair, not just neighbouring
## ones in a legend. Our categorical ramp only clears that bar for its first
## three slots — the fourth puts yellow next to orange, which collapses under
## the common forms of colour blindness. Faceting sidesteps the problem
## entirely: each panel holds one fill, so no two series ever have to be told
## apart by hue.
##
## Colour is then free to carry something else, and it carries the count, on the
## same steps map 2 uses: neutral for ground flown in one epoch, light blue for
## two, dark blue for three. Nothing changes meaning between the two figures.
gl_plot_combo_map <- function(epoch_cov, rep_cov, path, boundary = NULL) {
  ## One entry per combination, biggest first within each epoch count, so the
  ## panels run in the same order as pr_repeat_summary.csv.
  area_by_combo <- tapply(rep_cov$area_ha, rep_cov$epochs, sum)
  count_by_combo <- tapply(rep_cov$n_epochs, rep_cov$epochs, max)
  combos <- names(area_by_combo)[order(-count_by_combo, -area_by_combo)]

  fills <- c(GL_ONE_EPOCH_COLOUR, GL_TWO_EPOCH_COLOUR, GL_THREE_EPOCH_COLOUR)

  extent <- gl_map_extent(epoch_cov, boundary)
  if (!gl_open_map_png(path, extent, panels = length(combos), cols = 2)) return(invisible(NA_character_))
  on.exit(grDevices::dev.off())

  for (combo in combos) {
    pieces <- rep_cov[rep_cov$epochs == combo, ]

    ## The full extent first, so every panel is the same map.
    plot(sf::st_as_sfc(extent), border = NA, col = NA, axes = TRUE)
    gl_draw_coastline(boundary)
    plot(sf::st_geometry(epoch_cov), border = NA, col = GL_CONTEXT, add = TRUE)
    plot(sf::st_geometry(pieces), border = NA,
         col = fills[count_by_combo[[combo]]], add = TRUE)

    area <- format(round(area_by_combo[[combo]]), big.mark = ",")
    graphics::legend("bottomleft", bty = "n", cex = 1.0, border = NA,
                     text.col = GL_INK,
                     fill = c(fills[count_by_combo[[combo]]], GL_CONTEXT),
                     legend = c(sprintf("%s  (%s ha)", gl_combo_label(combo), area),
                                "all other coverage"))
  }

  graphics::mtext("Which epochs cover each piece of ground, Puerto Rico",
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
  combo_map <- gl_plot_combo_map(epoch_cov, rep_cov,
                                 file.path(paths$figures, "pr_epoch_combinations.png"),
                                 boundary)
  ## A figure that could not be written has already warned; drop it here so the
  ## message lists what actually landed on disk.
  figures <- c(epoch_map, repeat_map, combo_map)
  figures <- figures[!is.na(figures)]
  gl_msg("figures written: ", paste(basename(figures), collapse = ", "))

  invisible(list(inventory = by_epoch, figures = figures))
}

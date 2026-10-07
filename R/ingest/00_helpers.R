## ---------------------------------------------------------------------------
## Small helpers shared by the rest of the workflow.
##
## Each one is here because the same few lines were repeated in four or five
## places, and the repetition made the actual logic harder to find. Nothing in
## this file touches the network or the disk.
## ---------------------------------------------------------------------------

## Print a progress line with a timestamp.
## WHY: a full run takes ten minutes or more, and a bare message gives no way to
## tell a slow step from a stalled one.
gl_msg <- function(...) cat(format(Sys.time(), "%H:%M:%S"), "|", ..., "\n")

## Print a one-line percentage ticker from inside a loop: "10% ... 20% ... 100%".
## Call it once per iteration with the iteration number and the total.
##
## WHY a percentage rather than the campaign name: the crawl and the footprint
## builder both run for several minutes over ~300 campaigns, and naming every
## twentieth one filled the console with identifiers nobody reads while still
## giving no sense of how far through the run was. A percentage answers the only
## question being asked ("how much longer?") in one line instead of fifteen.
gl_progress <- function(i, n, step = 10) {
  if (n < 1) return(invisible(NULL))

  ## Print only when this iteration crosses a 10% boundary, so the line grows
  ## once per step no matter how many iterations there are.
  reached <- floor(100 * i / n / step) * step
  previous <- floor(100 * (i - 1) / n / step) * step
  if (reached <= previous || reached == 0) return(invisible(NULL))

  cat(if (reached < 100) sprintf("%d%% ... ", reached) else "100%\n")
  utils::flush.console()
  invisible(NULL)
}

## Area of each polygon, in hectares.
## WHY: sf reports area as a "units" object in square metres, but every result
## in this project is quoted in hectares. Converting in one place keeps the
## conversion factor out of a dozen call sites, where a stray 1e4 would be easy
## to get wrong and hard to spot.
gl_area_ha <- function(x) {
  square_metres <- as.numeric(sf::st_area(x))
  square_metres / 10000
}

## Combine a list of tables (data frames or sf objects) into one, skipping empty
## entries.
## WHY: the per-campaign loops return NULL whenever a campaign has nothing to
## contribute — an empty directory on the server, a missing shapefile — and
## rbind() fails on those NULLs unless they are dropped first.
gl_stack <- function(tables) {
  filled <- list()
  for (i in seq_along(tables)) {
    if (!is.null(tables[[i]])) {
      filled[[length(filled) + 1]] <- tables[[i]]
    }
  }
  if (length(filled) == 0) return(NULL)

  ## do.call() passes the whole list to rbind() at once, which is far faster
  ## than adding one table at a time.
  do.call(rbind, filled)
}

## Run an expression; if it fails, warn and return NULL rather than stopping.
## WHY: one malformed campaign out of 296 should not abandon a ten-minute run.
## The warning means the failure is still visible at the end.
gl_try <- function(expr, label) {
  tryCatch(expr, error = function(e) {
    warning(label, ": ", conditionMessage(e), call. = FALSE)
    NULL
  })
}

## The rows that belong in a coverage overlay.
## WHY two filters: campaigns whose name ends in "_all" are pre-merged mosaics of
## daily flights that are already counted individually, so keeping them would
## count the same ground twice; rows with no epoch have a date we could not parse
## and cannot be placed in time.
gl_analysis_subset <- function(x, drop_mosaics = TRUE) {
  if (drop_mosaics) x <- x[!x$is_mosaic, ]
  x[!is.na(x$epoch), ]
}

## Keep only the two-dimensional (area) parts of an overlay result.
## WHY: intersecting two footprints that merely touch along an edge returns a
## line, a point, or a GEOMETRYCOLLECTION mixing those with real area. They
## contribute nothing but would show up as zero-width slivers of "repeat
## coverage" in the outputs.
gl_polygon_parts <- function(x) {
  x <- x[!sf::st_is_empty(x), ]
  if (!nrow(x)) return(x)

  if (any(sf::st_geometry_type(x) == "GEOMETRYCOLLECTION")) {
    x <- suppressWarnings(sf::st_collection_extract(x, "POLYGON"))
  }

  ## Dimension 2 means area; 0 is a point and 1 is a line.
  dimension <- sf::st_dimension(x)
  x[!is.na(dimension) & dimension == 2, ]
}

## Write a table to the inventory output directory.
## WHY: the same file.path()/row.names dance appeared at ten call sites, and
## having one place that knows where outputs go makes them easy to relocate.
gl_write_csv <- function(x, filename) {
  path <- file.path(gl_paths()$out, filename)
  utils::write.csv(x, path, row.names = FALSE)
  invisible(path)
}

## Write several named map layers into one GeoPackage, replacing any existing
## file. NULL layers are skipped.
## WHY: sf wants append = FALSE for the first layer and TRUE for the rest, a
## detail that was spelled out at three call sites and easy to get wrong when
## adding a layer.
gl_write_gpkg <- function(filename, layers) {
  path <- file.path(gl_paths()$out, filename)
  if (file.exists(path)) unlink(path)

  written_any <- FALSE
  for (layer_name in names(layers)) {
    layer <- layers[[layer_name]]
    if (is.null(layer)) next
    sf::st_write(layer, path, layer = layer_name, quiet = TRUE,
                 append = written_any)
    written_any <- TRUE
  }
  invisible(path)
}

## Attach each campaign's date, epoch and site to a table that has a `campaign`
## column. Used by every geometry table, all of which need the same six columns.
gl_attach_metadata <- function(x, campaigns) {
  meta <- campaigns[, c("campaign", "date", "year", "epoch", "block", "is_mosaic")]
  merge(x, meta, by = "campaign", all.x = TRUE, sort = FALSE)
}

## Rename an sf object's geometry column.
## WHY: sf calls it "geometry" when an object is built in memory, but GeoPackage
## calls it "geom", so an object read back from disk cannot be rbind()-ed onto a
## fresh one until the names agree.
gl_rename_geometry <- function(x, to) {
  current <- attr(x, "sf_column")
  names(x)[names(x) == current] <- to
  sf::st_geometry(x) <- to
  x
}

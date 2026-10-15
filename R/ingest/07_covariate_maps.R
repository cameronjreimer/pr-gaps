## ---------------------------------------------------------------------------
## Overview maps of the covariate layers, one PNG per harmonized layer.
##
## Each figure is drawn from the EPSG:32161 copy under interim/covariates/, so it
## shows exactly what later steps will read. Rasters are thinned to about a
## million cells before plotting (the 2 m C-CAP mosaic is 8 billion), which is
## fine for an overview and keeps every figure to a few seconds.
##
## Legends come from the data where they exist:
##   * class colours — the colour table stored in each categorical GeoTIFF;
##   * class names   — GAP: the raster attribute table in the .aux sidecar;
##                     Helmer: raw/.../PuertoRico_class_list_cloudf2class.txt;
##                     C-CAP: the table below (from the NOAA metadata);
##                     Holdridge: the LifeZonesDesc field.
## Only classes that actually occur in the map are listed.
##
## Needs terra, sf, ggplot2, ggspatial, ragg, scales, stringr and viridisLite.
## ---------------------------------------------------------------------------

## C-CAP class names. The two products share a scheme but not quite a legend:
## the high-resolution one folds the developed intensity classes into a single
## "Impervious" class and words 6 and 8 differently.
CCAP_CLASSES <- c(
  `0` = "Background", `1` = "Unclassified",
  `2` = "Developed, high intensity", `3` = "Developed, medium intensity",
  `4` = "Developed, low intensity", `5` = "Developed, open space",
  `6` = "Cultivated land", `7` = "Pasture/hay", `8` = "Grassland",
  `9` = "Deciduous forest", `10` = "Evergreen forest", `11` = "Mixed forest",
  `12` = "Scrub/shrub", `13` = "Palustrine forested wetland",
  `14` = "Palustrine scrub/shrub wetland", `15` = "Palustrine emergent wetland",
  `16` = "Estuarine forested wetland", `17` = "Estuarine scrub/shrub wetland",
  `18` = "Estuarine emergent wetland", `19` = "Unconsolidated shore",
  `20` = "Bare land", `21` = "Open water", `22` = "Palustrine aquatic bed",
  `23` = "Estuarine aquatic bed"
)
CCAP_HR_CLASSES <- replace(CCAP_CLASSES, c("2", "6", "8"),
                           c("Impervious", "Cultivated crops",
                             "Grassland/herbaceous"))

## What to draw for each interim file, matched on its file name. `kind` is
## "continuous", "categorical" or "vector"; `palette` is a vector of colours for
## a continuous map. `names` is only for categoricals whose names are not stored
## in the raster.
gl_map_spec <- function(file, raw_root) {
  f <- basename(file)
  continuous <- function(title, legend, palette, limits = NULL, zero_is_na = FALSE,
                         transform = identity)
    list(kind = "continuous", title = title, legend = legend, palette = palette,
         limits = limits, zero_is_na = zero_is_na, transform = transform)
  categorical <- function(title, names = NULL, wrap = 40)
    list(kind = "categorical", title = title, names = names, wrap = wrap)

  if (grepl("treecover2000", f))
    continuous("Tree canopy cover, 2000", "Tree cover (%)",
               c("#f7fcb9", "#addd8e", "#41ab5d", "#006837", "#00331c"), c(0, 100))
  else if (grepl("lossyear", f))
    continuous("Forest loss, 2001–2025", "Year of loss",
               viridisLite::inferno(7, direction = -1, end = 0.95),
               c(2001, 2025), zero_is_na = TRUE, transform = function(v) v + 2000)
  else if (grepl("datamask", f))
    categorical("Hansen data mask",
                c(`0` = "No data", `1` = "Mapped land", `2` = "Permanent water"))
  else if (grepl("ccap_high_res", f))
    categorical("C-CAP land cover, 2010 (high resolution, 2 m)", CCAP_HR_CLASSES)
  else if (grepl("ccap", f))
    categorical("C-CAP land cover, 2010 (30 m)", CCAP_CLASSES)
  else if (grepl("gap_landcover", f))
    categorical("Puerto Rico GAP land cover, c. 2000 (15 m)", wrap = 52)
  else if (grepl("landcov2000_cloudfor2class", f)) {
    classes <- utils::read.delim(file.path(raw_root, "helmer_formations", "Data",
                                           "PuertoRico_class_list_cloudf2class.txt"),
                                 stringsAsFactors = FALSE, quote = "")
    categorical("Land cover and forest formations, c. 2000 (Kennaway & Helmer)",
                setNames(classes$Class_name, classes$Class_number), wrap = 52)
  }
  ## PRISM grids are stored as value x 100 (the metadata units read "mm*100"),
  ## so the maps divide by 100. The interim rasters themselves keep the x100.
  else if (grepl("_ppt_", f))
    continuous("Mean annual precipitation, 1963–1995", "mm / year",
               c("#fff7bc", "#c7e9b4", "#41b6c4", "#225ea8", "#081d58"),
               transform = function(v) v / 100)
  else if (grepl("_tmax_", f))
    continuous("Mean annual maximum temperature, 1963–1995", "°C",
               viridisLite::plasma(7, direction = -1, end = 0.95),
               transform = function(v) v / 100)
  else if (grepl("_tmin_", f))
    continuous("Mean annual minimum temperature, 1963–1995", "°C",
               viridisLite::plasma(7, direction = -1, end = 0.95),
               transform = function(v) v / 100)
  else if (grepl("Holdridge", f))
    list(kind = "vector", title = "Holdridge life zones", field = "LifeZonesDesc",
         wrap = 36)
  else
    NULL
}

## Shared look: pale panel standing in for the sea, no axes, legend on the right.
gl_map_theme <- function() {
  ggplot2::theme_void(base_size = 11) +
    ggplot2::theme(
      plot.background  = ggplot2::element_rect(fill = "white", colour = NA),
      panel.background = ggplot2::element_rect(fill = "#eef2f4", colour = NA),
      plot.margin      = ggplot2::margin(10, 12, 8, 12),
      plot.title       = ggplot2::element_text(face = "bold", size = 14,
                                               margin = ggplot2::margin(b = 2)),
      plot.subtitle    = ggplot2::element_text(colour = "grey35", size = 9.5,
                                               margin = ggplot2::margin(b = 8)),
      plot.caption     = ggplot2::element_text(colour = "grey45", size = 7.5,
                                               hjust = 0, margin = ggplot2::margin(t = 8)),
      legend.title     = ggplot2::element_text(face = "bold", size = 9.5),
      legend.text      = ggplot2::element_text(size = 8),
      legend.key.size  = grid::unit(0.42, "cm"),
      legend.position  = "right"
    )
}

## Furniture common to every map: metric scale bar and a north arrow.
gl_map_furniture <- function() {
  list(
    ggspatial::annotation_scale(location = "bl", width_hint = 0.25, text_cex = 0.7,
                                bar_cols = c("grey25", "white")),
    ggspatial::annotation_north_arrow(
      location = "tr", which_north = "true", height = grid::unit(0.8, "cm"),
      width = grid::unit(0.8, "cm"),
      style = ggspatial::north_arrow_minimal(text_size = 7))
  )
}

## Thin a raster to roughly `maxcell` cells by regular sampling. Nearest-cell
## sampling is the right choice for class codes; it never invents a value.
gl_thin_raster <- function(r, maxcell = 1.2e6) {
  if (terra::ncell(r) <= maxcell) return(r)
  terra::spatSample(r, size = maxcell, method = "regular", as.raster = TRUE)
}

## The extent every map is cropped to: the area the high-resolution C-CAP map
## covers, padded by 3%. Taken from the cells that hold data, not the file's
## bounding box. Falls back to the island outline if that layer is absent.
gl_map_frame <- function(interim_root, outline) {
  hr <- list.files(file.path(interim_root, "ccap_high_res"), pattern = "[.]tif$",
                   full.names = TRUE)
  if (length(hr)) {
    r <- gl_thin_raster(terra::rast(hr[1])[[1]])
    d <- as.data.frame(r, xy = TRUE, na.rm = TRUE)
    x <- range(d$x); y <- range(d$y)
  } else {
    b <- sf::st_bbox(outline)
    x <- c(b[["xmin"]], b[["xmax"]]); y <- c(b[["ymin"]], b[["ymax"]])
  }
  list(xmin = x[1] - 0.03 * diff(x), xmax = x[2] + 0.03 * diff(x),
       ymin = y[1] - 0.03 * diff(y), ymax = y[2] + 0.03 * diff(y))
}

## Island outline, drawn over the data so the coast reads the same on every map.
gl_map_outline <- function(outline) {
  ggplot2::geom_sf(data = outline, inherit.aes = FALSE, fill = NA,
                   colour = "grey10", linewidth = 0.3)
}

## Map one raster. Returns the ggplot and a suggested size in inches.
gl_map_raster <- function(file, spec, subtitle, caption, frame, outline) {
  r <- terra::rast(file)[[1]]
  ## Crop to the shared frame first, so the thinning budget is spent on the part
  ## that is drawn.
  r <- terra::crop(r, terra::ext(frame$xmin, frame$xmax, frame$ymin, frame$ymax))
  r <- gl_thin_raster(r)
  names(r) <- "v"
  ## GAP stores its class names as raster categories, and as.data.frame() would
  ## then return those names instead of the numeric codes. Drop them here; the
  ## names are looked up again from the file below.
  if (terra::is.factor(r)) levels(r) <- NULL
  d <- as.data.frame(r, xy = TRUE, na.rm = TRUE)
  if (isTRUE(spec$zero_is_na)) d <- d[d$v != 0, ]

  p <- ggplot2::ggplot(d, ggplot2::aes(x, y))
  ncol_legend <- 1L

  if (spec$kind == "continuous") {
    d$v <- spec$transform(d$v)
    limits <- if (is.null(spec$limits)) range(d$v, na.rm = TRUE) else spec$limits
    p <- p +
      ggplot2::geom_raster(data = d, ggplot2::aes(fill = v)) +
      ggplot2::scale_fill_gradientn(
        colours = spec$palette, limits = limits, name = spec$legend,
        oob = scales::squish,
        guide = ggplot2::guide_colourbar(
          barheight = grid::unit(7, "cm"), barwidth = grid::unit(0.45, "cm"),
          ticks.colour = "white", frame.colour = "grey60"))
  } else {
    ## Classes present in the map, with names and the colours stored in the file.
    present <- sort(unique(d$v))
    ct <- terra::coltab(terra::rast(file)[[1]])[[1]]
    cols <- if (is.null(ct)) NULL else
      grDevices::rgb(ct$red, ct$green, ct$blue, maxColorValue = 255)[match(present, ct$value)]
    if (is.null(cols) || anyNA(cols)) cols <- scales::hue_pal()(length(present))

    nm <- spec$names
    if (is.null(nm)) {                    # GAP: names live in the raster's own table
      cl <- terra::cats(terra::rast(file)[[1]])[[1]]
      nm <- setNames(as.character(cl[[2]]), cl[[1]])
    }
    labels <- unname(nm[as.character(present)])
    labels[is.na(labels) | !nzchar(labels)] <- paste("class", present[is.na(labels) | !nzchar(labels)])
    wrapped <- stringr::str_wrap(sprintf("%s  %s", present, labels), spec$wrap)

    d$cls <- factor(d$v, levels = present, labels = wrapped)
    ncol_legend <- max(1L, ceiling(length(present) / 24))
    p <- p +
      ggplot2::geom_raster(data = d, ggplot2::aes(fill = cls)) +
      ggplot2::scale_fill_manual(values = setNames(cols, wrapped), name = "Class",
                                 drop = FALSE) +
      ggplot2::guides(fill = ggplot2::guide_legend(ncol = ncol_legend,
                                                   byrow = TRUE))
  }

  ex <- frame
  p <- p +
    gl_map_outline(outline) +
    gl_map_furniture() +
    ggplot2::coord_sf(crs = sf::st_crs(CRS_AREA), datum = NA, expand = FALSE,
                      xlim = c(ex$xmin, ex$xmax), ylim = c(ex$ymin, ex$ymax)) +
    ggplot2::labs(title = spec$title, subtitle = subtitle, caption = caption) +
    gl_map_theme()

  map_w <- 8
  map_h <- map_w * (ex$ymax - ex$ymin) / (ex$xmax - ex$xmin)
  legend_h <- 0
  if (spec$kind == "categorical") {
    ## Tall legends (GAP has 70 classes) set the page height, not the map.
    lines_per_class <- vapply(strsplit(levels(d$cls), "\n", fixed = TRUE), length, 1L)
    ## Entries fill row by row, so a row is as tall as its longest label.
    row_lines <- tapply(lines_per_class,
                        ceiling(seq_along(lines_per_class) / ncol_legend), max)
    legend_h <- sum(row_lines) * 0.16 + length(row_lines) * 0.14 + 1.2
  }
  list(plot = p, width = map_w + 1.6 + 2.6 * (ncol_legend - 0.4) * (spec$kind == "categorical"),
       height = max(5, map_h + 1.4, legend_h))
}

## Map the Holdridge polygons.
gl_map_vector <- function(file, spec, subtitle, caption, frame, outline) {
  v <- sf::st_read(file, quiet = TRUE)

  ## Frame the main island and its nearby islands (the file also covers the
  ## U.S. Virgin Islands). PR_BBOX is the lon/lat box set in 03_download_covars.R.
  if (exists("PR_BBOX")) {
    box <- sf::st_as_sfc(sf::st_bbox(c(xmin = PR_BBOX[["xmin"]], xmax = PR_BBOX[["xmax"]],
                                       ymin = PR_BBOX[["ymin"]], ymax = PR_BBOX[["ymax"]]),
                                     crs = sf::st_crs(4326)))
    v <- suppressWarnings(sf::st_intersection(v, sf::st_transform(box, sf::st_crs(v))))
  }
  ## Polygons with no zone (offshore slivers, open water) get a grey entry of
  ## their own rather than ggplot's default "NA".
  label <- as.character(v[[spec$field]])
  label[is.na(label) | !nzchar(label)] <- "No zone assigned"
  v$cls <- stringr::str_wrap(label, spec$wrap)
  ex <- frame

  levels_present <- sort(unique(v$cls))
  fills <- setNames(scales::brewer_pal(palette = "Set3")(max(3, sum(levels_present != "No zone assigned"))),
                    levels_present[levels_present != "No zone assigned"])
  fills <- c(fills, "No zone assigned" = "grey80")

  p <- ggplot2::ggplot(v) +
    ggplot2::geom_sf(ggplot2::aes(fill = cls), colour = "white", linewidth = 0.08) +
    ggplot2::scale_fill_manual(values = fills, name = "Life zone") +
    gl_map_outline(outline) +
    gl_map_furniture() +
    ggplot2::coord_sf(crs = sf::st_crs(CRS_AREA), datum = NA, expand = FALSE,
                      xlim = c(ex$xmin, ex$xmax), ylim = c(ex$ymin, ex$ymax)) +
    ggplot2::labs(title = spec$title, subtitle = subtitle, caption = caption) +
    gl_map_theme()

  map_w <- 8
  list(plot = p, width = map_w + 3.2,
       height = max(5, map_w * (ex$ymax - ex$ymin) / (ex$xmax - ex$xmin) + 1.4))
}

## Make every figure. `registry` supplies the subtitle (vintage, resolution) and
## the source line for each layer. Returns the number that failed.
gl_covariate_maps <- function(interim_root, raw_root, out_dir, registry,
                              boundary, layers = NULL) {
  stopifnot(requireNamespace("ggplot2", quietly = TRUE),
            requireNamespace("ggspatial", quietly = TRUE),
            requireNamespace("ragg", quietly = TRUE),
            requireNamespace("stringr", quietly = TRUE),
            requireNamespace("viridisLite", quietly = TRUE),
            requireNamespace("scales", quietly = TRUE),
            requireNamespace("terra", quietly = TRUE),
            requireNamespace("sf", quietly = TRUE))
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  files <- list.files(interim_root, pattern = "[.](tif|gpkg)$", recursive = TRUE,
                      full.names = TRUE)
  if (!is.null(layers)) files <- files[basename(dirname(files)) %in% layers]
  if (!length(files)) {
    gl_msg("no harmonized layers under ", interim_root, " — run --reproject first")
    return(1L)
  }

  ## Island outline and the one extent shared by every map.
  if (!file.exists(boundary)) stop("no island outline at ", boundary)
  outline <- sf::st_transform(sf::st_read(boundary, quiet = TRUE), CRS_AREA)
  frame <- gl_map_frame(interim_root, outline)

  n_failed <- 0L
  for (file in files) {
    layer <- basename(dirname(file))
    spec <- gl_map_spec(file, raw_root)
    if (is.null(spec)) { gl_msg("no map spec for ", basename(file), " — skipped"); next }

    reg <- registry[registry$layer == layer, , drop = FALSE]
    subtitle <- if (nrow(reg)) sprintf("%s  ·  %s", reg$vintage[1], reg$resolution[1]) else ""
    caption <- sprintf("EPSG:32161 (NAD83 / Puerto Rico & Virgin Is.)  ·  layer: %s  ·  source: %s",
                       layer, if (nrow(reg)) reg$citation_key[1] else "unregistered")

    dest <- file.path(out_dir, paste0(tools::file_path_sans_ext(basename(file)), ".png"))
    gl_msg("map ", basename(dest))
    ok <- !is.null(gl_try({
      m <- if (spec$kind == "vector")
             gl_map_vector(file, spec, subtitle, caption, frame, outline)
           else gl_map_raster(file, spec, subtitle, caption, frame, outline)
      ## geom_raster warns that thinned-raster cell centres are not exactly even
      ## (floating-point noise in projected coordinates); harmless here.
      withCallingHandlers(
        ggplot2::ggsave(dest, m$plot, device = ragg::agg_png, width = m$width,
                        height = m$height, units = "in", dpi = 200),
        warning = function(w) {
          if (grepl("uneven horizontal", conditionMessage(w))) invokeRestart("muffleWarning")
        })
      TRUE
    }, basename(file)))
    if (!ok) n_failed <- n_failed + 1L
  }
  n_failed
}

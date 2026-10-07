## ---------------------------------------------------------------------------
## Puerto Rico's coastline, used as a basemap by the figures in 07_report.R.
##
## Source: the US Census TIGER/Line cartographic boundary at 1:500,000, via the
## tigris package.
##
## WHY the Census rather than a global coastline dataset: Puerto Rico is a US
## territory, so the Census files are the authoritative boundary, and the
## 1:500k generalisation is the right level of detail for an island-wide map —
## the full-resolution TIGER coastline is far more vertices than 1,800 px can
## show.
##
## Only the main island is kept. The territory also includes Mona (55 km²),
## Vieques (133 km²) and Culebra (27 km²); including them stretches the map from
## 175 km to 288 km wide, almost all of it empty ocean, and no G-LiHT coverage
## falls on any of them. The main island on its own spans 178 x 65 km against
## the footprints' 175 x 65 km, so it frames the data almost exactly.
##
## Cached under interim/ rather than raw/ because the stored layer is a
## union-reproject-and-filter of the Census file rather than the file as
## published, and one call regenerates it.
##
## Everything here degrades to NULL rather than failing: without tigris, or
## without a network, the maps are simply drawn with no coastline.
## ---------------------------------------------------------------------------

gl_pr_boundary <- function(refresh = FALSE) {
  cache <- file.path(gl_data_root(), "interim", "boundary", "pr_main_island.gpkg")

  if (!refresh && file.exists(cache)) {
    return(gl_try(sf::st_read(cache, quiet = TRUE), "cached PR boundary"))
  }
  if (!requireNamespace("tigris", quietly = TRUE)) {
    gl_msg("tigris is not installed — maps will be drawn without a coastline")
    return(NULL)
  }

  ## tigris keeps its own download cache, so this is a one-off even on a refresh.
  previous_option <- options(tigris_use_cache = TRUE)
  municipios <- gl_try(
    tigris::counties(state = "PR", cb = TRUE, year = 2022, progress_bar = FALSE),
    "PR boundary download")
  options(previous_option)
  if (is.null(municipios)) return(NULL)

  ## Dissolve the 78 municipios into land, then keep the largest landmass.
  land <- sf::st_union(sf::st_geometry(sf::st_transform(municipios, CRS_AREA)))
  parts <- sf::st_cast(land, "POLYGON")
  main_island <- parts[which.max(as.numeric(sf::st_area(parts)))]

  boundary <- sf::st_sf(name = "Puerto Rico (main island)", geometry = main_island)
  dir.create(dirname(cache), recursive = TRUE, showWarnings = FALSE)
  sf::st_write(boundary, cache, quiet = TRUE, delete_dsn = TRUE)
  gl_msg("coastline cached: ", cache)
  boundary
}

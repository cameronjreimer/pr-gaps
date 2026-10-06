## ---------------------------------------------------------------------------
## Step 2 — Where did the plane actually fly, and what ground does that cover?
##
## Two geometries per campaign:
##   trajectory  the aircraft's ground track
##   footprint   the ground the lidar actually covered
##
## Getting the footprint right takes one non-obvious step. G-LiHT publishes a
## shapefile of polygons per campaign, but it is not a map of coverage:
##
##   * for tile-delivered campaigns it is a complete rectangular grid over the
##     campaign's bounding box, and most of its ~1 km tiles are empty — for
##     PR_15March2017_EV1 the grid has 40 tiles and only 13 hold data;
##   * for strip-delivered campaigns it is one polygon per flight-line strip,
##     which does match what was delivered.
##
## What tells the two apart is the LAS file names, which say exactly which tiles
## or strips exist. So the footprint is the published polygons filtered to those
## that have a matching LAS.
##
## IMPORTANT, and the reason 06_refine_chm.R exists: even after filtering these
## polygons OVERESTIMATE coverage, because a G-LiHT swath is a few hundred
## metres wide while a tile is ~1 km, and a strip polygon envelopes its swath
## rather than tracing it. Measured against the canopy height model, the true
## area is 20-52% of the tile figure. Use these numbers for scoping, never for
## an area that goes into a result.
##
## Produces:
##   derived/inventory/pr_footprints.gpkg    layers: tiles, campaign_footprints,
##                                           trajectories
##   derived/inventory/pr_footprint_summary.csv
## ---------------------------------------------------------------------------

## Download a campaign's tile or trajectory shapefile and return the local path.
##
## The same shapefile is published three different ways depending on the
## campaign — as a .zip, as a .tar.gz one directory down, or as loose .shp/.shx/
## .dbf/.prj components — so all three have to be tried. Archives are preferred
## because they are one request instead of four and cannot arrive with a
## component missing.
gl_fetch_shapefile <- function(campaign, files, kind = c("tiles", "trajectory")) {
  kind <- match.arg(kind)
  campaign_files <- files[files$campaign == campaign, , drop = FALSE]
  if (!nrow(campaign_files)) return(NA_character_)
  dest_dir <- file.path(gl_paths()$vector, campaign, kind)

  patterns <- if (kind == "tiles") {
    c(zip = "_tiles[.]zip$",
      tar = "_tiles_shp[.]tar[.]gz$",
      shp = "_tiles[.]shp$")
  } else {
    c(zip = "_trajectory[.]zip$",
      tar = "_trajectory_shp[.]tar[.]gz$",
      shp = "gnd-trajectory[.]shp$")
  }

  for (packaging in c("zip", "tar")) {
    archive <- campaign_files[grepl(patterns[[packaging]], campaign_files$name), ]
    if (nrow(archive)) {
      local_archive <- file.path(dest_dir, archive$name[1])
      gl_download(archive$url[1], local_archive, archive$size_bytes[1])
      gl_extract(local_archive, dest_dir)
      found <- list.files(dest_dir, pattern = "[.]shp$", recursive = TRUE,
                          full.names = TRUE)
      if (length(found)) return(found[1])
    }
  }

  ## Loose components: fetch the .shp and each of its sidecar files, which a
  ## shapefile is unreadable without.
  main <- campaign_files[grepl(patterns[["shp"]], campaign_files$name), ]
  if (!nrow(main)) return(NA_character_)
  stem <- sub("[.]shp$", "", main$name[1])
  components <- campaign_files[
    grepl(paste0("^", stem, "[.](shp|shx|dbf|prj|cpg)$"), campaign_files$name), ]
  for (i in seq_len(nrow(components))) {
    gl_download(components$url[i], file.path(dest_dir, components$name[i]),
                components$size_bytes[i])
  }

  local_shp <- file.path(dest_dir, paste0(stem, ".shp"))
  if (file.exists(local_shp)) local_shp else NA_character_
}

## The tile or strip identifiers that actually hold data, read off the LAS file
## names — "c0r0" from PR_15March2017_EV1_c0r0.las.gz, "l0s3" from a strip
## campaign. These are matched against the shapefile's Name field.
gl_data_tile_ids <- function(campaign, files) {
  las_names <- files$name[files$campaign == campaign & files$subdir == "lidar/las/"]
  ids <- regmatches(
    las_names,
    regexpr("(c[0-9]+r[0-9]+|l[0-9]+s[0-9]+)(?=[.]las)", las_names, perl = TRUE))
  unique(ids)
}

## Read a shapefile into the analysis CRS.
## The three cleanups are all routine for this data: G-LiHT polygons carry a Z
## coordinate that nothing here uses, they arrive in lon/lat, and a few have
## self-intersections that would make later overlays fail.
gl_read_vector <- function(shp) {
  x <- sf::st_read(shp, quiet = TRUE)
  x <- sf::st_zm(x, drop = TRUE, what = "ZM")
  x <- sf::st_transform(x, CRS_AREA)
  sf::st_make_valid(x)
}

## One campaign's published polygons, each flagged with whether a LAS was
## actually delivered for it.
gl_campaign_tiles <- function(campaign, files) {
  shp <- gl_fetch_shapefile(campaign, files, "tiles")
  if (is.na(shp)) return(NULL)
  polygons <- gl_read_vector(shp)
  if (!nrow(polygons)) return(NULL)

  ## The identifier field is "Name" in most campaigns and "name" in a few.
  if ("Name" %in% names(polygons)) {
    tile_id <- as.character(polygons$Name)
  } else if ("name" %in% names(polygons)) {
    tile_id <- as.character(polygons$name)
  } else {
    tile_id <- NA_character_
  }

  las_names <- files$name[files$campaign == campaign & files$subdir == "lidar/las/"]
  delivered <- gl_data_tile_ids(campaign, files)

  tiles <- sf::st_sf(
    campaign   = campaign,
    tile       = tile_id,
    has_las    = tile_id %in% delivered,
    las_scheme = gl_las_scheme(las_names),
    geometry   = sf::st_geometry(polygons)
  )
  tiles$area_ha <- gl_area_ha(tiles)
  tiles
}

## One campaign's flight track.
##
## Careful: the published trajectory is the WHOLE DAY's ground track, not the
## track for this block alone. Every campaign flown on 2017-03-01 ships the same
## 533 km line, and PR_15March2017_EV1's is 1,127 km against a block of about
## 13 km². It is useful as context but must be de-duplicated by date before any
## track length is added up — see gl_step_footprints() below.
gl_campaign_trajectory <- function(campaign, files) {
  shp <- gl_fetch_shapefile(campaign, files, "trajectory")
  if (is.na(shp)) return(NULL)
  track <- gl_read_vector(shp)
  if (!nrow(track)) return(NULL)

  track <- sf::st_sf(campaign = campaign,
                     geometry = sf::st_union(sf::st_geometry(track)))
  track$length_km <- as.numeric(sf::st_length(track)) / 1000
  track
}

## Collapse the duplicated day tracks down to one feature per flight day, and
## record which campaigns shared each one.
gl_dedupe_trajectories <- function(traj) {
  if (is.null(traj) || !nrow(traj)) return(traj)

  ## Same date and same length (to the metre) means the same flight track.
  day_key <- paste(traj$date, round(traj$length_km, 3))

  ## Keep the first campaign for each distinct track, then record on it the
  ## names of all the campaigns that shared it.
  first_of_day <- !duplicated(day_key)
  kept <- traj[first_of_day, ]
  kept_keys <- day_key[first_of_day]

  shared_with <- character(nrow(kept))
  shared_count <- integer(nrow(kept))
  for (i in seq_along(kept_keys)) {
    sharing <- traj$campaign[day_key == kept_keys[i]]
    shared_with[i] <- paste(sharing, collapse = ";")
    shared_count[i] <- length(sharing)
  }

  kept$campaigns <- shared_with
  kept$n_campaigns <- shared_count
  kept
}

## Dissolve each campaign's data-bearing polygons into a single footprint.
##
## tile_source records how the match went, because the three outcomes carry
## different errors and a reader needs to know which one they are looking at:
##   las_tiles   grid filtered down to the tiles that hold data
##   las_strips  per-strip polygons, one-to-one with what was delivered
##   tile_grid   nothing matched, so the whole grid is used — a hard upper bound
gl_one_footprint <- function(campaign_tiles) {
  if (!any(campaign_tiles$has_las)) {
    source_type <- "tile_grid"
  } else if (campaign_tiles$las_scheme[1] == "lXsY") {
    source_type <- "las_strips"
  } else {
    source_type <- "las_tiles"
  }

  covered <- campaign_tiles[campaign_tiles$in_footprint, ]
  merged_outline <- sf::st_union(sf::st_geometry(covered))

  sf::st_sf(campaign    = covered$campaign[1],
            tile_source = source_type,
            las_scheme  = covered$las_scheme[1],
            n_tiles     = nrow(covered),
            geometry    = merged_outline)
}

gl_campaign_footprints <- function(tiles) {
  ## split() groups the row numbers by campaign, in alphabetical order.
  rows_by_campaign <- split(seq_len(nrow(tiles)), tiles$campaign)

  per_campaign <- list()
  for (campaign in names(rows_by_campaign)) {
    rows <- rows_by_campaign[[campaign]]
    per_campaign[[campaign]] <- gl_one_footprint(tiles[rows, ])
  }

  footprints <- gl_stack(per_campaign)
  footprints$area_ha <- gl_area_ha(footprints)
  footprints
}

## Run step 2 and write the GeoPackage.
gl_step_footprints <- function(campaigns, files) {
  gl_init_dirs()
  to_build <- campaigns$campaign

  ## Fetch and read both geometries for every campaign. A campaign that fails
  ## warns and is skipped rather than ending the run.
  tile_list <- traj_list <- vector("list", length(to_build))
  for (i in seq_along(to_build)) {
    if (i %% 20 == 1) {
      gl_msg(sprintf("footprints %d/%d: %s", i, length(to_build), to_build[i]))
    }
    tile_list[[i]] <- gl_try(gl_campaign_tiles(to_build[i], files), to_build[i])
    traj_list[[i]] <- gl_try(gl_campaign_trajectory(to_build[i], files), to_build[i])
  }
  tiles <- gl_stack(tile_list)
  traj  <- gl_stack(traj_list)
  if (is.null(tiles)) stop("no tile shapefiles could be read for any campaign")

  tiles <- gl_attach_metadata(tiles, campaigns)
  if (!is.null(traj)) {
    traj <- gl_attach_metadata(traj, campaigns)
    traj <- gl_dedupe_trajectories(traj)
  }

  ## Which polygons count as coverage. Normally those with a delivered LAS; for
  ## a campaign where nothing matched, all of them, so the campaign is not
  ## silently dropped from the inventory.
  tiles$in_footprint <- tiles$has_las
  for (campaign in unique(tiles$campaign)) {
    rows <- tiles$campaign == campaign
    if (!any(tiles$has_las[rows])) tiles$in_footprint[rows] <- TRUE
  }

  footprints <- gl_campaign_footprints(tiles)
  footprints <- gl_attach_metadata(footprints, campaigns)
  footprints <- footprints[order(footprints$date, footprints$campaign), ]

  gl_write_gpkg("pr_footprints.gpkg",
                list(tiles = tiles,
                     campaign_footprints = footprints,
                     trajectories = traj))
  gl_write_csv(sf::st_drop_geometry(footprints), "pr_footprint_summary.csv")

  gl_msg(sprintf("footprints: %d campaigns, %d data tiles, %.0f ha of tile coverage",
                 nrow(footprints), sum(tiles$has_las), sum(footprints$area_ha)))

  ## How many campaigns, and how much area, came from each kind of match.
  campaigns_per_source <- table(footprints$tile_source)
  area_per_source <- tapply(footprints$area_ha, footprints$tile_source, sum)
  gl_msg("footprint provenance (campaigns x ha):")
  print(cbind(n = campaigns_per_source, ha = round(area_per_source)))

  list(tiles = tiles, footprints = footprints, trajectories = traj)
}

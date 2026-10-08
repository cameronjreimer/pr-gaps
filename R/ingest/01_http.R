## ---------------------------------------------------------------------------
## Talking to the G-LiHT server.
##
## G-LiHT has no search API. What it has is an ordinary Apache "index of ..."
## web page per directory, so finding out what exists means fetching those pages
## and reading the file names out of the HTML. This file does three things:
##
##   gl_index()     fetch one directory page and turn it into a table
##   gl_download()  fetch one file, safely and restartably
##   gl_extract()   unpack a downloaded .zip or .tar.gz
##
## Every directory listing is saved to disk as JSON the first time it is
## fetched. A second run then costs no network traffic at all, and a crawl
## interrupted halfway resumes from where it stopped instead of starting over.
## ---------------------------------------------------------------------------

## Turn a URL into a safe file name for its cached listing, e.g.
##   ".../PR_15March2017_EV1/lidar/las/"  ->  "PR_15March2017_EV1__lidar__las"
## The 180-character cap keeps the result inside Windows' path length limit.
gl_cache_key <- function(u) {
  rel <- sub(GLIHT_BASE, "", u, fixed = TRUE)
  rel <- gsub("/", "__", sub("/+$", "", rel))
  rel <- gsub("[^A-Za-z0-9_.-]+", "_", rel)
  if (!nzchar(rel)) rel <- "ROOT"
  substr(rel, 1, 180)
}

## The shape of a directory listing, with no rows in it.
## WHY a function: a missing directory, an unreadable cache file and an empty
## page all have to return this, and the three copies previously drifted apart.
gl_empty_index <- function() {
  data.frame(name = character(), is_dir = logical(), size_bytes = numeric(),
             modified = character(), url = character(), stringsAsFactors = FALSE)
}

## Fetch a URL and return its text, or NULL if it is not there.
##
## NULL rather than an error is deliberate: plenty of campaigns legitimately
## lack a given subdirectory (not every flight has lidar/shp/tiles/), so a 404
## is an expected answer, not a failure. Genuine network failures are retried
## with a doubling delay before giving up.
gl_fetch_text <- function(u, retries = HTTP_RETRIES) {
  handle <- curl::new_handle(timeout = HTTP_TIMEOUT, followlocation = TRUE)

  for (attempt in seq_len(retries)) {
    response <- tryCatch(curl::curl_fetch_memory(u, handle = handle),
                         error = function(e) NULL)
    Sys.sleep(HTTP_PAUSE)          # be a polite guest on someone else's server
    if (is.null(response)) next
    if (response$status_code == 404L) return(NULL)
    if (response$status_code >= 200L && response$status_code < 300L) {
      return(rawToChar(response$content))
    }
    Sys.sleep(2^attempt)
  }
  NULL
}

## Convert the file sizes Apache prints ("6.9M", "13K", "1.2G", "482") to bytes.
##
## These are rounded for human reading, so the result is good to about two
## significant figures. That is fine for the only two things it is used for —
## estimating how big a download will be, and sanity-checking a file that is
## already on disk — but it is not a checksum.
gl_parse_size <- function(x) {
  x <- trimws(x)
  out <- rep(NA_real_, length(x))
  parseable <- grepl("^[0-9.]+[KMGT]?$", x)
  number <- suppressWarnings(as.numeric(gsub("[KMGT]$", "", x[parseable])))
  suffix <- toupper(gsub("^[0-9.]+", "", x[parseable]))
  suffix[!nzchar(suffix)] <- "B"                 # a bare number is already bytes
  multiplier <- c(B = 1, K = 1024, M = 1024^2, G = 1024^3, T = 1024^4)
  out[parseable] <- number * as.numeric(multiplier[suffix])
  out
}

## Read one Apache directory page into a table of name / is_dir / size / date.
##
## Each entry is a single <tr> line holding a link followed by two right-aligned
## cells, the modification date and the size:
##   <td><a href="NAME">...</a></td><td align="right">DATE</td><td align="right">SIZE</td>
## Requiring both of those cells is what filters out the page's other links: the
## column-sort headers have no such cells, and the "Parent Directory" row has
## only one.
gl_parse_index <- function(html, base_url) {
  all_lines <- strsplit(html, "\n", fixed = TRUE)[[1]]
  lines <- grep("<a href=", all_lines, value = TRUE)

  entry <- paste0('<a href="([^"]+)">.*?</a>.*?',
                  '<td align="right">([^<]*)</td>.*?<td align="right">([^<]*)</td>')
  matches <- regmatches(lines, regexec(entry, lines, perl = TRUE))
  matches <- matches[lengths(matches) == 4L]     # whole match + 3 capture groups
  if (!length(matches)) return(gl_empty_index())

  ## One row per entry: column 1 is the whole match, 2-4 are the captures.
  parts <- do.call(rbind, matches)
  href <- parts[, 2]
  keep <- !grepl("^[?/]", href)                  # belt-and-braces: sorts, parent
  href <- href[keep]

  data.frame(
    name       = sub("/$", "", href),            # directories arrive as "name/"
    is_dir     = grepl("/$", href),
    size_bytes = gl_parse_size(parts[keep, 4]),
    modified   = trimws(parts[keep, 3]),
    url        = paste0(sub("/+$", "", base_url), "/", href),
    stringsAsFactors = FALSE
  )
}

## One directory listing, from the cache if we have it and from the server if
## not. Missing directories are cached too, as an empty table, so that a
## re-crawl does not ask the server about them all over again.
gl_index <- function(u, refresh = FALSE) {
  cache_file <- file.path(gl_paths()$cache, paste0(gl_cache_key(u), ".json"))
  dir.create(dirname(cache_file), recursive = TRUE, showWarnings = FALSE)

  if (!refresh && file.exists(cache_file)) {
    cached <- tryCatch(jsonlite::read_json(cache_file, simplifyVector = TRUE),
                       error = function(e) NULL)
    ## An empty listing round-trips through JSON as an empty list, not a table.
    if (is.data.frame(cached)) {
      return(if (nrow(cached)) cached else gl_empty_index())
    }
  }

  html <- gl_fetch_text(u)
  listing <- if (is.null(html)) gl_empty_index() else gl_parse_index(html, u)
  jsonlite::write_json(listing, cache_file, auto_unbox = TRUE, na = "null")
  listing
}

## ---------------------------------------------------------------------------
## Archives, and what counts as "we already have this file".
##
## Most G-LiHT rasters arrive compressed and are unusable in that form: a
## <campaign>_CHM.tar.gz has to be unpacked before anything can open the
## GeoTIFFs inside it. Once it has been, keeping the archive as well is just a
## second copy, so gl_unpack_archive() deletes it.
##
## That breaks the obvious way of asking whether a file has already been
## fetched — "is it on disk at the published size?" — because the thing that is
## on disk is now the unpacked form under a different name. gl_have_file()
## accepts either, which is what stops the next run downloading all of it again.
## ---------------------------------------------------------------------------

## Where an archive's contents end up. A tar or zip unpacks into a directory
## named after it; any other .gz is a single file with the suffix removed.
##   PR_X_CHM.tar.gz   -> directory PR_X_CHM/
##   PR_X_CHM.tif.gz   -> file      PR_X_CHM.tif
gl_unpacked_path <- function(archive) {
  if (grepl("[.](tar[.]gz|tgz|zip)$", archive, ignore.case = TRUE)) {
    list(kind = "dir",
         path = sub("[.](tar[.]gz|tgz|zip)$", "", archive, ignore.case = TRUE))
  } else if (grepl("[.]gz$", archive, ignore.case = TRUE)) {
    list(kind = "file", path = sub("[.]gz$", "", archive, ignore.case = TRUE))
  } else {
    list(kind = "none", path = NA_character_)
  }
}

## Has this archive already been unpacked, and is the result still there?
gl_unpacked_present <- function(archive) {
  target <- gl_unpacked_path(archive)
  if (target$kind == "dir") {
    dir.exists(target$path) &&
      length(list.files(target$path, recursive = TRUE)) > 0
  } else if (target$kind == "file") {
    file.exists(target$path) && file.size(target$path) > 0
  } else {
    FALSE
  }
}

## Do we already hold this file, in either form?
##
## `approx_bytes` is the rounded size from the directory listing, so the check
## allows 20% slack; it catches a truncated download, not a corrupted one. The
## unpacked form gets no size check — the published size describes the archive,
## and what it expands to is not knowable in advance.
gl_have_file <- function(dest, approx_bytes = NA_real_) {
  if (file.exists(dest)) {
    close_enough <- is.na(approx_bytes) ||
      abs(file.size(dest) - approx_bytes) <= 0.2 * approx_bytes
    if (close_enough) return(TRUE)
  }
  gl_unpacked_present(dest)
}

## Decompress a plain .gz to a named file, in 4 MB chunks so that a large
## raster never has to fit in memory. (R has no gunzip of its own, and pulling
## in R.utils for one function is not worth the dependency.)
gl_gunzip <- function(src, dest) {
  input <- gzfile(src, "rb")
  on.exit(close(input), add = TRUE)
  output <- file(dest, "wb")
  on.exit(close(output), add = TRUE)

  repeat {
    chunk <- readBin(input, "raw", n = 4L * 1024^2)
    if (!length(chunk)) break
    writeBin(chunk, output)
  }
  invisible(dest)
}

## Unpack an archive and, by default, delete it.
##
## The archive is only deleted once the unpacked form has been confirmed to
## exist, so a failed extraction leaves the download intact rather than losing
## both copies. Calling this on something already unpacked does nothing and
## reports where the contents are.
gl_unpack_archive <- function(archive, discard = TRUE) {
  target <- gl_unpacked_path(archive)
  if (target$kind == "none") return(invisible(NA_character_))

  if (!file.exists(archive)) {
    ## Nothing to do — either it was unpacked on an earlier run, or it is gone.
    return(invisible(if (gl_unpacked_present(archive)) target$path else NA_character_))
  }

  if (target$kind == "dir") {
    gl_extract(archive, target$path)
  } else {
    gl_gunzip(archive, target$path)
  }

  if (!gl_unpacked_present(archive)) {
    warning("nothing unpacked from ", basename(archive), "; archive kept",
            call. = FALSE)
    return(invisible(NA_character_))
  }

  if (discard) unlink(archive)
  invisible(target$path)
}

## Download one file.
##
## Two things make this restartable. A file we already hold is left alone, so
## re-running a part-finished download plan only fetches what is missing. And
## the transfer writes to "<name>.part" and renames it only on success, so an
## interrupted run can never leave a half-written file that looks complete to
## the next run.
##
## "Already hold" is gl_have_file()'s question, not a plain file.exists(): an
## archive that has been unpacked and deleted still counts, or every unpacked
## download would be fetched again on the next run.
gl_download <- function(u, dest, approx_bytes = NA_real_, retries = HTTP_RETRIES) {
  if (gl_have_file(dest, approx_bytes)) return(invisible(dest))

  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  partial <- paste0(dest, ".part")

  ## timeout = 0 means "no overall time limit", because a single LAS file can be
  ## 500 MB; the connect timeout still catches a server that is simply not there.
  ## The low-speed pair aborts a transfer that has stalled (under 1 KB/s for two
  ## minutes) — without it a hung connection would sit until the job's wall time
  ## ran out, and the abort counts as a failed attempt so it is retried.
  handle <- curl::new_handle(timeout = 0L, connecttimeout = 60L,
                             low_speed_limit = 1024L, low_speed_time = 120L,
                             followlocation = TRUE)

  for (attempt in seq_len(retries)) {
    ok <- tryCatch({
      curl::curl_download(u, partial, quiet = TRUE, handle = handle)
      TRUE
    }, error = function(e) FALSE)

    if (ok && file.exists(partial) && file.size(partial) > 0) {
      if (file.exists(dest)) unlink(dest)
      file.rename(partial, dest)
      return(invisible(dest))
    }
    unlink(partial)
    Sys.sleep(2^attempt)
  }
  stop("download failed after ", retries, " attempts: ", u)
}

## Unpack a downloaded archive and return the files it wrote.
## WHY both formats: G-LiHT ships shapefiles and rasters as .zip in some
## campaigns and .tar.gz in others, with no pattern to which.
gl_extract <- function(archive, exdir) {
  dir.create(exdir, recursive = TRUE, showWarnings = FALSE)
  if (grepl("[.]zip$", archive, ignore.case = TRUE)) {
    utils::unzip(archive, exdir = exdir)
  } else if (grepl("[.](tar[.]gz|tgz)$", archive, ignore.case = TRUE)) {
    utils::untar(archive, exdir = exdir)
    list.files(exdir, recursive = TRUE, full.names = TRUE)
  } else {
    stop("unsupported archive: ", archive)
  }
}

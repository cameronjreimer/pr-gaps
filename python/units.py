"""Step 1 (distances) for island-wide work units: `canopy.py --job N` / `--unit ID`.

docs/hpc-scaling-plan.md §4.4. The same distance code and cache format as a site run;
only the inputs differ:

- 2017 points: the unit's tile bucket of its 2017 campaign (retile.py), kept where the
  plan's ownership raster gives the point's 1 m column to this unit's pair. This
  replaces the site run's study-area polygon, so ownership is exact at pair and tile
  edges.
- 2018 reference: the pair's 2018 buckets for every tile within the search cap (50 m)
  of the unit's cell bounds, clipped to those bounds plus 50 m, not to the owned
  columns, so edge points still find their true nearest neighbour.
- Coverage (both flights' returns per 1 m column) is counted only on owned columns.
- Height above ground: the 2017 campaign's DTM from campaign_dtm.py's index.

Caches go to $PR_GAPS_DATA/runs/canopy/units/<unit>/cache/, so check_run.py works on
them as `check_run.py units/<unit>`. A cache's identity is the step-1 settings, the
unit's pair and bounds, a hash of its own owned columns and the bucket parts it read:
re-ranking pairs (D3) rebuilds only units whose columns changed. Provenance
(source_file / source_index) points at the original LAS files, as in a site cache.
"""

import hashlib
import shutil
import sys
import tempfile
import traceback
from pathlib import Path

import numpy as np
import pandas as pd

from canopy import (
    CHUNK_SIZE, COVERAGE_DTYPE, COVERAGE_RESOLUTION, DATA, GLIHT, MAX_SEARCH_M, MIN_POST_RETURNS,
    MIN_PRE_RETURNS, PLAN, POST_LOWEST_FILE, RETILED, SCHEMA_VERSION, SCRATCH, THREADS,
    VERTICAL_DATUM, Coverage, atomic_directory, common_support, dtm_signatures, exact_c2c,
    file_signature, import_cloudcompy, inspect_headers, load_cache, post_lowest_description,
    raw_to_npy, read_json, row_keys, sample_hag, semantic_preparation, stable_id, stamp,
    stream_epoch, verify_source_files, write_json,
)

UNITS = DATA / "runs" / "canopy" / "units"
TILE_M = 1000
# Retiled parts carry no CRS record; the plan, the tiles and every G-LiHT LAS are in this.
UNIT_CRS = "EPSG:32620"
BUFFER_M = MAX_SEARCH_M  # 2018 reference beyond the unit's bounds: the search cap
# Per-campaign vertical corrections (a datum mismatch, decided case by case and recorded).
VERTICAL_OFFSETS = Path(__file__).resolve().parent.parent / "derived" / "registration" / "vertical_offsets.csv"


def vertical_offset(campaign):
    """Metres added to a campaign's z, from derived/registration/vertical_offsets.csv (0 if none)."""
    if not VERTICAL_OFFSETS.is_file():
        return 0.0
    table = pd.read_csv(VERTICAL_OFFSETS).set_index("campaign")["dz_m"]
    return float(table.get(campaign, 0.0))


def load_units():
    path = PLAN / "work_units.csv"
    if not path.is_file():
        raise SystemExit(f"No work-unit plan at {PLAN}; run python/plan_units.py")
    return pd.read_csv(path)


def tile_corner(tile):
    east, north = tile.split("_")
    return int(east[1:]) * TILE_M, int(north[1:]) * TILE_M


def ownership(unit):
    """A function xyz -> mask of points in columns this unit owns, and those columns' hash."""
    import rasterio

    x0, y0 = tile_corner(unit.tile)
    with rasterio.open(PLAN / "ownership" / f"{unit.tile}.tif") as raster:
        owned = raster.read(1) == unit["rank"]
    digest = hashlib.sha256(np.packbits(owned).tobytes()).hexdigest()

    def owns(xyz):
        col = np.floor(xyz[:, 0]).astype(np.int64) - x0
        row = (y0 + TILE_M - 1) - np.floor(xyz[:, 1]).astype(np.int64)
        inside = (col >= 0) & (col < TILE_M) & (row >= 0) & (row < TILE_M)
        mask = np.zeros(len(xyz), bool)
        mask[inside] = owned[row[inside], col[inside]]
        return mask

    return owns, digest


def reference_box(unit):
    return (unit.xmin - BUFFER_M, unit.ymin - BUFFER_M, unit.xmax + BUFFER_M, unit.ymax + BUFFER_M)


def tiles_in(box):
    xmin, ymin, xmax, ymax = box
    return [f"E{ix:04d}_N{iy:04d}"
            for ix in range(int(np.floor(xmin / TILE_M)), int(np.ceil(xmax / TILE_M)))
            for iy in range(int(np.floor(ymin / TILE_M)), int(np.ceil(ymax / TILE_M)))]


def bucket_parts(campaign, tiles):
    return sorted(p for tile in tiles for p in (RETILED / campaign / tile).glob("*.laz"))


def campaign_sources(campaign):
    """Signatures of the campaign's original LAS files, in source_file order."""
    names = pd.read_csv(RETILED / campaign / "files.csv").sort_values("source_file")["name"]
    return [file_signature(Path(GLIHT) / campaign / "lidar" / "las" / name) for name in names]


def campaign_dtm(campaign):
    index = DATA / "interim" / "dtm" / "index.csv"
    if not index.is_file():
        raise FileNotFoundError(f"No DTM index at {index}; run python/campaign_dtm.py")
    rows = pd.read_csv(index).set_index("campaign")
    if campaign not in rows.index:
        raise FileNotFoundError(f"No DTM for {campaign} in {index}; run python/campaign_dtm.py")
    return rows.at[campaign, "path"]


def unit_key(unit):
    """What the plan says about a unit; a cache built for another key is stale."""
    key = {"unit": unit.unit, "tile": unit.tile, "rank": int(unit["rank"]),
           "campaign_pre": unit.campaign_pre, "campaign_post": unit.campaign_post,
           "bounds": [int(unit.xmin), int(unit.ymin), int(unit.xmax), int(unit.ymax)]}
    # Only when there is one, so uncorrected units keep their cache identity.
    if vertical_offset(unit.campaign_pre):
        raise ValueError(f"{unit.campaign_pre}: vertical offsets are only applied to 2018 campaigns")
    if vertical_offset(unit.campaign_post):
        key["post_vertical_offset_m"] = vertical_offset(unit.campaign_post)
    return key


def unit_config(unit, digest, dtm):
    return {
        "engine": "CloudComPy_exact_C2C",
        "algorithm_version": 2,
        "distance": {"direction": "pre_to_post", "local_model": "none",
                     "max_search_dist": float(MAX_SEARCH_M)},
        "unit": unit_key(unit),
        "owned_columns_sha256": digest,
        "crs_fallback": UNIT_CRS,
        "vertical_datum": VERTICAL_DATUM,
        "dtm": dtm_signatures(dtm),
        "coverage_resolution_m": COVERAGE_RESOLUTION,
        "min_pre_returns": MIN_PRE_RETURNS,
        "min_post_returns": MIN_POST_RETURNS,
        "threads": THREADS,
        "chunk_size": CHUNK_SIZE,
        "polygon_boundary": "owned_columns",
        "reference_domain": f"unit_bounds_plus_{BUFFER_M:g}m",
        "height_sampling": "containing_raster_pixel; nodata_and_outside_are_nan",
    }


def empty_arrays(directory, n_pre=0):
    for name, dtype, shape in (("xyz", np.float64, (n_pre, 3)), ("c2c", np.float64, (n_pre,)),
                               ("classification", np.uint8, (n_pre,)), ("valid", bool, (n_pre,)),
                               ("source_file", np.uint32, (n_pre,)),
                               ("source_index", np.uint64, (n_pre,)), ("hag", np.float32, (n_pre,))):
        np.save(directory / f"{name}.npy", np.zeros(shape, dtype), allow_pickle=False)


def prepare_unit(unit):
    """Build (or reuse) one unit's distance cache; returns its manifest."""
    owns, digest = ownership(unit)
    transform = np.eye(4)
    transform[2, 3] = vertical_offset(unit.campaign_post)
    box = reference_box(unit)
    pre_parts = bucket_parts(unit.campaign_pre, [unit.tile])
    post_parts = bucket_parts(unit.campaign_post, tiles_in(box))
    pre_signatures = [file_signature(p) for p in pre_parts]
    post_signatures = [file_signature(p) for p in post_parts]
    dtm = campaign_dtm(unit.campaign_pre)
    config = unit_config(unit, digest, dtm)
    cache_id = stable_id({"schema_version": SCHEMA_VERSION,
                          "preparation": semantic_preparation(config),
                          "pre_parts": pre_signatures, "post_parts": post_signatures})
    destination = UNITS / unit.unit / "cache"
    if (destination / "manifest.json").is_file():
        manifest = read_json(destination / "manifest.json")
        if manifest.get("cache_id") == cache_id:
            return manifest, "reused"
        # The plan or the buckets changed: rebuild, and drop the old cache only once
        # the new one is complete.
        stale = destination.with_name(f".stale-{manifest.get('cache_id', 'unknown')[:12]}")
        shutil.rmtree(stale, ignore_errors=True)
        destination.rename(stale)
    else:
        stale = None

    if Path(SCRATCH).is_dir():
        tempfile.tempdir = SCRATCH
    in_box = lambda xyz: ((xyz[:, 0] >= box[0]) & (xyz[:, 0] < box[2])  # noqa: E731
                          & (xyz[:, 1] >= box[1]) & (xyz[:, 1] < box[3]))
    with atomic_directory(destination) as directory:
        crs, counts = inspect_headers(pre_parts + post_parts, UNIT_CRS)
        coverage = Coverage(COVERAGE_RESOLUTION)
        n_pre = n_post = 0
        pre_min = post_min = np.full(3, np.inf)
        pre_max = post_max = np.full(3, -np.inf)
        if pre_parts:
            n_pre, pre_min, pre_max = stream_epoch(
                pre_parts, counts[: len(pre_parts)], directory, coverage, owns, CHUNK_SIZE,
                provenance=True)
        if post_parts:
            n_post, post_min, post_max = stream_epoch(
                post_parts, counts[len(pre_parts):], directory, coverage, owns, CHUNK_SIZE,
                transform=transform, keep=in_box)
        if n_pre == 0:
            # A unit with no 2017 returns in its columns (a data hole): a complete, empty
            # cache, so it is not retried forever.
            empty_arrays(directory)
            if coverage.cells:
                ledger, lowest = coverage.array(), coverage.post_lowest
            else:
                ledger, lowest = np.zeros(0, COVERAGE_DTYPE), np.zeros(0, np.float32)
            np.save(directory / "coverage.npy", ledger, allow_pickle=False)
            np.save(directory / POST_LOWEST_FILE, lowest, allow_pickle=False)
            shift = np.zeros(3)
        else:
            xyz = raw_to_npy(directory, "pre.raw", "xyz", np.float64, (n_pre, 3), CHUNK_SIZE)
            arrays = {name: raw_to_npy(directory, name + ".raw", name, dtype, (n_pre,), CHUNK_SIZE)
                      for name, dtype in (("source_file", np.uint32), ("source_index", np.uint64),
                                          ("classification", np.uint8))}
            ledger = coverage.array()
            np.save(directory / POST_LOWEST_FILE, coverage.post_lowest, allow_pickle=False)
            del coverage
            np.save(directory / "coverage.npy", ledger, allow_pickle=False)
            valid = np.lib.format.open_memmap(directory / "valid.npy", mode="w+", dtype=bool,
                                              shape=(n_pre,))
            keys = row_keys(np.column_stack((ledger["ix"], ledger["iy"])))
            for start in range(0, n_pre, CHUNK_SIZE):
                valid[start:start + CHUNK_SIZE] = common_support(
                    xyz[start:start + CHUNK_SIZE], ledger, COVERAGE_RESOLUTION,
                    MIN_PRE_RETURNS, MIN_POST_RETURNS, keys)
            valid.flush()
            hag = np.lib.format.open_memmap(directory / "hag.npy", mode="w+", dtype=np.float32,
                                            shape=(n_pre,))
            sample_hag(dtm, xyz, hag, crs, CHUNK_SIZE)
            low = np.minimum(pre_min, post_min) if n_post else pre_min
            high = np.maximum(pre_max, post_max) if n_post else pre_max
            shift = -(low / 2 + high / 2)
            if n_post:
                reference = np.memmap(directory / "post.raw", dtype=np.float64, mode="r",
                                      shape=(n_post, 3))
                exact_c2c(directory, xyz, reference, arrays["classification"], shift, THREADS,
                          CHUNK_SIZE, import_cloudcompy(), max_search=MAX_SEARCH_M)
                del reference
            else:
                # No 2018 return within reach: every point is at the cap (and none is
                # covered, so none can be a gap).
                np.save(directory / "c2c.npy", np.full(n_pre, MAX_SEARCH_M), allow_pickle=False)
            del xyz, arrays, valid, hag, keys, ledger
        for raw in ("post.raw", "pre.raw"):
            (directory / raw).unlink(missing_ok=True)
        verify_source_files(pre_signatures + post_signatures)
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "cache_id": cache_id,
            "measurement": "one_way_nearest_neighbor_separation",
            "source_files": campaign_sources(unit.campaign_pre),
            "reference_files": campaign_sources(unit.campaign_post),
            "bucket_parts": {"pre": pre_signatures, "post": post_signatures},
            "unit": config["unit"],
            "crs_wkt": crs.to_wkt(),
            "vertical_datum": VERTICAL_DATUM,
            "coordinate_system": "world_xyz_metres",
            "global_shift": np.asarray(shift).tolist(),
            "global_scale": 1.0,
            "point_count": int(n_pre),
            "reference_point_count": int(n_post),
            "preparation": config,
            "coverage": {"origin_xy": [0, 0], "resolution_m": COVERAGE_RESOLUTION,
                         "min_pre_returns": MIN_PRE_RETURNS,
                         "min_post_returns": MIN_POST_RETURNS},
            "registration": {"post_transform": transform.tolist(),
                             "assessment": ("vertical_offset_table" if transform[2, 3]
                                            else "not_assessed")},
            "height_above_ground_available": True,
            "post_lowest_return": post_lowest_description(),
        }
        write_json(directory / "manifest.json", manifest)
    if stale is not None:
        shutil.rmtree(stale, ignore_errors=True)
    load_cache(destination)  # the new cache must read back with the standard checks
    return manifest, "built"


def run(job=None, unit_id=None):
    """Every unit of a job (or one unit), one after another; failures don't stop the rest."""
    units = load_units()
    selected = units[units.job == int(job)] if job is not None else units[units.unit == unit_id]
    if selected.empty:
        raise SystemExit(f"No unit {'in job ' + str(job) if job is not None else unit_id} "
                         f"in {PLAN / 'work_units.csv'}")
    failed = []
    for unit in selected.itertuples(index=False):
        unit = pd.Series(unit._asdict())
        stamp(f"unit {unit.unit}: {unit.campaign_pre} -> {unit.campaign_post}, "
              f"{unit.area_ha:.1f} ha")
        try:
            manifest, how = prepare_unit(unit)
            stamp(f"unit {unit.unit}: {how} cache {manifest['cache_id'][:12]}, "
                  f"{manifest['point_count']:,} 2017 points")
        except Exception:  # log it, carry on with the job's other units
            failed.append(unit.unit)
            traceback.print_exc()
            stamp(f"unit {unit.unit}: FAILED")
    stamp(f"{len(selected) - len(failed)} of {len(selected)} units done"
          + (f"; failed: {', '.join(failed)}" if failed else ""))
    return 1 if failed else 0


def unit_done(unit):
    """For status.py: a complete cache built for this plan row (pair, rank, bounds).

    Cheaper than recomputing the cache identity; a change in the unit's columns alone
    (same bounds) is caught when the job runs, which rebuilds the cache.
    """
    manifest_path = UNITS / unit.unit / "cache" / "manifest.json"
    if not manifest_path.is_file():
        return False
    built = read_json(manifest_path).get("unit", {})
    return built == unit_key(unit)


def job_done(job, units=None):
    units = load_units() if units is None else units
    return all(unit_done(pd.Series(row._asdict()))
               for row in units[units.job == int(job)].itertuples(index=False))


if __name__ == "__main__":
    sys.exit("Run units through canopy.py: canopy.py --job N or canopy.py --unit ID")

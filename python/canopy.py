"""Canopy gap pipeline: 2017 -> 2018 G-LiHT cloud-to-cloud change, grouped into 3D gaps.

Edit the settings below, then on the server:
    source ~/cloudcompy_env.sh
    export PR_GAPS_GLIHT=/ibstorage/shared/PR_NASA_GLiHT   # omit to use $PR_GAPS_DATA/raw/gliht
    python python/canopy.py

Step 1 computes the distances and saves them to CACHE; if CACHE already holds the
same inputs and settings it is reused instead. Step 2 finds gaps and writes
$PR_GAPS_DATA/runs/canopy/<site>/gaps/<run-id>/threshold_<t>m/:
  gaps.laz      gap points; every point carries its gap's id, volume and area
  gaps.gpkg     'footprints' (outline per gap) and 'bboxes' layers, same attributes
  gaps.csv      one row per gap
  voxels.parquet, point_labels.npy, metadata.json   internals for reuse

gap_volume_m3 is the exact convex hull of the gap's voxel cubes: an upper envelope
that fills hollows. voxel_volume_m3 counts occupied voxels. Distances describe
return separation; neither volume is confirmed empty space or biomass.
"""

from __future__ import annotations

from contextlib import ExitStack, contextmanager
import csv
from datetime import datetime
import gzip
import hashlib
import importlib
from itertools import product
import json
import math
import os
from pathlib import Path
import shutil
import tempfile
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import warnings

import numpy as np
from scipy.spatial import ConvexHull, QhullError


# ---------------------------------------------------------------- settings
# Paths follow the repository convention (README, plan Appendix A): code here,
# data under $PR_GAPS_DATA, which defaults to the data/ sibling of this repo.

REPO = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("PR_GAPS_DATA") or REPO.parent / "data")
# Campaign directories laid out as on the G-LiHT server: <campaign>/lidar/las/...
# On the server, point this at the shared copy: /ibstorage/shared/PR_NASA_GLiHT
GLIHT = os.environ.get("PR_GAPS_GLIHT") or str(DATA / "raw" / "gliht")

# Luquillo plot + 50 m buffer on EV1, 5 Mar 2017 -> 25 Apr 2018. The plot falls in
# tiles c4r2 and c5r2 of both flights (derived/inventory/pr_footprints.gpkg, 'tiles').
SITE = "lfdp"
PRE = [
    f"{GLIHT}/PR_5March2017_EV1/lidar/las/PR_5March2017_EV1_c4r2.las.gz",
    f"{GLIHT}/PR_5March2017_EV1/lidar/las/PR_5March2017_EV1_c5r2.las.gz",
]
POST = [
    f"{GLIHT}/PR_25April2018_EV1/lidar/las/PR_25April2018_EV1_c4r2.las.gz",
    f"{GLIHT}/PR_25April2018_EV1/lidar/las/PR_25April2018_EV1_c5r2.las.gz",
]
STUDY_AREA = REPO / "sites" / "lfdp" / "lfdp_buf50.gpkg"  # None = whole tiles
# None = no heights above ground. Unpacked from PR_5March2017_EV1_DTM.tif.gz by the
# download step; override with PR_GAPS_DTM (server copy: /workdir/ogh6/ev1/...).
DTM = os.environ.get("PR_GAPS_DTM") or (
    f"{GLIHT}/PR_5March2017_EV1/lidar/geotiff/PR_5March2017_EV1_DTM.tif"
)
THRESHOLDS = [2, 5]

# FIA12, 23-tile flight line, 11 Mar 2017 -> 2 May 2018:
# SITE = "fia12"
# PRE = [f"{GLIHT}/PR_11March2017_FIA12/lidar/las"]
# POST = [f"{GLIHT}/PR_2May018_FIA12/lidar/las"]
# STUDY_AREA = None
# DTM = None
# THRESHOLDS = [5]

CACHE = DATA / "runs" / "canopy" / SITE / "cache"
# .laz.gz tiles expand here, not on the shared root disk; used only if it exists.
SCRATCH = os.environ.get("PR_GAPS_SCRATCH") or "/workdir/ogh6/tmp"

# Step 1: distances. Changing any of these (except THREADS/CHUNK_SIZE) needs a new CACHE.
TILE_FILTER = []  # filename substrings; empty = every tile
CRS = None  # only used when a LAS header has no CRS
VERTICAL_DATUM = "unknown"
POST_TRANSFORM = None  # JSON 4x4 rigid matrix applied to 2018 points
COVERAGE_RESOLUTION = 1.0  # m, size of the both-flights coverage columns
MIN_PRE_RETURNS = 1
MIN_POST_RETURNS = 1
THREADS = 16
CHUNK_SIZE = 1_000_000

# Step 2: gaps
VOXEL_SIZE = 1.0
GRID_ORIGIN = (0.0, 0.0, 0.0)
CONNECTIVITY = 26  # 26 = faces, edges and corners touch; 6 = faces only
MIN_POINTS = 10
MIN_VOLUME = 0.0  # m3 of occupied voxels
MIN_VOXEL_POINTS = 1
EXCLUDE_CLASSES = [2, 7, 18]  # ground, low noise, high noise
MIN_HEIGHT = None  # m above ground; needs a DTM
OUTPUT = None  # None = runs/<site>/gaps/<run-id>


# ---------------------------------------------------------------- shared cache contract

SCHEMA_VERSION = 1
COVERAGE_DTYPE = np.dtype(
    [("ix", "<i8"), ("iy", "<i8"), ("pre_count", "<u8"), ("post_count", "<u8")]
)
_LAS_SUFFIXES = (".las", ".laz", ".las.gz", ".laz.gz")


def read_json(path):
    with Path(path).open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def write_json(path, value):
    path = Path(path)
    with tempfile.TemporaryDirectory(prefix=".json-", dir=path.parent) as folder:
        temporary = Path(folder) / path.name
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
        os.replace(temporary, path)


def stable_id(value):
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def file_signature(path):
    source = Path(path).expanduser().resolve(strict=True)
    if not source.is_file():
        raise ValueError(f"Expected a source file: {source}")
    stat = source.stat()
    return {"path": str(source), "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def verify_source_files(signatures):
    """Check immutable source provenance before reading original point records."""
    for recorded in signatures:
        current = file_signature(recorded["path"])
        if any(current[key] != recorded[key] for key in ("path", "size", "mtime_ns")):
            raise ValueError(
                f"Source changed since preparation: {recorded['path']}. "
                "Prepare a new cache; old source point indexes must not be reused."
            )


@contextmanager
def atomic_directory(destination):
    """Publish only complete stage results; never overwrite an existing run."""
    destination = Path(destination).expanduser().resolve()
    if destination.exists():
        raise FileExistsError(f"Output already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{destination.name}-", dir=destination.parent)
    )
    try:
        yield temporary
        if destination.exists():
            raise FileExistsError(f"Output appeared while processing: {destination}")
        os.rename(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


@contextmanager
def materialized_las(path):
    """Expose gzip-wrapped LAS/LAZ without basename collisions or leaked files."""
    source = Path(path).expanduser().resolve(strict=True)
    if not source.name.lower().endswith(".gz"):
        yield source
        return
    if not source.name.lower().endswith((".las.gz", ".laz.gz")):
        raise ValueError(f"Unsupported compressed point-cloud format: {source}")
    if source.name.lower().endswith(".las.gz"):
        # Uncompressed LAS reads sequentially, so stream it with no scratch copy.
        with gzip.open(source, "rb") as stream:
            yield stream
        return
    # LAZ chunk tables need random access; expand into scratch space.
    with tempfile.TemporaryDirectory(prefix="canopy-las-") as folder:
        uncompressed = Path(folder) / source.name[:-3]
        with gzip.open(source, "rb") as incoming, uncompressed.open("wb") as outgoing:
            shutil.copyfileobj(incoming, outgoing)
        yield uncompressed


def resolve_las_files(paths, tile_filter=()):
    matches = set()
    for value in paths:
        candidate = Path(value).expanduser().resolve(strict=True)
        if candidate.is_dir():
            entries = candidate.iterdir()
        elif candidate.is_file():
            if not candidate.name.lower().endswith(_LAS_SUFFIXES):
                raise ValueError(
                    f"Expected LAS/LAZ or gzip-wrapped LAS/LAZ: {candidate}"
                )
            entries = (candidate,)
        else:
            raise ValueError(f"Not a file or directory: {candidate}")
        for entry in entries:
            if not entry.is_file() or not entry.name.lower().endswith(_LAS_SUFFIXES):
                continue
            if tile_filter and not any(token in entry.name for token in tile_filter):
                continue
            matches.add(entry.resolve())
    if not matches:
        raise ValueError(
            "No LAS/LAZ input files matched the supplied paths and tile filter"
        )
    return sorted(matches)


def threshold_directory_name(threshold):
    value = float(threshold)
    if not math.isfinite(value) or value < 0:
        raise ValueError("Threshold must be finite and nonnegative")
    # str(float) round-trips without the collisions introduced by a short :g format.
    if value == 0:
        value = 0.0
    return f"threshold_{value}m"


def row_keys(array):
    """A lexicographically ordered structured view for vectorized row lookup."""
    values = np.ascontiguousarray(array, dtype=np.int64)
    if values.ndim != 2 or values.shape[1] == 0:
        raise ValueError("row_keys requires an (N, D) array with D > 0")
    dtype = np.dtype([(f"f{index}", values.dtype) for index in range(values.shape[1])])
    return values.view(dtype).reshape(-1)


def write_parquet(path, columns, schema=None):
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pa.table(columns, schema=schema)
    pq.write_table(table, path, compression="zstd")


def write_csv(path, rows, fieldnames):
    with Path(path).open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames, extrasaction="raise")
        writer.writeheader()
        writer.writerows(rows)


def load_cache(path, *, provenance=True):
    """Read validated array headers and memory-map data, without copying the cloud.

    Analyses only need point arrays; provenance and coverage remain available for
    source reconstruction and complete preparation-cache validation.
    """
    root = Path(path).expanduser().resolve(strict=True)
    manifest = read_json(root / "manifest.json")
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"Unsupported cache schema: {manifest.get('schema_version')}")
    cache_id = manifest.get("cache_id")
    if not isinstance(cache_id, str) or not cache_id:
        raise ValueError("Cache manifest is missing cache_id")
    if manifest.get("coordinate_system") != "world_xyz_metres":
        raise ValueError("Cache coordinates must be world XYZ in metres")
    count = manifest.get("point_count")
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        raise ValueError("Invalid cache point_count")
    coverage = manifest.get("coverage", {})
    resolution = coverage.get("resolution_m", 0)
    if (
        not isinstance(resolution, (int, float))
        or not math.isfinite(resolution)
        or resolution <= 0
    ):
        raise ValueError("Invalid cache coverage resolution")
    origin = np.asarray(coverage.get("origin_xy", []), dtype=np.float64)
    if origin.shape != (2,) or not np.isfinite(origin).all():
        raise ValueError("Invalid cache coverage origin")
    for key in ("min_pre_returns", "min_post_returns"):
        value = coverage.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            raise ValueError(f"Invalid cache coverage {key}")
    if not isinstance(manifest.get("source_files"), list):
        raise ValueError("Cache is missing original source file provenance")

    specs = {
        "xyz": ((count, 3), np.dtype("float64")),
        "c2c": ((count,), np.dtype("float64")),
        "classification": ((count,), np.dtype("uint8")),
        "valid": ((count,), np.dtype("bool")),
    }
    if provenance:
        specs.update({
            "source_file": ((count,), np.dtype("uint32")),
            "source_index": ((count,), np.dtype("uint64")),
        })
    if manifest.get("height_above_ground_available", False):
        specs["hag"] = ((count,), np.dtype("float32"))
    arrays = {}
    for name, (shape, dtype) in specs.items():
        array = np.load(root / f"{name}.npy", mmap_mode="r", allow_pickle=False)
        if array.shape != shape or array.dtype != dtype:
            raise ValueError(
                f"Invalid {name}.npy: expected {shape}/{dtype}, "
                f"found {array.shape}/{array.dtype}"
            )
        arrays[name] = array
    if provenance:
        cells = np.load(root / "coverage.npy", mmap_mode="r", allow_pickle=False)
        if cells.ndim != 1 or cells.dtype != COVERAGE_DTYPE:
            raise ValueError("Invalid sparse coverage.npy schema")
        arrays["coverage"] = cells
    return manifest, arrays


# ---------------------------------------------------------------- step 1: prepare distances

RAW_SCALAR_NAME = "c2c_raw_m"


def rigid_transform(path=None):
    """Read a proper rigid world-space transform (rotation plus translation)."""
    if path is None:
        matrix = np.eye(4)
    else:
        with Path(path).open(encoding="utf-8") as stream:
            matrix = np.asarray(json.load(stream), dtype=np.float64)
    if matrix.shape != (4, 4) or not np.isfinite(matrix).all():
        raise ValueError("--post-transform must contain a finite 4x4 JSON matrix")
    rotation = matrix[:3, :3]
    if (
        not np.allclose(matrix[3], [0, 0, 0, 1], rtol=0, atol=1e-10)
        or not np.allclose(rotation.T @ rotation, np.eye(3), rtol=0, atol=1e-8)
        or not np.isclose(np.linalg.det(rotation), 1, rtol=0, atol=1e-8)
    ):
        raise ValueError(
            "--post-transform must be rigid: proper rotation, translation, no scale/shear"
        )
    return matrix


def metric_crs(value, label="CRS"):
    from pyproj import CRS

    try:
        crs = CRS.from_user_input(value)
    except Exception as exc:
        raise ValueError(f"Invalid {label}: {value}") from exc
    if not crs.is_projected or len(crs.axis_info) < 2:
        raise ValueError(
            f"{label} must be projected with metre axes, not geographic coordinates"
        )
    if any(
        not np.isclose(axis.unit_conversion_factor, 1.0, rtol=0, atol=1e-12)
        for axis in crs.axis_info
    ):
        raise ValueError(f"{label} must use metres on every declared spatial axis")
    return crs


def inspect_headers(paths, fallback=None):
    """Require matching metric CRS; fallback applies only to missing headers."""
    import laspy

    expected = metric_crs(fallback, "--crs") if fallback else None
    counts = []
    for path in paths:
        opener = gzip.open if str(path).lower().endswith(".gz") else open
        with opener(path, "rb") as stream, laspy.open(stream) as reader:
            header = reader.header
            try:
                declared = header.parse_crs()
            except Exception as exc:
                raise ValueError(f"Cannot parse LAS CRS in {path}") from exc
            if declared is None:
                if fallback is None:
                    raise ValueError(
                        f"Missing LAS CRS in {path}; supply --crs explicitly"
                    )
                declared = metric_crs(fallback, "--crs")
            declared = metric_crs(declared, f"LAS CRS in {path}")
            if expected is None:
                expected = declared
            elif not expected.equals(declared):
                raise ValueError(
                    f"Conflicting LAS CRS in {path}; reproject epochs before preparation"
                )
            if (
                not np.isfinite(header.scales).all()
                or np.any(header.scales <= 0)
                or not np.isfinite(header.offsets).all()
            ):
                raise ValueError(f"Invalid LAS coordinate scales/offsets in {path}")
            counts.append(int(header.point_count))
    return expected, counts


def auxiliary_signatures(path):
    """Include shapefile companions and raster sidecars, not just the main file."""
    if path is None:
        return []
    path = Path(path).resolve()
    files = {path}
    if path.suffix.lower() == ".shp":
        suffixes = {".shp", ".shx", ".dbf", ".prj", ".cpg", ".qix", ".sbn", ".sbx"}
        files.update(
            p
            for p in path.parent.iterdir()
            if p.stem.lower() == path.stem.lower() and p.suffix.lower() in suffixes
        )
    else:
        files.update(p for p in path.parent.glob(path.name + ".*") if p.is_file())
    return [file_signature(p) for p in sorted(files)]


def dtm_signatures(path):
    """Track local raster data, georeferencing, masks, and GDAL dependencies."""
    if path is None:
        return []
    import rasterio

    path = Path(path).resolve(strict=True)
    files, pending = {path}, [path]
    sidecars = {".tfw", ".tifw", ".tiffw", ".tfwx", ".tifwx", ".wld", ".tab", ".prj"}
    while pending:
        current = pending.pop()
        try:
            with rasterio.open(current) as raster:
                dependencies = {Path(p).resolve(strict=True) for p in raster.files}
        except rasterio.errors.RasterioIOError:
            if current == path:
                raise
            # GDAL lists non-raster sidecars alongside dependent rasters.
            continue
        pending.extend(dependencies - files)
        files.update(dependencies)
        files.update(Path(s["path"]) for s in auxiliary_signatures(current))
        files.update(
            p for p in current.parent.iterdir()
            if p.stem.lower() == current.stem.lower()
            and p.suffix.lower() in sidecars and p.is_file()
        )
    return [file_signature(p) for p in sorted(files)]


def semantic_preparation(config):
    """Execution settings and selectors do not change already-resolved inputs."""
    ignored = {"threads", "chunk_size", "pre_paths", "post_paths", "tile_filter"}
    return {key: value for key, value in config.items() if key not in ignored}


def preparation_identity(args, sources, references, transform):
    config = {
        "engine": "CloudComPy_exact_C2C",
        "algorithm_version": 2,
        "distance": {
            "direction": "pre_to_post",
            "local_model": "none",
            "max_search_dist": 0,
        },
        "pre_paths": sorted(str(Path(p).resolve()) for p in args.pre),
        "post_paths": sorted(str(Path(p).resolve()) for p in args.post),
        "tile_filter": list(args.tile_filter),
        "crs_fallback": args.crs,
        "vertical_datum": args.vertical_datum,
        "study_area": auxiliary_signatures(args.study_area),
        "post_transform_file": auxiliary_signatures(args.post_transform),
        "post_transform": transform.tolist(),
        "dtm": dtm_signatures(args.dtm),
        "coverage_resolution_m": args.coverage_resolution,
        "min_pre_returns": args.min_pre_returns,
        "min_post_returns": args.min_post_returns,
        "threads": args.threads,
        "chunk_size": args.chunk_size,
        "polygon_boundary": "included",
        "reference_domain": "full_selected_tiles",
        "height_sampling": "containing_raster_pixel; nodata_and_outside_are_nan",
    }
    identity = {
        "schema_version": SCHEMA_VERSION,
        "preparation": semantic_preparation(config),
        "source_files": sources,
        "reference_files": references,
    }
    return stable_id(identity), config


def load_domain(path, crs):
    if path is None:
        return None
    import geopandas as gpd
    from shapely.ops import unary_union

    frame = gpd.read_file(path)
    if frame.crs is None:
        raise ValueError(
            "Study-area polygon must have a CRS; --crs is only a LAS fallback"
        )
    if frame.empty or frame.geometry.isna().any() or frame.geometry.is_empty.any():
        raise ValueError("Study area must contain nonempty polygon geometry")
    if not frame.geometry.geom_type.isin(["Polygon", "MultiPolygon"]).all():
        raise ValueError(
            "Study area must contain only Polygon or MultiPolygon geometry"
        )
    if not frame.geometry.is_valid.all():
        raise ValueError(
            "Study area contains invalid polygon geometry; repair it before preparation"
        )
    frame = frame.to_crs(crs)
    polygon = unary_union(frame.geometry)
    if (
        polygon.is_empty
        or not polygon.is_valid
        or not np.isfinite(polygon.bounds).all()
    ):
        raise ValueError(
            "Study area cannot be transformed to a finite valid polygon in the LAS CRS"
        )
    return polygon


def in_domain(xyz, polygon):
    if polygon is None:
        return np.ones(len(xyz), dtype=bool)
    import shapely

    # intersects includes boundary points and excludes hole interiors.
    return shapely.intersects_xy(polygon, xyz[:, 0], xyz[:, 1])


def xy_cells(xyz, resolution):
    cells = np.floor(xyz[:, :2] / resolution)
    if (
        not np.isfinite(cells).all()
        or np.any(cells < -(2.0**63))
        or np.any(cells >= 2.0**63)
    ):
        raise ValueError(
            "XY coverage indices exceed int64; increase --coverage-resolution"
        )
    return cells.astype(np.int64)


class Coverage:
    """Sparse union of observed cells; never turn epoch bounds into coverage."""

    def __init__(self, resolution):
        self.resolution = resolution
        self.cells, self.counts = [], []

    def add(self, xyz, epoch):
        # Per-chunk partial counts; merged once in array().
        cells, counts = np.unique(
            xy_cells(xyz, self.resolution), axis=0, return_counts=True
        )
        pair = np.zeros((len(cells), 2), dtype=np.uint64)
        pair[:, epoch] = counts
        self.cells.append(cells.reshape(-1, 2))
        self.counts.append(pair)

    def array(self):
        keys, inverse = np.unique(
            row_keys(np.concatenate(self.cells)), return_inverse=True
        )
        counts = np.concatenate(self.counts)
        output = np.empty(len(keys), dtype=COVERAGE_DTYPE)
        output["ix"], output["iy"] = keys.view(np.int64).reshape(-1, 2).T
        for column, name in enumerate(("pre_count", "post_count")):
            # float64 weights are exact for counts below 2**53.
            output[name] = np.bincount(
                inverse.reshape(-1), weights=counts[:, column], minlength=len(keys)
            )
        return output


def common_support(xyz, coverage, resolution, min_pre, min_post, keys=None):
    if keys is None:
        keys = row_keys(np.column_stack((coverage["ix"], coverage["iy"])))
    point_keys = row_keys(xy_cells(xyz, resolution))
    positions = np.searchsorted(keys, point_keys)
    found = positions < len(keys)
    rows = np.flatnonzero(found)
    found[rows] = keys[positions[rows]] == point_keys[rows]
    rows = np.flatnonzero(found)
    found[rows] &= (coverage["pre_count"][positions[rows]] >= min_pre) & (
        coverage["post_count"][positions[rows]] >= min_post
    )
    return found


def stream_epoch(
    paths,
    counts,
    destination,
    coverage,
    polygon,
    chunk_size,
    transform=None,
    provenance=False,
):
    import laspy

    total = 0
    minimum, maximum = np.full(3, np.inf), np.full(3, -np.inf)
    with ExitStack() as stack:
        output = stack.enter_context(
            open(destination / ("pre.raw" if provenance else "post.raw"), "wb")
        )
        mapping = {}
        if provenance:
            for name in ("source_file", "source_index", "classification"):
                mapping[name] = stack.enter_context(
                    open(destination / (name + ".raw"), "wb")
                )
        for file_number, (path, expected_count) in enumerate(zip(paths, counts)):
            offset = 0
            with materialized_las(path) as local_path, laspy.open(local_path) as reader:
                for points in reader.chunk_iterator(chunk_size):
                    xyz = np.column_stack((points.x, points.y, points.z)).astype(
                        np.float64, copy=False
                    )
                    if not np.isfinite(xyz).all():
                        raise ValueError(
                            f"Nonfinite point geometry in {path} at record {offset}"
                        )
                    if transform is not None:
                        xyz = xyz @ transform[:3, :3].T + transform[:3, 3]
                        if not np.isfinite(xyz).all():
                            raise ValueError(
                                f"Post transform produced nonfinite geometry in {path}"
                            )
                    mask = in_domain(xyz, polygon)
                    coverage.add(xyz[mask], 0 if provenance else 1)
                    if provenance:
                        selected = np.flatnonzero(mask)
                        xyz = xyz[mask]
                        np.full(len(selected), file_number, dtype=np.uint32).tofile(
                            mapping["source_file"]
                        )
                        (selected.astype(np.uint64) + offset).tofile(
                            mapping["source_index"]
                        )
                        np.asarray(points.classification, dtype=np.uint8)[mask].tofile(
                            mapping["classification"]
                        )
                    # Reference retains every selected tile point, outside-domain neighbors included.
                    xyz.tofile(output)
                    if len(xyz):
                        minimum = np.minimum(minimum, xyz.min(axis=0))
                        maximum = np.maximum(maximum, xyz.max(axis=0))
                    total += len(xyz)
                    offset += len(points)
            if offset != expected_count:
                raise ValueError(
                    f"LAS point count disagrees with header in {path}: {offset} != {expected_count}"
                )
    return total, minimum, maximum


def raw_to_npy(directory, raw_name, name, dtype, shape, chunk_size):
    source = np.memmap(directory / raw_name, dtype=dtype, mode="r", shape=shape)
    result = np.lib.format.open_memmap(
        directory / (name + ".npy"), mode="w+", dtype=dtype, shape=shape
    )
    for start in range(0, shape[0], chunk_size):
        result[start : start + chunk_size] = source[start : start + chunk_size]
    result.flush()
    del source
    (directory / raw_name).unlink()
    return result


def sample_hag(path, xyz, output, crs, chunk_size):
    import rasterio
    from pyproj import CRS, Transformer

    with rasterio.open(path) as raster:
        if raster.crs is None:
            raise ValueError("DTM must have an explicit CRS")
        if raster.count < 1:
            raise ValueError("DTM has no elevation band")
        if raster.units and raster.units[0] not in (
            None,
            "",
            "m",
            "metre",
            "meter",
            "metres",
            "meters",
        ):
            raise ValueError("DTM elevation band must be expressed in metres")
        raster_crs = CRS.from_user_input(raster.crs)
        if any(
            axis.direction in ("up", "down")
            and not np.isclose(axis.unit_conversion_factor, 1)
            for axis in raster_crs.axis_info
        ):
            raise ValueError("DTM vertical CRS axis must use metres")
        transformer = (
            None
            if crs.equals(raster_crs)
            else Transformer.from_crs(crs, raster_crs, always_xy=True)
        )
        scale, offset = raster.scales[0], raster.offsets[0]
        if not np.isfinite([scale, offset]).all():
            raise ValueError("DTM elevation scale/offset must be finite")
        inverse_transform = ~raster.transform
        # ponytail: whole band in RAM; read a window per chunk if a DTM outgrows memory.
        band = raster.read(1, masked=True)
        for start in range(0, len(xyz), chunk_size):
            points = xyz[start : start + chunk_size]
            x, y = points[:, 0], points[:, 1]
            if transformer is not None:
                x, y = transformer.transform(x, y, errcheck=True)
            x, y = np.asarray(x), np.asarray(y)
            columns = (
                inverse_transform.a * x + inverse_transform.b * y + inverse_transform.c
            )
            rows = (
                inverse_transform.d * x + inverse_transform.e * y + inverse_transform.f
            )
            inside = (
                np.isfinite(columns)
                & np.isfinite(rows)
                & (columns >= 0)
                & (columns < raster.width)
                & (rows >= 0)
                & (rows < raster.height)
            )
            # Explicit pixel bounds also handle rotated geotransforms.
            elevations = np.full(len(points), np.nan, dtype=np.float64)
            values = band[rows[inside].astype(np.int64), columns[inside].astype(np.int64)]
            elevations[inside] = np.ma.filled(values.astype(np.float64), np.nan)
            elevations *= scale
            elevations += offset
            heights = points[:, 2] - elevations
            heights[
                ~np.isfinite(heights) | (np.abs(heights) > np.finfo(np.float32).max)
            ] = np.nan
            output[start : start + len(points)] = heights
    output.flush()


def import_cloudcompy():
    try:
        cc = importlib.import_module("cloudComPy")
    except (ImportError, OSError) as exc:
        raise RuntimeError(
            "Exact C2C requires CloudComPy and its native libraries. Activate a supported "
            "CloudComPy environment (including its platform runtime setup); no fallback "
            "distance engine is used."
        ) from exc
    cc.initCC()
    return cc


def native_cloud(cc, name, xyz, shift, chunk_size):
    if len(xyz) > np.iinfo(np.uint32).max:
        raise ValueError(
            "CloudComPy clouds are limited to uint32 point counts; split this study explicitly"
        )
    cloud = cc.ccPointCloud(name)
    try:
        if not cloud.resize(len(xyz)) or cloud.size() != len(xyz):
            raise RuntimeError(
                f"CloudComPy could not allocate {name} ({len(xyz)} points)"
            )
        coordinates = cloud.toNpArray()
        for start in range(0, len(xyz), chunk_size):
            local = xyz[start : start + chunk_size] + shift
            if np.any(np.abs(local) > np.finfo(coordinates.dtype).max):
                raise ValueError(
                    "Shifted coordinates exceed CloudComPy coordinate precision range"
                )
            coordinates[start : start + len(local)] = local
        del coordinates
        cloud.setGlobalShift(*(float(v) for v in shift))
        cloud.setGlobalScale(1.0)
        return cloud
    except BaseException:
        cc.deleteEntity(cloud)
        raise


def exact_c2c(directory, xyz, reference, classification, shift, threads, chunk_size, cc):
    pre = post = None
    try:
        pre = native_cloud(cc, "pre_c2c", xyz, shift, chunk_size)
        post = native_cloud(cc, "post_reference", reference, shift, chunk_size)
        index = pre.addScalarField("Classification")
        if index < 0:
            raise RuntimeError(
                "CloudComPy could not allocate Classification scalar field"
            )
        field = pre.getScalarField(index)
        field.fromNpArrayCopy(np.asarray(classification, dtype=np.float32))
        field.computeMinAndMax()
        params = cc.Cloud2CloudDistancesComputationParams()
        params.maxSearchDist = 0.0
        params.octreeLevel = 0
        params.multiThread = threads > 1
        params.maxThreadCount = threads
        params.resetFormerDistances = True
        # The native default is NO_MODEL: exact nearest-point, not fitted-surface distance.
        status = cc.DistanceComputationTools.computeCloud2CloudDistances(
            pre, post, params
        )
        if status != 1:
            raise RuntimeError(f"CloudComPy exact C2C failed with code {status}")
        index = pre.getScalarFieldDic().get("C2C absolute distances", -1)
        if index < 0:
            raise RuntimeError(
                "CloudComPy returned success without the named raw C2C scalar field"
            )
        pre.renameScalarField(index, RAW_SCALAR_NAME)
        field = pre.getScalarField(index)
        # Owned-copy API is shared by older and current CloudComPy releases;
        # current releases include scalar offsets in this copy.
        values = field.toNpArrayCopy()
        distances = np.lib.format.open_memmap(
            directory / "c2c.npy", mode="w+", dtype=np.float64, shape=(len(xyz),)
        )
        if values.shape != distances.shape:
            raise RuntimeError(
                "CloudComPy C2C scalar length does not match source point ordering"
            )
        for start in range(0, len(xyz), chunk_size):
            distances[start : start + chunk_size] = values[start : start + chunk_size]
        del values
        distances.flush()
        pre.setCurrentDisplayedScalarField(index)
        binary = directory / "source_c2c.bin"
        temporary_binary = directory / ".source_c2c.bin"
        try:
            status = cc.SavePointCloud(pre, str(temporary_binary))
            if status != cc.CC_FILE_ERROR.CC_FERR_NO_ERROR:
                raise RuntimeError(f"CloudComPy BIN export returned {status}")
            if not temporary_binary.is_file() or temporary_binary.stat().st_size == 0:
                raise RuntimeError("CloudComPy produced no nonempty BIN file")
            temporary_binary.replace(binary)
        except Exception as exc:
            temporary_binary.unlink(missing_ok=True)
            warnings.warn(
                f"Optional source_c2c.bin export failed; numerical cache retained: {exc}",
                RuntimeWarning,
            )
    finally:
        if post is not None:
            cc.deleteEntity(post)
        if pre is not None:
            cc.deleteEntity(pre)


def prepare(args):
    if not np.isfinite(args.coverage_resolution) or args.coverage_resolution <= 0:
        raise ValueError("--coverage-resolution must be finite and positive")
    for name in ("min_pre_returns", "min_post_returns", "threads", "chunk_size"):
        if getattr(args, name) < 1:
            raise ValueError(f"--{name.replace('_', '-')} must be positive")
    if not args.vertical_datum.strip():
        raise ValueError(
            "--vertical-datum must name a datum or explicitly be 'unknown'"
        )
    pre_files = resolve_las_files(args.pre, args.tile_filter)
    post_files = resolve_las_files(args.post, args.tile_filter)
    if len(pre_files) > np.iinfo(np.uint32).max:
        raise ValueError("Too many source files for uint32 provenance")
    sources = [file_signature(p) for p in pre_files]
    references = [file_signature(p) for p in post_files]
    transform = rigid_transform(args.post_transform)
    cache_id, config = preparation_identity(args, sources, references, transform)
    destination = Path(args.cache).resolve()
    if destination.exists():
        manifest, _ = load_cache(destination)
        if (
            semantic_preparation(manifest.get("preparation", {}))
            != semantic_preparation(config)
            or manifest.get("source_files") != sources
            or manifest.get("reference_files") != references
        ):
            raise ValueError(
                f"Existing cache {destination} has incompatible inputs/configuration; choose a new --cache"
            )
        return manifest

    cc = import_cloudcompy()
    with atomic_directory(destination) as directory:
        crs, counts = inspect_headers(pre_files + post_files, args.crs)
        polygon = load_domain(args.study_area, crs)
        coverage = Coverage(args.coverage_resolution)
        n_pre, pre_min, pre_max = stream_epoch(
            pre_files,
            counts[: len(pre_files)],
            directory,
            coverage,
            polygon,
            args.chunk_size,
            provenance=True,
        )
        n_post, post_min, post_max = stream_epoch(
            post_files,
            counts[len(pre_files) :],
            directory,
            coverage,
            polygon,
            args.chunk_size,
            transform=transform,
        )
        if n_pre == 0:
            raise ValueError(
                "No pre points remain in the study domain; cannot compute native C2C"
            )
        if n_post == 0:
            raise ValueError(
                "Selected post tiles contain no reference points; cannot compute native C2C"
            )
        xyz = raw_to_npy(
            directory, "pre.raw", "xyz", np.float64, (n_pre, 3), args.chunk_size
        )
        arrays = {}
        for name, dtype in (
            ("source_file", np.uint32),
            ("source_index", np.uint64),
            ("classification", np.uint8),
        ):
            arrays[name] = raw_to_npy(
                directory, name + ".raw", name, dtype, (n_pre,), args.chunk_size
            )
        ledger = coverage.array()
        del coverage
        np.save(directory / "coverage.npy", ledger, allow_pickle=False)
        valid = np.lib.format.open_memmap(
            directory / "valid.npy", mode="w+", dtype=bool, shape=(n_pre,)
        )
        coverage_keys = row_keys(np.column_stack((ledger["ix"], ledger["iy"])))
        for start in range(0, n_pre, args.chunk_size):
            valid[start : start + args.chunk_size] = common_support(
                xyz[start : start + args.chunk_size],
                ledger,
                args.coverage_resolution,
                args.min_pre_returns,
                args.min_post_returns,
                coverage_keys,
            )
        valid.flush()
        del coverage_keys, ledger
        if args.dtm:
            hag = np.lib.format.open_memmap(
                directory / "hag.npy", mode="w+", dtype=np.float32, shape=(n_pre,)
            )
            sample_hag(args.dtm, xyz, hag, crs, args.chunk_size)
        # Center both epochs in one local frame before casting into native coordinate precision.
        shift = -(np.minimum(pre_min, post_min) / 2 + np.maximum(pre_max, post_max) / 2)
        reference = np.memmap(
            directory / "post.raw", dtype=np.float64, mode="r", shape=(n_post, 3)
        )
        exact_c2c(
            directory,
            xyz,
            reference,
            arrays["classification"],
            shift,
            args.threads,
            args.chunk_size,
            cc,
        )
        del reference
        (directory / "post.raw").unlink()
        verify_source_files(sources + references)
        for key in ("study_area", "post_transform_file", "dtm"):
            verify_source_files(config[key])
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "cache_id": cache_id,
            "measurement": "one_way_nearest_neighbor_separation",
            "source_files": sources,
            "reference_files": references,
            "crs_wkt": crs.to_wkt(),
            "vertical_datum": args.vertical_datum,
            "coordinate_system": "world_xyz_metres",
            "global_shift": shift.tolist(),
            "global_scale": 1.0,
            "point_count": n_pre,
            "preparation": config,
            "coverage": {
                "origin_xy": [0, 0],
                "resolution_m": args.coverage_resolution,
                "min_pre_returns": args.min_pre_returns,
                "min_post_returns": args.min_post_returns,
            },
            "registration": {
                "post_transform": transform.tolist(),
                "assessment": (
                    "user_supplied_transform" if args.post_transform else "not_assessed"
                ),
            },
            "height_above_ground_available": args.dtm is not None,
        }
        write_json(directory / "manifest.json", manifest)
    return manifest


# ---------------------------------------------------------------- step 2: find gaps

MEASUREMENT = "changed_return_support_volume"
ANALYSIS_VERSION = 2
SUMMARY_FIELDS = [
    "threshold_m",
    "n_components",
    "n_changed_points",
    "n_voxels",
    "voxel_volume_m3",
    "largest_gap_voxel_share",
]
VOXEL_DTYPES = {
    "ix": "int64",
    "iy": "int64",
    "iz": "int64",
    "object_id": "uint32",
    "n_changed_points": "uint64",
    "mean_c2c_m": "float64",
    "max_c2c_m": "float64",
}
COMPONENT_DTYPES = {
    "object_id": "uint32",
    "gap_volume_m3": "float64",
    "footprint_area_m2": "float64",
    "voxel_volume_m3": "float64",
    "n_points": "uint64",
    "n_voxels": "uint64",
    "volume_centroid_x": "float64",
    "volume_centroid_y": "float64",
    "volume_centroid_z": "float64",
    "point_centroid_x": "float64",
    "point_centroid_y": "float64",
    "point_centroid_z": "float64",
    "xmin": "float64",
    "xmax": "float64",
    "ymin": "float64",
    "ymax": "float64",
    "zmin": "float64",
    "zmax": "float64",
    "mean_c2c_m": "float64",
    "max_c2c_m": "float64",
    "mean_hag_m": "float64",
    "min_hag_m": "float64",
    "max_hag_m": "float64",
}


def fixed_voxel_indices(xyz, voxel_size=1.0, grid_origin=(0.0, 0.0, 0.0)):
    """Floor world coordinates into one fixed grid, with no cloud-bounds origin."""
    origin = np.asarray(grid_origin, dtype=np.float64)
    if origin.shape != (3,) or not np.isfinite(origin).all():
        raise ValueError("grid_origin must contain three finite coordinates")
    if not np.isfinite(voxel_size) or voxel_size <= 0:
        raise ValueError("voxel_size must be finite and positive")
    if xyz.ndim != 2 or xyz.shape[1] != 3:
        raise ValueError("xyz must have shape (N, 3)")
    result = np.empty(xyz.shape, dtype=np.int64)
    for axis in range(3):
        scaled = np.floor((xyz[:, axis] - origin[axis]) / voxel_size)
        # Reserve neighbor/boundary arithmetic at the int64 limits. The float
        # immediately below 2**63 is sufficiently far from overflow as well.
        if (
            not np.isfinite(scaled).all()
            or np.any(scaled <= -(2.0**63))
            or np.any(scaled >= 2.0**63)
        ):
            raise ValueError("coordinates exceed finite int64 voxel grid range")
        result[:, axis] = scaled
    return result


def label_voxels(voxels, connectivity=26):
    """Label sorted, unique occupied cells; IDs follow first lexicographic cell.

    Search only the positive half-neighborhood. Sparse storage scales with
    occupied cells and their adjacency, never with the world bounding volume.
    """
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components

    if connectivity not in (6, 26):
        raise ValueError("connectivity must be 6 or 26")
    n = len(voxels)
    if not n:
        return np.empty(0, dtype=np.uint32)
    keys = row_keys(np.ascontiguousarray(voxels, dtype=np.int64))
    previous, following = voxels[:-1], voxels[1:]
    ordered = (
        (following[:, 0] > previous[:, 0])
        | ((following[:, 0] == previous[:, 0]) & (following[:, 1] > previous[:, 1]))
        | (
            (following[:, 0] == previous[:, 0])
            & (following[:, 1] == previous[:, 1])
            & (following[:, 2] > previous[:, 2])
        )
    )
    if not np.all(ordered):
        raise ValueError("voxels must be unique and lexicographically sorted")
    starts, ends = [], []
    for offset in product((-1, 0, 1), repeat=3):
        if offset <= (0, 0, 0):
            continue
        if connectivity == 6 and sum(abs(x) for x in offset) != 1:
            continue
        neighbors = voxels + np.asarray(offset, dtype=np.int64)
        indices = np.searchsorted(keys, row_keys(neighbors))
        valid = np.flatnonzero(indices < n)
        matched = np.all(voxels[indices[valid]] == neighbors[valid], axis=1)
        valid = valid[matched]
        if valid.size:
            starts.append(valid)
            ends.append(indices[valid])
    if not starts:
        if n > np.iinfo(np.uint32).max:
            raise ValueError("too many objects for uint32 object IDs")
        return np.arange(1, n + 1, dtype=np.uint32)
    source, target = np.concatenate(starts), np.concatenate(ends)
    graph = coo_matrix(
        (np.ones(len(source), dtype=np.uint8), (source, target)), shape=(n, n)
    ).tocsr()
    n_components, labels = connected_components(
        graph, directed=False, return_labels=True
    )
    if n_components > np.iinfo(np.uint32).max:
        raise ValueError("too many objects for uint32 object IDs")
    first = np.full(n_components, n, dtype=np.int64)
    np.minimum.at(first, labels, np.arange(n))
    remap = np.empty(n_components, dtype=np.uint32)
    remap[np.argsort(first)] = np.arange(1, n_components + 1, dtype=np.uint32)
    return remap[labels]


CUBE = np.array([[x, y, z] for x in (0, 1) for y in (0, 1) for z in (0, 1)], float)


def hull_volume(ijk):
    """Exact volume, in cells, of the convex hull of unit cubes at lower corners ijk.

    hull(all corners) = hull(centre-hull vertices + cube), so only hull vertices need
    their 8 corners; flat or tiny objects fall back to all corners.
    """
    pts = np.asarray(ijk, dtype=float)
    try:
        pts = pts[ConvexHull(pts).vertices]
    except (QhullError, ValueError):
        pass
    return ConvexHull((pts[:, None, :] + CUBE).reshape(-1, 3)).volume


def _empty_columns(dtypes):
    return {name: np.empty(0, dtype=dtype) for name, dtype in dtypes.items()}


def _reduce_max(values, groups, count):
    result = np.full(count, -np.inf, dtype=np.float64)
    np.maximum.at(result, groups, values)
    return result


def analyze_threshold(
    arrays,
    indices,
    threshold,
    *,
    voxel_size=1.0,
    grid_origin=(0.0, 0.0, 0.0),
    connectivity=26,
    min_points=10,
    min_volume=0.0,
    min_voxel_points=1,
    exclude_classes=(2, 7, 18),
    min_height=None,
    eligibility=None,
    candidates=None,
):
    """Return point labels and typed sparse voxel/component tables for one cut.

    indices holds voxel cells for the candidates rows (every point when omitted).
    """
    xyz, distances = arrays["xyz"], arrays["c2c"]
    point_labels = np.zeros(len(xyz), dtype=np.uint32)
    empty = (
        point_labels,
        _empty_columns(VOXEL_DTYPES),
        _empty_columns(COMPONENT_DTYPES),
    )
    if eligibility is None:
        eligibility = _eligibility(arrays, exclude_classes, min_height)
    if candidates is None:
        candidates = np.arange(len(xyz))
    local = np.flatnonzero(
        eligibility[candidates] & (distances[candidates] >= threshold)
    )
    selected = candidates[local]
    if not selected.size:
        return empty

    keys, inverse, counts = np.unique(
        row_keys(np.ascontiguousarray(indices[local])),
        return_inverse=True,
        return_counts=True,
    )
    occupied = keys.view(np.int64).reshape(-1, 3)
    supported = counts >= min_voxel_points
    voxel_lookup = np.full(len(occupied), -1, dtype=np.int64)
    voxel_lookup[supported] = np.arange(np.count_nonzero(supported))
    point_voxel = voxel_lookup[inverse]
    retained = point_voxel >= 0
    selected, point_voxel = selected[retained], point_voxel[retained]
    occupied, counts = occupied[supported], counts[supported]
    if not len(occupied):
        return empty

    component = label_voxels(occupied, connectivity).astype(np.int64) - 1
    n_components = int(component.max()) + 1
    n_voxels = np.bincount(component, minlength=n_components).astype(np.uint64)
    n_points = np.zeros(n_components, dtype=np.uint64)
    np.add.at(n_points, component, counts.astype(np.uint64))
    cell_volume = float(voxel_size) ** 3
    volumes = n_voxels.astype(np.float64) * cell_volume
    keep = (n_points >= min_points) & (volumes >= min_volume)
    if not np.any(keep):
        return empty
    mapping = np.zeros(n_components, dtype=np.uint32)
    mapping[keep] = np.arange(1, np.count_nonzero(keep) + 1, dtype=np.uint32)
    object_ids = mapping[component]
    point_ids = object_ids[point_voxel]
    retained = point_ids > 0
    selected, point_voxel, point_ids = (
        selected[retained],
        point_voxel[retained],
        point_ids[retained],
    )
    point_labels[selected] = point_ids

    kept_voxels = object_ids > 0
    voxel_lookup = np.full(len(occupied), -1, dtype=np.int64)
    voxel_lookup[kept_voxels] = np.arange(np.count_nonzero(kept_voxels))
    point_voxel = voxel_lookup[point_voxel]
    occupied, counts, object_ids = (
        occupied[kept_voxels],
        counts[kept_voxels],
        object_ids[kept_voxels],
    )
    point_group = point_ids.astype(np.int64) - 1
    voxel_group = object_ids.astype(np.int64) - 1
    n_points, n_voxels, volumes = n_points[keep], n_voxels[keep], volumes[keep]
    count = len(n_points)
    changed_distances = distances[selected]
    voxel_table = {
        "ix": occupied[:, 0],
        "iy": occupied[:, 1],
        "iz": occupied[:, 2],
        "object_id": object_ids,
        "n_changed_points": counts.astype(np.uint64),
        "mean_c2c_m": np.bincount(
            point_voxel, weights=changed_distances, minlength=len(occupied)
        )
        / counts,
        "max_c2c_m": _reduce_max(changed_distances, point_voxel, len(occupied)),
    }
    table = {
        "object_id": np.arange(1, count + 1, dtype=np.uint32),
        "n_points": n_points,
        "n_voxels": n_voxels,
        "voxel_volume_m3": volumes,
    }
    first = np.full(count, len(occupied), dtype=np.int64)
    np.minimum.at(first, voxel_group, np.arange(len(occupied)))
    origin = np.asarray(grid_origin, dtype=np.float64)
    # Local reductions avoid summing large map coordinates repeatedly. Volume
    # centroids weight each occupied voxel exactly once, not each return.
    for axis, name in enumerate("xyz"):
        anchor = occupied[first, axis]
        local_cells = (occupied[:, axis] - anchor[voxel_group]).astype(np.float64)
        mean_cells = (
            np.bincount(voxel_group, weights=local_cells, minlength=count) / n_voxels
        )
        point_anchor = origin[axis] + anchor.astype(np.float64) * voxel_size
        table[f"volume_centroid_{name}"] = (
            point_anchor + (mean_cells + 0.5) * voxel_size
        )
        local_points = xyz[selected, axis] - point_anchor[point_group]
        table[f"point_centroid_{name}"] = (
            point_anchor
            + np.bincount(point_group, weights=local_points, minlength=count) / n_points
        )
        low = np.full(count, np.iinfo(np.int64).max, dtype=np.int64)
        high = np.full(count, np.iinfo(np.int64).min, dtype=np.int64)
        np.minimum.at(low, voxel_group, occupied[:, axis])
        np.maximum.at(high, voxel_group, occupied[:, axis])
        table[f"{name}min"] = origin[axis] + low.astype(np.float64) * voxel_size
        table[f"{name}max"] = origin[axis] + (high + 1).astype(np.float64) * voxel_size
    table["mean_c2c_m"] = (
        np.bincount(point_group, weights=changed_distances, minlength=count) / n_points
    )
    table["max_c2c_m"] = _reduce_max(changed_distances, point_group, count)
    for key in ("mean_hag_m", "min_hag_m", "max_hag_m"):
        table[key] = np.full(count, np.nan, dtype=np.float64)
    if "hag" in arrays:
        heights = arrays["hag"][selected].astype(np.float64)
        finite = np.isfinite(heights)
        height_groups, heights = point_group[finite], heights[finite]
        height_counts = np.bincount(height_groups, minlength=count)
        observed = height_counts > 0
        table["mean_hag_m"][observed] = (
            np.bincount(height_groups, weights=heights, minlength=count)[observed]
            / height_counts[observed]
        )
        table["max_hag_m"][observed] = _reduce_max(heights, height_groups, count)[
            observed
        ]
        table["min_hag_m"][observed] = -_reduce_max(-heights, height_groups, count)[
            observed
        ]
    # Gap volume = convex hull of the voxel cubes; footprint = occupied XY columns.
    order = np.argsort(voxel_group, kind="stable")
    splits = np.flatnonzero(np.diff(voxel_group[order])) + 1
    table["gap_volume_m3"] = cell_volume * np.array(
        [hull_volume(block) for block in np.split(occupied[order], splits)]
    )
    columns = np.unique(np.column_stack((voxel_group, occupied[:, :2])), axis=0)
    table["footprint_area_m2"] = (
        np.bincount(columns[:, 0], minlength=count) * float(voxel_size) ** 2
    )
    return point_labels, voxel_table, {name: table[name] for name in COMPONENT_DTYPES}


def _eligibility(arrays, exclude_classes, min_height):
    distances = arrays["c2c"]
    valid = arrays["valid"] & np.isfinite(distances) & (distances >= 0)
    if exclude_classes:
        valid &= ~np.isin(arrays["classification"], exclude_classes)
    if min_height is not None:
        if "hag" not in arrays:
            raise ValueError("--min-height requires a cache prepared with --dtm")
        valid &= np.isfinite(arrays["hag"]) & (arrays["hag"] >= min_height)
    return valid


def ground_separation(arrays):
    """Pre-to-post C2C of supported class-2 ground returns.

    Stable ground should sit near post return spacing; medians near or above the
    lowest threshold mean misregistration, not canopy change, can drive results.
    """
    ground = arrays["valid"] & (arrays["classification"] == 2)
    values = np.asarray(arrays["c2c"][ground])
    values = values[np.isfinite(values)]
    if not len(values):
        return None
    p50, p90, p99 = np.percentile(values, [50, 90, 99])
    return {
        "n_ground_points": int(len(values)),
        "c2c_p50_m": float(p50),
        "c2c_p90_m": float(p90),
        "c2c_p99_m": float(p99),
    }


def _config(
    thresholds,
    voxel_size,
    grid_origin,
    connectivity,
    min_points,
    min_volume,
    min_voxel_points,
    exclude_classes,
    min_height,
):
    thresholds = sorted(set(float(t) for t in thresholds))
    if not thresholds or any(not np.isfinite(t) or t < 0 for t in thresholds):
        raise ValueError("thresholds must be nonempty, finite, and nonnegative")
    if not np.isfinite(voxel_size) or voxel_size <= 0:
        raise ValueError("voxel-size must be finite and positive")
    try:
        cell_volume = float(voxel_size) ** 3
    except OverflowError as exc:
        raise ValueError("voxel-size must yield a finite positive cell volume") from exc
    if not np.isfinite(cell_volume) or cell_volume == 0:
        raise ValueError("voxel-size must yield a finite positive cell volume")
    if len(grid_origin) != 3 or not np.isfinite(grid_origin).all():
        raise ValueError("grid-origin must contain three finite coordinates")
    if connectivity not in (6, 26):
        raise ValueError("connectivity must be 6 or 26")
    if min_points < 1 or int(min_points) != min_points:
        raise ValueError("min-points must be a positive integer")
    if min_voxel_points < 1 or int(min_voxel_points) != min_voxel_points:
        raise ValueError("min-voxel-points must be a positive integer")
    if not np.isfinite(min_volume) or min_volume < 0:
        raise ValueError("min-volume must be finite and nonnegative")
    if min_height is not None and not np.isfinite(min_height):
        raise ValueError("min-height must be finite")
    if any(int(c) != c or not 0 <= c <= 255 for c in exclude_classes):
        raise ValueError("exclude-classes must contain integers from 0 through 255")
    return {
        "thresholds": thresholds,
        "voxel_size": float(voxel_size),
        "grid_origin": [float(v) for v in grid_origin],
        "connectivity": int(connectivity),
        "min_points": int(min_points),
        "min_volume": float(min_volume),
        "min_voxel_points": int(min_voxel_points),
        "exclude_classes": sorted(set(int(c) for c in exclude_classes)),
        "min_height": None if min_height is None else float(min_height),
    }


def _write_table(path, columns, dtypes):
    import pyarrow as pa

    schema = pa.schema(
        [(name, pa.from_numpy_dtype(np.dtype(dtype))) for name, dtype in dtypes.items()]
    )
    write_parquet(path, columns, schema=schema)


def _rows(columns):
    names = list(columns)
    for values in zip(*(columns[name] for name in names)):
        yield {name: value.item() for name, value in zip(names, values)}


PER_POINT = ("gap_volume_m3", "voxel_volume_m3", "footprint_area_m2")


def _write_laz(path, manifest, arrays, labels, components):
    """Gap points only, each stamped with its gap's attributes and a colour per gap."""
    import laspy
    from pyproj import CRS

    rows = np.flatnonzero(labels)
    ids = labels[rows].astype(np.int64)
    xyz = np.asarray(arrays["xyz"][rows])
    header = laspy.LasHeader(point_format=7, version="1.4")
    header.scales = np.full(3, 0.001)
    header.offsets = np.floor(xyz.min(axis=0)) if len(xyz) else np.zeros(3)
    header.add_crs(CRS.from_wkt(manifest["crs_wkt"]))
    header.add_extra_dims(
        [laspy.ExtraBytesParams(name="gap_id", type=np.uint32),
         laspy.ExtraBytesParams(name="c2c_m", type=np.float32)]
        + [laspy.ExtraBytesParams(name=c, type=np.float32) for c in PER_POINT]
    )
    las = laspy.LasData(header)
    las.x, las.y, las.z = xyz.T
    las.classification = np.asarray(arrays["classification"][rows])
    las["gap_id"] = ids
    las["c2c_m"] = np.asarray(arrays["c2c"][rows], dtype=np.float32)
    for c in PER_POINT:
        las[c] = components[c][ids - 1].astype(np.float32)
    palette = np.random.default_rng(0).integers(40, 256, (len(components["object_id"]) + 1, 3))
    las.red, las.green, las.blue = (palette[ids] * 257).T.astype(np.uint16)
    las.write(path)


def _write_gpkg(path, manifest, voxels, components, config):
    """Per-gap footprint outlines and bounding boxes, carrying every gap attribute."""
    import geopandas as gpd
    import pandas as pd
    from rasterio import features
    from rasterio.transform import from_origin
    from shapely.geometry import box, shape
    from shapely.ops import unary_union

    size, (ox, oy, _) = config["voxel_size"], config["grid_origin"]
    cells = np.unique(
        np.column_stack((voxels["object_id"].astype(np.int64), voxels["ix"], voxels["iy"])),
        axis=0,
    )
    outlines = []
    blocks = np.split(cells, np.flatnonzero(np.diff(cells[:, 0])) + 1) if len(cells) else []
    for block in blocks:
        x0, y0, y1 = block[:, 1].min(), block[:, 2].min(), block[:, 2].max()
        mask = np.zeros((y1 - y0 + 1, block[:, 1].max() - x0 + 1), np.uint8)
        mask[y1 - block[:, 2], block[:, 1] - x0] = 1
        transform = from_origin(ox + x0 * size, oy + (y1 + 1) * size, size, size)
        outlines.append(unary_union(
            [shape(g) for g, _ in features.shapes(mask, mask=mask > 0, transform=transform)]
        ))
    table = pd.DataFrame(components)
    crs = manifest["crs_wkt"]
    gpd.GeoDataFrame(table, geometry=outlines, crs=crs).to_file(path, layer="footprints")
    boxes = [box(*b) for b in table[["xmin", "ymin", "xmax", "ymax"]].to_numpy()]
    gpd.GeoDataFrame(table, geometry=boxes, crs=crs).to_file(path, layer="bboxes")


def analyze_cache(
    cache,
    output=None,
    *,
    thresholds=(1.0, 2.0, 5.0),
    voxel_size=1.0,
    grid_origin=(0.0, 0.0, 0.0),
    connectivity=26,
    min_points=10,
    min_volume=0.0,
    min_voxel_points=1,
    exclude_classes=(2, 7, 18),
    min_height=None,
):
    """Save numerical results per threshold; resume missing exports on retry."""
    config = _config(
        thresholds,
        voxel_size,
        grid_origin,
        connectivity,
        min_points,
        min_volume,
        min_voxel_points,
        exclude_classes,
        min_height,
    )
    cache = Path(cache).expanduser().resolve()
    manifest, arrays = load_cache(cache, provenance=False)
    identity = {
        "schema_version": SCHEMA_VERSION,
        "analysis_version": ANALYSIS_VERSION,
        "cache_id": manifest["cache_id"],
        "config": config,
    }
    run_id = stable_id(identity)
    output = (
        Path(output).expanduser().resolve()
        if output is not None
        else cache.parent / "gaps" / run_id[:16]
    )
    if output.exists():
        if not (output / "run.json").is_file():
            raise ValueError(
                f"output exists but has no analysis identity: {output}"
            )
        previous = read_json(output / "run.json")
        if previous.get("run_id") != run_id or any(
            previous.get(k) != v for k, v in identity.items()
        ):
            raise ValueError(
                f"output contains a different analysis; choose a new --output: {output}"
            )
    run = {
        **identity,
        "cache_path": str(cache),
        "run_id": run_id,
        "complete": False,
        "thresholds": config["thresholds"],
        "measurement": MEASUREMENT,
        "vertical_observation": "not_established",
        "scientific_description": "Union of fixed-grid voxels supported by eligible pre-epoch returns whose one-way nearest-neighbor separation meets the threshold.",
        "limitations": [
            "Changed-return support is not confirmed empty canopy volume, wood volume, biomass, or a causal attribution of vegetation loss.",
            "Common XY return coverage is necessary support, not proof of vertical visibility or equal sampling density.",
            "One-way C2C separation can reflect occlusion, registration error, acquisition geometry, or real change; no uncertainty interval is inferred.",
            "Support volume depends on voxel size, fixed-grid origin, threshold, and support filters; report these settings with results.",
        ],
        "registration": manifest["registration"],
        "ground_separation": ground_separation(arrays),
        "vertical_datum": manifest["vertical_datum"],
        "summary_count_definition": "Only points and occupied voxels in retained objects are counted.",
    }
    if not output.exists():
        with atomic_directory(output) as staging:
            write_json(staging / "run.json", run)
    else:
        write_json(output / "run.json", run)
    indices = eligibility = candidates = None
    options = {key: value for key, value in config.items() if key != "thresholds"}
    summary = []
    for threshold in config["thresholds"]:
        folder = output / threshold_directory_name(threshold)
        labels = voxels = components = None
        if not folder.exists():
            if indices is None:
                eligibility = _eligibility(
                    arrays, config["exclude_classes"], config["min_height"]
                )
                # Only points that can pass the lowest cut ever need a voxel.
                candidates = np.flatnonzero(
                    eligibility & (arrays["c2c"] >= config["thresholds"][0])
                )
                indices = fixed_voxel_indices(
                    arrays["xyz"][candidates], config["voxel_size"], config["grid_origin"]
                )
            labels, voxels, components = analyze_threshold(
                arrays,
                indices,
                threshold,
                eligibility=eligibility,
                candidates=candidates,
                **options,
            )
            row = {
                "threshold_m": threshold,
                "n_components": len(components["object_id"]),
                "n_changed_points": int(components["n_points"].sum()),
                "n_voxels": int(components["n_voxels"].sum()),
                "voxel_volume_m3": float(components["voxel_volume_m3"].sum()),
                "largest_gap_voxel_share": float(
                    components["n_voxels"].max(initial=0)
                    / max(components["n_voxels"].sum(), 1)
                ),
            }
            with atomic_directory(folder) as staging:
                np.save(staging / "point_labels.npy", labels, allow_pickle=False)
                _write_table(staging / "voxels.parquet", voxels, VOXEL_DTYPES)
                write_csv(staging / "gaps.csv", _rows(components), list(COMPONENT_DTYPES))
                write_json(staging / "metadata.json", {
                    "schema_version": SCHEMA_VERSION,
                    "analysis_version": ANALYSIS_VERSION,
                    "cache_path": str(cache),
                    "cache_id": manifest["cache_id"],
                    "run_id": run_id,
                    "threshold_m": threshold,
                    "grid_origin": config["grid_origin"],
                    "voxel_size_m": config["voxel_size"],
                    "connectivity": config["connectivity"],
                    "measurement": MEASUREMENT,
                    "vertical_observation": "not_established",
                    "config": config,
                    "limitations": run["limitations"],
                    "summary": row,
                })
        else:
            metadata = read_json(folder / "metadata.json")
            if metadata.get("run_id") != run_id:
                raise ValueError(f"threshold contains a different analysis: {folder}")
            row = metadata["summary"]

        for name, writer in (("gaps.gpkg", _write_gpkg), ("gaps.laz", _write_laz)):
            destination = folder / name
            if destination.is_file():
                continue
            if components is None:
                with (folder / "gaps.csv").open(newline="", encoding="utf-8") as stream:
                    rows = list(csv.DictReader(stream))
                components = {
                    key: np.array([r[key] for r in rows], dtype=dtype)
                    for key, dtype in COMPONENT_DTYPES.items()
                }
                del rows
            if name == "gaps.gpkg":
                if voxels is None:
                    import pyarrow.parquet as pq

                    table = pq.read_table(
                        folder / "voxels.parquet", columns=["object_id", "ix", "iy"]
                    )
                    voxels = {key: table[key].to_numpy() for key in table.column_names}
                    del table
                arguments = (manifest, voxels, components, config)
            else:
                if labels is None:
                    labels = np.load(folder / "point_labels.npy", mmap_mode="r", allow_pickle=False)
                arguments = (manifest, arrays, labels, components)
            with TemporaryDirectory(prefix=".export-", dir=folder) as temporary:
                export = Path(temporary) / name
                writer(export, *arguments)
                export.replace(destination)
            del arguments
        summary.append(row)
        del labels, voxels, components
    write_csv(output / "summary.csv", summary, SUMMARY_FIELDS)
    run["complete"] = True
    write_json(output / "run.json", run)
    return {**run, "output": str(output)}


# ---------------------------------------------------------------- run


def stamp(message):
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {message}", flush=True)


def check_inputs():
    """Name every missing input up front instead of failing partway through step 1."""
    inputs = [*PRE, *POST, STUDY_AREA, DTM]
    missing = [str(p) for p in inputs if p is not None and not Path(p).exists()]
    if missing:
        raise SystemExit(
            "Missing inputs:\n  " + "\n  ".join(missing)
            + "\nSet PR_GAPS_GLIHT / PR_GAPS_DTM, download the campaigns, or copy the"
            " study-area polygon into sites/ (see python/README.md)."
        )


def main():
    os.chdir(Path(__file__).resolve().parent)
    check_inputs()
    if Path(SCRATCH).is_dir():
        tempfile.tempdir = SCRATCH
    stamp(f"prepare {SITE} (reuses an identical cache)")
    manifest = prepare(SimpleNamespace(
        pre=PRE, post=POST, cache=CACHE, tile_filter=TILE_FILTER, crs=CRS,
        vertical_datum=VERTICAL_DATUM, study_area=STUDY_AREA,
        post_transform=POST_TRANSFORM, dtm=DTM,
        coverage_resolution=COVERAGE_RESOLUTION, min_pre_returns=MIN_PRE_RETURNS,
        min_post_returns=MIN_POST_RETURNS, threads=THREADS, chunk_size=CHUNK_SIZE,
    ))
    print(f"Cache {manifest['cache_id']}: {manifest['point_count']} pre points")

    stamp(f"gaps at thresholds: {THRESHOLDS}")
    run = analyze_cache(
        CACHE, OUTPUT, thresholds=THRESHOLDS, voxel_size=VOXEL_SIZE,
        grid_origin=GRID_ORIGIN, connectivity=CONNECTIVITY, min_points=MIN_POINTS,
        min_volume=MIN_VOLUME, min_voxel_points=MIN_VOXEL_POINTS,
        exclude_classes=EXCLUDE_CLASSES, min_height=MIN_HEIGHT,
    )
    print(f"Gaps {run['run_id']}: {run['output']}")
    print(f"Ground pre-to-post C2C: {run['ground_separation']}")
    print((Path(run["output"]) / "summary.csv").read_text(), end="")
    stamp("done")


if __name__ == "__main__":
    main()

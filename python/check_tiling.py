"""M2 step-1 test: do the tiled work units reproduce an untiled site run's distances?

    python python/check_tiling.py ev1           # the site's pair's units vs the site cache
    python python/check_tiling.py ev1 --units E0202_N2028_p030 E0203_N2028_p030

docs/hpc-scaling-plan.md §4.4. Matches 2017 points between the site cache and the unit
caches by original LAS file and record (source_file / source_index), then checks:

- no 2017 point appears in two units;
- every site point inside the site's study area is in a unit, and every unit point
  inside it is in the site cache. Points in 1 m columns that touch the study-area
  boundary are reported separately: the site clipped by polygon, units clip by column
  centre, so those columns legitimately differ;
- distances agree to float32 rounding (1 mm). Unit distances are capped at 50 m and the
  site's may not be, so the site distance is capped the same way before comparing.

Default units: every plan unit of the pair the site ran (its 2017 and 2018 campaigns).
Run it as a job: it holds both clouds' keys in memory (~40 bytes per point).
Exits 1 if anything FAILs.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

TOLERANCE_M = 1e-3
failures = []


def report(status, message):
    print(f"  {status:<4} {message}")
    if status == "FAIL":
        failures.append(message)


def campaign_of(signature):
    return Path(signature["path"]).parent.parent.parent.name


def keyed(manifest, arrays, paths):
    """uint64 key per point: index of its original LAS path in `paths`, then its record."""
    ids = np.array([paths.setdefault(s["path"], len(paths)) for s in manifest["source_files"]],
                   dtype=np.uint64)
    source_file = np.asarray(arrays["source_file"])
    index = np.asarray(arrays["source_index"]).astype(np.uint64)
    if index.size and index.max() >= 2**40:
        raise ValueError("source_index too large for the 40-bit key")
    return (ids[source_file] << np.uint64(40)) | index


def boundary_columns(columns, polygon):
    """Which 1 m columns (ix, iy) touch the polygon's boundary."""
    import shapely

    boxes = shapely.box(columns[:, 0], columns[:, 1], columns[:, 0] + 1, columns[:, 1] + 1)
    boundary = polygon.boundary
    shapely.prepare(boundary)
    return shapely.intersects(boxes, boundary)


def classify(xyz, polygon):
    """For unmatched points: inside the study area (and not on a boundary column) or not."""
    import shapely

    if not len(xyz):
        return np.zeros(0, bool), np.zeros(0, bool)
    columns, inverse = np.unique(np.floor(xyz[:, :2]).astype(np.int64), axis=0,
                                 return_inverse=True)
    inverse = inverse.ravel()
    edge = boundary_columns(columns, polygon)[inverse]
    centre = shapely.intersects_xy(polygon, columns[:, 0] + 0.5, columns[:, 1] + 0.5)[inverse]
    return centre & ~edge, edge


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("site", help="the untiled site run, e.g. ev1")
    parser.add_argument("--units", nargs="*", help="unit IDs (default: every unit of the site's pair)")
    args = parser.parse_args()

    site_root = canopy.DATA / "runs" / "canopy" / args.site / "cache"
    site_manifest, site = canopy.load_cache(site_root)
    pre = {campaign_of(s) for s in site_manifest["source_files"]}
    post = {campaign_of(s) for s in site_manifest["reference_files"]}
    plan = pd.read_csv(canopy.PLAN / "work_units.csv")
    names = args.units or list(plan.loc[plan.campaign_pre.isin(pre) & plan.campaign_post.isin(post), "unit"])
    print(f"site {args.site}: {site_manifest['point_count']:,} 2017 points; "
          f"{len(names)} units of {sorted(pre)} -> {sorted(post)}")
    study_area = site_manifest["preparation"]["study_area"]
    if not study_area:
        raise SystemExit(f"{args.site} has no study area; nothing to define the shared ground")
    polygon = canopy.load_domain(study_area[0]["path"], "EPSG:32620")

    paths = {}
    site_keys = keyed(site_manifest, site, paths)
    unit_keys, unit_c2c, unit_xyz_parts, missing = [], [], [], []
    for name in names:
        root = canopy.DATA / "runs" / "canopy" / "units" / name / "cache"
        if not (root / "manifest.json").is_file():
            missing.append(name)
            continue
        manifest, arrays = canopy.load_cache(root)
        unit_keys.append(keyed(manifest, arrays, paths))
        unit_c2c.append(np.asarray(arrays["c2c"]))
        unit_xyz_parts.append((root, len(unit_keys[-1])))
    note = f"; missing: {', '.join(missing[:10])}" if missing else ""
    report("FAIL" if missing else "PASS",
           f"{len(names) - len(missing)} of {len(names)} unit caches complete{note}")
    keys = np.concatenate(unit_keys) if unit_keys else np.zeros(0, np.uint64)
    c2c = np.concatenate(unit_c2c) if unit_c2c else np.zeros(0)
    print(f"units: {len(keys):,} 2017 points")

    unique, counts = np.unique(keys, return_counts=True)
    twice = int((counts > 1).sum())
    report("FAIL" if twice else "PASS", f"{twice:,} points in more than one unit (should be 0)")

    shared, site_at, unit_at = np.intersect1d(site_keys, keys, assume_unique=False,
                                              return_indices=True)
    cap = canopy.MAX_SEARCH_M
    expected = np.minimum(np.asarray(site["c2c"])[site_at], cap)
    difference = c2c[unit_at] - expected
    agree = np.abs(difference) <= TOLERANCE_M
    report("PASS" if agree.all() else "FAIL",
           f"{len(shared):,} shared points: {agree.mean():.4%} identical within 1 mm "
           f"(site distances capped at {cap:g} m), max |difference| "
           f"{np.abs(difference).max() if len(difference) else 0:.4f} m")

    # Points on one side only: fine at the study-area edge, a failure inside it.
    site_only = np.setdiff1d(np.arange(len(site_keys)), site_at, assume_unique=True)
    inside, edge = classify(np.asarray(site["xyz"])[site_only], polygon)
    report("FAIL" if inside.any() else "PASS",
           f"{len(site_only):,} site points in no unit: {int(edge.sum()):,} in study-area "
           f"boundary columns, {int(inside.sum()):,} inside the study area (should be 0)")
    unit_only = np.setdiff1d(np.arange(len(keys)), unit_at, assume_unique=True)
    xyz = []
    offset = 0
    for root, n in unit_xyz_parts:
        rows = unit_only[(unit_only >= offset) & (unit_only < offset + n)] - offset
        if len(rows):
            xyz.append(np.asarray(canopy.load_cache(root)[1]["xyz"])[rows])
        offset += n
    inside, edge = classify(np.concatenate(xyz) if xyz else np.zeros((0, 3)), polygon)
    report("FAIL" if inside.any() else "PASS",
           f"{len(unit_only):,} unit points not in the site: {int(edge.sum()):,} in boundary "
           f"columns, {int(inside.sum()):,} inside the study area (should be 0), the rest outside it")

    print("\n" + ("FAILED: " + "; ".join(failures) if failures else "All checks passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

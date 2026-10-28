"""Check that a canopy.py run finished and that its numbers are sane.

    python python/check_run.py                 # the site canopy.py would run (PR_GAPS_SITE)
    python python/check_run.py ev1
    python python/check_run.py ev1 --compare lfdp

Reads $PR_GAPS_DATA/runs/canopy/<site>/ and prints PASS/WARN/FAIL lines:

- step 1: a complete cache (not a leftover .cache-*), its point count, the share of
  2017 points with both-flights coverage, distances finite, and heights above ground
  near 0 m on ground returns (LAS and DTM on the same vertical datum);
- step 2: every gap run marked complete, every threshold folder holding all its
  outputs, and gaps.csv, point_labels.npy, gaps.laz and gaps.gpkg agreeing on counts.

--compare SITE matches 2017 points by source file and record (both caches must be on
this machine) and compares their distances. Inside one flight's tiles they should be
identical (to float32 rounding, ~1 mm); a larger site can only find nearer 2018 points (from tiles the smaller site
didn't read), so its distances may be smaller near tile edges, never larger.
Exits 1 if anything FAILs.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402

failures = []
TOLERANCE_M = 1e-3


def report(status, message):
    print(f"  {status:<4} {message}")
    if status == "FAIL":
        failures.append(message)


def check_cache(root):
    print(f"step 1: {root / 'cache'}")
    for leftover in sorted(root.glob(".cache-*")):
        report("WARN", f"leftover from a killed run, safe to delete: {leftover.name}")
    if not (root / "cache" / "manifest.json").is_file():
        report("FAIL", "no complete cache (cache/manifest.json missing): step 1 did not finish")
        return None
    manifest, arrays = canopy.load_cache(root / "cache")
    n = manifest["point_count"]
    report("PASS", f"cache complete: {n:,} 2017 points, from "
                   f"{len(manifest['source_files'])} + {len(manifest['reference_files'])} files")
    valid = np.asarray(arrays["valid"])
    report("PASS" if valid.any() else "FAIL",
           f"{valid.mean():.1%} of 2017 points have both-flights coverage")
    c2c = np.asarray(arrays["c2c"])
    bad = ~np.isfinite(c2c) | (c2c < 0)
    report("FAIL" if bad.any() else "PASS", f"{bad.sum():,} missing or negative distances")
    if "hag" in arrays:
        hag = np.asarray(arrays["hag"])
        missing = np.isnan(hag[valid]).mean()
        report("WARN" if missing > 0.01 else "PASS",
               f"{missing:.2%} of covered points have no height above ground (outside DTM)")
        ground = valid & (np.asarray(arrays["classification"]) == 2) & np.isfinite(hag)
        if ground.any():
            p5, p50, p95 = np.percentile(hag[ground], [5, 50, 95])
            report("PASS" if abs(p50) < 0.3 else "FAIL",
                   f"ground height above DTM: median {p50:+.2f} m (p5 {p5:+.2f}, p95 {p95:+.2f})")
    return manifest, arrays


def check_gaps(root, n_points):
    runs = sorted((root / "gaps").glob("*/run.json"))
    print(f"step 2: {len(runs)} gap run(s) in {root / 'gaps'}")
    if not runs:
        report("FAIL", "no gap runs: step 2 did not start")
    for run_file in runs:
        run = canopy.read_json(run_file)
        folder = run_file.parent
        report("PASS" if run.get("complete") else "FAIL",
               f"{folder.name}: complete={run.get('complete')}, thresholds {run['thresholds']}")
        ground = run.get("ground_separation") or {}
        if ground:
            report("PASS" if ground["c2c_p50_m"] < 1 else "WARN",
                   f"{folder.name}: ground C2C median {ground['c2c_p50_m']:.3f} m, "
                   f"p99 {ground['c2c_p99_m']:.3f} m")
        for threshold in run["thresholds"]:
            check_threshold(folder / canopy.threshold_directory_name(threshold), n_points)


def check_threshold(folder, n_points):
    import csv

    import laspy
    import pyogrio

    needed = ["gaps.csv", "voxels.parquet", "metadata.json", "point_labels.npy",
              "gaps.gpkg", "gaps.laz"]
    missing = [name for name in needed if not (folder / name).is_file()]
    if missing:
        report("FAIL", f"{folder.name}: missing {', '.join(missing)} (rerun to resume)")
        return
    summary = canopy.read_json(folder / "metadata.json")["summary"]
    with (folder / "gaps.csv").open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    gaps, points = len(rows), sum(int(r["n_points"]) for r in rows)
    labels = np.load(folder / "point_labels.npy", mmap_mode="r")
    labelled = sum(int(np.count_nonzero(labels[i:i + 50_000_000]))
                   for i in range(0, len(labels), 50_000_000))
    with laspy.open(folder / "gaps.laz") as reader:
        laz_points = reader.header.point_count
    footprints = pyogrio.read_info(folder / "gaps.gpkg", layer="footprints")["features"]
    agree = (gaps == summary["n_components"] == footprints
             and points == summary["n_changed_points"] == labelled == laz_points
             and len(labels) == n_points)
    report("PASS" if agree else "FAIL",
           f"{folder.name}: {gaps:,} gaps, {points:,} gap points, "
           f"{summary['voxel_volume_m3']:,.0f} m3; csv/labels/laz/gpkg "
           + ("agree" if agree else f"DISAGREE (labels {labelled:,}, laz {laz_points:,}, "
                                    f"gpkg {footprints:,}, label rows {len(labels):,})"))
    if gaps:
        hag = np.array([float(r["mean_hag_m"]) for r in rows])
        if np.isfinite(hag).any():
            report("PASS", f"{folder.name}: gap mean height above ground "
                           f"{np.nanpercentile(hag, 5):.1f}-{np.nanpercentile(hag, 95):.1f} m (p5-p95)")


def compare(site, cached, other_site):
    other_root = canopy.DATA / "runs" / "canopy" / other_site
    print(f"compare: {site} vs {other_site} distances for shared 2017 points")
    if not (other_root / "cache" / "manifest.json").is_file():
        report("FAIL", f"no complete cache for {other_site} at {other_root / 'cache'}")
        return
    manifest, arrays = cached
    other_manifest, other = canopy.load_cache(other_root / "cache")
    ids = {s["path"]: i for i, s in enumerate(manifest["source_files"])}
    this_file = np.asarray(arrays["source_file"])
    matched = equal = larger = 0
    worst = 0.0
    for other_id, source in enumerate(other_manifest["source_files"]):
        if source["path"] not in ids:
            continue
        rows = np.flatnonzero(this_file == ids[source["path"]])
        index = np.asarray(arrays["source_index"])[rows]  # ascending: streamed in order
        other_rows = np.flatnonzero(np.asarray(other["source_file"]) == other_id)
        other_index = np.asarray(other["source_index"])[other_rows]
        position = np.minimum(np.searchsorted(index, other_index), max(len(index) - 1, 0))
        hit = len(index) > 0
        found = (index[position] == other_index) if hit else np.zeros(len(other_rows), bool)
        mine = np.asarray(arrays["c2c"])[rows[position[found]]]
        theirs = np.asarray(other["c2c"])[other_rows[found]]
        difference = mine - theirs
        matched += int(found.sum())
        # CloudComPy works in float32 around each run's own centre: ~1 mm of rounding.
        equal += int(np.count_nonzero(np.abs(difference) <= TOLERANCE_M))
        larger += int(np.count_nonzero(difference > TOLERANCE_M))
        if difference.size:
            worst = max(worst, float(np.abs(difference).max()))
    if not matched:
        report("FAIL", f"no shared 2017 points between {site} and {other_site}")
        return
    report("PASS" if larger == 0 else "FAIL",
           f"{matched:,} shared points: {equal / matched:.2%} identical within 1 mm, "
           f"{larger:,} larger in {site} (should be 0), max |difference| {worst:.3f} m")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("site", nargs="?", default=canopy.SITE)
    parser.add_argument("--compare", metavar="SITE", help="compare distances with another site's cache")
    args = parser.parse_args()
    root = canopy.DATA / "runs" / "canopy" / args.site
    print(f"site {args.site}: {root}")
    cached = check_cache(root)
    if cached is not None:
        check_gaps(root, cached[0]["point_count"])
        if args.compare:
            compare(args.site, cached, args.compare)
    print("\n" + ("FAILED: " + "; ".join(failures) if failures else "All checks passed."))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

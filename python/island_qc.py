"""Island-wide quality control: per unit, per pair, per tile, and island-wide checks.

    python python/island_qc.py              # step 1 checks; gap maps for every finished join
    python python/island_qc.py --workers 8  # default: $SLURM_CPUS_PER_TASK

docs/hpc-scaling-plan.md §4.7. Run after step 1, and again after step 2 for the gap
maps. It flags; it never excludes anything. Excluding a pair or tile is a decision
recorded in the plan before the island-wide results are examined (M5).

Writes $PR_GAPS_DATA/runs/canopy/qc/<plan id>/:
  units.csv   one row per unit: check_run.py's step-1 metrics and PASS/WARN/FAIL
  pairs.csv   registration per flight pair, pooled over its units: ground-return C2C
              median and p95, ground height above DTM, share of distances at the cap,
              and ground_dz: the lowest 2018 return in a 2017 ground return's column
              minus its height (about 0 when registered; ~C2C for a vertical shift,
              ~0 with a large C2C for a sideways shift or no 2018 ground)
  tiles.gpkg  one square per tile with the same registration figures, covered hectares,
              and, per finished gap threshold, gap area fraction and largest-gap share
  checks.txt  island-wide checks, flags and the summary
  qc.json     what was checked, for status.py

Flags (thresholds as in the plan; for scale, LFDP and EV1 were 0.20-0.21 m and -0.05 m):
  pair registration:  ground C2C median > 0.5 m, or ground height median outside +-0.3 m
  unit missing data:  > 1% of covered returns at the 50 m cap
"""

import argparse
import hashlib
import os
import sys
import zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import units as plan_units  # noqa: E402

SAMPLE = 50_000  # ground returns kept per unit for pooled pair and tile figures
GROUND_C2C_FLAG_M = 0.5
GROUND_HAG_FLAG_M = 0.3
CAPPED_FLAG = 0.01


def unit_metrics(row):
    """check_run.py's step-1 figures for one unit, plus a sample of its ground returns."""
    unit = row["unit"]
    cache = plan_units.UNITS / unit / "cache"
    out = {"unit": unit, "tile": row["tile"], "rank": row["rank"], "area_ha": row["area_ha"]}
    if not (cache / "manifest.json").is_file():
        return {**out, "status": "FAIL", "problems": "no cache"}, None, None, None
    manifest, arrays = canopy.load_cache(cache)
    n = manifest["point_count"]
    valid = np.asarray(arrays["valid"])
    c2c = np.asarray(arrays["c2c"])
    hag = np.asarray(arrays["hag"])
    ground = valid & (np.asarray(arrays["classification"]) == 2)
    cap = manifest["preparation"]["distance"].get("max_search_dist", 0) or np.inf
    covered = int(valid.sum())
    ledger = arrays["coverage"]
    cov = manifest["coverage"]
    covered_columns = int(((np.asarray(ledger["pre_count"]) >= cov["min_pre_returns"])
                           & (np.asarray(ledger["post_count"]) >= cov["min_post_returns"])).sum())
    out.update({
        "points": n, "covered_share": covered / n if n else np.nan,
        "covered_ha": covered_columns / 1e4,
        "bad_distances": int((~np.isfinite(c2c) | (c2c < 0)).sum()),
        "capped_share": float((c2c[valid] >= cap).mean()) if covered else np.nan,
        "no_hag_share": float(np.isnan(hag[valid]).mean()) if covered else np.nan,
        "ground_points": int(ground.sum()),
    })
    g_c2c, g_hag = c2c[ground], hag[ground]
    # Lowest 2018 return in each 2017 ground return's column, minus that return's height:
    # about 0 where both flights reach the ground. A large C2C with dz near 0 means a
    # sideways shift (or no 2018 ground); dz near the C2C means a vertical shift.
    g_dz = np.zeros(0)
    if "post_lowest" in arrays and ground.any():
        rows = np.flatnonzero(ground)
        if len(rows) > 4 * SAMPLE:
            rows = np.sort(np.random.default_rng(zlib.crc32(unit.encode())).choice(rows, 4 * SAMPLE, replace=False))
        xyz = np.asarray(arrays["xyz"][rows])
        keys = canopy.row_keys(np.column_stack((np.asarray(ledger["ix"]), np.asarray(ledger["iy"]))))
        at = np.searchsorted(keys, canopy.row_keys(canopy.xy_cells(xyz, cov["resolution_m"])))
        at = np.minimum(at, len(keys) - 1)
        g_dz = np.asarray(arrays["post_lowest"])[at] - xyz[:, 2]
        g_dz = g_dz[np.isfinite(g_dz)]
        if len(g_dz):
            out["ground_dz_p50"] = float(np.median(g_dz))
    g_hag = g_hag[np.isfinite(g_hag)]
    if len(g_c2c):
        out["ground_c2c_p50"], out["ground_c2c_p95"] = np.percentile(g_c2c, [50, 95])
    if len(g_hag):
        out["ground_hag_p5"], out["ground_hag_p50"], out["ground_hag_p95"] = np.percentile(g_hag, [5, 50, 95])
    problems, warnings = [], []
    if out["bad_distances"]:
        problems.append("missing or negative distances")
    if n and not covered:
        warnings.append("no covered points")
    if len(g_hag) and abs(out["ground_hag_p50"]) >= GROUND_HAG_FLAG_M:
        problems.append("ground height above DTM off by >= 0.3 m")
    if covered and out["capped_share"] > CAPPED_FLAG:
        warnings.append("> 1% of covered returns at the search cap")
    if covered and out["no_hag_share"] > 0.01:
        warnings.append("> 1% of covered returns outside the DTM")
    out["status"] = "FAIL" if problems else "WARN" if warnings else "PASS"
    out["problems"] = "; ".join(problems + warnings)
    rng = np.random.default_rng(zlib.crc32(unit.encode()))  # same sample every run
    pick = lambda a: a[rng.choice(len(a), SAMPLE, replace=False)] if len(a) > SAMPLE else a  # noqa: E731
    return out, pick(g_c2c).astype(np.float32), pick(g_hag).astype(np.float32), pick(g_dz).astype(np.float32)


def pooled(samples, prefix):
    if not len(samples):
        return {}
    p50, p95 = np.percentile(samples, [50, 95])
    return {f"{prefix}_p50": p50, f"{prefix}_p95": p95}


def duplicate_check(plan):
    """No 2017 record in two units, campaign by campaign (keys: file << 40 | record)."""
    lines, ok = [], True
    for campaign, members in plan.groupby("campaign_pre"):
        keys = []
        for unit in members.unit:
            cache = plan_units.UNITS / unit / "cache"
            if not (cache / "manifest.json").is_file():
                continue
            _, arrays = canopy.load_cache(cache)
            keys.append((np.asarray(arrays["source_file"]).astype(np.uint64) << np.uint64(40))
                        | np.asarray(arrays["source_index"]).astype(np.uint64))
        if not keys:
            continue
        keys = np.sort(np.concatenate(keys))
        twice = int((keys[1:] == keys[:-1]).sum())
        ok &= twice == 0
        if twice:
            lines.append(f"FAIL {campaign}: {twice:,} 2017 records in more than one unit")
    lines.append(f"{'PASS' if ok else 'FAIL'} no 2017 record in two units "
                 f"({plan.campaign_pre.nunique()} campaigns checked)")
    return lines


def gap_maps(tiles):
    """Per finished join: each tile's gap area fraction and largest-gap share."""
    import island_gaps

    root = island_gaps.run_dir()
    columns = {}
    for threshold in island_gaps.SETTINGS["thresholds"]:
        name = island_gaps.label(threshold)
        folder = root / "gaps" / name
        if not (folder / "join.json").is_file():
            continue
        node_gap = np.load(folder / "node_gap.npy", mmap_mode="r")
        offsets = pd.read_csv(folder / "nodes.csv").set_index("tile")["offset"]
        fraction, largest = {}, {}
        for tile in tiles:
            voxels = pd.read_parquet(root / "tiles" / tile / name / "voxels.parquet")
            gap = np.asarray(node_gap[offsets[tile] + voxels.label.to_numpy(np.int64) - 1])
            inside = gap > 0
            columns_in_gaps = len(np.unique(voxels.ix.to_numpy()[inside] * 2**32
                                            + voxels.iy.to_numpy()[inside]))
            fraction[tile] = columns_in_gaps
            per_gap = np.bincount(gap[inside]) if inside.any() else np.zeros(1)
            largest[tile] = per_gap.max() / inside.sum() if inside.any() else 0.0
        columns[name] = (fraction, largest)
    return root, columns


def main():
    import geopandas as gpd
    from shapely.geometry import box

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workers", type=int,
                        default=int(os.environ.get("SLURM_CPUS_PER_TASK") or os.cpu_count() or 1))
    args = parser.parse_args()
    plan = plan_units.load_units()
    plan_hash = hashlib.sha256((canopy.PLAN / "plan.json").read_bytes()).hexdigest()
    out = canopy.DATA / "runs" / "canopy" / "qc" / plan_hash[:16]
    out.mkdir(parents=True, exist_ok=True)

    canopy.stamp(f"QC of {len(plan):,} units with {args.workers} workers")
    rows = [r for _, r in plan.iterrows()]
    results = []
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        for i, result in enumerate(pool.map(unit_metrics, rows, chunksize=4), 1):
            results.append(result)
            if i % 200 == 0:
                canopy.stamp(f"{i:,} of {len(rows):,} units")
    units = pd.DataFrame([r[0] for r in results])
    units.to_csv(out / "units.csv", index=False)
    samples = {r[0]["unit"]: (r[1], r[2], r[3]) for r in results if r[1] is not None}

    pairs = pd.read_csv(canopy.PLAN / "pairs.csv")[["rank", "campaign_a", "campaign_b", "block_a", "owned_ha"]]
    pair_rows = []
    for rank, members in units.groupby("rank"):
        c2c = [samples[u][0] for u in members.unit if u in samples]
        hag = [samples[u][1] for u in members.unit if u in samples]
        dz = [samples[u][2] for u in members.unit if u in samples]
        row = {"rank": rank, "units": len(members), "covered_ha": members.covered_ha.sum(),
               "capped_share": np.average(members.capped_share.fillna(0), weights=members.points.fillna(0) + 1e-9),
               **pooled(np.concatenate(c2c) if c2c else np.zeros(0), "ground_c2c"),
               **pooled(np.concatenate(hag) if hag else np.zeros(0), "ground_hag"),
               **pooled(np.concatenate(dz) if dz else np.zeros(0), "ground_dz")}
        flags = []
        if row.get("ground_c2c_p50", 0) > GROUND_C2C_FLAG_M:
            flags.append("registration: ground C2C median > 0.5 m")
        if abs(row.get("ground_hag_p50", 0)) > GROUND_HAG_FLAG_M:
            flags.append("ground height median outside +-0.3 m")
        row["flags"] = "; ".join(flags)
        pair_rows.append(row)
    pair_table = pairs.merge(pd.DataFrame(pair_rows), on="rank", how="right")
    pair_table.to_csv(out / "pairs.csv", index=False)

    tile_rows = []
    for tile, members in units.groupby("tile"):
        c2c = [samples[u][0] for u in members.unit if u in samples]
        hag = [samples[u][1] for u in members.unit if u in samples]
        dz = [samples[u][2] for u in members.unit if u in samples]
        x0, y0 = plan_units.tile_corner(tile)
        tile_rows.append({"tile": tile, "units": len(members), "covered_ha": members.covered_ha.sum(),
                          **pooled(np.concatenate(c2c) if c2c else np.zeros(0), "ground_c2c"),
                          **pooled(np.concatenate(hag) if hag else np.zeros(0), "ground_hag"),
               **pooled(np.concatenate(dz) if dz else np.zeros(0), "ground_dz"),
                          "geometry": box(x0, y0, x0 + plan_units.TILE_M, y0 + plan_units.TILE_M)})
    tiles = gpd.GeoDataFrame(tile_rows, crs=plan_units.UNIT_CRS)
    island_root, maps = gap_maps(list(tiles.tile))
    for name, (fraction, largest) in maps.items():
        tiles[f"gap_fraction_{name}"] = tiles.tile.map(fraction) / (tiles.covered_ha * 1e4)
        tiles[f"largest_gap_share_{name}"] = tiles.tile.map(largest)
    path = out / "tiles.gpkg"
    path.unlink(missing_ok=True)
    tiles.to_file(path, layer="tiles")

    lines = [f"plan {canopy.PLAN} ({plan_hash[:16]}), {len(units):,} units, {len(tiles):,} tiles"]
    counts = units.status.value_counts()
    lines.append(f"{'FAIL' if counts.get('FAIL', 0) else 'PASS'} units: "
                 + ", ".join(f"{counts.get(s, 0):,} {s}" for s in ("PASS", "WARN", "FAIL")))
    for row in units[units.status != "PASS"].head(30).itertuples():
        lines.append(f"   {row.status} {row.unit}: {row.problems}")
    flagged = pair_table[pair_table["flags"].fillna("") != ""]
    lines.append(f"{'FLAG' if len(flagged) else 'PASS'} pair registration: {len(flagged)} of "
                 f"{len(pair_table)} pairs flagged")
    for row in flagged.itertuples():
        lines.append(f"   rank {row.rank} {row.campaign_a} -> {row.campaign_b}: {row.flags} "
                     f"(ground C2C median {row.ground_c2c_p50:.2f} m, height {row.ground_hag_p50:+.2f} m, "
                     f"2018 lowest - 2017 ground {getattr(row, 'ground_dz_p50', float('nan')):+.2f} m)")
    duplicates = duplicate_check(plan)
    lines += duplicates
    lines.append(f"gap maps: {', '.join(maps) or 'none yet'} (island run {island_root.name})")
    lines.append(f"covered {units.covered_ha.sum():,.1f} ha of {units.area_ha.sum():,.1f} ha owned")
    text = "\n".join(lines)
    (out / "checks.txt").write_text(text + "\n", encoding="utf-8")
    canopy.write_json(out / "qc.json", {"plan_sha256": plan_hash, "units": len(units),
                                        "missing_caches": int((units.problems == "no cache").sum()),
                                        "gap_maps": sorted(maps), "island_run": island_root.name,
                                        "commit": os.environ.get("PR_GAPS_CODE_VERSION", "")})
    print(text)
    print(f"wrote {out}")
    # Flags (unit FAILs, flagged pairs) are for review, not a failed run; only a 2017
    # record in two units is. A crash fails on its own.
    failed = not duplicates[-1].startswith("PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

"""Step 2 island-wide: gaps from the unit distance caches, labelled per tile, then joined.

    python python/island_gaps.py voxels --job N       # 2a: each unit's changed voxels, every threshold
    python python/island_gaps.py label --tile TILE    # 2b: gaps within one 1 km tile
    python python/island_gaps.py join --threshold T   # 2c: join across tile edges; gap table, footprints
    python python/island_gaps.py points --job N       # 2d: each changed point's island-wide gap ID
    python python/island_gaps.py run                  # print the run directory and its settings

docs/hpc-scaling-plan.md §4.5. Gaps are defined exactly as in a site run (canopy.py):
changed returns are covered, not class 2/7/18, with distance >= T; they occupy 1 m
voxels on the fixed grid; gaps are 26-connected components of those voxels (canopy's
CONNECTIVITY), numbered by their first voxel in (ix, iy, iz) order; gaps with fewer
than MIN_POINTS changed returns are dropped. The difference is only in how it is
computed:

- 2a writes, per unit and threshold, every changed voxel with sums, minima and maxima
  of what it holds (point count, distances, heights, coordinates), so every gap
  attribute can be combined exactly across tiles.
- 2b labels each tile's voxels (all its units together) but applies no size filter: a
  small piece may belong to a big gap in the next tile. It keeps each label's partial
  sums, its voxels on the tile's outer ring, and its footprint.
- 2c links labels whose ring voxels touch across tile edges or corners (26-connected)
  with union-find, combines their sums, numbers the gaps, and only then filters by size.
- 2d gives every changed point of every unit its gap's island-wide ID.

Not computed island-wide (decided 2026-11-16): the convex-hull volume and gap LAZ.
Added per gap: n_tiles, n_pairs, main_pair_rank, main_pair_share, crosses_pair_border
(measured by more than one flight pair), edge_columns and touches_coverage_edge (gap
columns next to a column without both flights' returns: the gap may be cut off there).

Outputs go to $PR_GAPS_DATA/runs/canopy/island/<run id>/, where the run id hashes the
gap settings and the work-unit plan. Every task writes a done marker last.
"""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import units as plan_units  # noqa: E402

TILE_M = plan_units.TILE_M
THRESHOLDS = [float(t) for t in (os.environ.get("PR_GAPS_ISLAND_THRESHOLDS") or "2,3,4,5").split(",")]
SETTINGS = {
    "analysis": "island_gaps",
    "version": 1,
    "thresholds": sorted(THRESHOLDS),
    "voxel_size": 1.0,
    "grid_origin": [0.0, 0.0, 0.0],
    "connectivity": int(canopy.CONNECTIVITY),
    "min_points": int(canopy.MIN_POINTS),
    "min_volume": float(canopy.MIN_VOLUME),
    "min_voxel_points": int(canopy.MIN_VOXEL_POINTS),
    "exclude_classes": sorted(int(c) for c in canopy.EXCLUDE_CLASSES),
}
# What each changed voxel carries (2a), and each tile label's partial sums (2b).
VOXEL_COLUMNS = ["ix", "iy", "iz", "n", "sum_c2c", "max_c2c", "n_hag", "sum_hag", "min_hag",
                 "max_hag", "sx", "sy", "sz"]
GAP_COLUMNS = [
    "object_id", "footprint_area_m2", "voxel_volume_m3", "n_points", "n_voxels",
    "volume_centroid_x", "volume_centroid_y", "volume_centroid_z",
    "point_centroid_x", "point_centroid_y", "point_centroid_z",
    "xmin", "xmax", "ymin", "ymax", "zmin", "zmax",
    "mean_c2c_m", "max_c2c_m", "mean_hag_m", "min_hag_m", "max_hag_m",
    "n_tiles", "n_pairs", "main_pair_rank", "main_pair_share", "crosses_pair_border",
    "edge_columns", "touches_coverage_edge",
]


# ------------------------------------------------------------------ the run

def plan_hash():
    return hashlib.sha256((canopy.PLAN / "plan.json").read_bytes()).hexdigest()


def run_dir():
    run_id = canopy.stable_id({"settings": SETTINGS, "plan": plan_hash()})[:16]
    return canopy.DATA / "runs" / "canopy" / "island" / run_id


def ensure_run():
    root = run_dir()
    root.mkdir(parents=True, exist_ok=True)
    if not (root / "run.json").is_file():
        canopy.write_json(root / "run.json", {
            "settings": SETTINGS, "plan": str(canopy.PLAN), "plan_sha256": plan_hash(),
            "measurement": canopy.MEASUREMENT,
            "not_computed": ["gap_volume_m3 (convex hull)", "gap LAZ"],
        })
    return root


def label(threshold):
    return f"{threshold:g}m"


def commit():
    return os.environ.get("PR_GAPS_CODE_VERSION", "")


def done(path, **expected):
    """A done marker exists and records the expected values."""
    if not path.is_file():
        return False
    marker = canopy.read_json(path)
    return all(marker.get(key) == value for key, value in expected.items())


# ------------------------------------------------------------------ 2a: unit voxels

def changed_points(arrays):
    """Rows, voxels, distances, heights and coordinates of points at or above the lowest threshold."""
    eligible = canopy._eligibility(arrays, SETTINGS["exclude_classes"], None)
    distances = np.asarray(arrays["c2c"])
    rows = np.flatnonzero(eligible & (distances >= min(THRESHOLDS)))
    xyz = np.asarray(arrays["xyz"][rows])
    voxels = canopy.fixed_voxel_indices(xyz, SETTINGS["voxel_size"], SETTINGS["grid_origin"])
    return rows, voxels, distances[rows], np.asarray(arrays["hag"][rows], dtype=np.float64), xyz


def voxel_table(voxels, distances, heights, xyz, corner):
    """One row per occupied voxel with the sums, minima and maxima of its points."""
    if not len(voxels):
        return pd.DataFrame({c: np.zeros(0) for c in VOXEL_COLUMNS})
    keys, inverse = np.unique(canopy.row_keys(np.ascontiguousarray(voxels)), return_inverse=True)
    inverse = inverse.ravel()
    occupied = keys.view(np.int64).reshape(-1, 3)
    m = len(occupied)
    finite = np.isfinite(heights)
    table = {"ix": occupied[:, 0], "iy": occupied[:, 1], "iz": occupied[:, 2],
             "n": np.bincount(inverse, minlength=m).astype(np.int64),
             "sum_c2c": np.bincount(inverse, weights=distances, minlength=m),
             "max_c2c": canopy._reduce_max(distances, inverse, m),
             "n_hag": np.bincount(inverse[finite], minlength=m).astype(np.int64),
             "sum_hag": np.bincount(inverse[finite], weights=heights[finite], minlength=m)}
    high = canopy._reduce_max(heights[finite], inverse[finite], m)
    low = -canopy._reduce_max(-heights[finite], inverse[finite], m)
    table["min_hag"] = np.where(table["n_hag"] > 0, low, np.nan)
    table["max_hag"] = np.where(table["n_hag"] > 0, high, np.nan)
    # Coordinates from the tile corner, so sums of millions of points stay precise.
    for axis, name in enumerate(("sx", "sy", "sz")):
        table[name] = np.bincount(inverse, weights=xyz[:, axis] - corner[axis], minlength=m)
    return pd.DataFrame(table)[VOXEL_COLUMNS]


def unit_voxels(root, unit):
    cache = plan_units.UNITS / unit.unit / "cache"
    manifest, arrays = canopy.load_cache(cache)
    out = root / "units" / unit.unit
    out.mkdir(parents=True, exist_ok=True)
    corner = (*plan_units.tile_corner(unit.tile), 0.0)
    rows, voxels, distances, heights, xyz = changed_points(arrays)
    counts = {}
    for threshold in THRESHOLDS:
        m = distances >= threshold
        table = voxel_table(voxels[m], distances[m], heights[m], xyz[m], corner)
        table.to_parquet(out / f"voxels_{label(threshold)}.parquet", index=False)
        counts[label(threshold)] = {"voxels": len(table), "points": int(table.n.sum())}
    ledger = arrays["coverage"]
    covered = ((np.asarray(ledger["pre_count"]) >= manifest["coverage"]["min_pre_returns"])
               & (np.asarray(ledger["post_count"]) >= manifest["coverage"]["min_post_returns"]))
    pd.DataFrame({"ix": np.asarray(ledger["ix"])[covered],
                  "iy": np.asarray(ledger["iy"])[covered]}).to_parquet(
        out / "coverage.parquet", index=False)
    canopy.write_json(out / "voxels.json", {
        "cache_id": manifest["cache_id"], "thresholds": SETTINGS["thresholds"],
        "counts": counts, "covered_columns": int(covered.sum()), "commit": commit()})
    return counts


def unit_voxels_done(root, unit):
    manifest = plan_units.UNITS / unit.unit / "cache" / "manifest.json"
    if not manifest.is_file():
        return False
    return done(root / "units" / unit.unit / "voxels.json",
                cache_id=canopy.read_json(manifest)["cache_id"], thresholds=SETTINGS["thresholds"])


# ------------------------------------------------------------------ 2b: tile labels

def outline(columns):
    """Footprint polygon of a set of (ix, iy) columns."""
    from rasterio import features
    from rasterio.transform import from_origin
    from shapely.geometry import shape
    from shapely.ops import unary_union

    x0, y0, y1 = columns[:, 0].min(), columns[:, 1].min(), columns[:, 1].max()
    mask = np.zeros((y1 - y0 + 1, columns[:, 0].max() - x0 + 1), np.uint8)
    mask[y1 - columns[:, 1], columns[:, 0] - x0] = 1
    transform = from_origin(float(x0), float(y1 + 1), 1.0, 1.0)
    return unary_union([shape(g) for g, _ in features.shapes(mask, mask=mask > 0, transform=transform)])


def covered_keys(root, tile, plan):
    """Sorted keys of covered columns in the tile and its 8 neighbours."""
    x0, y0 = plan_units.tile_corner(tile)
    near = {f"E{(x0 // TILE_M) + dx:04d}_N{(y0 // TILE_M) + dy:04d}"
            for dx in (-1, 0, 1) for dy in (-1, 0, 1)}
    parts = [pd.read_parquet(root / "units" / u / "coverage.parquet")
             for u in plan.loc[plan.tile.isin(near), "unit"]
             if (root / "units" / u / "coverage.parquet").is_file()]
    if not parts:
        return np.zeros(0, np.int64)
    columns = pd.concat(parts)
    return np.unique(columns.ix.to_numpy(np.int64) * 2**32 + columns.iy.to_numpy(np.int64))


def label_tile(root, tile, plan):
    import geopandas as gpd

    members = plan[plan.tile == tile]
    x0, y0 = plan_units.tile_corner(tile)
    covered = covered_keys(root, tile, plan)
    for threshold in THRESHOLDS:
        out = root / "tiles" / tile / label(threshold)
        out.mkdir(parents=True, exist_ok=True)
        parts = []
        for unit in members.itertuples():
            table = pd.read_parquet(root / "units" / unit.unit / f"voxels_{label(threshold)}.parquet")
            table["rank"] = unit.rank
            parts.append(table)
        voxels = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame(columns=VOXEL_COLUMNS + ["rank"])
        voxels = voxels[voxels.n >= SETTINGS["min_voxel_points"]]
        voxels = voxels.sort_values(["ix", "iy", "iz"], kind="mergesort").reset_index(drop=True)
        occupied = voxels[["ix", "iy", "iz"]].to_numpy(np.int64)
        # label_voxels refuses unsorted or repeated voxels: a voxel in two units would
        # mean a column owned twice.
        ids = canopy.label_voxels(occupied, SETTINGS["connectivity"]).astype(np.int64)
        voxels["label"] = ids
        k = int(ids.max()) if len(ids) else 0
        g = ids - 1
        # Per label: the partial sums a join combines exactly.
        sums = {"label": np.arange(1, k + 1)}
        for name in ("n", "sum_c2c", "n_hag", "sum_hag", "sx", "sy", "sz"):
            sums[name] = np.bincount(g, weights=voxels[name].to_numpy(np.float64), minlength=k)
        sums["n_voxels"] = np.bincount(g, minlength=k)
        for axis, name in (("ix", x0), ("iy", y0), ("iz", 0)):
            sums[f"sum_{axis}"] = np.bincount(g, weights=voxels[axis].to_numpy(np.float64) - name, minlength=k)
            low = np.full(k, np.iinfo(np.int64).max)
            high = np.full(k, np.iinfo(np.int64).min)
            np.minimum.at(low, g, voxels[axis].to_numpy(np.int64))
            np.maximum.at(high, g, voxels[axis].to_numpy(np.int64))
            sums[f"{axis}_min"], sums[f"{axis}_max"] = low, high
        sums["max_c2c"] = canopy._reduce_max(voxels.max_c2c.to_numpy(np.float64), g, k)
        hag_low, hag_high = np.full(k, np.inf), np.full(k, -np.inf)
        finite = voxels.n_hag.to_numpy() > 0
        np.minimum.at(hag_low, g[finite], voxels.min_hag.to_numpy(np.float64)[finite])
        np.maximum.at(hag_high, g[finite], voxels.max_hag.to_numpy(np.float64)[finite])
        sums["min_hag"], sums["max_hag"] = hag_low, hag_high
        # First voxel in (ix, iy, iz) order: labels are numbered by it, so it is the
        # first row of each label in this sorted table.
        first = np.full(k, len(voxels), np.int64)
        np.minimum.at(first, g, np.arange(len(voxels)))
        for axis in ("ix", "iy", "iz"):
            sums[f"first_{axis}"] = voxels[axis].to_numpy(np.int64)[first] if k else np.zeros(0, np.int64)
        # Footprint columns, and those next to uncovered ground.
        columns = np.unique(np.column_stack((g, voxels.ix, voxels.iy)).astype(np.int64), axis=0) \
            if k else np.zeros((0, 3), np.int64)
        sums["n_columns"] = np.bincount(columns[:, 0], minlength=k)
        edge = np.zeros(len(columns), bool)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if dx or dy:
                    keys = (columns[:, 1] + dx) * 2**32 + (columns[:, 2] + dy)
                    at = np.searchsorted(covered, keys)
                    inside = at < len(covered)
                    hit = np.zeros(len(keys), bool)
                    hit[inside] = covered[at[inside]] == keys[inside]
                    edge |= ~hit
        sums["edge_columns"] = np.bincount(columns[:, 0], weights=edge, minlength=k)
        labels = pd.DataFrame(sums)
        labels.to_parquet(out / "labels.parquet", index=False)
        # Points per flight pair, so a joined gap knows which pairs measured it.
        voxels.groupby(["label", "rank"], as_index=False).n.sum().to_parquet(
            out / "pairs.parquet", index=False)
        ring = ((voxels.ix == x0) | (voxels.ix == x0 + TILE_M - 1)
                | (voxels.iy == y0) | (voxels.iy == y0 + TILE_M - 1))
        voxels.loc[ring, ["ix", "iy", "iz", "label"]].to_parquet(out / "edges.parquet", index=False)
        voxels[["ix", "iy", "iz", "label"]].to_parquet(out / "voxels.parquet", index=False)
        # Footprints only of labels that can be part of a kept gap: big enough alone, or
        # touching the ring (and so possibly joined to more).
        on_ring = np.zeros(k, bool)
        on_ring[voxels.label[ring].to_numpy() - 1] = True
        # Columns of labels that may join others. Two labels of one tile can share a
        # column (at different heights) and still end up in one gap through another
        # tile, so the join counts such gaps' columns from these, not from n_columns.
        joinable = on_ring[columns[:, 0]]
        pd.DataFrame({"label": columns[joinable, 0] + 1, "ix": columns[joinable, 1],
                      "iy": columns[joinable, 2], "edge": edge[joinable]}).to_parquet(
            out / "columns.parquet", index=False)
        wanted = (labels.n.to_numpy() >= SETTINGS["min_points"]) | on_ring
        blocks = np.split(columns, np.flatnonzero(np.diff(columns[:, 0])) + 1) if len(columns) else []
        pieces = {int(block[0, 0]) + 1: outline(block[:, 1:]) for block in blocks if wanted[block[0, 0]]}
        gpd.GeoDataFrame({"label": list(pieces)}, geometry=list(pieces.values()),
                         crs=plan_units.UNIT_CRS).to_parquet(out / "footprints.parquet", index=False)
    canopy.write_json(root / "tiles" / tile / "label.json", {
        "thresholds": SETTINGS["thresholds"], "units": list(members.unit), "commit": commit(),
        "unit_caches": {u: canopy.read_json(root / "units" / u / "voxels.json")["cache_id"]
                        for u in members.unit}})


def label_done(root, tile, plan):
    marker = root / "tiles" / tile / "label.json"
    if not marker.is_file():
        return False
    members = plan.loc[plan.tile == tile, "unit"]
    caches = canopy.read_json(marker).get("unit_caches", {})
    return all(u in caches and done(root / "units" / u / "voxels.json", cache_id=caches[u])
               for u in members)


# ------------------------------------------------------------------ 2c: join

def join(root, threshold, plan):
    import geopandas as gpd
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components

    name = label(threshold)
    tiles = sorted(plan.tile.unique())
    missing = [t for t in tiles if not label_done(root, t, plan)]
    if missing:
        raise SystemExit(f"{len(missing)} tiles not labelled yet, e.g. {missing[:3]}")
    canopy.stamp(f"join {name}: reading {len(tiles)} tiles")
    tables, offsets, offset = [], {}, 0
    for index, tile in enumerate(tiles):
        table = pd.read_parquet(root / "tiles" / tile / name / "labels.parquet")
        table["tile"] = index
        x0, y0 = plan_units.tile_corner(tile)
        table["x0"], table["y0"] = x0, y0
        offsets[tile] = offset
        offset += len(table)
        tables.append(table)
    nodes = pd.concat(tables, ignore_index=True)
    n = len(nodes)

    # Ring voxels of all tiles; a link wherever two of different tiles are 26-neighbours.
    rings = []
    for tile in tiles:
        ring = pd.read_parquet(root / "tiles" / tile / name / "edges.parquet")
        ring["node"] = offsets[tile] + ring.label.to_numpy(np.int64) - 1
        rings.append(ring)
    ring = pd.concat(rings, ignore_index=True).sort_values(["ix", "iy", "iz"], kind="mergesort")
    cells = ring[["ix", "iy", "iz"]].to_numpy(np.int64)
    node = ring.node.to_numpy(np.int64)
    tile_of = nodes.tile.to_numpy()[node]
    source, target = canopy.voxel_edges(cells, SETTINGS["connectivity"])
    across = tile_of[source] != tile_of[target]
    a, b = node[source[across]], node[target[across]]
    canopy.stamp(f"join {name}: {n:,} tile labels, {len(a):,} links across tile edges")
    graph = coo_matrix((np.ones(len(a), np.uint8), (a, b)), shape=(n, n)).tocsr()
    _, component = connected_components(graph, directed=False)

    # Combine partial sums per joined gap.
    count = int(component.max()) + 1 if n else 0
    add = lambda col: np.bincount(component, weights=nodes[col].to_numpy(np.float64), minlength=count)  # noqa: E731
    gap = {"n_points": add("n"), "n_voxels": add("n_voxels"), "n_columns": add("n_columns"),
           "sum_c2c": add("sum_c2c"), "n_hag": add("n_hag"), "sum_hag": add("sum_hag"),
           "edge_columns": add("edge_columns"),
           "n_tiles": np.bincount(component, minlength=count)}
    for col, how in (("max_c2c", np.maximum), ("max_hag", np.maximum), ("min_hag", np.minimum),
                     ("ix_min", np.minimum), ("iy_min", np.minimum), ("iz_min", np.minimum),
                     ("ix_max", np.maximum), ("iy_max", np.maximum), ("iz_max", np.maximum)):
        values = nodes[col].to_numpy(np.float64)
        result = np.full(count, np.inf if how is np.minimum else -np.inf)
        how.at(result, component, values)
        gap[col] = result
    # Each gap's reference corner: its first node's tile. Coordinate sums are moved
    # to it, so they stay small and precise.
    first_node = np.full(count, n, np.int64)
    np.minimum.at(first_node, component, np.arange(n))
    ref_x = nodes.x0.to_numpy(np.float64)[first_node][component]
    ref_y = nodes.y0.to_numpy(np.float64)[first_node][component]
    dx = nodes.x0.to_numpy(np.float64) - ref_x
    dy = nodes.y0.to_numpy(np.float64) - ref_y
    npts, nvox = nodes.n.to_numpy(np.float64), nodes.n_voxels.to_numpy(np.float64)
    point_x = np.bincount(component, weights=nodes.sx.to_numpy() + npts * dx, minlength=count)
    point_y = np.bincount(component, weights=nodes.sy.to_numpy() + npts * dy, minlength=count)
    point_z = np.bincount(component, weights=nodes.sz.to_numpy(), minlength=count)
    cell_x = np.bincount(component, weights=nodes.sum_ix.to_numpy() + nvox * dx, minlength=count)
    cell_y = np.bincount(component, weights=nodes.sum_iy.to_numpy() + nvox * dy, minlength=count)
    cell_z = np.bincount(component, weights=nodes.sum_iz.to_numpy(), minlength=count)
    corner_x = nodes.x0.to_numpy(np.float64)[first_node]
    corner_y = nodes.y0.to_numpy(np.float64)[first_node]

    # Number gaps by their first voxel, as canopy.py does, then filter by size.
    order = np.lexsort((nodes.first_iz.to_numpy(), nodes.first_iy.to_numpy(),
                        nodes.first_ix.to_numpy(), component))
    lead = order[np.concatenate(([True], np.diff(component[order]) != 0))] if n else order
    gap_first = np.column_stack((nodes.first_ix.to_numpy()[lead], nodes.first_iy.to_numpy()[lead],
                                 nodes.first_iz.to_numpy()[lead]))
    keep = (gap["n_points"] >= SETTINGS["min_points"]) & (gap["n_voxels"] >= SETTINGS["min_volume"])
    numbering = np.lexsort(gap_first.T[::-1])
    numbering = numbering[keep[numbering]]
    gap_id = np.zeros(count, np.uint32)
    gap_id[numbering] = np.arange(1, len(numbering) + 1, dtype=np.uint32)
    node_gap = gap_id[component]

    # Gaps of several labels: count distinct columns (labels may share columns).
    multi = gap["n_tiles"] > 1
    if multi.any():
        parts = []
        for tile in tiles:
            part = pd.read_parquet(root / "tiles" / tile / name / "columns.parquet")
            part["gap"] = component[offsets[tile] + part.label.to_numpy(np.int64) - 1]
            parts.append(part[multi[part.gap.to_numpy()]])
        columns = pd.concat(parts, ignore_index=True).drop_duplicates(["gap", "ix", "iy"])
        recount = columns.groupby("gap").agg(n=("ix", "size"), edge=("edge", "sum"))
        gap["n_columns"][recount.index.to_numpy()] = recount.n.to_numpy()
        gap["edge_columns"][recount.index.to_numpy()] = recount.edge.to_numpy()

    # Flight pairs per gap.
    pairs = []
    for tile in tiles:
        part = pd.read_parquet(root / "tiles" / tile / name / "pairs.parquet")
        part["node"] = offsets[tile] + part.label.to_numpy(np.int64) - 1
        pairs.append(part)
    pairs = pd.concat(pairs, ignore_index=True)
    pairs["gap"] = component[pairs.node.to_numpy()]
    by_pair = pairs.groupby(["gap", "rank"], as_index=False).n.sum()
    by_pair = by_pair.sort_values(["gap", "n", "rank"], ascending=[True, False, True])
    main = by_pair.drop_duplicates("gap").set_index("gap")
    n_pairs = by_pair.groupby("gap").size()

    k = numbering
    ids = gap_id[k]
    table = pd.DataFrame({
        "object_id": ids,
        "footprint_area_m2": gap["n_columns"][k],
        "voxel_volume_m3": gap["n_voxels"][k],
        "n_points": gap["n_points"][k].astype(np.int64),
        "n_voxels": gap["n_voxels"][k].astype(np.int64),
        "volume_centroid_x": corner_x[k] + cell_x[k] / gap["n_voxels"][k] + 0.5,
        "volume_centroid_y": corner_y[k] + cell_y[k] / gap["n_voxels"][k] + 0.5,
        "volume_centroid_z": cell_z[k] / gap["n_voxels"][k] + 0.5,
        "point_centroid_x": corner_x[k] + point_x[k] / gap["n_points"][k],
        "point_centroid_y": corner_y[k] + point_y[k] / gap["n_points"][k],
        "point_centroid_z": point_z[k] / gap["n_points"][k],
        "xmin": gap["ix_min"][k], "xmax": gap["ix_max"][k] + 1,
        "ymin": gap["iy_min"][k], "ymax": gap["iy_max"][k] + 1,
        "zmin": gap["iz_min"][k], "zmax": gap["iz_max"][k] + 1,
        "mean_c2c_m": gap["sum_c2c"][k] / gap["n_points"][k],
        "max_c2c_m": gap["max_c2c"][k],
        "mean_hag_m": np.where(gap["n_hag"][k] > 0, gap["sum_hag"][k] / np.maximum(gap["n_hag"][k], 1), np.nan),
        "min_hag_m": np.where(gap["n_hag"][k] > 0, gap["min_hag"][k], np.nan),
        "max_hag_m": np.where(gap["n_hag"][k] > 0, gap["max_hag"][k], np.nan),
        "n_tiles": gap["n_tiles"][k],
        "n_pairs": n_pairs.reindex(k).to_numpy(),
        "main_pair_rank": main["rank"].reindex(k).to_numpy(),
        "main_pair_share": (main["n"].reindex(k).to_numpy() / gap["n_points"][k]),
        "edge_columns": gap["edge_columns"][k].astype(np.int64),
    })
    table["crosses_pair_border"] = table.n_pairs > 1
    table["touches_coverage_edge"] = table.edge_columns > 0
    table = table[GAP_COLUMNS]

    out = root / "gaps" / name
    out.mkdir(parents=True, exist_ok=True)
    table.to_parquet(out / "gaps.parquet", index=False)
    np.save(out / "node_gap.npy", node_gap, allow_pickle=False)
    pd.DataFrame({"tile": tiles, "offset": [offsets[t] for t in tiles]}).to_csv(out / "nodes.csv", index=False)

    # Footprints, dissolved across tiles, one GeoPackage per 2017 campaign block.
    canopy.stamp(f"join {name}: {len(table):,} gaps; footprints")
    pieces = []
    for tile in tiles:
        part = gpd.read_parquet(root / "tiles" / tile / name / "footprints.parquet")
        part["gap"] = node_gap[offsets[tile] + part.label.to_numpy(np.int64) - 1]
        pieces.append(part[part.gap > 0])
    pieces = pd.concat(pieces, ignore_index=True)
    single = pieces.groupby("gap").gap.transform("size") == 1
    shapes = pd.concat([pieces[single].set_index("gap").geometry,
                        pieces[~single].dissolve(by="gap").geometry]).sort_index()
    blocks = pd.read_csv(canopy.PLAN / "pairs.csv").set_index("rank")["block_a"]
    footprints = gpd.GeoDataFrame(table.reset_index(drop=True),
                                  geometry=shapes.reindex(table.object_id.to_numpy()).to_numpy(),
                                  crs=plan_units.UNIT_CRS)
    footprints["block"] = blocks.reindex(footprints.main_pair_rank.to_numpy()).to_numpy()
    (out / "footprints").mkdir(exist_ok=True)
    for block, part in footprints.groupby("block"):
        path = out / "footprints" / f"{block}.gpkg"
        path.unlink(missing_ok=True)
        part.drop(columns="block").to_file(path, layer="footprints")

    # Conservation: every changed point and voxel of every unit is in some tile label.
    unit_points = sum(canopy.read_json(root / "units" / u / "voxels.json")["counts"][name]["points"]
                      for u in plan.unit)
    label_points = int(nodes.n.sum())
    if unit_points != label_points:
        raise RuntimeError(f"{name}: units hold {unit_points:,} changed points, tile labels {label_points:,}")
    volume = table.voxel_volume_m3.to_numpy()
    summary = {"threshold_m": threshold, "n_components": int(len(table)),
               "n_changed_points": int(table.n_points.sum()), "n_voxels": int(table.n_voxels.sum()),
               "voxel_volume_m3": float(volume.sum()),
               "largest_gap_voxel_share": float(volume.max() / volume.sum()) if len(volume) else 0.0,
               "n_crossing_tiles": int((table.n_tiles > 1).sum()),
               "n_crossing_pairs": int(table.crosses_pair_border.sum()),
               "n_touching_coverage_edge": int(table.touches_coverage_edge.sum()),
               "changed_points_before_size_filter": label_points}
    pd.DataFrame([summary]).to_csv(out / "summary.csv", index=False)
    canopy.write_json(out / "join.json", {**summary, "commit": commit()})
    return summary


# ------------------------------------------------------------------ 2d: point labels

def unit_points(root, unit):
    manifest, arrays = canopy.load_cache(plan_units.UNITS / unit.unit / "cache")
    rows, voxels, distances, _, _ = changed_points(arrays)
    out = root / "units" / unit.unit
    for threshold in THRESHOLDS:
        name = label(threshold)
        nodes = pd.read_csv(root / "gaps" / name / "nodes.csv").set_index("tile")["offset"]
        node_gap = np.load(root / "gaps" / name / "node_gap.npy", mmap_mode="r")
        tile_voxels = pd.read_parquet(root / "tiles" / unit.tile / name / "voxels.parquet")
        keys = canopy.row_keys(tile_voxels[["ix", "iy", "iz"]].to_numpy(np.int64))
        order = np.argsort(keys)
        keys, tile_label = keys[order], tile_voxels.label.to_numpy(np.int64)[order]
        m = distances >= threshold
        point_keys = canopy.row_keys(np.ascontiguousarray(voxels[m]))
        at = np.searchsorted(keys, point_keys)
        found = at < len(keys)
        found[found] = keys[at[found]] == point_keys[found]
        labels = np.zeros(manifest["point_count"], np.uint32)
        ids = np.zeros(len(point_keys), np.uint32)
        ids[found] = node_gap[nodes[unit.tile] + tile_label[at[found]] - 1]
        labels[rows[m]] = ids
        np.save(out / f"labels_{name}.npy", labels, allow_pickle=False)
    canopy.write_json(out / "points.json", {"cache_id": manifest["cache_id"], "commit": commit(),
                                            "thresholds": SETTINGS["thresholds"]})


def unit_points_done(root, unit):
    joined = all((root / "gaps" / label(t) / "join.json").is_file() for t in THRESHOLDS)
    return joined and done(root / "units" / unit.unit / "points.json", thresholds=SETTINGS["thresholds"])


# ------------------------------------------------------------------ CLI

def for_job(job, work, plan):
    selected = plan[plan.job == int(job)]
    failed = []
    for unit in selected.itertuples(index=False):
        unit = pd.Series(unit._asdict())
        try:
            work(unit)
            canopy.stamp(f"unit {unit.unit}: done")
        except Exception:  # log, carry on with the job's other units
            import traceback

            traceback.print_exc()
            failed.append(unit.unit)
            canopy.stamp(f"unit {unit.unit}: FAILED")
    canopy.stamp(f"{len(selected) - len(failed)} of {len(selected)} units done")
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("stage", choices=["voxels", "label", "join", "points", "run"])
    parser.add_argument("--job", type=int)
    parser.add_argument("--tile")
    parser.add_argument("--threshold", type=float)
    args = parser.parse_args()
    plan = plan_units.load_units()
    root = ensure_run()
    if args.stage == "run":
        print(root)
        print(json.dumps(SETTINGS, indent=2))
        return 0
    if args.stage == "voxels":
        return for_job(args.job, lambda u: unit_voxels(root, u), plan)
    if args.stage == "points":
        return for_job(args.job, lambda u: unit_points(root, u), plan)
    if args.stage == "label":
        label_tile(root, args.tile, plan)
        canopy.stamp(f"tile {args.tile}: labelled")
        return 0
    summary = join(root, args.threshold, plan)
    canopy.stamp(f"join {label(args.threshold)}: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

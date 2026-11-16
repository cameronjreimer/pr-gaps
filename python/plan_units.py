"""Plan the island-wide work units: one 2017 -> 2018 pair per 1 m column, cut into 1 km tiles.

    python python/plan_units.py                         # Maria pairs, default ranking (D3)
    python python/plan_units.py --rank=-same_block,-overlap_ha,days_between
    python python/plan_units.py --job-ha 200       # bigger array tasks (default ~100 ha each)
    python python/plan_units.py --out DIR --force

hpc-scaling-plan.md §4.1. Every pair (>= --min-overlap-ha in the inventory) gets the
overlap of its two campaigns' exact CHM footprints. Pairs are ranked (D3), and each 1 m
column goes to the highest-ranked pair whose overlap contains the column's centre, so
the pieces never overlap and leave nothing covered unassigned. A work unit is one 1 km
tile x one pair.

Units are packed into array tasks of about --job-ha hectares (the `job` column), so the
many small units at coverage edges don't each cost a job.

Columns are the same cells canopy.py uses for coverage (floor(x), floor(y) in
EPSG:32620), and tiles are whole kilometres in that CRS, so a 2017 point belongs to
exactly one unit: the one owning its column. The ownership rasters are the rule; the
unit polygons are drawn from them, for maps.

Writes to --out (default $PR_GAPS_PLAN, else $PR_GAPS_DATA/interim/work_units/):
  work_units.csv   the job list: unit id, job (Slurm array index), tile, pair, campaigns,
                   area, cell bounds
  pairs.csv        every pair with its rank, overlap and owned area
  work_units.gpkg  layers units, tiles, pairs (owned pieces)
  ownership/<tile>.tif   uint16 pair rank per 1 m column (0 = no pair)
  plan.json        settings, inventory signatures and totals

Ranking keys are columns of pairs.csv, "-" for descending; ties fall through to the next
key and finally to the campaign names, so the plan is deterministic. Changing the
ranking only changes which units exist; rerunning takes minutes.
"""

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
import rasterio
from rasterio.features import rasterize, shapes
from rasterio.transform import from_origin
from shapely import STRtree, box, clip_by_rect, get_parts, make_valid
from shapely.geometry import shape
from shapely.ops import unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import PLAN, REPO  # noqa: E402

INVENTORY = REPO / "derived" / "inventory"
FOOTPRINTS = INVENTORY / "pr_footprints_chm.gpkg"
PAIRS = INVENTORY / "pr_repeat_campaign_pairs.csv"
CAMPAIGNS = INVENTORY / "pr_campaigns.csv"
LAS_CRS = "EPSG:32620"
TILE_M = 1000  # whole metres, so 1 m columns and voxels never straddle a tile edge
CELL_M = 1  # canopy.py's COVERAGE_RESOLUTION and VOXEL_SIZE
DEFAULT_RANK = "-same_block,-overlap_ha,days_between"
SLIVER_HA = 1.0


def signature(path):
    return {"path": str(path.relative_to(REPO)), "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def polygons_only(geometry):
    geometry = make_valid(geometry)
    return unary_union([part for part in get_parts(geometry)
                        if part.geom_type in ("Polygon", "MultiPolygon")])


def load_pairs(min_overlap_ha, epochs):
    pairs = pd.read_csv(PAIRS)
    pairs = pairs[(pairs.epoch_a == epochs[0]) & (pairs.epoch_b == epochs[1])
                  & (pairs.overlap_ha >= min_overlap_ha)].copy()
    blocks = pd.read_csv(CAMPAIGNS).set_index("campaign")["block"]
    pairs["block_a"] = pairs.campaign_a.map(blocks)
    pairs["block_b"] = pairs.campaign_b.map(blocks)
    pairs["same_block"] = (pairs.block_a == pairs.block_b).astype(int)
    pairs = pairs.rename(columns={"overlap_ha": "overlap_ha_inventory"})
    return pairs.reset_index(drop=True)


def pair_overlaps(pairs):
    """Exact CHM-footprint overlap of each pair, in the LAS CRS."""
    footprints = gpd.read_file(FOOTPRINTS, layer="campaign_footprints_chm").to_crs(LAS_CRS)
    campaigns = set(pairs.campaign_a) | set(pairs.campaign_b)
    missing = campaigns - set(footprints.campaign)
    if missing:
        raise SystemExit(f"No CHM footprint for {len(missing)} campaigns, e.g. "
                         f"{sorted(missing)[:3]}; run the inventory with --refine first")
    footprint = {name: polygons_only(rows.geometry.union_all())
                 for name, rows in footprints[footprints.campaign.isin(campaigns)].groupby("campaign")}
    return [polygons_only(footprint[a].intersection(footprint[b]))
            for a, b in zip(pairs.campaign_a, pairs.campaign_b)]


def rank_pairs(pairs, keys):
    columns, ascending = [], []
    for key in keys:
        name = key.lstrip("-")
        if name not in pairs.columns:
            raise SystemExit(f"Unknown ranking key {name!r}; choose from {', '.join(pairs.columns)}")
        columns.append(name)
        ascending.append(not key.startswith("-"))
    columns += ["campaign_a", "campaign_b"]
    ascending += [True, True]
    ranked = pairs.sort_values(columns, ascending=ascending, kind="mergesort").reset_index(drop=True)
    ranked.insert(0, "rank", np.arange(1, len(ranked) + 1, dtype=np.uint16))
    return ranked


def tile_id(x, y):
    return f"E{x // TILE_M:04d}_N{y // TILE_M:04d}"


def tiles_touching(geometries):
    """Lower-left corners of the 1 km tiles any geometry's bounding box touches."""
    corners = set()
    for geometry in geometries:
        if geometry.is_empty:
            continue
        xmin, ymin, xmax, ymax = geometry.bounds
        for x in range(int(xmin // TILE_M), int(np.ceil(xmax / TILE_M))):
            for y in range(int(ymin // TILE_M), int(np.ceil(ymax / TILE_M))):
                corners.add((x * TILE_M, y * TILE_M))
    return sorted(corners)


def own_tile(x0, y0, ranked, overlaps, tree):
    """uint16 rank per column of one tile: the best-ranked pair whose overlap holds its centre."""
    size = TILE_M // CELL_M
    transform = from_origin(x0, y0 + TILE_M, CELL_M, CELL_M)
    owner = np.zeros((size, size), np.uint16)
    for index in sorted(tree.query(box(x0, y0, x0 + TILE_M, y0 + TILE_M))):
        piece = clip_by_rect(overlaps[index], x0, y0, x0 + TILE_M, y0 + TILE_M)
        if piece.is_empty or piece.area == 0:
            continue
        inside = rasterize([(piece, 1)], out_shape=owner.shape, transform=transform,
                           fill=0, dtype=np.uint8, all_touched=False).astype(bool)
        owner[inside & (owner == 0)] = ranked["rank"].iat[index]
    return owner, transform


def pack_jobs(units, job_ha):
    """Slurm array index per unit: units in pair then tile order, filled up to job_ha each.

    Keeping a pair's units together means a job reads one 2017 campaign and neighbouring
    2018 buckets. A unit larger than job_ha (a full tile is 100 ha) gets a job of its own.
    """
    order = units.sort_values(["rank", "tile"]).index
    jobs, job, filled = pd.Series(0, index=units.index), 0, 0.0
    for index in order:
        area = units.at[index, "area_ha"]
        if job == 0 or filled + area > job_ha:
            job, filled = job + 1, 0.0
        jobs[index] = job
        filled += area
    return jobs


def write_ownership(path, owner, transform):
    profile = {"driver": "GTiff", "width": owner.shape[1], "height": owner.shape[0], "count": 1,
               "dtype": "uint16", "crs": LAS_CRS, "transform": transform, "nodata": 0,
               "compress": "deflate", "tiled": True, "blockxsize": 256, "blockysize": 256}
    with rasterio.open(path, "w", **profile) as stream:
        stream.write(owner, 1)


def replace_directory(new, destination):
    """Swap a finished plan in; renaming fails whole, never half-way, if a file is open."""
    old = destination.with_name(destination.name + ".old")
    if old.exists():
        shutil.rmtree(old)
    if destination.exists():
        try:
            destination.rename(old)
        except PermissionError:
            raise SystemExit(f"Could not replace {destination}: a file in it is open (close it "
                             f"in your GIS). The new plan is complete in {new}.") from None
    new.rename(destination)
    shutil.rmtree(old, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rank", default=DEFAULT_RANK,
                        help=f"comma-separated ranking keys, '-' = descending (default {DEFAULT_RANK})")
    parser.add_argument("--min-overlap-ha", type=float, default=25.0)
    parser.add_argument("--epochs", nargs=2, default=("2017_pre", "2018_post"))
    parser.add_argument("--out", type=Path, default=PLAN)
    parser.add_argument("--job-ha", type=float, default=100.0,
                        help="pack units into array tasks of about this many hectares (default 100)")
    parser.add_argument("--force", action="store_true", help="replace an existing plan")
    args = parser.parse_args()
    keys = [key.strip() for key in args.rank.split(",") if key.strip()]

    if (args.out / "plan.json").exists() and not args.force:
        raise SystemExit(f"{args.out} already holds a plan; use --force to replace it "
                         "(units already computed from it would no longer match)")
    # Built beside the old plan and swapped in at the end, so a failed run or a file held
    # open elsewhere (a GIS) never leaves a half-deleted plan.
    build = args.out.with_name(args.out.name + ".building")
    if build.exists():
        shutil.rmtree(build)
    (build / "ownership").mkdir(parents=True)

    pairs = load_pairs(args.min_overlap_ha, args.epochs)
    print(f"{len(pairs)} pairs {args.epochs[0]} -> {args.epochs[1]} with >= "
          f"{args.min_overlap_ha:g} ha overlap in the inventory")
    overlaps = pair_overlaps(pairs)
    pairs["overlap_ha"] = [geometry.area / 1e4 for geometry in overlaps]
    pairs["inventory_row"] = np.arange(len(pairs))
    ranked = rank_pairs(pairs, keys)
    overlaps = [overlaps[i] for i in ranked.inventory_row]  # in rank order, like `tree`
    tree = STRtree(overlaps)

    corners = tiles_touching(overlaps)
    print(f"ranked by {', '.join(keys)}; {len(corners)} candidate 1 km tiles")
    units, pieces = [], {rank: [] for rank in ranked["rank"]}
    tile_rows = []
    for x0, y0 in corners:
        owner, transform = own_tile(x0, y0, ranked, overlaps, tree)
        if not owner.any():
            continue
        tile = tile_id(x0, y0)
        write_ownership(build / "ownership" / f"{tile}.tif", owner, transform)
        tile_rows.append({"tile": tile, "xmin": x0, "ymin": y0, "geometry": box(x0, y0, x0 + TILE_M, y0 + TILE_M)})
        for rank in np.unique(owner[owner > 0]):
            mask = owner == rank
            rows, cols = np.nonzero(mask)
            pair = ranked.iloc[int(rank) - 1]
            polygon = unary_union([shape(geom) for geom, _ in shapes(
                mask.astype(np.uint8), mask=mask, transform=transform)])
            pieces[int(rank)].append(polygon)
            units.append({
                "unit": f"{tile}_p{int(rank):03d}", "tile": tile, "rank": int(rank),
                "campaign_pre": pair.campaign_a, "campaign_post": pair.campaign_b,
                "block_pre": pair.block_a, "block_post": pair.block_b,
                "n_columns": int(mask.sum()), "area_ha": mask.sum() * CELL_M**2 / 1e4,
                # cell bounds, half-open: xmin <= x < xmax
                "xmin": x0 + int(cols.min()) * CELL_M, "xmax": x0 + (int(cols.max()) + 1) * CELL_M,
                "ymin": y0 + TILE_M - (int(rows.max()) + 1) * CELL_M,
                "ymax": y0 + TILE_M - int(rows.min()) * CELL_M,
                "geometry": polygon,
            })

    units = gpd.GeoDataFrame(units, crs=LAS_CRS)
    units.insert(1, "job", pack_jobs(units, args.job_ha))
    units = units.sort_values(["job", "unit"]).reset_index(drop=True)
    job_ha = units.groupby("job").area_ha.sum()
    owned = units.groupby("rank")["area_ha"].sum()
    ranked["owned_ha"] = ranked["rank"].map(owned).fillna(0.0)
    ranked["n_units"] = ranked["rank"].map(units.groupby("rank").size()).fillna(0).astype(int)
    ranked.to_csv(build / "pairs.csv", index=False)
    units.drop(columns="geometry").to_csv(build / "work_units.csv", index=False)
    units.to_file(build / "work_units.gpkg", layer="units")
    gpd.GeoDataFrame(tile_rows, crs=LAS_CRS).to_file(build / "work_units.gpkg", layer="tiles")
    owners = ranked[ranked.owned_ha > 0]
    gpd.GeoDataFrame(
        owners[["rank", "campaign_a", "campaign_b", "same_block", "overlap_ha", "owned_ha"]],
        geometry=[unary_union(pieces[rank]) for rank in owners["rank"]], crs=LAS_CRS,
    ).to_file(build / "work_units.gpkg", layer="pairs")

    # Checks: the pieces cover the both-epochs CHM overlap once (columns are owned by
    # construction at most once).
    # Measured in the LAS CRS: UTM areas in Puerto Rico are ~0.25% larger than the
    # inventory's EPSG:32161 areas (pr_repeat_summary_chm.csv), so compare like with like.
    repeat = gpd.read_file(FOOTPRINTS, layer="repeat_chm")
    expected = float(repeat[repeat.epochs == " + ".join(args.epochs)].to_crs(LAS_CRS).area.sum() / 1e4)
    total = float(units.area_ha.sum())
    slivers = units[units.area_ha < SLIVER_HA]
    n_multi = int((units.groupby("tile").size() > 1).sum())
    plan = {
        "created_by": "python/plan_units.py", "rank": keys, "min_overlap_ha": args.min_overlap_ha,
        "job_ha": args.job_ha, "epochs": list(args.epochs), "tile_m": TILE_M, "cell_m": CELL_M, "crs": LAS_CRS,
        "inventory": [signature(p) for p in (FOOTPRINTS, PAIRS, CAMPAIGNS)],
        "n_pairs": len(ranked), "n_pairs_owning": int((ranked.owned_ha > 0).sum()),
        "n_tiles": len(tile_rows), "n_units": len(units), "owned_ha": total,
        "expected_ha": expected, "n_units_below_1ha": len(slivers),
        "n_multi_unit_tiles": n_multi, "n_jobs": int(units.job.max()),
    }
    (build / "plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")

    print(f"{len(units):,} units in {len(tile_rows):,} tiles; {plan['n_pairs_owning']} of "
          f"{len(ranked)} pairs own ground; {n_multi:,} tiles have more than one unit")
    print(f"{plan['n_jobs']:,} array tasks of up to ~{args.job_ha:g} ha: median "
          f"{units.groupby('job').size().median():.0f} units and {job_ha.median():.0f} ha "
          f"(max {job_ha.max():.0f} ha)")
    print(f"owned {total:,.1f} ha vs {expected:,.1f} ha both-flights CHM overlap, both in "
          f"{LAS_CRS} ({total - expected:+,.1f} ha: pairs under {args.min_overlap_ha:g} ha "
          "and 1 m rasterising)")
    print(f"unit area: median {units.area_ha.median():.1f} ha, {len(slivers):,} units under "
          f"{SLIVER_HA:g} ha ({slivers.area_ha.sum():.1f} ha in total)")
    print(f"same-block pairs own {ranked.loc[ranked.same_block == 1, 'owned_ha'].sum():,.0f} ha")
    replace_directory(build, args.out)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()

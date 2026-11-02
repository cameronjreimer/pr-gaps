"""Gap area and volume per field quadrat, for every run of a sweep.

    python python/quadrat_gaps.py                      # newest LFDP sweep, 20 m + 40 m quadrats
    python python/quadrat_gaps.py --sweep thr-1-1.5-2-3-4-5-8_conn-26-6
    python python/quadrat_gaps.py --quadrats q20=path/to/a.shp:ID_1 q40=path/to/b.shp:quadrat_nu

Each 1 m voxel column belongs to the quadrat containing its centre (the voxel grid is
fixed, origin GRID_ORIGIN, so columns never straddle in a way that matters at 20 m).
Per quadrat, connectivity and threshold:

  gap_area_m2 / gap_area_pct     columns holding any gap voxel / share of quadrat area
  gap_volume_m3                  gap voxels x voxel volume
  pre_volume_m3                  2017 vegetation voxels: voxels of eligible 2017 returns
                                 (same classes, coverage and MIN_VOXEL_POINTS as the
                                 gaps), whatever their distance; gap voxels are a subset
  gap_volume_pct                 gap_volume_m3 / pre_volume_m3, comparable to a
                                 basal-area loss ratio
  gap_volume_m3_per_m2           gap_volume_m3 / quadrat area
  n_gaps                         gaps with at least one voxel in the quadrat

Writes <sweep>/quadrats/<name>_gaps.csv for each quadrat layer.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import geopandas as gpd  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import pyarrow.parquet as pq  # noqa: E402

FIELD = Path.home() / "OneDrive" / "Documents" / "EEB" / "GLIHT" / "data" / "LFDP_Quadrat_40m"
QUADRATS = {
    "q20": (FIELD / "LFDP_window_20.shp", "ID_1"),        # ID_1 = census Q20
    "q40": (FIELD / "LFDP_window_40.shp", "quadrat_nu"),
}


def column_quadrats(columns, quadrats, id_field, voxel_size, origin):
    """Quadrat id for each (ix, iy) column by its centre; -1 outside every quadrat."""
    centres = gpd.GeoDataFrame(
        geometry=gpd.points_from_xy(
            origin[0] + (columns[:, 0] + 0.5) * voxel_size,
            origin[1] + (columns[:, 1] + 0.5) * voxel_size,
        ),
        crs=quadrats.crs,
    )
    joined = gpd.sjoin(centres, quadrats[[id_field, "geometry"]], predicate="within", how="left")
    joined = joined[~joined.index.duplicated()]  # a centre exactly on a shared edge
    return joined[id_field].fillna(-1).astype(np.int64).to_numpy()


def column_lookup(table_columns, columns):
    """Row in the sorted unique `columns` for each column in `table_columns`."""
    keys = canopy.row_keys(columns)
    position = np.searchsorted(keys, canopy.row_keys(np.ascontiguousarray(table_columns)))
    if not np.array_equal(columns[position], table_columns):
        raise ValueError("gap voxel outside the 2017 vegetation voxels")
    return position


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sweep", help="sweep folder name (default: newest for the site)")
    parser.add_argument("--quadrats", nargs="+", metavar="NAME=SHP:ID_FIELD",
                        help="quadrat layers (default: LFDP 20 m and 40 m)")
    args = parser.parse_args()

    sweeps = canopy.DATA / "runs" / "canopy" / canopy.SITE / "sweeps"
    if args.sweep:
        sweep = sweeps / args.sweep
    else:
        found = sorted(sweeps.glob("*/runs.json"), key=lambda p: p.stat().st_mtime)
        if not found:
            raise SystemExit(f"No sweeps in {sweeps}; run python/sweep.py first")
        sweep = found[-1].parent
    runs = canopy.read_json(sweep / "runs.json")["runs"]
    layers = QUADRATS
    if args.quadrats:
        layers = {}
        for spec in args.quadrats:
            name, rest = spec.split("=", 1)
            path, field = rest.rsplit(":", 1)
            layers[name] = (Path(path), field)

    # 2017 vegetation voxels, grouped by column: the denominator for volume shares.
    manifest, arrays = canopy.load_cache(canopy.CACHE, provenance=False)
    first = next(iter(runs.values()))
    config = canopy.read_json(Path(first["output"]) / "run.json")["config"]
    size, origin = config["voxel_size"], config["grid_origin"]
    eligible = np.flatnonzero(canopy._eligibility(
        arrays, config["exclude_classes"], config["min_height"]))
    cells = canopy.fixed_voxel_indices(np.asarray(arrays["xyz"][eligible]), size, origin)
    cells, counts = np.unique(cells, axis=0, return_counts=True)
    cells = cells[counts >= config["min_voxel_points"]]
    columns, pre_cells = np.unique(cells[:, :2], axis=0, return_counts=True)
    print(f"{len(eligible):,} eligible 2017 returns -> {len(cells):,} vegetation voxels "
          f"in {len(columns):,} columns")

    out_dir = sweep / "quadrats"
    out_dir.mkdir(exist_ok=True)
    for name, (path, field) in layers.items():
        quadrats = gpd.read_file(path).to_crs(manifest["crs_wkt"])
        area = dict(zip(quadrats[field].astype(np.int64), quadrats.area))
        owner = column_quadrats(columns, quadrats, field, size, origin)
        inside = owner >= 0
        pre = pd.Series(pre_cells[inside] * size**3).groupby(owner[inside]).sum()
        rows = []
        for connectivity, run in runs.items():
            run_config = canopy.read_json(Path(run["output"]) / "run.json")
            for threshold in run_config["thresholds"]:
                folder = Path(run["output"]) / canopy.threshold_directory_name(threshold)
                voxels = pq.read_table(folder / "voxels.parquet",
                                       columns=["ix", "iy", "object_id"]).to_pandas()
                where = owner[column_lookup(voxels[["ix", "iy"]].to_numpy(np.int64), columns)]
                voxels = voxels.assign(quadrat=where)[where >= 0]
                by_quadrat = voxels.groupby("quadrat")
                table = pd.DataFrame({
                    "gap_volume_m3": by_quadrat.size() * size**3,
                    "gap_area_m2": by_quadrat.apply(
                        lambda v: len(v[["ix", "iy"]].drop_duplicates()), include_groups=False
                    ) * size**2,
                    "n_gaps": by_quadrat["object_id"].nunique(),
                })
                table = table.reindex(sorted(area), fill_value=0)
                table.index.name = "quadrat_id"
                table = table.reset_index()
                table["quadrat_area_m2"] = table["quadrat_id"].map(area)
                table["pre_volume_m3"] = table["quadrat_id"].map(pre).fillna(0)
                table["gap_area_pct"] = 100 * table["gap_area_m2"] / table["quadrat_area_m2"]
                table["gap_volume_pct"] = np.where(
                    table["pre_volume_m3"] > 0,
                    100 * table["gap_volume_m3"] / table["pre_volume_m3"].where(
                        table["pre_volume_m3"] > 0, 1),
                    np.nan)
                table["gap_volume_m3_per_m2"] = table["gap_volume_m3"] / table["quadrat_area_m2"]
                rows.append(table.assign(layer=name, connectivity=int(connectivity),
                                         threshold_m=threshold, run_id=run["run_id"][:16]))
        result = pd.concat(rows, ignore_index=True)
        leading = ["layer", "quadrat_id", "connectivity", "threshold_m", "run_id",
                   "quadrat_area_m2", "gap_area_m2", "gap_area_pct", "gap_volume_m3",
                   "pre_volume_m3", "gap_volume_pct", "gap_volume_m3_per_m2", "n_gaps"]
        result = result[leading]
        target = out_dir / f"{name}_gaps.csv"
        result.to_csv(target, index=False)
        print(f"{name}: {len(area)} quadrats x {len(rows)} runs/thresholds -> {target}")


if __name__ == "__main__":
    main()

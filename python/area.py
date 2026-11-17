"""Area accounting: owned, covered and forest hectares per flight pair and forest type.

    python python/area.py                    # every unit with a step-1 cache
    python python/area.py --treecover 30     # Hansen tree-cover threshold, % (ADR 007 placeholder)

docs/hpc-scaling-plan.md §4.6. The denominators for gap density and damage per hectare
(plan §2.10), and a record of how much ground each step removes. Per 1 m column:

- owned: the work-unit plan gives it to a pair (ownership rasters);
- covered: the unit's cache has both flights' returns there (step-1 coverage);
- forest_hansen: covered, Hansen treecover2000 >= --treecover and no loss in 2001-2016
  (ADR 007's default mask);
- forest_ccap: covered and a forest class in C-CAP 2010 (deciduous, evergreen or mixed
  forest, palustrine or estuarine forested wetland: codes 9, 10, 11, 13, 16), for the
  ADR 007 comparison; forest_both / forest_either are their intersection and union.

Forest type is the Holdridge life zone (as in 04_gap_covariates.R), rasterised at 10 m;
each column takes the mask and zone cells holding its centre. Columns are owned once,
so the sums are exact counts of 1 m columns.

Writes $PR_GAPS_DATA/runs/canopy/area/<id>/: areas.csv (pair x forest type),
areas_by_unit.csv, area.json (settings, inputs). The id hashes the plan and settings.
Run it as one job after step 1; units without a cache are listed and left out.
"""

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import units as plan_units  # noqa: E402

COVARIATES = canopy.DATA / "interim" / "covariates"
CCAP_FOREST = (9, 10, 11, 13, 16)
HANSEN_LOSS_YEARS = range(1, 17)  # lossyear 1..16 = 2001..2016, before the 2017 flights
ZONE_RESOLUTION_M = 10.0
CRS_AREA = "EPSG:32161"


class Grid:
    """A single-band raster held in memory, sampled at points by the cell holding them."""

    def __init__(self, path):
        import rasterio

        with rasterio.open(path) as raster:
            self.values = raster.read(1)
            self.inverse = ~raster.transform
            self.crs = raster.crs
        self.path = path

    def sample(self, x, y, fill=0):
        col, row = self.inverse * (x, y)
        col, row = np.floor(col).astype(np.int64), np.floor(row).astype(np.int64)
        inside = (row >= 0) & (row < self.values.shape[0]) & (col >= 0) & (col < self.values.shape[1])
        out = np.full(len(x), fill, dtype=self.values.dtype)
        out[inside] = self.values[row[inside], col[inside]]
        return out


def one(folder, pattern):
    matches = sorted((COVARIATES / folder).glob(pattern))
    if not matches:
        raise SystemExit(f"No {pattern} in {COVARIATES / folder}; run scripts/03_download_covars.R")
    return matches[0]


def zone_grid():
    """Holdridge life zones rasterised at 10 m in EPSG:32161; code 0 = outside every zone."""
    import geopandas as gpd
    from rasterio.features import rasterize
    from rasterio.transform import from_origin

    zones = gpd.read_file(one("holdridge", "*.gpkg")).to_crs(CRS_AREA)
    names = sorted(zones.LifeZonesDesc.dropna().unique())
    codes = {name: i + 1 for i, name in enumerate(names)}
    xmin, ymin, xmax, ymax = zones.total_bounds
    width = int(np.ceil((xmax - xmin) / ZONE_RESOLUTION_M))
    height = int(np.ceil((ymax - ymin) / ZONE_RESOLUTION_M))
    transform = from_origin(xmin, ymax, ZONE_RESOLUTION_M, ZONE_RESOLUTION_M)
    values = rasterize(((g, codes[n]) for g, n in zip(zones.geometry, zones.LifeZonesDesc) if n in codes),
                       out_shape=(height, width), transform=transform, fill=0, dtype="uint8")
    grid = Grid.__new__(Grid)
    grid.values, grid.inverse, grid.path = values, ~transform, "holdridge (10 m)"
    return grid, ["none"] + names


def owned_columns(unit):
    """(ix, iy) of the columns the unit owns, from its tile's ownership raster."""
    import rasterio

    x0, y0 = plan_units.tile_corner(unit.tile)
    with rasterio.open(canopy.PLAN / "ownership" / f"{unit.tile}.tif") as raster:
        rows, cols = np.nonzero(raster.read(1) == unit["rank"])
    return np.column_stack((x0 + cols, y0 + plan_units.TILE_M - 1 - rows)).astype(np.int64)


def main():
    from pyproj import Transformer

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--treecover", type=float, default=30.0,
                        help="Hansen treecover2000 threshold, %% (ADR 007's placeholder: 30)")
    args = parser.parse_args()

    plan = plan_units.load_units()
    treecover = Grid(one("hansen", "*treecover2000*_32161.tif"))
    lossyear = Grid(one("hansen", "*lossyear*_32161.tif"))
    ccap = Grid(one("ccap", "*_32161.tif"))
    zones, zone_names = zone_grid()
    to_area = Transformer.from_crs(plan_units.UNIT_CRS, CRS_AREA, always_xy=True)
    settings = {"treecover_min_pct": args.treecover, "hansen_loss_years": [2001, 2016],
                "ccap_forest_codes": list(CCAP_FOREST), "forest_type": "Holdridge LifeZonesDesc",
                "zone_resolution_m": ZONE_RESOLUTION_M,
                "inputs": [str(g.path) for g in (treecover, lossyear, ccap)],
                "plan_sha256": hashlib.sha256((canopy.PLAN / "plan.json").read_bytes()).hexdigest()}
    out = canopy.DATA / "runs" / "canopy" / "area" / canopy.stable_id(settings)[:16]
    out.mkdir(parents=True, exist_ok=True)

    rows, missing = [], []
    for unit in plan.itertuples(index=False):
        unit = pd.Series(unit._asdict())
        cache = plan_units.UNITS / unit.unit / "cache"
        if not (cache / "manifest.json").is_file():
            missing.append(unit.unit)
            continue
        owned = owned_columns(unit)
        _, arrays = canopy.load_cache(cache)
        ledger = arrays["coverage"]
        coverage = canopy.read_json(cache / "manifest.json")["coverage"]
        good = ((np.asarray(ledger["pre_count"]) >= coverage["min_pre_returns"])
                & (np.asarray(ledger["post_count"]) >= coverage["min_post_returns"]))
        covered_keys = np.asarray(ledger["ix"])[good] * 2**32 + np.asarray(ledger["iy"])[good]
        owned_keys = owned[:, 0] * 2**32 + owned[:, 1]
        covered = np.isin(owned_keys, covered_keys)
        x, y = to_area.transform(owned[:, 0] + 0.5, owned[:, 1] + 0.5)
        x, y = np.asarray(x), np.asarray(y)
        hansen = (treecover.sample(x, y) >= args.treecover) & ~np.isin(lossyear.sample(x, y), HANSEN_LOSS_YEARS)
        forest_ccap = np.isin(ccap.sample(x, y), CCAP_FOREST)
        zone = zones.sample(x, y)
        frame = pd.DataFrame({"zone": zone, "owned": 1, "covered": covered,
                              "forest_hansen": covered & hansen, "forest_ccap": covered & forest_ccap,
                              "forest_both": covered & hansen & forest_ccap,
                              "forest_either": covered & (hansen | forest_ccap)})
        summed = frame.groupby("zone").sum() / 1e4  # 1 m columns -> ha
        summed.columns = [f"{c}_ha" for c in summed.columns]
        summed = summed.reset_index()
        summed["forest_type"] = [zone_names[z] for z in summed.zone]
        summed["unit"], summed["rank"] = unit.unit, unit["rank"]
        rows.append(summed.drop(columns="zone"))
        if len(rows) % 200 == 0:
            canopy.stamp(f"{len(rows):,} of {len(plan):,} units")
    by_unit = pd.concat(rows, ignore_index=True)
    pairs = pd.read_csv(canopy.PLAN / "pairs.csv")[["rank", "campaign_a", "campaign_b", "block_a"]]
    by_unit.to_csv(out / "areas_by_unit.csv", index=False)
    areas = (by_unit.drop(columns="unit").groupby(["rank", "forest_type"], as_index=False).sum()
             .merge(pairs, on="rank", how="left"))
    areas.to_csv(out / "areas.csv", index=False)
    canopy.write_json(out / "area.json", {**settings, "units": len(plan) - len(missing),
                                          "units_without_cache": missing})

    totals = areas.drop(columns=["rank", "campaign_a", "campaign_b", "block_a"]).groupby("forest_type").sum()
    print(totals.round(1).to_string())
    total = totals.sum()
    print(f"\nall: owned {total.owned_ha:,.1f} ha, covered {total.covered_ha:,.1f}, forest (Hansen >= "
          f"{args.treecover:g}%) {total.forest_hansen_ha:,.1f}, forest (C-CAP) {total.forest_ccap_ha:,.1f}")
    if missing:
        print(f"{len(missing)} units have no step-1 cache yet and are left out, e.g. {missing[:3]}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()

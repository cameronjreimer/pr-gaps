"""Forest mask and covariates per island gap (hpc-scaling-plan §4.6, M6; ADR 007, ADR 008).

    python python/gap_covariates.py tile --tile E0188_N1997    # one tile's partial sums
    python python/gap_covariates.py combine                    # per-gap table + mask comparison

Every 1 m column of every gap object (island_gaps.py, the primary run, threshold
$PR_GAPS_COV_THRESHOLD, default 3 m: ADR 009) is sampled at its centre, as area.py
samples the area denominators, so gap and area figures use the same rule. `tile` writes
per-gap partial sums for the columns in one tile; `combine` adds them up per gap (a gap
spanning tiles gets exact totals) and writes

    runs/canopy/island/<run>/covariates/<T>/gaps_covariates.parquet  (one row per gap)
    runs/canopy/island/<run>/covariates/<T>/mask_comparison.csv       (ADR 007)

Per gap:
- forest fractions of its columns. Hansen = treecover2000 >= t and no loss 2001-2016,
  for t = 10, 30, 50 (ADR 007: 30 is a placeholder). C-CAP 2010 forest codes as area.py.
  Union and intersection at 30. hansen_treecover_mean and hansen_loss_frac too. No keep
  rule is applied here: the rule is chosen after the comparison (ADR 007).
- modes by column count: C-CAP code, PR GAP land cover code, Helmer formation code,
  Holdridge zone (rasterised at 10 m, as area.py).
- means: PRISM ppt/tmax/tmin (stored x100, as 04_gap_covariates.R), and from the
  column's own 2017 campaign (its pair's pre flight): DTM elevation, slope, circular
  aspect, CHM mean and max, and canopy rugosity (SD of CHM cells > 2 m in a centred
  41 m window, as R/ingest/08_gliht_rasters.R; computed per tile from a 20 m buffer, so
  windows are complete wherever the strips have data).
Missing data stays out of each mean; *_n columns say how many columns had a value.
"""

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import area  # noqa: E402
import island_gaps  # noqa: E402
import units as plan_units  # noqa: E402

THRESHOLD = float(os.environ.get("PR_GAPS_COV_THRESHOLD") or 3)
HANSEN_TC = (10, 30, 50)
BUFFER_M = 20  # half the 41 m rugosity window
RUGOSITY_WINDOW = 41
RUGOSITY_MIN_HEIGHT_M = 2.0
GLIHT_PRODUCTS = ("DTM", "slope", "aspect", "CHM")
CLASS_LAYERS = ("ccap", "gap_landcover", "helmer", "holdridge")


def out_dir(root=None):
    if os.environ.get("PR_GAPS_COV_DIR"):  # tests: keep their output out of the run
        return Path(os.environ["PR_GAPS_COV_DIR"])
    root = root or island_gaps.run_dir()
    return root / "covariates" / island_gaps.label(THRESHOLD)


def commit():
    return os.environ.get("PR_GAPS_CODE_VERSION", "")


# ------------------------------------------------------------------ sampling helpers

def sample_window(path, x, y):
    """Values of a raster at points (its CRS), reading only the window around them."""
    import rasterio
    from rasterio.windows import from_bounds

    with rasterio.open(path) as src:
        res = abs(src.transform.a)
        win = from_bounds(x.min() - 2 * res, y.min() - 2 * res, x.max() + 2 * res, y.max() + 2 * res,
                          src.transform).round_offsets().round_lengths()
        values = src.read(1, window=win, boundless=True, fill_value=src.nodata if src.nodata is not None else 0)
        inverse = ~src.window_transform(win)
        nodata = src.nodata
    col, row = inverse * (x, y)
    col, row = np.floor(col).astype(np.int64), np.floor(row).astype(np.int64)
    out = values[np.clip(row, 0, values.shape[0] - 1), np.clip(col, 0, values.shape[1] - 1)].astype(np.float64)
    if nodata is not None and not np.isnan(nodata):
        out[out == nodata] = np.nan
    return out


def holdridge_codes(x, y):
    """Holdridge zone name index per point (0 = none), rasterised at 10 m like area.zone_grid."""
    import geopandas as gpd
    from rasterio.features import rasterize
    from rasterio.transform import from_origin

    zones = gpd.read_file(area.one("holdridge", "*.gpkg")).to_crs(area.CRS_AREA)
    names = zone_names(zones)
    codes = {n: i + 1 for i, n in enumerate(names)}
    res = area.ZONE_RESOLUTION_M
    # Snap the window to the island grid area.zone_grid uses (origin at the zones' corner).
    gx0, _, _, gy1 = zones.total_bounds
    xmin = gx0 + np.floor((x.min() - gx0) / res - 1) * res
    ymax = gy1 - np.floor((gy1 - y.max()) / res - 1) * res
    width = int(np.ceil((x.max() - xmin) / res)) + 2
    height = int(np.ceil((ymax - y.min()) / res)) + 2
    transform = from_origin(xmin, ymax, res, res)
    grid = rasterize(((g, codes[n]) for g, n in zip(zones.geometry, zones.LifeZonesDesc) if n in codes),
                     out_shape=(height, width), transform=transform, fill=0, dtype="uint8")
    col, row = ~transform * (x, y)
    return grid[np.floor(row).astype(int), np.floor(col).astype(int)], ["none"] + names


def zone_names(zones=None):
    import geopandas as gpd

    if zones is None:
        zones = gpd.read_file(area.one("holdridge", "*.gpkg"))
    return sorted(zones.LifeZonesDesc.dropna().unique())


def strips(campaign, product):
    folder = Path(canopy.GLIHT) / campaign / "lidar" / "geotiff"
    single = folder / f"{campaign}_{product}.tif"
    if single.is_file():
        return [single]
    tifs = sorted(p for p in (folder / f"{campaign}_{product}").glob("*.tif") if "_mosaic_" not in p.name)
    if tifs:
        return tifs
    return sorted((folder / f"{campaign}_{product}").glob("*.tif"))  # a mosaic with no strips


def gliht_mosaic(campaign, product, x0, y0):
    """The tile plus BUFFER_M on a 1 m grid, from the campaign's strips; first strip wins."""
    import rasterio
    from rasterio.transform import from_origin
    from rasterio.warp import Resampling, reproject
    from rasterio.windows import from_bounds

    size = plan_units.TILE_M + 2 * BUFFER_M
    left, top = x0 - BUFFER_M, y0 + plan_units.TILE_M + BUFFER_M
    dst_transform = from_origin(left, top, 1.0, 1.0)
    out = np.full((size, size), np.nan, np.float32)
    for path in reversed(strips(campaign, product)):  # reversed: earlier strips overwrite
        with rasterio.open(path) as src:
            b = src.bounds
            if b.right <= left or b.left >= left + size or b.top <= top - size or b.bottom >= top:
                continue
            win = from_bounds(max(b.left, left), max(b.bottom, top - size), min(b.right, left + size),
                              min(b.top, top), src.transform).round_offsets().round_lengths()
            data = src.read(1, window=win).astype(np.float32)
            if src.nodata is not None and not np.isnan(src.nodata):
                data[data == src.nodata] = np.nan
            if not np.isfinite(data).any():
                continue
            reproject(data, out, src_transform=src.window_transform(win), src_crs=src.crs,
                      dst_transform=dst_transform, dst_crs=src.crs, src_nodata=np.nan,
                      dst_nodata=np.nan, init_dest_nodata=False, resampling=Resampling.nearest)
    return out


def rugosity(chm):
    """SD of CHM cells above 2 m in a centred 41 x 41 window (R's gl_canopy_rugosity)."""
    from scipy.ndimage import uniform_filter

    above = np.isfinite(chm) & (chm > RUGOSITY_MIN_HEIGHT_M)
    x = np.where(above, chm, 0).astype(np.float64)
    box = lambda a: uniform_filter(a, RUGOSITY_WINDOW, mode="constant", cval=0.0) * RUGOSITY_WINDOW ** 2  # noqa: E731
    n = np.rint(box(above.astype(np.float64)))
    s1, s2 = box(x), box(x * x)
    with np.errstate(invalid="ignore", divide="ignore"):
        m = s1 / n
        v = np.maximum(s2 / n - m * m, 0)
    return np.where((n > 0) & np.isfinite(chm), np.sqrt(v), np.nan)


# ------------------------------------------------------------------ one tile

def tile_columns(root, tile):
    """(gap, ix, iy) of every gap column in one tile, one row per column."""
    name = island_gaps.label(THRESHOLD)
    # voxels.parquet holds every changed voxel (columns.parquet only the edge-ring labels').
    path = root / "tiles" / tile / name / "voxels.parquet"
    if not path.is_file():
        return pd.DataFrame(columns=["gap", "ix", "iy"])
    cols = pd.read_parquet(path, columns=["label", "ix", "iy"]).drop_duplicates()
    offset = pd.read_csv(root / "gaps" / name / "nodes.csv").set_index("tile").at[tile, "offset"]
    node_gap = np.load(root / "gaps" / name / "node_gap.npy", mmap_mode="r")
    cols["gap"] = np.asarray(node_gap[offset + cols.label.to_numpy(np.int64) - 1], np.int64)
    return cols[cols.gap > 0].drop_duplicates(["gap", "ix", "iy"])[["gap", "ix", "iy"]].reset_index(drop=True)


def tile_partials(tile):
    import rasterio
    from pyproj import Transformer

    root = island_gaps.run_dir()
    out = out_dir(root) / "tiles"
    out.mkdir(parents=True, exist_ok=True)
    cols = tile_columns(root, tile)
    sums = pd.DataFrame()
    classes = pd.DataFrame(columns=["gap", "layer", "code", "n"])
    if len(cols):
        ix, iy = cols.ix.to_numpy(), cols.iy.to_numpy()
        x, y = ix + 0.5, iy + 0.5
        ax, ay = Transformer.from_crs(plan_units.UNIT_CRS, area.CRS_AREA, always_xy=True).transform(x, y)
        tc = sample_window(area.one("hansen", "*treecover2000*_32161.tif"), ax, ay)
        loss = np.isin(sample_window(area.one("hansen", "*lossyear*_32161.tif"), ax, ay), area.HANSEN_LOSS_YEARS)
        ccap = sample_window(area.one("ccap", "*_32161.tif"), ax, ay)
        ccap_forest = np.isin(ccap, area.CCAP_FOREST)
        f = {"n_columns": np.ones(len(cols)), "hansen_tc_n": np.isfinite(tc), "hansen_tc_sum": np.nan_to_num(tc),
             "hansen_loss": loss, "ccap_forest": ccap_forest}
        for t in HANSEN_TC:
            f[f"hansen{t}_forest"] = (np.nan_to_num(tc) >= t) & ~loss
        f["union30_forest"] = f["hansen30_forest"] | ccap_forest
        f["inter30_forest"] = f["hansen30_forest"] & ccap_forest
        values = {}
        for key, pattern in (("ppt", "*_ppt_*_32161.tif"), ("tmax", "*_tmax_*_32161.tif"),
                             ("tmin", "*_tmin_*_32161.tif")):
            values[key] = sample_window(area.one("prism", pattern), ax, ay) * 0.01

        # 2017 G-LiHT rasters of each column's own pair.
        x0, y0 = plan_units.tile_corner(tile)
        with rasterio.open(canopy.PLAN / "ownership" / f"{tile}.tif") as src:
            owner = src.read(1)
        rank = owner[plan_units.TILE_M - 1 - (iy - y0), ix - x0]
        campaign_of = pd.read_csv(canopy.PLAN / "pairs.csv").set_index("rank")["campaign_a"]
        for key in ("elev", "slope", "aspect", "chm", "rugosity"):
            values[key] = np.full(len(cols), np.nan)
        r, c = plan_units.TILE_M + BUFFER_M - 1 - (iy - y0), BUFFER_M + (ix - x0)
        for rk in np.unique(rank[rank > 0]):
            campaign = campaign_of.get(int(rk))
            here = rank == rk
            for product, key in zip(GLIHT_PRODUCTS, ("elev", "slope", "aspect", "chm")):
                try:
                    mosaic = gliht_mosaic(campaign, product, x0, y0)
                except Exception as error:  # noqa: BLE001  (a missing product leaves NaN)
                    canopy.stamp(f"{tile}: no {product} for {campaign}: {error}")
                    continue
                values[key][here] = mosaic[r[here], c[here]]
                if product == "CHM":
                    values["rugosity"][here] = rugosity(mosaic)[r[here], c[here]]
        for key, v in values.items():
            ok = np.isfinite(v)
            if key == "aspect":
                rad = np.deg2rad(np.where(ok, v, 0))
                f["aspect_sin"], f["aspect_cos"] = np.where(ok, np.sin(rad), 0), np.where(ok, np.cos(rad), 0)
            else:
                f[f"{key}_sum"] = np.where(ok, v, 0)
            f[f"{key}_n"] = ok
        frame = pd.DataFrame({k: np.asarray(v, np.float64) for k, v in f.items()})
        frame["gap"] = cols.gap.to_numpy()
        sums = frame.groupby("gap").sum()
        sums["chm_max"] = pd.Series(values["chm"]).groupby(cols.gap.to_numpy()).max()

        zone, _ = holdridge_codes(ax, ay)
        layers = {"ccap": ccap, "gap_landcover": sample_window(area.one("gap_landcover", "*_32161.tif"), ax, ay),
                  "helmer": sample_window(area.one("helmer_formations", "*_32161.tif"), ax, ay),
                  "holdridge": zone.astype(np.float64)}
        parts = []
        for layer, code in layers.items():
            part = pd.DataFrame({"gap": cols.gap.to_numpy(), "code": code}).dropna()
            part = part.groupby(["gap", "code"]).size().rename("n").reset_index()
            part["layer"] = layer
            parts.append(part)
        classes = pd.concat(parts, ignore_index=True)[["gap", "layer", "code", "n"]]
    sums.reset_index().to_parquet(out / f"{tile}.parquet", index=False)
    classes.to_parquet(out / f"{tile}_classes.parquet", index=False)
    canopy.write_json(out / f"{tile}.json", {"tile": tile, "threshold_m": THRESHOLD, "columns": int(len(cols)),
                                             "gaps": int(len(sums)), "commit": commit()})
    canopy.stamp(f"{tile}: {len(cols):,} columns of {len(sums):,} gaps")


def tile_done(tile, root=None):
    return (out_dir(root) / "tiles" / f"{tile}.json").is_file()


# ------------------------------------------------------------------ combine

def combine():
    root = island_gaps.run_dir()
    out = out_dir(root)
    tiles = sorted(plan_units.load_units().tile.unique())
    missing = [t for t in tiles if not tile_done(t, root)]
    if missing:
        raise SystemExit(f"{len(missing)} tiles have no covariates yet, e.g. {missing[:3]}")
    parts = [pd.read_parquet(out / "tiles" / f"{t}.parquet") for t in tiles]
    parts = pd.concat([p for p in parts if len(p)], ignore_index=True)
    chm_max = parts.groupby("gap").chm_max.max()
    s = parts.drop(columns="chm_max").groupby("gap").sum()
    gaps = pd.read_parquet(root / "gaps" / island_gaps.label(THRESHOLD) / "gaps.parquet",
                           columns=["object_id", "footprint_area_m2", "voxel_volume_m3", "main_pair_rank"])
    if len(s) != len(gaps) or not (s.n_columns.reindex(gaps.object_id).to_numpy() == gaps.footprint_area_m2).all():
        raise SystemExit("column counts do not match the gap table's footprint areas")

    n = s.n_columns
    table = pd.DataFrame(index=s.index)
    table["n_columns"] = n.astype(np.int64)
    for t in HANSEN_TC:
        table[f"forest_hansen{t}_frac"] = s[f"hansen{t}_forest"] / n
    table["forest_ccap_frac"] = s.ccap_forest / n
    table["forest_union30_frac"] = s.union30_forest / n
    table["forest_inter30_frac"] = s.inter30_forest / n
    table["hansen_treecover_mean"] = s.hansen_tc_sum / s.hansen_tc_n
    table["hansen_loss_frac"] = s.hansen_loss / n

    classes = pd.concat([pd.read_parquet(out / "tiles" / f"{t}_classes.parquet") for t in tiles], ignore_index=True)
    classes = classes.groupby(["layer", "gap", "code"], as_index=False).n.sum()
    classes = classes.sort_values(["layer", "gap", "n", "code"], ascending=[True, True, False, True])
    modes = classes.drop_duplicates(["layer", "gap"]).pivot(index="gap", columns="layer", values="code")
    for layer in CLASS_LAYERS:
        table[f"{layer}_code"] = modes[layer].reindex(table.index) if layer in modes else np.nan
    names = ["none"] + zone_names()
    table["holdridge"] = [names[int(c)] if np.isfinite(c) else None for c in table.pop("holdridge_code")]

    for key, column in (("ppt", "ppt_mm"), ("tmax", "tmax_c"), ("tmin", "tmin_c"), ("elev", "elev_m"),
                        ("slope", "slope_deg"), ("chm", "chm_mean_m"), ("rugosity", "rugosity_m")):
        table[column] = s[f"{key}_sum"] / s[f"{key}_n"].where(s[f"{key}_n"] > 0)
        if key in ("elev", "chm", "rugosity"):
            table[f"{column.rsplit('_', 1)[0]}_n"] = s[f"{key}_n"].astype(np.int64)
    table["aspect_deg"] = np.where(s.aspect_n > 0, np.rad2deg(np.arctan2(s.aspect_sin, s.aspect_cos)) % 360, np.nan)
    table["chm_max_m"] = chm_max
    table.index.name = "object_id"
    table = table.reset_index()
    table.to_parquet(out / "gaps_covariates.parquet", index=False)

    # ADR 007: the masks compared over gap columns, and what each keep rule would keep.
    merged = gaps.merge(table, on="object_id")
    rows = []
    masks = [f"hansen{t}" for t in HANSEN_TC] + ["ccap", "union30", "inter30"]
    for zone, group in [("all", merged)] + list(merged.groupby(merged.holdridge.fillna("none"))):
        row = {"holdridge": zone, "gaps": len(group), "gap_area_ha": group.footprint_area_m2.sum() / 1e4,
               "gap_volume_m3": group.voxel_volume_m3.sum()}
        for m in masks:
            frac = group[f"forest_{m}_frac"]
            row[f"{m}_forest_area_ha"] = (frac * group.footprint_area_m2).sum() / 1e4
            keep = frac >= 0.5
            row[f"{m}_keep50_gaps"] = int(keep.sum())
            row[f"{m}_keep50_volume_share"] = group.voxel_volume_m3[keep].sum() / group.voxel_volume_m3.sum()
        rows.append(row)
    comparison = pd.DataFrame(rows)
    comparison.to_csv(out / "mask_comparison.csv", index=False)
    canopy.write_json(out / "covariates.json", {"threshold_m": THRESHOLD, "gaps": int(len(table)),
                                                "commit": commit()})
    print(comparison[["holdridge", "gaps", "gap_area_ha", "hansen30_forest_area_ha", "ccap_forest_area_ha",
                      "hansen30_keep50_gaps", "ccap_keep50_gaps", "union30_keep50_gaps"]].to_string(index=False))


def combine_done(root=None):
    return (out_dir(root) / "covariates.json").is_file()


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    t = sub.add_parser("tile")
    t.add_argument("--tile", required=True)
    sub.add_parser("combine")
    a = p.parse_args()
    if a.command == "tile":
        tile_partials(a.tile)
    else:
        combine()


if __name__ == "__main__":
    main()

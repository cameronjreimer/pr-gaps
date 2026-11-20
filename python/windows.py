"""ADR 009's prototype windows and same-epoch nulls, as small work-unit plans.

    python python/windows.py select                  # choose the 25 ha windows (once, blind)
    python python/windows.py null ev1 PR_5March2017_EV1 PR_15March2017_EV1
    python python/windows.py report                  # separation per window, null ratios

docs/decisions/009-gap-definition-rule.md, docs/hpc-scaling-plan.md §7 (M3).

select: every 500 x 500 m quarter of a plan tile is a candidate. It is eligible when one
pair owns >= 99% of its columns and no other pair owns any, that pair isn't flagged by
island QC, its unit passed QC, >= --min-forest of it is forest (Hansen or C-CAP, as in
area.py) and >= --min-zone of it lies in one stratum's Holdridge zones. Windows are
drawn at random (fixed --seed) per stratum, at most one per pair and none touching
another, plus --ev1 windows from the EV1 pair. Nothing here reads gap output: ADR 009
requires the windows to be chosen before their gaps are seen. It refuses to run twice.

null NAME PRE POST: the same-epoch null. Every unit of the full plan whose 2017 flight
is PRE and whose tile meets POST's footprint, with POST (another 2017 flight) in place
of the 2018 one. The 2017 points, ownership and settings are the Maria unit's, so the
two runs label the same points.

Both write a plan folder; run it like the full plan, with its own workflow folder:

    export PR_GAPS_PLAN=$PR_GAPS_DATA/interim/windows/plan
    export PR_GAPS_WORKFLOW=$PR_GAPS_DATA/workflow_windows
    workflow/submit.sh step1 voxels label join            # nulls: ... join points

Unit IDs are prefixed (W01_, null-ev1_), so their caches never replace the full run's.

report: per window and threshold, gaps, gap volume and the largest gap's share
(separation, pass if <= --separation-limit); per null and threshold, the area of 1 m
columns holding a gap point in the null and in the Maria run, over the columns both
cover (noise, pass if null / Maria <= --noise-limit). Writes runs/canopy/adr009/.
"""

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import area  # noqa: E402
import island_gaps  # noqa: E402
import units as plan_units  # noqa: E402

WINDOW_M = 500
SAMPLE_M = 10  # forest and zone sampled on a 10 m grid (the zone raster's resolution)
WINDOWS = canopy.DATA / "interim" / "windows"
NULLS = canopy.DATA / "interim" / "nulls"
REPORTS = canopy.DATA / "runs" / "canopy" / "adr009"
FOOTPRINTS = Path(__file__).resolve().parent.parent / "derived" / "inventory" / "pr_footprints_chm.gpkg"
EV1_RANK = 30
# Holdridge zones covered by the plan, grouped into ADR 009's strata.
STRATA = {
    "dry": ["Subtropical Dry Forest"],
    "moist": ["Subtropical Moist Forest"],
    "wet": ["Subtropical Wet Forest", "Subtropical Rain Forest"],
    "montane": ["Lower Montane Wet Forest", "Lower Montane Rain Forest"],
}


def plan_sha(plan):
    return hashlib.sha256((Path(plan) / "plan.json").read_bytes()).hexdigest()


def island_run(plan):
    """The island_gaps run folder for a plan (island_gaps.run_dir for any plan)."""
    run_id = canopy.stable_id({"settings": island_gaps.SETTINGS, "plan": plan_sha(plan)})[:16]
    return canopy.DATA / "runs" / "canopy" / "island" / run_id


def qc_tables():
    folder = canopy.DATA / "runs" / "canopy" / "qc" / plan_sha(canopy.PLAN)[:16]
    if not (folder / "units.csv").is_file():
        raise SystemExit(f"No island QC for this plan at {folder}; run the qc stage first")
    return pd.read_csv(folder / "units.csv"), pd.read_csv(folder / "pairs.csv"), folder


def write_plan(out, rows, tiles_from, keep, extra):
    """A plan folder: work_units.csv, pairs.csv, plan.json and ownership rasters.

    keep(tile, values) -> the tile's ownership values for this plan (0 = not owned).
    """
    import rasterio

    (out / "ownership").mkdir(parents=True)
    rows.to_csv(out / "work_units.csv", index=False)
    shutil.copy2(canopy.PLAN / "pairs.csv", out / "pairs.csv")
    for tile in rows.tile.unique():
        with rasterio.open(tiles_from / f"{tile}.tif") as src:
            profile, values = src.profile, src.read(1)
        with rasterio.open(out / "ownership" / f"{tile}.tif", "w", **profile) as dst:
            dst.write(keep(tile, values), 1)
    plan = canopy.read_json(canopy.PLAN / "plan.json")
    plan.update({"subset_of": str(canopy.PLAN), "subset_of_sha256": plan_sha(canopy.PLAN),
                 "n_units": len(rows), "n_tiles": int(rows.tile.nunique()), **extra})
    canopy.write_json(out / "plan.json", plan)


# ------------------------------------------------------------------ select

def candidates(units, qc_units, flagged):
    """Every tile quarter one eligible pair owns, with its forest and stratum shares."""
    import rasterio
    from pyproj import Transformer

    treecover = area.Grid(area.one("hansen", "*treecover2000*_32161.tif"))
    lossyear = area.Grid(area.one("hansen", "*lossyear*_32161.tif"))
    ccap = area.Grid(area.one("ccap", "*_32161.tif"))
    zones, zone_names = area.zone_grid()
    to_area = Transformer.from_crs(plan_units.UNIT_CRS, area.CRS_AREA, always_xy=True)
    passed = set(qc_units.loc[qc_units.status == "PASS", "unit"])
    by_key = units.set_index(["tile", "rank"])
    offsets = np.arange(SAMPLE_M / 2, WINDOW_M, SAMPLE_M)
    gx, gy = np.meshgrid(offsets, offsets)
    rows = []
    for tile in sorted(units.tile.unique()):
        x0, y0 = plan_units.tile_corner(tile)
        with rasterio.open(canopy.PLAN / "ownership" / f"{tile}.tif") as raster:
            owner = raster.read(1)
        for qx in (0, 1):
            for qy in (0, 1):
                # Row 0 is the tile's north edge.
                block = owner[(1 - qy) * WINDOW_M:(2 - qy) * WINDOW_M, qx * WINDOW_M:(qx + 1) * WINDOW_M]
                ranks, counts = np.unique(block[block > 0], return_counts=True)
                if len(ranks) != 1 or counts[0] < 0.99 * block.size:
                    continue
                rank = int(ranks[0])
                if rank in flagged or (tile, rank) not in by_key.index:
                    continue
                unit = by_key.loc[(tile, rank)]
                if unit.unit not in passed:
                    continue
                wx, wy = x0 + qx * WINDOW_M, y0 + qy * WINDOW_M
                x, y = to_area.transform((wx + gx).ravel(), (wy + gy).ravel())
                hansen = ((treecover.sample(x, y) >= 30)
                          & ~np.isin(lossyear.sample(x, y), area.HANSEN_LOSS_YEARS))
                forest = hansen | np.isin(ccap.sample(x, y), area.CCAP_FOREST)
                zone = np.array(zone_names)[zones.sample(x, y)]
                row = {"tile": tile, "qx": qx, "qy": qy, "rank": rank, "unit": unit.unit,
                       "campaign_pre": unit.campaign_pre, "campaign_post": unit.campaign_post,
                       "block_pre": unit.block_pre, "n_columns": int(counts[0]),
                       "xmin": wx, "ymin": wy, "xmax": wx + WINDOW_M, "ymax": wy + WINDOW_M,
                       "forest_share": float(forest.mean())}
                for stratum, names in STRATA.items():
                    row[f"{stratum}_share"] = float(np.isin(zone, names).mean())
                rows.append(row)
    return pd.DataFrame(rows)


def touches(a, b, gap=1):
    return not (a.xmax + gap <= b.xmin or b.xmax + gap <= a.xmin
                or a.ymax + gap <= b.ymin or b.ymax + gap <= a.ymin)


def draw(pool, n, rng, chosen):
    """n windows from pool at random: distinct pairs, none touching a chosen window."""
    picked, ranks = [], set()
    for i in rng.permutation(len(pool)):
        row = pool.iloc[i]
        if row["rank"] in ranks or any(touches(row, c) for c in chosen + picked):
            continue
        picked.append(row)
        ranks.add(row["rank"])
        if len(picked) == n:
            break
    return picked


def select(args):
    out = args.out
    if out.exists() and not args.force:
        raise SystemExit(f"{out} exists: windows are chosen once. Use --force only if they "
                         "were chosen wrongly, before any of their gaps were looked at")
    units = plan_units.load_units()
    qc_units, qc_pairs, qc_folder = qc_tables()
    flagged = set(qc_pairs.loc[qc_pairs["flags"].fillna("") != "", "rank"].astype(int))
    pool = candidates(units, qc_units, flagged)
    pool = pool[pool.forest_share >= args.min_forest]
    rng = np.random.default_rng(args.seed)
    chosen, eligible = [], {}
    for stratum in STRATA:
        mine = pool[(pool[f"{stratum}_share"] >= args.min_zone) & (pool["rank"] != EV1_RANK)]
        eligible[stratum] = {"windows": len(mine), "pairs": int(mine["rank"].nunique())}
        for row in draw(mine, args.per_stratum, rng, chosen):
            chosen.append(row.copy())
            chosen[-1]["stratum"] = stratum
    ev1 = pool[pool["rank"] == EV1_RANK]
    eligible["ev1"] = {"windows": len(ev1), "pairs": 1}
    for row in draw(ev1.assign(rank=np.arange(len(ev1))), args.ev1, rng, chosen):  # any EV1 quarters
        row = row.copy()
        row["rank"] = EV1_RANK
        row["stratum"] = "ev1"
        chosen.append(row)
    if not chosen:
        raise SystemExit("No eligible windows")
    windows = pd.DataFrame(chosen).reset_index(drop=True)
    windows.insert(0, "window", [f"W{i + 1:02d}" for i in range(len(windows))])

    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    plan_rows = units.set_index("unit").loc[windows.unit].reset_index()
    plan_rows["unit"] = [f"{w}_{u}" for w, u in zip(windows.window, windows.unit)]
    plan_rows["job"] = np.arange(1, len(windows) + 1)
    for column in ("xmin", "ymin", "xmax", "ymax", "n_columns"):
        plan_rows[column] = windows[column].to_numpy()
    plan_rows["area_ha"] = windows.n_columns.to_numpy() / 1e4

    def keep(tile, values):
        kept = np.zeros_like(values)
        for w in windows[windows.tile == tile].itertuples():
            qx, qy = int(w.qx), int(w.qy)
            rows_ = slice((1 - qy) * WINDOW_M, (2 - qy) * WINDOW_M)
            cols = slice(qx * WINDOW_M, (qx + 1) * WINDOW_M)
            kept[rows_, cols] = np.where(values[rows_, cols] == w.rank, values[rows_, cols], 0)
        return kept

    settings = {"window_m": WINDOW_M, "seed": args.seed, "per_stratum": args.per_stratum,
                "ev1": args.ev1, "min_forest": args.min_forest, "min_zone": args.min_zone,
                "strata": STRATA, "qc": str(qc_folder), "flagged_ranks_excluded": sorted(flagged),
                "eligible": eligible}
    write_plan(out / "plan", plan_rows, canopy.PLAN / "ownership", keep,
               {"windows": settings})
    windows.to_csv(out / "windows.csv", index=False)
    canopy.write_json(out / "selection.json", settings)
    import geopandas as gpd
    from shapely.geometry import box
    gpd.GeoDataFrame(windows, geometry=[box(r.xmin, r.ymin, r.xmax, r.ymax) for r in windows.itertuples()],
                     crs=plan_units.UNIT_CRS).to_file(out / "windows.gpkg", layer="windows")
    for stratum, counts in eligible.items():
        n = int((windows.stratum == stratum).sum())
        print(f"{stratum:8s} {n} chosen of {counts['windows']} eligible windows in {counts['pairs']} pairs")
    print(f"{len(windows)} windows -> {out}; plan {out / 'plan'}")


# ------------------------------------------------------------------ null

def null(args):
    import geopandas as gpd
    from shapely.geometry import box

    out = NULLS / args.name
    units = plan_units.load_units()
    mine = units[units.campaign_pre == args.pre]
    if mine.empty:
        raise SystemExit(f"No units of the plan have 2017 flight {args.pre}")
    footprints = gpd.read_file(FOOTPRINTS, layer="campaign_footprints_chm")
    footprint = footprints[footprints.campaign == args.post].to_crs(plan_units.UNIT_CRS).unary_union
    if footprint.is_empty:
        raise SystemExit(f"No footprint for {args.post} in {FOOTPRINTS}")
    meets = [footprint.intersects(box(u.xmin, u.ymin, u.xmax, u.ymax)) for u in mine.itertuples()]
    rows = mine[meets].copy()
    if rows.empty:
        raise SystemExit(f"{args.post} meets none of {args.pre}'s units")
    rows["maria_unit"] = rows.unit
    rows["unit"] = f"null-{args.name}_" + rows.unit
    rows["campaign_post"] = args.post
    rows["block_post"] = rows.block_pre
    rows["job"] = np.arange(1, len(rows) + 1)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    def keep(tile, values):
        return np.where(np.isin(values, rows.loc[rows.tile == tile, "rank"]), values, 0).astype(values.dtype)

    write_plan(out / "plan", rows, canopy.PLAN / "ownership", keep,
               {"null": {"name": args.name, "pre": args.pre, "post": args.post}})
    print(f"null {args.name}: {len(rows)} units, {rows.area_ha.sum():,.1f} ha owned -> {out / 'plan'}")


# ------------------------------------------------------------------ report

def window_report(thresholds):
    windows = pd.read_csv(WINDOWS / "windows.csv")
    root = island_run(WINDOWS / "plan")
    rows = []
    for threshold in thresholds:
        path = root / "gaps" / island_gaps.label(threshold) / "gaps.parquet"
        if not path.is_file():
            raise SystemExit(f"No {path}; run voxels, label and join on the window plan")
        gaps = pd.read_parquet(path, columns=["voxel_volume_m3", "footprint_area_m2",
                                              "volume_centroid_x", "volume_centroid_y"])
        for w in windows.itertuples():
            inside = gaps[(gaps.volume_centroid_x >= w.xmin) & (gaps.volume_centroid_x < w.xmax)
                          & (gaps.volume_centroid_y >= w.ymin) & (gaps.volume_centroid_y < w.ymax)]
            volume = inside.voxel_volume_m3.to_numpy()
            total = volume.sum()
            rows.append({"window": w.window, "stratum": w.stratum, "rank": w.rank,
                         "threshold_m": threshold, "n_gaps": len(inside),
                         "gap_volume_m3": float(total),
                         "footprint_area_m2": float(inside.footprint_area_m2.sum()),
                         "largest_gap_m3": float(volume.max(initial=0)),
                         "largest_gap_share": float(volume.max(initial=0) / total) if total else np.nan})
    return pd.DataFrame(rows), root


def gap_columns(xyz, labels, mask):
    picked = mask & (labels > 0)
    x = np.floor(np.asarray(xyz[picked, 0])).astype(np.int64)
    y = np.floor(np.asarray(xyz[picked, 1])).astype(np.int64)
    return len(np.unique(x * 10_000_000 + y))


def null_report(name, thresholds):
    plan = NULLS / name / "plan"
    null_root, maria_root = island_run(plan), island_run(canopy.PLAN)
    rows = []
    exclude = island_gaps.SETTINGS["exclude_classes"]
    for unit in pd.read_csv(plan / "work_units.csv").itertuples():
        _, a = canopy.load_cache(plan_units.UNITS / unit.unit / "cache")
        _, b = canopy.load_cache(plan_units.UNITS / unit.maria_unit / "cache")
        if len(a["c2c"]) != len(b["c2c"]) or not np.array_equal(a["xyz"][:1000], b["xyz"][:1000]):
            raise SystemExit(f"{unit.unit} and {unit.maria_unit} hold different 2017 points")
        both = canopy._eligibility(a, exclude, None) & canopy._eligibility(b, exclude, None)
        covered = gap_columns(a["xyz"], np.ones(len(both), np.uint8), both)
        for threshold in thresholds:
            name_t = island_gaps.label(threshold)
            labels_null = np.load(null_root / "units" / unit.unit / f"labels_{name_t}.npy", mmap_mode="r")
            labels_maria = np.load(maria_root / "units" / unit.maria_unit / f"labels_{name_t}.npy", mmap_mode="r")
            rows.append({"null": name, "unit": unit.unit, "maria_unit": unit.maria_unit,
                         "threshold_m": threshold, "covered_m2": covered,
                         "null_gap_m2": gap_columns(a["xyz"], labels_null, both),
                         "maria_gap_m2": gap_columns(a["xyz"], labels_maria, both)})
    return pd.DataFrame(rows), null_root


def report(args):
    thresholds = island_gaps.THRESHOLDS
    out = REPORTS
    out.mkdir(parents=True, exist_ok=True)
    lines = [f"separation limit {args.separation_limit:.0%}, noise limit {args.noise_limit:.0%}"]
    if (WINDOWS / "windows.csv").is_file():
        table, root = window_report(thresholds)
        table["separation_pass"] = table.largest_gap_share <= args.separation_limit
        table.to_csv(out / "windows.csv", index=False)
        lines.append(f"windows ({root.name}): largest gap's share of gap volume")
        wide = table.pivot(index=["window", "stratum"], columns="threshold_m", values="largest_gap_share")
        lines += ["   " + line for line in wide.to_string(float_format=lambda v: f"{v:.1%}").splitlines()]
        for threshold, group in table.groupby("threshold_m"):
            lines.append(f"   {threshold:g} m: {int(group.separation_pass.sum())} of {len(group)} windows pass")
    nulls = []
    for name in sorted(p.name for p in NULLS.glob("*") if (p / "plan").is_dir()):
        table, root = null_report(name, thresholds)
        nulls.append(table)
        summed = table.groupby("threshold_m")[["covered_m2", "null_gap_m2", "maria_gap_m2"]].sum()
        summed["ratio"] = summed.null_gap_m2 / summed.maria_gap_m2
        lines.append(f"null {name} ({root.name}): {summed.covered_m2.iloc[0] / 1e4:,.1f} ha covered by both")
        for threshold, row in summed.iterrows():
            verdict = "PASS" if row.ratio <= args.noise_limit else "FAIL"
            lines.append(f"   {verdict} {threshold:g} m: null {row.null_gap_m2 / 1e4:,.2f} ha, "
                         f"Maria {row.maria_gap_m2 / 1e4:,.2f} ha, ratio {row.ratio:.1%}")
    if nulls:
        pd.concat(nulls).to_csv(out / "nulls.csv", index=False)
    (out / "report.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("select", help="choose the prototype windows")
    s.add_argument("--per-stratum", type=int, default=3)
    s.add_argument("--ev1", type=int, default=3, help="windows in the EV1 pair (rank 30)")
    s.add_argument("--min-forest", type=float, default=0.8)
    s.add_argument("--min-zone", type=float, default=0.9)
    s.add_argument("--seed", type=int, default=20170920)  # Maria's landfall
    s.add_argument("--out", type=Path, default=WINDOWS)
    s.add_argument("--force", action="store_true")
    n = sub.add_parser("null", help="a same-epoch null plan")
    n.add_argument("name")
    n.add_argument("pre", help="the Maria pairs' 2017 flight")
    n.add_argument("post", help="another 2017 flight of the same ground")
    r = sub.add_parser("report", help="separation per window, null ratios")
    r.add_argument("--separation-limit", type=float, default=0.10)
    r.add_argument("--noise-limit", type=float, default=0.10)
    args = parser.parse_args()
    {"select": select, "null": null, "report": report}[args.command](args)


if __name__ == "__main__":
    main()

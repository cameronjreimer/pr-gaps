"""AGU draft, steps 0 and 1 (docs/agu-analysis-plan.md): the analysis table and gap area.

    python python/agu_table.py table --threshold 3    # analysis/gaps_3m.csv
    python python/agu_table.py area --threshold 2 3   # analysis/gap_area.csv

Reads the island run (island_gaps.run_dir()), its covariates/<T>/gaps_covariates.parquet
(gap_covariates.py) and the plan's area accounting (runs/canopy/area/<id>/areas.csv).
Light on purpose: no CloudComPy import, runs on a login node in seconds.

table: gaps with forest_ccap_frac >= 0.5 (ADR 007), with stratum (Holdridge grouped as in
ADR 009's windows), the 1 km tile of the volume centroid (bootstrap blocks), is_largest
(footprint >= 25 ha) and the QC / edge flags.

area: gap area = sum over all gaps of footprint x C-CAP forest fraction (the column-level
mask, the same rule as the denominator), over the C-CAP forest covered by both flights
(forest_ccap_ha). Island-wide and per stratum. Columns holding two gaps at different
heights count twice, so the area is a slight overestimate; the kept-gap area (objects
passing the 0.5 rule) is given alongside.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd

DATA = Path(os.environ.get("PR_GAPS_DATA") or "/ibstorage/cam/G-LiHT/data")
PLAN = Path(os.environ.get("PR_GAPS_PLAN") or DATA / "interim" / "work_units")
RUN = os.environ.get("PR_GAPS_ISLAND_RUN") or "df81889aa38eecef"
ROOT = DATA / "runs" / "canopy" / "island" / RUN
OUT = ROOT / "analysis"
KEEP_FOREST = 0.5
LARGEST_M2 = 25 * 10_000
STRATA = {
    "Subtropical Dry Forest": "dry",
    "Subtropical Moist Forest": "moist",
    "Subtropical Wet Forest": "wet",
    "Subtropical Rain Forest": "wet",
    "Lower Montane Wet Forest": "montane",
    "Lower Montane Rain Forest": "montane",
}
GAP_COLUMNS = ["object_id", "footprint_area_m2", "voxel_volume_m3", "n_points", "mean_c2c_m",
               "mean_hag_m", "max_hag_m", "volume_centroid_x", "volume_centroid_y", "main_pair_rank",
               "main_pair_flagged", "touches_coverage_edge", "crosses_pair_border"]
COV_COLUMNS = ["object_id", "forest_ccap_frac", "holdridge", "elev_m", "ppt_mm", "tmax_c", "slope_deg",
               "chm_mean_m"]


def label(t):
    return f"{t:g}m"


def joined(threshold):
    name = label(threshold)
    cov = ROOT / "covariates" / name / "gaps_covariates.parquet"
    if not cov.is_file():
        raise SystemExit(f"No {cov}: run gap_covariates.py with PR_GAPS_COV_THRESHOLD={threshold:g} first")
    gaps = pd.read_parquet(ROOT / "gaps" / name / "gaps.parquet", columns=GAP_COLUMNS)
    gaps = gaps.merge(pd.read_parquet(cov, columns=COV_COLUMNS), on="object_id", how="left", validate="1:1")
    gaps["stratum"] = gaps.holdridge.map(STRATA).fillna("other")
    return gaps


def table(threshold):
    gaps = joined(threshold)
    kept = gaps[gaps.forest_ccap_frac >= KEEP_FOREST].copy()
    kept["tile"] = ["E%04d_N%04d" % (x, y) for x, y in
                    zip(np.floor(kept.volume_centroid_x / 1000).astype(int),
                        np.floor(kept.volume_centroid_y / 1000).astype(int))]
    kept["is_largest"] = kept.footprint_area_m2 >= LARGEST_M2
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"gaps_{label(threshold)}.csv"
    kept.drop(columns=["volume_centroid_x", "volume_centroid_y"]).to_csv(path, index=False)
    counts = kept.stratum.value_counts().to_dict()
    record = {"threshold_m": threshold, "run": RUN, "gaps_all": int(len(gaps)), "gaps_kept": int(len(kept)),
              "keep_rule": f"forest_ccap_frac >= {KEEP_FOREST}", "largest_m2": LARGEST_M2,
              "n_largest": int(kept.is_largest.sum()), "by_stratum": counts}
    (OUT / f"gaps_{label(threshold)}.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))


def area_table():
    plan_sha = hashlib.sha256((PLAN / "plan.json").read_bytes()).hexdigest()
    for marker in (DATA / "runs" / "canopy" / "area").glob("*/area.json"):
        if json.loads(marker.read_text()).get("plan_sha256") == plan_sha:
            return pd.read_csv(marker.parent / "areas.csv")
    raise SystemExit("No area accounting for this plan")


def area(thresholds):
    areas = area_table()
    areas["stratum"] = areas.forest_type.map(STRATA).fillna("other")
    denom = areas.groupby("stratum")[["covered_ha", "forest_ccap_ha"]].sum()
    denom.loc["all"] = denom.sum()
    rows = []
    for t in thresholds:
        gaps = joined(t)
        gaps["forest_m2"] = gaps.footprint_area_m2 * gaps.forest_ccap_frac
        kept = gaps.forest_ccap_frac >= KEEP_FOREST
        for stratum, g in [("all", gaps)] + list(gaps.groupby("stratum")):
            k = kept[g.index]
            gap_ha = g.forest_m2.sum() / 1e4
            forest_ha = denom.forest_ccap_ha.get(stratum, np.nan)
            rows.append({"threshold_m": t, "stratum": stratum, "gaps": len(g), "gaps_kept": int(k.sum()),
                         "gap_footprint_ha": g.footprint_area_m2.sum() / 1e4,
                         "gap_area_in_forest_ha": gap_ha,
                         "kept_gap_area_ha": g.footprint_area_m2[k].sum() / 1e4,
                         "forest_ccap_covered_ha": forest_ha,
                         "gap_fraction_of_forest": gap_ha / forest_ha if forest_ha else np.nan})
    out = pd.DataFrame(rows)
    OUT.mkdir(parents=True, exist_ok=True)
    out.to_csv(OUT / "gap_area.csv", index=False)
    show = out.copy()
    for c in ("gap_footprint_ha", "gap_area_in_forest_ha", "kept_gap_area_ha", "forest_ccap_covered_ha"):
        show[c] = show[c].round(0)
    show["gap_fraction_of_forest"] = (show.gap_fraction_of_forest * 100).round(2)
    print(show.to_string(index=False))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    t = sub.add_parser("table")
    t.add_argument("--threshold", type=float, default=3.0)
    a = sub.add_parser("area")
    a.add_argument("--threshold", type=float, nargs="+", default=[3.0])
    args = p.parse_args()
    if args.command == "table":
        table(args.threshold)
    else:
        area(args.threshold)


if __name__ == "__main__":
    main()

"""Gaps for one site across thresholds and connectivities, plus comparison tables.

    python python/sweep.py                                  # LFDP, the defaults below
    python python/sweep.py --thresholds 2 5 --connectivity 6
    PR_GAPS_SITE=ev1 python python/sweep.py                 # another site

Uses canopy.py's settings for everything else (site, cache, MIN_POINTS, seeded split
off unless PR_GAPS_SEED_THRESHOLD is set). Step 1 builds or reuses the site's distance
cache exactly as canopy.py does; then one gap run per connectivity covers all the
thresholds. Each run is an ordinary canopy.py run in runs/canopy/<site>/gaps/<run-id>/,
so reruns reuse finished work and check_run.py covers them.

Writes runs/canopy/<site>/sweeps/<name>/:
  comparison.csv   one row per connectivity x threshold: counts, volumes, size
                   quantiles, largest-gap share, gaps above size floors
  gaps_long.csv    every gap from every run, tagged with connectivity and threshold,
                   for size-distribution plots
  runs.json        which run folder holds each connectivity
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

THRESHOLDS = [1, 1.5, 2, 3, 4, 5, 8]
CONNECTIVITIES = [26, 6]
SIZE_FLOORS_M3 = [10, 100, 1000]


def summarise(gaps, metadata, connectivity, threshold, run_id):
    volume = gaps["voxel_volume_m3"].to_numpy()
    total = volume.sum()
    row = {
        "connectivity": connectivity,
        "threshold_m": threshold,
        "n_gaps": len(gaps),
        "n_changed_points": int(gaps["n_points"].sum()),
        "voxel_volume_m3": float(total),
        "footprint_area_m2_sum": float(gaps["footprint_area_m2"].sum()),
        "largest_gap_m3": float(volume.max(initial=0)),
        "largest_gap_share": float(volume.max(initial=0) / total) if total else 0.0,
        "median_gap_m3": float(np.median(volume)) if len(volume) else np.nan,
        "p90_gap_m3": float(np.percentile(volume, 90)) if len(volume) else np.nan,
        "median_gap_mean_hag_m": float(gaps["mean_hag_m"].median()) if len(gaps) else np.nan,
    }
    for floor in SIZE_FLOORS_M3:
        row[f"n_gaps_ge_{floor}m3"] = int((volume >= floor).sum())
    row["segmentation"] = metadata["config"].get("seed_threshold") and "seeded" or "components"
    row["run_id"] = run_id
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--thresholds", type=float, nargs="+", default=THRESHOLDS)
    parser.add_argument("--connectivity", type=int, nargs="+", default=CONNECTIVITIES,
                        choices=(6, 26))
    parser.add_argument("--name", help="sweep folder name (default from the settings)")
    args = parser.parse_args()
    thresholds = sorted(set(args.thresholds))

    canopy.prepare_site()
    root = canopy.DATA / "runs" / "canopy" / canopy.SITE
    rows, gaps_long, runs = [], [], {}
    for connectivity in args.connectivity:
        canopy.stamp(f"gaps, {connectivity}-connectivity, thresholds {thresholds}")
        run = canopy.analyze_cache(
            canopy.CACHE, None,
            **canopy.gap_settings(thresholds=thresholds, connectivity=connectivity),
        )
        runs[connectivity] = {"run_id": run["run_id"], "output": run["output"],
                              "segmentation": run["segmentation"]}
        for threshold in run["thresholds"]:
            folder = Path(run["output"]) / canopy.threshold_directory_name(threshold)
            gaps = pd.read_csv(folder / "gaps.csv")
            metadata = canopy.read_json(folder / "metadata.json")
            rows.append(summarise(gaps, metadata, connectivity, threshold, run["run_id"][:16]))
            gaps_long.append(gaps.assign(connectivity=connectivity, threshold_m=threshold,
                                         run_id=run["run_id"][:16]))

    name = args.name or "thr-{}_conn-{}{}".format(
        "-".join(f"{t:g}" for t in thresholds),
        "-".join(str(c) for c in args.connectivity),
        f"_seed-{canopy.SEED_THRESHOLD:g}" if canopy.SEED_THRESHOLD else "",
    )
    out = root / "sweeps" / name
    out.mkdir(parents=True, exist_ok=True)
    comparison = pd.DataFrame(rows).sort_values(["connectivity", "threshold_m"],
                                                ascending=[False, True])
    comparison.to_csv(out / "comparison.csv", index=False)
    leading = ["connectivity", "threshold_m", "run_id"]
    long = pd.concat(gaps_long, ignore_index=True)
    long[leading + [c for c in long.columns if c not in leading]].to_csv(
        out / "gaps_long.csv", index=False)
    canopy.write_json(out / "runs.json", {"site": canopy.SITE, "runs": runs})

    shown = comparison[["connectivity", "threshold_m", "n_gaps", "voxel_volume_m3",
                        "largest_gap_m3", "largest_gap_share", "median_gap_m3",
                        "n_gaps_ge_100m3", "n_gaps_ge_1000m3"]]
    with pd.option_context("display.width", 160, "display.float_format", "{:,.3g}".format):
        print(shown.to_string(index=False))
    print(f"\nWrote {out}")
    canopy.stamp("done")


if __name__ == "__main__":
    main()

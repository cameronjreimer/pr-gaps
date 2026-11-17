"""A work-unit plan holding only some units, for testing step 2 on part of the island.

    python python/subset_plan.py --pairs 30 --out $PR_GAPS_DATA/interim/work_units_ev1
    python python/subset_plan.py --units E0202_N2028_p030 --out DIR
    PR_GAPS_PLAN=DIR python python/island_gaps.py ...

Copies the full plan's rows for the chosen units (or every unit of the chosen pair
ranks), its pairs.csv and the ownership rasters of their tiles, and records the subset
in plan.json, so the island_gaps run ID differs from the full plan's. Unit caches are
shared: units.py finds them by unit ID, whichever plan names them.
"""

import argparse
import shutil
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import PLAN, read_json, write_json  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--pairs", nargs="+", type=int, help="pair ranks (pairs.csv 'rank')")
    which.add_argument("--units", nargs="+", help="unit IDs")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.out.resolve() == PLAN.resolve():
        raise SystemExit("--out must not be the full plan's folder")

    units = pd.read_csv(PLAN / "work_units.csv")
    chosen = units[units["rank"].isin(args.pairs)] if args.pairs else units[units.unit.isin(args.units)]
    if chosen.empty:
        raise SystemExit("No units match")
    if args.out.exists():
        shutil.rmtree(args.out)
    (args.out / "ownership").mkdir(parents=True)
    chosen.to_csv(args.out / "work_units.csv", index=False)
    shutil.copy2(PLAN / "pairs.csv", args.out / "pairs.csv")
    for tile in chosen.tile.unique():
        shutil.copy2(PLAN / "ownership" / f"{tile}.tif", args.out / "ownership" / f"{tile}.tif")
    plan = read_json(PLAN / "plan.json")
    plan.update({"subset_of": str(PLAN), "subset_units": sorted(chosen.unit),
                 "n_units": len(chosen), "n_tiles": int(chosen.tile.nunique())})
    write_json(args.out / "plan.json", plan)
    print(f"{len(chosen)} units in {chosen.tile.nunique()} tiles -> {args.out}")


if __name__ == "__main__":
    main()

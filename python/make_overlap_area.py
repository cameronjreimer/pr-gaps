"""Study area where two flights both have data, for canopy.py's STUDY_AREA.

    python python/make_overlap_area.py                    # EV1 2017 x EV1 2018, the defaults
    python python/make_overlap_area.py PRE POST OUTPUT [--force]

Intersects the two campaigns' exact CHM footprints from the inventory
(derived/inventory/pr_footprints_chm.gpkg, built by `--refine`) and writes the result
in the LAS CRS (EPSG:32620).

Why: canopy.py's exact C2C has no search cap, so a 2017 point far outside the 2018
coverage costs a search through hundreds of metres of empty space. For EV1, 28% of the
2017 area has no 2018 data, and the untiled run spent 3.5 h+ in C2C without finishing.
Those points are dropped afterwards by the coverage mask anyway, so clipping the 2017
points here changes no gap. The 2018 reference stays unclipped, so edge points still
find their true nearest neighbours.

An existing output is left alone unless --force is given, because the distance cache is
keyed on the study-area file's size and mtime.
"""

import argparse
import sys
from pathlib import Path

import geopandas as gpd
from shapely import get_parts, make_valid
from shapely.ops import unary_union

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import DATA, REPO  # noqa: E402

FOOTPRINTS = REPO / "derived" / "inventory" / "pr_footprints_chm.gpkg"
LAYER = "campaign_footprints_chm"
LAS_CRS = "EPSG:32620"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pre", nargs="?", default="PR_5March2017_EV1")
    parser.add_argument("post", nargs="?", default="PR_25April2018_EV1")
    parser.add_argument(
        "output", nargs="?", type=Path,
        default=DATA / "interim" / "sites" / "ev1" / "ev1_overlap.gpkg",
    )
    parser.add_argument("--force", action="store_true", help="overwrite an existing output")
    args = parser.parse_args()

    if args.output.exists() and not args.force:
        print(f"{args.output} exists; leaving it (and any cache built on it) alone. "
              "Use --force to rebuild.")
        return
    footprints = gpd.read_file(FOOTPRINTS, layer=LAYER).to_crs(LAS_CRS)
    shapes = {}
    for campaign in (args.pre, args.post):
        rows = footprints[footprints["campaign"] == campaign]
        if rows.empty:
            raise SystemExit(f"No CHM footprint for {campaign} in {FOOTPRINTS}; run the "
                             "inventory with --refine for it first")
        shapes[campaign] = make_valid(rows.geometry.union_all())
    overlap = make_valid(shapes[args.pre].intersection(shapes[args.post]))
    # Touching boundaries can add lines or points; canopy.py accepts polygons only.
    overlap = unary_union(
        [part for part in get_parts(overlap) if part.geom_type in ("Polygon", "MultiPolygon")]
    )
    if overlap.is_empty:
        raise SystemExit(f"{args.pre} and {args.post} do not overlap")

    result = gpd.GeoDataFrame(
        {"pre": [args.pre], "post": [args.post], "source": [f"{FOOTPRINTS.name}:{LAYER}"]},
        geometry=[overlap],
        crs=LAS_CRS,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result.to_file(args.output, layer="study_area")
    pre_ha = shapes[args.pre].area / 1e4
    print(f"{args.output}: {overlap.area / 1e4:.0f} ha where both flights have data "
          f"({100 * overlap.area / shapes[args.pre].area:.0f}% of {args.pre}'s {pre_ha:.0f} ha)")


if __name__ == "__main__":
    main()

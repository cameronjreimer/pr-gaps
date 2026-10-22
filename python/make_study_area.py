"""Buffer a study-area polygon for canopy.py's STUDY_AREA.

    python python/make_study_area.py                     # LFDP + 50 m, the defaults
    python python/make_study_area.py SOURCE BUFFER_M OUTPUT [--force]

The source polygons are dissolved and buffered in their own CRS, which must be
projected in metres. The result is written as one polygon in that CRS. An existing
output is left alone unless --force is given, because canopy.py keys its distance
cache on the study-area file's size and mtime: rewriting it, even identically,
makes the existing cache refuse to load.
"""

import argparse
import sys
from pathlib import Path

import geopandas as gpd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import DATA, metric_crs  # noqa: E402

DEFAULT_SOURCE = DATA / "raw" / "shapefiles" / "LFDP" / "LFDP.shp"
DEFAULT_OUTPUT = DATA / "interim" / "sites" / "lfdp" / "lfdp_buf50.gpkg"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("buffer_m", nargs="?", type=float, default=50.0)
    parser.add_argument("output", nargs="?", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--force", action="store_true", help="overwrite an existing output")
    args = parser.parse_args()

    if args.output.exists() and not args.force:
        print(f"{args.output} exists; leaving it (and any cache built on it) alone. "
              "Use --force to rebuild.")
        return
    source = gpd.read_file(args.source)
    if source.crs is None:
        raise SystemExit(f"{args.source} has no CRS")
    metric_crs(source.crs, f"CRS of {args.source}")
    if not source.geometry.is_valid.all():
        raise SystemExit(f"{args.source} contains invalid geometry; repair it first")

    polygon = source.geometry.union_all().buffer(args.buffer_m)
    result = gpd.GeoDataFrame(
        {"source": [args.source.name], "buffer_m": [args.buffer_m]},
        geometry=[polygon],
        crs=source.crs,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result.to_file(args.output, layer="study_area")
    print(f"{args.output}: {source.area.sum() / 1e4:.2f} ha + {args.buffer_m:g} m "
          f"buffer = {polygon.area / 1e4:.2f} ha ({source.crs.to_string()})")


if __name__ == "__main__":
    main()

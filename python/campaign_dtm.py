"""One DTM per 2017 campaign, for height above ground in the island-wide run.

    python python/campaign_dtm.py                     # every 2017 campaign that owns ground in the plan
    python python/campaign_dtm.py PR_12March2017_Guayama PR_5March2017_EV1
    python python/campaign_dtm.py --all-maria         # every 2017 campaign in a Maria pair

hpc-scaling-plan.md §4.3. The download unpacks a campaign's DTM to one of:
  <campaign>_DTM.tif                       tiled campaigns: already one raster, used as is
  <campaign>_DTM/<campaign>_l*s*_DTM.tif   strip campaigns: the strips are merged here,
                                           even when the published mosaic was kept
                                           (one published mosaic is entirely empty)
An archive not yet unpacked (<campaign>_DTM.tif.gz / .tar.gz) is unpacked next to it
first, the way the download does; the archive is kept.

Merging: the strips share a 1 m grid with whole-metre edges and store no-data as NaN
(no nodata tag). Each output cell takes the first strip, in file-name order, with a
finite value there. That is terra::merge's rule, which reproduces the published
mosaics exactly (R/ingest/05_download.R). A GDAL VRT is not used: it turns NaN no-data
into data (README). Strips that disagree where they overlap are counted and reported.

Writes $PR_GAPS_DATA/interim/dtm/:
  <campaign>_DTM.tif   merged strips (float32, NaN no-data, tiled, deflate)
  index.csv            campaign -> the DTM to use, how it was found, valid cells
Each merge is written to a temporary name and renamed when complete; a campaign
already in the index with an unchanged source is skipped.
"""

import argparse
import gzip
import json
import shutil
import sys
import tarfile
from pathlib import Path

import numpy as np
import pandas as pd
import rasterio
from rasterio.windows import Window, from_bounds

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import DATA, GLIHT, PLAN, REPO, file_signature  # noqa: E402

OUT = DATA / "interim" / "dtm"
INDEX = OUT / "index.csv"
BLOCK = 2048  # output rows/columns written per window
CONFLICT_M = 0.01  # strips disagreeing by more than this where they overlap are reported


def geotiff_folder(campaign):
    return Path(GLIHT) / campaign / "lidar" / "geotiff"


def unpack(campaign):
    """Unpack a DTM archive that the download left packed; keep the archive."""
    folder = geotiff_folder(campaign)
    single = folder / f"{campaign}_DTM.tif.gz"
    strips = folder / f"{campaign}_DTM.tar.gz"
    if single.is_file() and not (folder / f"{campaign}_DTM.tif").exists():
        partial = folder / f"{campaign}_DTM.tif.part"
        with gzip.open(single, "rb") as source, partial.open("wb") as target:
            shutil.copyfileobj(source, target, 4 * 1024 * 1024)
        partial.rename(folder / f"{campaign}_DTM.tif")
    if strips.is_file() and not (folder / f"{campaign}_DTM").is_dir():
        partial = folder / f"{campaign}_DTM.part"
        shutil.rmtree(partial, ignore_errors=True)
        with tarfile.open(strips) as archive:
            archive.extractall(partial, filter="data")
        # Some archives hold a top-level folder, others the files themselves.
        tifs = list(partial.rglob("*.tif"))
        partial.mkdir(exist_ok=True)
        final = folder / f"{campaign}_DTM"
        final.mkdir()
        for tif in tifs:
            tif.rename(final / tif.name)
        shutil.rmtree(partial)


def find_dtm(campaign):
    """('mosaic', path) for a raster to use as is, ('strips', [paths]) to merge, or (None, None).

    Strips are merged even when a published mosaic sits beside them: the mosaic of
    PR_17March2017_BG_north_high_alt (every product) is entirely NaN while its 10
    strips hold 6.3 M valid cells. A mosaic is used only when there are no strips.
    """
    folder = geotiff_folder(campaign)
    single = folder / f"{campaign}_DTM.tif"
    if single.is_file():
        return "mosaic", single
    tifs = sorted((folder / f"{campaign}_DTM").glob("*.tif"))
    strips = [tif for tif in tifs if "_mosaic_" not in tif.name]
    if strips:
        return "strips", strips
    if tifs:
        return "mosaic", tifs[0]
    return None, None


def merge_strips(strips, output):
    """First finite value per cell, in strip order. Returns (valid cells, strip valid cells, conflicts)."""
    sources = [rasterio.open(path) for path in strips]
    try:
        first = sources[0]
        for source in sources:
            if source.crs != first.crs or source.res != first.res:
                raise ValueError(f"{source.name}: CRS or resolution differs from {first.name}")
            offset = np.array([source.bounds.left - first.bounds.left,
                               source.bounds.top - first.bounds.top]) / np.array(first.res)
            if not np.allclose(offset, np.round(offset), atol=1e-6):
                raise ValueError(f"{source.name}: not on the same grid as {first.name}")
        left = min(s.bounds.left for s in sources)
        bottom = min(s.bounds.bottom for s in sources)
        right = max(s.bounds.right for s in sources)
        top = max(s.bounds.top for s in sources)
        xres, yres = first.res
        width, height = int(round((right - left) / xres)), int(round((top - bottom) / yres))
        transform = rasterio.transform.from_origin(left, top, xres, yres)
        profile = {"driver": "GTiff", "width": width, "height": height, "count": 1,
                   "dtype": "float32", "crs": first.crs, "transform": transform,
                   "nodata": np.nan, "compress": "deflate", "predictor": 3, "tiled": True,
                   "blockxsize": 256, "blockysize": 256, "BIGTIFF": "IF_SAFER"}
        strip_valid = conflicts = valid = 0
        with rasterio.open(output, "w", **profile) as target:
            for row in range(0, height, BLOCK):
                for col in range(0, width, BLOCK):
                    window = Window(col, row, min(BLOCK, width - col), min(BLOCK, height - row))
                    bounds = rasterio.windows.bounds(window, transform)
                    block = np.full((window.height, window.width), np.nan, np.float32)
                    for source in sources:
                        s = source.bounds
                        if (s.left >= bounds[2] or s.right <= bounds[0]
                                or s.bottom >= bounds[3] or s.top <= bounds[1]):
                            continue
                        part = source.read(1, window=from_bounds(*bounds, transform=source.transform),
                                           boundless=True, fill_value=np.nan).astype(np.float32)
                        finite = np.isfinite(part)
                        strip_valid += int(finite.sum())
                        overlap = finite & np.isfinite(block)
                        conflicts += int((np.abs(part[overlap] - block[overlap]) > CONFLICT_M).sum())
                        fill = finite & ~np.isfinite(block)
                        block[fill] = part[fill]
                    valid += int(np.isfinite(block).sum())
                    target.write(block, 1, window=window)
        return valid, strip_valid, conflicts
    finally:
        for source in sources:
            source.close()


def count_valid(path):
    with rasterio.open(path) as raster:
        return sum(int(np.isfinite(raster.read(1, window=window)).sum())
                   for _, window in raster.block_windows(1))


def signature(paths):
    return [file_signature(str(p)) for p in paths]


def save_index(index):
    if index.empty:
        return
    counts = ["n_inputs", "valid_cells", "strip_valid_cells", "overlap_conflicts"]
    index[counts] = index[counts].astype("Int64")
    index.rename_axis("campaign").reset_index().to_csv(INDEX, index=False)


def default_campaigns(all_maria):
    if all_maria:
        pairs = pd.read_csv(REPO / "derived" / "inventory" / "pr_repeat_campaign_pairs.csv")
        maria = pairs[(pairs.epoch_a == "2017_pre") & (pairs.epoch_b == "2018_post")
                      & (pairs.overlap_ha >= 25)]
        return sorted(set(maria.campaign_a))
    pairs_file = PLAN / "pairs.csv"
    if not pairs_file.is_file():
        raise SystemExit(f"No work-unit plan at {PLAN} (run python/plan_units.py), or name "
                         "campaigns / use --all-maria")
    pairs = pd.read_csv(pairs_file)
    return sorted(set(pairs.loc[pairs.owned_ha > 0, "campaign_a"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("campaigns", nargs="*", help="2017 campaigns (default: those owning ground in the plan)")
    parser.add_argument("--all-maria", action="store_true", help="every 2017 campaign in a Maria pair")
    args = parser.parse_args()
    campaigns = args.campaigns or default_campaigns(args.all_maria)

    OUT.mkdir(parents=True, exist_ok=True)
    index = pd.read_csv(INDEX).set_index("campaign") if INDEX.is_file() else pd.DataFrame()
    failed = []
    for campaign in campaigns:
        try:
            unpack(campaign)
            kind, source = find_dtm(campaign)
            if kind is None:
                raise FileNotFoundError(f"no DTM under {geotiff_folder(campaign)}; download it "
                                        "(scripts/02_download.R --products dtm)")
            inputs = [source] if kind == "mosaic" else source
            sources = json.dumps(signature(inputs))
            if campaign in index.index and index.at[campaign, "sources"] == sources \
                    and Path(index.at[campaign, "path"]).is_file():
                print(f"{campaign}: up to date ({index.at[campaign, 'source']})")
                continue
            if kind == "mosaic":
                path, valid, strip_valid, conflicts = source, count_valid(source), None, 0
            else:
                path = OUT / f"{campaign}_DTM.tif"
                partial = path.with_suffix(".part.tif")
                valid, strip_valid, conflicts = merge_strips(source, partial)
                partial.replace(path)
            if valid == 0:
                raise ValueError(f"{path} has no valid cells")
            index.loc[campaign, ["path", "source", "n_inputs", "valid_cells", "strip_valid_cells",
                                 "overlap_conflicts", "sources"]] = [
                str(path), kind, len(inputs), valid, strip_valid, conflicts, sources]
            note = "" if kind == "mosaic" else (
                f" from {len(inputs)} strips ({strip_valid - valid:,} overlapping cells, "
                f"{conflicts:,} disagreeing by > {CONFLICT_M:g} m)")
            print(f"{campaign}: {kind}, {valid:,} valid cells{note}")
        except Exception as error:  # report every campaign, then fail
            failed.append(campaign)
            print(f"{campaign}: FAILED: {error}")
        save_index(index)
    save_index(index)
    print(f"{len(campaigns) - len(failed)} of {len(campaigns)} campaigns have a DTM; index: {INDEX}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

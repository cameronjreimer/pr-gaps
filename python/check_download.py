"""Check that the inputs the island-wide run needs are on disk and complete.

    python python/check_download.py                     # LAS of the Maria campaigns (2017 -> 2018 pairs >= 25 ha)
    python python/check_download.py --all               # LAS of every campaign in the inventory
    python python/check_download.py --products dtm      # DTMs of the 2017 Maria campaigns
    python python/check_download.py --products las,dtm

Compares derived/inventory/pr_files.csv with $PR_GAPS_GLIHT (default
$PR_GAPS_DATA/raw/gliht).

LAS: the inventory's sizes come from the server's directory listing, which rounds them
("527M", "1.2G"), so a size within 5% + 1 MiB counts as complete; a truncated download
is far outside that. A leftover .part means an interrupted download.

DTM: only the 2017 campaigns are needed (height above ground comes from the 2017
flight). The download unpacks each one to <campaign>_DTM.tif (tiled campaigns) or to a
<campaign>_DTM/ folder of strip DTMs, with or without a mosaic; an archive not yet
unpacked counts as present, since python/campaign_dtm.py unpacks it.

Exits 1 if anything is missing, short, or left as .part.
"""

import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import GLIHT, REPO  # noqa: E402

INVENTORY = REPO / "derived" / "inventory"
MIB = 1024 * 1024
PRODUCTS = ("las", "dtm")


def maria_campaigns():
    """2017 and 2018 campaigns in a 2017_pre -> 2018_post pair with >= 25 ha overlap."""
    pairs = pd.read_csv(INVENTORY / "pr_repeat_campaign_pairs.csv")
    maria = pairs[(pairs.epoch_a == "2017_pre") & (pairs.epoch_b == "2018_post")
                  & (pairs.overlap_ha >= 25)]
    return set(maria.campaign_a), set(maria.campaign_b)


def report(label, items, show=lambda item: item):
    print(f"{len(items):,} {label}")
    for item in items[:20]:
        print(f"   {show(item)}")
    if len(items) > 20:
        print(f"   ... and {len(items) - 20:,} more")


def check_las(files, root, every_campaign):
    files = files[files["subdir"].str.rstrip("/") == "lidar/las"]
    if not every_campaign:
        pre, post = maria_campaigns()
        files = files[files.campaign.isin(pre | post)]
    print(f"LAS: checking {len(files):,} files from {files.campaign.nunique()} campaigns "
          f"({files.size_bytes.sum() / 1e9:.0f} GB listed) under {root}")

    missing, short, partial = [], [], []
    for row in files.itertuples():
        path = root / row.campaign / "lidar" / "las" / row.name
        if path.with_name(path.name + ".part").exists():
            partial.append(path)
        if not path.is_file():
            missing.append(path)
            continue
        size = path.stat().st_size
        if abs(size - row.size_bytes) > 0.05 * row.size_bytes + MIB:
            short.append((path, size, row.size_bytes))

    report("missing", missing)
    report("left as .part (interrupted)", partial)
    report("with a size far from the listing", short,
           lambda item: f"{item[0]}: {item[1]:,} bytes on disk, ~{item[2]:,} listed")
    ok = not (missing or partial or short)
    print("  All LAS files present and complete." if ok else
          "  Rerun the download (scripts/02_download.R --download all --products las); "
          "it fetches only what is missing.")
    return ok


def dtm_state(root, campaign):
    """How a campaign's DTM is on disk: 'mosaic', 'strips', 'archive' or None."""
    folder = root / campaign / "lidar" / "geotiff"
    if (folder / f"{campaign}_DTM.tif").is_file():
        return "mosaic"
    strips = folder / f"{campaign}_DTM"
    if strips.is_dir():
        tifs = list(strips.glob("*.tif"))
        if any("_mosaic_" not in tif.name for tif in tifs):
            return "strips"  # merged by campaign_dtm.py even if a mosaic is beside them
        if tifs:
            return "mosaic"
    if any((folder / f"{campaign}_DTM.{kind}.gz").is_file() for kind in ("tif", "tar")):
        return "archive"
    return None


def check_dtm(files, root, every_campaign):
    pre, _ = maria_campaigns()
    if every_campaign:
        campaigns = pd.read_csv(INVENTORY / "pr_campaigns.csv")
        pre = set(campaigns.loc[campaigns.epoch == "2017_pre", "campaign"])
    listed = files[(files["subdir"].str.rstrip("/") == "lidar/geotiff")
                   & files.name.str.contains(r"_DTM\.(?:tif|tar)\.gz$")]
    no_dtm = sorted(pre - set(listed.campaign))
    print(f"DTM: checking {len(pre)} 2017 campaigns under {root}")
    states = {campaign: dtm_state(root, campaign) for campaign in sorted(pre)}
    missing = [c for c, state in states.items() if state is None and c not in no_dtm]
    partial = [c for c in sorted(pre)
               if any((root / c / "lidar" / "geotiff" / f"{c}_DTM.{kind}.gz.part").exists()
                      for kind in ("tif", "tar"))]
    counts = pd.Series([s for s in states.values() if s]).value_counts()
    print("  " + ", ".join(f"{n} {state}" for state, n in counts.items())
          + "  (mosaic = ready to use; strips and archive are merged/unpacked by "
            "python/campaign_dtm.py)")
    report("missing", missing)
    report("left as .part (interrupted)", partial)
    report("with no DTM published at all (cannot be downloaded)", no_dtm)
    ok = not (missing or partial)
    print("  All 2017 DTMs present." if ok else
          "  Download them: Rscript scripts/02_download.R --download all --products dtm")
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--all", action="store_true",
                        help="every campaign in the inventory, not just the Maria pairs")
    parser.add_argument("--products", default="las",
                        help=f"comma-separated, from {', '.join(PRODUCTS)} (default las)")
    args = parser.parse_args()
    products = [p.strip() for p in args.products.split(",") if p.strip()]
    unknown = set(products) - set(PRODUCTS)
    if unknown:
        parser.error(f"unknown product(s) {', '.join(sorted(unknown))}; choose from {', '.join(PRODUCTS)}")

    files = pd.read_csv(INVENTORY / "pr_files.csv")
    root = Path(GLIHT)
    checks = {"las": check_las, "dtm": check_dtm}
    results = [checks[product](files, root, args.all) for product in products]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())

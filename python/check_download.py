"""Check that every LAS file in the inventory is on disk, complete, and not a leftover .part.

    python python/check_download.py            # Maria campaigns (2017 -> 2018 pairs >= 25 ha)
    python python/check_download.py --all      # every campaign in the inventory

Compares derived/inventory/pr_files.csv with $PR_GAPS_GLIHT (default
$PR_GAPS_DATA/raw/gliht). The inventory's sizes come from the server's directory
listing, which rounds them ("527M", "1.2G"), so a size within 5% + 1 MiB counts as
complete; a truncated download is far outside that. Exits 1 if anything is missing,
short, or left as .part.
"""

import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import GLIHT, REPO  # noqa: E402

INVENTORY = REPO / "derived" / "inventory"
MIB = 1024 * 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--all", action="store_true", help="every campaign, not just Maria pairs")
    args = parser.parse_args()

    files = pd.read_csv(INVENTORY / "pr_files.csv")
    files = files[files["subdir"].str.rstrip("/") == "lidar/las"]
    if not args.all:
        pairs = pd.read_csv(INVENTORY / "pr_repeat_campaign_pairs.csv")
        maria = pairs[(pairs.epoch_a == "2017_pre") & (pairs.epoch_b == "2018_post")
                      & (pairs.overlap_ha >= 25)]
        files = files[files.campaign.isin(set(maria.campaign_a) | set(maria.campaign_b))]
    root = Path(GLIHT)
    print(f"checking {len(files):,} LAS files from {files.campaign.nunique()} campaigns "
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

    for label, items in (("missing", missing), ("left as .part (interrupted)", partial)):
        print(f"{len(items):,} {label}")
        for path in items[:20]:
            print(f"   {path}")
    print(f"{len(short):,} with a size far from the listing")
    for path, size, listed in short[:20]:
        print(f"   {path}: {size:,} bytes on disk, ~{listed:,} listed")
    for items in (missing, partial, short):
        if len(items) > 20:
            print(f"   ... and {len(items) - 20:,} more")
    ok = not (missing or partial or short)
    print("All LAS files present and complete." if ok else
          "Rerun the download (scripts/02_download.R --download all --products las); "
          "it fetches only what is missing.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

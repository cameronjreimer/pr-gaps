"""Add the lowest 2018 return per 1 m column to a cache made before step 1 recorded it.

    python python/backfill_lowest.py                 # the site canopy.py would run (PR_GAPS_SITE)
    PR_GAPS_SITE=ev1 python python/backfill_lowest.py

Re-reads only the cache's 2018 files (about a third of a fresh step 1 for LFDP/EV1);
distances are not recomputed. Refuses to write if the recomputed 2018 return counts
don't match the cache exactly. Caches made since 2026-11-03 already have it.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)

if __name__ == "__main__":
    canopy.stamp(f"backfill lowest 2018 return: {canopy.CACHE}")
    canopy.backfill_post_lowest(canopy.CACHE)
    canopy.stamp("done")

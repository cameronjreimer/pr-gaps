"""Check that this Python can run canopy.py: imports, CloudComPy, and exact C2C.

    python python/check_env.py

Exits 0 when everything works. The C2C check runs canopy.exact_c2c itself on a
small synthetic pair at map-scale coordinates and compares it with scipy's exact
nearest-neighbour distances, so it also catches CloudComPy API changes and
global-shift mistakes, not just a failed import.
"""

import sys
import tempfile
from pathlib import Path

import numpy as np

# Same order as canopy.prepare(): GDAL-linked packages load before CloudComPy,
# which is where Windows DLL clashes would show up.
import laspy
import pyproj
import shapely
import geopandas
import rasterio
import pyarrow
from scipy.spatial import cKDTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canopy  # noqa: E402

TOLERANCE_M = 1e-4


def main():
    print(f"python {sys.version.split()[0]} at {sys.executable}")
    for module in (np, laspy, pyproj, shapely, geopandas, rasterio, pyarrow):
        print(f"  {module.__name__:<10} {module.__version__}")
    try:
        cc = canopy.import_cloudcompy()
    except RuntimeError as exc:
        print(f"FAIL: {exc}\n  cause: {exc.__cause__!r}")
        return 1
    print(f"  cloudComPy {getattr(cc, '__version__', 'imported')}")

    rng = np.random.default_rng(0)
    corner = np.array([200_000.0, 2_030_000.0, 100.0])  # EV1-like UTM 20N coordinates
    pre = rng.uniform(0, 50, (20_000, 3)) + corner
    post = rng.uniform(0, 50, (20_000, 3)) + corner
    low, high = np.minimum(pre.min(0), post.min(0)), np.maximum(pre.max(0), post.max(0))
    shift = -(low / 2 + high / 2)
    with tempfile.TemporaryDirectory(prefix="canopy-check-") as folder:
        canopy.exact_c2c(
            Path(folder), pre, post, np.ones(len(pre), np.uint8), shift, 2, 5_000, cc
        )
        distances = np.load(Path(folder) / "c2c.npy")
    error = np.abs(distances - cKDTree(post).query(pre)[0]).max()
    if not error <= TOLERANCE_M:
        print(f"FAIL: CloudComPy C2C differs from exact nearest neighbour by {error:.3g} m")
        return 1
    print(f"OK: CloudComPy C2C matches exact nearest neighbour (max error {error:.1e} m)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

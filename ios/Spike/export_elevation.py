"""Export a cached DEM grid as raw little-endian Float32 for the spike app.

Reads the derived grid DemProvider would read (run `python -m scripts.fetch_dem`
first), keeps its north-first row order, and writes grid_y * grid_x floats.
Spike only; phase 1 replaces this with a proper exporter for all grid sizes.

    venv/bin/python ios/Spike/export_elevation.py 256 280
"""

import hashlib
import sys
from pathlib import Path

import numpy as np

BOUNDS = (37.44, 37.95, -122.65, -122.15)  # config.fog_bounds_*
REPO = Path(__file__).resolve().parents[2]


def main() -> int:
    grid_x, grid_y = int(sys.argv[1]), int(sys.argv[2])
    lat_min, lat_max, lon_min, lon_max = BOUNDS
    raw = f"{lat_min:.6f},{lat_max:.6f},{lon_min:.6f},{lon_max:.6f},{grid_x}x{grid_y}"
    key = hashlib.sha1(raw.encode()).hexdigest()[:20]
    grid = np.load(REPO / "backend" / ".dem-cache" / f"dem-{key}.npy")
    assert grid.shape == (grid_y, grid_x), grid.shape
    out = Path(__file__).parent / "FogSpike" / "Resources" / f"elevation-{grid_x}x{grid_y}.f32"
    grid.astype("<f4").tofile(out)
    print(f"wrote {out.relative_to(REPO)} ({grid.min():.0f}-{grid.max():.0f} m)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

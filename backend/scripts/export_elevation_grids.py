"""Export the cached DEM grids the iOS app ships with.

The app never fetches elevation: it bundles the same derived grids
DemProvider reads, one per grid preset the client offers, as raw little-endian
float32 in north-first row order. Run fetch_dem first so the cache is warm:

    cd backend && python -m scripts.fetch_dem
    python -m scripts.export_elevation_grids

Writes ios/FogMap/FogMap/Resources/Elevation/sf-<x>x<y>.f32.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.config import settings  # noqa: E402
from app.providers.dem import _cache_key  # noqa: E402
from app.schemas import Bounds  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
CACHE = REPO / "backend" / ".dem-cache"
OUT_DIR = REPO / "ios" / "FogMap" / "FogMap" / "Resources" / "Elevation"
# Keep in step with GridPreset in ios/FogMap and GRID_PRESETS in fog-map.html.
PRESETS = [(160, 176), (256, 280), (340, 372), (420, 420), (560, 612)]


def main() -> int:
    bounds = Bounds(
        lat_min=settings.fog_bounds_lat_min, lat_max=settings.fog_bounds_lat_max,
        lon_min=settings.fog_bounds_lon_min, lon_max=settings.fog_bounds_lon_max,
    )
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for grid_x, grid_y in PRESETS:
        path = CACHE / f"dem-{_cache_key(bounds, grid_x, grid_y)}.npy"
        if not path.exists():
            sys.exit(f"missing {path.name}: run `python -m scripts.fetch_dem --grid {grid_x}x{grid_y}`")
        grid = np.load(path)
        assert grid.shape == (grid_y, grid_x), grid.shape
        out = OUT_DIR / f"sf-{grid_x}x{grid_y}.f32"
        grid.astype("<f4").tofile(out)
        print(f"wrote {out.relative_to(REPO)} ({grid.min():.0f}-{grid.max():.0f} m)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

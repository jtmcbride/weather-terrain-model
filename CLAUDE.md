# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Full stack (API on :8000, static frontend on :8080)
docker compose up --build

# Tests (no network in the test env; both upstreams are stubbed)
pip install -r backend/requirements-dev.txt
cd backend && python -m pytest
python -m pytest tests/test_fog_model.py::test_fog_pours_through_the_gap_rather_than_over_the_crest

# API alone, without Docker
cd backend && uvicorn app.main:app --reload

# Populate the DEM cache (optional, but makes fog renders instant)
cd backend && python -m scripts.fetch_dem              # all four client grid sizes
python -m scripts.fetch_dem --grid 256x280 --zoom 12
```

`pytest.ini` sets `asyncio_mode = auto` (no `@pytest.mark.asyncio` needed) and
promotes `DeprecationWarning` from `app.*` to an error. `conftest.py` puts
`backend/` on `sys.path`, so run pytest from `backend/`.

The `venv/` at the repo root holds only numpy and rasterio for the root-level
`download_bay_area_dem.py` scratch script — it is **not** the backend
environment and has no fastapi or pytest.

## Architecture

Two endpoints share a FastAPI app (`backend/app/main.py`) but are otherwise
separate lineages. Read `README.md` for the physical reasoning; this section
covers the wiring and the invariants that are easy to break.

### `/v1/forecast-grid` — the legacy elevation-aware path

`services/grid_builder.py` + `features/terrain.py`. Lapse-rate residual IDW over
a Northern California domain, using `elevation_penalized_distance`, which blends
horizontal separation with elevation *difference*. That is a **similarity**
metric, not a barrier metric — fine for temperature, wrong for fog. Its leakage
across a ridge is pinned as a deliberate regression test
(`tests/test_dem_and_terrain.py::test_elevation_penalised_distance_leaks_across_a_ridge`).
Do not "fix" it; the fog path exists because of it.

### `/v1/fog-grid` — the marine-layer model

Three stages, in `main.fog_grid`:

1. **Diagnose the slab** (`features/fog.py::diagnose_slab`) — one base `B` and
   one top `H` for the whole domain, from the pressure-level inversion, with
   observed ceilings, LCL, and fogged/clear station elevations as hard
   constraints. Horizontally uniform on purpose: a smeared top would blur the
   ridgeline contrast the model exists to reproduce.
2. **Horizontal influence** (`services/cost_distance.py`) — an 8-connected
   sparse graph over the DEM where climbing toward `H` is expensive and rising
   `block_buffer_m` above it is impassable, solved with
   `scipy.sparse.csgraph.dijkstra`, then IDW over cost distance. Unreachable
   cells get zero influence, which is the correct answer for fog.
3. **Vertical cut** (`features/fog.py::slab_occupancy`) — a feathered level set
   of the ground against `[B, H]`.

`services/fog_model.py::build_fog_grid` multiplies (2) × (3). That product is
what makes the fog edge a hillside contour. **There is no diffusion step and
should not be one** — fog extent is a level set, not a spreading front.

The cost graph is a function of `slab.top_m`, so it is rebuilt on every request
(a handful of vectorised ops). Dijkstra over ~180k cells is ~0.5 s of CPU and is
run via `asyncio.to_thread` — keep it off the event loop or slider drags stall
every other request.

### Raster row order — the recurring trap

- **Fog path is north-first**: row 0 = `lat_max`. `providers/dem.raster_coordinates`,
  `cost_distance.cell_index`, the terrain features in `features/terrain.py`,
  the test fixtures, and the image-source corner order in `fog-map.html` all
  assume this.
- **`grid_builder.coordinate_lattice` is south-first**: row 0 = `lat_min`.

The forecast map renders that legacy raster vertically mirrored (known, see
README). Anything new should use north-first.

### Elevation resolution

`providers/dem.DemProvider.elevation_grid` tries, in order: in-process memo →
on-disk `.npy` → local GeoTIFF via rasterio (if `dem_raster_path` is set) →
Open-Meteo elevation endpoint, caching the result. The cache key is
`(bounds, grid_x, grid_y)`, so **any new grid size or domain is a cold cache**,
and cold at fog resolution means ~1,600 batched network requests. Prefetch with
`scripts/fetch_dem.py --grid` rather than letting the API fall through.

There are two caches, and the distinction matters:

- `.dem-cache/dem-<key>.npy` — the **derived** grid, keyed by
  `(bounds, grid_x, grid_y)`. This is what `DemProvider` reads.
- `.dem-cache/tiles/terrarium-z<z>-x<x>-y<y>.npy` — the **source** tiles, keyed
  by z/x/y. Terrain is static and tiles are immutable, so these are fetched
  exactly once ever. A new grid size, a shifted domain, or a rerun after a
  failure all resample from these locally with no network (56 tiles / ~14 MB
  over the default domain; cold 8.5 s, warm 0.9 s).

So when a grid size or domain changes, run `fetch_dem` — it is nearly free.
Never add a network round trip to the render path to work around a cold cache.

`fetch_dem` downsamples tiles by **maximum**, not mean: for a barrier model the
highest ground in a cell decides whether fog crosses, and an averaged-away crest
is a wall the model would walk straight through. At 420 × 420 this reads Twin
Peaks 271 m (actual 281) and Mount Davidson 281 m (283); sharp isolated peaks
come in low, which is a resolution limit rather than a bug.

`settings.dem_cache_dir` defaults to `/app/.dem-cache`, the path *inside the
container*. Compose bind-mounts `./backend/.dem-cache` there so a host-side
prefetch is what the API reads; `fetch_dem` falls back to that repo-local path
when the configured one is unwritable. Pillow is needed only to decode
downloaded tiles and lives in `requirements-dev.txt` — the API image copies
`app`, not `scripts`.

### Degradation is a feature, not an error path

`visibility` and `boundary_layer_height` are model-dependent on Open-Meteo.
`providers/open_meteo.py` requests them, retries once without them on a 400, and
records what was dropped in `ForecastPoint.missing`. `features/fog.py` then falls
back to dewpoint depression plus low cloud, and Espy's approximation for the
base. METAR fetch failure is caught and downgraded the same way. Every such path
appends to the response's `warnings` array — that array is part of the API
contract, so new fallbacks belong in it rather than in a log line or a 5xx.

### Configuration

Everything tunable lives in `app/core/config.py` (pydantic-settings). Every field
is settable as an env var of the same name via `.env`; do not scatter constants
into modules. Request-level overrides (`terrain_routing`, `cost_beta`,
`fog_top_override_m`) are in `schemas.FogGridRequest`.

### Frontend

`frontend/*.html` are standalone static pages — no build step, no bundler,
MapLibre GL from a CDN, served by nginx. The API base URL is a text field in the
UI, defaulting to `http://localhost:8000`; CORS origins are allowlisted in
`main.py`.

`fog-map.html` builds its layers on `style.load`, **not** `load` — `load` waits
for every source, so a slow or firewalled basemap host would stop the fog from
ever appearing. It offers a drape mode (fog painted on the terrain surface) and
a volume mode (extruded columns, coarsened to ~5,000, taking max fog and max
elevation per block so thin ridges survive). Opacity comes from `fog_fraction`
directly — deliberately not a colour ramp.

Terrain tiles in the client come from the same AWS `elevation-tiles-prod`
Terrarium source as `scripts/fetch_dem.py`, so the surface the model cuts
against and the surface on screen are the same dataset. Keep it that way.

## Testing notes

`tests/terrain_fixtures.py` provides synthetic terrain reproducing the SF
blocking geometry — a north-south ridge with a Golden-Gate-like gap
(`peninsula`) and a cone for contour checks (`conical_hill`). Model behaviour is
asserted as physics, not as golden values: fog holds to the ridge and stops, the
boundary lands on the hill rather than in open ground, raising the top swallows
the crest, the edge traces an elevation contour. New model work should be
expressed the same way.

`tests/test_api.py` monkeypatches `main.client.forecast_points`,
`main.client.elevations`, `main.metar_client.observations`, and swaps `main.dem`
for a `tmp_path`-backed provider. Module-level singletons in `main.py` are the
seam — patch them there.

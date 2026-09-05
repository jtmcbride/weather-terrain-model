# Terrain-Aware Weather Model

Real hourly weather forecasts across Northern California with **elevation-aware
interpolation**, plus a **San Francisco marine-layer fog model** that keeps fog
on the correct side of a ridge.

## Two endpoints

The web client renders the fog as a slab against real 3D terrain, so the fog
edge follows the hillside and the marine layer visibly pours through the Golden
Gate rather than over the Marin Headlands.

| Endpoint | What it does |
| --- | --- |
| `POST /v1/forecast-grid` | Elevation-aware IDW over temperature, precipitation, wind, humidity, dewpoint, visibility and low cloud across a Northern California domain. |
| `POST /v1/fog-grid` | Diagnoses the marine layer over the Bay Area and renders it against the DEM, with terrain-routed horizontal influence. |

## How the fog model works

San Francisco fog is not diffuse haze that spreads until something stops it. It
is a stratus slab of cool saturated marine air under a subsidence inversion,
with a base `B` and a top `H`. The inversion is a lid — the layer does not thin
gradually with altitude, it ends.

That matters because the hills doing the blocking sit inside the band where `H`
lives on a summer day (200–500 m): Twin Peaks 281 m, Mount Sutro 274 m, Mount
Davidson 283 m, the Marin Headlands ridge 280–340 m, Mount Tamalpais 784 m.

So the model does not diffuse fog outward until a hill blocks it. It computes:

**fog exists where the terrain is below the fog top and the air is saturated**

which makes the fog boundary a *level set* — the intersection contour of the `H`
surface with the DEM. A contour of a height surface against terrain is, by
construction, a line that traces the shape of the hill. Fog pouring over the
Marin Headlands is not a special case bolted on; it is what the model produces.

The grid is built in two separable steps:

1. **Horizontal** — how much marine air reaches each cell, interpolated between
   observations along cost-distance paths that route *around* terrain standing
   above the inversion rather than straight through it.
2. **Vertical** — whether the ground at that cell lies inside the slab, via a
   feathered level set against the DEM.

Multiply them and the fog edge follows a hillside contour instead of fading out
in a circle around the nearest station.

### Why cost distance replaced the elevation-penalized metric

`features/terrain.py` blends horizontal separation with elevation *difference*.
That is a similarity metric, not a barrier metric: it says two points at the
same elevation are meteorologically alike. Defensible for temperature under a
lapse rate; exactly wrong for fog. Predicting at the Mission with the project's
own defaults (λ = 0.62, p = 2.4):

| Influencing station | Ground distance | Elevation | Penalized *d* | IDW weight |
| --- | --- | --- | --- | --- |
| Sunset District (across the ridge) | 6.6 km | 15 m | 0.0463 | **1.53×** |
| Twin Peaks summit (line of sight) | 2.9 km | 281 m | 0.0553 | 1.00× |

The Sunset is 2.3× farther away and behind a 281 m wall, and still outweighs the
station you can see from the target. Setting λ = 0 does not help — plain IDW has
no barriers either. This is pinned as a regression test in
`tests/test_dem_and_terrain.py`.

Cost distance replaces that: an 8-connected graph over the DEM where climbing
toward the inversion is expensive and rising through it is impossible, solved
with `scipy.sparse.csgraph.dijkstra`. An observation in the Sunset can then only
reach the Mission by routing through the Golden Gate or the San Bruno Gap.

Measured effect on synthetic ridge terrain, with a fogged station west and a
clear station east (`tests/test_fog_model.py`):

- **With routing** — marine influence holds above 0.95 right up to the ridge,
  then drops to 0 at the crest. The boundary lands *on the hill*.
- **Without routing** — influence fades smoothly and crosses 0.5 about 4 km west
  of the hill, in open ground where nothing is stopping it.

## Data sources

- **Forecast** — Open-Meteo hourly, including `relative_humidity_2m`,
  `dew_point_2m`, `cloud_cover_low`, and pressure-level temperatures at
  1000/950/925/900/850 hPa used to locate the inversion.
- **Observations** — METARs from the NOAA Aviation Weather Center (free, no key)
  for twelve Bay Area stations. KHAF (coastal) versus KSFO (bay side) is the
  canonical pair that disagrees when the hills hold fog on one side.
- **Terrain** — Terrarium-encoded elevation tiles from the public AWS
  `elevation-tiles-prod` bucket (free, no key) via `scripts/fetch_dem.py`, cached
  to disk. Falls back to the Open-Meteo elevation endpoint when the cache is
  cold, or reads a local GeoTIFF if `dem_raster_path` is set and rasterio is
  installed.

### Model-dependent variables

`visibility` and `boundary_layer_height` are not published by every Open-Meteo
model. The client requests them, retries without them on a 400, and reports what
was dropped. When `visibility` is unavailable the fog diagnosis falls back to
dewpoint depression (`T − Td < 2.5 °C`) plus low cloud cover, and Espy's
approximation (`B ≈ 125 · (T − Td)` m) for the deck base. Responses carry a
`warnings` array saying which path was taken.

## API

```http
POST /v1/fog-grid
Content-Type: application/json

{
  "hour_index": 0,
  "grid_x": 256,
  "grid_y": 280,
  "terrain_routing": true,
  "fog_top_override_m": null
}
```

Returns row-major `fog_fraction` (0–1, drives render opacity), `visibility_m`,
`elevation_m`, and `surface_state` per cell, plus the diagnosed `slab` and the
stations used.

`surface_state` is what a person standing there would experience:

| State | Meaning |
| --- | --- |
| `above_deck` | In sun above the inversion, looking down at a white sea |
| `in_fog` | Inside the slab, visibility under a kilometre |
| `under_deck` | Below the cloud base — grey overhead, but you can see |
| `clear` | No marine air here at all |

Useful knobs: `terrain_routing: false` renders the no-barrier baseline for
comparison, and `fog_top_override_m` explores "what does the city look like at a
250 m marine layer".

At the default 256 × 280 grid a fog grid builds in ~0.2 s; at the 420 × 420
maximum (~100 m cells) it takes ~0.5 s.

## Local workflow

```bash
cp .env.example .env                          # optional
cd backend && python -m scripts.fetch_dem     # optional, but makes renders instant
docker compose up --build
# Fog map:  http://localhost:8080/fog-map.html
# Forecast: http://localhost:8080/weather-terrain-map.html
# API docs: http://localhost:8000/docs
```

Tests:

```bash
pip install -r backend/requirements-dev.txt
cd backend && python -m pytest
```

## The web client

`frontend/fog-map.html` is a MapLibre GL map with 3D terrain. Two render modes:

- **Drape** — the fog field painted onto the terrain surface. Cheap, full
  resolution, and the fog edge traces the topography because the data does.
- **Volume** — one extruded column per cell, from the ground up to the
  inversion. Because `fill-extrusion-height` is measured from the terrain,
  `top − ground` puts every column's roof at the same absolute altitude, so the
  slab has a genuinely flat top you can see from the side. Coarsened to about
  5,000 columns, taking the max fog and max elevation per block so a thin ridge
  is not averaged away.

Opacity comes from `fog_fraction`, not from a colour ramp — fog is not a heat
map, and a blue-to-red scale would read as a data overlay rather than weather.

Camera presets frame the cases worth looking at: the Marin Headlands from the
Pacific, Twin Peaks from the Sunset, and the Golden Gate gap. The **fog top**
slider is the demo: drag it through about 280 m and watch the layer swallow
Twin Peaks. The **terrain routing** switch turns cost distance off, so you can
see the fog walk straight through the hills that should be stopping it.

Terrain comes from the same Terrarium tiles as `scripts/fetch_dem.py`, so the
surface the model cuts against and the surface you see are the same dataset.

The map builds its fog layers on `style.load` rather than `load`: `load` waits
for every source to finish, so a basemap host that is slow or firewalled would
otherwise stop the fog from ever appearing.

### Populating the DEM cache

```bash
pip install -r backend/requirements-dev.txt   # Pillow decodes the tiles
cd backend && python -m scripts.fetch_dem
```

Downloads the elevation tiles covering the fog domain, max-pools them onto the
model grid, and writes the result where `DemProvider` looks. After this the API
never calls the Open-Meteo elevation endpoint for that viewport.

Terrain is static and Terrarium tiles are immutable, so the decoded tiles are
themselves cached, one `.npy` per `z/x/y`, under `.dem-cache/tiles`. That is the
source data rather than a derived product, so it is fetched exactly once: a
second grid size, a shifted domain, or a rerun after a failed download all
resample locally with no network at all. Over the default domain that is 56
tiles and about 14 MB.

```
cold      56 tiles downloaded    8.5 s
warm       0 tiles downloaded    0.9 s
--grid 300x320 (new size)        0.3 s
```

The resampled cache is keyed by `(bounds, grid_x, grid_y)`, so the script
defaults to writing every resolution the client offers. Pass `--grid 256x280`
for just one, or `--bounds` for a different domain; both reuse whatever tiles
are already on disk. `--no-tile-cache` bypasses the tile cache, and
`--tile-cache-dir` moves it.

`.dem-cache` is bind-mounted into the API container, so a prefetch run on the
host is what the running API reads. It is gitignored: 14 MB of tiles is
reproducible in under ten seconds, so it is not worth committing.

Downsampling by *maximum* is deliberate: for a barrier model what decides
whether fog crosses a ridge is the highest ground in the cell, and a crest
averaged away is a wall the model would let fog walk through. Against known
summits at 420 × 420 (~110 m cells) this reads Twin Peaks 271 m (actual 281),
Mount Davidson 281 m (283) and Hawk Hill 272 m (280). Sharp isolated peaks
still come in low — Mount Tamalpais reads about 60 m under — which is a
resolution limit, not a bug; raise the grid or the zoom if you need those.

## Status and next steps

Implemented: fog fields and METAR ingest, the SF domain with a cached DEM and
raster terrain features, marine-layer slab diagnosis, cost-distance
interpolation behind `/v1/fog-grid`, and the 3D web client.

Not yet built:

1. **Validation against observed fog.** The GOES-18 ABI `3.9 µm − 11.2 µm`
   brightness-temperature difference is the standard fog/stratus mask and is
   available from the public `noaa-goes18` S3 bucket. Scoring the predicted mask
   against it, and holding out KHAF/KSFO, is the only honest way to tune the
   cost-distance parameters.
2. **Advection.** Treating the layer as shallow water with terrain as bathymetry
   and advecting `H` with the 10 m wind would make fog flow through the Gate and
   spill down the lee, rather than being re-diagnosed each hour.
3. **In-city observations.** SFO is the only ASOS in San Francisco, so the model
   has nothing telling it the Mission is clear while Ocean Beach is not. The
   ridge blocking works, but without a station on each side the contrast across
   it is a gradient rather than an edge. Weather Underground or Synoptic PWS
   data would fix this and is the single highest-value input left.

### Response size

A 420 × 420 grid is four arrays of 176,400 values and serialises to about
4.7 MB of JSON, most of it the `surface_state` strings. Fine over localhost,
worth compressing or trimming before this goes anywhere real. The client
defaults to 256 × 280.

### Known issue, not introduced here

`grid_builder.coordinate_lattice()` emits rows south-first (index 0 = `lat_min`),
but `drawField()` in the forecast map draws row 0 at the top of the canvas, i.e.
north. The existing `/v1/forecast-grid` raster is therefore rendered vertically
mirrored. The fog path deliberately uses north-first raster order throughout
(`providers/dem.py`, and the image-source corner order in `fog-map.html`) and is
unaffected; fixing the legacy path means flipping one of the two, which changes
the existing endpoint's output ordering.

## Scope of the model

This is a diagnostic and kinematic model, not a large-eddy simulation. It will
not give you fog *formation* timing, tendrils curling around individual
buildings, or the sharp advection front people watch move up Market Street in
twenty minutes. It will give you the fog/clear line landing on the correct side
of a ridge, the right neighborhoods on the right side of it, spill through the
Golden Gate and the San Bruno Gap, and an edge that traces topography.

# FogSpike — phase 0 Mapbox spike

Throwaway app that answers "can Mapbox Maps SDK for iOS render this fog model?"
before any of the model is ported. The fog field is **synthetic** (the vertical
level set times a west-to-east fade, `SyntheticFog.swift`) — renderer test only.

```bash
brew install xcodegen
cp Secrets.example.xcconfig Secrets.xcconfig   # paste a Mapbox public token
venv/bin/python ios/Spike/export_elevation.py 256 280   # from the repo root
cd ios/Spike && xcodegen generate && open FogSpike.xcodeproj
```

Without a token the app falls back to a style with no Mapbox-hosted sources;
terrain, drape and volume checks all still run. Launch arguments set the initial
state for unattended screenshots:
`-camera overview|oblique|side -mode drape|volume -lighting flat|3D -budget N
-top M -style light|dark|monochrome -cornerMarker YES -alphaTest YES -orbit YES -hideControls YES`.

## Findings (MapboxMaps 11.32.0, iPhone 18 Pro simulator, 2026-10-18)

| Check | Result |
|---|---|
| Terrarium terrain from AWS `elevation-tiles-prod` | Works: `RasterDemSource.encoding = .terrarium`. Same dataset as the backend DEM. |
| Image source draped on terrain | Works. Raster layers drape automatically. |
| Corner order | North-first TL, TR, BR, BL is correct: the raster's top-left marker lands on the vector NW corner, and the drape's holes land on Mt Tam, Twin Peaks and San Bruno Mountain. |
| Drape update cost (768×840 bitmap) | ~8.5 ms CPU to build, ~0.7 ms `updateImageSource`. No flicker with `rasterFadeDuration = 0`. |
| Volume, ~11k columns | Build 3–5 ms, GeoJSON parsed and ready in ~180 ms. |
| Volume, ~45k columns | Build 14 ms, ready ~840 ms: too slow to drag a slider. Keep the ~12k budget. |
| Alpha in `fill-extrusion-color` | **Not transparency.** Alpha darkens the colour (it is treated as premultiplied) and only `fill-extrusion-opacity` makes columns see-through. Same conclusion as MapLibre: density stays in lightness. |
| Lighting | v11 ambient + directional (`setLights(ambient:directional:)`) clearly beats the web page's flat viewport light: side walls go soft grey instead of dark, and the deck reads as cloud. Use 3D lights. |
| Frame rate while orbiting | 60 fps in drape, 11k and 45k volume — but on the simulator, which renders on the Mac's GPU. **Needs a device run.** |
| Token without a secret | SPM resolved and built with no secret download token. |
| Basemap: `light` | Loads, and alignment holds against real geography, but **white fog is nearly invisible** on it at density 0.5. |
| Basemap: `dark` | Fog reads clearly as a grey veil with the hills breaking through. |
| Basemap: Standard, `monochrome` theme, `dusk` preset | Fog invisible until the drape sets `rasterEmissiveStrength = 1`: Standard's light presets shade every layer, so the fog was being darkened into the ground. With it, the best-looking of the three. |

Also learned:

- **Inline styles finish loading inside `MapView`'s initialiser**, so an
  `onStyleLoaded` observer attached afterwards never fires. Create the map with
  `styleURI: nil`, attach observers, then `loadStyle(_:completion:)`.
- **Volume roofs step** where neighbouring blocks sample terrain at different
  centroids — the same artefact as the web page. Not a Mapbox problem.
- **Image sources are linear in Web Mercator, the grid is linear in latitude.**
  Over 37.44–37.95° that misplaces rows by up to 49 m north-south mid-domain:
  a quarter cell at 256×280, half a cell at 560×612. The web page has the same
  offset. Fix in phase 3 by sampling bitmap rows at Mercator-spaced latitudes.
- **On Standard, don't call `setLights`.** It replaces the style's own light
  preset (the volume run at "dusk" came out in daylight). Use the `lightPreset`
  config, and set `fillExtrusionEmissiveStrength` on the volume as well as
  `rasterEmissiveStrength` on the drape.
- Basemap labels draw on top of both fog layers. Decide in phase 3 whether
  that's wanted (it keeps the map readable) or whether fog goes in a slot above
  the labels.
- The no-token style has no sky, so pitched views show black above the
  horizon. The Mapbox styles include atmosphere; add `Atmosphere` regardless.

## Still open

1. Run on a device: frame rate while orbiting at the 12k budget, and the image
   update under a slider drag.

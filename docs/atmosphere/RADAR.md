# Atmosphere — Radar & Maps Decision Record

The research behind the RADAR screen, recorded so nobody relitigates it without
new facts. Live probes dated 2026-08-31; provenance detail in
`docs/atmosphere-architecture.md` §5. The tier-2 interactive view described
below is **built** (app build `b7`) and is the default; Classic RIDGE2 remains
the fallback and the manual option.

## The constraint that shapes everything

**`api.weather.gov` serves no radar pixels.** Verified against the NWS FAQ and
by live probe. The weather API gives us the radar *station id* (`/points` →
`radarStation`, e.g. `KAMX`) and nothing visual. Radar imagery must come from
somewhere else.

## Tier 1 — Classic: RIDGE2 pre-rendered imagery

The Classic radar view is NWS RIDGE2 static imagery:

```
https://radar.weather.gov/ridge/standard/{SITE}_0.gif       (latest frame)
https://radar.weather.gov/ridge/standard/{SITE}_loop.gif    (animation)
https://radar.weather.gov/ridge/standard/CONUS_0.gif        (national)
https://radar.weather.gov/ridge/standard/CONUS_loop.gif
```

Live-verified: 200, `image/gif`. Why this stays in the product:

- **Public domain** (NWS product) — no basemap licensing problem at fleet scale,
  no key, no account.
- **Boundaries, cities, and warning polygons are already composited in** by NWS
  — the hardest part of a radar view ships in the pixels.
- One `<img>` tag. It is the view that survives when the interactive stack's
  services misbehave — the interactive mode auto-falls back here (with a note)
  after a catalog failure or three imagery errors, and the toolbar's Classic /
  Interactive buttons switch manually (Interactive doubles as retry).

## Tier 2 — Interactive: composed images over one shared bbox (BUILT)

What the earlier revision of this document called "the V2 path" shipped in app
build `b7`, built from the live-verified NOAA `mapservices.weather.noaa.gov`
spec. It is deliberately "composed image per view + overlays", not a tile map,
because that is what the public services actually support (see the slippy-map
section below).

### The four-layer `<img>` stack

All layers are exported against the **same** bbox and pixel size, so they align
without any client-side projection math. Bottom to top, over a dark ground:

1. **Reference boundaries** — `nws_reference_maps/nws_reference_map/MapServer`
   `export`, `layers=show:2,3` (states + counties), transparent png32.
1. **Radar frames** — `radar/radar_base_reflectivity_time/ImageServer`
   `exportImage`, one `<img>` per catalog frame time; animation crossfades by
   toggling a `show` class every 500 ms, only advancing onto frames that have
   finished loading.
1. **WWA warning polygons** — `WWA/watch_warn_adv/MapServer/export`,
   `layers=show:0,1` with a `layerDefs` filter of `sig IN ('W','A')` (warnings +
   watches, no minor advisories cluttering the view), refreshed every 2 minutes,
   honoring the `radar.overlay_alerts` setting.
1. **NHC tropical overlays** — cone, track, and forecast points for each active
   storm whose cone intersects the current view (below), plus a "Tropical: AT1,
   …" chip.

### bbox math (summary)

EPSG:4326, aspect-correct: `latSpan = spanKm / 110.574`;
`lonSpan = latSpan × (W/H) / cos(lat)` — so pixels are square-ish at the view's
latitude and every layer shares the identical
`bbox=<w>,<s>,<e>,<n>&bboxSR=4326&imageSR=4326&size=W,H`. Span presets: **City**
60 km · **County** 150 km · **State** 400 km · **Region** 900 km. Center follows
the property; drag-to-pan translates the layer stack live and recenters +
reloads on release (300 ms debounce, latitude clamped to ±85°); **Home**
recenters on the property.

### The catalog-time rule (never wall-clock)

The ImageServer answers `exportImage?time=<t>` only for timestamps that actually
exist — **a wall-clock time yields a blank PNG**. Frame times are therefore
enumerated from the mosaic catalog:
`ImageServer/query?geometry=<lon>,<lat>&…&outFields=idp_validtime&orderByFields=idp_validtime DESC&resultRecordCount=6`,
sorted ascending, re-queried every 5 minutes (and after a pan, for the new
center). Frame URLs are immutable per timestamp, so the browser cache does the
right thing. If the catalog is empty or unreachable the mode fails over to
Classic; while the first catalog is loading, a single no-`time` export
("latest") frame keeps the screen honest.

### The NHC slot formula and view-local tropical detection

The `tropical/NHC_tropical_weather/MapServer` publishes 15 storm slots — AT1–5,
EP1–5, CP1–5 — with a fixed layer-id arithmetic: slot *i* (0-based across the
three basins) has `points = 4 + 26i + 2`, `track = 4 + 26i + 3`,
`cone = 4 + 26i + 4` (so AT1's cone is layer 8, EP1's is 138).

A slot counts as *active for this view* only when its cone layer answers a
`returnCountOnly` query with an `esriGeometryEnvelope` intersection against the
current bbox — a Florida view never draws a Pacific storm. Results are cached
per-bbox for 30 minutes (cache bounded to 24 entries, since panning mints new
bboxes) and re-probed every 30 minutes while the screen is open.

### Refresh cadences

Animation ~500 ms/frame · warnings 2 min · frame catalog 5 min · tropical probe
30 min — all tickers are inert unless the RADAR screen is active in interactive
mode.

## Why there is no slippy map

Every interactive-map path was investigated and rejected on facts:

- **`mapservices.weather.noaa.gov` has no tile cache.** The
  `radar_base_reflectivity_time` ImageServer answers `exportImage`
  (time-enabled, live-verified) but reports `singleFusedMapCache: false` — there
  is no z/x/y pyramid to feed a slippy map. Composed-image-per-view is possible
  (and is what tier 2 does); smooth pan/zoom tiles are not.
- **OpenStreetMap tile policy prohibits fleet use.** `tile.openstreetmap.org` is
  a donated community resource whose usage policy forbids bulk/distributed-app
  consumption. Shipping it to every controller we install is exactly the
  prohibited pattern. Not negotiable.
- **CARTO (and every commercial basemap) needs an API key** — a secret in a
  keyless product, plus a per-tile bill. Rejected.
- Screen-scraping NWS pages: never.
- USGS National Map imagery is noted as the only clean no-key basemap fallback
  if one is ever needed, with unconfirmed rate/uptime characteristics.

## Honest limits of tier 2

- **Every pan or span change is a full reload** — composed images, not tiles, so
  there is no smooth continuous zoom, and a pan costs a fresh export of every
  layer plus (for a new view) up to 15 tropical count queries.
- **No pinch zoom** — zoom is the four span presets.
- The tropical probe trusts the slot arithmetic above; NOAA republishing the
  service with a different layer layout would break tropical overlays (they fail
  invisible, never wrong — a failed probe just draws no cone).
- Warning polygon styling is the server's, not ours; the `sig IN ('W','A')`
  filter is the only editorial control taken.
- Field verification so far is the phone webview; T3/T4 panel behavior with the
  interactive stack (image sizes, pointer events) is still on the hardware test
  plan.

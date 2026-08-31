# Atmosphere — Radar & Maps Decision Record

The research behind the RADAR screen, recorded so nobody relitigates it without
new facts. Live probes dated 2026-08-31; provenance detail in
`docs/atmosphere-architecture.md` §5.

## The constraint that shapes everything

**`api.weather.gov` serves no radar pixels.** Verified against the NWS FAQ and
by live probe. The weather API gives us the radar *station id* (`/points` →
`radarStation`, e.g. `KAMX`) and nothing visual. Radar imagery must come from
somewhere else.

## V1: RIDGE2 pre-rendered imagery

The default radar view is NWS RIDGE2 static imagery:

```
https://radar.weather.gov/ridge/standard/{SITE}_0.gif       (latest frame)
https://radar.weather.gov/ridge/standard/{SITE}_loop.gif    (animation)
https://radar.weather.gov/ridge/standard/CONUS_0.gif        (national)
https://radar.weather.gov/ridge/standard/CONUS_loop.gif
```

Live-verified: 200, `image/gif`. Why this wins for V1:

- **Public domain** (NWS product) — no basemap licensing problem at fleet scale,
  no key, no account.
- **Boundaries, cities, and warning polygons are already composited in** by NWS
  — the hardest part of a radar view ships in the pixels.
- One `<img>` tag. No tile stack, no projection math, no JS mapping library
  (which the self-contained, no-CDN WebView could not load anyway).
- The site comes straight from `/points.radarStation`; the settings schema's
  `radar.default_view` chooses `station` or `conus`, and `radar.animate` swaps
  the loop/static frames for play/pause. Timestamp shown is fetch time.

**Hardware caveat:** whether Navigator's webview loads external images at all is
unconfirmed until hardware passes (it is on the hardware test plan). If it
cannot, the fallback is the proven `C4:CreateServer` relay pattern (from the
unifi-protect snapshot relay): the driver fetches the GIF and serves it from the
controller. That pattern is held in reserve for exactly this case and is not
used for anything else.

## Why there is no slippy map

Every interactive-map path was investigated and rejected on facts:

- **`mapservices.weather.noaa.gov` has no tile cache.** The
  `radar_base_reflectivity_time` ImageServer answers `exportImage`
  (time-enabled, live-verified) but reports `singleFusedMapCache: false` — there
  is no z/x/y pyramid to feed a slippy map. Composed-image-per- view is
  possible; smooth pan/zoom tiles are not.
- **OpenStreetMap tile policy prohibits fleet use.** `tile.openstreetmap. org`
  is a donated community resource whose usage policy forbids
  bulk/distributed-app consumption. Shipping it to every controller we install
  is exactly the prohibited pattern. Not negotiable.
- **CARTO (and every commercial basemap) needs an API key** — a secret in a
  keyless product, plus a per-tile bill. Rejected for V1.
- Screen-scraping NWS pages: never.
- USGS National Map imagery is noted as the only clean no-key basemap fallback
  if one is ever needed, with unconfirmed rate/uptime characteristics.

## V2 path (enhanced view, flagged, best-effort)

If a zoomable regional view earns its keep later, the researched recipe is:

1. `exportImage` from the `radar_base_reflectivity_time` ImageServer for an
   arbitrary bbox/size/time — one composed radar image per view, no tiles.
1. Overlay **WWA polygons** from the `WWA/watch_warn_adv` MapServer
   (watch/warning/advisory geometry) drawn client-side on a canvas.
1. Self-drawn state/county boundaries from **Census TIGER** vectors (public
   domain), pre-simplified and shipped in the c4z — a custom basemap with zero
   external dependencies.

This is deliberately "composed image + vector overlays", not a tile map, because
that is what the public services actually support. V2 remains optional; V1's
RIDGE2 view is the product commitment.

# Home Guide — design

Status: implemented on `feat/event-tracer` (batch of 2026-11-09);
simulator-verified (`make test`); **bench validation owed**. Driver #1 of
`docs/driver-batch-20261109.md`.

## What it is

A personalised user manual generated from the project and shown on a
Navigator tile: rooms → device groups → how-to paragraph → device chips, a
dealer contact block, dealer notes per room, and a "what to do if" list.
Rebuilt on start, hourly, on action and on a programming command. No cloud.

## Mechanism

| Piece | Choice | Evidence |
| --- | --- | --- |
| Tile | uibutton proxy 5001, `web_view_url` `controller://driver/smartbuildos-user-manual/app/index.html`, `mobile_web_view_enabled`, icons copied from Insights | VERIFIED_BY_EXAMPLE (Atmosphere, Insights, Control4's webview samples) |
| Data plane | LAN relay on **port 47821** (`C4:CreateServer`), page served same-origin as `/app` when the controller address is known, token-gated `/manual` and `/refresh`, tokenless `/ping` and `/app` | MEASURED on Atmosphere (its field finding: the WebView JS API reply channel starved; the relay works) |
| Controller address | `App Relay Address` property, else the first `control4_*` device's bindings through `GetNetworkBindingsByDevice` / `GetBindingsByDevice`, deep-walked | Atmosphere's code, field-measured shapes |
| Token | 32 hex chars from `C4:HMAC` over local entropy, persisted encrypted (`hg_relay_token_v1`) | Atmosphere's posture |
| Project read | `C4:GetDevices({})` → `deviceName`, `driverFileName`, `roomId`, `roomName` | MEASURED (CAPABILITY-MATRIX row 1) |
| Page | plain HTML/JS, text nodes only, phone-first, bottom pill clear of the app bar (`safe-area-inset-bottom` + 10 px) | Atmosphere's WEBVIEW notes |
| Licence | `sbos.license`, SKU `SBOS_USER_MANUAL`; `license.enforces()` stops the relay and republishes the URL; uncertainty never does | charter |

## Pure modules

- `src/usermanual/manual.lua`: classification table (driver file fragments
  first, then device-name fragments; first hit wins), exclusion rules
  (SmartBuildOS drivers, agents, UI devices, WattBox, timers, scenario
  buttons, processors/bridges, no-room devices), notes parser (`Room: text`,
  case-insensitive, joined), deterministic build, plain-text outline.
- `src/usermanual/relay.lua`: routes; reuses `atmosphere.uirelay` parse and
  render so the HTTP shape is identical to the proven one.

## PROBEs and limits (bench)

1. **Page reachability.** Same as Atmosphere's: the tile must load
   `http://<controller>:47821/app?k=…` on a touch screen and in the app on
   the LAN. If the app proxies LAN web views when remote, the guide works
   off-LAN too; that is Atmosphere's field precedent, not measured here.
2. **Port 47821 free** on the controller (nothing else in the house uses
   it; the tracer batch allocates 47821–47823).
3. **Classification coverage.** The rule table was written against the
   owner's 406-file library and Control4's common `.c4i` names. Devices
   that land in "Other equipment" on the bench are the signal to extend it
   (`Print Manual Outline` shows every group).
4. **FileRead of `www/app/index.html`** from `C4Z_ROOT` — Atmosphere does
   exactly this; if it fails the URL falls back to `controller://` with the
   relay in the query and the page still fetches the manual.

## Not included (v1)

- No project-change trigger from the Agent (this driver is not a module);
  hourly rebuild + action + command instead.
- No scenes/lighting-scene listing (no documented enumeration without the
  Agent's catalogue walk).
- No PDF export; the page prints from a browser if the dealer opens the
  relay URL on a laptop.

## Files

`drivers/smartbuildos-user-manual/{driver.xml,driver.lua,driver.c4zproj,www/app/index.html,www/documentation/index.md,www/icons/*}`,
`src/usermanual/{manual,relay}.lua`,
`test/test_usermanual_{model,relay,driver}.lua`.

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Composer lists it as **SmartBuildOS Home Guide** (Experience Button). Online, Manual Status `serving`, Devices In Manual `163 device(s) in 4 room(s); 23 not shown`, Last Rebuilt 07:21:31, App Data Relay `Listening :47821 - serving http://<controller>:47821/…`, licence painted (Enterprise, company).

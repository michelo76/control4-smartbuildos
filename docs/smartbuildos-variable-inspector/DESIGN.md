# Variable Inspector — design

Status: implemented on `feat/event-tracer` (batch of 2026-11-09);
simulator-verified (`make test`); bench validation owed. SKU
`SBOS_VARIABLE_INSPECTOR`; no Agent module (licensing only); relay port 47823.

## What it is

The dealer's Composer Pro variable view, served to Navigator and the Control4
app without a Pro session: device list → one device's variables live → a
persisted watch list with history → a PIN-guarded Set. A debugging tool: it
records no variable values anywhere but memory, and uploads nothing.

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Model (pure) | `src/varinspector/model.lua` | device list/filter, typed snapshots (`flightrecorder.recorder.typedValue`), masking (`flightrecorder.config.isFixedExclusion`), open-device + watch-list listener reconciliation, history rings (`tracer.ring`), Set with refusals by name, read-only flag |
| Relay (pure) | `src/varinspector/relay.lua` | routes over Atmosphere's `uirelay.parse/render`; token wall; PIN only in POST body |
| Driver | `drivers/smartbuildos-variable-inspector/driver.lua` | licensing, Composer surface, relay socket (Atmosphere's `CreateServer` pattern), URL publishing, persistence |
| Page | `www/app/index.html` | vanilla JS, phone-first, polls `/state` (2 s open device, 5 s otherwise), no external assets |

Transport is Atmosphere's measured answer (Doerr touchscreen, 2026-08-31):
the JS API reply channel starved the page, the LAN relay worked. Same-origin
serving from the relay (`http://<controller>:47823/app?k=`) when the
controller address is known; otherwise the c4z page with `?relay=`.

## Rules

- One open device; watched listeners persist across opens; reconciliation
  adds/removes only the difference (tested).
- Masking is the Flight Recorder's fixed credential list; masked variables
  get no listener, no history, no Set.
- Watch list ≤ 64 (ceiling), persisted (`vi_watches_v1`, list only — history
  is memory). History ring 50..200 per watch (the ring's floor is 50).
- Read-only when `license.enforces()` or no Dealer PIN: writes refused by
  name, reads unaffected (charter: enforcement is read-only, never dark).
- Set: `C4:SetDeviceVariable` — **PROBE**. Documented (DriverWorks API,
  Variable section; emulator apidoc `36_variable`), not measured on this
  bench. The driver reports "sent … verify on the next read" and the page
  re-reads the device; a driver that re-asserts its variable will win.

## Bench plan

1. Tile appears in Navigator; `App Data Relay` reads `Listening :47823`; the
   page loads devices on a touch screen AND in the mobile app (remote too:
   same-origin precedent from Atmosphere).
2. Open a light; change it from a keypad; the value updates within 2 s.
3. Watch `LIGHT_LEVEL`; change it; *Watched Variable Changed* fires and
   `LAST_CHANGE` paints; history shows previous values.
4. Set with wrong PIN → refused; right PIN → "sent"; confirm whether the
   light's `LIGHT_LEVEL` actually changes (this settles the PROBE; record it
   here either way).
5. Remove the driver: no further `OnWatchedVariableChanged` in the log.

## Not included (v1)

- No upload of history to SmartBuildOS (no module registration).
- No variable search across all devices (one device at a time by design: a
  300-device project is 300 `GetDeviceVariables` calls).
- No Composer property editing of other drivers (no documented API).

## Tests

`test_varinspector_model.lua` (65), `test_varinspector_relay.lua` (27),
`test_varinspector_driver.lua` (driver under the shim with a scripted Agent).

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Same Dealer PIN "Property Invalid" error as the Dealer Settings Panel on first add; same fix, re-imported as 121857. After the update: Driver Version 20261109.121857, Inspector Mode `read-only (set a Dealer PIN to allow writes)`, App Data Relay `Listening :47823`, Watched `0 of 64`. License Status still `SmartBuildOS Agent Found – Checking…` two minutes after the update (the other drivers took ~5 minutes to paint the tier; re-read).

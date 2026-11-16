# Dealer Settings — design

Status: implemented on `feat/event-tracer` (batch of 2026-11-09);
simulator-verified; bench validation owed. Driver
`drivers/smartbuildos-dealer-panel`, SKU `SBOS_DEALER_PANEL`, pure modules
`src/dealerpanel/{settings,relay}.lua`.

## Problem

Dealers tweak the same handful of values on every service call — motion
timeouts, dim levels, delays — and each lives as a literal inside Composer
programming, reachable only through a Pro session. This driver turns them
into twelve named, typed values that programming reads as variables and the
dealer edits from a Navigator tile behind a PIN.

## Shape

- **Model** (`settings.lua`, pure): a slot is a property quartet `Setting N
  Name / Type / Value / Options`. Types Number (range), Toggle, Text (≤ 200),
  Choice (list ≤ 24). Coercion refuses what does not fit (no clamping);
  numbers compare numerically; choices canonically. `propose()` returns the
  coerced value and whether it changes anything; `equalsText()` is the
  STRING conditional's comparison.
- **One truth**: the Composer property `Setting N Value`. Any write (tile,
  `SET_SETTING`, `TOGGLE_SETTING`) updates the property, the model is
  rebuilt from `Properties`, then variables/event/tile follow. A Composer
  edit of any quartet property triggers the same rebuild and fires *Setting
  Changed* for slots whose name or value moved.
- **Variables**: per slot `SETTING_N` (STRING text form), `SETTING_N_NUMBER`
  (NUMBER: the number, 1/0 for toggles, 0 otherwise), `SETTING_N_NAME`.
  Static, both forms, because a variable's type is fixed in XML while a
  slot's type is the dealer's choice. Plus `CHANGED_SETTING`,
  `CHANGED_VALUE`, `SETTINGS_CONFIGURED`, `PANEL_STATUS`.
- **Conditionals**: twelve STRING conditionals `SETTING_N_IS` (the docs'
  `NAME is LOGIC STRING` form; `TC` reads `tParams.STRING` and `LOGIC`,
  accepting `EQUAL`/`NOT_EQUAL` and `=`/`!=`), one BOOL `PANEL_WRITABLE`.
  Conditionals carry no free-text key parameter in the DriverWorks XML
  (verified in the cached XML docs: List, String, Number, Boolean, Simple,
  Room, Device), hence per-slot conditionals rather than a keyed one.
- **Web view** (Atmosphere's path): uibutton proxy 5001, `web_view_url`
  `controller://driver/smartbuildos-dealer-panel/app/index.html`, icons
  copied from Insights, LAN relay on **port 47822** (`C4:CreateServer`), the
  page served same-origin from the relay when the controller address is
  known (`http://<host>:47822/app?k=<token>`), else `controller://` with
  `?relay=&k=`. Token minted once (HMAC of local entropy), persisted
  encrypted. `URL_CHANGED` on late-init, address change, and a 60 s heal.
  Secondary channel: `UIR`/`RFP` commands `DEALER_GET_STATE`, `DEALER_SET`,
  `DEALER_VERIFY` for the Navigator JS API.
- **PIN gate** (`relay.lua`, pure): no Dealer PIN → every write refused
  `pin_not_configured` (read-only tile); wrong PIN counted, five wrong →
  locked 60 s, *Panel Locked* event once; correct PIN resets. The PIN is a
  PASSWORD property, never in a response or log. The page keeps an entered
  PIN in memory only.
- **Licence**: `sbos.license` SKU `SBOS_DEALER_PANEL`; `license.enforces()`
  → `gReadOnlyReason = "unlicensed"`: relay and programming writes refused,
  reads unchanged; cleared when the status is no longer a definitive
  enforced denial.

## PROBE / unconfirmed

- `C4:HMAC` with `return_encoding = "HEX"` for the token (Atmosphere's
  shipped call; fallback string if it throws).
- Controller address discovery through `GetNetworkBindingsByDevice` /
  `GetBindingsByDevice` deep walk (Atmosphere's field-measured shape);
  **App Relay Address** is the escape hatch.
- The STRING conditional's `tParams` key names (`STRING`, `LOGIC`) come from
  the docs' description macros; `VALUE` is accepted as well. Bench: add a
  "Setting 1 value is 50" conditional and confirm it evaluates.
- Whether Navigator honours `URL_CHANGED` for a tile that is open: known not
  to (Atmosphere); documented as "close and reopen".

## Not included (v1)

- No history of changes beyond *Last Change* and the event.
- No per-setting description text on the tile (name + type + range only).
- No writes to other devices' properties: the driver holds values,
  programming applies them.

## Files

| Path | Role |
| --- | --- |
| `src/dealerpanel/settings.lua` | model, coercion, propose, snapshot |
| `src/dealerpanel/relay.lua` | router (reuses Atmosphere's parse/render) + PIN gate |
| `drivers/smartbuildos-dealer-panel/driver.{xml,lua}` | Composer surface, relay, licence |
| `drivers/smartbuildos-dealer-panel/www/app/index.html` | the tile |
| `test/test_dealerpanel_{settings,relay,driver}.lua` | tests |

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

First add (build 060825) raised Composer **Property Invalid: Error creating property: SmartBuildOS Dealer Settings: Dealer PIN … Object reference not set to an instance of an object** — the driver was still added, but the PIN row was missing. Cause: `<type>PASSWORD</type>`; fixed to `<type>STRING</type><password>true</password>` and re-imported as 121857 (Composer's "Versions are equal — overwrite?" → Yes updates the project instance in place). After the update: Driver Version 20261109.121857, Dealer PIN row present, Panel Status `read-only (set a Dealer PIN to allow edits)`, App Data Relay `Listening :47822 - serving http://<controller>:47822/…`, licence painted (Enterprise, company).

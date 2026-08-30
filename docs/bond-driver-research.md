# Bond Local API → Control4 driver suite — research + design

Status: research complete (from the official OpenAPI spec v3.0.0,
docs-local.appbond.com, pinned at `docs/bond-openapi-v3.0.0.json`).
Nothing field-verified yet; the to-verify list is at the bottom.

## What Bond is

Olibra's Bond products put RF-remote appliances on the LAN:

- **Bond Bridge / Bridge Pro** (`ZZ…`/`ZP…` serials): learns/ships RF remote
  protocols for ceiling fans, fireplaces, motorized shades, awnings, lights.
  One Bridge fronts many **devices**.
- **Smart by Bond (SBB)** (`K…` serials): appliances (fans, dimmers) with the
  same API built in. Each SBB unit is its own HTTP host with exactly one
  device (usually device id `1`).

Either way the integration surface is identical: **one IP + one token = one
Bond unit**, and everything hangs off `GET /v2/devices`.

## API essentials

- Plain HTTP (deliberately no TLS — vendor's position: Wi-Fi password is the
  perimeter). Every endpoint except `/v2/sys/version` and `/v2/token` wants a
  `BOND-Token: <token>` header. 401 ⇒ bad/missing token; 404 with valid JSON
  body ⇒ stale id.
- **Token**: `GET /v2/token` returns `{"locked":1}` normally. It unlocks for
  10 minutes after power cycle (then `{"token":"..."}`), or the user reads it
  from the Bond Home app (Device → ⚙ → Advanced → Local Token). Dealer flow
  for us: paste token into a letterbox property. (PATCH /token with the PIN is
  the take-ownership flow — not our business.)
- **Version probe**: `GET /v2/sys/version` (no token) →
  `{bondid, target, fw_ver, make, model, …}`. Use it to validate the address
  before the token, and to display fw/model.
- **Inventory**: `GET /v2/devices` → `{"_":"hash", "<device_id>":{"_":..}, …}`.
  Then per device `GET /v2/devices/{id}` →
  `{name, type, subtype?, location, actions[], state:{_}, properties:{_}}`,
  and `GET /v2/devices/{id}/state` / `…/properties` for the documents.
- **Types**: `CF` fan, `FP` fireplace, `HT` heater, `MS` shades/awnings,
  `GX` generic, `SW` switch, `LT` light, `BD` bidet. Vendor's own guidance:
  **drive functionality from `actions[]` (features), use `type` only for
  cosmetics** — a CF without `SetSpeed` exists (one-speed fans), an FP can
  have a light, etc.
- **Control**: `PUT /v2/devices/{id}/actions/{Action}` with body `{}` or
  `{"argument": X}`. Blocks ≤7s until the Bond has transmitted. State
  reflects the *assumed* result (RF is one-way for most devices — state is
  tracked, not sensed). Optional `_lock_priority`/`_lock_expiration` fields
  implement a priority lockout; default priority 100. Not used in v1.
- **Hash tree**: every branch carries `"_"` which changes when the subtree
  changes — cheap change detection for polling (`GET /v2/devices` alone tells
  us if ANYTHING changed).
- **Groups** (`/v2/groups`): sharded across Bond units, actions =
  intersection of shard actions, execute on every shard concurrently. C4 has
  its own scenes/rooms; **skip groups in v1** (document as known limitation).
- **Skeds**: on-Bond schedules. C4 has scheduler agent; skip.

### BPUP — push state (the polling killer)

UDP to port **30007** on the Bond. Send `\n` ⇒ reply `{"B":"<bondid>"}\n` and
you're subscribed to `devices/*/state`. Re-send `\n` every 60s (dropped after
125s quiet). Updates arrive as one-line JSON:

```json
{"B":"ZZBL12345","t":"devices/aabbccdd/state","s":200,"m":0,
 "b":{"_":"ab9284ef","power":1,"speed":2}}
```

`t` topic identifies the device, `b` is the full state doc. Beta-status
protocol; design must degrade to hash-polling if no datagrams flow.

### Feature → state/action cheat sheet (what the children map)

| Feature | State vars | Actions we use |
|---|---|---|
| Power | `power` 0/1 | TurnOn/TurnOff/TogglePower |
| Speed | `speed` 1..`max_speed` (property) | SetSpeed(n)/IncreaseSpeed/DecreaseSpeed |
| Breeze | `breeze` [mode,mean,var] | BreezeOn/BreezeOff/SetBreeze |
| Direction | `direction` 1/-1 | SetDirection/ToggleDirection |
| Timer | `timer` secs | SetTimer(s) |
| Light | `light` 0/1 | TurnLightOn/TurnLightOff/ToggleLight |
| UpDownLight | `up_light`,`down_light` | TurnUp/DownLightOn/Off |
| Brightness | `brightness` 1-100 | SetBrightness(pct)+Inc/Dec |
| UpDownBrightness | `up/down_light_brightness` | SetUp/DownLightBrightness |
| ColorTemp | `color_temp` K (min/max props) | SetColorTemp(K) |
| Color | `hsv` {h,s,v} | SetHSV |
| Flame | `flame` 1-100 | SetFlame(n)+Inc/Dec |
| Heat (HT) | `heat` 1-100 | SetHeat + presets |
| FpFan | `fpfan_power`,`fpfan_speed` | TurnFpFanOn/Off/SetFpFan |
| OpenRaiseRetract | `open` 0/1 (+`open_raises`/`open_retracts` props) | Open/Close/ToggleOpen/Raise/Lower |
| Position | `position` 0-100 (0=retracted) | SetPosition/Inc/Dec |
| TDBU | `upper/lower_rail_position` | SetUpper/LowerRailPosition |
| TiltPosition | `tilt_position` deg | SetTiltPosition/ToggleTilt |
| Hold | — | Hold() (stop motion; Somfy RTS: doubles as My-preset when idle) |
| Preset | — | Preset() (position reports -1 after) |
| Battery / Power Supply / Signal | `battery`/`supply_voltage`/`signal` | read-only telemetry |

Position semantics trap: Bond `position` is **0 = retracted (open),
100 = extended (closed)** for normal shades — the C4 blind proxy's level is
conventionally **100 = open**. The child must invert, and honor
`open_raises`/`open_retracts` for awnings/top-down (where open ≠ raised).
`Preset()`/`Hold()` leave position unknown (-1) — the child must tolerate -1.

## Architecture: gateway + function children (the Protect pattern)

One **bond-bridge gateway** instance per Bond unit (Bridge or SBB). Combo
driver, no proxy of its own. Owns: address + token (letterbox → encrypted
persist), version probe, inventory, BPUP socket, hash-poll fallback, and
**one provider CONTROL binding per (device, function)** — because a CF with a
light is TWO Navigator devices (fan + light) in Control4.

Functions derived from `actions[]`, not `type`:

- `FAN` — has SetSpeed/IncreaseSpeed (or TurnOn+type CF single-speed)
  → child **bond-fan**, C4 `fan` proxy (discrete speeds 0..max_speed,
  preset speeds, direction via extras).
- `LIGHT` — has TurnLightOn (main light; up/down variants fold into it in
  v1, UpDownLight can grow dedicated bindings later) → child **bond-light**,
  `light_v2` proxy; dimmer personality iff SetBrightness present, else
  switch.
- `SHADE` — has Open/Close/SetPosition (MS) → child **bond-shade**, C4
  blind proxy; stop button = Hold when available; position inversion +
  `open_raises` handling; positionless shades run open/close/stop only.
- `FIREPLACE` — has SetFlame or (type FP + TurnOn) → child **bond-fireplace**
  (phase 2; flame as a dimmer-style level + on/off, likely `light_v2` proxy
  presented in the Comfort category, plus FpFan as extras — C4's fireplace
  proxy is poorly documented; decide when built).
- `GENERIC` — everything else with TurnOn/TurnOff (GX/SW/HT/BD) → child
  **bond-generic** (relay/switch personality, phase 2).

Binding ids allocated dynamically per function instance (namespace
`bond_<function>`), persisted and re-created in OnDriverLateInit — same
mechanics as the Protect gateway's camera bindings (`lib/bindings.lua`).

Child↔gateway protocol (mirrors PROTECT_*, over bound CONTROL binding +
SendToDevice dual path):

- `BOND_GET_DEVICE` → `BOND_DEVICE` (identity: device id, function, name,
  location, actions, properties incl. max_speed/open_raises, state snapshot)
- `BOND_STATE` — pushed on every BPUP update / poll delta
- `BOND_ACTION` {action, argument} — child asks, gateway PUTs, gateway pushes
  resulting state (the PUT's 200 body is the new action-relevant state; BPUP
  echoes it too — dedupe by state hash `_`)
- Re-ask + 60s retry until answered; state-push-without-identity re-asks
  (the Protect round-3 lesson, baked in from day one).

Auto-provision, auto-rename with the clobber guard, "Print Bindings To Log",
child "Gateway Link" diagnostics — all inherited patterns, reuse the code
shapes from unifi-protect.

Licensing: gateway registers **SBOS_BOND** via `sbos/license.lua`; children
inherit through the gateway. LEGACY until cataloged; add the SKU to
driver_catalog + CI publish map when we cut the first release.

## Transport notes (DriverWorks)

- HTTP: `lib.http` as-is (plain http URLs, no TLS involved at all). Token
  rides as a custom header per request — client takes
  `headers = {["BOND-Token"] = token}`. 401 ⇒ surface "Token rejected" on
  the Bond Status property, never retry-storm (Bond replies instantly).
  Send `User-Agent: SmartBuildOS-Bond/<ver>` (spec recommends identifying;
  BPUP echoes it in `U`).
- BPUP: needs a UDP socket that can *send* to bond:30007 and receive replies
  on the same socket. Plan: `C4:CreateServer(<local port>, "\n", true)` +
  `C4:ServerSend(handle, "\n", bondIp, 30007)` (UDP ServerSend with
  address/port args), datagrams arrive in the global `OnServerDataIn`.
  **TO VERIFY on hardware** — if UDP ServerSend can't target an address, the
  fallback is `C4:NetPortOptions`/network-binding UDP or plain 5s hash
  polling; the state pipeline is transport-agnostic either way.
- Poll fallback (always on, slow): `GET /v2/devices` every 60s compare root
  hash; per-device state only when the hash moved. Tighten to 5s only while
  BPUP is down (Bond Status property shows "Push" vs "Polling").

## Build order

1. `src/bond/api.lua` — client: version probe, token handling, inventory
   walk (devices → info/state/properties), `action()`, hash-diff helpers,
   BPUP frame parser (pure function — testable without sockets). Tests.
2. `drivers/bond-bridge` — gateway per above. Tests
   (test_bond_bridge.lua + globals suite).
3. `drivers/bond-fan` — fan proxy child incl. light-less CF, direction,
   preset speeds. Tests.
4. `drivers/bond-light` — dimmer/switch child (fan lights + LT/SW). Tests.
5. `drivers/bond-shade` — blind proxy child (position/inversion/Hold). Tests.
6. Phase 2: bond-fireplace (+FpFan), bond-generic, Breeze/Timer/Direction
   composer actions + variables, UpDownLight split, groups.

## To verify on hardware

- UDP ServerSend-to-address for BPUP (see above) — THE transport question.
- Whether `PUT …/actions/X` 200 body actually carries usable state (spec
  implies fire-and-check; we re-GET state on 200 as belt+braces).
- C4 fan proxy binding: which proxy XML shape Navigator's fan UI expects on
  current OS (crib from an existing open fan driver if the first attempt
  doesn't render).
- Token letterbox UX: confirm the Bond Home app path (Advanced → Local
  Token) on current app version for the installer guide.
- SBB units: gateway pointed at an SBB fan (device id `1`) — same code path,
  needs one real unit to confirm.

## Sources

- OpenAPI spec: `docs/bond-openapi-v3.0.0.json` (from user download,
  2026-08-30; source docs-local.appbond.com)
- Feature reference (Power…Signal), BPUP, groups, discovery: spec
  `info.description` markdown.

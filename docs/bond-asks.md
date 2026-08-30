# Bond suite — competitive read + differentiation roadmap

Source: Chowmain's public changelog (2019-08 → 2026-08, supplied 2026-08-30)
read as a seven-year field-hardening log. Goal is NOT parity with their
feature list — it is a better driver: everything they learned the hard way
baked in from day one, plus the capabilities their architecture can't reach.

## What their changelog teaches (and where we already are)

| Their lesson (version) | Our status |
| --- | --- |
| BPUP instant feedback vs polling (20221216) | ✅ day one, plus hash-dedupe |
| Stop ≠ stop-shade — it stops TX; Hold stops shades (20190919) | ✅ Stop→Hold from day one |
| `always_send_level` — resend even when level "matches" (20251231) | ✅ we never dedupe outgoing commands |
| Print debugging auto-off after 24h (20240416) | ✅ repo-wide Log Mode expiry |
| Rediscovery load on flaky networks (20200304) | ✅ push + slow hash poll, no rediscovery loop |
| Positional blind state invalid after reboot (20230531) | ✅ persisted inventory + identity, restored at LateInit |
| Binding names/classes collide across suites (Protect lesson too) | ✅ SBOS_ prefixes + "(SBOS)" names |
| Fan Discrete-vs-Nudge increase property (20191101) | ✅ we send discrete SetSpeed; IncreaseSpeed only for cycle |
| PIN + account-code token entry (20201203) | ✅ THIS PASS — documented `PATCH /v2/token {locked:0, pin}` |
| Button Links for keypads: fan/light/blind/fireplace (2019-12) | ✅ THIS PASS |
| Fake movement feedback while a blind travels (20201009) | ✅ THIS PASS — MOVING/STOPPED, `course_time`-aware, not a fixed 20s |
| Scenes support (20240830) | ✅ THIS PASS — surfaced for programming |
| Group Blind driver (20240902) | Deliberately NOT copied — C4 scenes/keypads already group; revisit only if a dealer asks |
| Skeds | Deliberately not surfaced — C4 scheduler owns it |

## Their features still ahead of us (build order)

1. ~~**Heater child with thermostat UI**~~ ✅ BUILT (`bond-heater`):
   thermostatV2, heat-only, Celsius-pinned 0-100 setpoint = SetHeat, blank
   ambient (no invented readings), Extras timer in minutes, relay + button
   links. HT devices with SetHeat derive HEATER; power-only HT stays GENERIC.
2. ~~**mDNS auto-discovery**~~ ✅ BUILT (`src/bond/mdns.lua` + gateway):
   one-shot RFC 6762 resolver for `_bond._tcp.local` with the QU bit
   (unicast replies reach the net-binding UDP socket — same to-verify
   transport as BPUP); Discovered Bonds property, Discover action, startup
   pass, auto-fill of a still-default address, never re-points a
   configured gateway.
3. ~~**Sidekick / keypad support**~~ ✅ BUILT (`bond-keypad`, 8th driver):
   keystream is BPUP-push-only, routed to per-Sidekick children; 8 buttons x
   Tap/Double Tap/Hold Start/Hold End events (their id layout preserved),
   per-key Tap/Double-Tap/Hold button links (hold pushes+releases so a held
   key ramps a bound dimmer), LAST_* variables, battery band events, Learn
   New Sidekick gateway action. The /v2/sidekicks endpoint also hosts Breeze
   weather sensors (ws_id, `state` of measurements) — a bond-weather child
   is the natural follow-on. → ✅ BUILT (`bond-weather`, 9th driver): all
   measurements as variables/properties, transition-only events (rain, wind,
   sun, batteries, freeze, data-lost), TEMPERATURE_VALUE + HUMIDITY_VALUE
   provider connections so the Breeze is any thermostat's outdoor sensor
   (unavailable on no-data, never stale), sidekicks-tree hash polling +
   BPUP state routing in the gateway.
4. ~~**Firefly color devices**~~ ✅ BUILT (`bond-color-light`, 10th driver,
   OS 3.3.0+): light_v2 with color wheel + CCT picker; xy↔HSV↔Kelvin via the
   C4:Color* helpers only (no home-grown colorimetry); color sends h+s and
   leaves brightness alone; CCT clamps to the device's real range or
   degrades to white-HSV without the ColorTemp feature; SetHSV in actions[]
   derives COLOR_LIGHT over LIGHT automatically.
5. Per-shade-type Navigator icons (their Curtain-icon fix) — blind proxy
   SET_TYPE from Bond `subtype` (ROLLER/SHEER/AWNING → type enum).

## Ours they can't match (the actual differentiation)

- **Function-derived children** from `actions[]` — one fan driver clamps to
  real max_speed instead of five per-speed variants; positionless shades
  drop the slider at runtime (SET_HAS_LEVEL) instead of shipping two blind
  drivers.
- **SmartBuildOS platform tie-in**: SBOS_BOND licensing, fleet health,
  Bond-offline → service ticket via the Agent roster path (Protect 9B/9C
  pattern; wire when SKU lands in driver_catalog).
- **Honest state**: unknown position reported as unknown, RF-drift explained
  in docs, no fake 20s feedback when `course_time` gives the real figure.
- Purpose-drawn state-icon set (one language across power/flame/fan tiles).

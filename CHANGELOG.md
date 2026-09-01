# <span style="color:#F97316">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

### Added

- **Bond driver suite** (new, 6 drivers): `bond-bridge` gateway (one per Bond
  Bridge / Smart by Bond unit — token letterbox stored encrypted, inventory sync
  with hash polling, BPUP push updates over UDP, per-function dynamic CONTROL
  bindings, one-button Auto Configure with rename-guarded naming, SBOS_BOND
  licensing) plus native-proxy children: `bond-fan` (fan proxy, speed clamping
  to the device's real max, direction/breeze/timer commands), `bond-light`
  (light_v2; real dimming only where the device has Brightness), `bond-shade`
  (blind proxy; position inversion handled, positionless shades drop the slider
  honestly, Stop = Hold), `bond-fireplace` (five Navigator tiles with a
  purpose-drawn icon set: power, flame level cycle, flame up/down, fireplace
  fan), and `bond-generic` (state-iconed toggle tile + relay connection for
  switches/heaters/bidets). Binding classes are SBOS\_-prefixed so the suite
  coexists with the official Chowmain-built Bond drivers in the same Drivers
  folder. Round 2 (from a study of that suite's seven-year changelog,
  `docs/bond-asks.md`): Bond **scenes** sync with a Run Bond Scene programming
  command; **PIN pairing** (the PIN printed on the unit unlocks the token
  endpoint — no app, no power-cycle); keypad **button links** with LED tracking
  on every child (toggle/up/down/stop per device type); and shade **movement
  feedback** that animates Navigator using the Bond's own `course_time` scaled
  by travel distance instead of a hardcoded delay.

- **Bond Heater** (`bond-heater.c4z`, 7th driver in the Bond suite): heaters
  with adjustable heat levels (Infratech and similar behind a Bridge Pro) as a
  heat-only thermostat whose dial setpoint IS the heat level 0-100 —
  Celsius-pinned so the ring reads unitless, ambient left blank because these
  devices have no sensor. Extras tab carries the auto-off timer in minutes (the
  factory fire-code cap stays in force). Toggle/heat-up/heat-down button links
  with LED tracking, relay connection, Turn On/Off + Set Heat + Set Timer
  programming. HT devices with SetHeat derive HEATER automatically; power-only
  heaters keep the simpler Bond Switch.

- **Bond mDNS auto-discovery**: the gateway searches for `_bond._tcp.local` at
  startup and on demand (Discover Bonds On Network action) with a one-shot RFC
  6762 resolver — the QU bit makes Bonds reply unicast straight to the driver's
  socket, no multicast group membership needed. Every Bond heard lists in the
  Discovered Bonds property as `id @ address` (with setup mode flagged); a
  factory-fresh instance auto-fills its Bond Address with the first Bond heard,
  and a configured gateway is never re-pointed. The DNS wire parser (name
  compression included) is pure and pinned by its own test suite.

- **Bond Keypad** (`bond-keypad.c4z`, 8th driver): Bond Sidekick remotes as
  Control4 keypads. Key presses arrive over the Bond's push protocol (the only
  way it reports them) and become, per key: Composer events (Tap / Double Tap /
  Hold Start / Hold End, 8 buttons, the event-id layout dealers already know),
  Tap and Double-Tap button links that click, and a Hold link that pushes on
  hold-start and releases on hold-end so a held Sidekick key ramps a bound
  dimmer like a real keypad button. LAST_BUTTON / LAST_EVENT / LAST_HOLD_MS
  variables cover any-key programming; coarse battery bands fire Battery
  OK/Low/Critical on transitions; a Learn New Sidekick gateway action opens the
  Bond's pairing window. Sidekicks sync as keypad pseudo-devices, so bindings,
  provisioning and renames reuse the existing machinery unchanged.

- **Bond Weather** (`bond-weather.c4z`, 9th driver): Breeze weather stations as
  Control4 sensors. Every measurement becomes a programming variable
  (temperature both scales, humidity, wind m/s, rain rate, sun level, both
  batteries) with transition-only events — Rain Started/Stopped, Wind and Sun
  Triggered, battery Low/OK for both cells, Freeze Warning, Data Lost/Restored.
  The differentiator: Outdoor Temperature and Outdoor Humidity provider
  connections (TEMPERATURE_VALUE / HUMIDITY_VALUE) turn the Breeze into any
  thermostat's outdoor sensor, reporting unavailable rather than stale when the
  sensor goes quiet. The gateway polls the sidekicks tree hash alongside devices
  and routes pushed weather state through the same pipeline as everything else.

- **Bond Color Light** (`bond-color-light.c4z`, 10th driver, OS 3.3.0+): Firefly
  bulbs and strips as full Control4 color lights — dimmer, color wheel, and
  white color-temperature picker on a light_v2 proxy. All colorimetry goes
  through the OS C4:Color\* conversion helpers; the color wheel sends
  hue+saturation and leaves brightness on the slider (Bond's own
  recommendation), CCT targets clamp to the device's real Kelvin range or
  degrade honestly to white on devices without the ColorTemp feature, and white
  at a known temperature reports back in CCT mode so the picker lands on the
  right tab. Devices with SetHSV derive the color child automatically; plain
  lights keep the simpler driver.

### Fixed

- **Atmosphere off-LAN state:** replaced the Agent-pulls-local-relay path with
  direct HTTPS publishing from Atmosphere. CORE 1 hardware on OS 4.2 proved an
  Agent request to a sibling driver's `CreateServer` listener hangs through both
  loopback and the controller's LAN address. The paired, licensed Agent now
  provisions a bearer cryptographically restricted to that controller,
  `SBOS_ATMOSPHERE`, and the app-token installation; Atmosphere never receives
  the Agent bearer or signing secret. The old pull handler remains for deployed
  drivers, accepts only private relay addresses, and HTTP traces redact the
  frozen `?k=` capability token. The Atmosphere upgrade rotates the token the
  field trace exposed. A new build guard also makes SmartBuildOS licensing
  mandatory for every standalone Control4 driver, with suite children explicitly
  inheriting their licensed parent. Bench builds give every package one shared
  UTC stamp so Composer sees the coordinated upgrade.

## v20260830.122926 - 2026-08-30

### Added

- **Mode Composer: device selection is now discoverable from the Properties
  tab.** A read-only **Devices In Selected Mode** property shows a live count of
  the selected mode's device entries (own + inherited) and, while the mode is
  empty, points at the two setup paths (Capture Current State, or the
  Programming tab's Include Device In Mode command). A **Show Device Setup
  Guide** action prints the full step-by-step to Lua Output, and the dealer
  manual's "Selecting devices" section names both surfaces. Composer offers
  third-party drivers no property-tab device picker, so the property is the
  breadcrumb to where selection actually lives.

## v20260829.222717 - 2026-08-29

### Added

- **SmartBuildOS Mode Composer** (`smartbuildos-mode-composer.c4z`) — a
  state-aware mode engine for Control4: Presence (Home/Away/Vacation) +
  Lifestyle (Movie/Party/Sleep/…) modes with stable ids, single inheritance
  (cycle-refused), Set/Ignore/Restore device behaviors, Capture Current State,
  device groups, transition engine (immediate/graceful/sequenced + departure
  countdown with cancel), per-action delays and criticality, preflight checks,
  keypad BUTTON_LINK slots with a deterministic tap/double/triple/hold gesture
  engine, keypad LED feedback with follow-global-mode and color inheritance,
  multi-signal sensor rules with debounce/cooldown/loop protection, clock
  schedules with presence guards, bounded activation history with "why did this
  happen" detail, dry run + test mode, diagnostic snapshot, atomic JSON
  export/import with a versioned+migratable config envelope, and SmartBuildOS
  licensing (`SBOS_MODE_COMPOSER` — enforcement gates configuration writes only;
  mode activation is operational and never refuses).
- **SmartBuildOS Mode Button** (`smartbuildos-mode-button.c4z`) — Navigator
  Experience button satellite: one instance per mode, icon/name/active state
  pushed by the manager, curated 16-glyph icon library with active/inactive art,
  tap-to-activate with hold-to-confirm double-tap guard, guarded auto-rename.
  Licenses through the manager's entitlement.
- Shared mode-engine library under `src/modes/` (model, store, adapters, plan,
  engine, gesture, led, triggers, history, schedule) — pure,
  dependency-injected, covered by five new test suites (229 checks).

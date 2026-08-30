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

- **Bond mDNS auto-discovery**: the gateway searches for `_bond._tcp.local`
  at startup and on demand (Discover Bonds On Network action) with a
  one-shot RFC 6762 resolver — the QU bit makes Bonds reply unicast straight
  to the driver's socket, no multicast group membership needed. Every Bond
  heard lists in the Discovered Bonds property as `id @ address` (with setup
  mode flagged); a factory-fresh instance auto-fills its Bond Address with
  the first Bond heard, and a configured gateway is never re-pointed. The
  DNS wire parser (name compression included) is pure and pinned by its own
  test suite.

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

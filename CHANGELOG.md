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

## v20260830.122926 - 2026-08-30

### Added

- **Mode Composer: device selection is now discoverable from the Properties
  tab.** A read-only **Devices In Selected Mode** property shows a live count
  of the selected mode's device entries (own + inherited) and, while the mode
  is empty, points at the two setup paths (Capture Current State, or the
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

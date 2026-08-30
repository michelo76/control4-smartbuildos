# SmartBuildOS Mode Composer — PRD (V1) + backlog + gap analysis

Written 2026-08-29 from the master prompt; this document, not the prompt, is
the working specification. Acceptance criteria at the end are the definition
of done for V1.

## V1 requirements

### Engine
- Presence + Lifestyle mode categories; one active per category; simultaneous
  Presence=HOME + Lifestyle=MOVIE. Extensible categories.
- Stable mode ids; create/duplicate/rename/reorder/enable/disable/delete
  without breaking references. No logic keyed on English names.
- Starter templates (Home/Away/Vacation/Sleep/Movie/Party/Morning/Night) that
  select **no devices** without dealer action; suggested icons/colors only.
- Single inheritance with override-only children; circular inheritance
  detected and refused at write time.
- Device behaviors per entry: SET / IGNORE / RESTORE (capability-gated).
- Capture Current State into a mode with per-category counts and a
  captured/unsupported/unavailable/offline report; never a silent fake.
- Device groups (dealer-defined lists + auto categories like "all lights"),
  group targets with device-level overrides; room-grouped views in listings.
- Transition engine: IMMEDIATE / GRACEFUL (ramps) / SEQUENCED (staged with
  delays); per-action delay; departure countdown with cancel; hold-to-confirm.
- Preflight checks (contact/garage/security readiness) with per-check
  WARN/BLOCK/IGNORE dealer policy.
- Action criticality OPTIONAL/NORMAL/CRITICAL with continue/warn/abort
  behavior; partial failure yields SUCCESS_WITH_WARNINGS, never total failure
  from one decorative light.
- Idempotent activation + explicit Reapply; no continuous enforcement.
- Restore-previous for restorable modes (Movie) with graceful handling of
  missing devices.
- Mode duration (auto-exit) for Lifestyle modes; manual-only exit supported.
- Sensor triggers (contact/motion/lock/security/garage via bindings and
  variable listeners) with debounce, AND-conditions, cooldown, loop
  protection, and priority rules (one contact never flips Vacation→Home).
- Schedules: time + days-of-week + presence guard (sunrise/sunset deferred —
  no confirmed official API).
- Occupancy tri-state; confidence scoring reserved for V2.

### Keypads & LEDs
- Named keypad slots (dynamic BUTTON_LINK bindings) the dealer binds in
  Composer; per-slot gesture map (tap/double/triple/hold/long/very-long) with
  sensible default windows and advanced timing config.
- Deterministic gesture FSM — single tap waits while double is possible;
  hold thresholds with LED progress; release-early cancels.
- Multi-mode buttons (tap=Home, double=Away, triple=Vacation, hold=Sleep) as
  a first-class case.
- Mode colors, keypad color inheritance (change Away's blue once), LED state
  vocabulary (inactive/active/activating/warning/failure/countdown),
  Follow-Global-Mode slots, change-deduped hardware writes, LED failure never
  blocks activation.

### Surfaces
- Navigator mode buttons via `smartbuildos-mode-button` child (uibutton,
  curated icon states, active/inactive art, tap=activate with manager-side
  confirm rules).
- Composer: events, commands, variables, conditionals per architecture doc;
  Test Mode (execute + per-device results), Dry Run (plan without execution),
  history view via action, "why did this happen" detail, diagnostic snapshot
  (no secrets), mode preview counts, validation with actionable messages,
  missing-device marking (MISSING, reassign/remove/ignore) — never silent
  deletion.
- Progressive disclosure: simple properties by default; advanced
  (timings, priorities, criticality, occupancy) revealed via a property.

### Platform & licensing
- `SBOS_MODE_COMPOSER` SKU; existing license SDK verbatim; offline behavior
  per charter (grace ladder, fail-open uncertainty); enforcement gates config
  writes + new manual activations only. Catalog seed migration + CI `sku_for()`
  arm. C4Z built by the standard pipeline; version `YYYYMMDD.HHMMSS`.

## V2 / backlog (tracked, not built)
Vacation presence simulation (bounded randomness, reproducible for tests);
advanced preflight (water/leak/pool); occupancy confidence scoring; geofence
event consumption; cloud config backup/restore + device reconciliation;
sunrise/sunset + offset schedules; conditional device states (state IF
condition); user-aware arrival profiles; iOS remote modes via the Agent (never
a raw endpoint; disarm/unlock/garage excluded from remote by policy); energy
modes; safety modes (higher precedence class, reserved in the priority
ladder); richer automation composer; SmartBuildOS web Mode Studio; Navigator
webview panel; favorites.

## Gap analysis (spec vs. repo, 2026-08-29)

| Needed | Exists today | Gap |
| --- | --- | --- |
| Licensing | `src/sbos/license.lua` complete + platform pipeline SKU-generic | Seed migration + CI mapping arm only |
| Proxy command vocabulary | Agent `COMMAND_RUNNERS` (lights/tstat/lock/security/keypad LED) hand-written in `drivers/smartbuildos/driver.lua:1911-2278` | Extract/generalize into `src/modes/adapters.lua`; add shade/fan/room vocab |
| Device classification | Field-proven signature tests in the Agent (thermostat/lock/sensor/keypad/battery) | Same extraction; add light/shade signatures |
| Keypad input | Nothing (no BUTTON_LINK anywhere in repo) | New: slots + gesture FSM |
| LED control | `KEYPAD_ALL_BUTTON_COLOR` identify blip only | New: binding-path LED engine |
| uibutton | `smartbuildos-insights` has a uibutton webview | New: mode-button child with icon states |
| Mode/state/transition/trigger/history engines | Nothing | New — the core build |
| Variables w/ ordering | `lib.values` written, unused | Adopt (first consumer) |
| Dynamic conditionals | `lib.conditionals` written, unused | Adopt |
| Dynamic events | `lib.events` written, unused | Adopt or follow the shipped pcall-AddEvent pattern (decide in impl; shipped pattern is field-proven) |
| Bindings | `lib.bindings` proven in Protect | Reuse for keypad slots + button children |
| Build/test/CI | Complete | Add driver dirs + tests; one CI line |

## V1 acceptance criteria (from spec §126-§135)
1. **Simple Away**: install → license → configure 20 lights Off, 5 shades
   Closed, media rooms Off → keypad slot, Hold 3 s = Away, blue → test → use;
   zero Programming-tab lines.
2. **Multi-gesture button**: tap/double/triple/hold on one slot, reliable, no
   premature single-tap, LED correct.
3. **Global house button**: three Follow-Global slots repaint on presence
   change; recoloring Vacation updates all inheriting slots.
4. **Capture**: manual house state → Capture → Movie; supported captured,
   unsupported reported, values editable, test reproduces.
5. **Inheritance**: Vacation inherits Away; shared change flows through;
   overrides stick; cycles refused.
6. **Sensor return**: Away + front door + disarm → Home; no single-signal
   activation; chatter debounced; Vacation protected by priority.
7. **Partial failure**: 1 offline shade of 50 → 49 execute,
   SUCCESS_WITH_WARNINGS, history names the shade.
8. **Director restart**: config + active state + license survive; no command
   storm; LEDs resync; timers recover.
9. **Internet loss**: everything works offline per charter grace.
10. **Security**: forged/wrong-controller entitlements refused (existing
    suite extended); no secrets in logs/exports.

Known SDK limitations (documented, accepted): no official LED blink (bounded
simulation); no third-party Composer webview tab (properties/actions UX); no
hardware multi-tap guarantee over BUTTON_LINK (own FSM); no confirmed
sunrise/sunset API (V1 schedules are clock-based); uibutton icon set is baked
per c4z (curated library, not user-supplied art).

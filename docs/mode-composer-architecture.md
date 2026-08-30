# SmartBuildOS Mode Composer — Architecture

Status: living document. Written 2026-08-29 before implementation; update when
reality diverges. Companion docs: `control4-capabilities.md` (SDK ground truth),
`mode-composer-prd.md` (requirements + scope), `driver-cloud-charter.md`
(licensing architecture — reused, not duplicated).

## Product thesis

The dealer describes how the house should behave; the driver derives the
programming. A competent dealer must be able to build Away — devices, states,
keypad button, color, test — without opening the Programming tab. Composer
programming is an extension point (events/commands/variables/conditionals), not
a requirement.

## Components

```
drivers/smartbuildos-mode-composer/    Mode Manager — one per project. The engine.
drivers/smartbuildos-mode-button/      Mode Button — uibutton child, one per mode
                                       surfaced in Navigator. UI only; no logic.
src/modes/                             Shared, shim-testable engine modules.
```

The Manager is authoritative (single source of truth, §115). Buttons render and
request; they never decide.

### Shared modules (`src/modes/`)

| Module | Responsibility |
| --- | --- |
| `model.lua` | Mode records (stable ids, categories, desired states, triggers, keypad assignments); inheritance resolution with cycle detection; validation with actionable errors; duplicate/rename that never breaks references. Pure. |
| `store.lua` | Config persistence envelope: `configVersion`, migrations, atomic import (validate → stage → migrate → apply), export with secrets excluded. Pure over an injected persist. |
| `adapters.lua` | Capability-declared device adapters (light, shade, thermostat, fan, lock, security, room/media, contact, relay/generic) + signature-based classification. Declares `canReadState/canSetState/canRestoreState/…`; builds command payloads and state readers. |
| `plan.lua` | Execution planning: resolve mode → inheritance → conditions → groups/devices → preflight → ordered action list with delays and criticality. **Planning never sends commands** — dry run is the plan without the executor. |
| `engine.lua` | Activation lifecycle: idempotency, correlation ids, countdown/cancel, queued throttled execution via an injected `send`, per-action results (`SUCCESS/SENT/SKIPPED/WARNING/FAILED/UNSUPPORTED/TIMEOUT`), aggregation (`SUCCESS/SUCCESS_WITH_WARNINGS/FAILED/CANCELLED/BLOCKED`), restore-previous capture, active-state bookkeeping. |
| `gesture.lua` | Deterministic per-binding gesture FSM: PUSH/CLICK/RELEASE in, `tap/double_tap/triple_tap/hold/long_hold/very_long_hold` out, timer-driven, configurable windows, ambiguity rules (single never fires while double is still possible), missing-release cancellation. Pure + injected timer. |
| `led.lua` | Logical LED state per assignment (`inactive/active/activating/warning/failure/countdown`) → color pair + match-state; change-dedupe so hardware sees only real changes; bounded 1 Hz simulated pulse during transitions only. |
| `triggers.lua` | Sensor/event trigger evaluation with per-source debounce, condition engine (presence/lifestyle is, security state, sensor state, time range, day-of-week), loop protection via activation-context correlation ids, cooldowns against thrash. |
| `history.lua` | Bounded ring of activation records (source, gesture, trigger, results, failures) + "why did this happen" rendering. |
| `schedule.lua` | V1 schedules: time + days-of-week + presence guard; tick-driven; manual activation never corrupts the schedule state. |

All modules are pure or dependency-injected so the existing `test/c4_shim.lua`
harness drives them without hardware.

## Domain model

```lua
Mode = {
  id,            -- "m_" .. C4:UUID at creation; NEVER changes; all references use it
  name,          -- display, freely renameable
  category,      -- "PRESENCE" | "LIFESTYLE" (extensible string, not a boolean)
  kind,          -- template hint: HOME/AWAY/VACATION/SLEEP/... or CUSTOM; never used for logic
  icon, color,   -- color = RRGGBB; keypad assignments may inherit it
  priority,      -- number; conflict resolution input
  enabled, sort_order,
  parent_mode,   -- id or nil; single inheritance, cycle-checked on write
  desired_states = { [deviceId] = {behavior="SET|IGNORE|RESTORE", state={...}, delay_s, criticality="OPTIONAL|NORMAL|CRITICAL"} },
  groups        = { {group_id, state, ...} },   -- group targets, device entries override
  triggers      = { {id, source, conditions={...}, cooldown_s} },
  transition    = { style="IMMEDIATE|GRACEFUL|SEQUENCED", countdown_s, sequence={...} },
  keypad_assignments = { {binding_id, gesture, action, color_inherit} },
  confirm_hold_s,   -- deliberate-activation hold, 0 = off
  duration_s,       -- auto-exit after N seconds, 0 = off (Lifestyle)
  metadata = {},
}
```

Category invariants: at most one active PRESENCE mode; at most one active
LIFESTYLE mode (plus NONE); activating a Lifestyle mode never touches Presence.
Future categories are new strings + their own "active" slot — no rewrite.

Priority/conflict ladder (§25): Emergency/Safety (reserved) > Manual explicit >
Security-driven > Presence automation > Lifestyle automation > Schedule >
Background. Automatic triggers can never override a higher-precedence
activation without an explicit dealer rule; debounce + cooldown prevent thrash.

## Activation pipeline (§43)

```
Resolve mode → resolve inheritance chain → evaluate conditions → resolve
groups/devices → preflight (OK/WARNING/BLOCKING per check) → build execution
plan → [dry-run returns the plan] → execute (queued, throttled, delays) →
collect action results → update mode state + previous-state capture →
LED/Navigator sync → history record → Composer events/variables.
```

Each activation carries `activation_id` (UUID) through logs, results, history,
and any cloud event. Idempotency: re-activating the active mode is a no-op;
`Reapply Mode` is a distinct explicit command. Manual device changes after
activation are not policed (no continuous enforcement in V1).

## Keypads

Dealer flow: an action mints a named dynamic `BUTTON_LINK` consumer binding
("Keypad Slot 1..N") via `lib.bindings`; the dealer binds a keypad button to it
in Connections; commands map gestures on that slot to actions (activate mode X,
toggle, all-off, follow-global). LED feedback rides the same binding
(`BUTTON_COLORS`/`MATCH_LED_STATE`, answering `REQUEST_BUTTON_COLORS`).
Follow-global slots repaint on presence changes only when the color actually
changed. Hold-confirmation and departure countdown reuse the gesture FSM's hold
tracking + the LED pulse simulation. LED failures log and never block execution.

## Navigator

`smartbuildos-mode-button` = uibutton proxy + consumer CONTROL binding
(class `SBOS_MODE_COMPOSER_UI`) + SendToDevice fallback (dual-path, same as the
Protect suite). Manager pushes `{mode_id, name, icon_state, active}`; button
renders via `ICON_CHANGED` and forwards `SELECT` to the manager. The curated
icon library ships as `<state>` entries in the button c4z (active + inactive
art per icon). Buttons inherit everything from the manager — no per-button
configuration beyond "which mode".

## Composer programming surface

- Variables (ordered contract, added via `lib.values`): `CURRENT_PRESENCE_MODE`,
  `CURRENT_LIFESTYLE_MODE`, `PREVIOUS_PRESENCE_MODE`, `PREVIOUS_LIFESTYLE_MODE`,
  `TRANSITIONING`, `CURRENT_MODE_ID`, `LAST_TRIGGER`, `LAST_TRIGGER_DEVICE`,
  `LAST_TRIGGER_TYPE`, `LAST_ACTIVATION_TIME`, `LAST_ACTIVATION_RESULT`,
  `OCCUPANCY_STATE`, `WARNING_COUNT`.
- Events: static core set (presence changed, lifestyle changed, activation
  begin/complete/fail/warning, countdown begin/cancel) + dynamic per-mode
  "<Mode> Activated" via `C4:AddEvent` (ids allocated once per mode id, frozen,
  persisted).
- Commands: `Activate Mode` (DYNAMIC_LIST of modes), `Deactivate Lifestyle
  Mode`, `Restore Previous Mode`, `Cancel Transition`, `Reapply Mode`, `Run
  Preflight`, `Capture Current State`.
- Conditionals: dynamic per-mode "is active" via `lib.conditionals` +
  static category-level ones.

## Occupancy (§24)

V1 holds a tri-state `OCCUPANCY_STATE` (UNKNOWN/OCCUPIED/UNOCCUPIED) derived
from explicit rules (presence mode + configured sensors). The model reserves a
confidence-score field so V2 scoring slots in without schema change.

## Persistence & versioning

One config envelope under `lib.persist` key `ModeComposerConfig`:
`{configVersion=1, modes, groups, slots, settings}`. Every write goes through
`store.lua` (validate → serialize). Migrations are `store.MIGRATIONS[n]`
functions applied in order at load. History persists separately
(`ModeComposerHistory`, bounded, best-effort). Active-mode state persists as
`{presence_id, lifestyle_id, timestamp}`; on restart the engine restores the
*logical* state and resyncs LEDs/variables but **does not** re-send device
commands. Export = the envelope minus nothing secret (it contains no secrets);
import validates + migrates + applies atomically, never corrupting current
config on malformed input. The envelope is JSON (not serialized Lua tables) so
a future Driver Cloud backup can carry it unchanged; device references include
stable metadata (name, room, proxy class) for future reconciliation (§53).

## Licensing & Driver Cloud

Reuse verbatim: `license.setup({sku = "SBOS_MODE_COMPOSER"})`,
`EC.SBOS_ENTITLEMENT`, `EC.REFRESH_LICENSE`, the four License properties.
Enforcement (only when `license.enforces()`, which requires server
mode=enforce AND a definitive deny): **configuration writes and new manual
activations refuse; sensor/schedule automation, LED sync, and everything
already configured keep working.** A license failure never strands a house —
uncertainty fails open per the charter, and we never disable the currently
active mode. Platform work: one catalog seed migration
(`SBOS_MODE_COMPOSER`) + one `sku_for()` arm in `publish-to-store.yml`.
Everything else (refresh eligibility, purchases, Studio, store) is
SKU-generic — verified 2026-08-29.

Cloud events (low-volume, mode-level only): rides the existing Agent roster /
event path in a later phase; V1 ships local-first with zero cloud dependency
(§62 non-negotiable).

## Security stance (§61, §106)

Sensitive actions (disarm, unlock, garage open) are never part of any template,
never auto-suggested, and require explicit dealer configuration with a
per-action acknowledgement property. No remote activation surface exists in V1;
the future path is the authenticated Agent, never a raw endpoint. Preflight and
security arming honor `PARTITION_ARM` only with dealer-entered configuration.
User codes are letterboxed into encrypted persist and never logged or exported.

## Restart resilience (§49)

`OnDriverInit`: restore bindings, values (variable order), config, active
state. `OnDriverLateInit`: re-add events, register variable listeners, replay
properties, license setup, resync LEDs, resume countdown/schedule/duration
timers from persisted deadlines. No mass re-send of the active mode.

## Performance guardrails (§48, §107)

No polling storms: device state is read on demand (capture/preflight/restore)
and tracked via variable listeners only for configured triggers + security.
Execution queue: batched sends with configurable inter-command delay (default
50 ms) and a serial queue per activation; timers are pooled (gesture per active
slot, one engine tick, one schedule tick). Tested at 20/100/250/500 device
plans in the shim.

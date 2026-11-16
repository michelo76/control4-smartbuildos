# Logic Pack — design

Status: implemented on `feat/event-tracer` (batch of 2026-11-09);
simulator-verified (`test_logic_engine.lua` 79 checks, `test_logic_driver.lua`
59 checks); bench validation owed. SKU `SBOS_LOGIC_PACK`, combo driver,
no Agent module (licensing only).

## What it is

Programming primitives Composer lacks, keyed by a programmer-typed name:
counters, flags, one state machine, debounce, throttle, once-per-day,
cancellable named timers. One driver per project; keys are project-wide.
Pure engine `src/logic/engine.lua` (injected clock, timers, calendar);
`driver.lua` maps engine events to Composer events, variables and the slot
properties.

## Conditionals: what the docs allow (VERIFIED_BY_DOCS)

DriverWorks fundamentals, chapter 10 (cached at
`control4-director-emulator/.cache/docs/docs-driverworks-fundamentals/source/includes/10_conditionals/`):
a `<conditional>` has a `<type>` of SIMPLE, BOOL, NUMBER, STRING, LIST, ROOM
or DEVICE and `TestCondition(name, tParams)` receives **one** value:
`tParams.VALUE` plus `tParams.LOGIC` (EQUAL, NOT_EQUAL, and for NUMBER/LIST
the four ordered comparisons). There is no `<param>` list and no second
value, so "counter KEY is at least N" cannot be one conditional. The design
therefore offers:

- `COUNTER_SLOT_1..8` (NUMBER, LOGIC + INTEGER): the counter mapped to the
  slot by the `Counter Slot N Key` property. Eight slots is the trade-off
  between Composer clutter and real use.
- `FLAG_SET`, `TIMER_RUNNING`, `ONCE_TODAY_DONE` (STRING): the VALUE is the
  key; `=` means the thing holds, `!=` means it does not. Documented in the
  condition statement itself so the dealer sees it in Composer.
- `STATE_IS` (STRING, EQUAL/NOT_EQUAL against the state name).
- `PACK_ACTIVE` (BOOL).

`C4:EvaluateExpression` exists in the docs; the engine compares in pure Lua
instead (testable under the shim, same vocabulary).

The vendored `handlers.lua` dispatches `TestCondition` to
`TC[name](name, tParams)` — note the name arrives first, so every TC
function here takes `(_, tParams)`.

## Rules (all tested)

| Primitive | Rule |
| --- | --- |
| Keys | trimmed, lower-cased, non-alphanumerics → `_`, ≤ 40 chars; empty refused; ≤ 200 keys per kind |
| Counters | integers, clamped ±1e9; non-integer BY/VALUE refused; same value is not a change |
| Flags | set/clear/toggle; a no-op change fires nothing |
| State | one string ≤ 60; same state fires nothing; last 10 transitions kept |
| Debounce | restart-on-call, fires once after the quiet window; 0 = immediate; ≤ 1 h |
| Throttle | leading edge only, suppressed calls counted; ≤ 1 h |
| Once per day | local calendar day from `os.date("%Y-%m-%d")`; rolls at local midnight; pruned every 10 min |
| Timers | restart re-arms from now; cancel silent; ≤ 7 days; restored timers: overdue fire at once marked late, future re-armed with remaining |
| Read-only | `license.enforces()` → every mutation refused with "read-only", events 8/9 on transition, reads unaffected |
| Persistence | one key `lp_state_v1`, written 2 s after a change and on destroy; debounces are not restored |

## Composer surface

14 commands, 7 actions, 9 events, 19 variables (`COUNTER_1..8`, state,
last-trigger/timer/counter/flag/once keys, `PACK_STATUS`), 13 conditionals,
properties incl. `Counter Slot 1..8 Key`, `Summary`, `Last Trigger`, `Last
Refusal`. A refused command never halts programming: it is named in `Last
Refusal` with the reason.

## Clock

Sub-second `socket.gettime()` where the controller offers it (debounce and
throttle windows are in milliseconds), `os.time()` otherwise; the test pins
it through `LOGIC_PACK_NOW`.

## Not included (v1)

- Per-room keys (keys are project-wide; prefix them by hand, e.g. `kitchen_motion`).
- Sequence detection (press A then B within N s) and interval repeaters:
  the timer + counter primitives compose them in programming.
- Any Agent module / upload: nothing leaves the controller.

## Bench checks owed

1. Conditionals with LOGIC/VALUE show in Composer's conditional picker as
   described (NUMBER with the operator list; STRING with = / !=).
2. `C4:SetVariable` on `COUNTER_n` NUMBER variables accepts Lua numbers.
3. Timer accuracy over a Director restart (late flag) on Beta Site 2.

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Online, Pack Status `active`, Summary `0 counter(s), 0 flag(s), 0 timer(s) running`. Licence painted after the same ~5-minute `Checking…` window as the other new drivers.

# SmartBuildOS Logic Pack

The small things Composer programming never had: counters, flags, a named
state, "only once per day", "wait until it has been quiet for two seconds",
"at most once a minute", and timers you can cancel. One driver per project,
any number of independent keys, everything persisted across restarts.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a
SmartBuildOS system. The Agent is the licensing authority (SKU
`SBOS_LOGIC_PACK`): **License Status** shows this driver's standing. A
definitive licence denial with enforcement on makes the pack **read-only**:
commands are refused and say so under **Last Refusal**, conditionals and
variables keep answering, nothing is lost.

## Setup

<!-- walkthrough: Set up Logic Pack -->
1. Install and pair the SmartBuildOS Agent from Composer's Agents tab.
1. Add this driver (one per project, anywhere; a Utility room is fine).
1. Optionally map up to eight counters to the `COUNTER_1..8` variables with
   the **Counter Slot N Key** properties, so programming can read them as
   numbers and the **Counter slot N** conditionals can compare them.

![Logic Pack in Composer: the Properties tab, status at the top and settings below](images/properties.jpg)

![The Actions tab](images/actions.jpg)

## Keys

Every primitive is addressed by a **KEY** you type in programming. Keys are
normalised: trimmed, lower-cased, punctuation and spaces become `_`, 40
characters at most. `Good Night`, `good night` and `GOOD_NIGHT` are the same
key. An empty key is refused.

## Primitives

| Command | What it does |
| --- | --- |
| Increment Counter (KEY, BY) / Decrement Counter | Adds or subtracts BY (default 1). Fires *Counter Changed*; `LAST_COUNTER_KEY` / `LAST_COUNTER_VALUE`; the slot variable when mapped. |
| Set Counter (KEY, VALUE) / Reset Counter (KEY) | Sets a counter outright, or back to 0. |
| Set Flag / Clear Flag / Toggle Flag (KEY) | Booleans. Fires *Flag Changed* only when the value actually changes. |
| Set State (STATE) | One named state for the whole project. Fires *State Changed* with `CURRENT_STATE` and `PREVIOUS_STATE`, only when it differs. |
| Debounce (KEY, MILLISECONDS) | Restarts KEY's quiet timer. *Debounced Trigger* fires once KEY has been quiet for that long; `LAST_TRIGGER_KEY` says which. 0 fires at once. |
| Throttle (KEY, MILLISECONDS) | *Throttled Trigger* fires now unless KEY fired within the window; otherwise the call is counted and dropped (no trailing fire). |
| Once Per Day (KEY) | *Once Per Day Passed* fires the first time today, by the controller's local calendar day. The day rolls at local midnight, not 24 hours after the last pass. |
| Start Timer (KEY, SECONDS) / Cancel Timer (KEY) | *Timer Expired* fires once after SECONDS (`LAST_TIMER_KEY`); restarting re-arms from now; cancel is silent. After a controller restart a timer whose time passed fires immediately with `LAST_TIMER_LATE` True; one still in the future keeps its remaining time. |
| Reset All (WHAT) | Counters, Flags, Timers, or Everything (also clears once-per-day marks, throttle history and the state). |

## Conditionals

Composer conditionals carry one value with an operator, so the pack offers:

- **Counter slot 1..8** `is = / != / < / <= / > / >= N` — the counter mapped to
  that slot.
- **Flag is set** `= key` (set) or `!= key` (not set).
- **Current state** `= name` / `!= name`.
- **Timer is running** `= key` / `!= key`.
- **Once-per-day already passed today** `= key` / `!= key`.
- **Logic Pack is active** — false while the licence holds it read-only.

## Variables

`COUNTER_1..8`, `CURRENT_STATE`, `PREVIOUS_STATE`, `LAST_TRIGGER_KEY`,
`LAST_TIMER_KEY`, `LAST_TIMER_LATE`, `LAST_COUNTER_KEY`,
`LAST_COUNTER_VALUE`, `LAST_FLAG_KEY`, `LAST_FLAG_VALUE`, `ONCE_KEY`,
`PACK_STATUS`.

## Actions

Print State (everything, with counts of calls and refusals), Reset All
Counters, Clear All Flags, Cancel All Timers, Reset Everything, Register
With Agent Now, Refresh Status.

## Limits

Up to 200 keys per primitive; counters within ±1,000,000,000; windows up to
one hour; timers up to seven days. A refused command never stops programming:
it is written to **Last Refusal** with the reason.

## What is not claimed

Debounce and throttle resolution follows Director's timers (tens of
milliseconds). A debounce window that spans a controller restart is not
restored: the quiet period has, by definition, passed, and nothing fires.
Keys are project-wide, not per room.

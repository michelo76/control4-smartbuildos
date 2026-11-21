# Logic Blocks — design

Status: implemented on `feat/logic-blocks` (cut from `origin/main` `4a9bca4`,
21 Nov 2026). Verified off the controller only: Lua suites under the shim, a
browser suite against a development host. **Nothing here has run on a
controller, in Composer or against equipment.** `BENCH.md` is the list of what
that leaves unproven.

Evidence labels used below: **CODE** (read in this repository), **DOCS**
(Control4's published DriverWorks documentation, read from the emulator's
cache), **TEST** (an automated test here asserts it), **BENCH-OWED** (needs a
controller).

## What it is

Logic Blocks are named, typed rules in 16 numbered slots on the existing
SmartBuildOS Logic Pack (`smartbuildos-logic-pack.c4z`, SKU `SBOS_LOGIC_PACK`).
A dealer configures a block in Composer; programming feeds it with `BLOCK_*`
commands, or it reads a device variable; it answers with per-slot events,
variables and conditionals. The driver evaluates the rule and reports the
decision. Equipment is operated by Composer programming on the block's events.

It is an evolution of the Logic Pack, not a second driver:

| Kept exactly                                                               | Evidence |
| -------------------------------------------------------------------------- | -------- |
| File name, SKU, driver name, model, `<combo>true</combo>`, no proxy         | TEST     |
| All 14 classic commands and their parameters                               | TEST     |
| Classic events 1–9, variables 3000–3020, conditionals 1–13                  | TEST     |
| The classic persisted document `lp_state_v1`, its shape and its semantics  | TEST     |
| Classic timer recovery (an overdue `START_TIMER` fires late at start-up)   | TEST     |
| The whole of `test_logic_driver.lua`, `test_logic_engine.lua`, `test_logic_aicore.lua` | TEST (unchanged, passing) |

## Architecture

```
Composer properties/actions ─┐
BLOCK_* commands ────────────┤   drivers/smartbuildos-logic-pack/driver.lua   (thin adapter)
device variable listeners ───┘        │
                                      ├─ logic/blockdraft.lua   one draft; validate whole; apply atomically
                                      ├─ logic/blocks.lua       slots, identities, rules, history, recovery
                                      │     └─ logic/engine.lua (a SECOND, private instance)
                                      ├─ logic/blockdefs.lua    types, bounds, validation, wording, ids
                                      ├─ logic/appstate.lua     read-only app document, redacted export
                                      ├─ logic/sandbox.lua      isolated simulation runtime
                                      └─ logic/relay.lua        LAN routes: reads + sandbox only
www/app/index.html → logic/page.lua (embedded)                  the dealer app
```

Every module under `src/logic/` except the driver is pure: no `C4` global, an
injected clock, timers, calendar and sinks. That is what makes the rules
testable and the sandbox possible.

### Reuse of the existing engine

The six classic block types run on `src/logic/engine.lua`, the engine behind
the free-form keys: cooldown is its throttle, quiet period its debounce, the
timer its timer, once per day, flag and counter its own. Blocks hold a **second
instance** of that engine, with timer ids prefixed `lb:` and a separate
persisted document. Consequences:

- a block and a free-form key can never be the same thing; a block named
  "Good Night" does not read, adopt or disturb the key `good_night` (TEST);
- the counter bounds, key normalisation and comparison vocabulary are the
  engine's, not a copy.

The engine gained only additive entry points: an optional per-call ceiling on
debounce and throttle windows (a block may wait up to 7 days; a programming
command still gets the 1-hour ceiling), `cancelDebounce`, `forgetThrottle`,
`forgetOnce` and three read-only accessors. No existing call changed (TEST: the
79 engine checks pass unmodified).

Conditions, threshold, stable filter and selector are implemented in
`blocks.lua`. Mode Composer's trigger engine and Daypart were read first; they
solve different problems (multi-signal windows with cooldowns; weekly time
blocks) and were not duplicated.

## Composer surface

Generated into `driver.xml` by `tools/logic-blocks-xml.lua` between marked
regions; `--check` fails when it is stale (TEST). Everything else in the file is
hand-written.

| Per slot `n`     | Count | Id                 |
| ---------------- | ----- | ------------------ |
| Events           | 8     | `1000 + 10n + k`   |
| Variables        | 4     | `4000 + 10n + k`   |
| Conditionals     | 3     | `100 + 10n + k`    |

Ids depend on the slot only. The id space is laid out for 32 slots, so the
capacity constant (`Defs.SLOTS`) can change without moving an id (TEST: ids
unique and clear of the classic ids out to 32 slots).

Decisions and why:

- **16 slots.** The brief's starting target. It costs 128 events, 64 variables
  and 48 conditionals. Whether Composer's pickers stay usable at that size, and
  what 128 `C4:AddEvent` calls cost at start-up, is BENCH-OWED. If the bench
  says 8, change one constant and regenerate.
- **Block picker = static `LIST`** (`Block 01`…`Block 16`). DOCS show a
  `DYNAMIC_LIST` command parameter and `GetCommandParamList`, but no driver in
  this repository uses one, so it is unproven here. A static list is what
  `RESET_ALL` already ships. The cost is that programming reads "Block 03", not
  the block's name; the **Blocks** property and the app map one to the other.
  `Defs.parseSlot` reads the leading number and ignores any text after it, so a
  later move to named entries would not break stored programming (TEST).
- **Events named by slot**, not by block name. DOCS say `C4:AddEvent` "will
  update an event if the event ID … is already in the driver", which would
  allow relabelling. Renaming events under existing programming is exactly the
  kind of behaviour the platform guide warns about, so it is not used.
  Follow-up worth a bench session.
- **Variables are added after the classic ones, in slot order**, and events are
  re-added at start-up, because XML events register only when an instance is
  first added (platform guide §8). Whether new XML conditionals appear on an
  update in place is BENCH-OWED.
- **BOOL variables use `"1"`/`"0"`**, as DOCS state. Other drivers here write
  `"true"`/`"false"`; which Composer shows correctly is BENCH-OWED.
- **Conditionals answer from the runtime**, not from the variables, so they are
  right between two variable writes. A BOOL conditional returns the fact and
  ignores its parameters, the convention every driver here follows; how Composer
  applies the "not active" choice is BENCH-OWED.

## Configuration

Composer is the only configuration authority. The app has no route that
changes a block (TEST: 88 method/path combinations refused).

A dealer never edits a live block. Draft properties feed one draft
(`blockdraft.lua`); *Validate Draft* checks the whole of it and reports every
problem at once; *Apply Draft* creates or replaces the block in one step. An
invalid draft leaves the live block, its settings and anything it has running
untouched (TEST).

`Blocks:impact()` says, before anything changes, what happens to a running
countdown. Rules:

- name, tag or notes only → nothing running is touched;
- settings changed → pending callbacks are dropped without firing; persistent
  values (flag, count, cooldown time, today's pass, a still-valid selector
  state) are kept;
- type changed → refused.

Identity: a block has an immutable id and a slot. A rename keeps both. A retired
slot stays out of use until *Release Retired Slot* (two presses), so
programming written for a retired block cannot drive a different one. A copy
gets a new id, a new slot and no history.

### Stored document (`lb_state_v1`)

```lua
{
  schema = "logic_blocks", v = 1, revision = n, saved_at = seconds,
  seq = n, run = n,
  blocks  = { s3 = { id, slot, name, tag, notes, type, enabled, rev,
                     created_at, updated_at, settings = {...},
                     inputs = { { index, label, device_id, variable_id,
                                  device_name, variable_name, true_when } },
                     feedback = { device_id, variable_id, expect, within_ms } } },
  retired = { s5 = { id, name, type, retired_at } },
  rt      = { s3 = { last, valid, suppressed, state, stable, reading, counts,
                     last_accepted, last_suppressed, last_refused, isolated,
                     timer = { deadline, seconds }, quiet_deadline,
                     src = { i1 = { raw, at } } } },   -- command-fed inputs only
  eng     = { counters, flags, once, throttle_last },  -- the private engine
  history = { ...last 50 decisions... },
}
```

`MIGRATIONS[n]` upgrades version n to n+1; `restore()` walks it. There is one
version today, so the walk is exercised with a synthetic table (TEST).

A stored document is never silently reset (TEST):

- not a table, not this schema, no version, no blocks table, or written by a
  newer driver → nothing is loaded, **Blocks Status** reads `RESTORE FAILED`,
  event 10 fires, every block command is refused, and nothing writes to the
  stored key until *Acknowledge Restore Failure*, which first copies what was
  stored to `lb_state_unreadable_<time>`;
- one block's definition unreadable → that slot is kept, marked unreadable,
  refuses commands, and is written back verbatim; the other blocks load.

### Legacy keys

Nothing is adopted by name. Validation notes when a new block's name matches an
existing key and says it adopts nothing. Explicit adoption exists for the two
types where copying a value is well defined: **Draft Adopt Legacy Key** on a new
Flag or Counter previews the value and, on apply, copies it once without
firing. The key is not deleted and classic commands keep changing the key.

## Block semantics

All TEST unless noted. The rules shared by every type:

- An unchanged value fires nothing.
- A refused input changes nothing, is recorded with its reason and is named
  under **Last Refusal**; it never halts programming.
- A slot's variables are written before its event fires.
- An input that arrives while another is being handled (a command sent by
  programming that an event started) is queued and handled next, in order.
- A disabled block refuses inputs; disabling drops anything pending with no
  event.

| Type       | Rule                                                                                                                              |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Cooldown   | Leading edge. A trigger at exactly the interval passes. No trailing pass. Reports the suppression count and the next eligible time |
| Quiet      | Restart on each trigger; passes once after the quiet duration. *Started* on the first trigger of a burst. Cancel fires *Cancelled* |
| Timer      | Start / restart / cancel. Repeated start: restart (default) or ignore. *Started* only idle → running                              |
| Once       | First trigger per controller-local calendar day. Not a rolling 24 h                                                               |
| Flag       | Set / clear / toggle. Persisted                                                                                                   |
| Counter    | Integer, classic bounds (clamped). Optional threshold with one of six comparisons; fires on crossing                              |
| Conditions | Three-valued ALL / ANY over up to four typed Boolean inputs. Continuous output, or a gate for `BLOCK_TRIGGER`                     |
| Threshold  | Active above upper, clear below lower, unchanged on or between. Inverted bounds refused at validation                             |
| Stable     | Output follows the source after it has held for the duration; a change back drops the pending change                              |
| Selector   | Named states, an initial state, optional allowed transitions with `*`; a disallowed change is refused with what is allowed        |

### Three-valued evaluation

Inputs are true, false or unknown. ALL: any false → false; else any unknown →
unknown; else true. ANY: any true → true; else any unknown → unknown; else
false. A result of unknown sets `VALID` false and `STATE` `unknown`, and fires
*Faulted* once on entering it. It never fires *Became False*. Readable again
with the same result fires nothing; with a different result it fires the
transition.

Transitions are measured against the last **valid** result, which starts as
false. So a first reading that programming sends above a threshold fires
*Became True*; one inside the band fires nothing.

### Opening values

DOCS: "The OnWatchedVariableChanged function will be called immediately after
the listener is successfully set." That first value, a value read after a
restart, and a value read when a lost device returns, set state and fire
nothing. Consequence, stated in the dealer guide: a change that happened while
the controller was down is silent. The recovery report and the activity list
record it.

A valid source is never marked stale for being quiet. Staleness is not inferred
from time at all; a source is unknown only when it has never been read, was
reported unreadable, or its device or variable is gone (checked once a minute).

### Time

DriverWorks documents no monotonic clock, so wall time is used and its jumps are
handled explicitly (TEST):

- a cooldown whose last pass is in the future (clock set back) is restarted
  from now, so a jump holds it shut for one interval at most;
- once per day compares calendar days; a clock set back to an earlier day does
  not pass again;
- a one-minute tick records a clock that moved by more than 30 s.

Live countdowns ride Director's timers; only their deadlines are stored.

### Restart recovery

| Was pending                | After a restart                                                                                     |
| -------------------------- | --------------------------------------------------------------------------------------------------- |
| Timer, `Cancel if missed`  | Deadline ahead → carries on. Deadline passed → cancelled, reported, *Expired* does not fire        |
| Timer, `Fire late`         | Deadline ahead → carries on. Deadline passed → *Expired* fires once, marked late                   |
| Timer, `Resume remaining`  | Counts what was left at the last save (the document is saved every minute while one is running)    |
| Quiet countdown            | Dropped, reported, does not pass                                                                    |
| Stable pending change      | Dropped; the source's current value becomes the starting state silently                             |
| Equipment-feedback window  | Closed; the decision reads "no feedback arrived"                                                    |
| Classic `START_TIMER`      | Unchanged: overdue fires late                                                                       |

### Licence

Uncertain statuses keep the pack working (TEST for `CLOUD_VALIDATION_REQUIRED`,
`AGENT_UNAUTHENTICATED`, `LEGACY`, `TRIAL`, `AUTHORIZED_GRACE`, a denial in
`observe` mode, and no Agent at all). A definitive denial with enforcement on
makes blocks read-only: inputs and configuration are refused with `read-only`,
reads answer, running countdowns are **held** and follow their After Restart
rule when the pack is restored, measured from the moment they were held.

### Bounds

| What                              | Bound                                   |
| --------------------------------- | --------------------------------------- |
| Slots                             | 16                                      |
| Inputs per block                  | 4                                       |
| Duration                          | 100 ms – 7 days (timer 1 s – 7 days)    |
| Timers per block                  | at most 3                               |
| Decisions kept / saved            | 200 / 50                                |
| Input queue while one is handled  | 64, drained 32 per callback             |
| Source value kept                 | 120 characters                          |
| App document                      | about 80 KB at capacity; under 96 KB    |
| Diagnostics export                | about 95 KB at capacity; under 128 KB   |

Runaway: more than 300 inputs to one block in 10 s, or a full queue, **isolates
that block**. It stops, fires *Faulted* once, says why, and stays stopped until
*Resume Selected Block*. Other blocks are unaffected. There is no generic rate
limiter: every input up to the limit is handled (TEST: 300 of 300).

## The dealer app

One interface: the page in the c4z, served by the driver on a controller port
(47871) with a token, the transport Atmosphere, Daypart and Variable Inspector
already use. It is opened in a desktop or phone browser from the address in the
**Dealer App** property.

Why not the SmartBuildOS web app, which the brief prefers where feasible: the
platform today has no company-scoped reader for `driver_state_mirror`
(`origin/main` `2e8f14b65`; the only readers are ingest, the public capability
URL and a staff-only fleet route). A dealer screen there needs a new
authenticated route, a System Studio panel and three guard-test updates. Doing
that as well as the page would have produced two interfaces. The app document
(`logic_blocks.app.v1`) is the contract a platform panel would render later.

Why no Navigator tile: the Logic Pack is proxy-less. Adding a `uibutton` would
change its structure on existing installs and put dealer diagnostics in front
of the homeowner. An optional companion UI driver is the way to add one later.

Transport honesty:

- reachable on the home network only, and the app says so;
- the relay pattern is bench-proven for other drivers in this repo; **this
  driver's relay has not run on a controller** (BENCH-OWED);
- every answer carries `generated_at`; the page shows live / stale / not
  connected, keeps the last good picture when the controller stops answering,
  and says since when;
- each fact has its own timestamp (an input's `observed_at`, a decision's
  `at`), read against the controller's clock, not the browser's.

The token is minted once, stored encrypted, shown only in the **Dealer App**
property, never logged and never in any response (TEST).

**Cloud Status Mirror** is off by default. On, it publishes
`logic_blocks.summary.v1` through `sbos.mirror`: names, types, health. No source
values, history or notes. Its read token is never displayed. Unverified end to
end; isolated behind the property.

### Sandbox

`sandbox.lua` builds a second `Blocks` runtime from a **copy** of one block's
definition, with its own clock, timers and sinks. It is constructed from plain
data and is never handed the live runtime, the driver's event or variable
functions, a listener or the persist store. The page's sandbox routes can reach
only that object. Isolation is asserted at the live runtime's output boundary:
no event, no variable write, no save request, no history entry, no timer, no
listener, and a byte-identical state document (TEST, in the pure suite, the
driver suite and the browser suite). Replaying the same steps gives the same
timeline (TEST).

### The four facts

Each decision record separates: the input received, the block's evaluation, the
events emitted, and equipment confirmation. Confirmation is `confirmed` only
when a feedback variable is mapped and reports an expected value after the
event; otherwise `not_monitored`, `not_confirmed`, or `already` (the equipment
was already in that state, so the event cannot be credited).

## Not built, on purpose

- Sequence recognition, interval repeaters, arbitrary expressions or scripting.
- Remote configuration: `EC.SBOS_DRIVER_CONFIG` is not wired.
- Event names carrying block names; a dynamic Block picker.
- A platform (SmartBuildOS web) panel; a Navigator tile.
- Registry changes: see `REGISTRY.md`.

## Build and test

```sh
make logic-blocks-test        # the seven Logic Pack suites, shim only
make logic-blocks-page-test   # browser suite against the development host
make logic-blocks-dev         # the page at http://localhost:47871 (development host)
make logic-blocks-gen         # regenerate the per-slot XML and embed the page
make logic-blocks             # build only smartbuildos-logic-pack.c4z into dist/oss
```

`make logic-blocks` does not format the repository and does not copy anything
into Composer's driver folder. `make build` does both; do not use it for this.

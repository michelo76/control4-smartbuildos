# Daypart Scheduler: design

Status: implemented on `feat/dealer-tools`; simulator-tested only
(`test_daypart_engine.lua`, `test_daypart_driver.lua`,
`test_daypart_relay.lua`, `test_daypart_page.lua`). Bench validation owed.
SKU `SBOS_DAYPART`, module id `daypart`, a licensed driver with a Web View
tile; no Agent module yet (see "Agent contract needed").

## What it is

A weekly time-block schedule of music source, volume and display power per
zone, edited by on-site staff without Composer. The dealer's properties are
the fence (zones, allowed sources, volume range, displays); the page lets the
manager move inside it.

## Shape

- `src/daypart/engine.lua`: pure. Calendar arithmetic on civil dates (no
  `os.time`), block validation, overlap detection, "which block is active",
  reconcile, ramp and command plans, persistence shape. The clock is injected.
- `src/daypart/relay.lua`: pure router. Reuses `dealerpanel.relay` (request
  parser, renderer, PIN gate with lockout).
- `driver.lua`: reads properties into zones, executes plans against Director,
  owns timers, the relay, persistence, licence and the Flight Recorder
  markers.
- `www/app/index.html`: self-contained page, no CDN. Its pure helpers sit in
  `<script id="daypart-pure">` and are tested with node when available.

## Decisions worth keeping

- **Wall-clock identity, not elapsed time.** A block run is `date|block id`.
  Each tick recomputes which block is live from the local date and minute and
  compares it with what is recorded as running. The difference is the action
  list. Restart, manual clock change, DST and a stalled controller are all the
  same case. A tick longer than 180 s (or going backwards) is only *noticed*
  (logged and recorded) and the runtime is marked "fresh" so an interrupted
  ramp resumes instead of restarting.
- **Midnight-crossing blocks belong to the day they start on.** When a spill
  and the next day's own block are both live (different templates only; the
  edit-time check cannot see across templates), the later start wins.
- **Restart does not blast volume.** A block start sets the level the room
  will climb from: the room's current level when it is on and readable,
  otherwise the zone minimum. The target is clamped to the dealer's range at
  run time as well as at edit time.
- **Edit-time rejection.** Overlaps, disallowed sources and bad times are
  refused with a message that names the other block and the weekday. Volume
  outside the range is clamped with a warning rather than refused. Week
  overlaps are checked on a 7-day circular timeline, the holiday template on
  a circular day, today-only on a linear two-day line.
- **Templates.** Priority: today-only, then holiday, then weekly. A holiday
  with no holiday blocks is silent.
- **Edits to the running block apply now** (a changed level, source or display
  choice emits an "update" without a new Block Started).
- **Auth.** The tile URL carries a minted token (read access); every change
  needs the Manager PIN (`Manager PIN` is a STRING property with
  `<password>true</password>`), with `dealerpanel.relay`'s gate (5 wrong PINs
  lock for 60 s). No PIN means read-only. The PIN is never logged, recorded or
  echoed.
- **Licence.** Fails open. A definitive denial with enforcement halts block
  actions and cancels ramps in flight, refuses edits, and leaves the page
  readable. Nothing is deleted. Pause state is separate and survives restarts.
- **History.** Common history is the Flight Recorder: `RECORD_EVENT` with
  `CHANNEL = "daypart"` and names beginning `Daypart:` (block started, block
  ended, schedule edited, paused, resumed, skipped, clock change, halted). The
  recorder is looked up by driver file name, re-asked once a minute, and its
  absence is silent.

## Needs from shared code (not edited here)

- Relay port `47851` is claimed by this driver; it should be added to whatever
  list of ports the repo keeps, next to 47815, 47821, 47822, 47823, 47841.
- `dealerpanel.relay` and `atmosphere.uirelay` are reused as they are. If
  either moves, `daypart.relay` follows.

## Agent contract needed (remote schedule backup and edit)

Today the schedule lives only on the controller (`lib.persist` key
`dp_state_v1`). Remote backup and remote edit from System Studio need
the Agent and the web repo. Not implemented; this is the proposal.

**Module.** `module_id = "daypart"` registered through `sbos.modules` /
`sbos.moduleclient` like the Flight Recorder. Add to `M.PREFIXES` in
`src/sbos/envelope.lua`:

```lua
daypart = { "daypart." },
```

**Controller to cloud (backup and audit), envelope v1 events:**

| `event_type` | When | `payload` |
| --- | --- | --- |
| `daypart.schedule.snapshot` | Start, after every accepted edit, daily | `{ "schema": 1, "revision": n, "zones": [ { "slot": 1, "name": "...", "min": 10, "max": 50, "week": [Block], "holiday": [Block], "today": { "date": "YYYY-MM-DD", "blocks": [Block] } } ], "holidays": ["YYYY-MM-DD"], "paused": false }` |
| `daypart.schedule.edited` | Each edit | `{ "who": "manager_page" or "composer" or "studio", "summary": "...", "revision": n }` |
| `daypart.block.started` / `daypart.block.ended` | Each block change | `{ "zone": "...", "block": "...", "late": false }` |

`Block` is `{ "id", "name", "days": [1..7], "from": "HH:MM", "to": "HH:MM",
"source": <device id> | "off" | null, "volume": 0..100 | null, "displays":
"on" | "off" | "keep" }`. The envelope's 4 KB payload limit means a full
snapshot may need splitting per zone (`daypart.schedule.snapshot` with
`zone_slot`, one event per zone); the 40-block cap per list keeps one zone
under the limit.

`source`, `room` and display device ids are controller-local. Names are the
labels from the property lists (`Name (Room)`), so Studio can show them but
cannot assume the ids exist on another controller.

**Cloud to controller (remote edit), through the Agent's existing downlink
(Agent to module command, same route the Agent uses for module config):**

```json
{ "command": "DAYPART_APPLY", "request_id": "...", "base_revision": n,
  "op": "replace_schedule" | "add_block" | "update_block" | "delete_block" | "set_holidays",
  "zone": 1, "scope": "week" | "holiday" | "today", "block": { }, "dates": [] }
```

The driver runs the same engine validation as the page (allowed sources, range,
overlaps) and answers with `daypart.schedule.edited` carrying `request_id`,
`ok`, and on refusal the message the page would have shown. A `base_revision`
older than the controller's is refused (`stale`), so a Studio session cannot
overwrite a manager's later change. `replace_schedule` is the restore-from-backup
path: all-or-nothing, validated block by block against the current zone limits;
blocks that no longer fit are reported, not silently fixed.

**Engine hooks already in place:** `Engine:exportSchedule()` (the document
above), `Engine:addBlock/updateBlock/deleteBlock/setHolidays` (return
`result` or `nil, message`). A `revision` counter (monotonic, persisted) and
`importSchedule(doc)` are the two pieces still to add.

## Open questions

- Should a block be able to name a Control4 scene or a lighting level too? Out
  of scope: use Block Started/Block Ended in Composer.
- Per-day exceptions inside a weekly block (every day except one date) are
  handled with "today only" or holidays; a dated exception list is not
  designed.

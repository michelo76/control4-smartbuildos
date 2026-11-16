# Usage Analytics — design

Status: implemented on branch `feat/event-tracer` (batch of 9 November 2026,
`docs/driver-batch-20261109.md` #3); simulator-verified (`make test`);
**bench validation owed**. SKU `SBOS_USAGE_ANALYTICS`, module_id
`usage_analytics`, prefix `usage.`.

## What it answers

At a service visit: which rooms play media and on what, for how long; which
lights burn longest; which keypad buttons are never pressed; which rooms are
never used. Measured on the controller from what the project already exposes,
rolled up per local day, kept 30 days, printable from Composer, uploaded once
a day through the Agent's pipeline.

## Sources (`src/usage/sources.lua`, pure)

Classification by variable signature and event names, never by device name:

| Kind | Found by | Measured through |
| --- | --- | --- |
| Rooms | distinct `roomId` in `C4:GetDevices({})`, then `GetDeviceVariables(roomId)` | `POWER_STATE` (in use), `CURRENT_SELECTED_DEVICE` (source) via `RegisterVariableListener` |
| Lights | a device exposing `LIGHT_STATE`, `LIGHT_LEVEL` or `Brightness Percent` | the same listener |
| Keypads | catalogued events (`tracer.catalog` + `tracer.catalog_data`) named Pushed / Pressed / Clicked / Tapped, not Released | `RegisterDeviceEvent` per press event |

Caps: 64 rooms, 200 lights, 100 keypads, 600 listeners, in ascending id
order; what did not fit is counted under `over_cap` and shown in **Sources**.
Rooms without media variables are counted, not measured. Self and `Exclude
Device IDs` are never planned.

## Meter (`src/usage/meter.lua`, pure)

- Running intervals are flushed into the current day on every change and on
  the one-minute tick, so a midnight crossing misattributes at most one tick.
- Unknown is not off: nothing counts until the first known value. The driver
  seeds every planned variable from its current value at apply (flagged as
  seeding: not a change, not a cycle).
- Media "in use" = `POWER_STATE` true; when power was never read, source ≠ 0
  stands in. Source ids are resolved to labels through `GetDeviceDisplayName`
  at change time.
- Light cycles count off→on transitions (not seeds, not re-announcements).
- Days roll by the injected `dayOf` (the driver uses `os.date("%Y-%m-%d")`,
  local time). `tick()` returns the closed days once; retention 30 days.
- `payload()` is bounded for the envelope: top 15 rooms, 10 lights, 15
  keypads, 15 names per unused list, labels ≤ 60 characters; a 60-room
  project's payload measures under 4 KB (tested with `sbos.envelope`).
- Persisted: days + counters only (one key, ≤ 1 write / 5 min when dirty,
  and on destroy). Running states are re-seeded on start.

## Driver (`drivers/smartbuildos-usage-analytics/driver.lua`)

Licensing through `sbos.license` (SKU above; definitive denial + enforcement
releases every listener and subscription and paints `unlicensed`); Agent
module through `sbos.moduleclient` (capabilities, commands `send_summary`,
`reapply`, `refresh_status`; events `usage.plan_applied`, `usage.daily`,
`usage.summary`). Re-plans on Agent registration, `project_changed`,
`director_reloaded` (5 s quiet period), `Measuring` and `Exclude Device IDs`
changes. Measuring continues with no Agent (`measuring_local`).

Every `require` sits at module scope, including `tracer.catalog_data`, so
the squish step packages the catalogue.

## Verification

| Suite | Checks | Covers |
| --- | --- | --- |
| `test_usage_meter.lua` | 45 | media/light/keypad accumulation, seeding, unknown-is-not-off, day roll + retention, aggregate/summary/report/payload, payload size under the envelope limit, serialize/restore through JSON, keepOnly |
| `test_usage_sources.lua` | 19 | press-name rule, classification, Released excluded, self excluded, caps in id order, exclusions, describe line |
| `test_usage_driver.lua` | 53 | the DRIVER under the shim with a scripted Agent: zero-config plan (7 listeners, 2 subscriptions), seeding counted from the seed, registration + licence under the SKU, a simulated day → one `usage.daily` (2 h media on Apple TV in the Kitchen, 6 presses, Office Lamp longest, Office never used), report/summary actions, Measuring Off/On, enforcement vs uncertainty, project change + exclusions, Studio commands with token, checkpoint + reload, reset |

## Bench plan (owner, Beta Site 2)

1. Add the driver; read **Sources**: rooms with media variables should be
   the rooms that have a media source, lights ≈ the lighting load count,
   keypads = keypads whose drivers are in the catalogue.
2. Play a source in one room for ten minutes; `Print Usage Report` (Today)
   shows that room with the right source and ≈ 0.2 h.
3. Toggle a light twice; the report shows 2 cycles.
4. Press a keypad button; **Today** shows the press. If a Control4 keypad
   shows no presses: its driver's events come from the project catalogue
   tier only (PROBE, see the Event Tracer's VERIFICATION) — note which
   drivers are missing from `tracer.catalog_data`.
5. Let it run past midnight; **Last Daily Summary** is stamped and the Agent
   log shows `usage.daily` accepted (platform prefix `usage.` owed on the web
   side; until then the Agent refuses the envelopes and they count as dropped).

## Not included (v1)

- No per-source media titles, volumes or any variable values beyond the
  typed ones above.
- No Studio view yet (web repo: catalogue row, prefix ownership, a usage
  page).
- Keypad presses rely on the event catalogue; keypads whose driver is not in
  the built-in catalogue are not measured until the Event Tracer's project
  tier or a regenerated catalogue names their events.
- Room variable ids are resolved by name at apply; a renamed room device
  keeps its id, a replaced one is picked up at the next re-plan.

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Online, Measuring Status `measuring`, Agent Link `Agent device 72 – registered`, Agent Connection `ready`, Sources `4 room(s), 2 light(s), 0 keypad(s); 12 listener(s)…`, Today `media 0.1 h, lights 0.0 h, 0 keypad press(es)`, Days Recorded 1, Last Upload 07:16:47. Licence painted immediately (Enterprise, company).

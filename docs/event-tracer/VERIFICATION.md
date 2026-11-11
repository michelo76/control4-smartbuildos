# Event Tracer — verification record and bench plan

> **Merged into the Flight Recorder on 11 November 2026.** The Event Tracer is
> no longer a driver of its own: its capture engine (`src/tracer/*`, unchanged
> apart from history notes) runs inside `smartbuildos-flight-recorder`, under
> the module id `flight_recorder` and the SKU `SBOS_FLIGHT_RECORDER`. The
> event types `capture.*` and `tracer.*` kept their names. Property, action
> and command names changed (Capture → Event Capture, Coverage → Event
> Coverage, `MARK_TIMELINE` → `RECORD_EVENT`, …): the Flight Recorder manual
> has the current ones. Everything below was observed on the separate driver; nothing in the
> merged driver has been run on a controller yet.

Date: 2026-11-09. Everything under "Simulator" is shim evidence (LuaJIT,
`test/c4_shim.lua`, scripted Agent). **No controller was touched, nothing was
installed into Composer's driver folder, nothing was deployed.** Hardware rows
are open until Beta 1 / Beta Site 2 (OS 4.2) produce the evidence named.

## Simulator (`make test`, branch `feat/event-tracer`)

Suite green: 64 files, 0 failures (the 60 pre-existing suites unchanged in
count after the `envelope.lua` prefix addition). New suites:

| Suite | Checks | What it proves |
| --- | --- | --- |
| `test_tracer_catalog.lua` | 42 | driver-XML events parsed (CDATA, entities, whitespace, nameless skipped, proxy sub-documents ignored); project-XML per-item parsing incl. self-closing root `<itemdata/>`; LIMIT_DEVICE_DATA shape → 0 quietly; tier precedence project > builtin > learned; learned ids merged and named; learn/forget round trip; the generated catalogue loads and names the Agent's own events |
| `test_tracer_ring.lua` | 30 | clamped capacity; eviction + sequence past capacity; recent/forDevice/since/window; shrink keeps newest, grow keeps all; serialize/restore resumes the sequence; corrupt and partly-corrupt documents |
| `test_tracer_engine.lua` | 75 | per-field policy validation (Composer On/Off, csv ids); zero-config plan (self + unknown skipped, tiers counted); identical re-apply registers nothing; capture envelope fields; marks; storm start → suppression → end by tick and by next event; threshold 0; budget drops with one warning, ring unbudgeted, minute reset; probe → learn → persisted → survives probe-off as learned; project tier wins and names a learned id; stale project tier cleared when the XML is gone; exclusions; cap in ascending order with per-device unsubscribed counts; refused registration counted and not kept; project add/remove; pause/resume/stop/disabled; restored ring continues |
| `test_tracer_driver.lua` | 77 | the DRIVER under the shim with a scripted Agent: starts and captures with no Agent (`capturing_local`), registration frame carries `SBOS_EVENT_TRACER` / `capture.,tracer.` / commands; licence registration under the tracer SKU and painted tier/company; **3 am scenario** (mark, then three device events, in order, instrumented vs observed, sequence increasing); chattering contact → one storm, 30 recorded, Composer events 3 then 4, conditional; Composer property changes re-plan (exclusion releases exactly two; bad value named and ignored; error clears); probe + learn fires event 7 and persists; project tier names a learned id; project change debounced 5 s; Studio commands (wrong token ignored, pause/resume/apply_policy/unknown) with Accepted→Executing→Completed; **licence enforcement**: CLOUD_VALIDATION_REQUIRED + enforce changes nothing, NOT_ENTITLED + enforce halts and paints read-only, observe resumes; Agent hello → re-register; ring checkpoint + restore continues the sequence across destroy/LateInit; print actions; clear/forget |

Build: `make preprocess gen-squishy update-xml docs-html package` →
`dist/oss/smartbuildos-event-tracer.c4z` (see the build note at the end of this
file for the result). `install-local` was deliberately NOT run.

## Composer import (Beta Site 2, Composer Pro 2026.10.14, OS 4.3) — DONE 2026-11-09

Two findings, both now baked into the driver and worth knowing for every
proxy-less SmartBuildOS driver:

1. **`<combo>true</combo>` is required.** A `lua_gen` driver with empty
   `<proxies>` and no `combo` flag imports with "Update Succeeded" and then
   never appears in Items → Search (Local or Online). Mode Composer and
   System Link carry the flag and appear; Flight Recorder does not and is
   equally invisible on this Composer (search "recorder" lists 17 receivers
   and no Flight Recorder). The tracer now declares `<combo>true</combo>`
   and shows as `SmartBuildOS Event Tracer | SmartBuildOS | others | IP`.
   **Flight Recorder needs the same one-line fix.**
2. **Never import a `.c4z` from Composer's own Drivers folder.** On this
   bench `~/Documents/Control4/Drivers` on the Mac IS Composer's local
   driver folder (Parallels share `\\Mac\Home`). Add or Update Driver
   copies the chosen file into that folder, so choosing a file already there
   copies it onto itself: the zip is truncated ("End-of-central-directory
   signature not found"), Composer reports "Broken: Failed to upload file",
   and later imports of the same path silently no-op. Import from
   `dist/oss/` (or anywhere else) and let Composer place the file. The
   Makefile's `install-local` pre-copies builds into that folder; after it,
   import from `dist/`, not from the Drivers folder.

## Bench 2026-11-09 — first add on Beta Site 2 (OS 4.3)

Owner added the tracer to the project (screenshots 00:32–00:38):

- **Agent Link: No SmartBuildOS Agent found in this project** while the Agent
  was paired and connected under Composer → Agents. Root cause: the licensing
  SDK found the Agent only through `C4:GetDevices`, which does not list an
  Agents-panel agent. Fixed in `src/sbos/license.lua` (three-tier discovery,
  see CHANGELOG); affects Flight Recorder, Atmosphere, System Link, Mode
  Composer, UniFi Protect and Bond equally. Needs a rebuilt dependent to
  verify: `Agent Link` must name the Agent's device id.
- **Coverage: 1000 subscriptions on 32 of 174 devices; 1 excluded** and
  **Catalogue: project: 0 device(s) → 0 subs; built-in: 0 driver(s)…** (first
  paint), later `capturing_local`. Reading: the plan reached the 1,000 default
  cap on 32 devices, so the per-device event counts in this project are
  large — raise `Max Subscriptions` or lower per-device coverage on the
  bench and record what Director tolerates (bench row 5). `project: 0`
  answers bench question 1 for OS 4.3: **the unlimited `GetProjectItems`
  does not carry `<events>`**, so Control4's own `.c4i` devices depend on
  the built-in catalogue and the probe. **`built-in: 0 driver(s)` was a build
  defect**: `tracer.catalog_data` was required inside `buildTracer()`, and
  the squish step (which loads the driver under the shim, where LateInit
  stops at the OS version check) never saw it, so the .c4z shipped without
  the catalogue. Fixed by requiring it at module scope. The 1,000
  subscriptions on 32 devices were the probe (32 unknown-driver devices ×
  probe range 32 = 1,024, capped at 1,000) — Probe Unknown Drivers was On.
- Events Captured 0 at 00:38 with 1000 subscriptions: nothing had fired yet
  in the six minutes; press a keypad and re-read.

## Bench plan (owner, Beta 1 / Beta Site 2, OS 4.2)

Order matters: question 1 decides how much of a real project the catalogue
covers before anything else is worth measuring.

| # | Question | How | Pass |
| --- | --- | --- | --- |
| 1 | Does the unlimited `GetProjectItems("DEVICES", "NO_ROOT_TAGS")` carry each device's `<events>`? | Add the driver; read **Catalogue** | `project: N device(s)` with N > 0 and ≈ the number of devices whose driver declares events; `Print Coverage` shows `project` tier on Control4 `.c4i` devices (lights, keypads, contacts). If N = 0: the OS strips device data → rely on builtin + probe; record it in DESIGN.md and consider adding the first-party `.c4i` set to `tools/gen-event-catalog.py` from a controller export |
| 2 | How big is that XML on a real project, and how long does apply take? | Log Level 4; time from `Re-apply Capture Now` to the `tracer.applied` line; note `#xml` (add a debug print if needed) | < 2 s and well under the 6 MB cap on a ~150-device project |
| 3 | Does `RegisterDeviceEvent` for a non-existent id error, silently succeed, or hurt Director? | Probe Unknown Drivers = On, Probe Range 8, on a project with one uncatalogued driver; watch Director log and `register_failures` | No Director errors, `register_failures` = 0, no restart. If errors: keep probe opt-in and document; if harmless: consider default On |
| 4 | Do events arrive, named, in order, for first-party devices? | Press a keypad top button; open a contact; `Print Recent Events` | Entries with Composer's names and the right room, order matching the physical sequence, `Last Event` painted within 2 s |
| 5 | Registration ceiling and cost | Max Subscriptions 2500 on the largest bench project; watch Director memory (Agent vitals) and `apply` time; Coverage line | No memory growth after apply settles; Coverage reports the real count; raise/lower the default accordingly |
| 6 | Storm protection on a real chattering input | Toggle a contact ≥ 30× in a minute (or a relay loop) | ONE *Event Storm Detected*, Active Storms shows it, then *Event Storm Ended* within ~90 s with the suppressed count; the ring holds exactly 30 entries for that key |
| 7 | Pipeline parity | Agent paired; Studio ingest for `event_tracer` prefixes (web work owed) | `capture.event` rows appear with `module_id = event_tracer`; rejected = 0 in the acks (`Dropped Events` stays 0) |
| 8 | Reload / update | Composer Update Driver on the tracer; Director restart | *Last Event* restored, next `seq` continues; subscriptions rebuilt without a Composer action; learned tier intact |
| 9 | Licence | Agent paired to a company without the SKU; enforcement on in the platform | `License Status` shows the denial `(read-only)`, Capture Status `unlicensed`, zero subscriptions; adding the entitlement restores capture without a reload |
| 10 | Removal | Remove the driver from the project | Director log shows no further `OnDeviceEvent` for its id; Agent registry drops `event_tracer` |

## Known limits (by design)

- No cause attribution; no event parameters (Director passes none).
- A storm's suppressed occurrences are counted, never recorded.
- Devices whose driver is in no tier are reported, not captured, unless probing
  is on; probing cannot reach ids above *Probe Range*.
- Renamed devices: entries keep the label at capture time.
- Loss windows: ring ≤ 30 s (checkpoint); upload per the Agent's queue rules
  (PROTOCOL.md §4).

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Agent Link `Agent device 72 – registered`, Agent Connection `ready` (the three-tier discovery fix works against the Agents-panel Agent). License Status `Licensing Not Yet Enforced`, tier `Enterprise`, company painted. Capture Status `capturing`. Coverage `1000 subscriptions on 34 of 174 devices; 1 excluded`; Catalogue `project: 0 device(s) → 0 subs; built-in: 187 driver(s)…` (the module-scope require fix shipped the catalogue; OS 4.3 still strips `<events>` from the project XML). Events Captured 0 at 07:18 with Last Upload 07:07:17. Probe Unknown Drivers was still On, so the 1,000 cap is the probe (32 × ~32 unknown devices): turn the probe off or raise Max Subscriptions before reading real coverage.

## Bench 2026-11-09 18:12 — Agent and Event Tracer updated to 20261109.203405

Composer's title bar was checked first: "Beta Site 2 (Smartbuildos) (Local)".
Both packages were imported from `dist/oss/` through Add or Update Driver or
Agent; Composer answered "Versions are equal — overwrite?" for each (its own
comparison, although the folder copy was the morning's 060825) and **Yes**
updated the file and the running instance.

- **Agent**: Agent Version `20261109.203405`, Pairing State `Paired`, Cloud
  Connection State `Connected`, licence check `OK` at 18:12. Pairing survived
  the update.
- **Event Tracer** (device 454): Driver Version `20261109.203405`, Capture
  Status `capturing`, Agent Link `Agent device 72 – registered`, Agent
  Connection `ready`, Last Upload 18:13:47, Last Capture Error `none`.
- **Bench row 8 (reload / update), first half: PASS.** After the update
  *Last Event* still read `Samsung TV: Event 2 (07:25:37)`: the ring was
  restored across the driver update. *Events Captured* restarted at 0, which
  is the per-start counter, not the ring.
- **Bench rows 3 and 4, partial.** That restored entry is an event captured
  on hardware this morning from a PROBE subscription (unnamed, "Event 2"), so
  registering probe ids delivered a real event and did not disturb Director
  over eleven hours. Named first-party events are still unverified.
- Coverage `1000 subscriptions on 35 of 186 devices; 1 excluded`: Probe
  Unknown Drivers is still On and still fills the cap. Real coverage needs
  the probe off or a higher limit.

Not exercised: a Studio-sent `apply_policy` against this build (the web side
is not deployed), and the policy report in `tracer.applied` as Studio reads
it.

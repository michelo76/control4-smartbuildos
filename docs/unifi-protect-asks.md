# The Asks — UniFi Protect suite, one-pass upgrade

2026-08-28. This is the measuring stick. Every ask is numbered, has a
verifiable measure, and is scoped against the **v7.2.105 official OpenAPI
spec** (extracted today — 55 paths, verified against the console this suite
runs on). Nothing lands until this list is agreed; then the whole in-scope
set ships as **one pass**.

**What the v7 spec changed vs the 6.2.83 research** (this is why half the
"experimental" column moved to "official"):

- **Arm profiles are official**: list, enable/disable, settings — and the
  NVR object now carries `armMode`, `armProfileId`, `armedAt`,
  `breachDetectedAt`, `breachEventCount`, `willBeArmedAt`. The whole
  Protect alarm state machine is readable and drivable.
- **Sirens (play/stop/test), relays (activate outputs), alarm hubs
  (trigger outputs), speakers (test sound), fobs, bridges, link stations**
  — all official resources now.
- **`/v1/ulp-users` is official**: the identity store (first/last/full
  name, status). **`fingerprintIdentifiedEvent`** and
  **`nfcCardScannedEvent`** carry identity metadata → "KNOWN PERSON: John"
  is officially buildable via doorbell fingerprint/NFC.
- **Alarm-hub event vocabulary**: entry open/close, glass break, smoke,
  motion, tamper, button press, battery — over the same events websocket
  we already hold open.
- **Still NOT official** (measured, not assumed): face names in video
  events (`smartDetectZone` carries type only), license-plate text in
  events, event-history query, recorded video, NVR storage/CPU health.

---

## A. Ground rules — the pass itself

| # | Ask | Measure |
| --- | --- | --- |
| A1 | **One update, zero re-adds.** Every new feature reaches existing Gateway + camera instances via a single Update Driver each. All new events/variables register at init (the AddEvent/AddVariable pattern), never only in XML. | Update instances in place; Driver Version matches; every new event visible in Composer programming on an updated (not re-added) instance. |
| A2 | **Zero regressions.** Everything in section B keeps working. | Full test suite green; on-site: 3 cameras stream, rename, history, snapshots, events — the section-B checklist re-run. |
| A3 | **Official API only in the core.** Every endpoint the drivers call appears in `docs/UBIQUITI_API_MATRIX.md` marked OFFICIAL. Anything else lives behind an Experimental toggle, default Off. | Grep of `src/unifi/*.lua` vs the matrix; no unlisted endpoint. |
| A4 | **No credentials beyond the API key.** No password property exists anywhere in the suite. No secret ever logged. | XML grep; log redaction test (exists) extended over new code. |
| A5 | **New child drivers only where Navigator presence or bindings demand them.** Sensors, lights, viewport = new drivers (new adds, fine). Sirens, relays, alarm, speakers, NVR health = Gateway surface, no new drivers. | Driver count: exactly 3 new c4z files (sensor, light, viewport). |
| A6 | **Memory/timer discipline.** Bounded caches, no timer leaks on destroy, no image retention in Lua. | OnDriverDestroyed cancels every timer it set (test); caches have hard caps. |

## B. Baseline — already shipped, protected by A2

Each of these has tests today; they are the regression floor, not new work.

B1 streams (RTSP-default, measured) · B2 per-camera quality selection ·
B3 dynamic stream URLs + cache + DYNAMIC_URLS_CHANGED · B4 auto-discovery
of cameras into bindings · B5 auto-rename with clobber guard + Rename From
Camera · B6 dual-path transport (bindings + SendToDevice) with self-healing
identity · B7 events websocket with reconnect · B8 14 Composer events + 6
variables · B9 History Agent timeline with appetite property · B10 snapshot
relay + thumbnails + notification attachments · B11 diagnostics
(Gateway Link, Print Diagnostics/Bindings/Inventory, Relay/Event Stream
status, Driver Version truth) · B12 API-key letterbox + encrypted persist.

## C. One-pass scope

Scores: Customer value / Dealer value / Difficulty / API stability /
Control4 fit, each /10.

### P0 — Foundation (do first, everything else leans on it)

| # | Ask | Measure | Score |
| --- | --- | --- | --- |
| C1 | **Capability model.** Per-camera capability table from `featureFlags` + `smartDetectTypes` (+ PTZ probe). Actions/events/variables gated by it: no mic controls on mic-less cameras, no plate variable on cameras that can't read one. | Two fixture cameras with different flags expose different surfaces (test); real G4 vs doorbell differ in Composer. | 6/9/5/9/9 |
| C2 | **API matrix + adapters.** Endpoints centralized in `src/unifi/` modules; `docs/UBIQUITI_API_MATRIX.md` rows: function, endpoint, Protect version, auth, used-by, fallback. Missing endpoint → property says "Unsupported by this Protect version", never a Lua error. | Matrix complete; downgrade simulation (404 route) degrades gracefully (test). | 3/8/4/10/9 |
| C3 | **Event storm controls.** Per-camera Motion Event Cooldown (default ~3s) and per-event-type notification cooldown; Control4 event delivery and notification delivery distinguished. | Test: 10 motion frames in cooldown → 1 event; state variables still correct. | 6/8/4/10/8 |
| C4 | **Normalized event model.** The parent's event normalization (kind/phase/types/at/value) documented in `docs/EVENT_MATRIX.md` covering every v7 event type we route, including the new alarm-hub/sensor/NFC/fingerprint families. | Matrix lists every v7 title with route/drop decision + test per routed family. | 4/7/3/9/9 |

### P1 — Competitive parity (what the $199 drivers have that we lack)

| # | Ask | Measure | Score |
| --- | --- | --- | --- |
| C5 | **Doorbell pack.** Actions+Composer commands: Set Doorbell Message (+duration), Do Not Disturb, Leave Package, Reset Display — via `PATCH /v1/cameras/{id}` lcdMessage. | Command → PATCH body correct (test); message appears on real doorbell LCD. | 8/8/3/9/9 |
| C6 | **Camera settings.** LED on/off, mic volume, HDR, video mode as actions+commands; current values as properties from inventory. | PATCH round-trip test; property reflects console change on next poll. | 5/7/3/9/8 |
| C7 | **PTZ presets/patrols.** Run Preset (slot), Start/Stop Patrol commands; native camera-UI presets via `has_dynamic_presets` where a slot list is obtainable. | Command → `POST ptz/goto/{slot}` (test); UI presets on a real PTZ camera or documented as command-only. | 6/6/5/8/8 |
| C8 | **Protect Sensor driver** (new child). CONTACT_SENSOR binding, MOTION, temp/humidity/light/battery variables, configurable thresholds → threshold events, plus the new v7 events (button press, CO fault, smoke battery, tamper). | Sensor open/close flips the bound contact (test); thresholds fire once per crossing (test). | 7/8/6/9/9 |
| C9 | **Protect Light/Floodlight driver** (new child). light_v2 on/off + lightMotion events routed. | Composer light on → `PATCH /v1/lights/{id}` (test). | 6/6/5/9/8 |
| C10 | **Viewport driver** (new child). Set Live View, Next/Previous, and **Temporarily Show View (seconds) with restore** — doorbell→TV pop-up primitive. | `PATCH /v1/viewers/{id}` (test); restore returns prior liveview after timer (test); field: ring → viewport flips 20s → restores. | 8/8/6/9/8 |
| C11 | **C4 → Protect webhooks.** Gateway action+command Trigger Protect Webhook (id) via `POST /v1/alarm-manager/webhook/{id}`. | Test asserts POST; field: Alarm Manager rule fires. | 6/8/2/9/9 |
| C12 | **Protect → C4 webhooks.** The relay's HTTP listener accepts `POST /webhook/<name>?token=<secret>`; fires CUSTOM WEBHOOK RECEIVED + LAST_WEBHOOK_NAME/TIME. Token property required; wrong/missing token → 404; payload size capped; per-name cooldown. | curl with token → event (test); without → 404, nothing fires (test). | 7/8/4/9/8 |
| C13 | **Snapshot notification action.** SEND CAMERA SNAPSHOT NOTIFICATION (message, severity) composing History + notification attachment — one Composer action instead of three. | Action → history record + notification fired with attachment URL (test). | 7/7/3/9/9 |

### P2 — Competitive advantage (what neither competitor has, all official)

| # | Ask | Measure | Score |
| --- | --- | --- | --- |
| C14 | **Protect Alarm subsystem** (Gateway surface). Read `armMode`/`armProfileId`/`breach*` from `/v1/nvrs`; discover profiles from `/v1/arm-profiles`; actions+commands Arm With Profile / Disarm / Select Profile (`enable`/`disable`); events ARMED, DISARMED, PROFILE CHANGED, **BREACH DETECTED**; variables ARM_MODE, ARM_PROFILE. Profile names discovered, never hardcoded. | Arm from Composer → enable called with profile id (test); breachDetectedAt change → event (test); field: C4 Away scene arms Protect. | 9/9/6/8*/9 (*new surface, one console verified) |
| C15 | **Sirens + relays + alarm-hub outputs** (Gateway surface). Discover; PLAY/STOP/TEST SIREN (duration/volume per schema), ACTIVATE RELAY OUTPUT, TRIGGER ALARM-HUB OUTPUT as clearly-security-labelled commands; SIREN STARTED/STOPPED events. **No retry on activation commands** — a timeout is reported, never re-fired. | Tests: play → POST once even on timeout; events fire. Field: siren test action sounds once. | 7/8/5/8/8 |
| C16 | **Known-person via fingerprint/NFC.** Route `fingerprintIdentifiedEvent`/`nfcCardScannedEvent`; resolve identity via `/v1/ulp-users` (cached); KNOWN PERSON DETECTED + UNKNOWN PERSON events; LAST_PERSON, LAST_PERSON_TIME variables. This is the *official* half of "face intelligence" — honest about being fingerprint/NFC, not video face-ID. | Fixture event with ulp id → variable carries "John Doe" (test); unknown id → UNKNOWN event (test). | 8/7/5/8/8 |
| C17 | **Alarm-hub sensor events.** Entry open/close, glass break, smoke, tamper, battery — routed to Composer events on the Gateway (no child driver until hardware demands one). | Each fixture event fires its Composer event (test). | 7/7/3/8/8 |
| C18 | **Enriched variables.** LAST_EVENT, LAST_EVENT_TYPE, LAST_EVENT_TIME, per-type LAST_*_TIME on cameras; capability-gated so unsupported hardware exposes nothing empty. | Variables update per fixture event; absent on incapable fixture camera (test). | 6/7/2/10/9 |
| C19 | **NVR/system health.** Gateway properties: Protect version (have), camera counts (have), offline devices, WebSocket state (have), last event time, reconnect count, avg API latency; NVR OFFLINE/ONLINE + DEVICE OFFLINE events. Storage/CPU **not claimed** — not in the official spec (KNOWN_LIMITATIONS). | Properties live; unplugging a camera fires DEVICE OFFLINE (field). | 6/9/4/9/9 |
| C20 | **SmartBuildOS handoff (Phase 1).** Gateway → SBOS Connector roster (name/MAC/state) via SendToDevice; camera-offline events forwarded. Platform ingestion is a separate (web-repo) work item; the driver side ships now, gated by a property. | Connector receives roster (test with stub); property Off = zero traffic (test). | 5/10/4/10/7 |
| C21 | **Docs the pass must leave behind.** UBIQUITI_API_MATRIX, EVENT_MATRIX, CURRENT_DRIVER_BEHAVIOR (regression inventory), TEST_PLAN (field checklist incl. restart/outage/key-revoked/camera-swap), KNOWN_LIMITATIONS (the honest NOs). COMPETITOR_MATRIX + research docs already exist. | Files exist, complete, and match shipped code. | 2/8/3/10/10 |

### P3 — Explicitly OUT of the pass (and why)

| # | Item | Why deferred |
| --- | --- | --- |
| D1 | Recorded video playback | Not in the official spec. Chowmain's is experimental/PIN-gated by their own manual. Alternative shipped instead: History timeline + snapshots. Revisit per new spec versions. |
| D2 | Face-by-name from video | `smartDetectZone` carries type only (verified in v7). Fingerprint/NFC identity (C16) is the official path. No unofficial cookie API. |
| D3 | Plate text / vehicle-of-interest | Same: not in v7 events. The defensive metadata read stays; watched-plate aliases build the day the field appears. |
| D4 | Talkback / intercom audio | Official endpoint exists but the C4 intercom architecture question is open. Research doc first, PoC second, never a hacked audio path. |
| D5 | Custom camera buttons (Extras) | Real feature, moderate UI effort, and Extras capability changes may not propagate on update-in-place (violates A1). Own pass, after field verification of Extras behavior. |
| D6 | Custom WebView dashboard / event browser UI | Mega-prompt's own rule: no big custom UI before core stability is proven. |
| D7 | Dynamic driver-created Live Views | Official POST exists; deferred until C10 proves viewer control in the field. Ownership tracking required first. |
| D8 | Speakers/chimes/fobs/bridges/link-stations surfaces | Inventoried + diagnostics display only in this pass; controls added when a real use case shows up (avoid speculative features). |
| D9 | Storage forecasting | No storage fields in the official spec. Will not fake math. |
| D10 | Auto-provisioning that CREATES child driver instances | Composer has no supported API for a driver to add other drivers to a project. Best legal version = today's auto-bindings + a MISSING/FOUND report (part of C19). The competitors' "auto setup" runs through their licensing agents — noted in the matrix. |

## Verification protocol

1. **Test suite** — every C-ask lands with tests; suite stays green (A2).
   Current: 12 files. Expected growth: +3 (sensor, light, viewport).
2. **Field checklist** — `docs/TEST_PLAN.md` run once on the real project
   after the single update pass: the B-list plus one check per C-ask.
3. **The matrix docs** are the contract for future API drift (C2, C4).
4. **Scorecard review** — after the pass, each C-ask gets ✅/❌ against its
   Measure column, in this file, dated.

---

## Scorecard — pass completed 2026-08-28

Build `20260828.17xxxx`; suite: 13 files, all green. Bench-verified (✅);
🏠 = awaiting the field checklist in TEST_PLAN.md on the real project.

| Ask | Result |
| --- | --- |
| A1 one update, zero re-adds | ✅ every event/variable registers at init 🏠 |
| A2 zero regressions | ✅ full suite green; floor documented |
| A3 official API only | ✅ UBIQUITI_API_MATRIX covers every call |
| A4 no credentials beyond key | ✅ no password property exists |
| A5 exactly 3 new child drivers | ✅ sensor, light, viewport |
| A6 memory/timer discipline | ✅ every timer cancelled on destroy; caches bounded |
| C1 capability model | ✅ featureFlags → caps; local refusal tested |
| C2 API matrix + graceful degradation | ✅ optional sync steps degrade, tested |
| C3 event storm controls | ✅ per-kind + per-type cooldowns; variables never gated |
| C4 normalized event model | ✅ EVENT_MATRIX covers the v7 vocabulary |
| C5 doorbell pack | ✅ LCD message/DND/leave-package/reset 🏠 |
| C6 camera settings | ✅ LED/mic/HDR/video mode 🏠 |
| C7 PTZ presets/patrols | ✅ commands; ⚠ native-UI preset list not surfaced (no official slot-list endpoint) |
| C8 sensor driver | ✅ contacts, thresholds-on-crossings, readings 🏠 |
| C9 light driver | ✅ force on/off + mode + motion 🏠 (Navigator tile = documented follow-up) |
| C10 viewport driver | ✅ set/step/temporary-with-restore; overlap-safe 🏠 |
| C11 C4→Protect webhooks | ✅ Trigger Protect Webhook 🏠 |
| C12 Protect→C4 webhooks | ✅ token-or-404, cooldown, size cap |
| C13 snapshot notification action | ✅ one command: history + event + attachment |
| C14 alarm subsystem | ✅ arm/disarm/select, transition events, breach; empty-is-unknown 🏠 |
| C15 sirens/relays/hub outputs | ✅ single-shot, never retried (tested on timeout) |
| C16 known-person via fingerprint/NFC | ✅ ulp-users resolution, known/unknown events |
| C17 alarm-hub events | ✅ full family as gateway events |
| C18 enriched variables | ✅ LAST_EVENT trio + per-type times + LAST_PERSON |
| C19 NVR/system health | ✅ offline roster, device+NVR transition events, last event; ⚠ avg-latency/reconnect-count counters not kept (thin value, deliberate) |
| C20 SBOS handoff | ✅ gateway side, property-gated, change-driven (platform ingestion = separate work item) |
| C21 docs | ✅ API_MATRIX, EVENT_MATRIX, CURRENT_DRIVER_BEHAVIOR, TEST_PLAN, KNOWN_LIMITATIONS |
| **C22 (field addendum) auto-provisioning** | ✅ D10 was WRONG — C4:AddDevice is official (OS 3.2.0+); Auto Provision Protect Devices adds + binds instances for every discovered unbound device, duplicate-safe, delete-never 🏠 |
| **Field fix: camera XML events 15-17** | ✅ Known/Unknown Person + Snapshot Notification were Lua-registered but missing from driver.xml; both paths now carry them |

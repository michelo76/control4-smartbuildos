# SmartBuildOS AI Core — Implementation Report

Date: 2026-11-18 (close-out), with section 10 added on 2026-11-19 for round two · Author: the conductor · Companion documents: `ARCHITECTURE.md`, `IMPLEMENTATION_CHECKLIST.md` (same folder). Source of truth for decisions and verification: the conductor's facts file `STATUS-2026-11-18-evening.md` and `SPEC-webview-and-driver-reporting.md` §8.

Final heads at the time of the conductor's final rerun: driver `feat/ai-core` at `26a3d44`, plus documents-only commits after it; platform `codex/ai-core` at `2ebbd5bd2`.

## Summary

AI Core is built and passes its automated tests **in simulation only**. Nothing has run on a physical Control4 controller or a Navigator touchscreen, no live AI provider call has been made, and no real booking, calendar or places service has been contacted. Each of those is recorded as blocked, not done.

- **Pull requests are open, not merged:** driver `michelo76/control4-smartbuildos#49` (`feat/ai-core`) and platform `michelo76/smartbuildos#435` (`codex/ai-core`), opened on 2026-11-18 with the owner's go-ahead. Commits made after that first push stay local until the conductor pushes them.
- **No migration has been applied to any remote database.**
- **Nothing has been published to the Driver Store.** No `.c4z` has been built for the drivers changed after the first push.
- **Round two is built in simulation on separate, unpushed branches** (section 10): live device answers, dealer-set preset questions on the touchscreen, battery and sensor health. Driver `feat/ai-core-round2` (stacked on `09d138b`) and platform `codex/ai-core-round2` (stacked on `e30367901`); the two pull requests are frozen at those heads for the owner to apply and deploy and **do not contain round two**. Its one new migration is not applied anywhere remote.

The owner took nine decisions on 2026-11-18 (price, the ninth Studio destination, Flight Recorder retention, household-analysis scheduling, a touchscreen page, driver reporting from every driver, PIN approvals, a PIN-locked chat, all 52 drivers). They were built the same day as two new phases (11 and 12 in the checklist).

**How to read "verified" in this report.** Three classes are used throughout:

- **SIM** — automated tests against emulators, mocks and fixtures.
- **HW** — needs a physical Control4 controller. Not done.
- **LIVE** — needs a real credential or a vendor grant. Not done.

Each result says who ran it: the conductor (rerun), a worker (reported, not rerun), or nobody.

---

## 1. What was implemented

### The original ten phases (before the first push)

**Driver side (Control4 repository)**

- **Module contract v2** — the driver-to-driver protocol, a superset of v1, hub-and-spoke through the SmartBuildOS Agent: discovery, publish/subscribe, request/response with deadlines and idempotency, a cloud relay with a closed operation list, per-module rate limits, sender stamping and a closed error vocabulary (`docs/protocol/MODULE-CONTRACT-V2.md`). Existing v1 modules are unchanged.
- **Agent changes** — v2 negotiation, directory, bus, relay and counters; two existing Agent bugs fixed on the way.
- **Flight Recorder** — a v2 manifest and local history queries over the bus.
- **AI Core driver** (`drivers/smartbuildos-ai-core`) — Composer properties, programming commands, events, variables, system-event and device-state collection with exclusions and no double capture, an offline priority buffer, restricted cloud operations, health, diagnostics, licence states with grace. No AI provider key ever reaches the controller.

**Cloud side (platform repository)**

- Database tables (`ai_core_*`) with row-level security, explicit grants and rollbacks; the controller route `/api/integrations/control4/modules/rpc`.
- Anthropic (Messages) and OpenAI (Responses, `store:false`) behind one neutral interface; credential vault; spend and rate limits in the database.
- The orchestrator: the model calls only typed tools from a fixed registry; tool results are untrusted; citations must come from the same turn.
- Flight Recorder intelligence; household learning with deterministic detectors and homeowner controls; a permission engine; approved device actions through the existing command queue; programming changes as hand-off records only.
- System Studio "Intelligence" pages; the homeowner portal; a concierge with a sandbox provider labelled SIMULATION; calendar adapters written against documented formats.
- Licensing through the existing Driver Store (SKU `SBOS_AI_CORE`).

### Added on 2026-11-18 after the first push

**Owner decisions carried out**

- **Price:** $150 dealer (one-time, per controller), $250 MSRP. Public surfaces show only the MSRP. A purchase grants `BASE`, `AI_LEARNING`, `AI_ACTIONS` (never `AI_CONCIERGE`). AI Core cannot be bought until a release is published. No plan includes it.
- **"Intelligence"** stays a ninth top-level Studio destination.
- **Flight Recorder retention** is scheduled nightly by a migration (not applied anywhere).
- **Household analysis:** a per-property schedule the dealer sets (off by default; daily or weekly, property-local time) and an 11th Composer command, *Run Household Analysis* (`AI_RUN_HOUSEHOLD_ANALYSIS`, op `analyze_household`), both through one entry point and one set of gates.

**Touchscreen page and PIN (checklist Phase 11)**

- **PIN Lock** now serves AI Core over the bus (`pinlock.availability`, `pinlock.challenge`, `pinlock.redeem`) and a `/verify` route on its own relay. Owner codes only; guest and vendor codes are always refused; one lockout shared with PIN Lock's own page. No code name or slot leaves PIN Lock.
- **AI Core touchscreen page:** status without a PIN; the chat is locked behind an owner PIN and relocks after 5 idle minutes; each approval needs its own PIN entry; no PIN ever enters AI Core; text is shown with `textContent` only. It works only on the home network.
- **Cloud:** approval operations for the touchscreen, a ceiling of low and medium actions (in code and by a database check), single-use nonces, a freshness window, rate caps, two homeowner switches (both off by default; staff can only switch approvals off), a notice to the homeowner on every touchscreen decision, and a new risk class `medium` that is never automatic.

**Driver reporting (checklist Phase 12)**

- **Bus foundations:** any registered module may report to AI Core; the Agent binds the reserved module ids to their driver files and marks each registration `verified` or not; the registry holds 48 modules; declared driver actions need the homeowner's Remote Control at Comfort or above; module frames are kept out of debug logs; duplicates are detected per sender.
- **A shared helper** (`sbos.aireport`) any driver can use to describe itself, report state, events and diagnostics, declare read-only queries and actions, and show an `AI Core` property; **a small passive module** (`sbos.aipresence`) for child drivers; **the Agent** derives its own property from its registry and now shows AI Core's version and whether it is verified.
- **AI Core's report hub** batches reports to the cloud, relays queries and declared actions to the driver that declared them, and reports the real outcome (`started` is never shown as `completed`).
- **Reference drivers:** Atmosphere, Mode Composer (declares `activate_mode`, the only declared action in the repo) and Flight Recorder.
- **Rollout:** 51 of 52 driver directories show the `AI Core` property (AI Core itself is the exception): 20 root drivers report (VenueFlow only while its Remote Management property is on), 30 children show it passively, and the Agent derives it. A repo-wide test fails if a driver lacks it.
- **Cloud:** ingest and stores for driver reports, query results and action results; three new tools (`drivers.list`, `drivers.run_query`, `drivers.propose_action`; 37 tools in all); a staff-only "Connected drivers" page in System Studio.
- **A packaging check that needs no packager:** for every driver, the module list the build would squish into the `.c4z` is generated with the repo's own steps and compared with every module the driver can load; no child carries the report helper or the module client.

**Migrations.** Twelve files, each with a rollback, each a single transaction with a 5-second lock limit, with the order enforced both ways (a file refuses to run before the one it needs, and a rollback refuses while a later file depends on it):

| # | File stamp | Content |
| --- | --- | --- |
| 1 | `20261118120010` | foundation |
| 2 | `20261118120100` | driver catalogue row for `SBOS_AI_CORE`, without a price |
| 3 | `20261118140000` | credentials and usage |
| 4 | `20261118150000` | learning |
| 5 | `20261118160000` | conversations |
| 6 | `20261118170000` | actions |
| 7 | `20261118180000` | concierge |
| 8 | `20261118190000` | integration |
| 9 | `20261118200000` | Flight Recorder retention schedule |
| 10 | `20261118210000` | touchscreen approvals |
| 11 | `20261118211000` | driver reports |
| 12 | `20261118220000` | the price — applied only AFTER the new app is deployed |

An independent reviewer (a separate worker that wrote none of it) ran two passes on a local database. Second-pass verdict, on platform `2ebbd5bd2`: **"ready with conditions"**. Every first-pass finding is closed. One new medium finding: on Supabase, creating a policy takes a lock on the sign-in and Storage tables until the file commits; the fix — moving policies to the end of each file — was in progress at the time of writing. Update: that fix has landed (platform `0a128d748`: the policies are now the last statements of each file) and the same reviewer ran a third pass on it — final verdict: ready to apply by hand with the conditions in its runbook; every finding closed, accepted or documented; nothing new found. Reviewer-reported, not rerun by the conductor. The first file was renumbered from `20261118120000` to `20261118120010` on 2026-11-19, after `main` gained an unrelated migration with the same version number; its contents did not change.

The reviewer's conditions for applying them:

1. Files 1–11, then deploy the AI Core app, then file 12 (the price). Roll file 12 back before rolling the app back; with today's production app, file 12 would make the $150 dealer price public.
2. Run `PREFLIGHT.sql` first and clear every stop it reports.
3. Back up the Flight Recorder history before file 9: its first nightly run deletes the whole backlog beyond the windows (30 days events, 90 days traces) in one pass.
4. Use a quiet window (the lock finding above can stall sign-in, token refresh and Storage for up to the 5-second limit; a file that hits it can be run again).
5. Record the versions under their file stamps (eleven rows, then the twelfth after file 12).

The reviewer's documents (`REVIEW.md`, `PREFLIGHT.sql`, `POSTCHECK.sql`, `APPLY-ORDER.md`) are in `ai-core-program/migrations-review/`, not in either repository.

### Documents and deliverables

| Deliverable | Location |
| --- | --- |
| Architecture, checklist, this report | `ai-core-program/` (working copies) and driver repo `docs/ai-core/program/` (committed copies) |
| Webview and driver-reporting specification (with the conductor's rulings, §8) | `ai-core-program/SPEC-webview-and-driver-reporting.md` |
| Migration review | `ai-core-program/migrations-review/` |
| Repository analyses (5) | `ai-core-program/analysis/` |
| Protocol specification | driver repo `docs/protocol/MODULE-CONTRACT-V2.md` |
| Driver reference, installation, release, test matrix, known issues | driver repo `docs/ai-core/` |
| How any driver reports to AI Core | driver repo `docs/DRIVER_PLATFORM_GUIDE.md` §9 |
| Developer API, operations, migrations, driver contract, test matrix | platform repo `docs/ai-core/` |
| Interactive guide | driver repo `docs/ai-core/guide/` — rebuilt for the 2026-11-18 additions and the final numbers |
| Screenshots from browser passes | `ai-core-program/screenshots/` |

---

## 2. What was tested, and by whom

### Rerun by the conductor

| Check | Result |
| --- | --- |
Run on 2026-11-18 at driver `26a3d44` and platform `2ebbd5bd2`.

| Check | Result |
| --- | --- |
| Driver unit suite (`make test`, run with the platform repo) | 192 test files, 13,350 checks, 0 failed |
| Driver lint | 0 warnings and 0 errors in 429 files |
| Director emulator through the real Agent — AI Core | 126 of 126 |
| Director emulator — module contract v2 | 24 of 24 |
| Director emulator — driver reporting | 47 of 47 |
| Director emulator — reference drivers | 39 of 39 |
| Director emulator — touchscreen webview with the real PIN Lock | 34 of 34 |
| Platform unit suite (run with the driver repo, so the cross-repo comparisons are included) | 12,632 of 12,632, 0 skipped |
| Platform typecheck | 0 errors |
| Platform lint | 0 errors; 1,432 warnings that predate this work |
| Platform browser tests (`npm run test:e2e:ai-core`) | 22 of 22 |
| Interactive guide — consistency test | 946 assertions, passing |
| Interactive guide — browser test | 831 controls exercised, 2,435,469 assertions, 0 failures, 0 network requests |
| Counted: driver directories that declare the `AI Core` property | 51 of 52 (the exception is AI Core itself); only Mode Composer declares an action |

The conductor also reran each driver brief's gates on a snapshot as it landed (bus foundations, helper, PIN Lock, report hub, hardening, reference drivers, rollout to the root drivers, webview, children / Agent / VenueFlow, documents) and the platform's gates at each platform brief. Earlier on 2026-11-18, at the heads before the first push (driver `1a99e24`, platform `4e86ca3c6`), the conductor reran every gate in both repositories. One browser-test failure on the way was traced to a test helper that waited four seconds per page for a cookie banner that never reappears; it was fixed in the test, and it was not a product slowdown.

After the final rerun, the documents-only close-out commits changed only documents and the guide. On those commits the documents worker reran, worker-reported and not rerun by the conductor: `make test` without the platform repo 192 files, 13,183 checks, 0 failed (the cross-repo parity checks skip without `SBOS_PLATFORM_REPO`, which accounts for the difference from 13,350); `make lint` 0 warnings and 0 errors in 429 files; the guide's consistency test 994 assertions, 0 failures, and its browser test 835 controls exercised, 2,435,473 assertions, 0 failures, 0 network requests.

### Reported by workers, not rerun by the conductor

- The migrations applied, QA'd, rolled back and re-applied on a local Postgres (the original eight by the platform workers; all twelve, in two passes, by the independent reviewer), including pg_cron firing the retention job locally.
- The defect-reintroduction proofs (each new guard shown to fail when the defect it guards is put back).
- The offline packaging check's per-driver results (all 52 pass) beyond its inclusion in the 192 files the conductor ran.
- Source-size growth figures (section 6).
- Facts taken from vendor web documentation on 2026-11-18 (model ids and prices, DriverWorks behaviour).
- Prose accuracy beyond what the automated consistency checks cover.

### Never run by anyone

- Anything on a physical Control4 controller or Navigator: driver load in Composer, the touchscreen tile, the PIN posted from AI Core's page to PIN Lock's port, page-close events, system events reaching child drivers, Director's answer for identity binding, sizes at a 48-module registry, bus latency against the 15 s query wait, an approved action changing a real device.
- A real call to Anthropic or OpenAI; a real calendar, places or booking call.
- A `.c4z` build of the changed drivers; real package sizes are unmeasured (see section 6).
- Any migration on a remote database.

---

## 3. What remains incomplete

| Item | Why |
| --- | --- |
| Hardware verification (checklist 2.17, 3.12, 7.9, 11.10–11.12, 12.14–12.18) | No controller or Navigator available |
| Live AI provider calls (5.11, 5.12) | No API key |
| Real restaurant booking (9.6) | No vendor agreement |
| Real calendar and places use (9.7) | No OAuth client credentials or API key |
| `.c4z` for the changed drivers (10.8, 12.19) | No packager in this worktree |
| New versions of all 52 drivers (12.20) | Owner decision and go-ahead |
| The last migration fix from the independent review (lock ordering, 10.14) | In progress at the time of writing |
| Round two (Phase 13): built in simulation on unpushed branches; the platform's matching preset rule and temperature unit (13.11) in progress; hardware checks 13.12–13.15; camera descriptions on hold (13.16) | See section 10; owner decisions 26–30 |
| "Rarely used scenes", seasonal patterns, away-mode recommendations | The data does not support them: about 30 days of history and no scene inventory |
| Automatic acceptance of a programming recommendation into a blueprint | Composer Studio has no per-project programming field |
| Driver-side licence transfer workflow | Transfer is a platform staff action today |
| Merge, production migrations, store publication (10.11, 10.12) | Owner review and go-ahead |

---

## 4. Dependencies requiring external authorisation

| Dependency | What is needed | Who |
| --- | --- | --- |
| Anthropic and/or OpenAI | An API key entered in System Studio | Owner / customer |
| Google Calendar | OAuth client credentials and Google app verification | Owner |
| Microsoft Graph calendar | OAuth app registration | Owner |
| Google Places | API key | Owner |
| OpenTable, Yelp Reservations, SevenRooms | A partner agreement each | Owner with each vendor |
| Resy, Tock | No sanctioned booking API exists | — |
| Control4 hardware | A controller on OS 3.3.2 or later with Composer Pro, a touchscreen running Navigator | Owner |
| Production database | Review and apply of the migrations (staging first) | Owner |
| Driver Store | Building and publishing the `.c4z` files | Owner |

---

## 5. Supported Control4 versions

- **Minimum: Control4 OS 3.3.2.** Features that exist only in 3.4 or 4.x are probed at runtime and skipped when absent. On OS 4.3 a driver cannot read its own `.c4z` files, so the touchscreen page is embedded in the driver's Lua.
- **Requires** the SmartBuildOS Agent with module contract protocol 2 in the same project. With an older Agent, or none, AI Core loads and reports itself degraded; other drivers' `AI Core` property says the Agent needs an update or is missing.
- **Optional:** the Flight Recorder (history), PIN Lock (touchscreen chat and approvals; without a verified PIN Lock the page says to use the portal).
- These claims come from the DriverWorks documentation, existing drivers' field notes and the emulator. **None is confirmed on hardware.**

---

## 6. Technical limitations

From DriverWorks itself:

- No callback when Composer programming runs and no API to write programming: AI Core recommends programming changes; it cannot make them.
- No sender identity and no publish/subscribe between drivers: the Agent supplies both, and proves a reserved module's driver file by asking Director (unmeasured on hardware).
- A driver cannot read Control4's own History and cannot send push or email.
- No secure input for a driver's page: the PIN crosses the home network as plain HTTP to PIN Lock, as on PIN Lock's own page. The cloud cannot verify a PIN; it trusts AI Core's statement that PIN Lock verified an owner PIN, bounded by the homeowner's opt-in, the low/medium ceiling, rate caps, freshness and a single-use nonce.
- The touchscreen page works only on the home network.

Design limits worth knowing:

- AI Core's report hub and the touchscreen state are memory only: a restart drops waiting reports and locks every page.
- A declared action that gets no answer in 20 s is reported failed with "outcome unknown"; the driver may have run it. Actions are never retried.
- The first Flight Recorder retention run deletes the whole backlog past its windows in one pass.
- **Size growth (worker-reported, not rerun by the conductor; source before compression):** each reporting root driver gains about 134 KB of source, each child driver about 15 KB; all drivers together go from 17.7 MB to 20.8 MB. Squish strips comments and the `.c4z` is a zip, so packages grow less — but real `.c4z` sizes are unmeasured.
- The Agent's main Lua chunk is at 198 of Lua's 200 top-level locals (unchanged by this work).

---

## 7. Known issues

The driver repo's `docs/ai-core/KNOWN-ISSUES.md` holds 62 numbered entries (KI-1 to KI-62): 59 still standing (open, mitigated or by design) and 3 marked closed (KI-43, KI-47, KI-51). On the unpushed round-two branch `feat/ai-core-round2` the same file holds 74 (KI-1 to KI-74): 69 standing and 5 closed (KI-67 and KI-68 also closed); KI-63 to KI-74 are round two's (section 10). The ones most likely to matter:

- **Not verified on hardware** (KI-10 to KI-16, KI-41, KI-42, KI-52, KI-53, KI-56): load on 3.3.2 and 4.x, frame ordering and sizes, sizes at 48 modules, whether child drivers receive the system events the passive module relies on, bus latency, the cross-port PIN post in Navigator, page-close events.
- **The PIN on the home network** travels as plain HTTP (KI-54), and the cloud cannot verify it (KI-58).
- **Lost results:** a query or action result that still cannot be delivered after two retries is only logged (KI-44); the hub forgets waiting events on restart (KI-45).
- **The shared envelope library** cuts text by bytes and can split a character; AI Core guards against it, other drivers do not (KI-1). A request id inside some payloads arrives redacted (KI-36).
- **Settings delivery:** a configuration reaches a newly added AI Core only at the next change (KI-8); the Studio page text still says "next check-in" (KI-9).
- **Licensing:** a tampered licence assertion is dropped and the driver keeps running, as for every SmartBuildOS driver (KI-24, KI-25).
- **Release:** nothing is released (KI-26); the store workflow does not deliver the Flight Recorder (KI-27); tag and version gaps in `release.yml` (KI-28).
- **Database:** the repo's migration history cannot be replayed from empty (KI-33); a rollback deletes certain memories (KI-34).
- KI-46 says the platform's driver-report handlers have landed (built and tested in simulation, not deployed); KI-32 names the twelve migration files and the reviewer's verdict.

---

## 8. Next steps

1. The conductor pushes the follow-up commits to the two open pull requests after the final rerun.
2. Finish the last migration fix (lock ordering) and its re-review; then apply to a staging or branch database first, then production, under the reviewer's conditions (section 1), using the platform's `docs/ai-core/MIGRATIONS.md` and `migrations-review/APPLY-ORDER.md`. Back up the Flight Recorder history before file 9.
3. Review and merge the two pull requests.
4. **Hardware pass:** load the drivers on a real controller and run the hardware column of the test matrix, including the touchscreen page, the PIN post to PIN Lock, identity binding, child system events and a declared action. Treat everything as unproven until then.
5. Build the `.c4z` files where the packager is available, measure their sizes, and decide whether to publish new versions of all 52 drivers.
6. One live AI call per provider with a real key.
7. Start the vendor conversations for calendar OAuth and reservation partners if the concierge is to go beyond the sandbox.
8. Round two (section 10): the conductor's final rerun at the round-two heads; then the owner decides whether to ship it, push its branches, and apply its migration (after file 12, before the round-two app). Camera snapshot descriptions stay on hold for an owner decision on privacy.
9. Work through the open owner decisions, including 24 (pre-existing database permissions), 25 (owner PIN and household answers) and the round-two decisions 26–30.

---

## 9. Decisions waiting on the owner

The full list is at the end of `IMPLEMENTATION_CHECKLIST.md`.

- **Decided on 2026-11-18:** 1 (ninth Studio destination), 2 (price; plan inclusion still open under 13), 4 (Flight Recorder retention), and the scheduling part of 7. 8 was resolved earlier.
- **Still open:** 3 (one-click import of plaintext company AI keys), 5 (store category), 6 (default limits, budget month, unknown-cost rollups), 7 without scheduling (detector thresholds, re-raising a dismissed recommendation, whether a subscription grants `AI_LEARNING`), 9 (email notices; action limits), 10 (no per-project programming field in Composer Studio), 11 (tampered-licence policy), 12 (pre-existing release gaps), 13 (plan inclusion), 14 (staff route scope), 15 (erase semantics).
- **New, for the owner to confirm or change (16–23):** the touchscreen ceiling (low and medium); homeowner-only opt-in; owner PINs only; no PIN name recorded; the freshness window and rate caps; the driver-report limits (64 live drivers, 2,000 events a day, 30-day retention); whether to build and publish new versions of all 52 drivers; whether to add PIN-protected approval of recommendations later.
- **New at the close-out (24–25):** 24 — pre-existing database permissions found during the review, outside these migrations and not changed by them: the signed-out and ordinary signed-in roles hold TRUNCATE on `companies` and `profiles`, and TRIGGER / MAINTAIN / REFERENCES on `ai_usage_events` (the migrations revoke only TRUNCATE on `ai_usage_events`); 25 — whether an owner PIN alone should unlock household answers on the touchscreen (today a separate homeowner portal switch, default off).
- The conductor's 24 rulings (each reversible) are in `SPEC-webview-and-driver-reporting.md` §8.
- **New with round two (26–30):** 26 — whether an owner PIN alone should unlock door, lock and light state on the touchscreen (today no); 27 — whether to apply the round-two migration; 28 — whether to switch System Studio monitoring on by default; 29 — whether lights and media count as occupancy (today yes); 30 — camera snapshot descriptions, still on hold.

---

## 10. Round two (2026-11-19, on separate, unpushed branches)

Driver `feat/ai-core-round2` (stacked on the frozen `09d138b`) and platform `codex/ai-core-round2` (stacked on the frozen `e30367901`). **Not pushed. The frozen pull requests #49 and #435 do not contain any of this.** Specification and rulings: `SPEC-round2-live-answers.md` §9. Checklist Phase 13.

### What was built

- **A live device read.** Restricted operation `ai_core.read_device_state` (platform → controller) and cloud op `device_state_result` (controller → platform). AI Core reads one device once and decides on the controller, before anything leaves the home, what may be sent: cameras refused in every scope; locks, security, doors, motion, contacts, relays and lights refused at scope `system`; secret, personal and occupancy names dropped and counted; at `system` only reviewed allow-lists. The platform screens the answer a second time.
- **Two read-only AI tools, making the fixed set 39:** `devices.get_state` (one device, live, waits up to 15 seconds and otherwise says no current value is known) and `devices.health` (battery and sensor health from the samples the SmartBuildOS Agent already uploads when System Studio monitoring is on — off by default; the tool says plainly when it is off).
- **What a touchscreen can be told** with the homeowner's portal switch off: temperature, humidity, battery, signal quality, online status and the temperature scale. Locks, security, doors, motion, contacts, relays, lights and cameras are refused before anything is sent. Never energy: there is no energy data anywhere, and the AI is held to saying so. With the switch on, or in the portal for a signed-in homeowner, the existing household rules decide. Cameras are always refused.
- **Dealer preset questions:** at most 6, set by staff in Studio, shown on the touchscreen only after the chat is unlocked with an owner PIN, alongside the three built-in questions. Delivered only to a controller whose AI Core registers the live read (an older driver gets the round-one document byte for byte).
- **One new migration, `20261119120000_ai_core_round2.sql`** — not one of the twelve. The owner applies it only if and when he ships round two: after file 12, before the round-two app. Its rollback deletes every home's presets.

### Rerun by the conductor (snapshots during round two)

| Snapshot | Result |
| --- | --- |
| Driver `64660fb` (live read) | 194 test files, 0 failed; lint 0/0; emulator 132, 47, 39, 34, 24, all passing |
| Driver `1a663b1` (filter fixes and presets) | 194 test files, 0 failed; lint 0/0; emulator 132, 47, 39, 37, 24 |
| Platform `e68167946` (wire, handler, round-two migration) | unit 12,710 of 12,710; typecheck 0 errors; lint 0 errors and 1,432 pre-existing warnings; browser 22 of 22; the twelve frozen migration files unchanged |
| The round-two heads (the platform's tools-and-presets head; the driver's last head) | ⟨conductor: round-two final totals⟩ |

### Reported by workers, not rerun by the conductor

- The platform's two tools, the Studio presets editor with the gate, and the energy guard (platform unit and browser tests on `codex/ai-core-round2` after `e68167946`).
- The round-two migration on a throwaway local database: apply, its QA script, re-apply refused by name, rollback to an identical schema, apply again.
- The driver's last two changes after `1a663b1` (the temperature scale travels with a temperature; a preset may say "desk-lamp"), with `make test`, lint, the emulator runs and a reintroduce-the-defect proof for each.
- Every other defect-reintroduction proof of round two.

### Never run by anyone

- Anything on a physical controller or touchscreen: the real variable names of batteries, locks and appliance sensors; whether a device's protocol id exposes its proxy's variables; a live read's time on a large project; how a preset button wraps on a real touchscreen (checklist 13.12–13.15).
- A live AI provider call; a `.c4z` build; a publication; the round-two migration on any remote database.

### Still open in round two

- The platform's identical preset `sk-` rule and temperature unit were being added by another worker at the time of writing (13.11).
- Owner decisions 26–30 (section 9).

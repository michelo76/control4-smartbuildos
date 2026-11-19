# SmartBuildOS AI Core — Implementation Report

Date: 2026-11-18 (evening) · Author: the conductor · Companion documents: `ARCHITECTURE.md`, `IMPLEMENTATION_CHECKLIST.md` (same folder). Source of truth for decisions and verification: the conductor's facts file `STATUS-2026-11-18-evening.md` and `SPEC-webview-and-driver-reporting.md` §8.

Final heads: driver `feat/ai-core` ⟨conductor: final head⟩; platform `codex/ai-core` ⟨conductor: final head⟩.

## Summary

AI Core is built and passes its automated tests **in simulation only**. Nothing has run on a physical Control4 controller or a Navigator touchscreen, no live AI provider call has been made, and no real booking, calendar or places service has been contacted. Each of those is recorded as blocked, not done.

- **Pull requests are open, not merged:** driver `michelo76/control4-smartbuildos#49` (`feat/ai-core`) and platform `michelo76/smartbuildos#435` (`codex/ai-core`), opened on 2026-11-18 with the owner's go-ahead. Commits made after that first push stay local until the conductor pushes them.
- **No migration has been applied to any remote database.**
- **Nothing has been published to the Driver Store.** No `.c4z` has been built for the drivers changed after the first push.

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

**Migrations.** Eleven files with rollbacks, plus a twelfth that carries the price so it can be applied after the new app is deployed. An independent review found them "ready with conditions"; its fixes are being applied. Final list: ⟨conductor: final migration list⟩.

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
| Interactive guide | driver repo `docs/ai-core/guide/` — describes the state before the 2026-11-18 additions; to be rebuilt from these documents |
| Screenshots from browser passes | `ai-core-program/screenshots/` |

---

## 2. What was tested, and by whom

### Rerun by the conductor

| Check | Result |
| --- | --- |
| Driver unit suite (`make test`) | ⟨conductor: final totals⟩ |
| Driver lint | ⟨conductor: final totals⟩ |
| Director emulator — AI Core scenarios | ⟨conductor: final totals⟩ |
| Director emulator — module contract v2 | ⟨conductor: final totals⟩ |
| Director emulator — driver reports, reference drivers, webview with the real PIN Lock | ⟨conductor: final totals⟩ |
| Platform unit suite, typecheck, lint | ⟨conductor: final totals⟩ |
| Platform browser smoke spec | ⟨conductor: final totals⟩ |

Earlier on 2026-11-18, at the heads before the first push (driver `1a99e24`, platform `4e86ca3c6`), the conductor reran every gate in both repositories; the driver work added after the push was verified by the conductor rerunning the driver gates on a snapshot. Those intermediate numbers are not repeated here as final.

### Reported by workers, not rerun by the conductor

- The platform tests for the work added after the first push (touchscreen approvals, driver reports, tools, schedule, price), until the conductor's rerun above.
- The two driver changes made last: the Agent's two new `AI Core` values and the all-driver packaging check (worker-run on 2026-11-18; each proven by breaking what it guards).
- The migrations applied, rolled back and re-applied on a local Postgres (original eight by the platform workers; all eleven by the independent reviewer).
- Facts taken from vendor web documentation on 2026-11-18 (model ids and prices, DriverWorks behaviour).
- Prose accuracy beyond what the automated consistency checks cover.

### Never run by anyone

- Anything on a physical Control4 controller or Navigator: driver load in Composer, the touchscreen tile, the PIN posted from AI Core's page to PIN Lock's port, page-close events, system events reaching child drivers, Director's answer for identity binding, sizes at a 48-module registry, bus latency against the 15 s query wait, an approved action changing a real device.
- A real call to Anthropic or OpenAI; a real calendar, places or booking call.
- A `.c4z` build of the changed drivers; package size growth is unmeasured (see section 6).

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
| Migration fixes from the independent review (10.14) | Being applied |
| Interactive guide refresh (10.3, 10.4) | Rebuilt by a later brief from these documents |
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
- Package growth is unmeasured as `.c4z` sizes. Offline, the uncompressed source fed to the squish step grows by about 15 KB per child driver (the passive module and the value list) and about 70–155 KB per reporting root driver (the helper, the module client and their dependencies), and about 20 KB for the Agent; about 3.1 MB across all 52 drivers, before squish strips comments and before zip compression; one earlier scratch measurement put a child's compressed growth at about 2.7 KB.
- The Agent's main Lua chunk is at 198 of Lua's 200 top-level locals (unchanged by this work).

---

## 7. Known issues

The driver repo's `docs/ai-core/KNOWN-ISSUES.md` holds 62 numbered entries (KI-1 to KI-62): 59 still standing (open, mitigated or by design) and 3 marked closed (KI-43, KI-47, KI-51). The ones most likely to matter:

- **Not verified on hardware** (KI-10 to KI-16, KI-41, KI-42, KI-52, KI-53, KI-56): load on 3.3.2 and 4.x, frame ordering and sizes, sizes at 48 modules, whether child drivers receive the system events the passive module relies on, bus latency, the cross-port PIN post in Navigator, page-close events.
- **The PIN on the home network** travels as plain HTTP (KI-54), and the cloud cannot verify it (KI-58).
- **Lost results:** a query or action result that still cannot be delivered after two retries is only logged (KI-44); the hub forgets waiting events on restart (KI-45).
- **The shared envelope library** cuts text by bytes and can split a character; AI Core guards against it, other drivers do not (KI-1). A request id inside some payloads arrives redacted (KI-36).
- **Settings delivery:** a configuration reaches a newly added AI Core only at the next change (KI-8); the Studio page text still says "next check-in" (KI-9).
- **Licensing:** a tampered licence assertion is dropped and the driver keeps running, as for every SmartBuildOS driver (KI-24, KI-25).
- **Release:** nothing is released (KI-26); the store workflow does not deliver the Flight Recorder (KI-27); tag and version gaps in `release.yml` (KI-28).
- **Database:** the repo's migration history cannot be replayed from empty (KI-33); a rollback deletes certain memories (KI-34).
- Some entries describe the state before the platform's driver-report handlers and the later migrations landed (KI-32 still says eight migrations; KI-46 still says the platform answers `unsupported`); they need a refresh: ⟨conductor: confirm KI-32 and KI-46 wording⟩.

---

## 8. Next steps

1. Finish the migration fixes from the independent review; apply to a staging or branch database first, then production, using the platform's `docs/ai-core/MIGRATIONS.md` and `migrations-review/APPLY-ORDER.md`. Back up the Flight Recorder history the owner wants before retention's first run.
2. Review and merge the two pull requests.
3. **Hardware pass:** load the drivers on a real controller and run the hardware column of the test matrix, including the touchscreen page, the PIN post to PIN Lock, identity binding, child system events and a declared action. Treat everything as unproven until then.
4. Build the `.c4z` files where the packager is available, measure their sizes, and decide whether to publish new versions of all 52 drivers.
5. One live AI call per provider with a real key.
6. Start the vendor conversations for calendar OAuth and reservation partners if the concierge is to go beyond the sandbox.
7. Rebuild the interactive guide from these documents.
8. Work through the open owner decisions.

---

## 9. Decisions waiting on the owner

The full list is at the end of `IMPLEMENTATION_CHECKLIST.md`.

- **Decided on 2026-11-18:** 1 (ninth Studio destination), 2 (price; plan inclusion still open under 13), 4 (Flight Recorder retention), and the scheduling part of 7. 8 was resolved earlier.
- **Still open:** 3 (one-click import of plaintext company AI keys), 5 (store category), 6 (default limits, budget month, unknown-cost rollups), 7 without scheduling (detector thresholds, re-raising a dismissed recommendation, whether a subscription grants `AI_LEARNING`), 9 (email notices; action limits), 10 (no per-project programming field in Composer Studio), 11 (tampered-licence policy), 12 (pre-existing release gaps), 13 (plan inclusion), 14 (staff route scope), 15 (erase semantics).
- **New, for the owner to confirm or change (16–23):** the touchscreen ceiling (low and medium); homeowner-only opt-in; owner PINs only; no PIN name recorded; the freshness window and rate caps; the driver-report limits (64 live drivers, 2,000 events a day, 30-day retention); whether to build and publish new versions of all 52 drivers; whether to add PIN-protected approval of recommendations later.
- The conductor's 24 rulings (each reversible) are in `SPEC-webview-and-driver-reporting.md` §8.

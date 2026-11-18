# SmartBuildOS AI Core — Final Implementation Report

Date: 2026-11-18 · Author: the conductor · Companion documents: `ARCHITECTURE.md`, `IMPLEMENTATION_CHECKLIST.md` (same folder).

Final heads: driver `feat/ai-core` at guide commit `1a99e24` plus one documents-only commit; platform `codex/ai-core` at `4e86ca3c6`.

## Summary

All ten phases of the brief are built and pass their automated tests **in simulation**. Nothing has been run on a physical Control4 controller, no live AI provider call has been made, and no real booking, calendar or places service has been contacted — none of those were possible in this environment, and each is recorded as blocked rather than done.

Nothing has been pushed, tagged, published, opened as a pull request, or applied to any remote database. All work sits in two local branches:

| Repository | Worktree | Branch | Commits ahead of `origin/main` | Change size |
| --- | --- | --- | --- | --- |
| Control4 drivers | `control4-smartbuildos-ai-core` | `feat/ai-core` | 37 (after the documents commit below) | 100+ files, ~29,000 lines added |
| Platform | `smartbuildos-ai-core` | `codex/ai-core` | 89 | 326+ files, ~55,000 lines added |

**How to read "verified" in this report.** Three classes are used throughout:

- **SIM** — automated tests against emulators, mocks and fixtures.
- **HW** — needs a physical Control4 controller. Not done.
- **LIVE** — needs a real credential or a vendor grant. Not done.

Where a result was re-run by the conductor it says so; where it rests on a worker's report it says that instead.

---

## 1. What was implemented

### Driver side (Control4 repository)

- **Module contract v2** — the driver-to-driver protocol, a superset of the existing v1. Hub-and-spoke through the SmartBuildOS Agent: discovery, publish/subscribe with topic policy, request/response with deadlines and idempotency, a cloud relay with a closed operation list, per-module rate limits, sender stamping and a closed error vocabulary. Specified in `docs/protocol/MODULE-CONTRACT-V2.md`. Existing v1 modules are unchanged.
- **SmartBuildOS Agent changes** — v2 negotiation, directory, bus, relay and counters. Two existing Agent bugs were found and fixed on the way: system events were registered only if the Agent started already paired, and the licence inventory kept one device per SKU.
- **Flight Recorder driver** — a v2 manifest and local history queries served over the bus.
- **AI Core driver** (`drivers/smartbuildos-ai-core`, packaged as `smartbuildos-ai-core.c4z`) — Composer properties, 10 `AI_*` programming commands, 10 events, variables, system-event and device-state collection with exclusions and no double capture, an offline priority buffer with counted drops, restricted cloud operations, health and diagnostics, licence states with grace.
- **No credentials on the controller.** AI provider keys are never entered in Composer and never reach the driver; Composer shows a read-only status only.

### Cloud side (platform repository)

- **Database** — 20 `ai_core_*` tables in 8 migrations, each with row-level security, explicit grants and a rollback script.
- **Controller route** — `/api/integrations/control4/modules/rpc`: token auth, closed operations, idempotency.
- **AI providers** — Anthropic (Messages API) and OpenAI (Responses API, `store:false`) behind one neutral interface: tool calling, timeouts, retry, fallback provider, a versioned price table and cost accounting.
- **Credential vault and budgets** — customer-supplied keys are encrypted, shown masked only, and entered only in System Studio. Spend and rate limits are enforced in the database before any provider call.
- **Orchestrator** — the tool-calling loop. The model can call only typed tools from a fixed registry (34 tools); there is no path to arbitrary Lua, shell, SQL or device commands. Each tool declares its audience, so a technician-only tool is never offered to or run for a homeowner or a controller. Tool results are marked untrusted, and an answer's citations must come from that turn's tool results.
- **Flight Recorder intelligence** — search, timeline, device history, room activity, correlation, incident analysis and period comparison. Gaps in the data are reported as gaps, never filled in.
- **Household learning** — a structured memory store (verified vs inferred, with confidence and evidence), deterministic pattern detectors, and a recommendation lifecycle including two-party approval. Learning is off by default. Homeowners can review, correct, delete, pause, exclude, export and erase. A guard and test prevent inferring a person's identity from device activity.
- **Safe action execution** — a permission engine (modes `observe`, `recommend`, `execute_low_risk` × six risk classes). Locks, alarms, garage doors, access control, purchases, reservations, credentials and programming always need explicit homeowner approval and can never be triggered from learned behaviour alone. Approved device actions go through the existing command queue with provenance. Programming changes are hand-off records for a person, never applied automatically.
- **System Studio "Intelligence"** — Overview, Household Usage, Flight Recorder Intelligence, Recommendations, Service Intelligence, Conversations, plus provider setup, approvals, rules and hand-off screens.
- **Homeowner portal** — concierge conversation, approvals, learned-preference review, status.
- **Concierge** — a provider interface, a booking state machine and a sandbox provider labelled SIMULATION everywhere. A simulated booking is recorded `simulated_confirmed`; the database refuses `confirmed` for it. Google Calendar and Microsoft Graph adapters with homeowner OAuth are written against documented wire formats.
- **Licensing** — uses the existing Driver Store. SKU `SBOS_AI_CORE` with features `BASE`, `AI_LEARNING`, `AI_ACTIONS`, `AI_CONCIERGE`. No second licensing system was created. AI Core is licensed only by an explicit entitlement.

### Documentation and deliverables

| Deliverable | Location |
| --- | --- |
| Architecture | `ai-core-program/ARCHITECTURE.md` |
| Checklist | `ai-core-program/IMPLEMENTATION_CHECKLIST.md` |
| Copies of the architecture, checklist and this report | driver repo `docs/ai-core/program/` |
| Repository analyses (5) | `ai-core-program/analysis/` |
| Protocol specification | driver repo `docs/protocol/MODULE-CONTRACT-V2.md` |
| Driver, installation, release, test matrix, known issues | driver repo `docs/ai-core/` |
| Developer API, operations, migrations, driver contract, test matrix | platform repo `docs/ai-core/` |
| Interactive guide | driver repo `docs/ai-core/guide/SmartBuildOS_AI_Core_Interactive_Guide.html` |
| Packaged driver | driver repo `dist/oss/smartbuildos-ai-core.c4z` (git-ignored build output) |
| Screenshots from browser passes | `ai-core-program/screenshots/` |

---

## 2. What was tested

### Re-run by the conductor at the final heads

| Check | Result |
| --- | --- |
| Driver unit suite (`make test`, with the platform repo linked) | 156 test files, 10,727 checks, 0 failed |
| Driver lint | 0 warnings, 0 errors |
| Director emulator — AI Core scenarios | 125 of 125 |
| Director emulator — module contract v2 | 23 of 23 |
| Platform unit suite | 12,513 of 12,513 pass |
| Platform typecheck | 0 errors |
| Platform lint | 0 errors (about 1,430 warnings that predate this work) |
| Platform browser smoke spec (Studio and portal in fixture mode) | 12 of 12 |
| Interactive guide — consistency test | 794 assertions, 0 failures |
| Interactive guide — browser test | 798 controls, 2,352,443 assertions, 0 failures, 0 network requests |

The guide and the Studio and portal screens were also looked at by eye in screenshots at desktop and phone widths.

### Reported by workers, not re-run by the conductor

- All 8 migrations applied in order on a local Postgres, rolled back in reverse and re-applied, under both strict and default privileges; the QA SQL scripts pass, including one that acts as the application role.
- Facts taken from vendor web documentation on 2026-11-18: AI model ids and prices, and DriverWorks API behaviour.
- Line-by-line accuracy of the prose in the documents and the guide beyond what the automated consistency checks cover.

### Never tested by anyone

- Anything on a physical Control4 controller: driver load in Composer, protocol timing and frame sizes, an approved action changing a real device.
- A real call to Anthropic or OpenAI.
- A real calendar read or write, places lookup, or restaurant booking.

---

## 3. What remains incomplete

| Item | Why |
| --- | --- |
| Hardware verification (checklist 2.17, 3.12, 7.9) | No controller available |
| Live AI provider calls (5.11, 5.12) | No API key |
| Real restaurant booking (9.6) | No vendor agreement; see section 4 |
| Real calendar and places use (9.7) | No OAuth client credentials or API key |
| Scheduled household analysis (6.7) | Runs on demand only; who schedules it is an owner decision |
| "Rarely used scenes", seasonal patterns, away-mode recommendations | The data does not support them: about 30 days of history and no scene inventory |
| Automatic acceptance of a programming recommendation into a blueprint | Composer Studio has no per-project programming field; a hand-off record is produced instead |
| Driver-side licence transfer workflow | Transfer is a platform staff action today |
| Flight Recorder retention (4.7) | Enabling it deletes events older than 30 days; owner decision |
| Push, pull requests, production migrations, store publication (10.10–10.12) | Owner go-ahead required |

---

## 4. Dependencies requiring external authorization

| Dependency | What is needed | Who |
| --- | --- | --- |
| Anthropic and/or OpenAI | A customer or company API key entered in System Studio | Owner / customer |
| Google Calendar | OAuth client credentials and Google app verification | Owner |
| Microsoft Graph calendar | OAuth app registration | Owner |
| Google Places | API key | Owner |
| OpenTable, Yelp Reservations, SevenRooms | A partner agreement each | Owner with each vendor |
| Resy, Tock | No sanctioned booking API exists; not buildable legitimately | — |
| Control4 hardware | A controller on OS 3.3.2 or later with Composer Pro | Owner |
| Production database | Review and apply of the 8 migrations | Owner |
| Driver Store | Publication of the `.c4z` and a catalog price | Owner |

---

## 5. Supported Control4 versions

- **Minimum: Control4 OS 3.3.2.** Features that exist only in 3.4 or 4.x are probed at runtime and skipped when absent.
- **Requires** the SmartBuildOS Agent with module contract protocol 2 in the same project. With an older Agent, or none, AI Core loads and reports itself degraded rather than failing.
- The Flight Recorder driver is optional; without it the history features report that it is absent.
- These version claims come from the DriverWorks documentation and the emulator. **None is confirmed on hardware.**

---

## 6. Outstanding technical limitations

These come from DriverWorks itself, not from choices made here:

- A driver gets no callback when Composer programming runs, and has no API to write programming. AI Core therefore recommends programming changes; it cannot make them.
- There is no sender identity and no publish/subscribe between drivers; the Agent supplies both.
- A driver cannot read Control4's own History, and cannot send push or email.

Design limits worth knowing:

- A settings change is published at once but reaches the controller at the Agent's next configuration delivery. Only pause, resume and exclusion changes are also sent immediately.
- Job processing is triggered when the controller's request is accepted and by a staff trigger; there is no cron.
- No pattern detector currently produces a recommendation needing both homeowner and integrator approval, so that path is exercised only by fixtures.
- Device online state is stored as true when the Agent omits it; the screens say "not reported offline" rather than "online".
- The Agent's main Lua chunk is at 198 of Lua's 200 top-level locals (it was 198 before this work too). The next change to that file needs care.

---

## 7. Known issues

The full list (36 entries) is in the driver repo at `docs/ai-core/KNOWN-ISSUES.md`. The ones most likely to matter:

- The shared envelope library truncates text by bytes and can split a multi-byte character. AI Core guards against it; other drivers using the library are not changed.
- The driver's Property ID and Controller ID properties read "Not delivered yet"; the payload's `request_id` arrives redacted.
- If an AI Core instance is removed and re-added, the Agent's forwarding fingerprint can leave the new instance waiting.
- Erase behaves differently by path: "erase everything learned" deletes every recommendation including approved ones, while deleting one memory keeps approved ones.
- Thirteen staff route families scope technicians by company only, which is the platform's existing convention; three also check property visibility.
- A tampered licence assertion is dropped and the driver keeps running — the existing policy for every SmartBuildOS driver.
- Pre-existing release gaps: the store-publish workflow has no mapping for the Flight Recorder, and `release.yml` fires only on `v*` tags.
- The guide's embedded product screenshots come from the fixture-mode browser passes and were not recaptured after the last UI changes.

---

## 8. Recommended next steps

1. **Review the two branches** and decide on pushing them and opening pull requests.
2. **Apply the migrations to a staging or branch database first**, using `docs/ai-core/MIGRATIONS.md`, then production.
3. **Hardware pass**: load the three drivers on a real controller and run the test matrix's hardware column. Treat the driver as unproven until this is done.
4. **One live AI call per provider** with a real key, to confirm the adapters against the real services.
5. **Decide pricing and plan inclusion** for `SBOS_AI_CORE`, then publish to the Driver Store.
6. **Start the vendor conversations** for calendar OAuth and reservation partners if concierge is to go beyond the sandbox.
7. Work through the open owner decisions listed in `IMPLEMENTATION_CHECKLIST.md`.

---

## 9. Decisions waiting on the owner

The full list of 15 is at the end of `IMPLEMENTATION_CHECKLIST.md`. The ones that gate release:

1. Push the branches and open pull requests?
2. Apply the 8 migrations — staging first, then production?
3. Publish AI Core to the Driver Store, at what price, and included in any plan?
4. Keep "Intelligence" as a ninth top-level Studio destination, or nest it?
5. Enable Flight Recorder retention (deletes events older than 30 days)?
6. Who schedules the household analysis job, and how often?

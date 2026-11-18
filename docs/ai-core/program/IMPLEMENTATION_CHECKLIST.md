# SmartBuildOS AI Core — Implementation Checklist

Maintained by the conductor only. Architecture: `ARCHITECTURE.md` (same folder). Analysis: `analysis/01`–`05`.

**Status vocabulary:** Not started · In progress · Implemented (code written) · Tested (an automated test that fails without it passes) · Completed (tested AND verified by the conductor against the repo) · Blocked (reason given).

**Verification classes:** `SIM` = automated, simulated/emulated/mocked. `HW` = needs a physical Control4 controller. `LIVE` = needs a real external credential or vendor grant. An item with an `HW` or `LIVE` part is never Completed on simulation alone; the simulated part is recorded separately.

Last updated: 2026-11-18 (all phases built and verified in simulation; conductor reran every gate in both repos at their final heads — driver `1a99e24`, platform `4e86ca3c6`; final report written; nothing pushed, published or applied to a remote database).

---

## Phase 1 — Repository analysis and architecture verification

| # | Task | Status | Evidence |
| --- | --- | --- | --- |
| 1.1 | Platform core analysis (architecture, tenants, AI, vault, licensing, gates) | Completed | `analysis/01-platform-core.md`; claims spot-checked against source |
| 1.2 | System Studio, ingestion, Flight Recorder web side, Programming Agent | Completed | `analysis/02-system-studio-ingestion.md`; spot-checked |
| 1.3 | Driver monorepo analysis (Agent, Flight Recorder, module contract v1, build, tests) | Completed | `analysis/03-driver-repo.md`; spot-checked; suite 9,287 checks green |
| 1.4 | DriverWorks SDK verification against official docs | Completed | `analysis/04-driverworks-sdk.md`; local precedents spot-checked. Web-doc claims not independently re-fetched by the conductor |
| 1.5 | OpenAI + Anthropic API requirements; concierge legitimacy check | Completed | `analysis/05-ai-and-concierge-apis.md`; local claims spot-checked. Model ids/prices rest on the analyst's doc fetch of 2026-11-18 |
| 1.6 | Architecture and wire contract | Completed | `ARCHITECTURE.md` |
| 1.7 | Dedicated worktrees off `origin/main` in both repos | Completed | `feat/ai-core`, `codex/ai-core` |

## Phase 2 — Driver communication protocol and Agent integration

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 2.1 | Protocol v2 spec document (frames, policy, errors, retry, limits) | — | Completed — `docs/protocol/MODULE-CONTRACT-V2.md` in the driver repo |
| 2.2 | Agent: v2 negotiation, manifest storage, stronger tokens, sender stamping | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.3 | Agent: discovery (`DISCOVER` / `DIRECTORY` / `DIRECTORY_CHANGED`) | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.4 | Agent: pub/sub with topic policy, bounded buffers, drop counters | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.5 | Agent: request/response routing with policy, idempotency ring, deadlines | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.6 | Agent: cloud relay with closed op vocabulary | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.7 | Agent: per-module rate limits; bus counters in status/heartbeat | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.8 | Module client library: v2 API (discover, subscribe, request, respond, cloudRequest, retry) | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.9 | v1 backward compatibility proven (existing modules unchanged, suite green) | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.10 | Director-emulator scenario: Agent + two v2 modules, restart, absent target | SIM | Completed — conductor reran `make test` (137 files, 9,516 ok, 0 failed), lint 0/0, emulator 23/23 |
| 2.11 | Platform: `ai_core` module registration (prefix, operations, labels) | SIM | Completed — cross-repo parity test passes 22/22 against the AI Core driver worktree (conductor reran) |
| 2.12 | Platform: `/api/integrations/control4/modules/rpc` (auth, closed ops, idempotency) | SIM | Completed — business outcomes are HTTP 200 `{ok}`; 401 bad token; 5xx outage; conductor reran RPC tests |
| 2.13 | Platform: foundation migration (`ai_core_*` tables, RLS, grants, rollback) | SIM | Completed — 20 `ai_core_*` tables across 8 migrations; grants explicit (no reliance on default privileges); conductor read the foundation migration; all-migrations run under strict and default privileges is worker-reported |
| 2.14 | Platform: `control4_commands` AI provenance columns | SIM | Tested — `origin`, `ai_action_id`, `reason`; FK to actions table deferred to Phase 7 |
| 2.15 | Platform: `driver_catalog` SKU `SBOS_AI_CORE` + feature emission in refresh route | SIM | Completed — licensed only by an explicit entitlement (not plan-included) until the owner decides pricing; conductor reran the suite |
| 2.16 | Migrations exercised on a local database built from baseline + new files | SIM | Completed — all AI Core migrations applied in order, rolled back in reverse and re-applied on a local Postgres with 6 QA scripts (worker-reported; procedure in `docs/ai-core/MIGRATIONS.md`) |
| 2.17 | Protocol v2 measured on a real controller (frame sizes, ordering, restart) | HW | Blocked — no controller in this environment |

## Phase 3 — Control4 driver and event collection

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 3.1 | Driver scaffold: `driver.xml`, `<script>`, packaging, store filename tables | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.2 | Registration as `ai_core` (v2), degrade on v1-only Agent / no Agent | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.3 | Composer properties (brief §11) incl. read-only credential status | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.4 | Composer commands `AI_*` (10) with typed params | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.5 | Composer events (10) and variables | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.6 | System-event collection (documented ids; guarded extras) | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.7 | Device-state collection without double capture; exclusions honoured | SIM | Completed (simulation) — no double capture; exclusions honoured; configuration contract tested with golden documents in both repos and through the emulator |
| 3.8 | Offline priority buffer with counted drops; recovery on reconnect | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.9 | Restricted operations (`apply_config`, `deliver_result`, `raise_event`, …) | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.10 | Health and status reporting | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.11 | Licence states, grace, feature entitlements | SIM | Completed (simulation) — licensing end to end in emulator with real HMAC and a virtual clock; conductor reran suite (155 files, 10,445 ok) and emulator 105/105 |
| 3.12 | Driver loads and runs in Composer on a real controller | HW | Blocked — no controller |

## Phase 4 — Flight Recorder integration and historical intelligence

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 4.1 | Flight Recorder driver: v2 manifest + local ring queries served over the bus | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 4.2 | AI Core driver: discover Flight Recorder; subscribe; degrade when absent | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 4.3 | Cloud tools: `search_events`, `get_timeline`, `get_device_history`, `get_room_activity` | SIM | Completed — conductor reran 171 tools/authz/evidence tests; fakes only, no real database |
| 4.4 | Cloud tools: `correlate_events`, `analyze_incident`, `compare_periods` | SIM | Completed — conductor reran 171 tools/authz/evidence tests; fakes only, no real database |
| 4.5 | Missing-data handling: gaps surfaced, never filled in | SIM | Completed — conductor reran 171 tools/authz/evidence tests; fakes only, no real database |
| 4.6 | Evidence post-check (citations must come from this turn's tool results) | SIM | Completed — conductor reran 171 tools/authz/evidence tests; fakes only, no real database |
| 4.7 | Flight Recorder retention scheduling (currently commented out) | SIM | Blocked — owner decision: enabling retention deletes Flight Recorder events older than 30 days once applied |

## Phase 5 — AI provider integration and structured tool calling

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 5.1 | Neutral types + provider error taxonomy | SIM | Completed — conductor reran 103 provider tests; no env key reads, `store:false`, no temperature. Mocked HTTP only |
| 5.2 | Anthropic adapter (Messages, tools, effort, caching, usage) | SIM | Completed — conductor reran 103 provider tests; no env key reads, `store:false`, no temperature. Mocked HTTP only |
| 5.3 | OpenAI adapter (Responses API, `store:false`, strict tools, usage) | SIM | Completed — conductor reran 103 provider tests; no env key reads, `store:false`, no temperature. Mocked HTTP only |
| 5.4 | Per-provider schema compiler + our own argument re-validation | SIM | Completed — conductor reran 103 provider tests; no env key reads, `store:false`, no temperature. Mocked HTTP only |
| 5.5 | Timeout, retry, fallback provider | SIM | Completed — conductor reran 103 provider tests; no env key reads, `store:false`, no temperature. Mocked HTTP only |
| 5.6 | Versioned price table + cost accounting | SIM | Completed — conductor reran 103 provider tests; no env key reads, `store:false`, no temperature. Mocked HTTP only |
| 5.7 | Credential vault (encrypted, masked) + connectivity test | SIM | Completed — conductor reran 41 vault/settings/budget/audit tests; migration run on local Postgres is worker-reported |
| 5.8 | Settings: provider, model classes, effort, limits, timeout, retry, fallback | SIM | Completed — conductor reran 41 vault/settings/budget/audit tests; migration run on local Postgres is worker-reported |
| 5.9 | Blocking spend and rate limits in the database | SIM | Completed — conductor reran 41 vault/settings/budget/audit tests; migration run on local Postgres is worker-reported |
| 5.10 | Orchestrator loop with untrusted-content isolation | SIM | Completed — conductor reran the full suite (12,513 pass); injection fixtures pass; a tool declares its audience and a staff-only tool is never offered to or run for a homeowner or controller (authz-enforced, ratchet-tested). No live model call (5.11/5.12) |
| 5.11 | Real call against Anthropic | LIVE | Blocked — needs an API key |
| 5.12 | Real call against OpenAI | LIVE | Blocked — needs an API key |

## Phase 6 — Household learning and recommendation engine

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 6.1 | Memory store: four categories, verified vs inferred, confidence, evidence | SIM | Completed — conductor reran 60 learning tests; detectors pure; migration run on local Postgres is worker-reported |
| 6.2 | Homeowner controls: review, correct, delete, pause, exclusions, export, erase | SIM | Completed — homeowner controls incl. pending proposals; pause is sent to the controller at once; erase keeps the integrator's hand-off records |
| 6.3 | Detectors: routines, scene override, thermostat override | SIM | Completed — conductor reran 60 learning tests; detectors pure; migration run on local Postgres is worker-reported |
| 6.4 | Detectors: automation conflict, recurring failures, rarely used scenes | SIM | Completed (as far as data allows) — conflict + recurring-failure detectors tested; "rarely used scenes" answers `insufficient_context` (no scene inventory, needs 90 days) |
| 6.5 | Recommendations lifecycle with evidence, confidence, impact, approval need | SIM | Completed — incl. two-party approval for `homeowner_and_integrator` (no detector emits that requirement yet, so it appears only in fixtures) |
| 6.6 | No identity inference from device activity (guard + test) | SIM | Completed — conductor reran 60 learning tests; detectors pure; migration run on local Postgres is worker-reported |
| 6.7 | Scheduled analysis job | SIM | Tested — `analyze_property` job runs on demand only; scheduling is an owner decision (no cron entry added) |

## Phase 7 — Safe Control4 action execution

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 7.1 | Permission engine (modes × risk classes) as pure, table-tested functions | SIM | Completed — conductor reran 1,139 action/rule/programming/authz tests; migration run on local Postgres is worker-reported |
| 7.2 | Action lifecycle: propose → approve → queue → result; expiry; idempotency; replay refusal | SIM | Completed — conductor reran 1,139 action/rule/programming/authz tests; migration run on local Postgres is worker-reported |
| 7.3 | Protected classes always need explicit homeowner approval | SIM | Completed — conductor reran 1,139 action/rule/programming/authz tests; migration run on local Postgres is worker-reported |
| 7.4 | Pre-approved low-risk rules (verb + scope + bounds) | SIM | Completed — conductor reran 1,139 action/rule/programming/authz tests; migration run on local Postgres is worker-reported |
| 7.5 | Cross-property and cross-tenant isolation tests | SIM | Completed — conductor reran 1,139 action/rule/programming/authz tests; migration run on local Postgres is worker-reported |
| 7.6 | Prompt-injection tests (hostile device names, titles, calendar text) | SIM | Completed — conductor reran 1,139 action/rule/programming/authz tests; migration run on local Postgres is worker-reported |
| 7.7 | Audit trail for every tool call and decision | SIM | Completed — conductor reran 1,139 action/rule/programming/authz tests; migration run on local Postgres is worker-reported |
| 7.8 | Programming-change hand-off to a human-accepted blueprint revision | SIM | Completed (as far as Composer Studio allows) — structured hand-off record a person carries into Composer Studio; no automatic "accept into blueprint" because project drafts have no programming field |
| 7.9 | An approved action physically changes a device | HW | Blocked — no controller |

## Phase 8 — System Studio AI Intelligence

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 8.1 | Navigation registry, permissions, bootstrap capability | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 33 tests and reviewed screenshots |
| 8.2 | AI Overview | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 33 tests and reviewed screenshots |
| 8.3 | Household Usage (measured occupancy kept apart from interaction counts) | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 33 tests and reviewed screenshots |
| 8.4 | Flight Recorder Intelligence | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 33 tests and reviewed screenshots |
| 8.5 | AI Recommendations | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 55 Studio tests and reviewed screenshots. Real model answers not shown live (no provider key) |
| 8.6 | AI Service Intelligence (incl. service-ticket draft) | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 55 Studio tests and reviewed screenshots. Real model answers not shown live (no provider key) |
| 8.7 | AI Conversations (streaming, role-gated) | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 55 Studio tests and reviewed screenshots. Real model answers not shown live (no provider key) |
| 8.8 | Provider + credential setup UI | SIM | Completed — browser-verified in fixture mode and against a local stack; conductor reran 33 tests and reviewed screenshots |
| 8.9 | Browser verification of every page in fixture mode | SIM | Completed — all six pages plus setup, approvals, rules and hand-off screens exercised in a browser (60 + 118 screenshots); one screenshot captured a loading state instead of its answer |
| 8.10 | Owner sign-off on a ninth top-level Studio destination | — | Blocked — owner decision (built as specified in the brief; reversible) |

## Phase 9 — Homeowner concierge

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 9.1 | Reservation provider interface + booking state machine | SIM | Completed — state machine + registry; the missing function grant that broke every transition in a real database is fixed and covered by a behavioural QA script acting as the application role (database run worker-reported) |
| 9.2 | Sandbox provider, labelled as simulation everywhere | SIM | Completed — conductor reran 56 concierge tests; DB allows only the sandbox provider; no vendor adapter code exists |
| 9.3 | Calendar adapters (Google, Microsoft) with homeowner OAuth | SIM | Tested — Google Calendar + Microsoft Graph adapters and homeowner OAuth against documented wire fixtures; live use blocked on OAuth client credentials (9.7) |
| 9.4 | Portal: concierge conversation, approvals, learned-preference review | SIM | Completed — homeowner portal screens browser-verified at 360/768/1280 in fixture mode and against a local stack (158 screenshots); conductor reran 23 tests and reviewed screenshots. Dark mode not screenshotted; erase not executed live |
| 9.5 | Failed-booking recovery; never "confirmed" without provider confirmation | SIM | Completed — conductor reran 56 concierge tests; DB allows only the sandbox provider; no vendor adapter code exists |
| 9.6 | Real restaurant booking | LIVE | Blocked — vendor partner agreements (OpenTable, Yelp, SevenRooms); Resy/Tock have no sanctioned API |
| 9.7 | Real calendar read/write | LIVE | Blocked — OAuth client credentials |

## Phase 10 — Licensing, testing, documentation, packaging

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 10.1 | Licence activation, controller binding, grace, renewal, transfer, updates end to end | SIM | Completed (simulation) — see 3.11. Gaps vs brief: no driver-side transfer workflow (platform staff action); platform never issues CONTROLLER_MISMATCH for AI Core; tampered assertion falls back per existing policy |
| 10.2 | Full test matrix of brief §15 mapped to named tests | SIM | Completed — driver matrix (driver repo) + cloud matrix (platform repo, 148 quoted test names verified) + committed browser smoke spec `npm run test:e2e:ai-core` (conductor ran it: 12/12) |
| 10.3 | `SmartBuildOS_AI_Core_Interactive_Guide.html` — 14 chapters, 10 interactive features | SIM | Completed — refreshed to the final code (platform `4e86ca3c6`); conductor reran consistency test (794 assertions, 0 failures) and browser test (798 controls, 2,352,443 assertions, 0 failures, 0 network requests) and reviewed screenshots. Prose not checked line by line; embedded product shots not recaptured after the last UI changes |
| 10.4 | Every guide control exercised in a browser | SIM | Completed — see 10.3; the test harness bounds every step and has a whole-run watchdog after an earlier run hung on lazy-loaded images |
| 10.5 | Developer API documentation | — | Completed — `DEVELOPER-API.md`, `OPERATIONS.md`, `README.md`, `DRIVER-CONTRACT.md`, `MIGRATIONS.md` synced to platform commit 0481f3f98; cross-checked by script by the worker, not line-by-line by the conductor |
| 10.6 | Installation documentation | — | Completed — `docs/ai-core/INSTALLATION.md` (driver repo) |
| 10.7 | Release and deployment instructions | — | Completed — `docs/ai-core/RELEASE.md` (driver repo) and `docs/ai-core/MIGRATIONS.md` (platform repo) |
| 10.8 | `.c4z` built and packaged from the worktree | SIM | Completed (simulation) — `dist/oss/smartbuildos-ai-core.c4z`, version 20261118.091052, 92,634 bytes, packaging test green |
| 10.9 | Final implementation report | — | Completed — `FINAL_IMPLEMENTATION_REPORT.md` |
| 10.10 | Branches pushed / PRs opened | — | Blocked — owner go-ahead |
| 10.11 | Migrations applied to production | — | Blocked — owner review and apply |
| 10.12 | Store publication | — | Blocked — owner go-ahead |

---

## Open owner decisions (none block current work)

0. Decided by the architect, reversible: AI Core events count as household activity; learning is off by default.

1. Ninth top-level Studio destination "Intelligence" versus nesting under existing ones (8.10).
2. Catalog price and plan inclusion for `SBOS_AI_CORE` and its feature tiers.
3. Whether to offer a one-click import of existing plaintext company AI keys into the encrypted AI Core vault.
4. Enabling Flight Recorder retention (deletes events older than 30 days once applied).
5. Store category for AI Core (currently `Utility`).
6. Default daily request limit (500) and burst (20/min/property); UTC vs property-local budget month; whether existing usage rollups should exclude unknown-cost rows.
7. Who schedules the household analysis job; thresholds for detectors with no row in the existing §N rules; whether a dismissed recommendation may be raised again; whether the subscription grants `AI_LEARNING` (today only an explicit licence row does).
8. (Resolved — the homeowner approval screen and two-party approval are built.)
9. Whether AI Core notices may also go out by email; high-risk actions currently need two homeowner confirmations (AI Core's, then the command queue's own); action limits (30-minute approval window; 6 proposals/min, 40/hour, 10 open per property).
10. Composer Studio has no per-project programming field, so an AI programming recommendation cannot be accepted into a blueprint automatically.
11. Licensing policy: a tampered licence assertion is dropped and the driver keeps running (existing behaviour for every SmartBuildOS driver).
12. Pre-existing release gaps: the store-publish workflow has no mapping for the Flight Recorder; `release.yml` fires only on `v*` tags; the Agent main chunk is at 198 of Lua's 200 top-level locals.
13. Whether `SBOS_AI_CORE` is included in a subscription plan (the catalog row currently says Professional-included, which appears to license every property on that plan) or sold only by explicit licence.
14. Staff route scope: actions, rules, programming, credentials, settings, usage, overview, household-usage, flight-recorder, memories, patterns, recommendations and service scope technicians by company only (the platform's existing convention); conversations, jobs and concierge also check property visibility. Tighten all, or leave.
15. Erase semantics: "erase everything learned" deletes every recommendation including approved ones; deleting a single memory keeps approved/implementing/implemented ones.

# SmartBuildOS AI Core — Implementation Checklist

Maintained by the conductor only. Architecture: `ARCHITECTURE.md` (same folder). Analysis: `analysis/01`–`05`.

**Status vocabulary:** Not started · In progress · Implemented (code written) · Tested (an automated test that fails without it passes) · Completed (tested AND verified by the conductor against the repo) · Blocked (reason given).

**Verification classes:** `SIM` = automated, simulated/emulated/mocked. `HW` = needs a physical Control4 controller. `LIVE` = needs a real external credential or vendor grant. An item with an `HW` or `LIVE` part is never Completed on simulation alone; the simulated part is recorded separately.

Last updated: 2026-11-19, round two (Phase 13 and decisions 26–30, from `SPEC-round2-live-answers.md` §9 and the conductor's round-two reruns); phases 1–12 unchanged since the 2026-11-18 close-out (final numbers from the conductor's rerun at the final heads; decisions from the conductor's facts file `STATUS-2026-11-18-evening.md` and `SPEC-webview-and-driver-reporting.md` §8, same folder).

- **Pull requests (open, not merged):** driver `michelo76/control4-smartbuildos#49` (`feat/ai-core`), platform `michelo76/smartbuildos#435` (`codex/ai-core`), opened 2026-11-18 with the owner's go-ahead. Commits after the first push are local until the conductor pushes them.
- **Nothing applied to any remote database. Nothing published to the Driver Store. Simulation only:** nothing has run on a physical Control4 controller or Navigator, and no live AI provider, calendar, places or booking call has been made. No `.c4z` has been built for the changed drivers.
- **Final gate totals, rerun by the conductor on 2026-11-18 at the final heads** (driver `26a3d44` on `feat/ai-core`, plus documents-only commits after it; platform `2ebbd5bd2` on `codex/ai-core`):
  - Platform: unit tests 12,632 of 12,632 (0 skipped), run with the driver repo so the cross-repo comparisons are included; typecheck 0 errors; lint 0 errors and 1,432 warnings that predate this work; browser tests (`npm run test:e2e:ai-core`) 22 of 22.
  - Driver, run with the platform repo: 192 test files, 13,350 checks, 0 failed; lint 0 warnings and 0 errors in 429 files; Director-emulator runs through the real Agent: AI Core 126 of 126, driver reporting 47 of 47, reference drivers 39 of 39, touchscreen webview with the real PIN Lock 34 of 34, module contract 24 of 24.
  - Interactive guide (at `26a3d44`): consistency test 946 assertions, passing; browser test 831 controls exercised, 2,435,469 assertions, 0 failures, 0 network requests.
  - Not rerun by the conductor (worker- or reviewer-reported): the local-Postgres apply / QA / rollback runs of the migrations; the defect-reintroduction proofs; the offline packaging check's per-driver results beyond its inclusion in the 192 files; source-size growth figures.

- **Round two (Phase 13) lives on separate branches that are NOT pushed:** driver `feat/ai-core-round2` (stacked on `09d138b`) and platform `codex/ai-core-round2` (stacked on `e30367901`). The two pull requests above are FROZEN at those heads for the owner to apply and deploy; **they do not contain round two.** Round two is simulation only, like everything else: nothing has run on a physical controller or touchscreen, no live AI provider call, no `.c4z` built, nothing published, no migration applied to any database other than throwaway local ones.
- **Round-two gate totals rerun by the conductor on snapshots (2026-11-19):** driver at `64660fb` (live read): 194 test files, 0 failed; lint 0/0; emulator runs 132, 47, 39, 34, 24, all passing. Driver at `1a663b1` (filter fixes and presets): 194 files, 0 failed; lint 0/0; emulator 132, 47, 39, 37, 24. Platform at `e68167946` (wire, handler, round-two migration): unit 12,710 of 12,710; typecheck 0 errors; lint 0 errors and 1,432 pre-existing warnings; browser tests 22 of 22; the twelve frozen migration files confirmed unchanged. Final totals at the round-two heads (the platform's tools-and-presets head and the driver's last head): ⟨conductor: round-two final totals⟩.

Phases 1–10 were built and verified in simulation earlier on 2026-11-18 (conductor reran every gate at driver `1a99e24`, platform `4e86ca3c6`; the totals quoted in rows below are from that run unless a row says otherwise). Phases 11 and 12 were added after the first push; the conductor reran each driver brief's gates on a snapshot as it landed and the platform's gates at each platform brief, and every row below is covered by the final rerun above.

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
| 2.13 | Platform: foundation migration (`ai_core_*` tables, RLS, grants, rollback) | SIM | Completed — 20 `ai_core_*` tables across the original 8 migrations; grants explicit (no reliance on default privileges); conductor read the foundation migration; all-migrations run under strict and default privileges is worker-reported. Three later files (retention, touchscreen, driver reports) are tracked in 10.14 |
| 2.14 | Platform: `control4_commands` AI provenance columns | SIM | Tested — `origin`, `ai_action_id`, `reason`; FK to actions table deferred to Phase 7 |
| 2.15 | Platform: `driver_catalog` SKU `SBOS_AI_CORE` + feature emission in refresh route | SIM | Completed — catalog row and feature emission; conductor reran the suite. Price and purchase rules decided on 2026-11-18 are tracked in 10.13; no plan includes AI Core (plan inclusion still open, decision 13) |
| 2.16 | Migrations exercised on a local database built from baseline + new files | SIM | Tested — all AI Core migrations applied in order, rolled back in reverse and re-applied on a local Postgres with 6 QA scripts (worker-reported; procedure in `docs/ai-core/MIGRATIONS.md`); all twelve files again by the independent reviewer in two passes (reviewer-reported, 10.14). Not rerun by the conductor |
| 2.17 | Protocol v2 measured on a real controller (frame sizes, ordering, restart) | HW | Blocked — no controller in this environment |

## Phase 3 — Control4 driver and event collection

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 3.1 | Driver scaffold: `driver.xml`, `<script>`, packaging, store filename tables | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.2 | Registration as `ai_core` (v2), degrade on v1-only Agent / no Agent | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.3 | Composer properties (brief §11) incl. read-only credential status | SIM | Completed (simulation) — conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77; `.c4z` built |
| 3.4 | Composer commands `AI_*` (11) with typed params | SIM | Completed (simulation) — the first 10: conductor reran `make test` (149 files, 10,175 ok, 0 failed), lint 0/0, emulator 77/77. The 11th, `AI_RUN_HOUSEHOLD_ANALYSIS` (op `analyze_household`), added after the first push: conductor reran the driver gates on a snapshot. No `.c4z` built since (10.8) |
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
| 4.7 | Flight Recorder retention scheduling | SIM | Tested — owner decided 2026-11-18 to enable it; scheduled nightly by migration `20261118200000_flight_recorder_retention_schedule.sql` (with rollback). The independent reviewer saw pg_cron fire the job on a local database and delete exactly what the pre-flight script predicted (reviewer-reported, not rerun by the conductor). Not applied to any remote database (10.11). The first run deletes the whole backlog past the windows in one pass (30 days events, 90 days traces) |

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
| 6.7 | Scheduled household analysis | SIM | Completed — owner decided 2026-11-18: a per-property schedule the dealer sets (off by default; daily or weekly, property-local time; hourly cron route `/api/cron/ai-core-analysis`) and the Composer command *Run Household Analysis* (`AI_RUN_HOUSEHOLD_ANALYSIS`, op `analyze_household`); one entry point and gate chain (`patterns/entry.ts`). Platform unit tests (`ai-core-household-schedule.test.mjs`) and the Studio schedule browser test, in the conductor's final rerun (12,632 unit, 22 browser); driver side in the conductor's final driver rerun. Schedule columns not applied to any remote database |

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
| 8.10 | Owner sign-off on a ninth top-level Studio destination | — | Completed — owner decided 2026-11-18: "Intelligence" stays a ninth top-level Studio destination |

## Phase 9 — Homeowner concierge

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 9.1 | Reservation provider interface + booking state machine | SIM | Completed — state machine + registry; the missing function grant that broke every transition in a real database is fixed and covered by a behavioural QA script acting as the application role (database run worker-reported) |
| 9.2 | Sandbox provider, labelled as simulation everywhere | SIM | Completed — conductor reran 56 concierge tests; DB allows only the sandbox provider; no vendor adapter code exists |
| 9.3 | Calendar adapters (Google, Microsoft) with homeowner OAuth | SIM | Completed (simulation) — Google Calendar + Microsoft Graph adapters and homeowner OAuth against wire fixtures written from vendor documentation; platform unit tests in the conductor's final rerun (12,632). Live use blocked on OAuth client credentials (9.7) |
| 9.4 | Portal: concierge conversation, approvals, learned-preference review | SIM | Completed — homeowner portal screens browser-verified at 360/768/1280 in fixture mode and against a local stack (158 screenshots); conductor reran 23 tests and reviewed screenshots. Dark mode not screenshotted; erase not executed live |
| 9.5 | Failed-booking recovery; never "confirmed" without provider confirmation | SIM | Completed — conductor reran 56 concierge tests; DB allows only the sandbox provider; no vendor adapter code exists |
| 9.6 | Real restaurant booking | LIVE | Blocked — vendor partner agreements (OpenTable, Yelp, SevenRooms); Resy/Tock have no sanctioned API |
| 9.7 | Real calendar read/write | LIVE | Blocked — OAuth client credentials |

## Phase 10 — Licensing, testing, documentation, packaging

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 10.1 | Licence activation, controller binding, grace, renewal, transfer, updates end to end | SIM | Completed (simulation) — see 3.11. Gaps vs brief: no driver-side transfer workflow (platform staff action); platform never issues CONTROLLER_MISMATCH for AI Core; tampered assertion falls back per existing policy |
| 10.2 | Full test matrix of brief §15 mapped to named tests | SIM | Completed — driver matrix (driver repo) + cloud matrix (platform repo, 148 quoted test names verified) + committed browser spec `npm run test:e2e:ai-core` (conductor's final rerun: 22 of 22) |
| 10.3 | `SmartBuildOS_AI_Core_Interactive_Guide.html` — 14 chapters, 10 interactive features | SIM | Completed — rebuilt for Phases 11–12 and the decisions of 2026-11-18; conductor rerun at driver `26a3d44`: consistency test 946 assertions, passing. Refreshed once more in the close-out (final statuses and numbers only); see 10.4 for the rerun after that |
| 10.4 | Every guide control exercised in a browser | SIM | Completed — conductor rerun at driver `26a3d44`: 831 controls exercised, 2,435,469 assertions, 0 failures, 0 network requests. After the close-out refresh (statuses and final numbers only) the documents worker reran both guide tests: consistency 994 assertions, 0 failures; browser 835 controls exercised, 2,435,473 assertions, 0 failures, 0 network requests (worker-reported, not rerun by the conductor; the first two attempts timed out in the browser test while the machine's load average was above 500, the third, at normal load, passed) |
| 10.5 | Developer API documentation | — | Completed — `DEVELOPER-API.md`, `OPERATIONS.md`, `README.md`, `DRIVER-CONTRACT.md`, `MIGRATIONS.md` synced to platform commit 0481f3f98; cross-checked by script by the worker, not line-by-line by the conductor |
| 10.6 | Installation documentation | — | Completed — `docs/ai-core/INSTALLATION.md` (driver repo) |
| 10.7 | Release and deployment instructions | — | Completed — `docs/ai-core/RELEASE.md` (driver repo) and `docs/ai-core/MIGRATIONS.md` (platform repo) |
| 10.8 | `.c4z` built and packaged from the worktree | SIM | Blocked — the only build, `smartbuildos-ai-core.c4z` 20261118.091052 (92,634 bytes), predates Phases 11–12; no `.c4z` has been built for any changed driver because this worktree has no packager. Offline substitute: 12.8 |
| 10.9 | Final implementation report | — | Completed — `FINAL_IMPLEMENTATION_REPORT.md` with the conductor's final totals; the one migration item still open is tracked in 10.14 |
| 10.10 | Branches pushed / PRs opened | — | Completed — pushed and opened 2026-11-18 with the owner's go-ahead: driver `michelo76/control4-smartbuildos#49`, platform `michelo76/smartbuildos#435`; not merged |
| 10.11 | Migrations applied to production | — | Blocked — owner review and apply (no migration applied to any remote database) |
| 10.12 | Store publication | — | Blocked — owner go-ahead (nothing published) |
| 10.13 | Price and purchase: $150 dealer (one-time, per controller), $250 MSRP; public surfaces show only the MSRP; a purchase grants BASE, AI_LEARNING, AI_ACTIONS (never AI_CONCIERGE); not buyable until a release is published | SIM | Completed — platform unit tests in the conductor's final rerun (12,632). The price itself is set by the twelfth migration, `20261118220000`, applied only after the new app is deployed (10.14); not applied anywhere |
| 10.14 | The AI Core migrations: twelve files `20261118120010`, `120100`, `140000`, `150000`, `160000`, `170000`, `180000`, `190000`, `200000`, `210000`, `211000` and `20261118220000` (the price, applied only after the new app is deployed), each with a rollback, each a single transaction with a 5-second lock limit, order enforced both ways | SIM | Tested — reviewer-reported, not rerun by the conductor: an independent reviewer (a separate worker that wrote none of it) ran two passes on a local database; second-pass verdict on platform `2ebbd5bd2`: "ready with conditions", every first-pass finding closed, one new medium finding (on Supabase, creating a policy takes a lock on the sign-in and Storage tables until the file commits; the fix moves policies to the end of each file). Update: that fix has landed (platform `0a128d748`: the policies are now the last statements of each file) and the same reviewer ran a third pass on it — final verdict: ready to apply by hand with the conditions in its runbook; every finding closed, accepted or documented; nothing new found. Reviewer-reported, not rerun by the conductor. Conditions for applying: files 1–11, deploy the app, then file 12; run `PREFLIGHT.sql` first; back up Flight Recorder history before file 9; a quiet window; record versions under their file stamps (`migrations-review/REVIEW.md`, `APPLY-ORDER.md`). Applied to no remote database (10.11) |

## Phase 11 — AI Core touchscreen webview and PIN (added after the first push)

Driver rows marked "conductor reran" were verified by the conductor rerunning the driver gates (`make test`, lint, the AI Core and module-contract emulator runs, the new webview scenario) on a snapshot. Platform rows rest on the platform unit and browser suites, which the conductor reran at the final heads (12,632 of 12,632 unit tests; 22 of 22 browser tests); any part that exists only in the database was exercised only on local Postgres (worker- or reviewer-reported, 10.14).

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 11.1 | PIN Lock serves AI Core: `pinlock.availability` / `pinlock.challenge` / `pinlock.redeem`, the `/verify` relay route, owner codes only (guest and vendor always refused), one lockout shared with PIN Lock's page, properties `AI Core Approvals` and `AI Core PIN Verification`; no code name and no slot leave PIN Lock | SIM | Completed (simulation) — conductor reran; PIN Lock suites and the webview emulator scenario with the real PIN Lock (34 checks) |
| 11.2 | AI Core touchscreen page (`src/aicore/webui.lua`, `www/app/index.html`, LAN relay on port 47871): status without a PIN; text rendered with `textContent` only; works only on the home network | SIM | Completed (simulation) — conductor reran; `test_aicore_webui`, webview emulator scenario (34) |
| 11.3 | Chat locked behind an owner PIN (owner decision 8): no conversation bytes on any route while locked, 5-minute idle relock, lock on page close or driver restart, fail closed when PIN Lock is absent, unverified, unlicensed, without an owner PIN or stale | SIM | Completed (simulation) — conductor reran; `test_aicore_webui` [7] asserts on response bodies; webview emulator scenario (34) |
| 11.4 | PIN approvals at the touchscreen (owner decision 7): one PIN entry per approval item, a single-use proof for that one item, no PIN ever enters AI Core or a bus frame; a chat unlock never approves and an approval PIN never unlocks the chat | SIM | Completed (simulation) — conductor reran; `test_aicore_webui`, webview emulator scenario (34) |
| 11.5 | Platform approval ops `approvals_pending` / `approval_detail` / `approval_decide`; approver kind `touchscreen_pin`; ceiling low + medium in code and by a database CHECK; single-use nonce; freshness window [now − 120 s, now + 60 s]; 30 details and 10 decisions per hour per property; locks, garage and security portal-only | SIM | Completed — platform unit tests in the conductor's final rerun (12,632); the database CHECK on the ceiling ran only on local Postgres (worker/reviewer-reported) |
| 11.6 | Homeowner switches in the portal, per property, default off: touchscreen approvals (staff can only switch it off) and touchscreen answers using household activity | SIM | Completed — platform unit tests and the portal and Studio touchscreen browser tests in the conductor's final rerun (12,632 unit, 22 browser) |
| 11.7 | Homeowner notice on every touchscreen approve and decline; the cloud records "approved at the touchscreen with an owner PIN" and nothing that identifies the code | SIM | Completed — platform unit tests and browser tests ("with an owner PIN", never a name) in the conductor's final rerun |
| 11.8 | `ask` channel `touchscreen` with `detail`; household data only when the homeowner allowed it | SIM | Completed — platform unit tests in the conductor's final rerun; driver side conductor reran |
| 11.9 | Risk class `medium`: never auto-executed; no pre-approved rule can match it | SIM | Completed — platform engine tests in the conductor's final rerun; the database CHECK ran only on local Postgres (worker/reviewer-reported) |
| 11.10 | The page opens as a tile in Navigator on a touchscreen and the phone app | HW | Blocked — no controller or Navigator |
| 11.11 | The PIN posted from AI Core's page (port 47871) to PIN Lock's relay (port 47831) in Navigator's browser (cross-port) | HW | Blocked — no controller or Navigator |
| 11.12 | Navigator delivers page-close events (`pagehide`, `visibilitychange`) so the chat locks when the tile closes | HW | Blocked — no controller or Navigator |

## Phase 12 — Driver reporting to AI Core (added after the first push)

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 12.1 | Module bus foundations: wildcard requester (`ANY`, mirrored as `"*"`), identity binding for reserved module ids with `verified` in directory and heartbeat rows, registry cap 48, Remote Control tier Comfort for `invoke_driver_action` (`driver_actions_v1`), debug suppression for module frames, per-sender de-duplication (module RPC and the Agent's idempotency ring) | SIM | Completed (simulation) — conductor reran; `test_agent_modules_v2` [10]–[12], module-contract emulator run (24) |
| 12.2 | Shared helper `src/sbos/aireport.lua` (report kinds describe / state / event / diagnostic, declared read-only queries, declared actions, the `AI Core` property) and the one value list `src/sbos/aivalues.lua` | SIM | Completed (simulation) — conductor reran; `test_sbos_aireport`, `test_sbos_aivalues` |
| 12.3 | Passive module `src/sbos/aipresence.lua` for child drivers (requires neither the helper nor the module client); `src/sbos/agentaicore.lua` for the Agent (no new top-level local: 198 of 200) | SIM | Completed (simulation) — conductor reran; `test_sbos_aipresence`, `test_agent_modules_v2` [13] |
| 12.4 | The Agent's two own values: `Found — registered (v…)` (live, verified) and `Found — not verified (v…)` (live, unverified); list now 15 values | SIM | Completed (simulation) — `test_sbos_aivalues`, `test_agent_modules_v2` [13], in the conductor's final driver rerun (13,350 checks). The proof by making the unverified case show the verified value (two checks fail) is worker-reported |
| 12.5 | AI Core report hub (`src/aicore/reports.lua`): receives reports from any module, batches them to the cloud (`driver_reports`), relays `run_driver_query` and `invoke_driver_action`, reports real outcomes (`driver_query_result`; `driver_action_result` with `started` / `completed` / `failed`) | SIM | Completed (simulation) — conductor reran; reports emulator scenario through the real Agent (47 checks) |
| 12.6 | Reference drivers with hand-written reports: Atmosphere, Mode Composer (declares `activate_mode`, the only declared action in the repo), Flight Recorder | SIM | Completed (simulation) — conductor reran; reference-drivers emulator scenario (39 checks) |
| 12.7 | Rollout to 51 of 52 driver directories (AI Core itself is the exception): 20 root drivers report through the helper (VenueFlow only while Remote Management is on), 30 children show the property through the passive module, the Agent derives it from its own registry | SIM | Completed (simulation) — conductor reran; `test_driver_aicore_guard` (the repo-wide ratchet fails if any driver lacks it) |
| 12.8 | Packaging check without a packager: for every driver, the squish list from the Makefile's own steps (`preprocess.py --oss`, `gen-squishy.lua`, in a scratch folder) holds every module its preprocessed `driver.lua` can require, transitively; no child squishes `sbos.aireport` or `sbos.moduleclient` | SIM | Completed (simulation) — `test_driver_squish_closure` passes in the conductor's final driver rerun (one of the 192 files); its per-driver results (all 52 pass) and its proofs (a lazy require and a module-client require in a child both fail) are worker-reported. Not a `.c4z` build |
| 12.9 | Platform ingest and stores for `driver_reports`, `driver_query_result`, `driver_action_result`; 64 live drivers per system, 2,000 events a day per system, driver event log kept 30 days; `identity_verified` written only from the Agent's heartbeat row | SIM | Completed — platform unit tests in the conductor's final rerun (12,632); the stores exist only in migrations applied to no remote database |
| 12.10 | Three tools `drivers.list`, `drivers.run_query`, `drivers.propose_action` (registry 34 → 37) | SIM | Completed — platform tools tests in the conductor's final rerun; the guide's consistency test compares its 37 tools with the live registry |
| 12.11 | Driver-declared actions: never run on the model's say-so; at least `medium`; every action of a driver with a lock or security control is `high` (portal only); homeowner approval; Remote Control Comfort or above; unverified drivers refused; `started` is never shown as `completed` | SIM | Completed — platform unit tests in the conductor's final rerun; driver relay conductor reran |
| 12.12 | System Studio "Connected drivers" page (staff only) | SIM | Completed — platform unit tests and the Connected drivers browser test in the conductor's final rerun (22 of 22) |
| 12.13 | Platform wire mirror of the module bus; heartbeat reads `verified`; module cap 48 | SIM | Completed — platform unit tests in the conductor's final rerun, with the cross-repo comparisons against the driver repo |
| 12.14 | Identity binding against Director: `C4:GetDevicesByC4iName` answers in a form the Agent can compare with `instance_id` | HW | Blocked — no controller |
| 12.15 | System events 13 and 11 reach child drivers (the passive module relies on them) | HW | Blocked — no controller |
| 12.16 | Sizes at a full 48-module registry (Agent persist, heartbeat, directory) | HW | Blocked — no controller |
| 12.17 | Bus latency of a driver query against the platform's 15 s wait | HW | Blocked — no controller |
| 12.18 | A declared action (Mode Composer `activate_mode`) runs on a real controller and reports its outcome | HW | Blocked — no controller |
| 12.19 | A `.c4z` built for every changed driver and its size measured | SIM | Blocked — no packager in this worktree; squish input growth only (12.8) |
| 12.20 | New versions of all 52 drivers built and published | — | Blocked — owner decision (decision 22) and go-ahead |

## Phase 13 — Round two: live device answers, dealer presets, battery and sensor health (agreed by the owner 2026-11-18)

**On separate, unpushed branches** (driver `feat/ai-core-round2`, platform `codex/ai-core-round2`); the frozen pull requests #49 and #435 do not contain any of it. Specification and the conductor's rulings: `SPEC-round2-live-answers.md` §9 (same folder). "Conductor reran" rows rest on the round-two snapshot reruns in the header; "Tested" rows on worker-reported runs not yet rerun by the conductor.

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 13.1 | Live read on the controller: restricted operation `ai_core.read_device_state` (the Agent forwards it with no Remote Control tier, only to an AI Core that registers it) → one `C4:GetDeviceVariables` read → cloud op `device_state_result` (completed / failed with a closed reason); licence `BASE`, 12 a minute locally, never retried; read-only ratchets (no variable write, command, listener or code loader) | SIM | Completed (simulation) — conductor reran at driver `64660fb`: 194 test files, 0 failed; lint 0/0; emulator 132, 47, 39, 34, 24 (AI Core scenario [13h]: one live read end to end through the real Agent) |
| 13.2 | The filter and class rules on the controller: class from the live variable names (the Agent's own signature lists, a parity test against its source); cameras refused in every scope; locks, security, doors, motion, contacts, relays and lights refused at scope `system` before anything is sent; secret / personal / occupancy names and unsafe values dropped and counted; at `system` every class answered only through a reviewed allow-list (KI-68 closed), what an allow-list withheld counted `not_allowed` (KI-67 closed); 40 variables / 4,096 bytes | SIM | Completed (simulation) — conductor reran at driver `1a663b1`: 194 files, 0 failed; lint 0/0; emulator 132, 47, 39, 37, 24 |
| 13.3 | Platform operation, handler and screen: the pending read record, the enqueue of `MODULE_COMMAND ai_core.read_device_state`, the `device_state_result` handler, the platform's second screening of the answer (`state-policy.ts`), 6 a minute and 60 an hour per property | SIM | Completed — conductor reran at platform `e68167946`: unit 12,710 of 12,710; typecheck 0 errors; lint 0 errors (1,432 pre-existing warnings); browser 22 of 22 |
| 13.4 | Round-two migration `20261119120000_ai_core_round2.sql` (NOT one of the twelve): table `ai_core_device_state_reads`, column `ai_core_settings.touchscreen_presets` (≤ 6, 2,160 bytes), file 11's retention function replaced in place (no new cron job); rollback `ROLLBACK-20261119120000.sql` deletes every home's presets; order: after file 12, before the round-two app; round-two code fails closed without it | SIM | Tested — worker-reported local database runs (apply, the round-two QA script, re-apply refused by name, rollback to an identical schema, apply again; platform `docs/ai-core/MIGRATIONS.md` "Round two"); not rerun by the conductor. The conductor confirmed at `e68167946` that the twelve frozen files are unchanged. NOT applied to any remote database |
| 13.5 | Tool `devices.get_state` (wire `devices_get_state`; read, `BASE`, everyone): the id checked against the four tables the Agent already writes; scope `full` only when the existing household rules allow it, else `system`; refuses `restricted_class` / `camera_not_supported` / `controller_not_capable` before anything is sent; waits ≤ 15 s, otherwise says no current value is known and gives a labelled stored sample with its age when allowed; a temperature's unit only from its name or the device's `SCALE`. Registry 37 → 39 with 13.6 | SIM | Tested — platform unit tests on `codex/ai-core-round2` (worker-reported); not yet rerun by the conductor |
| 13.6 | Tool `devices.health` (wire `devices_health`; read, `BASE`, everyone): stored samples the SmartBuildOS Agent uploads while System Studio monitoring is on (off by default), plus devices reported offline; a problem is only the device's own low flag or status, offline, or a sample older than 15 minutes (no threshold of ours); says plainly when monitoring is off ("Nothing is known") | SIM | Tested — platform unit tests on `codex/ai-core-round2` (worker-reported); not yet rerun by the conductor |
| 13.7 | Presets on the driver: configuration key `touchscreen.presets` (≤ 6, 3–120 characters, one line of plain text, one bad preset refuses the whole document); shown as buttons only after an owner PIN unlocks the chat, in addition to the three built-in questions; a locked page carries no preset text; a button from an old list is refused (`unknown_suggestion`) | SIM | Completed (simulation) — conductor reran at driver `1a663b1` (webview emulator scenario 37 of 37 with the real PIN Lock) |
| 13.8 | Presets in Studio with the gate: staff-only editor, the validator mirrored from the driver's `config.lua`, the configuration key sent only when every live AI Core on the controller registers `read_device_state` (an older driver's document is byte-identical to round one's), a republish when that flips; homeowners cannot edit them | SIM | Tested — platform unit and browser tests on `codex/ai-core-round2` (worker-reported); not yet rerun by the conductor |
| 13.9 | Energy honesty guard: no source reports energy; the static prompt and an `energy` report job say energy use is not known and must never be estimated | SIM | Tested — platform unit tests (worker-reported); not yet rerun by the conductor |
| 13.10 | Driver, after `1a663b1`: the temperature scale `SCALE` (exactly the name the Agent's thermostat reader uses, tied to its source by the parity test) joins the base `system` allow-list, so a temperature carries its unit when the device has one; a preset may say "desk-lamp" — `sk-` counts as credential-shaped only as `(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}` (provider name, model and credential status keep the stricter rule) | SIM | Tested — `make test`, lint and the emulator runs on `feat/ai-core-round2`; each change proved by reintroducing its defect once (the old `sk-` rule fails the desk-lamp and sk-lamp checks; `SCALE` removed fails the wine-fridge and parity checks) (worker-reported); not yet rerun by the conductor |
| 13.11 | Platform: the identical preset `sk-` rule and the `SCALE` unit (mirror of 13.10) | SIM | Implemented — landed on `codex/ai-core-round2` by another worker while this round's documents were written (`cfd9a9401` the preset rule, `a95867ea1` the unit, `7a8b05ae2` the platform's `system` screen applying the controller's allow-lists); their tests were not run for these documents and are not yet rerun by the conductor |
| 13.12 | The real variable names of batteries, locks and appliance sensors (every class signature and allow-list is a candidate copied from the Agent) | HW | Blocked — no controller (KNOWN-ISSUES KI-64) |
| 13.13 | Whether the device id the platform sends (often the protocol driver's) exposes its proxy's variables to `C4:GetDeviceVariables` | HW | Blocked — no controller (KI-63) |
| 13.14 | A live read's wall time on a large project, and the queue + bus latency against the 15 s wait | HW | Blocked — no controller (KI-65) |
| 13.15 | How a preset button wraps a 120-character question on a real touchscreen and the phone app | HW | Blocked — no controller or Navigator (KI-70) |
| 13.16 | Camera snapshot descriptions | — | Blocked — on hold for an owner decision on privacy (decision 30); cameras are refused in every scope |

---

## Open owner decisions (none block current work)

Rulings the conductor took on 2026-11-18 (each reversible by the owner) are in `SPEC-webview-and-driver-reporting.md` §8. Numbers 0–15 keep their original numbering (the guide's Verification page uses the same numbers).

0. Decided by the architect, reversible: AI Core events count as household activity; learning is off by default.

1. (Resolved — decided by the owner 2026-11-18) "Intelligence" stays a ninth top-level Studio destination (8.10).
2. (Resolved — decided by the owner 2026-11-18) Price: $150 dealer (charged, one-time, per controller), $250 MSRP. Plan inclusion is still open under 13.
3. Whether to offer a one-click import of existing plaintext company AI keys into the encrypted AI Core vault.
4. (Resolved — decided by the owner 2026-11-18) Flight Recorder retention is enabled (nightly; the first run deletes history older than 30 days for events and 90 days for traces, in one pass) (4.7).
5. Store category for AI Core (currently `Utility`).
6. Default daily request limit (500) and burst (20/min/property); UTC vs property-local budget month; whether existing usage rollups should exclude unknown-cost rows.
7. Thresholds for detectors with no row in the existing §N rules; whether a dismissed recommendation may be raised again; whether the subscription grants `AI_LEARNING` (today only an explicit licence row does). (The scheduling part was decided 2026-11-18: a per-property dealer schedule plus the *Run Household Analysis* command, 6.7.)
8. (Resolved — the homeowner approval screen and two-party approval are built.)
9. Whether AI Core notices may also go out by email; high-risk actions currently need two homeowner confirmations (AI Core's, then the command queue's own); action limits (30-minute approval window; 6 proposals/min, 40/hour, 10 open per property).
10. Composer Studio has no per-project programming field, so an AI programming recommendation cannot be accepted into a blueprint automatically.
11. Licensing policy: a tampered licence assertion is dropped and the driver keeps running (existing behaviour for every SmartBuildOS driver).
12. Pre-existing release gaps: the store-publish workflow has no mapping for the Flight Recorder; `release.yml` fires only on `v*` tags; the Agent main chunk is at 198 of Lua's 200 top-level locals.
13. Whether `SBOS_AI_CORE` is included in any subscription plan (today no plan includes it) or sold only by explicit licence.
14. Staff route scope: actions, rules, programming, credentials, settings, usage, overview, household-usage, flight-recorder, memories, patterns, recommendations and service scope technicians by company only (the platform's existing convention); conversations, jobs and concierge also check property visibility. Tighten all, or leave.
15. Erase semantics: "erase everything learned" deletes every recommendation including approved ones; deleting a single memory keeps approved/implementing/implemented ones.

New on 2026-11-18, for the owner to confirm or change (the conductor's rulings are in force until then):

16. The touchscreen PIN ceiling: low and medium action proposals only (11.5).
17. Opt-in to touchscreen approvals is homeowner-only, in the portal, default off; staff can only switch it off (11.6).
18. Owner-role PINs only; guest and vendor codes always refused (11.1).
19. No PIN code name is recorded or sent to the cloud (11.7).
20. The freshness window [now − 120 s, now + 60 s] and the rate caps (30 details and 10 decisions per hour per property) (11.5).
21. Driver-report limits: 64 live drivers per system, 2,000 events a day per system, 30-day retention of the driver event log (12.9).
22. Whether to build and publish new versions of all 52 drivers (12.20).
23. Whether to add PIN-protected approval of recommendations later (not in v1).

New at the close-out of 2026-11-18:

24. Pre-existing database permissions found during the migration review, outside these migrations and not changed by them: the signed-out (`anon`) and ordinary signed-in (`authenticated`) roles hold TRUNCATE on `companies` and `profiles`, and TRIGGER / MAINTAIN / REFERENCES on `ai_usage_events` (the AI Core migrations revoke only TRUNCATE on `ai_usage_events`). Whether, and when, to revoke them.
25. Whether an owner PIN alone should unlock household answers on the touchscreen (today a separate homeowner portal switch, default off, 11.6, 11.8).

New with round two (2026-11-19; the conductor's rulings in `SPEC-round2-live-answers.md` §9 are in force until the owner decides):

26. Whether an owner PIN alone should unlock door, lock and light state on the touchscreen (today no: only the homeowner's portal switch allows scope `full` there; ruling 2).
27. Whether to apply the round-two migration `20261119120000` (13.4) — only if and when round two ships: after file 12, before the round-two app.
28. Whether to switch System Studio monitoring on by default, so battery and sensor health has data (today off; ruling 6, 13.6).
29. Whether lights and media count as occupancy on the touchscreen (today yes: refused at scope `system`; ruling 3).
30. Camera snapshot descriptions: still on hold for privacy (13.16).

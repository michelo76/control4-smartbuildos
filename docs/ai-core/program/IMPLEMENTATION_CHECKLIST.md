# SmartBuildOS AI Core — Implementation Checklist

Maintained by the conductor only. Architecture: `ARCHITECTURE.md` (same folder). Analysis: `analysis/01`–`05`.

**Status vocabulary:** Not started · In progress · Implemented (code written) · Tested (an automated test that fails without it passes) · Completed (tested AND verified by the conductor against the repo) · Blocked (reason given).

**Verification classes:** `SIM` = automated, simulated/emulated/mocked. `HW` = needs a physical Control4 controller. `LIVE` = needs a real external credential or vendor grant. An item with an `HW` or `LIVE` part is never Completed on simulation alone; the simulated part is recorded separately.

Last updated: 2026-11-18, evening (after the owner's decisions of 2026-11-18; source: the conductor's facts file `STATUS-2026-11-18-evening.md` and `SPEC-webview-and-driver-reporting.md` §8, same folder).

- **Pull requests (open, not merged):** driver `michelo76/control4-smartbuildos#49` (`feat/ai-core`), platform `michelo76/smartbuildos#435` (`codex/ai-core`), opened 2026-11-18 with the owner's go-ahead. Commits after the first push are local until the conductor pushes them.
- **Nothing applied to any remote database. Nothing published to the Driver Store. Simulation only:** nothing has run on a physical Control4 controller or Navigator, and no live AI provider, calendar, places or booking call has been made.
- Final gate totals at the final heads: ⟨conductor: final totals⟩.

Phases 1–10 were built and verified in simulation earlier on 2026-11-18 (conductor reran every gate at driver `1a99e24`, platform `4e86ca3c6`; the totals quoted in rows below are from that run). Phases 11 and 12 were added after the first push.

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
| 2.16 | Migrations exercised on a local database built from baseline + new files | SIM | Completed — all AI Core migrations applied in order, rolled back in reverse and re-applied on a local Postgres with 6 QA scripts (worker-reported; procedure in `docs/ai-core/MIGRATIONS.md`) |
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
| 4.7 | Flight Recorder retention scheduling | SIM | Implemented — owner decided 2026-11-18 to enable it; scheduled nightly by migration `20261118200000_flight_recorder_retention_schedule.sql` (with rollback). Not applied to any database (10.11). The first run deletes the whole backlog past the windows in one pass (30 days events, 90 days traces) |

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
| 6.7 | Scheduled household analysis | SIM | Tested — owner decided 2026-11-18: a per-property schedule the dealer sets (off by default; daily or weekly, property-local time; hourly cron route `/api/cron/ai-core-analysis`) and the Composer command *Run Household Analysis* (`AI_RUN_HOUSEHOLD_ANALYSIS`, op `analyze_household`); one entry point and gate chain (`patterns/entry.ts`). Platform unit tests (`ai-core-household-schedule.test.mjs`), driver side conductor-rerun on a snapshot. Schedule columns not applied to any database |

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
| 10.3 | `SmartBuildOS_AI_Core_Interactive_Guide.html` — 14 chapters, 10 interactive features | SIM | In progress — the guide describes the state at platform `4e86ca3c6` (then: consistency test 794 assertions, 0 failures; browser test 798 controls, 0 failures, 0 network requests, conductor rerun). It predates Phases 11–12 and the decisions of 2026-11-18; a later brief rebuilds it from these documents, and its consistency test disagrees with this checklist until then |
| 10.4 | Every guide control exercised in a browser | SIM | In progress — see 10.3; to be rerun after the rebuild |
| 10.5 | Developer API documentation | — | Completed — `DEVELOPER-API.md`, `OPERATIONS.md`, `README.md`, `DRIVER-CONTRACT.md`, `MIGRATIONS.md` synced to platform commit 0481f3f98; cross-checked by script by the worker, not line-by-line by the conductor |
| 10.6 | Installation documentation | — | Completed — `docs/ai-core/INSTALLATION.md` (driver repo) |
| 10.7 | Release and deployment instructions | — | Completed — `docs/ai-core/RELEASE.md` (driver repo) and `docs/ai-core/MIGRATIONS.md` (platform repo) |
| 10.8 | `.c4z` built and packaged from the worktree | SIM | Blocked — the only build, `smartbuildos-ai-core.c4z` 20261118.091052 (92,634 bytes), predates Phases 11–12; no `.c4z` has been built for any changed driver because this worktree has no packager. Offline substitute: 12.8 |
| 10.9 | Final implementation report | — | In progress — `FINAL_IMPLEMENTATION_REPORT.md` restructured for the current state; final totals ⟨conductor: final totals⟩ |
| 10.10 | Branches pushed / PRs opened | — | Completed — pushed and opened 2026-11-18 with the owner's go-ahead: driver `michelo76/control4-smartbuildos#49`, platform `michelo76/smartbuildos#435`; not merged |
| 10.11 | Migrations applied to production | — | Blocked — owner review and apply (no migration applied to any remote database) |
| 10.12 | Store publication | — | Blocked — owner go-ahead (nothing published) |
| 10.13 | Price and purchase: $150 dealer (one-time, per controller), $250 MSRP; public surfaces show only the MSRP; a purchase grants BASE, AI_LEARNING, AI_ACTIONS (never AI_CONCIERGE); not buyable until a release is published | SIM | Tested — platform unit tests (worker-reported; conductor rerun ⟨conductor: final totals⟩). The price row moves to a twelfth migration applied after the new app is deployed (10.15) |
| 10.14 | The AI Core migrations: eleven files `20261118{120000,120100,140000,150000,160000,170000,180000,190000,200000,210000,211000}` with rollbacks, plus a twelfth file for the price | SIM | In progress — an independent review (2026-11-18, `migrations-review/REVIEW.md`) found them "ready with conditions"; its fixes are being applied (transactions around guards and cron calls, price moved to the twelfth file, `lock_timeout`, order checks, a rollback that refuses while licences exist, a TRUNCATE revoke). Final migration list ⟨conductor: final migration list⟩. Applied to no remote database |

## Phase 11 — AI Core touchscreen webview and PIN (added after the first push)

Driver rows marked "conductor reran" were verified by the conductor rerunning the driver gates (`make test`, lint, the AI Core and module-contract emulator runs, the new webview scenario) on a snapshot. Platform rows rest on the platform worker's tests; the conductor's rerun of the platform gates is ⟨conductor: final totals⟩.

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 11.1 | PIN Lock serves AI Core: `pinlock.availability` / `pinlock.challenge` / `pinlock.redeem`, the `/verify` relay route, owner codes only (guest and vendor always refused), one lockout shared with PIN Lock's page, properties `AI Core Approvals` and `AI Core PIN Verification`; no code name and no slot leave PIN Lock | SIM | Completed (simulation) — conductor reran; PIN Lock suites and the webview emulator scenario with the real PIN Lock (34 checks) |
| 11.2 | AI Core touchscreen page (`src/aicore/webui.lua`, `www/app/index.html`, LAN relay on port 47871): status without a PIN; text rendered with `textContent` only; works only on the home network | SIM | Completed (simulation) — conductor reran; `test_aicore_webui`, webview emulator scenario (34) |
| 11.3 | Chat locked behind an owner PIN (owner decision 8): no conversation bytes on any route while locked, 5-minute idle relock, lock on page close or driver restart, fail closed when PIN Lock is absent, unverified, unlicensed, without an owner PIN or stale | SIM | Completed (simulation) — conductor reran; `test_aicore_webui` [7] asserts on response bodies; webview emulator scenario (34) |
| 11.4 | PIN approvals at the touchscreen (owner decision 7): one PIN entry per approval item, a single-use proof for that one item, no PIN ever enters AI Core or a bus frame; a chat unlock never approves and an approval PIN never unlocks the chat | SIM | Completed (simulation) — conductor reran; `test_aicore_webui`, webview emulator scenario (34) |
| 11.5 | Platform approval ops `approvals_pending` / `approval_detail` / `approval_decide`; approver kind `touchscreen_pin`; ceiling low + medium in code and by a database CHECK; single-use nonce; freshness window [now − 120 s, now + 60 s]; 30 details and 10 decisions per hour per property; locks, garage and security portal-only | SIM | Tested — platform unit tests (worker-reported); conductor rerun ⟨conductor: final totals⟩ |
| 11.6 | Homeowner switches in the portal, per property, default off: touchscreen approvals (staff can only switch it off) and touchscreen answers using household activity | SIM | Tested — platform unit tests (worker-reported) |
| 11.7 | Homeowner notice on every touchscreen approve and decline; the cloud records "approved at the touchscreen with an owner PIN" and nothing that identifies the code | SIM | Tested — platform unit tests (worker-reported) |
| 11.8 | `ask` channel `touchscreen` with `detail`; household data only when the homeowner allowed it | SIM | Tested — platform unit tests (worker-reported); driver side conductor reran |
| 11.9 | Risk class `medium`: never auto-executed; no pre-approved rule can match it | SIM | Tested — platform engine and CHECK tests (worker-reported) |
| 11.10 | The page opens as a tile in Navigator on a touchscreen and the phone app | HW | Blocked — no controller or Navigator |
| 11.11 | The PIN posted from AI Core's page (port 47871) to PIN Lock's relay (port 47831) in Navigator's browser (cross-port) | HW | Blocked — no controller or Navigator |
| 11.12 | Navigator delivers page-close events (`pagehide`, `visibilitychange`) so the chat locks when the tile closes | HW | Blocked — no controller or Navigator |

## Phase 12 — Driver reporting to AI Core (added after the first push)

| # | Task | Class | Status |
| --- | --- | --- | --- |
| 12.1 | Module bus foundations: wildcard requester (`ANY`, mirrored as `"*"`), identity binding for reserved module ids with `verified` in directory and heartbeat rows, registry cap 48, Remote Control tier Comfort for `invoke_driver_action` (`driver_actions_v1`), debug suppression for module frames, per-sender de-duplication (module RPC and the Agent's idempotency ring) | SIM | Completed (simulation) — conductor reran; `test_agent_modules_v2` [10]–[12], module-contract emulator run (24) |
| 12.2 | Shared helper `src/sbos/aireport.lua` (report kinds describe / state / event / diagnostic, declared read-only queries, declared actions, the `AI Core` property) and the one value list `src/sbos/aivalues.lua` | SIM | Completed (simulation) — conductor reran; `test_sbos_aireport`, `test_sbos_aivalues` |
| 12.3 | Passive module `src/sbos/aipresence.lua` for child drivers (requires neither the helper nor the module client); `src/sbos/agentaicore.lua` for the Agent (no new top-level local: 198 of 200) | SIM | Completed (simulation) — conductor reran; `test_sbos_aipresence`, `test_agent_modules_v2` [13] |
| 12.4 | The Agent's two own values: `Found — registered (v…)` (live, verified) and `Found — not verified (v…)` (live, unverified); list now 15 values | SIM | Tested — `test_sbos_aivalues`, `test_agent_modules_v2` [13]; proven by making the unverified case show the verified value (two checks fail). Worker-run; awaiting conductor rerun |
| 12.5 | AI Core report hub (`src/aicore/reports.lua`): receives reports from any module, batches them to the cloud (`driver_reports`), relays `run_driver_query` and `invoke_driver_action`, reports real outcomes (`driver_query_result`; `driver_action_result` with `started` / `completed` / `failed`) | SIM | Completed (simulation) — conductor reran; reports emulator scenario through the real Agent (47 checks) |
| 12.6 | Reference drivers with hand-written reports: Atmosphere, Mode Composer (declares `activate_mode`, the only declared action in the repo), Flight Recorder | SIM | Completed (simulation) — conductor reran; reference-drivers emulator scenario (39 checks) |
| 12.7 | Rollout to 51 of 52 driver directories (AI Core itself is the exception): 20 root drivers report through the helper (VenueFlow only while Remote Management is on), 30 children show the property through the passive module, the Agent derives it from its own registry | SIM | Completed (simulation) — conductor reran; `test_driver_aicore_guard` (the repo-wide ratchet fails if any driver lacks it) |
| 12.8 | Packaging check without a packager: for every driver, the squish list from the Makefile's own steps (`preprocess.py --oss`, `gen-squishy.lua`, in a scratch folder) holds every module its preprocessed `driver.lua` can require, transitively; no child squishes `sbos.aireport` or `sbos.moduleclient` | SIM | Tested — `test_driver_squish_closure`: all 52 pass; proven by a lazy require and a module-client require in a child (both fail). Worker-run; awaiting conductor rerun. Not a `.c4z` build |
| 12.9 | Platform ingest and stores for `driver_reports`, `driver_query_result`, `driver_action_result`; 64 live drivers per system, 2,000 events a day per system, driver event log kept 30 days; `identity_verified` written only from the Agent's heartbeat row | SIM | Tested — platform unit tests (worker-reported); conductor rerun ⟨conductor: final totals⟩ |
| 12.10 | Three tools `drivers.list`, `drivers.run_query`, `drivers.propose_action` (registry 34 → 37) | SIM | Tested — platform tools tests (worker-reported) |
| 12.11 | Driver-declared actions: never run on the model's say-so; at least `medium`; every action of a driver with a lock or security control is `high` (portal only); homeowner approval; Remote Control Comfort or above; unverified drivers refused; `started` is never shown as `completed` | SIM | Tested — platform unit tests (worker-reported); driver relay conductor reran |
| 12.12 | System Studio "Connected drivers" page (staff only) | SIM | Tested — platform tests and browser walk in fixture mode (worker-reported) |
| 12.13 | Platform wire mirror of the module bus; heartbeat reads `verified`; module cap 48 | SIM | Tested — platform unit tests (worker-reported) |
| 12.14 | Identity binding against Director: `C4:GetDevicesByC4iName` answers in a form the Agent can compare with `instance_id` | HW | Blocked — no controller |
| 12.15 | System events 13 and 11 reach child drivers (the passive module relies on them) | HW | Blocked — no controller |
| 12.16 | Sizes at a full 48-module registry (Agent persist, heartbeat, directory) | HW | Blocked — no controller |
| 12.17 | Bus latency of a driver query against the platform's 15 s wait | HW | Blocked — no controller |
| 12.18 | A declared action (Mode Composer `activate_mode`) runs on a real controller and reports its outcome | HW | Blocked — no controller |
| 12.19 | A `.c4z` built for every changed driver and its size measured | SIM | Blocked — no packager in this worktree; squish input growth only (12.8) |
| 12.20 | New versions of all 52 drivers built and published | — | Blocked — owner decision (decision 22) and go-ahead |

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

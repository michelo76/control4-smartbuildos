'use strict';
/* ══════════════════════════════════════════════════════════════════════
   STATUS — the single place every status callout in this guide comes from.
   A later pass updates statuses here only. tone: sim | dev | block | ok.
   Sources: docs/ai-core/program/IMPLEMENTATION_CHECKLIST.md (last updated
   2026-11-18, evening), driver docs/ai-core/{DRIVER,INSTALLATION,KNOWN-ISSUES}.md,
   platform branch codex/ai-core at commit dbdd9b67c (committed work only).
   ══════════════════════════════════════════════════════════════════════ */
const PLATFORM_HEAD = 'dbdd9b67c';
const STATUS = {
  driver: { area: 'AI Core driver (Composer surface, collection, buffer, operations, licence states)', tone: 'sim',
    title: 'Built and simulator-tested; not yet run on a physical controller',
    text: 'Checklist 3.1–3.11 are Completed in simulation (the conductor reran the suite: 149 test files, 10,175 checks, emulator 77/77; for licensing 155 files, 10,445 checks, emulator 105/105). The eleventh command, AI_RUN_HOUSEHOLD_ANALYSIS, was added after the first push and rerun by the conductor on a snapshot. 3.12 (the driver runs in Composer on a real controller) is Blocked: no controller.',
    source: 'DRIVER.md §13–14; KNOWN-ISSUES.md; checklist Phase 3' },
  protocol: { area: 'Module contract v2 and the Agent bus', tone: 'sim',
    title: 'Built and emulator-verified; not yet run on a physical controller',
    text: 'Completed in simulation (checklist 2.2–2.10; the conductor reran 137 test files, 9,516 checks, 0 failed, emulator 23/23). Measuring frame sizes, ordering and restart on a real controller is Blocked (2.17). No released Agent speaks v2 yet: the latest Agent release, 20261116.035552, is protocol 1 only.',
    source: 'MODULE-CONTRACT-V2.md; INSTALLATION.md §1; checklist Phase 2' },
  frLocal: { area: 'Flight Recorder local history over contract v2', tone: 'sim',
    title: 'Built and emulator-tested; not yet run on a physical controller',
    text: 'The Flight Recorder serves its local ring over contract v2, and AI Core discovers it, subscribes and degrades when it is absent: checklist 4.1–4.2 Completed in simulation. Emulator only.',
    source: 'DRIVER.md §8; checklist 4.1–4.2' },
  cloudTools: { area: 'Cloud Flight Recorder tools and evidence post-check', tone: 'sim',
    title: 'Built and tested with fakes; no real database',
    text: 'Completed in simulation (checklist 4.3–4.6): the conductor reran 171 tools/authz/evidence tests, fakes only.',
    source: 'checklist 4.3–4.6' },
  frRetention: { area: 'Flight Recorder retention', tone: 'dev',
    title: 'Decided and scheduled in a migration; not applied anywhere',
    text: 'The owner decided on 18 November 2026 to enable it (decision 4, resolved). Checklist 4.7 is Implemented: migration 20261118200000_flight_recorder_retention_schedule.sql (with a rollback) schedules the existing retention function nightly. It is applied to no database (10.11 is Blocked: owner review and apply). The first run deletes the whole backlog past the windows in one pass: events older than 30 days, traces older than 90 days.',
    source: 'PRIVACY-RETENTION-LIMITS.md; checklist 4.7, 10.11' },
  providers: { area: 'AI provider adapters, key vault, settings, budgets', tone: 'sim',
    title: 'Built and tested with mocked HTTP; no live provider call',
    text: 'Completed in simulation (checklist 5.1–5.9: 103 provider tests and 41 vault/settings/budget/audit tests). A real call to Anthropic or OpenAI is Blocked until an API key is supplied (5.11, 5.12): every adapter has only been tested against wire fixtures written from vendor documentation.',
    source: 'providers/README.md; checklist Phase 5' },
  rpc: { area: 'Controller RPC route and cloud ops', tone: 'sim',
    title: 'Built and tested in simulation; the route is not deployed',
    text: 'Checklist 2.12 is Completed in simulation: business outcomes are HTTP 200 `{ok}`, a bad token 401, an outage 5xx. ask, analyze_room, analyze_system, suggest_scene, generate_report, start_diagnostic and test_provider answer with a job; set_context, send_notification and learn_preference complete at once (`job_id: null`); analyze_household answers accepted (queued) and runs afterwards; status answers its own object. The touchscreen ops (approvals_pending, approval_detail, approval_decide) and the driver-reporting ops (driver_reports, driver_query_result, driver_action_result) have handlers on the platform branch, Tested by the platform worker (11.5, 12.9). The route is not deployed: until it is, the Agent gets 404 and the driver sees `cloud_refused` (KNOWN-ISSUES KI-15).',
    source: 'rpc/ops.ts; DRIVER.md §3; checklist 2.12' },
  learning: { area: 'Household learning (memory, detectors, recommendations, homeowner controls)', tone: 'sim',
    title: 'Built and tested in simulation; off by default; analysis on a dealer schedule, from programming or on demand',
    text: 'Completed in simulation (checklist 6.1–6.6; 60 learning tests; the migration ran only on a throwaway local Postgres). Learning is off until switched on in System Studio. Scheduled household analysis is Tested (6.7), as the owner decided on 18 November 2026: a per-property schedule the dealer sets (off by default; daily or weekly, property-local time; an hourly cron route) and the Composer command AI_RUN_HOUSEHOLD_ANALYSIS, both through one entry point and gate chain. Platform unit tests; the driver side was rerun by the conductor on a snapshot; the schedule columns are applied to no database. Today only an explicit licence row grants AI_LEARNING (owner decision 7).',
    source: 'memory/README.md; checklist Phase 6' },
  portalUi: { area: 'Homeowner portal screens ("Your home assistant")', tone: 'sim',
    title: 'Built and browser-verified against fixtures and a local stack; not deployed',
    text: 'Checklist 9.4 is Completed: concierge, approvals, what my home has learned, recommendations and calendar were browser-verified at 360, 768 and 1280 px in fixture mode and against a local stack (158 screenshots; the conductor reran 23 tests). Dark mode was not screenshotted and erase was not executed live. A committed browser smoke spec of the fixture-mode preview pages (npm run test:e2e:ai-core) passed 12/12 (10.2). Not deployed.',
    source: 'checklist 9.4; platform src/components/portal/ai-core' },
  orchestrator: { area: 'Orchestrator (conversation loop)', tone: 'sim',
    title: 'Built and tested in simulation; no live model call',
    text: 'The bounded turn loop (static prompts, fixed tool list, budget before every call, structured answer, evidence post-check) is Completed in simulation (checklist 5.10: 81 orchestrator/conversation/RPC/job tests; injection fixtures pass). No call has been made to a real model (5.11, 5.12 blocked on a key).',
    source: 'orchestrator/turn.ts; checklist 5.10' },
  actions: { area: 'Actions, approvals, pre-approved rules, programming hand-offs', tone: 'sim',
    title: 'Built and tested in simulation; no device has been changed',
    text: 'Checklist 7.1–7.8 are Completed in simulation (the conductor reran 1,139 action/rule/programming/authz tests; the migration ran on a local Postgres, worker-reported). An approved action physically changing a device is Blocked: no controller (7.9).',
    source: 'actions/*.ts; checklist Phase 7' },
  studio: { area: 'System Studio Intelligence pages', tone: 'sim',
    title: 'Built and browser-verified against fixtures and a local stack; no live provider answer',
    text: 'Checklist 8.1–8.9 are Completed: the six pages plus the setup, approvals, rules and hand-off screens were exercised in a browser in fixture mode and against a local stack (60 + 118 screenshots; one captured a loading state). Real model answers have not been shown live (no provider key). The owner decided on 18 November 2026 that Intelligence stays a ninth top-level System Studio destination (8.10). The Connected drivers page, added later, is Tested by the platform worker (12.12; tests and a browser walk in fixture mode, worker-reported). Not deployed.',
    source: 'checklist Phase 8, 12.12' },
  conversations: { area: 'AI Conversations', tone: 'sim',
    title: 'Built; no real model answer has been shown',
    text: 'The Studio AI Conversations page (Server-Sent Events progress, role-gated) and the homeowner conversation in the portal are browser-verified in fixture mode and against a local stack (8.7, 9.4). Without a provider key a turn ends `provider_not_configured`: no real model answer has been produced.',
    source: 'conversations routes; checklist 8.7, 9.4' },
  concierge: { area: 'Lifestyle concierge (request flow, sandbox, recovery)', tone: 'sim',
    title: 'Built and tested in simulation — only a labelled SIMULATION sandbox can complete a request',
    text: 'The provider interface and booking state machine (9.1), the sandbox provider labelled as a simulation everywhere (9.2) and failed-booking recovery (9.5) are Completed in simulation (56 concierge tests; the database admits only the sandbox provider). A missing function grant that broke every transition in a real database was found in the portal browser pass and fixed; a behavioural QA script acting as the application role covers it (worker-reported). The calendar adapters are Tested against documented wire fixtures (9.3). A sandbox booking ends simulated_confirmed, never confirmed.',
    source: 'checklist Phase 9' },
  vendor: { area: 'Restaurant booking with a real vendor', tone: 'block',
    title: 'Requires a vendor partner agreement — not available',
    text: 'Real booking is Blocked (9.6): OpenTable, Yelp Reservations and SevenRooms need a partner agreement each; Resy and Tock have no sanctioned booking API; Reserve with Google cannot book on a diner’s behalf. No vendor adapter code exists.',
    source: 'concierge/providers/registry.ts; checklist 9.6' },
  calendar: { area: 'Calendar read/write and restaurant discovery', tone: 'block',
    title: 'Requires OAuth client credentials and a Places key — never called live',
    text: 'Real calendar read/write is Blocked (9.7) on OAuth client credentials (AI_CORE_CALENDAR_GOOGLE_CLIENT_ID / _SECRET, AI_CORE_CALENDAR_MICROSOFT_CLIENT_ID / _SECRET); Google’s calendar scopes also need sensitive-scope verification before production. Google Places discovery needs AI_CORE_GOOGLE_PLACES_API_KEY. Without them each answers not_configured.',
    source: 'concierge/server.ts; checklist 9.7; KNOWN-ISSUES.md' },
  licensing: { area: 'Licensing end to end', tone: 'sim',
    title: 'Tested end to end in the emulator; three stated gaps',
    text: 'Licence activation, controller binding, grace, renewal, transfer and updates are Completed in simulation with real HMAC signatures and a virtual clock (checklist 3.11, 10.1). Gaps: no driver-side transfer workflow (a platform staff action); the platform never issues CONTROLLER_MISMATCH for AI Core; a tampered assertion is dropped and the driver keeps running (owner decision 11). Price, decided by the owner on 18 November 2026: $150 dealer (charged once, per controller), $250 MSRP; public surfaces show only the MSRP; a purchase grants BASE, AI_LEARNING and AI_ACTIONS, never AI_CONCIERGE. AI Core cannot be bought until a release is published, and no subscription plan includes it (plan inclusion is owner decision 13). The price rules are Tested by platform unit tests (10.13, worker-reported).',
    source: 'checklist 3.11, 10.1, 10.13; KNOWN-ISSUES KI-24, KI-25' },
  packaging: { area: 'Packaging, branches and store publication', tone: 'block',
    title: 'No current .c4z; pull requests open, not merged; nothing published',
    text: 'Packaging is Blocked (10.8): the only AI Core build, 20261118.091052 (92,634 bytes), predates the touchscreen page and driver reporting, and no .c4z has been built for any changed driver because this worktree has no packager (12.19 is Blocked for the same reason; the offline substitute is the squish-closure test, 12.8). The branches were pushed and the pull requests opened on 18 November 2026 with the owner’s go-ahead (10.10, Completed); they are not merged. Nothing is published to the store (10.12 is Blocked: owner go-ahead).',
    source: 'checklist 10.8, 10.10, 10.12, 12.8, 12.19; RELEASE.md' },
  migrations: { area: 'Database migrations', tone: 'block',
    title: 'Under review; applied to no remote database',
    text: 'Eleven AI Core migration files with rollbacks, plus a twelfth that carries the price and is applied after the new app is deployed. They were applied, rolled back and re-applied only on a throwaway local Postgres (2.16, worker-reported). An independent review on 18 November 2026 found them “ready with conditions”; its fixes are being applied, so the final list is being finalised (10.14, In progress). Applying them to production is the owner’s step and has not happened (10.11, Blocked).',
    source: 'platform docs/ai-core/MIGRATIONS.md; checklist 2.16, 10.11, 10.14' },
  touchscreen: { area: 'AI Core touchscreen page, PIN-locked chat and PIN approvals', tone: 'sim',
    title: 'Built and emulator-tested; never opened on a real touchscreen or phone',
    text: 'The driver side is Completed in simulation (11.1–11.4: PIN Lock serving AI Core, the page and its relay, the chat locked behind an owner PIN, one PIN per approval item; the conductor reran the suites and the webview emulator scenario with the real PIN Lock, 34 checks). The platform side is Tested by the platform worker’s unit tests (11.5–11.9: the approval ops and their low + medium ceiling, the homeowner’s two switches, the notice on every decision, touchscreen answers, the medium risk class; worker-reported). On a real controller and Navigator it is Blocked: no controller or Navigator (11.10 the tile on a touchscreen and the phone app, 11.11 the PIN posted across ports to PIN Lock, 11.12 page-close events).',
    source: 'DRIVER.md §7b; INSTALLATION.md §10; checklist 11.1–11.12' },
  driverReports: { area: 'Driver reporting to AI Core (AI Core property, reports, declared queries and actions)', tone: 'sim',
    title: 'Built and emulator-tested; never run on a real controller',
    text: 'The driver side is Completed in simulation (12.1–12.3, 12.5–12.7: bus foundations, the shared helper and value list, the passive module, the report hub, three reference drivers, the rollout to 51 of 52 driver directories; the conductor reran, including the reports emulator scenario, 47 checks, and the reference-drivers scenario, 39). The Agent’s two own values (12.4) and the packaging check without a packager (12.8) are Tested by the worker, awaiting the conductor’s rerun. The platform side (12.9–12.13: ingest and stores, the three driver tools, driver-declared actions, the Connected drivers page, the wire mirror) is Tested by platform unit tests, worker-reported. Blocked on hardware, no controller: 12.14 identity binding against Director, 12.15 system events reaching child drivers, 12.16 sizes at a full 48-module registry, 12.17 query latency against the 15 s wait, 12.18 a declared action running on a real controller.',
    source: 'DRIVER.md §7a; DRIVER_PLATFORM_GUIDE.md §9; checklist 12.1–12.18' },
  driverRollout: { area: 'New versions of every SmartBuildOS driver', tone: 'block',
    title: 'Not built and not published',
    text: 'Every changed driver needs a new build: none has been built (12.19 is Blocked: no packager in this worktree; only the squish input growth is measured) and none is published (12.20 is Blocked on the owner, decision 22, and a go-ahead).',
    source: 'checklist 12.19, 12.20' },
  devdocs: { area: 'Developer API documentation and test matrix', tone: 'sim',
    title: 'Written and cross-checked by script',
    text: 'Checklist 10.5 is Completed: the platform repo\u2019s docs/ai-core/DEVELOPER-API.md, OPERATIONS.md, README.md, DRIVER-CONTRACT.md and MIGRATIONS.md are synced to platform commit 0481f3f98 and cross-checked by script (by the worker, not line by line by the conductor). The test matrix is Completed (10.2): the driver repo\u2019s and the platform\u2019s docs/ai-core/TEST-MATRIX.md. Chapter 14 links to them by repository path.',
    source: 'checklist 10.2, 10.5; platform commit 557fa8d54' },
};

/* What the Verification status page lists, from the checklist as it read when
   this guide was refreshed. Each entry: [text, checklist reference].
   simulated = Completed (the conductor reran it); reported = Tested by a
   worker and not yet rerun by the conductor (the consistency test checks
   both lists against the checklist). */
const VERIFY = {
  simulated: [
    ['Driver: Composer surface, collection, buffer, restricted operations, licence states (unit tests under a C4 shim + Director emulator; the conductor reran)', '3.1–3.11'],
    ['Module contract v2 and the Agent bus (emulator; the conductor reran)', '2.2–2.10'],
    ['Flight Recorder local history over contract v2 (emulator; the conductor reran)', '4.1–4.2'],
    ['Cloud history tools and the evidence post-check (fakes; the conductor reran)', '4.3–4.6'],
    ['Provider adapters, vault, settings, budgets (mocked HTTP; the conductor reran)', '5.1–5.9'],
    ['Orchestrator turn loop (fakes; injection fixtures; the conductor reran)', '5.10'],
    ['Household learning and homeowner controls (the conductor reran)', '6.1–6.6'],
    ['Permission engine, actions, rules, hand-offs, isolation, audit (the conductor reran)', '7.1–7.8'],
    ['Concierge: request state machine, labelled SIMULATION sandbox and failed-booking recovery', '9.1, 9.2, 9.5'],
    ['Licensing end to end with real signatures and a virtual clock (the conductor reran)', '10.1'],
    ['Touchscreen, driver side: PIN Lock serving AI Core, the page and its relay, the PIN-locked chat, one PIN per approval item (the conductor reran; webview emulator scenario with the real PIN Lock, 34 checks)', '11.1–11.4'],
    ['Driver reporting, driver side: bus foundations, the helper and value list, the passive module, the report hub, three reference drivers, the rollout to 51 of 52 driver directories (the conductor reran; reports scenario 47 checks, reference drivers 39)', '12.1–12.3, 12.5–12.7'],
  ],
  reported: [
    ['Migrations applied, rolled back and re-applied on a local Postgres (worker-reported)', '2.16'],
    ['Scheduled household analysis: platform unit tests (the driver side was rerun by the conductor on a snapshot)', '6.7'],
    ['Calendar adapters and OAuth against documented wire fixtures', '9.3'],
    ['Price and purchase rules: platform unit tests', '10.13'],
    ['Touchscreen, platform side: approval ops with the low + medium ceiling, the homeowner’s two switches, the notice on every decision, touchscreen answers, the medium risk class (platform unit tests)', '11.5–11.9'],
    ['The Agent’s two own AI Core values (worker-run; awaiting the conductor’s rerun)', '12.4'],
    ['Packaging check without a packager: every driver’s squish list holds its whole require closure (worker-run; not a .c4z build)', '12.8'],
    ['Driver reporting, platform side: ingest and stores, the three driver tools, driver-declared actions, the wire mirror (platform unit tests)', '12.9–12.11, 12.13'],
  ],
  browser: [
    ['System Studio Intelligence: AI Overview, Household Usage, Flight Recorder Intelligence, Recommendations, Service, Conversations, Provider & settings, approvals, rules, hand-offs, pending memories — fixture mode and a local stack', '8.1–8.9'],
    ['Homeowner portal "Your home assistant" at 360, 768 and 1280 px — fixture preview and a local stack (dark mode not screenshotted; erase not executed live)', '9.4'],
    ['Committed browser smoke spec of the fixture-mode Studio and portal preview pages (npm run test:e2e:ai-core, 12/12)', '10.2'],
    ['System Studio Connected drivers: tests and a browser walk in fixture mode (worker-reported; screenshot pending in this guide)', '12.12'],
  ],
  never: [
    ['A live AI provider call (Anthropic or OpenAI)', '5.11, 5.12'],
    ['A physical Control4 controller running the driver, contract v2 or an approved action', '2.17, 3.12, 7.9'],
    ['The AI Core tile on a real touchscreen or phone, the PIN posted across ports to PIN Lock in Navigator, Navigator’s page-close events', '11.10, 11.11, 11.12'],
    ['Driver reporting on a real controller: identity binding against Director, system events reaching child drivers, a full 48-module registry, query latency, a declared action', '12.14–12.18'],
    ['A .c4z built for AI Core or any changed driver since the touchscreen and reporting work (no packager in this worktree)', '10.8, 12.19'],
    ['Any vendor booking', '9.6'],
    ['A real calendar read or write, or a real Google Places search', '9.7'],
    ['The controller route deployed (until then: 404 → cloud_refused)', 'KI-15'],
  ],
  decided: [
    ['Intelligence stays a ninth top-level Studio destination', 'decided 2026-11-18'],
    ['Price: $150 dealer (charged once, per controller), $250 MSRP; plan inclusion stays open (decision 13)', 'decided 2026-11-18'],
    ['Flight Recorder retention is enabled (nightly; the first run deletes history older than 30 days for events and 90 days for traces, in one pass)', 'decided 2026-11-18'],
    ['Household analysis: a per-property schedule the dealer sets, and the Composer command Run Household Analysis', 'decided 2026-11-18'],
  ],
  owner: [
    ['One-click import of existing plaintext company AI keys into the vault', 'decision 3'],
    ['Store category for AI Core (currently Utility)', 'decision 5'],
    ['Default daily request limit (500) and burst (20/min); UTC vs property-local month; unknown-cost rows in rollups', 'decision 6'],
    ['Thresholds without a §N row; re-raising a dismissed recommendation; whether the subscription grants AI_LEARNING (the scheduling part was decided on 2026-11-18)', 'decision 7'],
    ['Email for AI Core notices; two homeowner confirmations for high-risk actions; action limits (30 min, 6/min, 40/hour, 10 open)', 'decision 9'],
    ['Composer Studio has no per-project programming field, so a programming recommendation cannot be accepted into a blueprint automatically', 'decision 10'],
    ['Licensing policy: a tampered assertion is dropped and the driver keeps running', 'decision 11'],
    ['Pre-existing release gaps: no store mapping for the Flight Recorder; release.yml only on v* tags; Agent main chunk at 198 of 200 locals', 'decision 12'],
    ['Whether SBOS_AI_CORE is included in a subscription plan or sold only by explicit licence (today no plan includes it)', 'decision 13'],
    ['Staff route scope: most staff routes scope technicians by company only; conversations, jobs and concierge also check property visibility — tighten all, or leave', 'decision 14'],
    ['Erase semantics: “erase everything learned” deletes every recommendation, approved ones included; deleting one memory keeps approved, implementing and implemented ones', 'decision 15'],
    ['The touchscreen PIN ceiling: low and medium action proposals only (the conductor’s ruling, in force until the owner confirms or changes it)', 'decision 16'],
    ['Opt-in to touchscreen approvals is homeowner-only, in the portal, off by default; staff can only switch it off', 'decision 17'],
    ['Owner-role PINs only; guest and vendor codes always refused', 'decision 18'],
    ['No PIN code name is recorded or sent to the cloud', 'decision 19'],
    ['The freshness window [now − 120 s, now + 60 s] and the rate caps (30 details and 10 decisions per hour per property)', 'decision 20'],
    ['Driver-report limits: 64 live drivers per system, 2,000 events a day per system, driver event log kept 30 days', 'decision 21'],
    ['Whether to build and publish new versions of all 52 drivers', 'decision 22'],
    ['Whether to add PIN-protected approval of recommendations later (not in this version)', 'decision 23'],
  ],
  unreleased: [
    ['Pull requests open on both repositories since 18 November 2026, not merged; later commits are local until pushed', 'not merged'],
    ['Nothing published to the Driver Store; no GitHub release', '10.12'],
    ['New versions of the changed drivers not built or published (owner decision 22)', '12.20'],
    ['Migrations not applied to production or any remote database', '10.11'],
    ['Platform not deployed (the controller route answers 404)', 'KI-15'],
  ],
};

/* Glossary for contextual definitions (hover, focus or tap a dotted term). */
const GLOSSARY = {
  evidence: ['Evidence', 'Stored Flight Recorder event ids that a tool returned in the same conversation turn. A post-check drops any citation that was not returned in this turn.'],
  contract: ['Module contract v2', 'The driver-to-driver protocol between SmartBuildOS drivers and the Agent: discovery, pub/sub, requests and a cloud relay, on top of v1 registration and events.'],
  entitlement: ['Entitlement', 'A Driver Store licence grant for a SKU (here SBOS_AI_CORE) plus feature flags (BASE, AI_LEARNING, AI_ACTIONS, AI_CONCIERGE). The Agent answers licence questions on the controller.'],
  module: ['Module', 'A SmartBuildOS driver that registers with the Agent under a module_id (AI Core is ai_core; the Flight Recorder is flight_recorder) and receives a per-registration token.'],
  envelope: ['Envelope', 'The event format every module emits (envelope v1): event_id, event_type with an owned prefix, observed_at, severity, evidence_source, quality, payload and more.'],
  capability: ['Capability', 'A named service a module advertises in its manifest, either a request (e.g. events.query) or a topic (events.subscribe over prefixes). Consumers discover capabilities; they never assume them.'],
  manifest: ['Capability manifest', 'Optional JSON sent with SBOS_MODULE_REGISTER (≤ 2 KB, ≤ 24 capabilities) listing what a module can serve.'],
  cloudop: ['Cloud op', 'One of the closed operations AI Core may ask the Agent to relay to the platform route (ask, analyze_room, …, test_provider). Anything else is not_permitted.'],
  restricted: ['Restricted operation', 'One of eight closed operations the platform may send to AI Core through the Agent (apply_config, refresh_status, deliver_result, raise_event, set_learning, run_diagnostic, run_driver_query, invoke_driver_action). None controls equipment; the last two reach only a query or action a driver declared.'],
  topic: ['Topic', 'An event-type prefix such as capture. or observation. that a module subscribes to. The Agent grants only prefixes listed for the subscriber in its topic policy.'],
  idempotency: ['Idempotency key', 'A key kept the same across retries of one request, so the Agent replays the stored answer instead of routing the request twice.'],
  risk: ['Risk class', 'Declared once per tool in the registry: read, low, medium, high, external or programming. The permission engine reads it from the registry, never from the model.'],
  mode: ['Permission mode', 'Per-property setting in System Studio: observe (default; no actions at all), recommend (actions need approval), execute_low_risk (low-risk actions may run under a homeowner-consented rule).'],
  sandbox: ['SIMULATION sandbox', 'The only reservation provider with code: a made-up restaurant inventory (every name begins SIMULATION), off unless staff enable it for a property. Its bookings end simulated_confirmed, never confirmed; nothing is booked at a real restaurant.'],
  precedence: ['Configuration precedence', 'The configuration document is the source of truth on the controller. set_learning only previews a document version so a pause takes effect at once; a late or repeated operation can never undo a newer document.'],
};

/* ── small helpers ────────────────────────────────────────────────────── */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const codeify = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>');
const store = {
  get(k, d) { try { const v = window.localStorage.getItem('sbos-guide:' + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) { try { window.localStorage.setItem('sbos-guide:' + k, JSON.stringify(v)); } catch (e) { /* storage unavailable: ignore */ } },
  del(k) { try { window.localStorage.removeItem('sbos-guide:' + k); } catch (e) { /* ignore */ } },
};
const announce = (msg) => { const l = $('#liveMsg'); if (l) { l.textContent = ''; setTimeout(() => { l.textContent = msg; }, 30); } };
const REF = JSON.parse(document.getElementById('ref-data').textContent);
const reduceMotion = () => window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function table(cols, rows, cls) {
  const head = '<thead><tr>' + cols.map((c) => '<th scope="col">' + c + '</th>').join('') + '</tr></thead>';
  const body = '<tbody>' + rows.map((r) => '<tr>' + r.map((c) => '<td>' + c + '</td>').join('') + '</tr>').join('') + '</tbody>';
  return '<div class="table-wrap"><table' + (cls ? ' class="' + cls + '"' : '') + '>' + head + body + '</table></div>';
}

/* ── status callouts ──────────────────────────────────────────────────── */
const TONE_ICON = {
  sim: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M9 3h6M10 3v6L5 19a2 2 0 0 0 1.8 3h10.4A2 2 0 0 0 19 19l-5-10V3"/></svg>',
  dev: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 3"/></svg>',
  block: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/></svg>',
  ok: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M5 12l5 5L20 7"/></svg>',
};
const TONE_WORD = { sim: 'Simulated only', dev: 'In development', block: 'Blocked', ok: 'Verified' };
function renderStatuses() {
  $$('[data-status]').forEach((el) => {
    const s = STATUS[el.dataset.status];
    if (!s) { el.textContent = 'Unknown status key ' + el.dataset.status; return; }
    el.dataset.tone = s.tone;
    el.setAttribute('role', 'note');
    el.innerHTML = TONE_ICON[s.tone] + '<div><b><span class="sr-only">' + TONE_WORD[s.tone] + ': </span>' + esc(s.title) + '</b><p>' + codeify(s.text) + '</p><small>Source: ' + esc(s.source) + '</small></div>';
  });
  const used = {};
  $$('.chapter [data-status]').forEach((el) => {
    const ch = el.closest('.chapter');
    (used[el.dataset.status] = used[el.dataset.status] || new Set()).add(ch.id);
  });
  $('#statusRows').innerHTML = Object.entries(STATUS).map(([k, s]) => {
    const where = [...(used[k] || [])].map((id) => '<a href="#' + id + '">' + esc($('#' + id).dataset.title) + '</a>').join(', ') || '—';
    return '<tr data-key="' + k + '"><td>' + esc(s.area) + '</td><td><span class="status" data-tone="' + s.tone + '" style="display:inline-block;margin:0;padding:2px 8px">' + esc(TONE_WORD[s.tone]) + '</span><br><b>' + esc(s.title) + '</b></td><td>' + codeify(s.text) + '<br><small>Source: ' + esc(s.source) + '</small></td><td>' + where + '</td></tr>';
  }).join('');
  Object.entries(VERIFY).forEach(([k, list]) => {
    const host = document.getElementById('verify-' + k);
    if (host) host.innerHTML = list.map(([t, ref]) => '<li data-ref="' + esc(ref) + '">' + codeify(t) + ' <small>(' + esc(ref) + ')</small></li>').join('');
  });
  const head = document.getElementById('platformHead');
  if (head) head.textContent = PLATFORM_HEAD;
}

/* ── generated reference tables (Chapter 11, 14) ──────────────────────── */
function renderReferenceTables() {
  $('#tblCommands').innerHTML = REF.commands.map((c) => {
    const params = c.params.length ? table(['Parameter', 'Type', 'Rule', 'Values'], c.params.map((p) => ['<code>' + esc(p.name) + '</code>', esc(p.type), esc(p.rule), p.items ? p.items.map(esc).join(', ') : '—'])) : '<p>No parameters.</p>';
    return '<details class="cmd" id="cmd-' + c.name + '"><summary><code>' + esc(c.name) + '</code> <span class="type" data-t="command">command</span></summary><div class="body"><p>' + esc(c.description) + '</p><dl class="kv"><dt>Cloud op</dt><dd>' + (c.op ? '<code>' + esc(c.op) + '</code>' : 'none') + '</dd><dt>Licence feature</dt><dd><code>' + esc(c.feature) + '</code></dd></dl>' + params + (c.note ? '<p>' + codeify(c.note) + '</p>' : '') + '</div></details>';
  }).join('');
  $('#tblActions').innerHTML = table(['Action', 'Command', 'Does'], REF.actions.map((a) => ['<strong>' + esc(a.name) + '</strong>', '<code>' + esc(a.command) + '</code>', esc(a.does)]));
  $('#tblProperties').innerHTML = table(['Property', 'Default', 'Shows'], REF.properties.map((p) => ['<strong>' + esc(p.name) + '</strong>' + (p.readonly ? '' : ' <span class="type">editable</span>'), esc(p.default || '(empty)'), esc(p.items ? 'List: ' + p.items.join(', ') : p.shows)]));
  $('#tblEvents').innerHTML = table(['Id', 'Event', 'Fired when', 'Description'], REF.events.map((e) => [String(e.id), '<strong>' + esc(e.name) + '</strong>', codeify(e.fired), esc(e.description)]));
  $('#tblVariables').innerHTML = table(['Id', 'Variable', 'Type', 'Value'], REF.variables.map((v) => [String(v.id), '<code>' + esc(v.name) + '</code>', esc(v.type), esc(v.value)]));
  $('#tblConditionals').innerHTML = table(['Id', 'Conditional', 'Type', 'Statement', 'True when'], REF.conditionals.map((c) => [String(c.id), '<code>' + esc(c.name) + '</code>', esc(c.type), esc(c.statement), esc(c.meaning)]));
  $('#tblFrames').innerHTML = table(['Direction', 'Frame', 'Params', 'Answer', 'Since'], REF.frames.map((f) => [esc(f.dir), '<code>' + esc(f.name) + '</code>', esc(f.params), esc(f.answer), 'v' + f.ver]));
  $('#tblErrors').innerHTML = table(['Code', 'Meaning', 'Retry'], REF.errorCodes.map((e) => ['<code>' + esc(e.code) + '</code>', esc(e.meaning), e.retry === 'yes' ? '<strong>yes</strong>' : esc(e.retry)]), 'errors');
  $('#tblRoutes').innerHTML = table(['Method', 'Route', 'Gate', 'Does', 'State'], REF.routes.map((r) => [esc(r.method), '<code>' + esc(r.path) + '</code>', esc(r.gate), esc(r.does), esc(r.state)]));
  $('#envelopeRows').innerHTML = REF.envelope.map((f) => '<tr><td><code>' + esc(f.field) + '</code></td><td>' + esc(f.rule) + '</td></tr>').join('');
  $('#tblTools').innerHTML = REF.tools.map((t) => '<details class="tool" id="tool-' + t.wire + '"><summary><code>' + esc(t.wire) + '</code> <span class="type">' + esc(t.risk) + '</span>' + (t.household ? ' <span class="type">household</span>' : '') + '</summary><div class="body"><p>' + esc(t.description) + '</p><dl class="kv"><dt>Registry id</dt><dd><code>' + esc(t.id) + '</code></dd><dt>Risk</dt><dd><code>' + esc(t.risk) + '</code></dd><dt>Household data</dt><dd>' + (t.household ? 'yes (needs the household grant)' : 'no') + '</dd><dt>Feature</dt><dd>' + (t.feature ? '<code>' + esc(t.feature) + '</code>' : 'default for the risk class (' + (t.risk === 'read' ? 'BASE' : 'AI_ACTIONS') + ')') + '</dd><dt>Audience</dt><dd>' + (t.audience && t.audience !== 'everyone' ? '<code>' + esc(t.audience) + '</code> only — never offered to, and denied for, any other actor (<code>audience_not_permitted</code>)' : 'everyone') + '</dd>' + (t.verb ? '<dt>Queue verb</dt><dd><code>' + esc(t.verb) + '</code></dd>' : '') + '<dt>Required</dt><dd>' + (t.required.length ? t.required.map((r) => '<code>' + esc(r) + '</code>').join(', ') : 'none') + '</dd></dl>' + (t.props.length ? table(['Argument', 'Type', 'Rule'], t.props.map((p) => ['<code>' + esc(p.name) + '</code>', esc(p.type), esc(p.rule || '—')])) : '<p>No arguments.</p>') + '</div></details>').join('');
}

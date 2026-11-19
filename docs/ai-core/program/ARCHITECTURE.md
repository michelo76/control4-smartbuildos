# SmartBuildOS AI Core — Architecture

Status: architect's decisions after Phase 1 analysis (2026-11-18), updated the evening of 2026-11-18 with what landed after the first push (touchscreen webview and PIN approvals, driver reporting; §4.6, §5, §6, §6a, §7, §8). Simulation only: nothing here has run on a physical Control4 controller. Open pull requests: driver `michelo76/control4-smartbuildos#49`, platform `michelo76/smartbuildos#435`. This file is the contract every worker builds against. Evidence for each decision is in `analysis/01`–`05` in this folder. Only the conductor edits this file and `IMPLEMENTATION_CHECKLIST.md`.

Worktrees (the ONLY places code is written):

| Repo | Worktree | Branch | Base |
| --- | --- | --- | --- |
| Driver monorepo | `control4-smartbuildos-ai-core` | `feat/ai-core` | `origin/main` 7db22e7 |
| Platform (Next.js + Supabase) | `smartbuildos-ai-core` | `codex/ai-core` | `origin/main` 19f2d3a7e |

Ground rules for every worker: commit locally to the branch above with small commits touching only your own paths (`git add <paths>`; never `git add -A`); never push, tag, publish to the store, open a PR, or apply a migration to any remote database; never touch sibling checkouts; never use bare `git stash`. A thing is "Tested" only when a test that would fail without it passes — prove each new guard by breaking the thing it guards once.

---

## 1. Principles (non-negotiable)

1. **Extend, do not fork.** The module contract, the command queue, the Flight Recorder store, licensing, notifications, audit and the secret box already exist. AI Core adds to them.
2. **The model proposes; deterministic code decides.** The LLM only ever emits typed tool calls. A permission engine written in plain TypeScript authorizes every call. No tool accepts Lua, shell, SQL, raw device commands or free-form command names.
3. **Evidence or silence.** Every historical claim cites stored event ids that were returned by a tool in the same turn; a post-check rejects citations that were not. Unknown stays `unknown`. Confirmed causes are separated from possible ones.
4. **Nothing simulated is presented as real.** Sandbox providers, fixtures and emulator runs are labelled as such in code, UI, tests and docs. Hardware-dependent items are never marked Completed without a real controller.
5. **The controller stays light.** No AI, no large history, no API keys on the controller.
6. **Household privacy is a second gate.** Household activity needs `homecontrol:view` in addition to the route gate; learning can be paused, scoped and erased by the homeowner.

## 2. Decisions taken (and why)

| # | Decision | Reason |
| --- | --- | --- |
| D1 | Driver-to-driver protocol = **module contract v2**, a superset of the existing v1 (`docs/flight-recorder/PROTOCOL.md`). Hub-and-spoke through the Agent over `C4:SendToDevice` → `ExecuteCommand`, JSON in string params. | v1 already has negotiation, tokens, an acknowledged queue and dedup; DriverWorks has no broadcast, no sender identity and no documented delivery guarantee, so the hub supplies them. |
| D2 | AI provider keys are **customer-supplied**, entered only in System Studio, stored with `encryptSecret` in a new AI Core vault table. The Composer property is read-only status. Keys never transit the controller. | Matches existing policy (`docs/ai-assistant.md`), keeps one hardened entry path, and satisfies "never expose credentials in Composer". |
| D3 | AI Core is gated by its **Driver Store entitlement** (`SBOS_AI_CORE` + features), not by the Enterprise `ai` module. Staff routes live under `/api/monitoring/ai-core/` (already in the drivers-only allowlist). | Standalone Driver Store customers must be able to use it. |
| D4 | AI-originated device actions go through the **existing `control4_commands` queue**, executed by the Agent as today, with new provenance columns. No second executor. The homeowner's Composer "Remote Control" tier still bounds what is possible. | "No redundant subsystems"; the queue already has allowlist, expiry, atomic claim, acks and homeowner approval. |
| D5 | Persistent programming changes are **recommendations only**. A human accepts one into a Composer Studio blueprint revision under their own session. | DriverWorks has no write API for code items; the Programming Agent's apply path is manual-only by a DB constraint. |
| D6 | Flight Recorder history for AI tools is read **cloud-side** from `flight_recorder_events` through the existing timeline library. The driver-side Flight Recorder additionally exposes its recent ring over protocol v2 for local diagnostics. | The AI runs in the cloud; the ring is short. Both are real data. |
| D7 | No double capture. AI Core consumes event classes Flight Recorder already captures; its own collector covers only what Flight Recorder lacks, and a minimal set when Flight Recorder is absent. | Controller cost; graceful degradation. |
| D8 | Pattern detection is **deterministic** (SQL/TypeScript detectors with sample-size confidence). The LLM phrases findings; it does not invent them. | Reproducible, testable, no fabricated patterns. Thresholds follow `docs/implementation/control4-home-intelligence.md` §N. |
| D9 | Memory is structured rows + Postgres full-text. No pgvector in v1. | No new extension to review; retrieval by category/room/device/recency is sufficient at household scale. |
| D10 | OpenAI via the **Responses API** with `store:false`; Anthropic via Messages. Official SDKs. `tool_choice` is `auto|none` only. No temperature. | Current provider constraints (analysis 05). |
| D11 | Minimum Control4 OS **3.3.2**; 3.4/4.x features probed at runtime. | Matches 38 of the repo's drivers; needed APIs arrived by 3.3.1. |
| D12 | Restaurant booking ships as a provider interface + state machine + a clearly labelled **sandbox** provider. Real providers are adapter slots blocked on vendor agreements. Calendar (Google, Microsoft) and Places search are built against real APIs and blocked only on OAuth client credentials. | No vendor grants a booking API without an agreement; scraping is prohibited. |
| D13 | System Studio gets a ninth top-level destination **"Intelligence"** with six sub-pages, per the product brief. This contradicts `REBUILD-SPEC.md` §6 (eight destinations) and is flagged for owner sign-off; nesting is a one-field change (`parent`). | The brief is the newer, explicit instruction. |
| D14 | Sensitive AI Core routes refuse on `gate.wouldDeny` explicitly. | `PERMISSION_ENFORCEMENT` defaults to audit-only. |

## 3. Identifiers

| Thing | Value |
| --- | --- |
| Driver directory / file | `drivers/smartbuildos-ai-core` / `smartbuildos-ai-core.c4z` |
| Driver display name | SmartBuildOS AI Core |
| `module_id` | `ai_core` (singleton per controller) |
| Event-type prefix | `ai_core.` |
| Driver SKU | `SBOS_AI_CORE` |
| Feature entitlements | `BASE`, `AI_LEARNING`, `AI_ACTIONS`, `AI_CONCIERGE` |
| Manifest driver name | `sbos.ai_core` (Flight Recorder: `sbos.flight_recorder`) |
| Platform lib | `src/lib/ai-core/` |
| Staff routes | `/api/monitoring/ai-core/…` |
| Homeowner routes | `/api/portal/ai-core/…` |
| Controller route | `/api/integrations/control4/modules/rpc` |
| DB table prefix | `ai_core_` |
| Studio section ids | `intelligence` (parent) → `ai-overview`, `ai-usage`, `ai-flight-recorder`, `ai-recommendations`, `ai-service`, `ai-conversations` |

## 4. Module contract v2 (driver-to-driver protocol)

`PROTOCOL_MIN = 1`, `PROTOCOL_MAX = 2` on Agent and client. Every v1 frame and rule is unchanged; v1 modules keep working. A module that needs v2 and meets a v1-only Agent reports `agent_update_required` and degrades. All v2 frames carry the v1 auth triple (`module_id`, `instance_id`, `token`); the Agent ignores unauthenticated frames and **stamps the sender** (`from_module_id`, `from_instance_id`) itself — a module's own claim of who it is is never forwarded. Registration tokens are minted from `C4:UUID("RANDOM")` when available (fallback: the v1 generator). New Agent code lives in new `src/sbos/` modules required at module scope (the Agent main chunk is at 195/200 locals).

Limits: frame ≤ 32 KB (v1); v2 keeps request `args` ≤ 16 KB and response `result` ≤ 24 KB and pages with a `cursor` instead of fragmenting. Large-frame behaviour is unmeasured on hardware, so stay under these.

### 4.1 Capability manifest (registration)

`SBOS_MODULE_REGISTER` gains one optional param `manifest` (JSON); the v1 csv params stay.

```json
{
  "driver": "sbos.flight_recorder",
  "version": "20261118.120000",
  "protocol": 2,
  "capabilities": [
    { "id": "events.query", "version": 1, "kind": "request" },
    { "id": "events.timeline", "version": 1, "kind": "request" },
    { "id": "events.device_history", "version": 1, "kind": "request" },
    { "id": "events.room_activity", "version": 1, "kind": "request" },
    { "id": "events.subscribe", "version": 1, "kind": "topic", "topics": ["capture.", "observation.", "trace."] }
  ]
}
```

A capability a driver cannot serve locally is not advertised. Consumers discover; they never assume.

### 4.2 New frames

| Direction | Command | Params (beyond auth) | Answer / semantics |
| --- | --- | --- | --- |
| M→A | `SBOS_MODULE_DISCOVER` | `request_id`, `filter` (JSON, optional `{module_id, capability}`) | `SBOS_MODULE_DIRECTORY`: `request_id`, `directory_version`, `agent` (JSON: version, protocol_min/max, paired, connected), `modules` (JSON array: module_id, instance_id, driver, driver_version, protocol, status, stale, capabilities[]) |
| A→M | `SBOS_MODULE_DIRECTORY_CHANGED` | `directory_version` | pushed (debounced ≥ 5 s) to v2 modules when a module registers, unregisters or goes stale |
| M→A | `SBOS_MODULE_SUBSCRIBE` | `subscription_id`, `topics` (JSON array of event-type prefixes, ≤ 16) | `SBOS_MODULE_SUBSCRIBED`: `subscription_id`, `ok`, `reason`, `granted` (JSON) |
| M→A | `SBOS_MODULE_UNSUBSCRIBE` | `subscription_id` | none |
| A→M | `SBOS_MODULE_PUBLISH` | `subscription_id`, `events` (JSON array of envelopes, ≤ 25), `dropped` (count since last frame) | best-effort, at-most-once fan-out of envelopes the Agent accepted; per-subscriber buffer 200, drop-oldest, counted. The durable path remains the cloud queue. |
| M→A | `SBOS_MODULE_REQUEST` | `request_id` (UUID = correlation id), `idempotency_key`, `to` (module_id), `to_instance` (optional), `capability`, `args` (JSON), `deadline` (epoch s, ≤ now+60) | `SBOS_MODULE_REQUEST_ACK`: `request_id`, `state` (`Routed`/`Refused`), `error_code` |
| A→M | `SBOS_MODULE_REQUEST` | target's auth triple, `request_id`, `idempotency_key`, `from_module_id`, `from_instance_id`, `capability`, `args`, `deadline` | target must answer before `deadline` |
| M→A | `SBOS_MODULE_RESPONSE` | `request_id`, `status` (`ok`/`error`), `error_code`, `result` (JSON), `cursor` (optional) | relayed A→M to the requester with `from_*` stamped |
| M→A | `SBOS_MODULE_CLOUD_REQUEST` | `request_id`, `idempotency_key`, `op`, `body` (JSON ≤ 16 KB), `deadline` | Agent POSTs `/api/integrations/control4/modules/rpc` with its pairing token, then `SBOS_MODULE_CLOUD_RESPONSE`: `request_id`, `status`, `http_status`, `error_code`, `result` (JSON) |

### 4.3 Authorization, idempotency, retry

- **Closed policy tables in the Agent** (data, mirrored in the web repo like `MODULE_COMMANDS`): `MODULE_REQUEST_POLICY[capability] = { requester module ids }`, `MODULE_TOPIC_POLICY[prefix] = { subscriber module ids }`, `MODULE_CLOUD_OPS[module_id] = { op = true }`. Anything not listed is `not_permitted`. The relay is not a generic HTTP proxy: one fixed route, closed op vocabulary per module.
- **Idempotency:** the Agent keeps a ring (256) of `(from_module, idempotency_key)` → terminal answer; a repeat returns the stored answer and is not re-routed. Targets also dedup on `request_id`. The cloud route is unique on `(system_id, module_id, idempotency_key)`.
- **Timeout:** the requester arms a timer at `deadline`; no answer → local `deadline_exceeded`. The Agent drops routing state at `deadline + 5 s`.
- **Retry:** only for `deadline_exceeded`, `target_unavailable`, `rate_limited`, `cloud_unreachable`; ≤ 2 retries, 2 s then 5 s, **same** idempotency key. Never for `not_permitted`, `invalid_args`, `capability_not_found`, `cloud_refused`.
- **Rate limits:** per-module token buckets in the Agent — 30 module requests/min, 20 cloud requests/min, burst 10.
- **Restart:** tokens and subscriptions die with the Agent; on `SBOS_MODULE_AGENT_HELLO` every module re-registers and re-subscribes. In-flight requests fail with `target_unavailable` at their deadline.
- **Health:** unchanged `SBOS_MODULE_STATUS` + heartbeat `modules` block; `counters` gains `bus` (requests, refused, timeouts, published, dropped).

### 4.4 Error codes (closed vocabulary)

`ok`, `invalid_frame`, `incompatible_protocol`, `unknown_target`, `target_unavailable`, `capability_not_found`, `not_permitted`, `invalid_args`, `payload_too_large`, `deadline_exceeded`, `duplicate_request`, `rate_limited`, `agent_not_paired`, `cloud_unreachable`, `cloud_refused`, `unsupported`, `internal_error`.

### 4.5 Known limits (document, do not paper over)

No global ordering; local pub/sub is lossy by design; legacy unauthenticated Agent commands invoked from Composer programming (`SEND_EVENT`, `REPORT_*`, `SEND_PUSH_NOTIFICATION`) remain sender-unverified because programming has no token; the whole protocol is emulator-verified only until a bench pass.

### 4.6 As landed after the first push (driver `docs/protocol/MODULE-CONTRACT-V2.md` is authoritative)

- **Wildcard requester.** A `MODULE_REQUEST_POLICY` row may say `requesters = ANY` (`modulepolicy.ANY`, mirrored on the platform as `"*"`): every authenticated, registered v2 module may call it. Only `ai_core.report` uses it. An engine that does not know `ANY` refuses.
- **Identity binding and `verified`.** Every root driver's module id is reserved and bound to its `.c4z` file (the 21 roots; the Agent never registers). On a registration under a reserved id the Agent asks Director (`C4:GetDevicesByC4iName(file)`): the claimed device listed → registered, `verified = true`; a table that does not list it → refused `not_permitted`; no answer → registered, `verified = false`. Any other id registers as before, unverified. `verified` is the Agent's own finding, carried in directory rows and heartbeat module rows, never copied from a module's claim. Consumers decide: AI Core refuses PIN verification unless `pin_lock` is verified and refuses declared actions on an unverified target; the cloud refuses to propose a declared action on an unverified driver; `ai.action` is served only to a verified `ai_core`. The Agent's own `AI Core` property shows the result (`Found — registered (v…)` / `Found — not verified (v…)`).
- **Registry cap 48** (was 16): the 49th registration is refused `registry_full`. Root drivers register and report; child drivers do not register (a small passive module looks AI Core up through Director). Sizes at 48 are unmeasured.
- **Per-sender de-duplication.** The Agent's idempotency ring and the targets' dedup ring key on the Agent-stamped sender (`from_module_id`, `from_instance_id`) with the request id, so two modules cannot collide on one key.
- **Tier gate.** A `MODULE_COMMANDS` entry may carry a minimum Remote Control rank: `invoke_driver_action = 2` (Comfort). Below Comfort the Agent acks it failed and forwards nothing; the heartbeat advertises `driver_actions_v1` only at Comfort or above. `run_driver_query` is read-only and needs no tier.
- **Debug suppression.** The Agent keeps every `SBOS_MODULE_*` frame that carries args, results or cloud bodies out of its debug output.
- **New capabilities** (policy rows): `ai_core.report` (provider `ai_core`, requesters `ANY`); `pinlock.availability`, `pinlock.challenge`, `pinlock.redeem` (provider `pin_lock`, requester `ai_core`; no PIN ever travels in a bus frame); `ai.query`, `ai.action` (any provider, requester `ai_core`).
- **New cloud ops** (`MODULE_CLOUD_OPS.ai_core`, now 18): `analyze_household`, `approvals_pending`, `approval_detail`, `approval_decide`, `driver_reports`, `driver_query_result`, `driver_action_result`, beside the original 11. **New restricted operations** (`MODULE_COMMANDS.ai_core`, now 8): `run_driver_query`, `invoke_driver_action`.

## 5. AI Core driver (Lua)

Registers as `ai_core` (v2 required), licenses through `src/sbos/license.lua`, updates through the existing store updater.

**Collection** (D7): `C4:RegisterSystemEvent` for the documented system events; consume Flight Recorder topics when present; own `RegisterVariableListener` collector only for classes Flight Recorder lacks or when it is absent, bounded by room/category exclusions delivered in config; `AI_RECORD_EVENT` from programming. DriverWorks cannot report who caused a change, the previous value, or that a programming item ran — events never claim those.

**Outbound events** (envelope v1, prefix `ai_core.`): `ai_core.command`, `ai_core.record`, `ai_core.context`, `ai_core.status`, `ai_core.observation.*`, `ai_core.diagnostic`.

**Cloud ops** (`MODULE_CLOUD_OPS.ai_core`): `ask`, `analyze_room`, `analyze_system`, `learn_preference`, `suggest_scene`, `generate_report`, `start_diagnostic`, `send_notification`, `set_context`, `status`, `test_provider`. Each returns quickly with `{accepted, job_id}`; the result comes back later.

**Restricted operations from the platform** (`MODULE_OPERATIONS.ai_core`, via the existing `MODULE_COMMAND` verb): `apply_config`, `refresh_status`, `deliver_result`, `raise_event`, `set_learning`, `run_diagnostic`. `raise_event` takes one of a closed list of Composer event names. None of these controls equipment — device actions use D4.

**Composer surface:** the properties, commands, variables and events of brief §11. `AI API Credential` is read-only status (e.g. `Configured in System Studio · Anthropic ••••abcd`). Results land in variables (`AI_LAST_RESPONSE` truncated, `AI_LAST_RESPONSE_ID`, `AI_STATUS`, …) and fire events.

**Buffering:** events go through the module client stage → Agent durable queue. While no Agent is reachable, a small persisted priority buffer keeps critical events only, with counted drops.

### 5a. As landed after the first push (driver `docs/ai-core/DRIVER.md` §3, §7a, §7b are authoritative)

- **11 Composer commands.** `AI_RUN_HOUSEHOLD_ANALYSIS` (*Run Household Analysis*, op `analyze_household`) joined the original ten. It starts the household analysis (the learning detectors), not the provider-backed `analyze_system`; the controller allows one accepted run an hour, the cloud does too, and the result is shown in System Studio, never sent back.
- **Report hub** (`src/aicore/reports.lua`). AI Core advertises `ai_core.report` v1 and receives reports (describe, state, event, diagnostic) from any module, with the sender the Agent stamped. It validates them against the shapes the cloud accepts, keeps them in memory only (at most 48 reporting instances), and uploads them in batches (`driver_reports`, ≤ 64 items, ≤ 16 KB). A describe or state counts as uploaded only when the cloud accepted its batch. It relays `run_driver_query` and `invoke_driver_action` to the declaring driver (never retried; the target must be live, protocol 2, advertise `ai.query` / `ai.action` and, for an action, be verified) and reports the real outcome (`driver_query_result`; `driver_action_result` with `started` / `completed` / `failed`). "Sent" is never reported as done.
- **Touchscreen page** (`src/aicore/webui.lua`, `www/app/index.html`, embedded in `src/aicore/page.lua`). A Navigator tile served by AI Core's own LAN relay on port 47871. Without a PIN it shows status and how many items await approval. The chat is locked behind an owner PIN (owner decision): a locked session gets no conversation content from any route, the unlock lasts 5 minutes without interaction and ends on page close, Lock, a driver restart, or PIN Lock becoming unavailable. Approvals need one PIN entry per item. Text is set with `textContent` only. Works only on the home network.
- **PIN path.** The page posts the PIN only to PIN Lock's own relay (port 47831, `/verify`) against a 60-second single-use challenge that AI Core asked PIN Lock for over the bus (`pinlock.challenge`, purpose `approval` or `chat_view`); AI Core then redeems the challenge over the bus (`pinlock.redeem`) and receives only `{verified, verified_at, role: "owner"}`. No AI Core code path and no bus frame carries a PIN. Owner-role codes only; one lockout shared with PIN Lock's own page. The PIN crosses the home network as plain HTTP, as on PIN Lock's own page. AI Core then calls `approval_detail` / `approval_decide` with `verification = {nonce, verified_at, role, method: "pin_lock"}`; the cloud cannot verify the PIN itself and bounds what it trusts (§6a).

## 6. Cloud

```
src/lib/ai-core/
  providers/      neutral types, anthropic + openai adapters, schema compiler, errors, retry/timeout/fallback, pricing
  credentials/    vault read/write (secret box), masking, connectivity test
  settings/       per-property settings, limits, learning controls
  budget/         DB-backed rate + spend enforcement (blocking)
  tools/          registry (name, schema, risk), implementations
  authz/          permission engine (pure functions)
  orchestrator/   conversation loop, untrusted-content isolation, evidence post-check
  memory/         four categories, confidence, homeowner controls
  patterns/       deterministic detectors
  recommendations/
  actions/        proposal → approval → control4_commands
  concierge/      provider interface, state machine, calendar, sandbox
  audit/
```

**Provider layer** — neutral `ChatRequest` / `ToolDefinition{risk}` / `ToolCall` / `ToolResult{untrusted}` / `Usage` / `ProviderError{kind, retryable, retryAfterMs, fallbackEligible}` exactly as specified in analysis 05 Part 3. Model *classes* (`deep`, `fast`) map to model ids in settings, never hard-coded at call sites. Spend-limit errors are non-retryable quota errors on both providers. Every tool argument is re-validated on our side.

**Permission engine** — input: actor (staff role | homeowner | automation), property `permission_mode` (`observe` | `recommend` | `execute_low_risk`), tool risk, target class, the controller's declared capabilities, entitlement features, learning/consent flags. Output: `allow` | `require_approval(by)` | `deny(reason)`.

| Risk class | Examples | Rule |
| --- | --- | --- |
| `read` | history, registry, usage | allowed in every mode, subject to role + household gate |
| `low` | lights, thermostat within bounds, scenes (the `comfort_v1` verbs) | `observe`: deny · `recommend`: require approval · `execute_low_risk`: allow only if it matches a pre-approved rule (verb + scope + bounds), else require approval |
| `high` | locks, garage, security, access control | always explicit homeowner approval per action; never auto; never from learned behaviour alone |
| `external` | reservations, purchases, calendar writes | always explicit homeowner final confirmation |
| `programming` | persistent programming | never executed; becomes a recommendation (D5) |
| `credential` | reading secrets | no tool exists |

Also enforced deterministically: tenant + property scope from the session/token only; device ids validated against the property's registry; action expiry; idempotency keys unique; replay refused; per-property rate limits in the database (the in-memory limiter is not used).

**Orchestrator** — bounded rounds; system prompt is static (cacheable) and contains no tenant data; all telemetry-derived text reaches the model only inside tool results marked untrusted; answers carry `evidence[]` of event ids and a `confirmed` / `possible` split; the post-check drops or flags any citation not present in this turn's tool results.

**Tools (as built — the registry in `src/lib/ai-core/tools/` is authoritative; 37 after the first push, see §6a)** — `flight_recorder.search_events`, `.get_timeline`, `.get_device_history`, `.get_room_activity`, `.correlate_events`, `.analyze_incident`, `.compare_periods`; `devices.list`, `devices.get`, `rooms.list`; `usage.summary`; `health.incidents`; `memory.search`, `memory.propose` (stores a *pending* proposal only); `notifications.send`; `service.findings`, `service.driver_health`, `service.draft_ticket` (draft only); one typed action tool per existing verb — `actions.set_light`, `.set_thermostat`, `.activate_scene`, `.lock`, `.garage`, `.security` (each only *proposes*); `concierge.*`. Provider-facing wire names replace the dot with an underscore. There is deliberately no `recommendations.create` and no generic `actions.propose`: recommendations are produced by the deterministic detectors, and no tool accepts a free-form verb.

**Data** — new tables, all `ai_core_*`, composite FK `(property_id, company_id)` to `properties(id)` (the uuid), revoke-first grants, RLS, rollback file alongside each migration: `settings`, `provider_credentials`, `conversations`, `messages`, `memories`, `patterns`, `recommendations`, `actions`, `jobs`, `audit_events` (append-only; FK SET NULL must be permitted by the trigger), `rate_counters`, `concierge_connections`, `concierge_requests`. `control4_commands` gains provenance (`origin`, `ai_action_id`, `reason`). `ai_usage_events` gains property, cache, reasoning and request-id columns. Migrations are written and tested locally only; applying them to production is the owner's step.

**Registration with existing systems** — `MODULE_PREFIXES.ai_core = ["ai_core."]`, `MODULE_OPERATIONS.ai_core`, `MODULE_LABELS`, the driver's `MODULE_COMMANDS` mirror, `driver_catalog` row for `SBOS_AI_CORE` with features, refresh-route feature emission, notification catalog entries **and** topic flags (both gates), Studio navigation registry + bootstrap capability.

## 6a. As built — where the code differs from the plan above

The code is authoritative; the platform repo's `docs/ai-core/DEVELOPER-API.md` and the driver repo's `docs/ai-core/DRIVER.md` describe it exactly. Differences from sections 4–6 as originally written:

- **Events:** the driver emits `ai_core.event` (the outcome of `raise_event`, carrying `correlation_id`) and never emits `ai_core.context` (the context travels in the `AI_SET_CONTEXT` command envelope).
- **Operations:** `raise_event` accepts an optional `correlation_id`; `set_learning` carries a `config_version`. Staff may send only `refresh_status` and `run_diagnostic`; the other four are platform-only.
- **Cloud ops:** `set_context`, `send_notification` and `learn_preference` complete synchronously (`job_id: null`); only the analysis ops return a job.
- **Configuration:** the driver's schema-1 document is the contract; the platform emits exactly that, tested against golden documents in both repos. The document wins over `set_learning`. Learning is off by default.
- **Data:** 20 `ai_core_*` tables, not 13. `ai_core_rpc_requests`, `ai_core_rate_counters` and `ai_core_context` are keyed by system rather than by the property foreign key.
- **Models:** class → model-id defaults live in `providers/registry.ts`; settings hold only overrides.
- **Tools:** 34 registered, including 11 `concierge.*` tools (`notifications.send` was removed: it could never send). Each tool declares an audience (`everyone`, `staff`, `homeowner`); the authorisation engine denies any other actor kind, so the three `service.*` tools are never offered to or run for a homeowner or a controller, and the concierge tools only for a homeowner.
- **Programming hand-off (D5):** Composer Studio has no per-project programming field, so a recommendation becomes a structured hand-off record a person carries into Composer Studio; nothing is accepted into a blueprint automatically.
- **Licensing (D3):** AI Core is licensed only by an explicit entitlement until the owner decides pricing; it is not included in any plan.
- **Agent locals:** the Agent's main chunk is at 198 of Lua's 200 top-level locals (it was 198 before this project; the "195" above was a miscount). Still 198 after the Agent gained its `AI Core` property (the code lives in `src/sbos/agentaicore.lua`).

Added after the first push (platform `docs/ai-core/DRIVER-CONTRACT.md` and `DEVELOPER-API.md` are authoritative):

- **Tools: 37.** Three driver tools joined the 34: `drivers.list`, `drivers.run_query` (queues one declared read-only query) and `drivers.propose_action` (proposes one declared action; it never runs it).
- **Risk class `medium`.** Added to the engine, the tool types and the action CHECK. `medium` is never auto-executed and no pre-approved rule can match it. Driver-declared actions are at least `medium`; every action of a driver whose describe includes a lock or security control is `high`.
- **Touchscreen approvals.** Cloud ops `approvals_pending`, `approval_detail`, `approval_decide`; approver kind `touchscreen_pin`. Ceiling: low and medium action proposals only, enforced in code and by a database CHECK; high, external, programming, recommendations, bookings, learning consent, erase, settings, and lock / garage / security actions stay portal-only. The homeowner opts in per property in the portal (default off; staff can only switch it off). Single-use nonce; `verified_at` must lie within [now − 120 s, now + 60 s]; 30 details and 10 decisions per hour per property. The homeowner is notified of every touchscreen approve or decline; the record says "approved at the touchscreen with an owner PIN" and nothing that identifies the code. `ask` accepts channel `touchscreen` and returns household activity only when the homeowner's second portal switch (default off) allows it.
- **Driver reports.** Ingest of `driver_reports` (each item validated again; a bad item is dropped and counted, never fails the batch), stores per driver instance (latest describe, latest state, an event log kept 30 days), limits of 64 live drivers per system and 2,000 events and diagnostics a day per system. `identity_verified` is written only from the Agent's heartbeat row (now read with the 48 cap), never from a report. `driver_query_result` and `driver_action_result` record outcomes; `started` is recorded as "started — the driver reports the outcome as an event", never as completed. System Studio gains a staff-only "Connected drivers" page.
- **Driver-declared actions.** Proposed only by `drivers.propose_action` in a person's conversation, never on the model's say-so; homeowner approval (portal, or the touchscreen for `medium` with the switch on); require `AI_ACTIONS`, a verified driver, the stored declaration hash, and `driver_actions_v1` (the homeowner's Remote Control at Comfort or above). Dispatch re-checks all of it and queues `MODULE_COMMAND ai_core.invoke_driver_action`.
- **Household analysis.** One entry point and gate chain (`patterns/entry.ts` `admitHouseholdAnalysis`) for the staff trigger, the controller's `analyze_household` op and a per-property schedule the dealer sets (off by default; daily or weekly, property-local time) run by the hourly cron route `/api/cron/ai-core-analysis`. Gates: `AI_LEARNING`, learning on and not paused, one analysis at a time, and one accepted controller request per property per hour. Usage budgets do not gate it (no provider call).
- **Price and purchase.** $150 dealer (one-time, per controller), $250 MSRP; public surfaces show only the MSRP; a purchase grants `BASE`, `AI_LEARNING`, `AI_ACTIONS` (never `AI_CONCIERGE`); AI Core is not buyable until a release is published. No plan includes it.
- **Migrations: twelve files.** `20261118{120010,120100,140000,150000,160000,170000,180000,190000,200000,210000,211000}` (the last three add Flight Recorder retention, touchscreen approvals and driver reports) and `20261118220000`, which carries the price and is applied only after the new app is deployed. Each has a rollback, each is a single transaction with a 5-second lock limit, and the order is enforced both ways. An independent reviewer's second pass (on platform `2ebbd5bd2`) found them "ready with conditions": files 1–11, deploy the app, then file 12; the pre-flight script first; a backup of Flight Recorder history before file 9; a quiet window; versions recorded under their file stamps (what remains open is in checklist 10.14). None is applied to any remote database. Flight Recorder retention, once applied, deletes the whole backlog past its windows (30 days events, 90 days traces) on its first nightly run.

## 7. What DriverWorks cannot do (and what we do instead)

| Asked for | Reality | Instead |
| --- | --- | --- |
| Observe programming executing | No callback | Read programming text (`GetAllCodeItems`), see edits via system events, and offer `AI_RECORD_EVENT` for dealers to drop into programming |
| Modify Composer programming | No write API | Recommendation → human-accepted blueprint revision (D5) |
| Know who/what caused a change | Not provided | Correlate in time; label as *possible* unless an explicit trace exists |
| Read Control4 History | Not readable | Flight Recorder is the history |
| Send push/email from a driver | No API | Fire events wired to the Notification Agent; platform `dispatchNotification` |
| Authorization for locks/security | None in the SDK | Our permission engine + homeowner approval |
| Pub/sub, delivery acks, sender identity | None | Module contract v2 through the Agent |
| Prove which driver file a module really is | No sender identity on `SendToDevice` | The Agent asks Director which devices run a reserved module's file (`C4:GetDevicesByC4iName`) and marks the registration `verified`; unmeasured on hardware |
| A PIN prompt in a driver's touchscreen page | No secure input or credential API for driver pages | A driver-hosted page on a LAN relay posts the PIN only to PIN Lock's relay; plain home-network HTTP, as PIN Lock's own page; the cloud cannot verify the PIN and bounds what it trusts |
| Know that a touchscreen page closed | No documented close callback for a driver page | The page reports `pagehide` / `visibilitychange`; otherwise 75 s without a poll counts as closed (unmeasured in Navigator) |
| A page reachable away from home | The relay is on the home network only | Use the SmartBuildOS portal; the page says so |
| Read a driver's own `.c4z` files on OS 4.3 | Refused | Pages are embedded into Lua modules (`make embed-pages`) |

## 8. External blockers (precise)

| Item | Blocked on |
| --- | --- |
| Live AI calls in tests | A customer OpenAI and/or Anthropic API key (adapters are tested against recorded/mocked HTTP until one is supplied) |
| OpenTable, Yelp Reservations, SevenRooms booking | A partner agreement with each vendor |
| Resy, Tock booking | No sanctioned API |
| Google Calendar / Microsoft Graph | OAuth client credentials; Google sensitive-scope verification before production |
| Google Places search | An API key |
| Bench validation of protocol v2 and the driver | A physical Control4 controller |
| Bench validation of the touchscreen page, the cross-port PIN post, page-close events, identity binding, child system events, 48-module sizes, bus latency against the 15 s query wait, a declared action on real equipment | A physical Control4 controller and Navigator |
| A `.c4z` for every changed driver and its real size | A worktree with the driver packager (absent here); then the owner's decision to build and publish all 52 |
| Database changes in production | Owner review and apply |
| Store publication | Owner go-ahead |

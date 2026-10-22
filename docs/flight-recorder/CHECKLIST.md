# Flight Recorder — implementation checklist

Persistent, kept current as work proceeds. An item is `[x]` only when it is
implemented AND verified the way its row says; `[~]` is implemented but only
simulator-verified; `[ ]` is open. Hardware rows stay open until a bench
controller (Beta 1 / Beta Site 2, OS 4.2) produced the evidence named.

Branches: driver `feat/flight-recorder` (from `feat/agent-as-agent`, PR #31);
web `codex/flight-recorder` (from `main`). Status date: 2026-10-22 (end of implementation session). Hardware rows stay open.

## Milestone 1 — capability and compatibility audit

- [x] Capability matrix written (`CAPABILITY-MATRIX.md`), every row with
      evidence class, minimum version, limitation, approach, controller check.
- [x] No API name used that is not in the repo, the cached docs, or a shipped
      driver in `~/Documents/Control4/Drivers` (census in the matrix).

## Milestone 2 — expand the Agent

- [x] A. Module registration contract v1 (`src/sbos/modules.lua`, pure):
      register / re-register without duplicate listeners / stale / remove /
      incompatible protocol / singleton instances / token-authenticated
      follow-ups. Verified: `test/test_sbos_modules.lua`.
- [x] A. Agent wiring: `EC.SBOS_MODULE_REGISTER / STATUS / EVENTS /
      COMMAND_RESULT / SNAPSHOT`, hello broadcast on Agent start, unpair →
      modules told. Verified: `test/test_agent_modules.lua` (driver under shim).
- [x] B. Identity: installation identity = existing pairing (token → server
      derives tenant/property/system); controller MAC stays `technical_metadata`;
      the module registration carries the Agent's device id + boot id; the
      platform keeps `control4_agent_modules` keyed by (system, module,
      instance). No historic permission transfers (server keeps the
      registration row per instance id; a new instance is a new row).
- [x] C. Event envelope v1 (`src/sbos/envelope.lua`): build/validate/limits/
      redaction. Verified: `test/test_sbos_envelope.lua`.
- [x] D. Durable, bounded, acknowledged event queue
      (`src/sbos/eventqueue.lua`): take→in-flight→ack semantics, partial
      rejection, permanent errors, priority eviction with recorded loss
      ranges, journal checkpoints, corruption recovery, backoff with jitter.
      Verified: `test/test_sbos_eventqueue.lua`.
- [x] D. Transport: reuses `send()` (same token, same auth renewal, same
      clock note), path `events`, acks parsed. Verified in
      `test_agent_modules.lua` (ack drains, nack requeues, partial reject).
- [x] E. Versioned module configuration delivery (desired/applied/validation/
      last sync/last error) through the heartbeat `modules` block → module.
- [x] F. Restricted command handling: `MODULE_COMMAND` runner added to the
      existing `COMMAND_RUNNERS` allowlist (no second gateway), only the five
      Flight Recorder operations, expiry + duplicate request id + target
      validation, states Accepted/Executing/Completed/Failed/Expired/Unverified
      reported as `agent.command_state` events. Verified: `test_agent_modules`.
- [x] G. Agent observability on the heartbeat (`event_pipeline`, `modules`).
- [x] G. Extension points documented (`PROTOCOL.md` §8) and reserved
      (`capabilities` strings, `extensions` map) — not implemented.

## Milestone 3 — Flight Recorder driver

- [x] A. Recording configuration (`src/flightrecorder/config.lua`): validate,
      keep last valid, unsupported/stale mapping report, templates, never
      auto-subscribe. Verified: `test/test_flightrecorder_config.lua`.
- [x] A/B. Recorder (`src/flightrecorder/recorder.lua`): listener plan
      reconciliation (no duplicates, removals), initial observations vs changes,
      unknown previous value stays unknown, debounce/min-change/coalesce,
      per-minute budget with loss counters. Verified:
      `test/test_flightrecorder_recorder.lua`.
- [x] C. Composer programming commands (Record Event, Start Trace, Record Trace
      Step, Record Trace Decision, Record Expected Result, Complete Trace, Fail
      Trace, Capture Snapshot, Pause/Resume) with trace channels
      (`src/flightrecorder/traces.lua`): overlap, timeout, abandoned,
      duplicate completion, bounded active count. Verified:
      `test/test_flightrecorder_traces.lua`.
- [x] D. Properties, events, variables (status, Agent connection, source
      count, active traces, buffered, dropped, last upload, last error,
      config version; events degraded/restored/threshold/snapshot). No
      feedback loop: own variables are never recordable sources.
- [x] E. Diagnostic snapshots (`src/flightrecorder/snapshot.lua`): bounded,
      redacted, async job with status, warnings. Verified:
      `test/test_flightrecorder_snapshot.lua`.
- [x] Driver under the shim end to end with a fake Agent
      (`test/test_flightrecorder_driver.lua`), Good Night scenario fixture
      exported for the web suite.
- [ ] Hardware: driver adds from Composer, properties paint, Agent registers
      it (Bench: Beta 1). Evidence needed: Composer screenshot + Agent log line
      "module registered: flight_recorder".

## Milestone 4 — backend and database

- [x] Migration `supabase/migrations/20261022120000_flight_recorder.sql`
      (tables, indexes, RLS, storage bucket, retention function) + rollback
      file. NOT applied (classifier-blocked in sessions; owner applies).
- [x] Ingestion `POST /api/integrations/control4/events` (idempotent,
      bounded, structured acks, late steps before trace-start materialise).
- [x] Snapshot upload `POST /api/integrations/control4/snapshots`.
- [x] Heartbeat: `modules` block stored; module config + commands delivered.
- [x] Studio API `src/app/api/monitoring/flight-recorder/*` (events cursor,
      event, traces, trace, config get/put with revision conflict, commands,
      snapshots list + signed download, bookmarks/notes, modules).
- [x] Permissions: read / configure / export keys through `requirePermission`,
      tenant scope through the property's company; cross-tenant denied in tests.
- [x] Retention cleanup function with conservative defaults (events 30 d,
      traces 90 d, snapshots 30 d) — scheduled by the owner (pg_cron row in
      the migration is commented, see the migration header).

## Milestone 5 — System Studio

- [x] Section registered in the property workspace (capability
      `flight-recorder` when a Control4 system exists).
- [x] Activity timeline (range, filters, search, cursor pagination, new-event
      indication, property-local time + zone, detail panel, before/after,
      evidence/quality, links, bookmarks/notes, gap + stale + drop warnings).
- [x] Trace viewer.
- [x] Recorder settings (discovery/selection, templates, exclusions, budgets,
      pause/resume, desired vs applied, validation, limits, permission-aware).
- [x] Snapshots (request, status, details, protected download, redaction
      notice, failed/expired).
- [x] Driver detail/overview + room/device → prefiltered Activity links.
- [x] Genuine empty/loading/error/disconnected/unavailable/permission states.

## Milestone 6 — privacy and performance

- [x] Only configured sources; credential-looking keys/values redacted on the
      controller AND on the server; string variables flagged `quality=
      unreviewed_text`; payload limits enforced both sides.
- [x] No blocking work in callbacks; listener/timer cleanup on config change,
      reload, removal (tested).

## Milestone 7 — verification

- [x] Driver suite green (`make test`), counts in `VERIFICATION.md`.
- [x] Web unit tests green for the new modules (counts in `VERIFICATION.md`).
- [x] Good Night acceptance scenario, simulator run (both repos).
- [ ] Good Night on hardware (owner): see `VERIFICATION.md` §Hardware.

## Milestone 8 — deliverables

- [x] Docs: PROTOCOL.md, CAPABILITY-MATRIX.md, COMPOSER-PROGRAMMING.md,
      INSTALL-UPGRADE-ROLLBACK.md, PRIVACY-RETENTION-LIMITS.md,
      VERIFICATION.md, this checklist; driver `www/documentation/index.md`.
- [x] Build: `make build` produced `smartbuildos.c4z` and
      `smartbuildos-flight-recorder.c4z` (version stamps in VERIFICATION.md).
- [x] PRs opened: driver michelo76/control4-smartbuildos#33 (→ `feat/agent-as-agent`), web michelo76/smartbuildos#394 (→ `main`).

## Outstanding blockers / decisions made without the owner

- Snapshot files: stored as JSON objects in a private bucket; no project
  backup semantics (documented).
- Trace correlation: caller-supplied TRACE CHANNEL strings (Composer cannot
  capture a return value); overlapping Start on one channel interrupts the
  earlier trace (documented in COMPOSER-PROGRAMMING.md).
- Pricing/licence policy: SKU `SBOS_FLIGHT_RECORDER` registered with the
  existing licensing SDK; which tier includes it is NOT decided here.
- Production migration: prepared, not applied.

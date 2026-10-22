# Flight Recorder — verification record

Date: 2026-10-22. Everything below is SIMULATOR evidence (the driver test
shim and node unit tests) unless the row says hardware. Nothing was deployed,
no production migration was applied, no release was published, no controller
was touched.

## Driver repository (`make test`, branch `feat/flight-recorder`)

Suite green: 53 files, 0 failures. New and extended suites:

| Suite | Checks | What it proves |
| --- | --- | --- |
| `test_sbos_envelope.lua` | 25 | envelope build/validate, prefix ownership, redaction (keys, JWT, cycles), bounding → partial, priority |
| `test_sbos_eventqueue.lua` | 30 | take → ack removes only accepted; permanent rejection dropped + recorded; nack returns to front with jittered backoff and doubling; in-flight timeout; eviction prefers initial reads and records contiguous ranges; priority order in a batch; journal checkpoint rate limit, restore, corrupt and partly-corrupt journals; refusals never evict; budgets lower only |
| `test_sbos_modules.lua` | 26 | register/authenticate; re-registration replaces the token and keeps the row; singleton duplicates refused until stale; validation (ids, protocol with the Agent's range); display status matrix incl. "unlicensed only when denied AND enforced"; serialize/restore; heartbeat block carries no token |
| `test_flightrecorder_config.lua` | 26 | whole-document validation with paths; credential variables refused; reserved kind refused; duplicate sources; budget ceiling; resolve → listeners/stale/unsupported/excluded; templates offer only what exists |
| `test_flightrecorder_recorder.lua` | 37 | initial observations are not changes; unknown previous stays unknown; identical re-apply registers nothing twice; reconcile adds/removes; debounce last-value-wins; min_change against last emitted; coalesce burst → one event with count; unchanged re-announcements ignored; budget drops counted with one warning per minute; string values flagged / excluded; pattern + fixed exclusions; self never a source; pause/resume/stop release listeners and timers; stale/unsupported reported; sbos events only when selected |
| `test_flightrecorder_traces.lua` | 21 | channel traces: steps/decisions/expected correlate; duplicate completion recorded; orphan steps; overlap on one channel interrupts the earlier trace; two channels stay distinct; bounded active count; timeout → abandoned; reload → interrupted; bounds |
| `test_flightrecorder_snapshot.lua` | 13 | document shape, redaction, warnings, size trimming (recent first) with truncation notice, job lifecycle |
| `test_flightrecorder_driver.lua` | 60 | the DRIVER under the shim with a scripted Agent: start without an Agent (waiting, retry), registration round trip + licence registration, config delivery/ack/refusal keeps v3, **Good Night** (event order `trace.start, trace.step, trace.expected, observation.change, trace.step, trace.decision, observation.programmed, trace.end`; the observed change is uncorrelated, previous 75 → 0), overlapping executions, restricted commands (token, expiry, Accepted→Executing→Completed, pause releases listeners, resume re-reads, unknown command fails by name, apply_config reconciles), snapshot job (async, redacted, acked, events fired), Agent restart hello → re-register, lost ack → resend then drop + count, Composer template adds only what exists as a composer revision, removal stops listeners/timers and unregisters. Exports `test/fixtures/flight-recorder/good-night-events.json` |
| `test_agent_modules.lua` | 53 | the AGENT under the shim with a scripted module: `event_pipeline` + `modules_v1` on the heartbeat; registration token to the claimed id + agent state + config resend; duplicate/incompatible refused; unauthenticated frames ignored; event validation/ownership/instance check/dedup/stamping with counts in the ack; upload with partial rejection; transport failure → requeue + backoff; 2xx without verdict is not an acceptance; drain; `MODULE_COMMAND` through the existing gateway (duplicate request id, unknown operation, unregistered module, expired → refused by name; token forwarded; command states on the pipeline; terminal is terminal; Unverified after expiry); snapshot upload acks (ok / failure / oversized); `DISCOVER_VARIABLES` partial catalogue; project_changed offered to modules; journal checkpoint on destroy + restore + corrupt recovery; hello on start; unpair broadcast |
| existing suites (`test_smartbuildos_connector`, `test_sbos_license`, `test_sbos_entitlements`, `test_systemlink_*`, `test_agent_driver_contract` …) | unchanged counts | pairing, licensing, System Link and the Agents-panel XML shape still pass after the Agent changes |

Build: `make build` → `dist/oss/smartbuildos.c4z` and
`dist/oss/smartbuildos-flight-recorder.c4z`, both stamped `20261022.061954`,
installed to `~/Documents/Control4/Drivers` (every other `.c4z` in that folder
was overwritten by this branch's build — rebuild the bench branch before bench
testing System Link).

## Web repository (branch `codex/flight-recorder`, from `origin/main`)

| Check | Result |
| --- | --- |
| `npx tsc --noEmit` | clean |
| `npx eslint` on touched files | 0 errors |
| `tests/unit/flight-recorder-envelope.test.mjs` | 5 tests: every Good Night envelope validates; refusals permanent and named; redaction/bounding parity with the driver; clock window |
| `tests/unit/flight-recorder-config.test.mjs` | 3 tests: normalisation, refusal paths, templates/catalogue |
| `tests/unit/flight-recorder-traces.test.mjs` | 5 tests: Good Night materialises one completed trace with 4 steps + programmed event; late starts / early steps; cursors + filters; warnings; modules + pipeline normalisation |
| `tests/unit/flight-recorder-routes.test.mjs` | 8 source contracts: gates per route, company + system scoping, ingest ownership from the token, idempotent upsert, structured acks, redaction twice on snapshots, command verbs + DB CHECK, migration shape (tenant columns, RLS, unique event ids, no payload index, bucket, retention), heartbeat/telemetry changes, navigation/bootstrap/shell wiring |
| guard suites (`admin-tenant-scope`, `api-route-gating`, `orphan-routes`, `schema-drift`, `self-service-gates`, `row-cap-guard`, `audit-no-secrets`, `lazy-builder-guard`) | pass with the new routes/tables classified (reasons recorded in each test) |
| full `npm run test:unit` | see the PR description for the final count |

## The Good Night acceptance scenario

Repeatable, simulator: `make test` runs `test_flightrecorder_driver.lua` [5]–[9]
(trace + lighting request + observed feedback + garage contact + decision +
completion; overlapping executions; commands; snapshot; Agent restart) and
`test_agent_modules.lua` [5] (an internet outage: transport failure → events
stay queued, backoff, no retry inside the window, drain after). The fixture
the driver test writes is what the web test ingests, so both halves agree on
the same bytes.

Hardware (owner, Beta 1 / Beta Site 2, OS 4.2) — NOT DONE, evidence owed:

1. Install `smartbuildos.c4z` 20261022.061954 (Agents tab, per PR #31) and
   confirm the heartbeat `capabilities` lists `modules_v1`.
2. Add `smartbuildos-flight-recorder.c4z`; Composer properties show "Agent
   device N — registered", Agent Connection `ready`; Agent Lua log: `module
   registered: flight_recorder@N`.
3. Studio → Flight Recorder → Recorder settings: Lighting + Contacts
   templates, Save; "applied v1" appears after the next heartbeat.
4. Program the Good Night routine from COMPOSER-PROGRAMMING.md; press it;
   Activity shows the eight events in order with property-local times; the
   trace viewer shows steps beside the LIGHT_LEVEL observation.
5. Pull the controller's uplink for 10 minutes, press Good Night twice on the
   same channel and once on `garage`; restore the uplink; the timeline fills
   in with no duplicates, the first trace reads `interrupted`, no gap is
   marked (queue under 2,000).
6. Capture a snapshot from Studio and from the Composer action; download;
   confirm no token/code strings in the JSON.
7. Remove the driver; Director log shows no further `OnWatchedVariableChanged`
   for its device id; Studio Driver tab lists the instance as removed.

Specific facts still only documented, never measured: `C4:GetBootID`
availability on OS 4.2 (`boot_id` may be absent, handled); SendToDevice frame
size tolerance at 32 KB; timer count under 200 sources; `/events` end-to-end
latency on a real uplink.

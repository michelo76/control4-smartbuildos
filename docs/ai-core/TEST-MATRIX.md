# SmartBuildOS AI Core — driver test matrix

Every driver-side item of the product brief's test list, mapped to a named
test that passes today, plus the licensing and update items. **Everything in
the first two tables is simulation**: `unit` = the C4 shim with a scripted
Agent (`test/aicore_harness.lua`) or pure modules; `emulator` = the Director
emulator running the real Agent, the real Flight Recorder and the real AI
Core with a scripted cloud (`test/emulator/run-ai-core.sh`). Neither is a
controller. What only a physical controller can show is in
[Hardware validation plan](#hardware-validation-plan); none of it has been
done.

How to run: `make test` (unit; every `test/test_*.lua`), `make lint`,
`test/emulator/run-ai-core.sh [path/to/control4-director-emulator]`,
`test/emulator/run-module-contract-v2.sh [path]`, and for the cross-repo
check `SBOS_PLATFORM_REPO=/path/to/smartbuildos make test`.

A case is named `file [section] "check label"`; the label is the exact text
the test prints after `ok`.

## Product brief test list (driver side)

| # | Item | Test (file → section → case) | Class |
| --- | --- | --- | --- |
| 1 | Driver startup | `test/test_aicore_driver.lua` [1] "Driver Status Online"; `test/test_aicore_robustness.lua` [5] "LateInit completed (Driver Status Online)" (corrupted persisted state) | unit |
| | | `test/emulator/ai_core.lua` [1] "AI Core AI_STATUS ready" | emulator |
| 2 | Agent pairing | `test/test_smartbuildos_connector.lua` [56] "pairing at run time registers every listed event", "re-pairing and a later start-time call register nothing twice"; `test/test_aicore_failure_modes.lua` [1] "paired while running → ready, no reload" | unit |
| | | `test/emulator/ai_core.lua` [0] "the run-time-paired Agent received OnItemAdded without a reload"; [1] "Agent Pairing Status Paired" | emulator |
| 3 | Driver registration | `test/test_aicore_driver.lua` [2] "registration contract: ai_core, protocol 1..2, SKU, singleton"; [16] "AI_STATUS agent_update_required" (v1 Agent) | unit |
| | | `test/emulator/ai_core.lua` [1] "both modules registered with the Agent"; [16] "registered at protocol 1 → AI_STATUS agent_update_required" | emulator |
| 4 | Capability discovery | `test/test_aicore_driver.lua` [3] "directory asked for flight_recorder"; [12] "Flight Recorder Link: not installed"; `test/test_aicore_robustness.lua` [2] "the recorder probe with a malformed directory does not throw" | unit |
| | | `test/emulator/ai_core.lua` [2] "Flight Recorder Link: local history served, topics subscribed"; [9] "recorder re-added → found and subscribed again" | emulator |
| 5 | Event delivery | `test/test_aicore_driver.lua` [4] "two distinct events consumed"; [2] "the buffered status event reached the Agent" | unit |
| | | `test/emulator/ai_core.lua` [3] "AI Core consumed the recorder's event"; [4] "an ai_core.command envelope per cloud command reached the cloud", "AI_RECORD_EVENT → ai_core.record through the durable event path" | emulator |
| 6 | Event deduplication | `test/test_aicore_driver.lua` [4] "the repeat is dropped as a duplicate (dedup by event id)"; [18] "no event id handed to the Agent twice" | unit |
| | | `test/emulator/ai_core.lua` [3] "a PUBLISH frame delivered twice is consumed once (dedup by event id)"; [12] "no AI Core event id reached the cloud twice in the whole run" | emulator |
| 7 | Buffer recovery | `test/test_aicore_driver.lua` [14] "buffered events delivered on recovery", "delivered in order"; `test/test_aicore_robustness.lua` [6] "a 500-item persisted buffer loads at most capacity (50)" | unit |
| | | `test/emulator/ai_core.lua` [11] "the buffered events reached the cloud after recovery", "in order", "the overflow is counted" | emulator |
| 8 | Network interruptions | `test/test_aicore_driver.lua` [7] "cloud unreachable after retries → connection status says so", "the next accepted answer clears cloud_unreachable"; `test/test_aicore_failure_modes.lua` [2] "Agent reports no cloud → cloud_unreachable", "cloud back → ready" | unit |
| | | `test/emulator/ai_core.lua` [11] "AI_STATUS agent_lost" (Agent unreachable both ways); [13d] "day 11: never bricked (not unlicensed; commands go)" (cloud down 11 days) | emulator |
| 9 | Controller restarts | `test/test_aicore_driver.lua` [18] "sequence continues after the restart (never reused)", "buffer survives"; [15] "re-registered with a new token" (Agent restart) | unit |
| | | `test/emulator/ai_core.lua` [12] "AI Core back: ready, configuration v8 kept", "event sequence continues after the restart"; [10] "re-subscribed on the reloaded Agent" | emulator |
| 10 | AI provider failure surfaced | `test/test_aicore_robustness.lua` [11] "AI Provider Error (event 10) fired", "AI_LAST_ERROR names the provider error", "a delivered result clears the provider error" | unit |
| 11 | Invalid permissions / refused operations | `test/test_aicore_driver.lua` [7] "Last Error: refused by SmartBuildOS: not_permitted"; [9] "no event fired by a refused raise_event"; [15] "a restricted operation under a pre-restart token is ignored"; [19] "refused: execute_lua with equipment-shaped args"; `test/test_aicore_failure_modes.lua` [5] "an operation under a forged token is ignored: nothing fired, nothing answered", "a device action smuggled into an operation's args → Failed, named" | unit |
| | | `test/emulator/ai_core.lua` [4] "a platform refusal is shown as it is (Last Error)"; [5] "raise_event outside the closed list → Failed, nothing fired"; [14] "every SendToDevice AI Core made in the run went to the Agent" | emulator |
| 12 | Action-approval events | `test/test_aicore_failure_modes.lua` [4] "approval_required Completed → Approval Required fired", "AI_PENDING_APPROVALS 1, APPROVALS_PENDING true, detail shown", "action_completed → Action Completed, approvals back to 0", "action_failed → Action Failed with its detail"; `test/test_aicore_driver.lua` [9] "raise_event approval_required → event 6" | unit |
| 13 | Flight Recorder queries, incl. missing history and absent recorder | `test/test_aicore_driver.lua` [13] "ai_core.diagnostic envelope with the recorder's events", "recorder absent: the envelope says so", "run_diagnostic on an empty ring: Completed, 0 local events"; `test/test_aicore_failure_modes.lua` [3] "a ring that no longer holds older matching events says truncated, with what it does hold", "a refused query: available=false, request_failed, the code kept", "a recorder that never answers: request_failed / deadline_exceeded, after its retry"; `test/test_aicore_robustness.lua` [3] (malformed answer); `test/test_flightrecorder_localquery.lua`, `test/test_flightrecorder_v2.lua` (the recorder's side) | unit |
| | | `test/emulator/ai_core.lua` [8] "it carries the recorder's local event with the id the cloud stores"; [9] "absent recorder: the diagnostic says so instead of failing" | emulator |
| 14 | Licence expiration | `test/test_aicore_driver.lua` [17] "enforced denial → AI_STATUS unlicensed"; `test/test_aicore_licence.lua` [2] "22 combinations: refused exactly when enforce AND a definitive denial"; [9] "past the deadline with no new licence answer: unlicensed" | unit |
| | | `test/emulator/ai_core.lua` [13] "expired + enforce → AI_STATUS unlicensed", "unlicensed: the command is refused, nothing sent" | emulator |

## Licensing and updates

| Item | Test | Class |
| --- | --- | --- |
| Activation on first registration | `test/test_aicore_licence.lua` [1] "SBOS_REGISTER_DRIVER to the Agent at start: sku, version, requester", "the licence registration is re-sent the moment the module registers", "an answered driver stops asking" | unit |
| | `test/emulator/ai_core.lua` [1] "activation: the Agent asked the cloud for SBOS_AI_CORE on its own", "activation: licensed before anyone pressed anything" | emulator |
| Controller-bound assertion accepted | `test/emulator/ai_core.lua` [13a] "signed for this controller: Licensed / Permanent" | emulator |
| Assertion for another controller refused | `test/emulator/ai_core.lua` [13b] "signed with another controller's secret: not honoured (the Agent drops it at fetch)", "server-issued CONTROLLER_MISMATCH (signed, enforced): unlicensed, read-only"; `test/test_aicore_licence.lua` [3] (every path refuses, naming the reason); `test/test_sbos_entitlements.lua` [4], [15] (the Agent's verification) | emulator, unit |
| Signature tampering refused | `test/emulator/ai_core.lua` [13c] "a tampered assertion is not honoured (no Licensed / Permanent)"; `test/test_sbos_entitlements.lua` [3], [14] | emulator, unit |
| Cache → grace → `CLOUD_VALIDATION_REQUIRED` | `test/emulator/ai_core.lua` [13d] "day 8: AI Core told Licensed / Grace (dated) without a refresh", "day 11: Cloud Validation Required" (virtual clock, cloud down); `test/test_aicore_licence.lua` [6]; `test/test_sbos_entitlements.lua` [5], [19]–[21] | emulator, unit |
| Renewal without a reload | `test/emulator/ai_core.lua` [13e] "…AI Core was not reloaded"; `test/test_aicore_licence.lua` [7] "no reload happened (the same tick timer)" | emulator, unit |
| Transfer (revoked here, granted again) | `test/emulator/ai_core.lua` [13g] "moved away: unlicensed, commands refused", "granted again: Licensed / Permanent, commands go, no reload"; `test/test_aicore_licence.lua` [8] | emulator, unit |
| Feature entitlements (and `AI_RUN_HOUSEHOLD_ANALYSIS`: `test/test_aicore_household_analysis.lua` [1]) | `test/test_aicore_licence.lua` [4] "BASE only: AI_LEARN_PREFERENCE refused — 'the licence does not include AI_LEARNING'", "BASE only: set_learning(true) Failed, saying so", "BASE only: a configuration asking for learning keeps it paused, and says why", "without AI_ACTIONS the driver still shows approval/action events …", "the driver gates exactly BASE and AI_LEARNING (AI_ACTIONS / AI_CONCIERGE: no driver path)" | unit |
| Uncertain states never brick | `test/test_aicore_licence.lua` [5] "validation required, unauthenticated, legacy, an unknown status: all operational"; `test/emulator/ai_core.lua` [13d], [13f] "AI Core stays licensed and operational" (clock skew) | unit, emulator |
| Store update picks up a newer `.c4z` | `test/test_aicore_updates.lua` [2] "newer → installed", "older → never a downgrade"; [3] "leading-zero time: 093000 < 120000 on the same day"; [4] "sku_for maps smartbuildos-ai-core.c4z → SBOS_AI_CORE" | unit |
| Cross-repo vocabulary parity | `test/test_aicore_platform_parity.lua` [1]–[6] (needs `SBOS_PLATFORM_REPO`; skips otherwise) | unit |
| Second instance of a SKU removed: the SKU stays for the one that remains | `test/test_sbos_entitlements.lua` [27] "the second instance removed: SBOS_AI_CORE stays in the inventory", "the remaining instance is still pushed its licence", "the last instance removed: the SKU leaves the inventory", "an inventory saved before instances were tracked still works (device_id)" | unit |
| | `test/emulator/ai_core.lua` [1] "a second instance removed: SBOS_AI_CORE stays inventoried, under the instance that remains" (the add-and-remove step restored) | emulator |

## Contract with the platform (integration fixes)

| Item | Test | Class |
| --- | --- | --- |
| `raise_event` takes an optional `correlation_id`; every other unknown key still refuses | `test/test_aicore_operations.lua` [3b] "accepted, carried as op.correlation_id", "97 refused", "a control character refused", "every OTHER unknown key is still refused, with correlation_id present"; `test/test_aicore_cloud_answers.lua` [1] "approval_required WITH correlation_id → Completed (it used to end Failed)", "AI_LAST_CORRELATION_ID = the action id", "an ai_core.event envelope carries it as its correlation_id", "AI_LAST_CORRELATION_ID cleared: it never names an earlier event's subject", "any OTHER unknown key still refuses the whole operation" | unit |
| | `test/emulator/ai_core.lua` [5] "raise_event WITH correlation_id (as the actions service sends it) → Completed, Approval Required", "the ai_core.event envelope reached the cloud carrying it as its correlation_id" | emulator |
| `{accepted: true, job_id: null}` is a completed request (no job, no `working`, no AI Response Ready) | `test/test_aicore_commands.lua` [4] "accepted with job_id null/absent → completed, no job", "the platform's literal {accepted:true, job_id:null} → completed"; `test/test_aicore_cloud_answers.lua` [2] "set_context {accepted, job_id: null} → AI_STATUS ready, NOT working", "no AI Response Ready for either, ever", "learn_preference recorded at once (job_id null) → completed, ready, the refusal cleared" | unit |
| | `test/emulator/ai_core.lua` [4] "set_context and send_notification answered without a job: completed, not waited for" | emulator |
| Every other answer shape per op: job, `unsupported`, `rate_limited`, `status` | `test/test_aicore_cloud_answers.lua` [2] "analyze_system {accepted, job_id} → working", "learn_preference unsupported → refused as it is, no job", "send_notification rate_limited → refused, says rate limited (not 'no answer'), no job", "test_provider rate_limited → shown as refused (rate_limited), nothing pending", "status answered (no `accepted` in its shape) → synchronised, no Sync Now error, nothing pending"; `test/test_aicore_commands.lua` [4] "rate_limited → refused (an answer), says rate limited, not 'no answer'" | unit |
| `set_context` body names the context key `key` (the platform's name) | `test/test_aicore_commands.lua` [1] "…and as `key` in the cloud body (rpc/ops.ts OP_BODIES.set_context: key, value)"; `test/test_aicore_driver.lua` [5] "closed context key normalised, sent as `key` (rpc/ops.ts OP_BODIES.set_context)"; `test/emulator/ai_core.lua` [4] "set_context body names the key `key`, as rpc/ops.ts validates it" | unit, emulator |
| Cross-repo: every restricted-operation argument the platform sends is accepted (incl. `set_learning` `config_version`); every cloud body the driver sends is valid there; answer shapes read right | `test/test_aicore_platform_parity.lua` [7] "<op>: the driver accepts every key of <platform source>"; [8] "<op>: every body key the driver sends is in OP_BODIES.<op> (+ COMMON)", "<op>: every field the platform requires is in the driver's minimal body", "<op>: {accepted: true, job_id: null} → the driver reads it as completed (no pending job)" (needs `SBOS_PLATFORM_REPO`) | unit |
| Robustness (malformed input, timers, persistence, secrets in logs) | `test/test_aicore_robustness.lua` [1]–[10] | unit |
| Text the driver sends satisfies the platform's rule per field (closeout): control characters (C0, DEL, C1, U+2028/U+2029) replaced, malformed UTF-8 dropped, Director's names cut to `room_name` 64 / `device_name` 120 characters on a character boundary, typed text refused over its bound counted in characters | `test/test_aicore_commands.lua` [6] "room_name of 64 2-byte characters: the platform accepts it" (and 63 / 65, 2-, 3- and 4-byte characters, `device_name` at 119 / 120 / 121), "room_name of 65 2-byte characters: bounded where it is resolved (envelope args too)", "room_name with C1 U+0085 (NEL): replaced by a space, accepted" (one case per refused class), "a name with a surrogate: the byte is dropped" (one per malformed form), "501 characters refused (not cut)", "every text field of every cloud body passes the platform's rule", "body(): every bounded text field is cut to the platform's bound and cleaned"; `test/test_aicore_learning_default.lua` [8] "device_name cut to 120 characters (480 bytes), the C1 control gone", "room_name: U+2028 removed, cut to 64 characters", "the diagnostic label is cut between characters (≤ 120 bytes)", "run_diagnostic: the target name is cleaned and bounded like a cloud body"; `test/test_aicore_platform_parity.lua` [8] "<op>.room_name: the driver bounds it before sending (BODY_TEXT_MAX.room_name)", "start_diagnostic.device_name: the driver's bound 120 fits the platform's 120", "every character the platform refuses in text (UNPRINTABLE: 5 ranges) is removed by the driver (commands.lua refusedCodePoint)", "the platform counts text bounds in code points ([...t].length), as the driver does (commands.lua length)" | unit |
| Learning OFF by default; every configuration field defaults to its conservative value | `test/test_aicore_config.lua` [1] "{} = the conservative defaults: learning OFF, every collection source off", "learning on only when a document says so", "explicit learning off"; `test/test_aicore_collector.lua` [1] "default document, even active: nothing subscribed or registered", [2] "a new collector admits nothing until a policy is applied"; `test/test_aicore_learning_default.lua` [1] "no configuration: Learning Status says Off (not switched on in System Studio)", [2] "learning absent: LEARNING_ACTIVE false", [3] "collection not mentioned → every source stays off", [4] "explicit off: Learning Status says Paused by System Studio", [5] "invalid document: Learning Status says Paused by configuration: v7 refused", "the rest of the last valid document stays in force", "a valid document that says on turns it back on", [6] "first document invalid: LEARNING_ACTIVE false", [7] "after a restart: LEARNING_ACTIVE false", [8] "AI_START_DIAGNOSTIC still asks the Flight Recorder for local history"; `test/test_aicore_driver.lua` [1] "Learning Status: off until System Studio switches it on", "learning OFF by default: no system event registered" | unit |
| | `test/emulator/ai_core.lua` [1a] "no configuration: LEARNING_ACTIVE false", "no configuration: Learning Status says so", "no configuration: no subscription to the recorder's topics", "a configuration that says on → LEARNING_ACTIVE true"; [16] "v1 Agent, no configuration: learning off, AI_RECORD_EVENT still recorded" | emulator |
| **Closeout 2026-11-18 — the configuration document is the platform's (the break):** every golden document System Studio publishes (`tests/unit/fixtures/ai-core-driver-config/*.json`: minimum, typical, maximum, learning-on, learning-paused, with-exclusions) is accepted whole by `config.lua` and lands in its expected state; wrong documents (the pre-closeout platform shape, an unknown key, a credential key, a key in the status line, a platform category, one room too many) are refused whole; the platform's bounds mirror equals `config.lua`; 500 excluded rooms accepted, 501 refused | `test/test_aicore_platform_parity.lua` [10] "<golden>: config.lua accepts the document whole", "<golden>: lands in the expected state", "refused whole: <label>", "AI_CORE_DRIVER_CONFIG_LIMITS (driver-config.ts) = config.lua LIMITS", "AI_CORE_DRIVER_CATEGORIES (driver-config.ts) = vocab.lua CATEGORY_LIST" (needs `SBOS_PLATFORM_REPO`); `test/test_aicore_config.lua` [bounds] "500 room ids (the platform's SETTINGS_LIMITS.excludedRooms) are accepted", "501 are refused"; `test/test_aicore_learning_default.lua` [6] (the pre-closeout shape, refused) | unit |
| | `test/emulator/ai_core.lua` [7a] "typical golden (v10): accepted whole → learning ON", "… the ack the Agent reports to Driver Cloud says applied v10", "… the Agent's registry shows applied_config_version 10, no config_error", "learning-paused golden (v11): learning OFF again", "… the subscription is released" (needs `SBOS_PLATFORM_REPO`; prints SKIP otherwise) | emulator |
| `set_learning` and the document never disagree for long: the document decides; `config_version` previews a version; stale or repeated operations ignored; a held preview survives a restart; switching on refused over a refused document; a late older `apply_config` superseded | `test/test_aicore_learning_default.lua` [9] "set_learning(false) previewing v11 → Completed, off at once", "a re-delivered OLDER document (v10, on) does not undo it", "the document it previewed (v11) decides — here: on", "a stale set_learning (v11 already applied) is ignored, idempotently", "… until a newer document (v12) decides", "a late apply_config older than the document in force is superseded, not applied", "set_learning(true) cannot switch it back on over a refused document", "the preview survives a restart"; `test/test_aicore_operations.lua` [1] "set_learning carries the configuration version it previews", [2] "set_learning config_version negative / fractional / as text" | unit |
| | `test/emulator/ai_core.lua` [7a] "set_learning(true) previewing v12 → Completed, learning ON at once", "an older document forwarded late (v10, paused) is applied but does not undo the preview", "the v12 document (learning-on golden) decides", "a stale set_learning (v12 already applied) is ignored" | emulator |
| `AI_RECORD_EVENT` is a dealer's marker, not learning (architect's ruling): recorded with learning off, paused or on; exclusions still refuse it; bounded and cleaned | `test/test_aicore_learning_default.lua` [1] "no configuration: AI_RECORD_EVENT IS recorded (a dealer's marker, not learning; architect's ruling)", [10] "learning paused: still recorded", "learning off by the document: still recorded", "an excluded category still refuses it", "an excluded room still refuses it", "bounded like other text: a NAME over 120 characters is refused", "… and the recorded name is clean"; `test/test_aicore_collector.lua` [marker]; `test/test_aicore_driver.lua` [11] "excluded room: not recorded", "excluded category: not recorded" | unit |
| | `test/emulator/ai_core.lua` [7] "paused: AI_RECORD_EVENT still recorded (a dealer's marker, not learning)"; [7a] "… its excluded category (security) refuses a marker"; [16] "v1 Agent, no configuration: learning off, AI_RECORD_EVENT still recorded" | emulator |
| Envelope text cut between UTF-8 characters by AI Core before `sbos.envelope` (which would split one and get the frame refused by the Agent: `KNOWN-ISSUES.md` KI-1) | `test/test_aicore_learning_default.lua` [11] "the marker reached the Agent in a frame it could decode", "DETAIL cut to 510 bytes (170 whole characters), marked partial", "the label cut to 120 bytes between characters", "AI_ASK: the envelope's copy of a 1500-byte question is cut between characters" | unit |
| `status` (Sync Now) sends only `request_id`, and the platform validates it (no other field) | `test/test_aicore_platform_parity.lua` [8] "status: every body key the driver sends is in OP_BODIES.status (+ COMMON)" — an op the platform handles without a body spec is now a FAIL, not a NOTE | unit |
| `raise_event` detail: the platform's 240 characters against the driver's 512 bytes — never refused, cut between characters | `test/test_aicore_platform_parity.lua` [9] "a 240-character ASCII detail is kept whole", "a 240-character 4-byte detail (960 bytes) is accepted, cut to ≤ 512 bytes between characters" | unit |
| `AI_RUN_HOUSEHOLD_ANALYSIS` ("Run Household Analysis", op `analyze_household`): licensed (`AI_LEARNING`) / unlicensed, accepted (queued), completed, plain accepted, each refusal reason, the Agent's own `not_permitted`, offline, timeout, the in-flight and hourly loop guard (a refusal never uses up the hour; survives a restart) | `test/test_aicore_household_analysis.lua` [1] "BASE only: nothing reaches the cloud", "…Last Error says the licence lacks AI_LEARNING", "a definitive denial: nothing reaches the cloud"; [2] "op analyze_household, body exactly {command, request_id}", "idempotency key = request id = AI_LAST_REQUEST_ID", "last cloud result: accepted (queued)", "no job held: AI_STATUS ready, not working", "no AI Response Ready"; [3] "50 presses in a loop within the hour: zero cloud calls", "AI Status: refused locally (rate_limited)", "after a restart within the hour: still refused locally", "after the hour: allowed again"; [4] "<reason>: reached the cloud (the previous refusal used nothing up), AI Status refused (<reason>)" for rate_limited, learning_not_allowed, not_licensed, already_running, not_permitted, invalid_args and an unknown reason, "not_permitted with NO reason (the Agent refused the op itself): tells the dealer to update the Agent"; [5] "completed: shown as completed", "accepted with no state: plain 'accepted', never 'completed', no job held"; [6] "offline: unreachable (cloud_unreachable), the connection says so", "back online: allowed at once (offline used nothing up)", "a second press while it is in flight: refused locally, not sent", "the unanswered request ends as unreachable (deadline_exceeded)", "after the timeout: allowed again at once (a timeout used nothing up)"; `test/test_aicore_commands.lua` [8] (the answer mapping); `test/test_sbos_modulebus.lua` [9] "a 200 {ok:false, error_code, result:{reason}} keeps error_code AND relays result.reason", "an Agent without the op refuses it itself: not_permitted, result null, no http_status, nothing posted" | unit |
| | `test/emulator/ai_core.lua` [4a] "refusal <reason>: POSTed (the earlier refusals used nothing up); the real Agent relays result.reason" (five reasons), "offline: unreachable, said so", "an Agent without the op refuses it itself: nothing POSTed; AI Core says update the Agent", "op analyze_household as ai_core; body exactly {command, request_id}; idempotency key = request id", "accepted (queued) shown; no AI Response Ready", "25 presses in a loop within the hour: no POST"; [13] "enforced licence without AI_LEARNING: Run Household Analysis refused locally, nothing sent". Timeout is unit-only. Each guard was proven by reintroducing its defect once (licence feature, hourly guard, in-flight guard, a refusal or an outage using up the hour, the hour lost on restart, the answer treated as a job, an unknown state shown as completed, `result.reason` ignored or not relayed by the Agent, the Agent-outdated branch, the op missing from the Agent's policy): each made the named checks fail; restored | emulator |
| `AI_GENERATE_REPORT` requires `TYPE` and `PERIOD` (as documented) | `test/test_aicore_commands.lua` [7] "no TYPE → refused, TYPE: is required", "no PERIOD → refused, PERIOD: is required", "neither → refused" | unit |
| `AI_LAST_RESPONSE` ≤ 1024 bytes, cut between UTF-8 characters; `raise_event` detail ≤ 512 bytes likewise | `test/test_aicore_operations.lua` [4] "exactly 1024 bytes of 2-byte characters: kept whole", "1025 bytes: cut to 1021 bytes of whole characters + '...'", "4-byte characters, offset 0..3: no partial sequence before the marker", "raise_event detail: bounded to 512 bytes, cut between characters"; `test/test_aicore_driver.lua` [8] "AI_LAST_RESPONSE bounded to 1024 bytes and marked", "no split UTF-8 sequence" | unit |

## Report hub and driver operations (D4)

Unit = `test/test_aicore_reports.lua` (pure hub + the driver under the
scripted Agent); emulator = `test/emulator/ai_core_reports.lua` (run by
`test/emulator/run-ai-core.sh`): the real Agent, the real AI Core and two
reporters built on the real helper (`test/emulator/fixtures/sbos-ai-reporter`,
assembled as `smartbuildos-atmosphere.c4z` and `smartbuildos-mode-composer.c4z`).

| Item | Test | Class |
| --- | --- | --- |
| Accepted reports of each kind | unit [1] "a valid describe / state / event / diagnostic is accepted"; emulator [2] "a describe from atmosphere@A reached the cloud", [3] "event uploaded, `at` in epoch seconds", "diagnostic uploaded", "state uploaded with the driver's facts and the baseline" | unit, emulator |
| Unknown kind and oversize refused | unit [1] "an unknown kind is refused (invalid)", "a describe over 8 KB → too_large"; [4] "unknown kind refused (invalid)", "oversize describe refused (too_large)"; emulator [4] "unknown kind → accepted false, invalid", "oversize describe (> 8 KB) → accepted false, too_large" | unit, emulator |
| Identity from the Agent's stamp, never from the report | unit [1] "a report that names its own sender (from_module_id) is refused: unknown key"; [4] "items carry the Agent's stamp (atmosphere@321, mode_composer@322)", "no item under a sender a report named"; emulator [4] "a report naming its sender → accepted false, invalid", "…and no item under that name ever reaches the cloud" | unit, emulator |
| Validation to the platform's item shapes (one bad item fails a batch there) | unit [1] "empty summary refused (the platform requires text)", "hash must be 16 lower-case hex", "`at` as ISO text → invalid (epoch seconds only)", "free text: newline/tab/controls → space, bidi removed, U+2028 → space", "an enum value with a control character is refused"; cross-repo `test/test_aicore_platform_parity.lua` [8a] | unit |
| Answer shape, version, need_describe, unlicensed | unit [2] "answer shape: accepted, ai_core{state, version}", "need_describe while no describe is held", "unlicensed AI Core: answers accepted=false, state unlicensed, nothing kept"; [4] "ai_core.version = the driver_version AI Core registered with"; emulator [2] "the Agent's directory lists AI Core at its driver version", "reporter A: Found — reporting (v<AI Core's version>)"; [11] "reporter A: Found — not licensed (v…)" | unit, emulator |
| Per-instance rates, coalescing, ring and instance bounds | unit [2] "state: 6 a minute per instance", "…coalesced: only the latest waits", "event: 10 a minute", "diagnostic: 6 a minute", "ring bounded at 200, oldest dropped and counted", "48 instances held; the least recently heard is evicted (counted)" | unit |
| Batching within the budget | unit [3] "at most 3 batches in any minute", "a batch holds at most 64 items", "…and fits the 16 KB cloud body", "refused: events are dropped and counted; states wait again (ruling 23)", "the next batch says how many were dropped since the last delivered one"; [3a] "refused: the describe and the state wait again (ruling 23); the event is dropped and counted", "a newer state that arrived meanwhile is kept, not the refused older one (latest per instance)", "a refusing cloud: gaps 60, 120, 240, 480, then every 600 s", "…6 batches an hour in the steady state"; [4] "at most 3 driver_reports batches in any 60 s (budget)"; emulator [5] "at most 3 batches in any 60 s (…)" | unit, emulator |
| AI Core restart → `need_describe` → describe re-sent | unit [4] "after an AI Core restart: need_describe on the next report"; helper `test/test_sbos_aireport.lua` [13a] "a state answered need_describe -> the same-hash describe goes again at once", "a describe AI Core refused (invalid) is not re-sent on need_describe"; emulator [10] "reporter A was told need_describe and re-sent its describe", "atmosphere's describe reached the cloud again after the restart" | unit, emulator |
| Reporter with AI Core absent sends nothing | emulator [1] "AI Core absent: no report frame left either reporter"; [12] "no report frame after AI Core is gone"; helper `test/test_sbos_aireport.lua` [6] | emulator, unit |
| Query round trip | unit [5] "driver_query_result {query_ref, status completed, data}", "a 20 KB answer (bus ok, cloud body 16 KB) → failed payload_too_large, never cut"; emulator [6] "driver_query_result completed with the driver's data" | unit, emulator |
| Action round trip with the real outcome | unit [6] "Completed only after the driver said ok", "the driver's refusal: failed, its words as result_text", "no answer: failed deadline_exceeded, 'outcome is unknown' — never completed", "the same ai_action_id is never run twice (duplicate_request)"; emulator [7] "completed, with the driver's result_text", "the driver refused: failed, its words as result_text (never completed)" | unit, emulator |
| `declaration_changed` | unit [6] "a changed declaration: failed not_permitted, result_text declaration_changed"; emulator [8] "the approved (old) declaration → failed not_permitted, declaration_changed", "…the handler did not run" | unit, emulator |
| Action refused for an unverified module | unit [6] "an unverified module: refused before anything is sent (not_permitted, target_unverified)"; emulator [9] "the Agent registered reporter B unverified", "failed not_permitted, target_unverified", "…nothing reached reporter B" | unit, emulator |
| Licence: reports and queries on `BASE`, actions on `AI_ACTIONS` | unit [6] "licence without AI_ACTIONS (enforced): refused, nothing sent", "an unlicensed AI Core refuses queries (BASE), nothing sent", "…and uploads no batch while unlicensed"; emulator [11] "unlicensed: invoke refused (not_permitted, not_licensed)", "unlicensed: no driver_reports batch" | unit, emulator |
| Debug suppression of the `SBOS_MODULE_*` frames AI Core receives | unit [4] "EC.suppressDebug covers the SBOS_MODULE_* frames AI Core receives" | unit |
| Strict operation parity (the D1 allowance removed) | `test/test_aicore_surface.lua` [5] "MODULE_COMMANDS.ai_core = the driver's restricted operations, exactly (vocab.OPERATIONS)"; `test/test_aicore_platform_parity.lua` [1] "= the driver's registered vocab.OPERATIONS, exactly" | unit |

Each guard was proved by reintroducing its defect once and seeing the named
checks fail (2026-11-18, then restored):

| Defect reintroduced | Failed |
| --- | --- |
| no batching timer / budget (one batch per report) | unit [4] "at most 3 driver_reports batches in any 60 s (budget)" (12 in a minute); emulator [5] "at most 3 batches in any 60 s" (16 in a minute). In that emulator run [4] "unknown kind → accepted false, invalid" also failed: the raw report reused an earlier request id (the emulator's `C4:UUID` is low-entropy) and AI Core's module client replayed the stored answer of another report — its served-dedup ring is keyed by `request_id` alone (`src/sbos/modulerpc.lua`), see the D4 report |
| a sender id taken from inside the report | unit [4] "a report naming another sender is refused", "no item under a sender a report named"; emulator [4] "a report naming its sender → accepted false, invalid", "…and no item under that name ever reaches the cloud" |
| an action reported completed on forward | unit [5]/[6] "Executing, then Completed on the driver's answer", "the driver's refusal: failed, its words as result_text", "a changed declaration: …"; emulator [6] "driver_query_result completed with the driver's data", [7] "completed, with the driver's result_text", "the driver refused: failed, its words as result_text (never completed)", "…the Agent's record ended Failed" |
| invoke on an unverified module | unit [6] "an unverified module: refused before anything is sent (…)"; emulator [9] "failed not_permitted, target_unverified", "…nothing reached reporter B" |
| an unknown kind accepted | unit [1] "an unknown kind is refused (invalid)", [2], [4] "unknown kind refused (invalid)"; emulator [4] "unknown kind → accepted false, invalid" |
| `need_describe` skipped | unit [2] "need_describe while no describe is held", [4] "after an AI Core restart: need_describe on the next report"; emulator [10] "reporter A was told need_describe and re-sent its describe", "atmosphere's describe reached the cloud again after the restart", "mode_composer's too" |

## Known gaps the tests pin rather than hide

* An assertion that fails verification is dropped and the SKU answers
  `LEGACY` ("Licensing Not Yet Enforced"), which is operational: a forged or
  tampered assertion does not license AI Core, but it does not stop it
  either (emulator [13b], [13c]). This is the Agent's documented "enforcement
  cannot precede issuance" rule.
* The Agent never compares an assertion's `controller_id` with its own
  identity (it does not know its platform controller id); binding rests on
  the per-controller signing secret. `CONTROLLER_MISMATCH` is a status the
  platform must issue — and for `SBOS_AI_CORE` the refresh route issues it
  nowhere today (only System Link does); a transferred licence reaches the
  old controller as `NOT_ENTITLED`.
* `AI_CONCIERGE` gates nothing on the controller because the driver has no
  concierge path; the platform must enforce it. `AI_ACTIONS` gates only
  `invoke_driver_action` (device actions still use the Agent's command queue).

## Hardware validation plan

None of this has been done. Each procedure needs a physical Control4
controller, Composer Pro, a paired SmartBuildOS Agent built from this branch
(protocol 2), the Flight Recorder and AI Core `.c4z` from the same build, and
access to System Studio for the paired property. Record for each: OS version,
controller model, Agent / Flight Recorder / AI Core versions, the Lua output
(Composer → driver → Lua tab) and a pass/fail with the observed text.

1. **Load on OS 3.3.2 and on 4.x.** Add `smartbuildos-ai-core.c4z` (Items →
   search the local drivers). Expect in the Lua output no error, `Driver
   Status` = `Online`, `Driver Version` = the build's `<version>`. Press
   **Print Diagnostics**: the counter list prints (proves every squished
   module loaded and the `<script>` tag runs).
2. **Agent paired while running hears system events.** With the Agent
   unpaired, pair it (Pairing Code) and do not reload anything. Add any
   device in Composer and refresh navigators. Expect the Agent's `Project
   Changed` event (or its Lua log `OnSystemEvent(… OnItemAdded …)` at Debug)
   within 30 s, without reloading the Agent.
3. **Registration at protocol 2.** Expect on AI Core: `Agent Pairing Status`
   = `Paired`, `SmartBuildOS Connection Status` = `Connected`, `AI_STATUS` =
   `ready`. **Test Agent Link** writes `Agent link: OK … protocol 1..2,
   paired, cloud connected; N module(s)`.
4. **Request ids and UUIDs.** Run `AI_ASK` from a programming button. Expect
   `AI_LAST_REQUEST_ID` = `aic-` followed by a UUID-shaped value (records
   `C4:UUID("RANDOM")`'s real format).
5. **BOOL variables and conditionals.** Program `If AGENT_CONNECTED is true`
   and `If AI_READY`; disable the Agent driver (or remove it) and confirm the
   `Agent Disconnected` event fires once, `AGENT_CONNECTED` reads false in
   Composer's variable view, and the conditionals evaluate as shown.
6. **System event payloads (17–20, 48, 49, 90).** Unplug a networked device
   for 2 minutes, plug it back; change the Director's IP (DHCP lease) on a
   bench network. Expect `system_events` to grow in Print Diagnostics and
   `ai_core.observation.system` events in System Studio's Flight Recorder
   view with the event name; record the raw `data` text Director sent.
7. **Variable listener first callback.** With the Flight Recorder removed,
   deliver `collection.variables` for a light's `LIGHT_STATE` from System
   Studio. Expect the first event's evidence `initial`, later ones
   `observed`.
8. **Flight Recorder local history under load.** With the recorder
   installed and a busy device, run `AI_START_DIAGNOSTIC` with that device.
   Expect an `ai_core.diagnostic` event citing recorder event ids, no
   `payload_too_large` and no Lua error (frame sizes near 24–32 KB are
   unmeasured on hardware).
9. **Command budget and timers under load.** Fire 11 AI commands in one
   minute from programming. Expect 10 sent and the 11th refused
   `rate_limited`, and the 30 s tick still running (Last Synchronization
   moves).
10. **Graceful controller reboot.** Reboot from Composer. Expect AI Core back
    with its configuration version, `AI_LAST_RESPONSE_ID` kept, and in
    System Studio no duplicated event id and increasing sequence numbers.
11. **Power cut.** Pull power right after a `deliver_result` from System
    Studio. Expect the same as 10 (records Director's persistence flush
    timing).
12. **Agent update / restart.** Update the Agent driver. Expect `Agent
    Disconnected` once, then re-registration within a minute and the Flight
    Recorder subscription back (Flight Recorder Link `…topics subscribed`).
13. **WAN loss.** Unplug the internet uplink for 10 minutes. Expect
    `AI_STATUS` `cloud_unreachable`, AI Core still recording to the Agent's
    queue; after reconnection the queued events reach System Studio in order.
14. **Agent unreachable (LAN side).** Disable the Agent for 6 minutes while
    a device goes offline repeatedly. Expect `agent_lost`, Telemetry Status
    `No Agent answering: N critical event(s) buffered`, and after re-enabling
    the buffered events in System Studio in order.
15. **The platform route.** With the platform deployed, press **Test AI
    Connection**. Expect `AI connection: test accepted (job …)` and later `AI
    Response Ready`. A 404 shows `cloud_refused` (route not deployed).
16. **Results and events to programming.** From System Studio deliver a
    result and raise `approval_required`, `action_completed`,
    `action_failed`, `ai_provider_error`. Expect each Composer event to fire
    its programming (wire one to the Notification Agent), `AI_LAST_ERROR` to
    show the provider error, and `APPROVALS_PENDING` to follow
    `AI_PENDING_APPROVALS`.
17. **Licence on real HMAC.** Refresh entitlements on the Agent. Expect AI
    Core `License Status` `Licensed / …`. With the platform set to enforce
    and the entitlement removed, expect `unlicensed` and commands refused
    with the licence text; restore and expect service back without a reload.
18. **Store update.** Publish a newer AI Core build to the BETA channel
    (owner action), set the Agent's Update Channel to prerelease and press
    Update Drivers. Expect AI Core's `Driver Version` to change and the
    driver to keep its configuration (Director's `UpdateProjectC4i` on real
    hardware).
19. **No equipment touched.** During all of the above, watch the project's
    devices. Expect no device state change caused by AI Core.
20. **Secrets never printed.** Set Log Level `5 - Trace` and Log Mode
    `Print` during registration and an operation. Expect no module token in
    the Lua output (the `SBOS_MODULE_*` frames are suppressed from the
    handler debug print).
21. **Run Household Analysis from programming.** In Composer Programming,
    find `AI_RUN_HOUSEHOLD_ANALYSIS` under the AI Core device's commands and
    record exactly what Composer lists and what the script line shows (the
    `<name>` and the `<description>` "Run Household Analysis: …"). Wire it to
    a button; press once. Expect `Print Diagnostics` `last_cloud_result =
    AI_RUN_HOUSEHOLD_ANALYSIS: accepted (queued)`, no AI Response Ready, and
    the run's result in System Studio. Press again at once: expect `refused
    locally (rate_limited)` and no request in the platform's logs. With
    learning paused in System Studio (after the hour): expect `refused
    (learning_not_allowed)`.

21 procedures.

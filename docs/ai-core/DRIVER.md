# SmartBuildOS AI Core — driver reference

Status: built on branch `feat/ai-core` (frozen at `09d138b` in pull request #49
for the owner); **round two** — the live device read (§7c, `read_device_state` →
`device_state_result`), the dealer's preset questions (§7b, §9
`touchscreen.presets`) — exists **only on `feat/ai-core-round2`**, which is not
pushed; on `feat/ai-core` there are eight restricted operations, eighteen cloud
ops and no presets. **One physical controller has loaded this driver**: it
showed its properties and a real SmartBuildOS cloud accepted its requests; no AI
answer has been seen on it, and the touchscreen page and the PIN flow were not
opened. Everything else below is verified by unit tests under the C4 shim and by
a Director-emulator scenario (simulation); see [Verification](#13-verification)
and [Not verified on hardware](#14-not-verified-on-hardware).

This file is the authoritative reference: later documentation is generated
from it, so the names here are exact.

| Item | Value |
| --- | --- |
| Driver directory / file | `drivers/smartbuildos-ai-core` / `smartbuildos-ai-core.c4z` |
| Display name | SmartBuildOS AI Core |
| `module_id` | `ai_core` (singleton per controller) |
| Manifest driver | `sbos.ai_core` (serves no capability to other modules) |
| Protocol | module contract v2 required (`require_protocol = 2`); negotiates 1..2 |
| SKU | `SBOS_AI_CORE` |
| Feature entitlements | `BASE`, `AI_LEARNING`, `AI_ACTIONS`, `AI_CONCIERGE` |
| Event-type prefix | `ai_core.` |
| Minimum OS | 3.3.2 (`<minimum_os_version>`) |
| Variable ids | 4000–4010 |
| Pure logic | `src/aicore/{vocab,commands,config,operations,buffer,collector,state,diagnostic,reports,webui}.lua` |
| Touchscreen page | `www/app/index.html`, embedded as `src/aicore/page.lua`; LAN relay on port 47871 (§7b) |
| Driver wiring | `drivers/smartbuildos-ai-core/driver.lua` |
| Dealer manual | `drivers/smartbuildos-ai-core/www/documentation/index.md` |

What it is: the controller-side half of AI Core. The AI runs in the
SmartBuildOS cloud. The controller holds **no AI, no history beyond a small
buffer, and no API key** (ARCHITECTURE §1.5, D2). The driver turns Composer
programming into validated cloud requests, shows results and platform events
to programming, collects a minimal set of events, and reports its health.

## 1. Composer properties

All read-only except **Log Level**, **Log Mode**, **Touchscreen Detail** and
**App Relay Address**.

| Property | Shows | Source |
| --- | --- | --- |
| `Driver Status` | `Online` once started | driver |
| `Driver Version` | the built `<version>` | driver |
| `SmartBuildOS Connection Status` | one of the state texts in §6 | state machine |
| `Agent Pairing Status` | `Paired`, `Not paired`, `No SmartBuildOS Agent`, `Agent update required`, `Unknown (not registered with the Agent yet)` | Agent registration reply |
| `Property ID` | the id System Studio delivered, else `Not delivered yet (System Studio)` — the platform sends it from the release that includes its fix; a platform before that release does not, and this stays `Not delivered yet` (`KNOWN-ISSUES.md` KI-6) | configuration `property_id` |
| `Controller ID` | as above (sent from the same platform release; not by an older one) | configuration `controller_id` |
| `AI Provider` | display name, else `Not configured (System Studio)` | configuration `provider.name` |
| `AI Model` | display name, else `Not configured (System Studio)` | configuration `provider.model` |
| `AI API Credential` | the **status text** System Studio wrote (e.g. `Configured in System Studio · Anthropic ••••abcd`), else `Not configured`. Not an input; the driver never receives, stores or displays a key | configuration `credential_status` |
| `AI Status` | `Ready`, `Working: N request(s) waiting for a result`, `Degraded: <connection text>`, `Unavailable: <licence>`; `(learning paused)` and `— last request refused (<code>)` (or the cloud's reason in words: see the quick answer below) / `refused locally (<code>)` / `not delivered (<code>)` appended when they apply | state machine + last refusal |
| `Telemetry Status` | `Through the Agent: N sent, N acknowledged, N dropped; buffer N, buffer drops N`, or `No Agent answering: N critical event(s) buffered, N waiting in memory, N dropped`, or `Learning paused: …` | module client + buffer |
| `Learning Status` | `Off (not switched on in System Studio)` (the default: no valid configuration has switched learning on), `Active`, `Paused by <who>: <reason>` (`Paused by System Studio` — a document or `set_learning` said off; `Paused by System Studio: the configuration does not switch it on` — a valid document without `learning`; `Paused by configuration: vN refused` — an invalid document; `… the licence does not include AI_LEARNING`), `Stopped (not licensed)` | config / `set_learning` / licence |
| `Permission Mode` | `observe`, `recommend` or `execute_low_risk` + ` (set in System Studio)`, else `Not delivered yet (System Studio owns it)` | configuration `permission_mode` |
| `Flight Recorder Link` | `Installed: local history served; topics subscribed`, `Installed (no local history service; update the Flight Recorder)`, `Not installed: AI Core collects its minimal set itself`, `Unknown (needs Agent protocol 2)` | Agent directory |
| `License Status` | the licence SDK's one line (`sbos.license`) | Agent |
| `License Source`, `Subscription Tier`, `SmartBuildOS Company` | licence display set | Agent |
| `Last Synchronization` | last time the platform was heard (config applied, restricted operation, accepted cloud answer, Sync Now) | driver |
| `Last Test Result` | result line of Test Agent Link / Test AI Connection | actions |
| `Last Error` | last error or refusal, ≤ 240 bytes (cut between UTF-8 characters), `none` when clear | driver |
| `Touchscreen Detail` (editable) | `Basic (status and approvals only)`, `Standard (no household activity)` (default), `Household (only if the homeowner allows it)`: the `detail` a touchscreen ask carries (`basic` also switches the chat off). It can only LOWER what the homeowner allowed: household activity is answered only when the homeowner's portal switch is on (the cloud decides, ruling 8) | dealer |
| `Touchscreen Approvals` | one line: PIN Lock ready or why not (`unavailable (<reason>): chat and approvals off, use the portal`), the chat's detail and that it needs an owner PIN to view, whether the homeowner switched approvals on in the portal (from the last `approvals_pending`), how many page sessions are open | `webui:summary()` |
| `Webview Address` | `http://<controller>:47871/app (home network only)`, `Controller address unknown: set App Relay Address`, or `Not listening (port 47871 unavailable)` | relay |
| `App Relay Address` (editable) | `Auto` or the controller's LAN address (`lib.relayhost`, as PIN Lock and Atmosphere) | dealer |
| `Log Level` (editable) | `0 - Fatal` … `5 - Trace` | — |
| `Log Mode` (editable) | `Off`, `Print`, `Log`, `Print and Log` | — |

## 2. Actions

| Action | Command | Does |
| --- | --- | --- |
| `Test Agent Link` | `TEST_AGENT_LINK` | `SBOS_MODULE_DISCOVER` to the Agent; writes the Agent's version, protocol range, pairing, cloud state and module count to `Last Test Result` (or why it cannot: no Agent, protocol 1, failed with a code) |
| `Test AI Connection` | `TEST_AI_CONNECTION` | cloud op `test_provider`; `Last Test Result` says accepted (job id; the result arrives as AI Response Ready) or the refusal code |
| `Sync Now` | `SYNC_NOW` | re-registers if needed, drains the buffer, flushes staged events, re-reads the directory, sends a status frame (which carries `applied_config_version`), and (protocol 2) calls cloud op `status`, whose body is `{request_id}` only — the platform takes no other field (`rpc/ops.ts` `OP_BODIES.status`) and refuses an unknown one |
| `Republish App URL` | `REPUBLISH_URL` | sends the page's URL (`URL_CHANGED` on binding 5001) again; Navigator applies it the next time the tile opens |
| `Print Diagnostics` | `PRINT_DIAGNOSTICS` | prints state, Agent link, licence, configuration, learning, Flight Recorder link, collection plan, every counter, pending jobs and bus counters to the Lua output |

## 3. Composer commands

Parameters arrive as strings. Every value is validated; an over-long typed text
is **refused**, not cut. Lengths are counted in **characters** (Unicode code
points), as the platform counts them (`rpc/ops.ts` `[...t].length`), not in
bytes. A refused command sends nothing, sets `Last Error` /
`AI_LAST_ERROR` and `AI Status` (`refused locally (<code>)`). At most 10
commands a minute (local token bucket; the 11th is refused `rate_limited`).
`ROOM` is a room **name or id** resolved against `C4:GetDevices` (rooms are
known through the devices in them); a typed `ROOM` longer than 64 characters is
refused (`… (use the room id)`). LIST labels normalise to codes
(`Last 7 Days` → `last_7_days`); an empty optional LIST takes its default, an
empty required one is refused `<PARAM>: is required`.

**Text sent to the cloud** (`aicore.commands.sanitise`). The platform refuses
the WHOLE request (`invalid_args`) for one text field that is longer than its
bound, or that contains a character of `UNPRINTABLE` (U+0000–U+0008,
U+000B–U+001F, U+007F–U+009F, U+2028, U+2029). So every text field of every
cloud-op body is cleaned before it is sent: every C0 control (TAB and LF too),
DEL, every C1 control, U+2028 and U+2029 becomes a space; a byte that is not
well-formed UTF-8 is dropped; the ends are trimmed with the platform's (JS
`trim`) whitespace set. Names Director supplies are then **cut** on a character
boundary (never inside a multi-byte character) to the platform's bound —
`room_name` 64, `device_name` 120 characters — and a name with nothing
printable left is not sent. Typed text (`QUESTION`, `STATEMENT`, `VALUE`,
`OCCASION`, `TITLE`, `MESSAGE`, `NAME`, `DETAIL`) is cleaned the same way and
**refused** over its bound; `body()` applies every bound again as a last guard
(`BODY_TEXT_MAX`). Labels the driver writes into envelopes (bounded at 120
bytes by the envelope) are cut between characters too.

| Command | Parameters (type, bound) | Cloud op | Feature |
| --- | --- | --- | --- |
| `AI_ASK` | `QUESTION` STRING ≤ 500, required; `ROOM` STRING, optional | `ask` | `BASE` |
| `AI_ANALYZE_ROOM` | `ROOM` STRING, required | `analyze_room` | `BASE` |
| `AI_ANALYZE_SYSTEM` | — | `analyze_system` | `BASE` |
| `AI_RECORD_EVENT` | `NAME` STRING ≤ 120, required; `DETAIL` STRING ≤ 400, optional; `ROOM` STRING, optional; `CATEGORY` LIST (General, Lighting, Comfort, Media, Security, Access, Safety, Energy, Presence, System, Programming, Maintenance), optional, default General | none — recorded as `ai_core.record`. A dealer's explicit marker, **not learning** (architect's ruling 2026-11-18): recorded whether learning is off, on or paused; still refused for an excluded room (`… is excluded by the AI Core configuration`) or category (`not recorded (excluded_category)`); bounded and cleaned like all typed text; the cloud's learning engine never learns from it (it reads only `observation.change`) | `BASE` |
| `AI_SET_CONTEXT` | `KEY` LIST (Occupancy, Guests Present, Vacation, Quiet Hours, Special Event, Cleaning, Maintenance Window), required; `VALUE` STRING ≤ 120, required | `set_context` (the key is `key` in the cloud body, `context_key` in the envelope) | `BASE` |
| `AI_LEARN_PREFERENCE` | `STATEMENT` STRING ≤ 300, required; `ROOM` STRING, optional | `learn_preference` (refused while learning is off) | `AI_LEARNING` |
| `AI_SUGGEST_SCENE` | `ROOM` STRING, required; `OCCASION` STRING ≤ 120, required | `suggest_scene` | `BASE` |
| `AI_GENERATE_REPORT` | `TYPE` LIST (System Health, Usage, Energy, Security, Comfort, Device Reliability), **required**; `PERIOD` LIST (Today, Last 24 Hours, Last 7 Days, Last 30 Days), **required** — no defaults | `generate_report` | `BASE` |
| `AI_START_DIAGNOSTIC` | `DEVICE` DEVICE_SELECTOR **or** `ROOM` STRING (exactly one; `DEVICE` `0`, Composer's empty selector, counts as none) | `start_diagnostic` (after the local diagnostic, §8) | `BASE` |
| `AI_SEND_NOTIFICATION` | `TITLE` STRING ≤ 80, required; `MESSAGE` STRING ≤ 400, required; `AUDIENCE` LIST (Homeowner, Integrator, All), optional, default Homeowner | `send_notification` (recipients decided by the platform) | `BASE` |
| `AI_RUN_HOUSEHOLD_ANALYSIS` ("Run Household Analysis") | — | `analyze_household` — runs the household analysis (patterns, memories, recommendations); answered once, never by `deliver_result` (below) | `AI_LEARNING` |

Room exclusions: a command whose room (or whose device's room) is excluded by
configuration is refused `not_permitted`, except `AI_ASK` and
`AI_SEND_NOTIFICATION` (the cloud decides those).

Flow of a cloud command: validate → new `request_id` (`aic-<uuid>`,
`AI_LAST_REQUEST_ID`) → `ai_core.command` envelope (evidence `requested`,
correlation id = request id) → `client.cloudRequest(op, body,
{idempotency_key = request_id})` → the Agent POSTs
`/api/integrations/control4/modules/rpc`. Body: `{command, request_id,
<normalised args>}` (+ `room_id`/`room_name`, `device_id`/`device_name`). The
body names are the platform's (`src/lib/ai-core/rpc/ops.ts` `OP_BODIES`, which
refuses the whole request for an unknown key): the context key is `key` in the
`set_context` body, and `context_key` only in the envelope (§15).

The quick answer (`aicore.commands.interpret`):

| Answer | Meaning | Shown |
| --- | --- | --- |
| `status=ok`, `result.accepted=true` with a `job_id` (a non-empty string or a number) | accepted as a job; the job waits for `deliver_result` (≤ 20, 30 min) | `AI Status` Working; `AI_STATUS` `working` |
| `status=ok`, `result.accepted=true`, `job_id` null or absent | **completed** now: nothing will be delivered later, so no job is tracked and `AI Response Ready` is never fired for it (`set_context`, `send_notification`, `learn_preference` when the platform records it) | `AI Status` stays Ready; counter `cloud_completed`; `last_cloud_result` `<COMMAND>: completed` |
| `status=ok` without `accepted=true` | **not** success (`cloud_refused`) | Last Error `…answered without accepting…` |
| `not_permitted`, `invalid_args`, `unsupported`, `payload_too_large`, `agent_not_paired`, `cloud_refused`, other | refused, not retried | Last Error `refused by SmartBuildOS: <code>`; AI Status `— last request refused (<code>)` |
| the same, with `result.reason` a short token (`^[a-z][a-z0-9_]*$`, ≤ 40 bytes, no part over 20 bytes or with four digits in a row), e.g. the platform's `cloud_refused` + `not_entitled` for an unlicensed controller | refused, not retried; the code is kept for counters, `last_cloud_result` and `AI_STATUS` | Last Error `refused by SmartBuildOS: <words> (<reason>)` (`vocab.REFUSAL_REASONS`; a reason without words: `<code> (<reason>)`); AI Status `— last request refused (<words>)`; Last Test Result `AI connection: refused (<words>)`. No other field of `result` is shown, and any other `reason` is ignored |
| `rate_limited` (the platform's per-system limits on `send_notification` and `test_provider`, or the Agent's bucket; after the client's 2 retries, same key) | refused: an answer, not silence | Last Error `rate limited by SmartBuildOS (rate_limited); try again later`; the connection state is not touched |
| `cloud_unreachable`, `deadline_exceeded`, `target_unavailable` (after the client's 2 retries, same key) | not delivered | Last Error `no answer from SmartBuildOS (<code>)`; `cloud_unreachable` also sets the connection state |
| `incompatible_protocol` | v1 Agent | refused locally before sending when the Agent is v1 |

What each cloud op answers (`rpc/ops.ts`, `rpc/status.ts`): `ask`,
`analyze_room`, `analyze_system`, `suggest_scene`, `generate_report`,
`start_diagnostic`, `test_provider` → a job; `set_context`,
`send_notification` → completed (`job_id: null`); `learn_preference` →
completed when the platform's memory library is wired, else `unsupported`;
`status` (Sync Now) → its own synchronous object (no `accepted`), read as a
successful sync. `Test AI Connection` shows `test accepted (job …); result
follows as AI Response Ready` for a job, `answered by SmartBuildOS (no result
follows)` without one, and `refused (<code>)` for a refusal.

### Run Household Analysis (`AI_RUN_HOUSEHOLD_ANALYSIS` → `analyze_household`)

The programming action that runs the household analysis (the platform's
pattern detectors, memories and recommendations) when the dealer's
programming says so; the platform can also run it on a schedule the dealer
chooses in System Studio. It is **not** `AI_ANALYZE_SYSTEM`, whose op
`analyze_system` is an AI health review answered by `deliver_result`.

Wire (module contract v2, existing `SBOS_MODULE_CLOUD_REQUEST` frame; no new
frame): op `analyze_household`, body exactly `{command:
"AI_RUN_HOUSEHOLD_ANALYSIS", request_id}`, `idempotency_key = request_id`.
The request is recorded first as an `ai_core.command` envelope (evidence
`requested`). The op is in the Agent's `MODULE_CLOUD_OPS.ai_core`
(`src/sbos/modulepolicy.lua`) and the driver's `vocab.CLOUD_OPS`.

Before anything is sent (in this order; each refusal sends nothing and is
shown as `refused locally (<code>)` with the reason in Last Error):

1. licence: `AI_LEARNING` (the same gate as every command: refused under a
   definitive denial, or when an enforced authorised licence lacks the
   feature; uncertain states fail open) → `not_permitted`;
2. one request in flight at a time (an unanswered one stops blocking after
   3 min; the module client gives up well before) → `rate_limited`;
3. one **accepted** run per 60 minutes from this controller
   (`household_accepted_at`, persisted: a restart does not reset it; a clock
   that moved backwards does not block) → `rate_limited`, Last Error names
   when the next is allowed. Only an accepted answer starts the hour: a local
   refusal, a cloud refusal, offline or a timeout leave it untouched;
4. the shared 10-a-minute bucket and the Agent-protocol check, as every
   command.

Whether learning is allowed is **not** checked on the controller: the
platform's settings are the source of truth and the controller's copy can
lag (KI-7); the platform answers `learning_not_allowed`.

The answer (`aicore.commands.interpretHousehold`). No job is ever held, no
`AI Response Ready` fires, `AI_STATUS` stays `ready`:

| Answer | Shown (`last_cloud_result`, AI Status, Last Error / `AI_LAST_ERROR`) |
| --- | --- |
| `ok`, `{accepted: true, state: "queued", job_id}` — **the normal case**: the gates are decided before the answer and the analysis runs after it | `AI_RUN_HOUSEHOLD_ANALYSIS: accepted (queued)`; counter `cloud_accepted`; starts the hour. The driver is **never told when the run finishes**; the result appears in System Studio |
| `ok`, `{accepted: true, state: "completed"}` | `…: completed`; counter `cloud_completed`; starts the hour |
| `ok`, `accepted: true`, `state` missing or unknown | plain `…: accepted` — never `completed`; starts the hour |
| `ok` without `accepted: true` | `refused (cloud_refused)` |
| `error`, `result.reason` = `rate_limited` (error_code `rate_limited`, `result.retry_after_seconds`), `learning_not_allowed`, `not_licensed`, `already_running`, `not_permitted` (error_code `not_permitted`), `invalid_args` (error_code `invalid_args`), or a reason added later | `refused (<reason>)`; Last Error `refused by SmartBuildOS (<reason>)` (+ `; SmartBuildOS allows the next run in about N minute(s)` with `retry_after_seconds`). A reason that is not a lower-case code is ignored and `error_code` is shown |
| `error`, `not_permitted` with **no** `result.reason` | the Agent refused the op itself (its policy lacks `analyze_household`; the platform always names its reason for this op): Last Error `the SmartBuildOS Agent refused it (not_permitted): update the SmartBuildOS Agent …` |
| `error`, another code without a reason | `refused (<code>)` |
| `cloud_unreachable`, `deadline_exceeded`, `target_unavailable`, `incompatible_protocol` | as every command (table above) |

The typed reason travels in `result.reason` because the Agent passes only
its `CLOUD_PASSTHROUGH` codes through `error_code` (anything else becomes
`cloud_refused`) but relays `result` on an `ok:false` answer
(`modulebus.cloudAnswer`; tested in `test/test_sbos_modulebus.lua` [9]).

## 4. Composer events

Ids are permanent. Registered from XML and again with `C4:AddEvent` at start.

| Id | Event | Fired when |
| --- | --- | --- |
| 1 | `AI Response Ready` | `deliver_result` (or `raise_event ai_response_ready`); never for a request the cloud completed at once (§3) |
| 2 | `Pattern Detected` | `raise_event pattern_detected` |
| 3 | `Recommendation Available` | `raise_event recommendation_available` |
| 4 | `Automation Conflict Detected` | `raise_event automation_conflict_detected` |
| 5 | `Device Failure Pattern Detected` | `raise_event device_failure_pattern_detected` |
| 6 | `Approval Required` | `raise_event approval_required` |
| 7 | `Action Completed` | `raise_event action_completed` |
| 8 | `Action Failed` | `raise_event action_failed` |
| 9 | `Agent Disconnected` | this driver only: `AGENT_CONNECTED` goes true → false (registration lost, Agent restarted, or the Agent stopped answering the liveness probe). Not raisable by the platform |
| 10 | `AI Provider Error` | `raise_event ai_provider_error`; also sets `AI_LAST_ERROR` / `Last Error` to `AI provider error: <detail>` (cleared by the next `deliver_result`) |

## 5. Variables and conditionals

Variables (ids fixed, order frozen):

| Id | Variable | Type | Value |
| --- | --- | --- | --- |
| 4000 | `AI_STATUS` | STRING | state code (§6) or `working` |
| 4001 | `AI_LAST_RESPONSE` | STRING | last delivered result, ≤ 1024 **bytes** (not characters: an accented letter is 2 bytes, an emoji 4). A longer result keeps its first ≤ 1021 bytes, cut between two UTF-8 characters, followed by `...` (`aicore.operations.boundResponse`) |
| 4002 | `AI_LAST_RESPONSE_ID` | STRING | its `response_id` |
| 4003 | `AI_LAST_REQUEST_ID` | STRING | the last command's `request_id` |
| 4004 | `AI_LAST_EVENT_DETAIL` | STRING | `raise_event` detail (≤ 512 bytes, cut between UTF-8 characters) or the Agent Disconnected reason |
| 4005 | `AI_PENDING_APPROVALS` | NUMBER | from `deliver_result` / `raise_event` `pending_approvals` |
| 4006 | `AI_RECOMMENDATION_COUNT` | NUMBER | from `recommendation_count` |
| 4007 | `AGENT_CONNECTED` | BOOL | registered and answering |
| 4008 | `LEARNING_ACTIVE` | BOOL | learning on (`false` until a valid configuration or `set_learning` switches it on) |
| 4009 | `AI_LAST_ERROR` | STRING | as `Last Error` (empty when clear); includes the platform's AI provider error (`raise_event ai_provider_error`) |
| 4010 | `AI_LAST_CORRELATION_ID` | STRING | the `correlation_id` of the last `raise_event` (for an approval or action event, the platform's action id); set to empty by an event without one, so it never names an earlier event's subject. Not part of the brief's ten: added so programming and support can tie `Approval Required` / `Action Completed` / `Action Failed` to the action in System Studio |

All except `AI_STATUS`, `AGENT_CONNECTED` and `LEARNING_ACTIVE` (recomputed
at start) are persisted and repainted after a reload.

Conditionals (BOOL): `AI_READY` (state `ready`), `AGENT_CONNECTED`,
`LEARNING_ACTIVE` (learning on and licence not halted), `APPROVALS_PENDING`
(`AI_PENDING_APPROVALS` > 0), `RECOMMENDATIONS_AVAILABLE`
(`AI_RECOMMENDATION_COUNT` > 0).

## 6. State machine

`aicore.state.code(facts)`; first match wins:

| Code (`AI_STATUS`) | Condition | `SmartBuildOS Connection Status` |
| --- | --- | --- |
| `no_agent` | no `smartbuildos.c4z` found (licence SDK's 3-tier discovery) | `No SmartBuildOS Agent in this project` |
| `agent_update_required` | the Agent negotiated protocol 1 (or refused with max 1) | `SmartBuildOS Agent update required (module contract v2)` |
| `agent_lost` | registered, but the liveness probe got no directory by its deadline | `SmartBuildOS Agent not responding` |
| `registering` | Agent found, registration not accepted yet | `Registering with the SmartBuildOS Agent` |
| `agent_unpaired` | the Agent reports `paired=false` | `SmartBuildOS Agent not paired` |
| `cloud_unreachable` | the Agent reports `connected=false`, or the last cloud call ended `cloud_unreachable` | `SmartBuildOS cloud unreachable` |
| `unlicensed` | `license.enforces()` (definitive denial with enforcement on) | `Connected (not licensed)` |
| `ready` | none of the above (`AI_STATUS` = `working` while jobs are pending) | `Connected` |

Transitions: every change of code emits one `ai_core.status` envelope
(severity `warning` for any code other than `ready`/`unlicensed`, which makes
it critical for the buffer). `AGENT_CONNECTED` true → false fires
`Agent Disconnected`.

Lifecycle: LateInit registers (`SBOS_MODULE_REGISTER` with the v2 manifest),
the module client retries every 30 s doubling to 5 min; on
`SBOS_MODULE_AGENT_HELLO` it re-registers (new token) and re-subscribes; on
`SBOS_MODULE_DIRECTORY_CHANGED` it re-reads the directory 2 s later. A
liveness probe (`SBOS_MODULE_DISCOVER` filtered to `flight_recorder`) runs
every 5 min and every 30 s while the Agent is not answering; failure →
`agent_lost` + a re-registration attempt; the first answer → flush the buffer.
Persisted across Director reload, driver update and controller restart:
configuration + version + last refusal (`aicore_config_v1`), learning state
(`aicore_learning_v1`), the buffer (`aicore_buffer_v1`), last result/request/
detail/error/sync (`aicore_last_v1`), and the envelope sequence
(`sbos_module_seq`, `sbos.seqblock`: may skip, never repeats).

## 7. Restricted operations (from the platform)

Delivered by the Agent's `MODULE_COMMAND` runner as `SBOS_MODULE_COMMAND`
(`MODULE_COMMANDS.ai_core`, registered by this driver). States reported with
`SBOS_MODULE_COMMAND_RESULT`: `Accepted` (module client), `Executing`, then
`Completed` / `Failed`. Each operation accepts a **closed set of argument
keys**; any other key refuses the whole operation (`Failed`). None runs
code or takes a command name to forward; `run_driver_query` and
`invoke_driver_action` hand a read-only query / a person-approved action to
the driver that DECLARED it (§7a); `read_device_state` reads ONE device's
variables and filters them here (§7c).

| Operation | Arguments | Effect |
| --- | --- | --- |
| `apply_config` | `config` (object), `version` (integer) | as §9; `Completed` / `Failed` with the refusals; status frame with `applied_config_version` / `config_error`. A version **older** than the one in force is `Completed` as `superseded` and changes nothing (a queued operation can arrive after the Agent forwarded a newer document). System Studio sends it when exclusions change, with the document it just published |
| `refresh_status` | — | repaint, `ai_core.status` envelope, status frame |
| `deliver_result` | `response_id` (id, required), `text` (≤ 4000, required), `request_id`, `job_id`, `kind` (`answer`, `analysis`, `report`, `scene_suggestion`, `diagnostic`), `pending_approvals`, `recommendation_count` (0–9999) | sets `AI_LAST_RESPONSE` (bounded), `AI_LAST_RESPONSE_ID`, counts; clears the pending job; fires `AI Response Ready` |
| `raise_event` | `event` (one of `ai_response_ready`, `pattern_detected`, `recommendation_available`, `automation_conflict_detected`, `device_failure_pattern_detected`, `approval_required`, `action_completed`, `action_failed`, `ai_provider_error`), `detail` (≤ 512 bytes, cut between UTF-8 characters; control characters removed), `pending_approvals`, `recommendation_count`, `correlation_id` (optional; 1–96 characters, no control characters — the envelope's rule; anything else refuses the operation) | sets `AI_LAST_EVENT_DETAIL`, `AI_LAST_CORRELATION_ID` (empty without one), counts; records one `ai_core.event` envelope whose `correlation_id` is it; fires the event; `ai_provider_error` also sets `AI_LAST_ERROR` (`AI provider error: <detail>`, or `… (no detail from SmartBuildOS)`), which the next `deliver_result` clears. Anything else → `Failed`, nothing fired |
| `set_learning` | `active` (boolean), `reason` (≤ 120), `config_version` (whole number ≥ 0, optional: the configuration version this change was published as) | learning on/off at once (on needs `AI_LEARNING` when enforced, and is `Failed` while the last document was refused); re-plans collection. Precedence with the document in §9. System Studio sends it when learning is paused, resumed, switched on or off |
| `run_diagnostic` | exactly one of `device_id`, `room_id`; `note` | the local diagnostic (§8; the target's Director name cleaned and bounded as in §3); `Executing` then `Completed` with the envelope id and how many local events |
| `run_driver_query` | `query_ref` (lower-case uuid), `module_id` (`^[a-z][a-z0-9_]{2,47}$`, never `ai_core`), `instance_id` (digits), `query_id` (`^[a-z][a-z0-9_]{0,47}$`), `params` (object, ≤ 6 keys `^[a-z][a-z0-9_]{0,31}$`, each a string ≤ 64 characters without control characters, a finite number or a boolean; `{}` when absent) | licence `BASE`; `ai.query` to that instance (§7a); `Executing`, then `Completed` / `Failed` on the driver's answer; the answer goes back as cloud op `driver_query_result` |
| `invoke_driver_action` | `ai_action_id` (lower-case uuid), `module_id`, `instance_id`, `action_id`, `params` (as above), `declaration_hash` (16 lower-case hex: the declaring driver's describe hash) | licence `AI_ACTIONS`; the Agent refuses it below Remote Control *Comfort*; only to a module the Agent **verified**; `ai.action` to that instance (§7a); `Completed` only when the driver answered `ok`; the real outcome goes back as cloud op `driver_action_result` |
| `read_device_state` | `state_ref` (lower-case uuid), `device_id` (a JSON whole number 1..2147483647; text is refused), `scope` (`system` or `full`), `variables` (optional array of ≤ 12 distinct names, each `^[A-Za-z0-9 _.-]{1,48}$`; absent or `[]` = every variable that passes the filter) | read-only, no Remote Control tier; licence `BASE`; ONE `C4:GetDeviceVariables`, filtered here (§7c); `Completed` with the count of values and of omissions, or `Failed` with the reason; the answer goes back as cloud op `device_state_result` |

Proof that no path reaches equipment: `test/test_aicore_driver.lua` [19] and
`test/emulator/ai_core.lua` [14] record every `C4:SendToDevice` the driver
makes over the whole run — all go to the Agent — and that
`SetDeviceVariable`, `SendToProxy`, `SendUIRequest`, `RegisterDeviceEvent`
and `Bind` are never called, including with equipment-shaped arguments.

## 7a. Report hub (`ai_core.report` v1) and driver queries / actions

Every SmartBuildOS root driver reports to AI Core with `sbos.aireport`
(`docs/DRIVER_PLATFORM_GUIDE.md` §9). AI Core's manifest advertises
`{id: "ai_core.report", version: 1, kind: "request"}`; the Agent's policy
lets any registered module call it (`requesters = ANY`). Code:
`src/aicore/reports.lua` (pure) and `drivers/smartbuildos-ai-core/driver.lua`
(`onReport`, `flushReports`, `relayDriverOp`). **Emulator and unit tests
only: nothing here has run on a physical controller.**

**Receiving.** A report is `args = {v: 1, kind, …}` with closed keys
(`docs/protocol/MODULE-CONTRACT-V2.md`). The sender is the module id and
instance id **the Agent stamped** on the request; a report that names a
sender itself has an unknown key and is refused. Each report is checked
against the shapes the platform accepts in `driver_reports`
(`P:src/lib/ai-core/drivers/wire.ts`), because there one bad item fails the
whole batch:

| Check | Refused as |
| --- | --- |
| `v` ≠ 1 (a higher whole number) | `unsupported_version` |
| `v` missing / not 1, kind not `describe`/`state`/`event`/`diagnostic`, a missing or unknown key, an id / key / enum value / param that breaks its rule, `at` not epoch seconds (whole, 2001–2100), a describe `hash` not 16 lower-case hex, an empty summary / description / title / label / vocabulary word / driver name / version / file (the platform requires text) | `invalid` |
| the report over 16 KB, a describe over 8 KB (encoded) | `too_large` |
| per instance per rolling minute: more than 6 `state`, 10 `event`, 6 `diagnostic`; the same describe hash again within 10 minutes | `rate_limited` |

Free text (summary, labels, titles, descriptions, event / diagnostic text,
fact and data strings) is data: bidi characters removed, every character the
platform refuses (C0 incl. newline and tab, DEL, C1, U+2028/2029) turned into
a space, trimmed, cut to its bound in code points. It is never interpreted.

**Answer** (what the helper consumes): `{accepted, ai_core: {state,
version}, reason?, need_describe?}`. `ai_core.version` is this driver's
`driver_version` as the Agent's directory lists it. `state`: `unlicensed`
when the licence blocks `BASE` (then `accepted` is always false and nothing
is kept), else `agent_unpaired` / `cloud_unreachable` from §6, else `ready`.
`need_describe: true` whenever AI Core holds no describe for that sender —
always after an AI Core restart, since describes are not persisted — and the
helper re-sends its describe at once on seeing it.

**What AI Core keeps (memory only).** Per reporting instance, at most 48
(the least recently heard is evicted, counted): the describe hash and when
it came, the driver's name / version / file, the declared query and action
ids, the latest state facts (≤ 32) and when, per-kind counts and the
per-minute windows. Waiting for upload: the latest describe (≤ 8 KB) and
latest state per instance (latest wins, counted `coalesced`), and one ring of
200 events and diagnostics (drop-oldest, counted).

**Uploading.** Cloud op `driver_reports`, body `{request_id, reports:[…],
dropped?}`: ≤ 64 items, ≤ the 16 KB cloud body, describes first, then
states, then events and diagnostics oldest first. Each item is the report
flattened with the stamped sender: `{from_module_id, from_instance_id, v: 1,
kind, …the kind's keys}`. `dropped` (sent only when above 0) counts every
report AI Core dropped since the last delivered batch: refused (over budget,
invalid, oversize), ring overflow, evicted, or in a batch the cloud refused.
A 20 s timer asks; a batch goes only when something waits, none is in flight
and fewer than **3** went in the last 60 s — inside the Agent's per-module
cloud bucket (20 a minute, burst 10). An answered batch is delivered; one
that never arrived (`cloud_unreachable`, `deadline_exceeded`,
`target_unavailable`, `rate_limited`, `agent_not_paired`) goes again later
(the module client already retried it twice); any other answer is a
refusal (the platform branch's `driver_reports` handler is built and tested
in simulation, not deployed; a platform built without the driver-report
store answers `not_permitted` with `result.reason` `unavailable`, and a
platform older than this op answers `unsupported`, KI-46): its
events and diagnostics are dropped, counted. **A describe or a state counts
as uploaded only when the cloud accepted the batch that carried it**: after
a refusal, a timeout or an unreachable cloud it waits again for the next
batch (latest per instance: a newer describe or state that arrived meanwhile
replaces it; ruling 23).
After any batch that did not land the next one backs off: 60 s, doubling per
consecutive failure up to 10 minutes; a delivered batch resets it. Against a
cloud that keeps refusing, the steady state is one batch every 10 minutes
(6 an hour), each carrying the waiting describes plus whatever states,
events and diagnostics are waiting, which are then dropped and counted (the
ring keeps the newest 200 meanwhile). Nothing is uploaded while the licence
blocks `BASE`.

**`run_driver_query` / `invoke_driver_action`.** AI Core reads the target's
directory row at that moment: it must exist (`unknown_target`), be live and
protocol 2 (`target_unavailable`), advertise `ai.query` / `ai.action`
(`capability_not_found`) and, for an action, be **verified** by the Agent's
identity binding (`not_permitted`, `target_unverified`). Then one request,
never retried (an action must not run twice), 10 s for a query, 20 s for an
action, idempotency key = `ai_action_id`. An `ai_action_id` runs once per AI
Core run (`duplicate_request` after that); at most 8 driver operations in
flight (`rate_limited`). The declaring driver's own helper validates the
params against its declaration and refuses a changed `declaration_hash`.

| Driver's answer | `driver_query_result` | `driver_action_result` |
| --- | --- | --- |
| `ok`, `{ok: true, data}` / `{ok: true, result_text}` | `completed`, `data` (scalars / arrays / objects ≤ 3 deep; strings lose refused characters) | `completed`, `result_text` |
| `ok`, `{ok: false, …}` (its handler could not) | `failed`, `internal_error` | `failed`, `internal_error`, `result_text` = the driver's words |
| an error (`invalid_args`, `not_permitted` + `reason: declaration_changed`, …) | `failed`, that code | `failed`, that code, `result_text` = the helper's reason (`declaration_changed`, `requester_unverified`, `unknown_action`, …) |
| no answer by the deadline | `failed`, `deadline_exceeded` | `failed`, `deadline_exceeded`, `result_text` says the outcome is unknown |
| refused here (licence, unverified, not found, duplicate, busy) | `failed`, the code | `failed`, the code, `result_text` = `not_licensed` / `target_unverified` / `target_not_found` / `target_not_responding` / `not_declared` / `already_invoked` / `busy` |
| a query answer that does not fit the 16 KB cloud body | `failed`, `payload_too_large` (never cut) | — |

"Sent" is never reported as done: the operation stays `Executing` until the
driver answers or the deadline passes. Both result ops go once per operation
(the module client retries a lost one twice); a result that still cannot be
delivered is logged, not stored (KNOWN-ISSUES KI-44).

## 7c. Live device read (`read_device_state` → `device_state_result`)

**Round two: on `feat/ai-core-round2` only** (not in pull request #49).

**What a touchscreen can be told, in short.** The touchscreen chat reads at
scope `system` unless the homeowner's portal switch for household answers is
on (an owner PIN alone does not widen it). At `system` only temperature,
humidity, battery, signal quality, online status and the temperature scale
(`SCALE`) leave the home, through the allow-lists below; locks, security,
doors (opening), motion, contacts, relays, lights and cameras are refused
before anything is read out. Cameras are refused in every scope. No energy
value exists anywhere (the platform holds the AI to saying so). With the
switch on, or in the portal for a signed-in homeowner, the existing household
rules decide (scope `full`). The platform's tools over this read are
`devices.get_state` and `devices.health` (fixed tool set 39 on the
platform's round-two branch, 37 on the frozen one).

The platform's tool `devices.get_state` asks for ONE device's current
values. AI Core reads them once and decides, **on the controller, before
anything leaves the home**, what may be sent. Code:
`src/aicore/devicestate.lua` (pure: `classify`, `filter`, `bound`,
`result`) and `drivers/smartbuildos-ai-core/driver.lua`
(`OPS.read_device_state`). **Emulator and unit tests only: nothing here has
run on a physical controller.** Read-only: the operation writes no
variable, sends no command, registers no listener and runs nothing it is
sent (`test/test_aicore_driver.lua` [20]/[20b] ratchet).

**Steps.** (1) licence `BASE`, else `not_licensed`; (2) a local bucket of
12 a minute (above the platform's 6, so a platform retry never collides),
else `busy`; (3) the device in `C4:GetDevices({})` (its driver file name),
else `not_found`; (4) one `pcall(C4:GetDeviceVariables, id)`: an error is
`read_failed`, nothing or an empty table `no_variables`; (5) the class from
the live variable names (D); (6) a camera is refused in every scope; a
restricted class in scope `system` is refused with **no variable and no
count** in the body; (7) the filter (A, C, F, B) and the bound; (8) one
`device_state_result` with a new idempotency key. The read itself is never
retried (the module client may re-send the same result under the same key).

**The class (D)**, from the variable names, matched in their joined form
(upper-case, non-alphanumerics removed, so `LockStatus` is `LOCK_STATUS`)
and present even with an empty value — both only ever make an answer more
restrictive. First match wins: `camera` (driver file name containing
`camera`, `doorbell`, `nvr`, `protect-camera`, or a variable whose joined
name contains `STREAM` or `SNAPSHOT`, or `AVAILABLE_CAMERAS`), `lock`,
`security`, `opening`, `motion`, `contact`, `relay` (the Agent's
`sensorReading` lists), `thermostat` (the Agent's `looksLikeThermostat`),
`light` (`src/telemetry/lights.lua` `signature`), `leak`, `power`,
`battery` (the Agent's lists), `climate_sensor` (any name starting
`TEMPERATURE` or `HUMIDITY`), else `unknown`. The device's own name is never
used. `test/test_aicore_devicestate_parity.lua` fails when the Agent's lists
and AI Core's copy differ.

**Restricted classes (E):** `lock`, `security`, `opening`, `motion`,
`contact`, `relay`, `camera`, `light` (conductor ruling: on/off is presence)
and `unknown`. In scope `system` they are answered `failed` /
`restricted_class`, except `unknown`, which gets the base allow-list below.
Every other class answered in scope `system` also goes through an
allow-list (F).

**What is dropped, and counted (`omitted`):**

| Rule | Scope | Counted as |
| --- | --- | --- |
| A — a name containing a secret fragment (the Flight Recorder's 14 `FIXED_EXCLUSIONS` plus `PASSPHRASE`, `PRIVATEKEY`, `AUTH`, `BEARER`, `SESSION`, `COOKIE`, `CERT`) or a secret token (`PIN`, `CODE`, `CODES`, `KEY`, `KEYS`, `PWD`, `PASS`, `OTP`, `NONCE`, `JWT`, `HMAC`) | every | `secret` |
| A — a personal-data token (`USER`, `USERS`, `USERNAME`, `LOGIN`, `ACCOUNT`, `OWNER`, `GUEST`, `PERSON`, `NAME`, `EMAIL`, `MAIL`, `PHONE`, `MOBILE`, `SMS`, `CONTACT` unless `STATE` follows, `ADDRESS`, `STREET`, `CITY`, `ZIP`, `POSTAL`, `LATITUDE`, `LONGITUDE`, `GPS`, `LOCATION`, `URL`, `URI`, `HOST`, `IP`, `MAC`, `SSID`, `WIFI`, `SERIAL`, `STREAM`, `RTSP`, `SNAPSHOT`, `CAMERA`, `HISTORY`, `LOG`, and the joined `FIRSTNAME`, `LASTNAME`, `FULLNAME`, `USERID`, `TELEPHONE`, `HOSTNAME`, `IPADDRESS`, `MACADDRESS`, `EMAILADDRESS`, `ZIPCODE`, `POSTCODE`, `PHONENUMBER`) | every | `personal` |
| C — an occupancy token (`OCCUPANCY`, `OCCUPIED`, `PRESENCE`, `AWAY`, `HOME`, `VACATION`, `MOTION`, `LAST`, `ARRIVAL`, `DEPARTURE`, `DOORBELL`, `RING`, `VISITOR`) | `system` | `occupancy` |
| B — a table, a non-finite number; a string with `<`, `{`, `[`, a control, C1, line-separator or bidi character | every | `non_scalar` |
| B — a string over 64 bytes (dropped whole, never cut); a name over 48 bytes | every | `too_long` |
| B — `://`, `www.`, an `@` with a dot after it, IPv4, a MAC, a phone shape (≥ 7 digits once spaces, `+`, `-`, `(`, `)` are removed, when it is not a plain number) | every | `personal` |
| B — a token shape (20+ characters of `[A-Za-z0-9+/=_-]` with no space) | every | `secret` |
| F — outside the class's allow-list for the scope (below) | `full` (lock, security); `system` (every class answered) | `not_allowed` |
| bound — beyond 40 variables or 4,096 bytes of `variables` JSON (a conservative estimate: non-ASCII bytes ×3, `"` and `\` ×2) | every | `over_limit` |

Tokens come from two splits of the name — on non-alphanumerics, and also at
camelCase and letter/digit boundaries (`OwnerName` → `OWNER NAME`, `Pin1` →
`PIN 1`); a token rule matches in either.

**Allow-lists (F)**, matched on the joined name: `lock` in scope `full` —
`LOCKSTATUS`, `LOCKSTATE`, `LOCKED`, `BATTERYLEVEL`, `BATTERYSTATUS`,
`LOWBATTERY`, `LINKQUALITY`, `LQI`, `RSSI`; `security` in scope `full` —
`PARTITIONSTATE`, `ARMSTATE`, `ARMEDTYPE`, `ALARMSTATE`, `TROUBLE*`,
`BATTERY*`, `LOWBATTERY`. In scope `system` **every class that is
answered** goes through an allow-list (fail closed, KI-68 closed): the base
list is `unknown`'s — `TEMPERATURE*`, `HUMIDITY*`, `SCALE`, `BATTERY*`,
`LOWBATTERY`, `LINKQUALITY`, `LQI`, `RSSI`, `ONLINE`, `CONNECTED`,
`COMM*STATUS` — and `climate_sensor` gets exactly that list. `SCALE`
(added on `feat/ai-core-round2` after `1a663b1`) is exactly the name the
Agent's `thermostatReading` reads as its `scale` (`devicestate.SCALE_NAME`;
the parity test ties the two), so a climate sensor or thermostat carries its
temperature unit when the device has one; nothing else joined the list; `thermostat`
adds the 26 names the Agent's `thermostatReading` reads (and already uploads:
setpoints, `HVAC_MODE` / `HVAC_STATE`, fan and humidity modes, `SCALE`, …;
`THERMOSTAT_READ_NAMES`, kept equal by the parity test); `leak`, `power` and
`battery` add their own signature lists (battery: the battery, low-battery
and link lists). A class without an entry gets the base list. So a name
nobody reviewed for that class — a wine fridge's `DOOR_AJAR`, a sensor's
`IN_USE` — never reaches the touchscreen; it is counted `not_allowed`
(the test fixture's wine fridge sends temperature, humidity and `SCALE`;
its door flag is withheld and counted)
(the count only, never the name; KI-67 closed). Scope `full` is unchanged: deny-lists
for every class except `lock` and `security`. A name that A or C drops is
counted first.

| Class | Scope `system` before (to `64660fb`) | Scope `system` now |
| --- | --- | --- |
| `camera` | refused | refused |
| `lock`, `security`, `opening`, `motion`, `contact`, `relay`, `light` | refused (`restricted_class`) | refused (`restricted_class`) |
| `unknown` | base allow-list | base allow-list |
| `climate_sensor` | deny-lists only: any unreviewed name passed | base allow-list |
| `thermostat` | deny-lists only | base + `THERMOSTAT_READ_NAMES` |
| `leak` | deny-lists only | base + leak signature |
| `power` | deny-lists only | base + power signature |
| `battery` | deny-lists only | base + battery, low-battery and link signatures |

`variables` in the operation
narrows further (case-insensitive exact names); a narrowed-to name that a
rule drops is still dropped and counted.

**Values** are sent as Director holds them (strings), never converted:
`TEMPERATURE` on a thermostat is deci-Celsius and goes as it is;
`TEMPERATURE_F` / `TEMPERATURE_C` as named. Nothing is filled in.

**`device_state_result` body:**

| Outcome | Keys |
| --- | --- |
| completed | `request_id`, `state_ref`, `status: "completed"`, `read_at` (controller epoch seconds of the read), `device: {id, class, restricted}`, `variables: [{name, value}]` (possibly `[]`), `omitted: {secret, personal, occupancy, non_scalar, too_long, over_limit, not_allowed}` (all seven, always; whole numbers, never a name; the platform takes `not_allowed` as an optional key) |
| failed after a read (`restricted_class`, `camera_not_supported`) | `request_id`, `state_ref`, `status: "failed"`, `read_at`, `device: {id, class, restricted: true}`, `reason`, `error_code` |
| failed after a read attempt (`read_failed`, `no_variables`) | `request_id`, `state_ref`, `status: "failed"`, `read_at`, `reason`, `error_code` |
| failed before a read (`not_licensed`, `busy`, `not_found`) | `request_id`, `state_ref`, `status: "failed"`, `reason`, `error_code` |

`restricted` is true when the class is restricted and was answered only
because the scope is `full`; `unknown` in scope `system` reports false.
`reason` → `error_code`: `not_found` → `unknown_target`, `no_variables` →
`unsupported`, `restricted_class` → `not_permitted`,
`camera_not_supported` → `unsupported`, `not_licensed` → `not_permitted`,
`busy` → `rate_limited`, `read_failed` → `internal_error`.

**Honesty.** `read_at` is when the controller read the device. Control4
does not say when a value last changed, and a battery device's value may
be one Director cached long ago; nothing in the body implies otherwise.
Whether a protocol driver's id exposes its proxy's variables, the real
variable names of batteries and appliance sensors, and the read's wall time
on a large project are unmeasured (`KNOWN-ISSUES.md` KI-63 – KI-66).

## 7b. Touchscreen page: status, PIN-gated chat, PIN approvals (D5)

A Navigator tile with a driver-hosted page, built the way PIN Lock and
Atmosphere build theirs: a primary `uibutton` proxy on binding 5001 (so the
driver carries **no `<combo>`**), `web_view_url`
`controller://driver/smartbuildos-ai-core/app/index.html`,
`mobile_web_view_enabled` `true` (as Atmosphere; the page says it works only
on the home network), the shared SmartBuildOS icons, and a LAN relay
(`C4:CreateServer` on **47871**, `OnServerDataIn`, Atmosphere's
`uirelay.parse`/`render`). The page is embedded (`make embed-pages` →
`src/aicore/page.lua`; OS 4.3 refuses a driver its own c4z files) and served
same-origin at `/app`. Its URL `http://<controller>:47871/app?k=<install
token>` is published with `URL_CHANGED` at start and again 60 s later; the
install token is 32 hex from `C4:HMAC`, persisted encrypted. Every rule is in
`src/aicore/webui.lua` (pure); the driver supplies the socket, the bus, the
cloud and the facts. **Nothing here has run on a controller or a Navigator.**

**Routes** (all but `/ping`, `/app` and `OPTIONS` need `k`; all but
`/session` also need the page session token `s`, minted by the driver):

| Route | Body (closed keys) | Answer |
| --- | --- | --- |
| `GET /ping` | — | `{ok, service:"ai-core"}` |
| `GET /app` | — | the page, its CSP completed for this controller |
| `POST /session` | — | `{ok, s}` (≤ 4 sessions; the least recently seen is evicted) |
| `GET /state` | — | `{ok, status:{licensed, provider_configured, online, learning_active, text}, approvals:{count, screen_count, portal_only_count, enabled, can_review, text, message?}, pin:{available, reason, message, retry_in?}, chat:{available, locked, message?, …}, prompt?, review?, notice?}`; `chat` carries `conversation`, `suggestions`, `explain`, `locks_in`, `detail` **only for an unlocked session** |
| `POST /chat/unlock` | `{}` | `{ok, waiting}` — asks PIN Lock for a `chat_view` challenge |
| `POST /pin/done` | `{challenge_id}` | `{ok}` — redeems the challenge (`pinlock.redeem`) |
| `POST /pin/cancel` | `{}` | drops the PIN prompt |
| `POST /chat/lock` | `{}` | locks this session now |
| `POST /chat/touch` | `{}` | interaction: the unlock stays 5 more minutes |
| `POST /ask` | `{question}` (≤ 500) or `{suggestion_id}` (a built-in id or a current preset id `p<index>-<rev>`) or `{explain:true}` | `{ok, id}` or `{ok:false, reason, message}` (`unknown_suggestion` for a stale or unknown id) |
| `POST /approvals/refresh` | `{}` | asks `approvals_pending` (≤ 1 per 30 s) |
| `POST /approvals/next` | `{}` | `{ok, waiting}` — an `approval` challenge for the first item this screen may review |
| `POST /approvals/decide` | `{decision: approve\|decline}` | `{ok}` — the outcome follows in `/state` `notice` |
| `POST /approvals/close` | `{}` | drops the item and its proof |
| `POST /session/close` | `{}` | ends the session (the page sends it on `pagehide`) |

A body with a `pin` key is refused (400) on every route before anything
reads it; every other unknown key is refused too. Business refusals are HTTP
200 `{ok:false, reason, message}` where `message` is plain words from the
closed table `webui.TEXT` (an unknown reason becomes a generic sentence that
says to use the portal, never the code).

**The chat lock (ruling 17), enforced in `webui.lua`.** A session is unlocked
only by a `chat_view` proof: AI Core mints a nonce, asks PIN Lock for a
challenge (`purpose:"chat_view"`, `subject` = the session's own 32-hex id,
which is not its token), hands the page `challenge_id` and `verify_url`
through `/state`, the page posts the PIN to `verify_url`, then `/pin/done`
makes AI Core redeem the challenge over the bus; only `{verified:true,
role:"owner", verified_at:<epoch s>}` creates the proof. The unlock ends
after **5 minutes without interaction** (a poll is not interaction; the page
sends `/chat/touch` at most every 30 s while the person uses it), on
`/chat/lock` (the button, and the page when it is hidden), when the page
closes (`/session/close`, or no request for **75 s**), on a driver restart
(memory only), and for every session at once when PIN Lock stops being
available. While locked, `/state` carries no question, answer, suggestion or
explain action, `/ask` is refused (`chat_locked`), and no other route returns
conversation content (asserted on response bodies in
`test_aicore_webui.lua` [7]).

**Conversation bounds.** Per session, in memory only: the last 10
exchanges; a question ≤ 500 characters; an answer ≤ 2048 bytes; cleared
after 15 minutes without interaction; a question still unanswered after 5
minutes is shown as failed. An answer that arrives while the session is
locked is **held** in that session (within the same 10 / 15-minute bounds)
and shown at the next unlock; if the session is gone it is dropped
(counted). A touchscreen answer never reaches `AI_LAST_RESPONSE`, the
persisted last response or *AI Response Ready*, and a touchscreen question
is not recorded as an envelope.

**Asking.** The existing cloud op `ask` with `channel:"touchscreen"` and
`detail` (`Touchscreen Detail`), `command:"TOUCHSCREEN_ASK"`. The answer
arrives through the existing `deliver_result`, matched by `request_id`.
Suggested questions are a closed list in `webui.SUGGESTIONS`; *Explain what
just happened* is a fixed question (`webui.EXPLAIN_QUESTION`). Asks take from
the shared Composer command bucket (10 a minute) and the page's own bucket
(4 a minute).

**The dealer's preset questions (round two, D-R2b; on `feat/ai-core-round2`
only — on `feat/ai-core` the suggestions are the three built-ins).** Staff set up to 6 in
System Studio; they arrive as `touchscreen.presets` in the configuration
document (§9). They are shown **in addition to** the three built-in
questions — first, then the built-ins — and **only to an unlocked chat
session**: while locked, no route returns any preset text (asserted on
response bytes, `test_aicore_webui.lua` [15]). In `/state` each is
`{id:"p<index>-<rev>", label:<the preset's text>}` inside `chat.suggestions`.
`rev` changes whenever the list changes (and starts from the controller
clock at driver start), so an id issued for an older list is refused with
`unknown_suggestion` — it is never mapped to whatever question now sits at
that index. `POST /ask {suggestion_id}` with a current id sends **exactly
the preset's text** through the same `ask` (channel `touchscreen`, the same
buckets). Labels are set with `textContent` only; a suggestion button wraps
a 120-character label inside the page (`max-width: 100%`, `white-space:
normal`, `overflow-wrap: anywhere`) — how it wraps on a real Navigator is
unmeasured (KI-70). Homeowners neither see nor edit presets outside the
unlocked chat. A document without the key means no presets.

**Approvals (rulings 2, 4, 21, 24).** `approvals_pending` (on session open,
on refresh at most every 30 s, when older than 60 s while a page is open,
and after `pending_approvals` changes in `deliver_result`/`raise_event`)
gives a count and refs; the refs never reach the page. *Review next item*
picks the first eligible ref not decided in this session and asks PIN Lock for
an `approval` challenge with `subject` = that ref. After the redeem, AI Core
holds a proof for **that one ref**, **60 s** from `verified_at`, and calls
`approval_detail` with `verification:{nonce, verified_at, role, method:
"pin_lock"}` (the challenge's nonce). The page shows title, description and
risk (text only). *Approve*/*Decline* call `approval_decide` with the
detail's `args_hash` and the same verification; the proof is deleted first,
whatever the answer (single use). A new item always needs a new PIN. A chat
unlock never approves (decide looks only for an `approval` proof for that
ref) and an approval PIN never unlocks the chat. `queued`/`denied`/`failed`/
`expired` and every refusal reason are shown in words; what the screen
cannot decide says to use the SmartBuildOS portal. Detail, decide and
refresh take from the shared command bucket.

**Fail closed.** PIN Lock is usable only when the Agent's directory lists a
`pin_lock` that is live (not stale, protocol 2), **verified** by the Agent,
advertises `pinlock.availability`/`challenge`/`redeem`, and answers
`pinlock.availability` with `{ready:true, reason:"ready"}` (checked at most
every 30 s while a page is open). Otherwise — not installed, not verified,
stale, needs an update, not answering, or `starting`, `off`, `unlicensed`,
`no_owner_pin`, `relay_unavailable`, `locked` (with `retry_in`) — the chat
is unavailable, no approval is offered, every unlock and proof ends, and the
page says to use the portal. A `verify_url` that is not
`http://<this relay's host>:47831/verify` is never handed to the page.

**Page security.** The page's CSP is `default-src 'none'; script-src
'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src
'self'; base-uri 'none'; form-action 'none'`; when AI Core serves `/app` it
adds PIN Lock's origin on the same host (`http://<host>:47831`) to
`connect-src` and nothing else. No third-party resource, no storage, no
`innerHTML` anywhere: every string is set with `textContent`. The PIN pad
shows dots; the PIN is serialised once, posted only to a `verify_url` the
page checked against its own host and port 47831 (as `text/plain`, so the
browser sends no preflight), and cleared before the request leaves. Relay
bounds: one request ≤ 8 KB (a body ≤ 4 KB), 90 requests a minute per session,
6 PIN prompts a minute for all sessions, ≤ 4 sessions. The relay never logs
a body.

## 8. Local diagnostics

`AI_START_DIAGNOSTIC` / `run_diagnostic`: when the Flight Recorder is present
and advertises the capability, ask it over contract v2
(`events.device_history {device_id, limit: 25}` or `events.room_activity
{room_id, limit: 25}`, timeout 10 s, 1 retry). Then record **one**
`ai_core.diagnostic` envelope:

```
payload = { request_id, source, target,
  flight_recorder = { available = true, capability, truncated, held, capacity,
                      oldest_available, events = [{event_id | no_event_id, at, kind, line}], omitted },
  note = "local Flight Recorder history only; causes are not inferred on the controller" }
```

Summaries are cut from the oldest end to fit the 4 KB envelope payload; the
cut is counted in `omitted`. When there is nothing to attach the envelope
says why: `flight_recorder_not_installed`, `flight_recorder_has_no_local_history_service`,
`flight_recorder_unknown_agent_cannot_discover`, or `request_failed` with
`error_code`. For `AI_START_DIAGNOSTIC` the cloud op `start_diagnostic`
follows with `diagnostic_event_id`, `local_event_ids` and
`flight_recorder_available`.

### Flight Recorder local history (served by the Flight Recorder, Part A)

The Flight Recorder (manifest `sbos.flight_recorder`) advertises
`events.query`, `events.timeline`, `events.device_history`,
`events.room_activity` (requests) and `events.subscribe` (topic over
`capture.`, `observation.`, `trace.`). Not advertised: correlation, incident
analysis, period comparison (cloud-side). Code: `src/flightrecorder/localquery.lua`.

| Capability | Arguments (closed) | Default order |
| --- | --- | --- |
| `events.query` | `limit` 1–200 (50), `cursor`, `order` `asc`/`desc`, `from`, `to` (epoch s), `since_seq`, `kinds` (`event`, `change`, `trace`, `mark`, `system`, `note`), `device_id`, `room_id`, `text` (≤ 64) | desc |
| `events.timeline` | `limit`, `cursor`, `from`, `to` (default the last 15 min; window ≤ 31 days), `kinds` | asc |
| `events.device_history` | `device_id` (required), `limit`, `cursor`, `order`, `from`, `to` | desc |
| `events.room_activity` | `room_id` (required), `limit`, `cursor`, `order`, `from`, `to` | desc |

Answer: `{capability, events, count, has_more, order, truncated, retention,
window?}` plus the contract `cursor` when more remain (`h<generation>.<a|d>.<seq>`;
refused after Clear Local History). Each event: `seq`, `event_id` (the
envelope id the platform stores) **or** `no_event_id` (`over_upload_budget`
— held locally but never uploaded; `not_recorded` — recorded before ids were
kept), `at`, `t`, `kind`, `event_type`, device/room ids and labels, and the
kind's fields (a device event's Composer event number is `device_event_id`).
`retention = {source, policy, capacity, held, newest_seq, evicted_total,
history_generation, recording_status, oldest_available{seq, at}}`.
`truncated = true` when older matching entries may have existed but are no
longer held. Pages stay under ~20 KB (hard cap 24 KB, measured by encoding).
Answered whatever the recording state; never synthesised. Against a v1-only
Agent nothing changes (no `require_protocol`).

## 9. Configuration (`SBOS_DRIVER_CONFIG`, SKU `SBOS_AI_CORE`)

Forwarded by the Agent (`SKU_FILENAMES.SBOS_AI_CORE`); acknowledged with
`SBOS_DRIVER_CONFIG_ACK` (`applied`, `refused` count, `settings_version`) and
a status frame with `applied_config_version` / `config_error`. The same
document can arrive by `apply_config`.

Whichever way a document arrives (the Agent's heartbeat copy, the cached copy
the Agent replays when AI Core registers again, or `apply_config`), one
**older** than the version in force is not applied and changes nothing: over
`SBOS_DRIVER_CONFIG` it is not acknowledged at all (neither applied nor
refused), and `apply_config` answers `Completed` as `superseded`. The same
version again is re-applied.

```json
{
  "schema": 1,
  "learning": { "active": true },
  "exclusions": { "rooms": [12, 40], "categories": ["security"] },
  "permission_mode": "observe | recommend | execute_low_risk",
  "provider": { "name": "Anthropic", "model": "…" },
  "credential_status": "Configured in System Studio · Anthropic ••••abcd",
  "collection": {
    "system_events": true,
    "flight_recorder_topics": true,
    "agent_events": true,
    "variables": [ { "device_id": 12, "variable": "LIGHT_STATE" } ],
    "max_events_per_minute": 60
  },
  "property_id": "…",
  "controller_id": "…",
  "touchscreen": { "presets": ["Is the wine cellar at the right temperature?"] }
}
```

Rules (`aicore.config`): every key optional, and what a document does not say
is **not switched on** (the defaults below); **unknown keys refuse the document**; any key anywhere
whose name is credential-shaped (`api_key`, `token`, `secret`, … —
`sbos.envelope.isSensitiveKey`) refuses it; display strings are bounded
(`provider.name` 40, `provider.model` 80, `credential_status` 96), have no
control characters, and are refused if they look like a key (`sk-…`,
`Bearer …`, long opaque blobs); `exclusions.rooms` ≤ 500 ids (the platform's
own bound, so every saved list arrives whole);
`exclusions.categories` from the closed list (`general`, `lighting`,
`comfort`, `media`, `security`, `access`, `safety`, `energy`, `presence`,
`system`, `programming`, `maintenance`, `unknown`); `variables` ≤ 32, never a
code- or credential-named variable; `max_events_per_minute` 1–300;
`touchscreen` an object with only `presets`: a list of at most **6**
strings, each **3–120 characters** and ≤ 360 bytes, one line of plain text
(no control, C1, line-separator or bidi character, no `<` or `>`, no `://`
or `www.`, no leading or trailing space), refused if it looks like a key
(long opaque blobs, `Bearer …`, and — round two, the rule the platform
applies identically — an `sk-` at the start or after a character that is not
an ASCII letter or digit, followed by at least 8 of `[A-Za-z0-9_-]`, i.e.
`(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}`; so "Is the desk-lamp on?" is
accepted and "key: sk-proj-12345678" is refused; the three display strings
above keep the stricter `sk-` rule), and no two alike ignoring case and spacing. One bad
field refuses the whole document; the last valid one stays in force and
`Last Error` says `Configuration vN refused: <path>: <reason> (vM kept)`.
`learning.active` is the platform's latest word on learning.

**Precedence between `set_learning` and the document.** The document is the
source of truth. `set_learning` exists so a pause (or a resume) takes effect
on the controller at once instead of at the next configuration delivery; it
previews document version `config_version`:

1. `config_version` given and ≤ the version in force → ignored (`Completed`,
   `configuration vN already decides learning`): the document already says it,
   or says something newer. A late or repeated operation can never undo a
   newer document.
2. Otherwise it is applied now and **held until** a document of at least
   `config_version` is applied (without `config_version`: until a document
   newer than the one in force). A document older than that — re-forwarded,
   or delayed — is applied in every other respect but does not change
   learning.
3. The first document of at least that version decides learning, whatever
   the preview said.
4. Switching learning **on** is refused while the last document was refused
   (the controller cannot know the platform's settings); switching it off is
   always accepted.

The held state (`until_version`) is persisted with the learning state and
survives a restart. So the two can disagree only until the next document
arrives, and System Studio publishes that document before it queues the
operation. Tests: `test/test_aicore_learning_default.lua` [9];
`test/emulator/ai_core.lua` [7a].

**Where the document comes from.** System Studio builds it from the
property's AI Core settings (`src/lib/ai-core/settings/settings.ts`
`driverConfigDocument`, with a mirror of every rule above in
`settings/driver-config.ts`, and refuses to publish anything that mirror
refuses):

| Key | From |
| --- | --- |
| `learning.active` | `learning_enabled` and not paused (a homeowner's pause is "off" here; the cloud keeps the two apart) |
| `exclusions.rooms` | `excluded_room_ids` as stored. A room is the same thing on both sides: a **Director room id** — the integer an envelope's and a command's `room_id` carries here (`aicore.collector.admit`, `aicore.commands.build`) and the one the platform compares in `flight_recorder_events.room_id` when it learns. The homeowner's room list is read from `flight_recorder_events` for that reason (not `control4_devices.room_id`, which is a uuid column and empty) |
| `exclusions.categories` | `excluded_categories` translated from the platform's learning categories to this driver's: `lighting` → lighting; `climate`, `shades` → comfort; `media` → media; `occupancy` → presence; `device_health` → system, maintenance; `security` → security, access, safety; `scenes`, `keypad`, `other` → none (no driver event carries them; the cloud alone enforces those) |
| `permission_mode` | as stored |
| `provider` | display name of the provider in force and its deep model; omitted when none |
| `credential_status` | the status line; without the last four characters if they would look like a key here |
| `collection` | system events, Flight Recorder topics and Agent events on, no own variables, 60 a minute — the platform has no per-source setting; learning off stops all of it here regardless |

`property_id` and `controller_id` are sent from the platform release that
includes its fix for them (not merged at the time of writing); an older platform
does not send them, and the two properties stay at `Not delivered yet`
(`KNOWN-ISSUES.md` KI-6). `touchscreen.presets` (round two) is sent **only** to
a controller whose `ai_core` module row lists `read_device_state` among its
commands (the round-two driver), so an older driver — which refuses an unknown
key, and with it the whole document — never sees it (platform P-R2b; spec round
two §3.2). The golden documents
(`tests/unit/fixtures/ai-core-driver-config/*.json` in the platform) are checked
against `driverConfigDocument()` on the platform and fed to this validator by
`test/test_aicore_platform_parity.lua` [10].

**Defaults** — with no configuration, for a field a valid document leaves out,
and (for learning) after an invalid document. Each is the conservative value:
the most private, the least capable.

| Field | Default | Effect of the default |
| --- | --- | --- |
| `learning.active` | **`false`** (off) | no collection at all (below), `AI_LEARN_PREFERENCE` refused, `LEARNING_ACTIVE` false, `Learning Status` `Off (not switched on in System Studio)`. A valid document with `learning.active: true` turns it on; a valid document without `learning` leaves it off (`Paused by System Studio: the configuration does not switch it on`); an **invalid** document turns it off (`Paused by configuration: vN refused`) while the rest of the last valid document stays in force — the refused document may be the one that switched learning off |
| `collection.system_events` | `false` | no Director system event registered |
| `collection.flight_recorder_topics` | `false` | no subscription to the recorder's topics |
| `collection.agent_events` | `false` | Agent events not recorded |
| `collection.variables` | `[]` | no variable listener |
| `collection.max_events_per_minute` | `60` | an upper bound on own observations; it switches nothing on |
| `exclusions.rooms` / `exclusions.categories` | `[]` / `[]` | nothing excluded — exclusions only narrow what learning and the collection sources allow, and with the defaults nothing is collected |
| `permission_mode` | none (`Not delivered yet (System Studio owns it)`) | display only on the controller; the platform's own default is `observe` |
| `provider.name`, `provider.model`, `credential_status` | none (`Not configured (System Studio)`, `Not configured`) | display only |
| `property_id`, `controller_id` | none (`Not delivered yet (System Studio)`) | display only |
| `touchscreen.presets` | `[]` | no preset questions; the page offers the three built-ins only |
| `schema` | `1` | the only schema |

What learning gates (`aicore.collector.plan`, `admit`): every own observation
(Director system events, Agent events and variables when the recorder is
absent), the Flight Recorder topic subscription and its consumption, and
`AI_LEARN_PREFERENCE`. Not gated by learning — the non-learning features:
`AI_RECORD_EVENT` (a dealer's marker; `admitMarker` applies only the
exclusions), every other Composer command and its cloud op, the
local diagnostic (`AI_START_DIAGNOSTIC`, `run_diagnostic` ask the Flight
Recorder for its local history on demand), restricted operations, status
envelopes, Test/Sync actions.

## 10. Event collection (D7: no double capture)

What the Flight Recorder captures, read from its source
(`drivers/smartbuildos-flight-recorder/driver.lua`, `src/tracer/tracer.lua`,
`src/flightrecorder/{recorder,config,traces}.lua`), and what AI Core does:

| Class | Flight Recorder | AI Core when FR present (v2) | AI Core when FR absent |
| --- | --- | --- | --- |
| Composer device events, every catalogued device (`C4:RegisterDeviceEvent`) | `capture.event` (within its upload budget) | consumes topic `capture.` | **not collected** (needs the recorder's catalogue; documented gap) |
| Device/room variables selected in Studio (`C4:RegisterVariableListener`) | `observation.change` / `observation.initial` | consumes topic `observation.` | own listeners for `collection.variables` only (default none) → `ai_core.observation.variable` |
| Programming markers and traces (`RECORD_EVENT`, `START_TRACE`, …) | `observation.programmed`, `trace.*` | consumes `observation.` / `trace.`; `AI_RECORD_EVENT` is AI Core's own marker (`ai_core.record`; recorded with learning off too, §3) | `AI_RECORD_EVENT` only |
| Agent-classified events (`SBOS_MODULE_AGENT_EVENT`) | `observation.system`, only when selected as a source | left to the recorder | recorded → `ai_core.observation.agent` |
| Director system events (`C4:RegisterSystemEvent`) | **not captured** | own collector, always | own collector, always |

Own system events (documented ids only, registered system-wide with device
0): 17 `OnNetworkBindingAdded`, 18 `OnNetworkBindingRemoved`, 19
`OnNetworkBindingRegistered`, 20 `OnNetworkBindingUnregistered`, 48
`OnDeviceOnline`, 49 `OnDeviceOffline` (severity warning → critical), 90
`OnDirectorIPAddressChanged` → `ai_core.observation.system` with the
undocumented payload kept as bounded unreviewed text.

An old (v1) recorder or an unknown one (v1 Agent, cannot discover) is
treated as present for collection: AI Core does not duplicate its classes.

Consumed events are **not re-uploaded** (they already reach the cloud
through the recorder's own upload); AI Core uses them locally (counters,
dedup) only.

Before anything is recorded or consumed, `aicore.collector` applies, in
order: learning off (the default, §9) or licence halted → nothing (and the subscription,
system-event registrations and variable listeners are released); excluded
room; excluded category; event-id dedup (ring of 512); per-minute budget
(own observations only). Events never claim who caused a change, the
previous value, or that a programming item executed — DriverWorks does not
provide those; unknown stays unknown (category `unknown`).

## 11. Outbound envelopes (`ai_core.` prefix, envelope v1)

| Event type | Evidence | When |
| --- | --- | --- |
| `ai_core.command` | `requested` | each cloud command (payload `command`, `op`, `request_id`, `args`) |
| `ai_core.record` | `instrumented` | `AI_RECORD_EVENT` (severity warning for security/safety) |
| `ai_core.status` | `derived` | each state change and `refresh_status` (payload `state`, `previous_state`, counts) |
| `ai_core.event` | `system` | each `raise_event` (label = the event; envelope `correlation_id` = the operation's `correlation_id` when given; payload `event`, `detail`, `correlation_id`, `operation_request_id`, counts; severity warning for `action_failed` and `ai_provider_error`, else info) |
| `ai_core.observation.system` | `system` | own system events |
| `ai_core.observation.agent` | `system` | Agent events, recorder absent |
| `ai_core.observation.variable` | `initial` / `observed` | own variable listeners, recorder absent |
| `ai_core.diagnostic` | `derived` | §8 |

Payload keys never use names the envelope redacts (`code`, `key`, …). Every
payload string is cut to 512 bytes and every label to 120 bytes **between two
UTF-8 characters** before the shared envelope sees it
(`aicore.commands.boundPayloadText`, `cutBytes`; the cut marks the envelope
`partial`): `sbos.envelope` cuts by bytes and can split a character, and the
Agent then refuses the whole frame as malformed (`KNOWN-ISSUES.md` KI-1). A
typed text that fits the platform's bound in characters can exceed 512 bytes
(an `AI_ASK` question of 500 three-byte characters is 1500 bytes): the cloud
body carries it whole; only the envelope's copy is cut.

## 12. Buffering, health, limits

* Normal path: module client stage (≤ 300, frames of ≤ 100, 30 s ack, 3
  tries) → the Agent's durable acknowledged queue → `/events`.
* No Agent answering (not installed, registering, not responding): critical
  envelopes (severity ≥ warning) go to the persisted buffer (50, dedup by
  `event_id`, evict least severe then oldest, every drop counted); the rest
  wait in the module client's memory stage (lost on restart, counted when
  dropped). The buffer drains oldest first on registration, on the first
  answered probe, and on every tick while answered. Envelopes carry
  `sequence`; the platform orders by it.
* `SBOS_MODULE_STATUS` counters: `events_recorded`, `events_buffered`,
  `events_staged`, `events_sent`, `events_dropped`, `events_unrecordable`,
  `buffer_depth`, `buffer_dropped`, `buffer_flushed`, `requests`, `refusals`,
  `cloud_accepted`, `cloud_completed`, `cloud_refused`, `cloud_unreachable`,
  `last_cloud_result`, `results_delivered`, `events_raised`, `operations`,
  `operations_refused`, `liveness_failures`, `jobs_expired`, `jobs_dropped`,
  `system_events`, `variable_events`, `agent_events`, `collector_*`,
  `applied_config_version`, `config_error`, `learning_active`,
  `flight_recorder`, `flight_recorder_subscribed`, `report_modules`,
  `reports_accepted`, `reports_refused`, `reports_pending`, `reports_dropped`,
  `report_batches_sent`, `report_batches_delivered`, `report_batches_refused`,
  and `bus` (module client). Print Diagnostics adds every hub counter
  (`hub_*`) and one line per reporting module.
* Licence (`sbos.license`, SKU `SBOS_AI_CORE`): commands, `run_diagnostic`
  and collection stop only when `license.enforces()` (a definitive denial
  with enforcement on). A missing feature refuses only when enforcement is
  on **and** the status is authorised (the feature list is then definitive).
  Grace, trial, legacy, cloud-validation-required and no-answer states fail
  open. Features gated on the controller: `BASE` (every command but
  `AI_LEARN_PREFERENCE` and `AI_RUN_HOUSEHOLD_ANALYSIS`, `run_diagnostic`,
  Test AI Connection) and `AI_LEARNING` (`AI_LEARN_PREFERENCE`,
  `AI_RUN_HOUSEHOLD_ANALYSIS`, `set_learning` on, `learning.active` in the
  configuration), `BASE` also for reports and `run_driver_query`, and
  `AI_ACTIONS` for `invoke_driver_action`. `AI_CONCIERGE` gates nothing
  here (no concierge path); the platform enforces it.
  An assertion the Agent cannot verify is dropped and the SKU answers
  `LEGACY` (operational). The Agent's licence inventory keeps the **set of
  instances** per SKU: removing one instance of a driver keeps the SKU while
  another remains, and every instance is told its licence
  (`SbosInventoryInstances`, `drivers/smartbuildos/driver.lua`). Updates: the Agent's updater (`DRIVER_FILENAMES`;
  store `sku_for`).
* Limits (characters = code points): question 500, statement 300, name 120,
  detail 400, value 120, occasion 120, title 80, message 400, room name 64,
  device name 120; (bytes) result text 4000, `AI_LAST_RESPONSE` 1024 (`...`
  included), event detail 512, error 240; 10 commands a
  minute; one accepted `AI_RUN_HOUSEHOLD_ANALYSIS` an hour and one in flight; 20 pending jobs for 30 min; cloud body 16 KB, request args 16 KB,
  result 24 KB (contract v2).

## 13. Verification

| What | Where |
| --- | --- |
| Driver under the shim with a scripted Agent (19 sections) | `test/test_aicore_driver.lua` (+ `test/aicore_harness.lua`) |
| `raise_event` `correlation_id`; every cloud answer shape per op (job, completed, unsupported, rate limited, status) | `test/test_aicore_cloud_answers.lua` |
| `AI_RUN_HOUSEHOLD_ANALYSIS`: licence, wire body, queued / completed / plain accepted, every refusal reason, the Agent's own `not_permitted`, offline, timeout, the in-flight and hourly guards (a refusal never uses up the hour), across a restart | `test/test_aicore_household_analysis.lua` [1]–[6]; answer mapping `test/test_aicore_commands.lua` [8]; the Agent relays `result.reason` `test/test_sbos_modulebus.lua` [9] |
| Names agree across XML, code, Agent tables, policy, docs | `test/test_aicore_surface.lua` |
| Per module | `test/test_aicore_{commands,config,operations,buffer,collector,state,diagnostic}.lua` |
| Learning off by default; absent / invalid / explicit-on / explicit-off configuration; non-learning features with learning off; Director names bounded end to end; `set_learning` / document precedence; `AI_RECORD_EVENT` with learning off, paused, on; envelope text cut between characters | `test/test_aicore_learning_default.lua` [1]–[11] |
| Report hub: validation against the platform's item shapes, answers, `need_describe`, rates, coalescing, ring and instance bounds, batches (≤ 64 items, ≤ 16 KB, ≤ 3 a minute, `dropped`), identity from the Agent's stamp, restart; `run_driver_query` / `invoke_driver_action` real outcomes, unverified target, timeout, duplicate, licence | `test/test_aicore_reports.lua` [1]–[7]; end to end `test/emulator/ai_core_reports.lua` |
| Packaging (squish closure; built `.c4z` when present) | `test/test_aicore_package.lua` |
| Flight Recorder local history | `test/test_flightrecorder_localquery.lua`, `test/test_flightrecorder_v2.lua` |
| Licensing as the driver sees it (statuses × enforcement, features, renewal, transfer, trial) | `test/test_aicore_licence.lua` |
| Store update selection for AI Core | `test/test_aicore_updates.lua` |
| Failure modes no other suite named (pairing, Agent cloud loss, missing history, approvals, refused operations) | `test/test_aicore_failure_modes.lua` |
| Malformed input, timers on destroy, persistence growth, tokens in Trace output | `test/test_aicore_robustness.lua` |
| Vocabularies against the platform's mirrors; every restricted-operation argument the platform sends against `operations.lua`; every cloud body the driver sends against `rpc/ops.ts` `OP_BODIES` (keys, required fields, enums, every text bound incl. `room_name`/`device_name`, the `UNPRINTABLE` character rule, bounds in code points), and each answer shape; the `raise_event` detail bound (characters there, bytes here: cut, never refused); the platform's golden configuration documents accepted whole by `config.lua` and landing in their expected state, wrong ones refused, the bounds mirror equal (needs `SBOS_PLATFORM_REPO`) | `test/test_aicore_platform_parity.lua` [1]–[10] |
| Real Agent + real Flight Recorder + AI Core, incl. licensing with real signatures and the platform's golden documents through `SBOS_DRIVER_CONFIG` ([7a]; needs `SBOS_PLATFORM_REPO`, skipped otherwise) (EMULATOR ONLY) | `test/emulator/run-ai-core.sh` → `test/emulator/ai_core.lua` |

Every item of the product brief's test list is mapped to a named test in
`TEST-MATRIX.md`; installation is in `INSTALLATION.md`, building and
releasing in `RELEASE.md`; every known issue and limitation, with its source,
in `KNOWN-ISSUES.md`.

## 14. Not verified on hardware

One physical controller has loaded this driver and shown its properties, with a
real SmartBuildOS cloud accepting its requests; no AI answer has been seen on
it, and the touchscreen page and the PIN flow were not opened. Nothing else in
this driver, the Flight Recorder's v2 service or module contract v2 has been
verified on hardware. The bench procedures are in `TEST-MATRIX.md` (hardware
validation plan). Owed on a bench:

* the whole driver on OS 3.3.2 and 4.x (LuaJIT load, `<script>` tag, squished modules);
* `C4:UUID("RANDOM")` output; BOOL variable values `"true"`/`"false"` as Composer conditions read them;
* `OnSystemEvent` payload format for ids 17–20, 48, 49, 90 (only the `name="…"` attribute is read);
* `RegisterVariableListener` first-callback behaviour (treated as `initial`);
* SendToDevice ordering, frame sizes near 24–32 KB, timer behaviour under Director load;
* the platform route `/api/integrations/control4/modules/rpc` (until deployed, the Agent gets 404 → `cloud_refused`);
* the report hub and driver queries / actions with real drivers on a controller (bus latency, memory with 48 reporting modules, the 20 s batch timer under Director load);
* `read_device_state` (§7c): whether `C4:GetDeviceVariables` on the id the platform sends (often the protocol driver's) returns the proxy's variables, the real variable names of locks, partitions, batteries and appliance sensors (every signature list is a candidate), the read's wall time on a large project, the controller clock behind `read_at`, queue + doorbell + bus latency against the platform's 15 s wait;
* persistence across a real power cut (Director's flush timing);
* the touchscreen page on a real Navigator (touch screen, T-series, the phone app): the tile, `URL_CHANGED`, the relay on 47871, the page's `fetch` to PIN Lock's `/verify` on another port (`KNOWN-ISSUES.md` KI-53), `pagehide`/`visibilitychange` delivery, the keypad at touchscreen size, and how a preset button wraps a 120-character question (KI-70).

## 15. Deviations from the brief / architecture

| Deviation | Reason |
| --- | --- |
| `AI_RECORD_EVENT` makes no cloud call; it is recorded as `ai_core.record` through the durable event path | `MODULE_CLOUD_OPS.ai_core` has no op for it; the event path is durable and deduplicated |
| No separate `ai_core.context` envelope | the context is already in the `ai_core.command` envelope of `AI_SET_CONTEXT`; a second envelope would duplicate it |
| Context key travels as `context_key` in the envelope, `key` in the `set_context` cloud body | `key` is redacted by the envelope's credential rules; the cloud body is not an envelope and the platform validates `key` |
| An 11th variable, `AI_LAST_CORRELATION_ID` (4010) | `raise_event` carries the platform's `correlation_id`; a variable is where a dealer can see and use it |
| `ROOM` is a STRING (name or id), not a room selector | the documented command parameter types have no room selector; DYNAMIC_LIST needs a 3.3 `GetCommandParamList` path that is unverified here |
| Device events are not collected when the Flight Recorder is absent | `RegisterDeviceEvent` needs per-driver event ids (the recorder's catalogue); duplicating that catalogue would be the double capture D7 forbids |
| Variables are collected by AI Core only when listed in `collection.variables` | no documented API identifies a device's proxy type reliably; System Studio selects |
| Agent-classified events are left to the recorder when it is present, even if it is not configured to record them | AI Core cannot read the recorder's configuration; recording them too would double-capture when it is |
| `Last Test Result` and `Flight Recorder Link` properties added | the four actions need a place to report; the recorder link is a state the brief requires to be clear |
| A driver action that its driver refused (`{ok: false}`) is `driver_action_result` `failed` with `error_code: internal_error` and the driver's words in `result_text`; `declaration_changed`, `target_unverified` and the other local reasons also travel in `result_text` | the platform's `error_code` is the closed module error vocabulary, which has no code for "the driver declined" or "the declaration changed" |
| `driver_reports` is sent without `command` (COMMON's optional key) | the batch is not a Composer command |
| The touchscreen routes differ from §2.1's `/approvals/begin`, `/approvals/open` and `/approvals/decide {ref}`: `/chat/unlock`, `/pin/done`, `/approvals/next` and `/approvals/decide {decision}` | ruling 17 adds the chat PIN; "Review next item" lets the driver pick the ref, so refs never reach the page; the PIN Lock answer is collected by polling `/state`, the transport's contract (`uirelay`), never by holding a socket |
| A touchscreen answer is kept out of `AI_LAST_RESPONSE`, its persisted copy and *AI Response Ready*; a touchscreen question is not recorded as an envelope | ruling 17: the chat requires a PIN to view; a Composer variable or a persisted value would show it unlocked |
| `App Relay Address` added beside the spec's `Webview Address` | `lib.relayhost` needs the dealer override every relay driver has; set the same value on PIN Lock |
| Cloud request ids (`aic-` + 32 hex) come from the `C4:HMAC` recipe (UUID, clock, counter, `math.random`), no longer from `C4:UUID` alone | the request id is the cloud relay's idempotency key; the emulator's `C4:UUID` repeats, which made an `approval_detail` reuse an `approvals_pending` answer and, once the page drew extra ids, an `AI_ANALYZE_SYSTEM` reuse an earlier answer (KI-60) |
| Agent liveness is a periodic directory request | DriverWorks gives no delivery acknowledgement; the directory request is the cheapest authenticated round trip the Agent answers |

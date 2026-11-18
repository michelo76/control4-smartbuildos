# SmartBuildOS AI Core — known issues and limitations

Every known issue and limitation of AI Core across the driver repo and the
platform, collected in one place, de-duplicated, each with the file it comes
from. "Open" means nothing in this branch fixes it. Everything here is from
simulation (unit tests under the C4 shim, the Director emulator) or from
reading the code: **no physical controller and no live AI provider** has run
any of it.

Sources: `DRIVER.md`, `TEST-MATRIX.md`, `RELEASE.md`, `INSTALLATION.md` (this
folder); the platform's `docs/ai-core/MIGRATIONS.md` and
`docs/ai-core/DRIVER-CONTRACT.md`; the code named per item.

## KI-1 The shared envelope cuts text by bytes and can split a character (open, shared library)

**What it does.** `src/sbos/envelope.lua`:

* `M.bound` (called by `M.build` on every payload) cuts any payload string
  longer than `LIMITS.text` (512) with `value:sub(1, 512)`;
* `M.build` cuts the label with `tostring(label):sub(1, LIMITS.label)` (120).

Both count **bytes** and cut at a byte, so a string whose 512th (or 120th)
byte falls inside a multi-byte UTF-8 character (any accented letter, CJK, an
emoji, `·`, `•`) keeps a partial sequence at its end. The envelope is then
marked `quality = "partial"`, but its text is no longer valid UTF-8.

**What follows (measured under the shim with the vendored `JSON.lua`).** The
module client encodes the frame and sends it; the Agent's
`EC.SBOS_MODULE_EVENTS` (`drivers/smartbuildos/driver.lua`) decodes it with
`JSON:decode`, which fails with `incomplete utf8 sequence`; the Agent answers
`malformed frame` and the module client counts **every** event of that frame
(up to 100) as dropped (`events_dropped_local`, `Agent rejected N event(s)`).
One long non-ASCII string loses its whole batch.

**Who is affected.** Every driver whose envelopes go through `sbos.envelope`:
the modules on `sbos.moduleclient` — **Flight Recorder**
(`drivers/smartbuildos-flight-recorder`: labels from device names, variable
values), **Usage Analytics**, **VenueFlow**, **MQTT Broker** — and the
**Agent** itself (`Envelope.build` for `agent.command_state`, whose `detail`
is also cut with `:sub(1, 400)` before it gets there). Any of them loses a
frame when a payload string over 512 bytes, or a label over 120 bytes, is cut
inside a character.

**AI Core.** It did **not** bypass this: an `AI_RECORD_EVENT` `DETAIL` (400
characters = up to 1600 bytes) or an `AI_ASK` question (500 characters = up
to 2000 bytes) reached the envelope over 512 bytes. Fixed for AI Core only in
this branch: `drivers/smartbuildos-ai-core/driver.lua` `record()` cuts every
payload string to 512 bytes and the label to 120 bytes **between characters**
(`aicore.commands.boundPayloadText`, `cutBytes`) before the envelope sees
them, and marks the envelope `partial` as the envelope would. Test:
`test/test_aicore_learning_default.lua` [11]. The shared library is unchanged.

**Proposed fix (not applied: it changes behaviour for every driver above).**
In `envelope.lua`, one helper and two call sites:

```lua
--- Cut to at most `max` bytes without splitting a UTF-8 character.
function M.cutUtf8(s, max)
  if #s <= max then
    return s
  end
  local cut = max
  while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return s:sub(1, cut)
end
-- M.bound:  return M.cutUtf8(value, M.LIMITS.text), true
-- M.build:  label = M.cutUtf8(tostring(label), M.LIMITS.label)
```

and the same for the Agent's `rec.detail = …:sub(1, 400)`. ASCII output is
byte-for-byte unchanged; a multi-byte cut loses at most 3 bytes more. Test it
with every offset 0–3 of 2-, 3- and 4-byte characters at both bounds and a
round trip through `JSON:encode`/`JSON:decode`, then run every module's suite
and both emulator scenarios. Once it ships, AI Core's own pre-cut becomes
redundant but harmless. Source: this closeout (`src/sbos/envelope.lua`,
`drivers/smartbuildos/driver.lua` `EC.SBOS_MODULE_EVENTS`,
`src/sbos/moduleclient.lua` `SBOS_MODULE_EVENTS_ACK`).

## Seams between the driver and the platform

| # | Issue | Status | Source |
| --- | --- | --- | --- |
| KI-2 | `raise_event` `detail`: the platform bounds it at 240 **characters** (`RAISE_EVENT_DETAIL_MAX`), the driver keeps 512 **bytes**. 240 four-byte characters are 960 bytes: the driver accepts such a detail and cuts it to ≤ 512 bytes between characters (never refuses). The platform's own producers send at most 230 bytes (jobs) or fixed ASCII text (actions), so no cut happens today | open, by design; asserted | `test/test_aicore_platform_parity.lua` [9]; platform `src/lib/ai-core/protocol.ts` |
| KI-3 | Category exclusions are translated, not shared: the platform's `scenes`, `keypad` and `other` have no driver category and are enforced by the cloud alone; `climate` and `shades` both map to the driver's `comfort`, so excluding either also refuses `comfort` markers on the controller (errs towards excluding more) | open, by design | `DRIVER.md` §9; platform `src/lib/ai-core/settings/driver-config.ts` `DRIVER_CATEGORIES_FOR` |
| KI-4 | Staff settings accept any lowercase category name in `excluded_categories` (`settings.ts` `CATEGORY`); one outside the learning vocabulary excludes nothing on either side (the portal accepts only `LEARNING_CATEGORIES`) | open | platform `src/lib/ai-core/settings/settings.ts` |
| KI-5 | The homeowner's room list is read from rooms the Flight Recorder has recorded (`flight_recorder_events.room_id`, last 1000 events with a room): a room with no recorded event yet is not offered. `control4_devices.room_id` cannot be used: it is a uuid column, `NULL` in practice | open | platform `src/lib/ai-core/memory/portal.ts`; migration `20260829182833_control4_devices_room_id.sql` |
| KI-6 | `Property ID` and `Controller ID` read `Not delivered yet`: System Studio's document does not carry `property_id` / `controller_id` | open | `DRIVER.md` §1; platform `settings.ts` `driverConfigDocument` |
| KI-7 | Prompt delivery of a pause / resume / exclusion change needs the controller to have declared `modules_v1` and the document to have been published with a version; the queued `MODULE_COMMAND` expires after 10 minutes. Otherwise nothing is queued (logged, not an error) and the change reaches the controller with the next configuration delivery | open, by design | platform `settings.ts` `promptDriverDelivery`; `src/lib/control4/flight-recorder/modules.ts` `MODULE_COMMAND_TTL_SECONDS` |
| KI-8 | The Agent forwards a configuration only when its `settings_version` or content changed since it last forwarded one (`forwardDriverConfig` fingerprint): an AI Core instance added after the current document was forwarded to another instance waits for the next change to receive it, and has learning off until then | open | `drivers/smartbuildos/driver.lua` `forwardDriverConfig` |
| KI-36 | The `request_id` inside `ai_core.command` / `ai_core.record` **payloads** arrives as `[redacted]`: `aic-` + a UUID is 40 characters of `[%w-]`, which `sbos.envelope.looksLikeSecret` treats as a key. The envelope's `correlation_id` (not redacted) carries the same id, and `AI_LAST_REQUEST_ID` shows it; the payload copy is lost. Found during this closeout (shim) | open | `src/sbos/envelope.lua` `looksLikeSecret`; `src/aicore/commands.lua` `envelope` |
| KI-37 | `AI_RUN_HOUSEHOLD_ANALYSIS`: "the Agent refused it, update the Agent" is inferred from `not_permitted` arriving **without** `result.reason`. The contract has the platform name a reason on every one of its own refusals of `analyze_household`; a platform refusal without one (for example from a layer in front of the op handler, or a platform that has not landed the op yet) is shown as the Agent's refusal. Until the platform side ships, the cross-repo parity test fails on the op lists (`test/test_aicore_platform_parity.lua` [2]) | open, by contract | `src/aicore/commands.lua` `interpretHousehold`; `src/sbos/modulebus.lua` `cloudRequest` |
| KI-38 | `AI_RUN_HOUSEHOLD_ANALYSIS`: the driver is never told when an accepted (queued) run finishes or what it found — by design, the result is in System Studio. A reason the platform adds later is shown as it is; an error code outside the Agent's `CLOUD_PASSTHROUGH` without a reason arrives as `cloud_refused` | open, by design | `DRIVER.md` §3; `src/sbos/modulebus.lua` `CLOUD_PASSTHROUGH` |
| KI-9 | System Studio's settings page still says the controller receives the change "on its next check-in"; learning and exclusion changes now also go at once | open (UI owners) | platform `src/components/system-studio/intelligence/AiProviderSetup.tsx` |

## Driver: not verified on hardware

No physical controller has run AI Core, the Flight Recorder's v2 service or
module contract v2 (`DRIVER.md` §14; `TEST-MATRIX.md` "Hardware validation
plan", 21 procedures, none done; `RELEASE.md` §5). Owed on a bench:

| # | Item | Source |
| --- | --- | --- |
| KI-10 | Load on OS 3.3.2 and 4.x (LuaJIT, the `<script>` tag, squished modules) | `DRIVER.md` §14; `TEST-MATRIX.md` procedure 1 |
| KI-11 | `C4:UUID("RANDOM")`'s real output; BOOL variables `"true"`/`"false"` as Composer conditions read them | `DRIVER.md` §14; procedures 4, 5 |
| KI-12 | The `OnSystemEvent` payload for ids 17–20, 48, 49, 90 is undocumented; only `name="…"` is read | `DRIVER.md` §10, §14; procedure 6 |
| KI-13 | `RegisterVariableListener`'s first callback is assumed to be the initial value | `DRIVER.md` §14; procedure 7 |
| KI-14 | `SendToDevice` ordering, frames near 24–32 KB, timers under Director load | `DRIVER.md` §14; `ARCHITECTURE.md` §4 limits; procedures 8, 9 |
| KI-15 | The platform route `/api/integrations/control4/modules/rpc` until deployed: the Agent gets 404 → `cloud_refused` | `DRIVER.md` §14; `RELEASE.md` §3 step 2; procedure 15 |
| KI-16 | Persistence across a real power cut (Director's flush timing) | `DRIVER.md` §14; procedure 11 |
| KI-41 | Sizes at a full 48-module registry are unmeasured: the Agent's persisted registry (each entry may carry a manifest of up to 2 KB, so up to ~96 KB of manifests alone), the heartbeat `modules` block (one row per module with `bus` counters, `manifest` and `verified`), and how often a real directory reply reaches the 28 KB cap and arrives `truncated` (the helper asks for `ai_core` alone, so its own replies stay small). Ruling 10 raised the cap from 16 to 48 without a bench measurement | `docs/protocol/MODULE-CONTRACT-V2.md` §3, §10; `src/sbos/modules.lua` `LIMITS`; `src/sbos/modulepolicy.lua` `directory_bytes` |
| KI-42 | `sbos.aireport` passive mode (child drivers): whether the system events `OnDriverAdded` (13) and `OnItemRemoved` (11) are delivered to a child driver, and the exact shape of `C4:GetDevicesByC4iName("smartbuildos-ai-core.c4z")`'s answer when none is installed (nil and an empty table are both read as "not installed"). If the events do not arrive, the property is refreshed only at the child's next start | `src/sbos/aireport.lua` `passive`; `docs/DRIVER_PLATFORM_GUIDE.md` §9 |

## Driver: limitations by design

| # | Limitation | Source |
| --- | --- | --- |
| KI-17 | Composer device events are not collected when the Flight Recorder is absent (`RegisterDeviceEvent` needs the recorder's per-driver catalogue; duplicating it is the double capture D7 forbids) | `DRIVER.md` §10, §15 |
| KI-18 | Variables are collected by AI Core only when listed in `collection.variables`, and System Studio lists none today | `DRIVER.md` §15; platform `driver-config.ts` `AI_CORE_DRIVER_COLLECTION` |
| KI-19 | Agent-classified events are left to the recorder when it is present, even if it is not configured to record them | `DRIVER.md` §15 |
| KI-20 | `ROOM` is a STRING (name or id), not a room selector | `DRIVER.md` §15 |
| KI-21 | Events never say who or what caused a change, the previous value, or that a programming item ran (DriverWorks provides none) | `DRIVER.md` §10; manual "What is not claimed" |
| KI-22 | `AI_CONCIERGE` gates nothing on the controller (no concierge path there); the platform must enforce it. `AI_ACTIONS` gates `invoke_driver_action` (D4) but nothing else: AI-proposed device actions still go through the Agent's command queue | `TEST-MATRIX.md` known gaps; `DRIVER.md` §12 |
| ~~KI-43~~ | **Closed (D4, 2026-11-18).** It was: after an AI Core restart that never went stale, a reporter re-sent its same-hash `describe` only at the first directory change ≥ 10 min after the last one. Now AI Core answers `need_describe: true` whenever it holds no describe for the sender (always after a restart: describes are not persisted, ruling 19) and the helper re-sends at once (`test/test_sbos_aireport.lua` [13a]; emulator `test/emulator/ai_core_reports.lua` [10]). Still by contract: events and diagnostics made while AI Core is absent are dropped, not queued | `src/sbos/aireport.lua` `onAnswer`; `src/aicore/reports.lua` `receive` |
| KI-39 | The controller's one-accepted-run-an-hour guard for `AI_RUN_HOUSEHOLD_ANALYSIS` lives in the driver's persisted state on `os.time()`: removing and re-adding the driver resets it, and a clock that moved backwards does not block (the platform's own hourly limit per property still applies). A cloud `rate_limited` is retried twice by the module client (2 s, 5 s) like every op, so one refused press can make three requests | `DRIVER.md` §3; `src/sbos/modulepolicy.lua` `RETRYABLE` |
| KI-40 | Whether Composer lists a device command by its `<name>` (`AI_RUN_HOUSEHOLD_ANALYSIS`, like the driver's other `AI_*` commands) with the `<description>` (`Run Household Analysis: …`) in the script line is not checked in a real Composer (`TEST-MATRIX.md` procedure 21). A spaced `<name>` ("Run Household Analysis") would also work with the vendored `ExecuteCommand` (it maps spaces to `_`, as `drivers/smartbuildos-mode-composer` does) | `drivers/smartbuildos-ai-core/driver.xml`; `vendor/drivers-common-public/global/handlers.lua` |
| KI-23 | Local pub/sub is lossy by design; there is no global event order (envelopes carry `sequence`) | `DRIVER.md` §12; `ARCHITECTURE.md` §4.5 |

## Driver: the report hub (D4)

Emulator and unit tests only; nothing here has run on a controller.

| # | Issue | Status | Source |
| --- | --- | --- | --- |
| KI-44 | `driver_query_result` / `driver_action_result` go once per operation; the module client retries a lost one twice (2 s, 5 s) and then the outcome is only logged, not stored or re-sent. The platform then sees no result for that `query_ref` / `ai_action_id` (a query tool times out; an action stays without a driver outcome) | open | `drivers/smartbuildos-ai-core/driver.lua` `relayDriverOp` |
| KI-45 | The hub is memory only (ruling 19): an AI Core restart loses the reports waiting for upload. Describes come back through `need_describe`, the latest state with the reporter's next state; events and diagnostics that were waiting are lost and not counted anywhere the cloud sees | by design | `src/aicore/reports.lua` |
| KI-46 | Today the platform answers every `driver_reports`, `driver_query_result` and `driver_action_result` with `unsupported` (wire reserved; handlers land in P3), so no report or result reaches a store: each refused batch drops its states, events and diagnostics (counted), keeps its describes waiting (KI-51) and backs off, so the steady state against this platform is one `driver_reports` batch every 10 minutes per controller. The two body disagreements found while building D4 (`driver_reports.dropped` missing from `OP_BODIES`; `DECLARATION_HASH` 64 hex against the helper's 16) are resolved on the platform branch (ruling 22); `test/test_aicore_platform_parity.lua` [8] / [8a] would name either if it came back | open (platform, P3) | `P:src/lib/ai-core/rpc/ops.ts`; `P:src/lib/ai-core/drivers/wire.ts` |
| ~~KI-47~~ | **Closed (D4b, 2026-11-18).** It was: the helper accepted a query or action declaration with an empty `description` (its default) and could send an empty vocabulary word; AI Core refuses such a describe, so that driver's describe never reached the cloud. Now the helper requires non-empty text: `declareQuery` / `declareAction` return `false, reason` for a missing or empty id, description or (actions) title; `describe` drops empty vocabulary words, labels an unlabelled control with its id and refuses an explicitly empty summary; the built-in summary (else the driver's label) is used otherwise. Tests run the helper's describe through AI Core's own validator (`test/test_sbos_aireport.lua` [4], [8], [9]; `DRIVER_PLATFORM_GUIDE.md` §9) | closed | `src/sbos/aireport.lua` `validateQuery` / `validateAction` / `describe` |
| KI-48 | `error_code` is the closed module error vocabulary, which has no code for "the driver declined" or "the declaration changed": a driver's own refusal is `failed` / `internal_error` with its words in `result_text`; `declaration_changed`, `requester_unverified`, `target_unverified`, `not_licensed` and the other local reasons travel in `result_text` too. The platform (P3) has to read `result_text` to map `declaration_changed` to `approval_invalidated` | open (contract) | `src/aicore/reports.lua` `actionResultBody`; `DRIVER.md` §7a |
| KI-49 | An action whose driver does not answer within 20 s is reported `failed` / `deadline_exceeded` "the outcome is unknown": the driver may have run it. AI Core never retries an action | by design | `DRIVER.md` §7a |
| KI-50 | "Each `ai_action_id` runs once" is held in memory for the last 64 ids: an AI Core restart forgets it (the Agent's per-request-id dedup and the platform's single dispatch still apply) | by design | `src/aicore/reports.lua` `beginOp` |
| ~~KI-51~~ | **Closed (D4b, 2026-11-18).** It was: a describe in a `driver_reports` batch the cloud refused was dropped while AI Core kept its hash, so it was uploaded again only when the hash changed, after an AI Core restart, or on the helper's own 10-minute re-send. Now a describe counts as uploaded only when the cloud accepted its batch: after a refusal, timeout or unreachable cloud it waits for the next batch (latest per instance). States, events and diagnostics in a refused batch are still dropped and counted. After any batch that did not land the next backs off 60 s, doubling to 10 minutes (reset on delivery): against a cloud that keeps refusing, one batch every 10 minutes (`test/test_aicore_reports.lua` [3a]) | closed | `src/aicore/reports.lua` `settle` / `due` |
| KI-52 | Bus latency for queries and actions (discover + request through the Agent) against the platform's 15 s query wait, and memory with 48 reporting modules (up to 48 describes of 8 KB pending plus a ring of 200 events), are unmeasured on a controller | open (bench) | `DRIVER.md` §14 |

## Licensing

| # | Issue | Source |
| --- | --- | --- |
| KI-24 | An assertion that fails verification is dropped and the SKU answers `LEGACY`, which is operational: a forged or tampered assertion does not license AI Core, but it does not stop it either | `TEST-MATRIX.md` known gaps (emulator [13b], [13c]) |
| KI-25 | The Agent never compares an assertion's `controller_id` with its own identity; binding rests on the per-controller signing secret. `CONTROLLER_MISMATCH` is never issued for `SBOS_AI_CORE` by the refresh route (only System Link); a transferred licence reaches the old controller as `NOT_ENTITLED` | `TEST-MATRIX.md` known gaps |

## Release and store

| # | Issue | Source |
| --- | --- | --- |
| KI-26 | Nothing is released: no tag, no release, no store package, no production migration for AI Core | `RELEASE.md` intro |
| KI-27 | `smartbuildos-flight-recorder.c4z` is not in `sku_for()` and not in the Agent's `DRIVER_FILENAMES`: neither CI nor the updaters deliver the Flight Recorder (owner decision) | `RELEASE.md` §2, §3 step 4 |
| KI-28 | A CI build triggered by a `v*` tag restamps `<version>`, so the tag and the files disagree; recent releases use bare tags, which `release.yml` does not run for | `RELEASE.md` §2 |
| KI-29 | `make build`'s `fmt` rewrites tracked files (build on a clean checkout or a scratch copy); `make lint` is not in CI | `RELEASE.md` §1 |
| KI-30 | The Agent updater never downgrades: rolling back the Agent, the recorder or AI Core is a manual reinstall in Composer | `RELEASE.md` §3 |
| KI-31 | Store price, tier and category for `SBOS_AI_CORE` are placeholders pending the owner | `RELEASE.md` §3 step 6; platform `protocol.ts` `AI_CORE_CATALOG` |

## Platform database

| # | Issue | Source |
| --- | --- | --- |
| KI-32 | The eight AI Core migrations are not applied to production (owner's action); they were run on a throwaway local container only | platform `docs/ai-core/MIGRATIONS.md` |
| KI-33 | The repo's migration history cannot be replayed from an empty database (duplicate version stamps; a backfill reads columns no migration adds): a local database is built from the canonical baseline plus the listed prerequisites | platform `docs/ai-core/MIGRATIONS.md` "Prerequisites" |
| KI-34 | Rolling back `20261118190000` deletes every memory whose source is `programming` or `model_proposed` | platform `docs/ai-core/MIGRATIONS.md` "What 8's rollback deletes" |
| KI-35 | The concierge QA script was uncommitted when the migration run was recorded | platform `docs/ai-core/MIGRATIONS.md` "Verify" |

## External blockers

Live AI calls (a customer API key), restaurant booking partners, Google /
Microsoft calendar OAuth credentials, a Places API key, bench validation and
store publication are blocked outside engineering (`ARCHITECTURE.md` §8;
`RELEASE.md` §3–§5).

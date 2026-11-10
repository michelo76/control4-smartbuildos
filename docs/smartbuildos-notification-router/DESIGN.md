# Notification Router — design

Status: implemented on `feat/event-tracer` (batch of 2026-11-09);
simulator-verified; no bench run yet. SKU `SBOS_NOTIFICATION_ROUTER`.
Combo driver (no proxy), licensed through the Agent with `sbos.license`.

## Shape

| Layer | File | Role |
| --- | --- | --- |
| Pure | `src/notify/router.lua` | priority/clock parsing, per-target decisions (disabled, below_priority, quiet_hours with critical bypass, duplicate within the dedupe window, rate_limited per rolling hour), retry schedule (5 s, 30 s; three attempts), bounded delivery log (50) |
| Pure | `src/notify/formatters.lua` | exact request per target: Telegram `sendMessage`, Pushover `messages.json` (critical → emergency with retry/expire), Slack/Discord webhook (`text` + `content`), generic JSON POST with optional bearer, Twilio `Messages.json` form body with Basic auth; each with a credential-free `describe` for the log |
| Driver | `drivers/smartbuildos-notification-router/driver.lua` | targets from Composer properties, `NOTIFY` / `NOTIFY_ALL`, deliveries in flight with named retry timers, events, counters by day, persistence of the log and counts, licence enforcement |
| Pure | `src/notify/template.lua` | message variables: `${1}`..`${4}` (the command's VARIABLE pickers) and `${Room->Device::VARIABLE}` written out, lookup by name or id, on/off wording and rounding, picked-but-unwritten variables added at the end, `?` for what cannot be read, `[hidden]` for credential-named variables |
| Tests | `test/test_notify_router.lua` (31), `test/test_notify_formatters.lua` (24), `test/test_notify_template.lua` (68), `test/test_notify_driver.lua` (62) | see VERIFICATION below |

## Decisions

- **HTTP only through `lib.http`** (`C4:url` underneath via the vendored
  `urlDo`): a table body is JSON-encoded with `Content-Type: application/json`
  by the library; Twilio's form body is a string with its own content type.
  4xx answers other than 408/429 are configuration errors and fail fast; 5xx,
  timeouts and transport errors retry.
- **Credentials** are `STRING` properties with `<password>true</password>`
  (the shape shipped drivers such as wattbox.c4i use; the docs' "String
  Password" type). The property value is persisted by Director as any
  property; the driver never logs it, and `lib.http` redacts URLs and headers
  in its own trace lines.
- **Dedupe** is per target + title + body; test actions clear the dedupe
  table first so a dealer can click twice.
- **Rate limit** counts attempted sends in a rolling hour, so a failing
  target cannot burn unbounded retries.
- **Pending deliveries** are bounded at 50; beyond that a send is logged as
  `dropped`.
- **Enforcement**: a definitive denial with enforcement on halts sending
  (`unlicensed`, Router Degraded); every uncertain status leaves it working.

## Message variables (added 2026-11-10)

A notification can carry a variable's live value, set up in the programming
window the way Control4's Push Notification agent does it; the dealer-facing
rules are in the driver's documentation.

- **Picked in the command.** `NOTIFY` and `NOTIFY_ALL` each declare four
  parameters `VARIABLE 1`..`VARIABLE 4` of type `VARIABLE_SELECTOR`
  (`<variabletype>all</variabletype>`). In programming Composer shows a `…`
  button that opens its own *Select variable…* tree and stores the choice in
  the programming line. The driver receives `"deviceId,variableId"` as a
  string, or `""` when nothing is picked (bench: `82,5015`).
  `${1}`..`${4}` in TITLE or MESSAGE stand for them.
- **Written out.** `${Room->Device::VARIABLE}` is the agents' token syntax,
  resolved by the driver through `C4:GetDevices` and
  `C4:GetDeviceVariables`; also `${Device::VARIABLE}`, `${id::VARIABLE}` and
  `${Variables::NAME}` (device 100001).
- **Picked but not written** → appended to the message in order, so a
  dealer who only uses the picker still gets the value.
- **Where it happens**: in `EC.NOTIFY`, before `Router.message`. The router
  therefore trims, logs and de-duplicates the filled-in text. Test actions
  send fixed text. One resolver per notification reads each device once;
  nothing is subscribed or cached.
- **Never blocks a send**: an unreadable variable is `?`; each is logged as
  a `variable` entry, counted in `variable_missing`, named in Last Router
  Error, and raises *Message Variable Missing* once per notification.
- **Credentials**: `flightrecorder.config.isFixedExclusion` (the list the
  Flight Recorder and the Variable Inspector use) decides; such a variable
  is sent as `[hidden]` and reported like a missing one.
- **Not a token**: `${…}` holding neither one digit nor a `::` pair, and
  every plain `{…}`, are left as written.

What the bench showed, and the two designs it replaced:

- `VARIABLE_SELECTOR_VALUE` hands the driver the variable's *value* instead
  of its ids (bench: `0`). It is not used: a `?` could not say which
  variable failed and the credential rule needs the name.
- A `STRING` parameter in programming is a combo box whose drop-down lists
  every project variable as `Room->Device->VARIABLE`. Choosing one replaces
  the whole field, and Director substitutes the value before the command
  reaches the driver (bench: MESSAGE `Living->Apple TV->APP_COUNT` arrived
  as `59`). Good for a value on its own; it cannot mix a value with words,
  which is what the pickers add.
- First design, withdrawn the same day: eight slots in the driver's
  *properties* (`{1}`..`{8}`). The owner's direction was to do it in the
  programming window like Push Notification. Along the way: a
  `DEVICE_SELECTOR` property with no `<items>` filter makes Composer Pro
  2026.10.14 raise "Property Invalid … Object reference not set" on import
  (`test/test_driver_xml_guard.lua` now refuses it, and `PASSWORD`).

## PROBE / unconfirmed

- `${Variables::NAME}` relies on `C4:GetDeviceVariables(100001)` returning
  Composer's custom variables; not bench-confirmed (a custom variable picked
  in the tree arrives with its real device id, so the picker does not depend
  on it).
- `${1}` typed into a text field was not bench-checked: keystrokes from the
  Mac into the Composer VM do not land reliably. The picker → value →
  appended path is bench-confirmed; the token path is covered by the shim
  suites.
- The exact behaviour of Director's `C4:url` with a 4xx answer (whether the
  callback carries the status code) is taken from `lib.http`'s contract
  (`result.code` on reject). If a bench shows codes missing on failure, every
  failure retries — a safe degradation.
- No local queue across a Director restart: in-flight deliveries are lost on
  reboot. Documented as a limit, not a bug.

## Not included (v1)

- Escalation chains (send to B if A did not acknowledge).
- Control4 push notifications (the Push Notification agent has no documented
  driver-callable API) and e-mail (no SMTP from a driver; SendGrid could be a
  generic-webhook target).
- Per-notification images or attachments.

## VERIFICATION

Simulator (shim) suites, all green at hand-over: router 31, formatters 24,
driver see `test/test_notify_driver.lua` (licence registration under the
SKU, Notify All producing the exact Telegram and Twilio calls, pushover gated
by priority, unconfigured target fails with reason, dedupe, channel
selection, 503 → retry at 5 s and 30 s → Delivery Failed, 401 fails fast, a
successful retry counts as sent, quiet hours and critical bypass, rate limit
event, enforcement halting and observe resuming, test actions, log and
counters surviving a reload, no token in the persisted log; message
variables: a picked variable and a written-out one sent as values, dedupe
on the filled-in text, a picked variable not written into the text added at
the end, Notify All taking the same parameters, `?` and `[hidden]` with the
event, the error and the log entries, the credential's value in no request
and no log, a device that does not answer, a programming line written
before the parameters existed, the eight pickers declared in driver.xml).

Each of these was seen to fail when the rule behind it was removed: the
credential mask, the single pass, and keeping a slot's setting.

Bench plan: turn on one real target (Telegram is the quickest), Send Test,
confirm the message and that Print Delivery Log shows `sent (attempt 1)`;
then a wrong token → `failed … HTTP 401 (check the target's settings)`.

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Online, Router Status `no_targets`, Targets Ready `none`, Sent/Failed Today 0. License Status read `SmartBuildOS Agent Found – Checking…` for the first ~5 minutes, then `Licensing Not Yet Enforced`, tier `Enterprise`, company painted.

## Bench 2026-11-10 — Beta Site 2 (OS 4.3), message variables

- Builds `054552` and `055207` carried the withdrawn property-slot design
  (see above for the `DEVICE_SELECTOR` failure). By mistake the Solar
  Position package of build `054552` (source unchanged) was imported first:
  in Composer's file dialog a single click on a file opens it.
- Probe builds `061638`..`063230` added a temporary command with the two
  variable-picker parameter types and painted what the driver received.
  Readings: `VARIABLE_SELECTOR` → `82,5015`; `VARIABLE_SELECTOR_VALUE` →
  `0`; unset picker → empty string; a variable chosen in a `STRING`
  parameter's drop-down → its value.
- Build `20261110.064130` (this design): import "Update Succeeded", no
  property error, the slot properties gone. In programming, Notify shows
  CHANNEL, PRIORITY, TITLE, MESSAGE and VARIABLE 1..4, each picker with a
  `…` button opening *Select variable…*. With VARIABLE 1 = an Apple TV's
  `APP_COUNT`, MESSAGE = another device's status variable from the
  drop-down, channel Webhook (Off, so nothing left the house), Execute
  painted Last Notification `BRIDGED 59 (low)`: the drop-down's value
  followed by the picked variable's value. The script line read
  `Notify Webhook (low): …`. The test line was deleted afterwards.
- Composer reports "Versions are equal" and offers to overwrite for every
  same-day rebuild, although the stamps differ; Yes works.

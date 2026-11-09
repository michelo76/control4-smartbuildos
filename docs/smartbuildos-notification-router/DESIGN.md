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
| Tests | `test/test_notify_router.lua` (31), `test/test_notify_formatters.lua` (24), `test/test_notify_driver.lua` (46) | see VERIFICATION below |

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

## PROBE / unconfirmed

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
counters surviving a reload, no token in the persisted log).

Bench plan: turn on one real target (Telegram is the quickest), Send Test,
confirm the message and that Print Delivery Log shows `sent (attempt 1)`;
then a wrong token → `failed … HTTP 401 (check the target's settings)`.

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Online, Router Status `no_targets`, Targets Ready `none`, Sent/Failed Today 0. License Status read `SmartBuildOS Agent Found – Checking…` for the first ~5 minutes, then `Licensing Not Yet Enforced`, tier `Enterprise`, company painted.

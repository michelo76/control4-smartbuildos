# SmartBuildOS Notification Router

One programming command, **Notify**, and the router decides where it goes:
Telegram, Pushover, a Slack or Discord webhook, a generic JSON webhook, or a
text message through Twilio. Each target has its own on/off switch, minimum
priority and quiet hours. Across targets the router removes duplicates, caps
the rate per hour, retries failures and keeps a delivery log you can print
from Composer. It does not depend on 4Sight or on any SmartBuildOS service
for delivery.

Licensing is through the **SmartBuildOS Agent** (SKU
`SBOS_NOTIFICATION_ROUTER`); **License Status** shows this driver's standing.

## Setup

1. Install the SmartBuildOS Agent from Composer's Agents tab and pair it.
1. Add this driver (one per project).
1. Turn on a target and fill in its credentials:
   - **Telegram**: create a bot with BotFather, add it to a chat or group,
     paste the bot token and the chat id (read it from `getUpdates`).
   - **Pushover**: an application token and your user key.
   - **Webhook**: a Slack or Discord incoming webhook URL.
   - **Generic Webhook**: any URL that accepts a JSON POST, with an optional
     bearer token.
   - **Twilio SMS**: Account SID, Auth Token, From and To numbers in E.164
     form (+15551234567).
1. Use **Send Test To …** for each target. **Targets Ready** lists the
   targets that are on and fully configured.
1. In programming, add **Notify** (CHANNEL, PRIORITY, TITLE, MESSAGE) or
   **Notify All** to any routine.

## Routing rules

- **Priority** is low, normal, high or critical. A target's **Minimum
  Priority** gates what it receives.
- **Quiet hours** per target (`HH:MM` to `HH:MM`, may cross midnight) hold
  everything back except **critical**, which always goes through, and raise
  *Quiet Hours Suppressed*.
- **Dedupe Window**: the same title and message to the same target inside
  the window is sent once. Zero disables it. Test actions bypass it.
- **Rate Limit Per Hour** per target; a dropped notification raises *Rate
  Limited*.
- **Retries**: a failed send is retried after 5 s and again after 30 s. A
  4xx answer other than 408 and 429 is a configuration error and fails at
  once with "check the target's settings". *Target Unreachable* fires on the
  first failure, *Delivery Failed* once the attempts are spent.
- **Pushover critical** is sent as an emergency that repeats every minute
  for an hour until acknowledged, as the Pushover API requires.

## What is NOT claimed

Delivery means the target's API accepted the message, not that a person read
it. Nothing is queued across a Director restart: a notification in flight
during a reboot is lost and the next one is not affected.

## Actions

| Action | What it does |
| --- | --- |
| Send Test To … | A normal-priority test notification to that target (it must be On) |
| Print Delivery Log | The last 50 deliveries with target, outcome, attempts and reason |
| Print Router Status | Targets, limits, counters, deliveries in flight |
| Clear Delivery Log | Empties the log |
| Register With Agent Now / Refresh Status | Licence and status refresh |

## Programming

- Commands: **Notify** (CHANNEL, PRIORITY, TITLE, MESSAGE), **Notify All**
  (PRIORITY, TITLE, MESSAGE).
- Events: *Notification Sent*, *Delivery Failed*, *Target Unreachable*,
  *Quiet Hours Suppressed*, *Rate Limited*, *Router Degraded*, *Router
  Restored*.
- Conditionals: *At least one target is configured and enabled*, *Quiet
  hours are active on every enabled target*.
- Variables: `ROUTER_STATUS`, `LAST_NOTIFICATION`, `SENT_TODAY`,
  `FAILED_TODAY`, `LAST_FAILED_TARGET`, `PENDING_DELIVERIES`.

## Privacy

Tokens, keys and webhook URLs are password properties and never appear in
the delivery log, the Lua output or any variable; the log records the target
and a masked destination (for SMS the last four digits are hidden). Message
text is whatever your programming puts in it: do not put codes or personal
details in notifications.

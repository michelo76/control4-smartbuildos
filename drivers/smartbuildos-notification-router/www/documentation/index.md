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

## Message variables

A notification can carry the **current value** of any Control4 variable. It
works the way Control4's own Push Notification and Email agents do, and you
set it up in the programming window, on the Notify command itself. Only the
value is sent, never the variable's name.

1. In programming, select the router and the **Notify** command.
1. Next to **VARIABLE 1**, press `…`. Composer opens its *Select variable…*
   tree: every room, device and variable of the project. Pick one.
1. Write `${1}` in the TITLE or MESSAGE where the value should appear.
   `${2}`, `${3}` and `${4}` are the other three pickers.

| You write | VARIABLE 1 | It is sent as |
| --- | --- | --- |
| `Garage is ${1}` | Garage Door → STATE | `Garage is 1` |
| `Garage is ${1\|Open\|Closed}` | Garage Door → STATE | `Garage is Open` |
| `Pool ${1\|.1}°F` | Variables → Pool Temp | `Pool 81.5°F` |
| `Garage:` | Garage Door → STATE | `Garage: 1` |

**Picking is enough.** A variable that is picked but not written into the
text is added at the end of the message, as in the last row.

**Written out, with no picker.** The token Control4's agents use works too:

- `${Garage->Garage Door::STATE}` is `Room->Device::VARIABLE`.
- `${Garage Door::STATE}` when the device name is unique in the project.
- `${231::STATE}` by device id, which survives a rename.
- `${Variables::Pool Temp}` for one of the project's custom variables.

Case, spaces and underscores in the names do not matter.

**How the value is shown.** Add one of these after a `|`:

- `${1|Open|Closed}` for on/off values: the first text when the value is 1,
  true, on, yes or a non-zero number; the second when it is 0, false, off,
  no or empty. Any other text is sent as it is. The second text may be left
  empty: `${1| (door open)|}`.
- `${2|.1}` rounds a number to that many decimals (0 to 3).

**One variable as the whole text.** The TITLE and MESSAGE fields also have a
drop-down listing every variable. Choosing one there makes that variable's
value the entire text of the field; this is Composer's own behaviour for a
text parameter. Use the VARIABLE pickers to mix a value with words.

**What you can rely on.**

- A variable that cannot be read is sent as `?` and never stops the
  notification. *Message Variable Missing* fires, **Last Router Error** names
  the token and the reason, and **Print Delivery Log** lists each one.
- A variable whose name marks it as a credential (user code, PIN, password,
  token and the like) is sent as `[hidden]`. These messages leave the house.
- The **Dedupe Window** compares the filled-in text: the same reading twice
  is sent once, a changed reading is a new message.
- Only `${1}` to `${4}` and `${device::variable}` are tokens. Anything else,
  `{braces}` and JSON included, is left exactly as written. A value is filled
  in once; a token inside a value is not expanded again.
- A value is one line of at most 120 characters.
- A picked variable is stored by id, so renaming the device or the variable
  later changes nothing.

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

- Commands: **Notify** (CHANNEL, PRIORITY, TITLE, MESSAGE, VARIABLE 1 to 4),
  **Notify All** (PRIORITY, TITLE, MESSAGE, VARIABLE 1 to 4).
- Events: *Notification Sent*, *Delivery Failed*, *Target Unreachable*,
  *Quiet Hours Suppressed*, *Rate Limited*, *Router Degraded*, *Router
  Restored*, *Message Variable Missing*.
- Conditionals: *At least one target is configured and enabled*, *Quiet
  hours are active on every enabled target*.
- Variables: `ROUTER_STATUS`, `LAST_NOTIFICATION`, `SENT_TODAY`,
  `FAILED_TODAY`, `LAST_FAILED_TARGET`, `PENDING_DELIVERIES`.

## Privacy

Tokens, keys and webhook URLs are password properties and never appear in
the delivery log, the Lua output or any variable; the log records the target
and a masked destination (for SMS the last four digits are hidden). Message
text is whatever your programming puts in it: do not put codes or personal
details in notifications. A message variable sends a variable's value to the
target's service; credential-named variables are refused, but any other
variable you pick or write out is sent as it is.

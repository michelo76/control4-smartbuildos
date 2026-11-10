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

## Two-way: messages sent to the house

A person can send a message to the house and programming reacts to it. Two
channels can receive: **Telegram** and **Twilio SMS**. Slack and Discord
webhooks, Pushover and the generic webhook can only send.

**How it works.** A controller cannot be called from the internet, so the
router asks for new messages every few seconds (**Inbound Poll Seconds**,
default 5) using the credentials the target already has. A reply therefore
takes up to one poll interval to be noticed.

**Turn it on.**

1. Set **Telegram Inbound** or **Twilio Inbound** to On. **Inbound Status**
   reads `listening` once the first answer comes back, or names the problem.
1. Send a message to the bot, or a text to the Twilio number.
1. It appears in **Last Message** and in the variables below, and the events
   fire.

**Who is taken.** An inbound message can start programming, so the router
takes it only from a sender you named:

| Channel | Taken by default | Add more with |
| --- | --- | --- |
| Telegram | the chat in **Telegram Chat ID** | **Telegram Allowed Senders**: user ids or @usernames |
| Twilio SMS | the number in **Twilio To Number** | **Twilio Allowed Senders**: phone numbers |

In a Telegram group, every member is taken until you list people in
**Telegram Allowed Senders**; then only they are, and they may also message
the bot privately. Anything else fires *Message Rejected*, and its text is
never stored, logged or shown.

**What programming gets.**

- Variables: `LAST_MESSAGE`, `LAST_MESSAGE_CHANNEL`, `LAST_MESSAGE_SENDER`,
  and one per channel, `TELEGRAM_LAST_MESSAGE` and `SMS_LAST_MESSAGE`.
  `MESSAGE_COUNTER` goes up by one for every message, so programming on a
  variable change runs even when the same words arrive twice.
- Events: *Message Received*, *Telegram Message Received*, *SMS Message
  Received*, *Message Rejected*. Variables are set before the events fire.
- **Keywords.** Type a word or short phrase in **Keyword 1** to **Keyword
  8**. A message that is the keyword, or begins with it, fires *Keyword N
  Received*; the rest of the message is in `LAST_MESSAGE_ARGUMENT` and the
  keyword in `LAST_KEYWORD`. Case does not matter, the longest keyword wins,
  and a Telegram command such as `/status` matches the keyword `status`.
  With Keyword 2 = `gate`, the message `Gate open now` fires *Keyword 2
  Received* with the argument `open now`.
- **Reply** (command): sends MESSAGE back to whoever wrote last, on the
  channel they used. It takes message variables like Notify, so *When
  Keyword 1 Received → Reply "Garage is ${1|open|closed}"* answers a status
  question with a live value. A reply is not held back by quiet hours, the
  minimum priority or the dedupe window; the hourly rate limit still applies.

**Protection you can rely on.**

- **No replay.** A message older than two minutes (or three poll intervals,
  if that is longer) is ignored, so a controller that was off does not act
  on an old command when it starts. A message is handled once, including
  across a driver update or a controller restart.
- **Inbound PIN** (optional). When set, every message must begin with the
  PIN and a space, as in `4471 gate open`. The PIN is removed before the
  text reaches any variable or the log.
- At most 20 messages a minute per channel; text is one line of at most 500
  bytes. The text only ever becomes variables and a keyword match; nothing
  in it is run.
- When an ask fails, **Inbound Status** names the cause and the router backs
  off, up to five minutes, then recovers by itself.

**Limits to know.**

- **A texting number can be forged.** Set an Inbound PIN before letting an
  SMS unlock, disarm or open anything.
- **One reader per Telegram bot.** If another program reads the same bot, or
  the bot has a webhook, Inbound Status says `HTTP 409`. Use a bot of its
  own for the house.
- The controller's clock must be right to within a minute or two, or every
  message looks old and is ignored. **Print Router Status** shows the count
  of `stale` messages.
- Twilio keeps and bills messages under your Twilio account; the router only
  lists them.

## What is NOT claimed

Delivery means the target's API accepted the message, not that a person read
it. Nothing is queued across a Director restart: a notification in flight
during a reboot is lost and the next one is not affected.

## Actions

| Action | What it does |
| --- | --- |
| Send Test To … | A normal-priority test notification to that target (it must be On) |
| Print Delivery Log | The last 50 deliveries with target, outcome, attempts and reason |
| Print Router Status | Targets, limits, counters, deliveries in flight, inbound status and counts |
| Check For Messages Now | Asks Telegram and Twilio at once instead of waiting for the next poll |
| Clear Delivery Log | Empties the log |
| Register With Agent Now / Refresh Status | Licence and status refresh |

## Programming

- Commands: **Notify** (CHANNEL, PRIORITY, TITLE, MESSAGE, VARIABLE 1 to 4),
  **Notify All** (PRIORITY, TITLE, MESSAGE, VARIABLE 1 to 4), **Reply**
  (MESSAGE, VARIABLE 1 to 4).
- Events: *Notification Sent*, *Delivery Failed*, *Target Unreachable*,
  *Quiet Hours Suppressed*, *Rate Limited*, *Router Degraded*, *Router
  Restored*, *Message Variable Missing*, *Message Received*, *Telegram
  Message Received*, *SMS Message Received*, *Message Rejected*, *Keyword 1
  Received* to *Keyword 8 Received*.
- Conditionals: *At least one target is configured and enabled*, *Quiet
  hours are active on every enabled target*.
- Variables: `ROUTER_STATUS`, `LAST_NOTIFICATION`, `SENT_TODAY`,
  `FAILED_TODAY`, `LAST_FAILED_TARGET`, `PENDING_DELIVERIES`,
  `LAST_MESSAGE`, `LAST_MESSAGE_CHANNEL`, `LAST_MESSAGE_SENDER`,
  `LAST_MESSAGE_ARGUMENT`, `LAST_KEYWORD`, `TELEGRAM_LAST_MESSAGE`,
  `SMS_LAST_MESSAGE`, `MESSAGE_COUNTER`, `MESSAGES_RECEIVED_TODAY`.

## Privacy

Tokens, keys and webhook URLs are password properties and never appear in
the delivery log, the Lua output or any variable; the log records the target
and a masked destination (for SMS the last four digits are hidden). Message
text is whatever your programming puts in it: do not put codes or personal
details in notifications. A message variable sends a variable's value to the
target's service; credential-named variables are refused, but any other
variable you pick or write out is sent as it is.

Inbound messages: the text of a message that is taken is kept in the
variables, in **Last Message** and, cut to 60 characters, in the delivery
log. The text of a refused message is not kept anywhere. A texting number is
logged with its last four digits hidden. The Inbound PIN is a password
property and is stripped from the text before anything else sees it.

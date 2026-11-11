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

<!-- walkthrough: Set up the router -->
1. Install the **SmartBuildOS Agent** from Composer's Agents tab and pair it.
1. Add this driver to the project (one per project). **Driver Status** reads
   `Online` and **License Status** shows the licence within a few seconds.
1. Turn on a target and fill in its credentials:
   - **Telegram**: a bot token and a chat id. The
     [Telegram walkthrough](#telegram-create-the-bot-and-find-the-chat-id)
     below takes you through both.
   - **Pushover**: an application token and your user key.
   - **Webhook**: a Slack or Discord incoming webhook URL.
   - **Generic Webhook**: any URL that accepts a JSON POST, with an optional
     bearer token.
   - **Twilio SMS**: Account SID, Auth Token, From and To numbers in E.164
     form (+15551234567).
1. On the **Actions** tab press **Send Test To …** for that target. **Targets
   Ready** lists the targets that are on and fully configured, and **Last
   Notification** shows the test.
1. In programming, add **Notify** or **Notify All** to any routine. See
   [Writing a message](#writing-a-message).

![The router's properties in Composer: status at the top, then one block of settings per target](images/properties.jpg)

![The Actions tab](images/actions.jpg)

## Telegram: create the bot and find the chat id

Telegram needs two things from you: a **bot** that the router sends as, and
the **chat** it sends to. The chat can be you alone, a group, or a channel.
Everything below is done in the Telegram app on a phone or a computer, then
finished in Composer.

<!-- walkthrough: Create the Telegram bot -->
1. In Telegram, search for **BotFather** and open the account with the blue
   verified tick. BotFather is Telegram's own bot for making bots.
1. Send `/newbot`. BotFather asks for a **name** (shown in chats, for example
   `Lake House`) and then a **username** that must be unique and end in `bot`
   (for example `lakehouse_c4_bot`).
1. BotFather answers with the bot's **token**, a long text of digits, a
   colon, then letters. Copy the whole line.
1. In Composer, select the router and paste the token into **Telegram Bot
   Token**. Set **Telegram** to On.

<div class="chat">
<p class="me">/newbot</p>
<p class="who">BotFather</p>
<p class="them">Asks what the bot should be called.</p>
<p class="me">Lake House</p>
<p class="them">Asks for a username ending in “bot”.</p>
<p class="me">lakehouse_c4_bot</p>
<p class="them">Confirms the bot and gives its token:<br><code>1234567890:AAH…your-token…</code></p>
</div>
<p class="chat-note">An illustration of the conversation, not a screenshot. BotFather's own wording is longer and may change.</p>

> **The token is a password.** Anyone who has it can send as your bot and
> read what is sent to it. If it leaks, send `/revoke` to BotFather for a new
> one and paste the new one into Composer.

Now choose where the messages go, and get that chat's id.

<!-- walkthrough: Find the chat id -->
1. **Make the chat.** Pick one:
   - **Just you:** open your new bot in Telegram and press **Start** (or send
     it any message). A bot cannot write to a person who has not written to
     it first.
   - **A group** (the household, the service team): add the bot to the group
     as a member, then send any message in the group.
   - **A channel** (one-way announcements): add the bot to the channel as an
     **administrator** with the right to post messages.
1. In Composer, on the router's **Actions** tab, press **Find Telegram Chat
   ID**.
1. Read **Telegram Chats Seen** on the Properties tab. It lists each chat the
   bot has heard from with its id, newest first, for example
   `Family (group): -1001234567890 · Sam (private): 123456789`.
1. Type the id of the chat you want into **Telegram Chat ID**, minus sign
   included. Group and channel ids are negative.
1. Press **Send Test To Telegram**. The test arrives in that chat.

![Telegram settings on the router: the token is masked, the chat id is typed in, and Telegram Chats Seen shows what Find Telegram Chat ID found](images/telegram-settings.jpg)

**If Telegram Chats Seen stays empty.** Telegram only keeps what a bot has
not yet read, and for about a day. Write to the bot again (or remove and
re-add it to the group), then press **Find Telegram Chat ID** once more. If
it says `HTTP 409`, another program is reading this bot or the bot has a
webhook: use a bot of its own for the house. `HTTP 401` means the token is
not right.

**Groups and two-way.** In a group, Telegram by default shows a bot only the
messages that are commands, such as `/gate open`. That is enough for
keywords (`/gate` matches the keyword `gate`). To let the bot see every
message in the group, send `/setprivacy` to BotFather, choose the bot, choose
**Disable**, then remove the bot from the group and add it again. A channel
can only be sent to; messages for the house come from a private chat or a
group.

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

## Writing a message

A notification is written the way it reads, top to bottom, on the Notify
command in the programming window: a text, then a variable, then the next
text. Only the variable's **value** is sent, never its name, and it is read
at the moment the line runs.

![The Notify command: MESSAGE, then VARIABLE 1, then MESSAGE 2, and so on](images/notify-command.jpg)

<!-- walkthrough: A message with a live value in the middle -->
1. In programming, select the router in the Actions tree and choose the
   **NOTIFY** command. Pick a **CHANNEL** and a **PRIORITY**, and type a
   **TITLE**.
1. In **MESSAGE**, type the words before the value: `This system rebooted`.
1. Next to **VARIABLE 1**, press `…`. Composer opens its *Select variable…*
   tree with every room, device and variable of the project. Pick the
   variable and press OK.
1. In **MESSAGE 2**, type the words after the value: `times`.
1. Drag the green arrow into the script. If the variable holds `3`, the
   message that arrives is **This system rebooted 3 times**.

![Composer's Select variable… tree, opened from the … button next to VARIABLE 1](images/variable-picker.jpg)

![The finished line in the script](images/notify-programming.jpg)

There are four variables and five texts: MESSAGE, VARIABLE 1, MESSAGE 2,
VARIABLE 2, MESSAGE 3, VARIABLE 3, MESSAGE 4, VARIABLE 4, MESSAGE 5. Leave
any of them empty. Try it:

<div class="tryit" id="tryit">
<div class="row"><label for="t1">MESSAGE</label><input id="t1" value="This system rebooted"></div>
<div class="row var"><label for="v1">VARIABLE 1 holds</label><input id="v1" value="3"></div>
<div class="row"><label for="t2">MESSAGE 2</label><input id="t2" value="times since"></div>
<div class="row var"><label for="v2">VARIABLE 2 holds</label><input id="v2" value="Monday"></div>
<div class="row"><label for="t3">MESSAGE 3</label><input id="t3" value="."></div>
<output id="tout" for="t1 v1 t2 v2 t3" aria-live="polite">This system rebooted 3 times since Monday.</output>
<p class="hint">What arrives. Type in the boxes to change it.</p>
</div>
<script>
(function () {
  var before = [".", ",", ";", ":", "!", "?", "%", ")", "]", "}", "°"];
  var after = ["(", "[", "{", "$", "#", "£", "€"];
  function starts(s, list) { return list.some(function (p) { return s.slice(0, p.length) === p; }); }
  function ends(s, list) { return list.some(function (p) { return s.slice(-p.length) === p; }); }
  var ids = ["t1", "v1", "t2", "v2", "t3"];
  var out = document.getElementById("tout");
  if (!out) return;
  function paint() {
    var text = "", lastWasText = false;
    ids.forEach(function (id) {
      var isText = id.charAt(0) === "t";
      var piece = document.getElementById(id).value.trim();
      if (!piece) return;
      var tight = text === "" || (isText && starts(piece, before)) || (lastWasText && ends(text, after));
      text += (tight ? "" : " ") + piece;
      lastWasText = isText;
    });
    out.textContent = text || "(nothing to send)";
  }
  ids.forEach(function (id) { document.getElementById(id).addEventListener("input", paint); });
  paint();
})();
</script>

**Spaces are added for you.** The pieces are joined with one space. A text
that begins with punctuation (`. , ; : ! ? % ) °`) sits tight against the
value before it, and a text that ends with `( [ { $ # £ €` sits tight against
the value after it, so `Costs $` + `40` reads `Costs $40`.

**Picking is enough.** With only MESSAGE and VARIABLE 1 filled in, the value
follows the text: `Garage:` + a variable holding `1` is sent as `Garage: 1`.

**Putting a value anywhere, and changing how it reads.** Write `${1}` to
`${4}` inside any text (the TITLE too) and that picked variable goes there
instead of at its own row:

| You write | VARIABLE 1 | It is sent as |
| --- | --- | --- |
| `Garage is ${1\|Open\|Closed}` | Garage Door → STATE | `Garage is Open` |
| `Pool ${1\|.1}°F` | Variables → Pool Temp | `Pool 81.5°F` |
| TITLE `Garage ${1\|open\|closed}` | Garage Door → STATE | `Garage open` |

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

**The simplest way to act on a message: `MESSAGE_RECEIVED`.** When a message
is taken, the router writes its text into the variable `MESSAGE_RECEIVED`.
Program on the variable changing, and test what it says:

<!-- walkthrough: Run programming when a message says "gate open" -->
1. Set **Message Received As** to **Lower Case**. A phone capitalises the
   first word, and `Gate open` is not the same text as `gate open`.
1. In programming, open the router in the left-hand tree and select the
   variable **MESSAGE_RECEIVED**. The event is *When MESSAGE_RECEIVED
   changes*.
1. On the right, select the router's **MESSAGE_RECEIVED** variable again and
   open the **Conditionals** tab. Choose **Is =** and type `gate open`. Drag
   the question mark into the script.
1. Drag what should happen (open the gate) onto that condition, so it sits
   indented under it.
1. Add one more condition for each other message you want to answer, on the
   same event.

![Programming on MESSAGE_RECEIVED: the event on the left, and on the right the condition "is equal to gate open"](images/message-received.jpg)

- **Programming can set it.** `MESSAGE_RECEIVED` is not read-only: the
  Commands tab has *Set to Value*, so a routine can clear it or write to it.
- **The same message twice still runs.** If the variable already holds the
  text that arrives, the router empties it first and then writes the text,
  so the change is seen. Your condition is simply false for the empty step.
- Only a message that was **taken** reaches it (see *Who is taken*), with
  the Inbound PIN already removed.
- The other variables below keep the message exactly as sent, whatever
  **Message Received As** says.

**What else programming gets.**

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
- **Reply** (command): sends its message back to whoever wrote last, on the
  channel they used. It is written in the same pieces as Notify, so *When
  Keyword 1 Received → Reply "Garage is" + VARIABLE 1* answers a status
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
| Find Telegram Chat ID | Lists the chats that wrote to the bot, with their ids, in **Telegram Chats Seen** and the Lua output. Takes nothing: the messages stay unread for the listener |
| Clear Delivery Log | Empties the log |
| Register With Agent Now / Refresh Status | Licence and status refresh |

## Programming

- Commands: **Notify** (CHANNEL, PRIORITY, TITLE, then MESSAGE, VARIABLE 1,
  MESSAGE 2, VARIABLE 2 … VARIABLE 4, MESSAGE 5), **Notify All** (PRIORITY,
  TITLE and the same pieces), **Reply** (the same pieces, no title).
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
  `SMS_LAST_MESSAGE`, `MESSAGE_COUNTER`, `MESSAGES_RECEIVED_TODAY`, and
  `MESSAGE_RECEIVED`, the one programming may also set.

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

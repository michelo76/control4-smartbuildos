# SmartBuildOS AI Core

SmartBuildOS AI Core lets your Composer programming ask the SmartBuildOS AI a
question, record what happens in the home, ask for an analysis, a scene
suggestion, a report or a diagnostic, and react when the AI has a result, a
pattern, a recommendation or an action waiting for approval.

The AI runs in the SmartBuildOS cloud, never on the controller. The controller
holds no AI and **no AI provider key**: the key is entered in System Studio and
stays there. This driver sends requests, shows results and fires Composer
events. It **never controls equipment**: actions the AI proposes are approved by
the homeowner and executed by the SmartBuildOS Agent's command queue.

Requires the **SmartBuildOS Agent** (`smartbuildos.c4z`) with module contract
v2, paired to a SmartBuildOS system. An older Agent registers the driver but
shows *Agent update required*. The Agent is the licensing authority (SKU
`SBOS_AI_CORE`). The **SmartBuildOS Flight Recorder** is recommended: AI Core
reads its events instead of collecting them twice, and attaches its local
history to diagnostics. One AI Core per project. Control4 OS 3.3.2 or later.

**One physical controller has loaded this driver**: it showed its properties,
and a real SmartBuildOS cloud accepted its requests. Nothing else has been
exercised on hardware: no AI answer has been seen there, and the touchscreen
page and the PIN flow have not been opened. Everything else has been tested with
unit tests and in a Director emulator only. See *What is not claimed*.

## Setup

<!-- walkthrough: Add AI Core -->

1. Install and pair the SmartBuildOS Agent (an Agent build with module contract
   v2).
1. Optionally add the SmartBuildOS Flight Recorder.
1. Add **SmartBuildOS AI Core** to the project (any room).
1. Wait for **SmartBuildOS Connection Status** to read *Connected* and **AI
   Status** to read *Ready*. Run *Test Agent Link* if it does not.
1. In System Studio, choose the AI provider, enter its key, and set learning,
   exclusions and the permission mode. **AI Provider**, **AI Model**, **AI API
   Credential** and **Permission Mode** fill in when the configuration arrives.
   Learning stays **off** until it is switched on there.
1. Run *Test AI Connection*.

## Programming

### Commands

Every command checks its parameters first and refuses — sending nothing — when
one is missing, too long or not in its list; the reason is in **Last Error** and
`AI_LAST_ERROR`. Lengths count characters (an accented letter or an emoji is one
character). `ROOM` is a room name or a room id; for a room whose name is longer
than 64 characters, use its id. At most 10 AI commands a minute.

Text is sent clean: control characters and line or paragraph separators become
spaces, and the names Control4 gives rooms and devices are shortened to what
SmartBuildOS accepts (room 64, device 120 characters), never in the middle of a
character.

| Command                     | Parameters                                                                                                                                                                                                                               | What happens                                                                                                                                                           |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AI_ASK`                    | `QUESTION` (required, up to 500 characters), `ROOM` (optional)                                                                                                                                                                           | Asks the AI. The answer arrives later: **AI Response Ready**, `AI_LAST_RESPONSE`                                                                                       |
| `AI_ANALYZE_ROOM`           | `ROOM` (required)                                                                                                                                                                                                                        | Asks for an analysis of one room                                                                                                                                       |
| `AI_ANALYZE_SYSTEM`         | —                                                                                                                                                                                                                                        | Asks for an analysis of the whole system                                                                                                                               |
| `AI_RECORD_EVENT`           | `NAME` (required, up to 120), `DETAIL` (optional, up to 400), `ROOM` (optional), `CATEGORY` (optional, default General: General, Lighting, Comfort, Media, Security, Access, Safety, Energy, Presence, System, Programming, Maintenance) | Records a named marker. It says what your programming reports, not an observed result. Works with learning on, off or paused; refused for an excluded room or category |
| `AI_SET_CONTEXT`            | `KEY` (required: Occupancy, Guests Present, Vacation, Quiet Hours, Special Event, Cleaning, Maintenance Window), `VALUE` (required, up to 120)                                                                                           | Tells the AI about the home's situation                                                                                                                                |
| `AI_LEARN_PREFERENCE`       | `STATEMENT` (required, up to 300), `ROOM` (optional)                                                                                                                                                                                     | Teaches a household preference. Refused while learning is off                                                                                                          |
| `AI_SUGGEST_SCENE`          | `ROOM` (required), `OCCASION` (required, up to 120)                                                                                                                                                                                      | Asks for a scene suggestion. A suggestion only: nothing is changed                                                                                                     |
| `AI_GENERATE_REPORT`        | `TYPE` (required: System Health, Usage, Energy, Security, Comfort, Device Reliability), `PERIOD` (required: Today, Last 24 Hours, Last 7 Days, Last 30 Days)                                                                             | Asks for a report                                                                                                                                                      |
| `AI_START_DIAGNOSTIC`       | `DEVICE` or `ROOM` (exactly one of them)                                                                                                                                                                                                 | Starts a diagnostic, with the Flight Recorder's recent local events for that device or room                                                                            |
| `AI_SEND_NOTIFICATION`      | `TITLE` (required, up to 80), `MESSAGE` (required, up to 400), `AUDIENCE` (optional, default Homeowner: Homeowner, Integrator, All)                                                                                                      | Sends a notification through SmartBuildOS; recipients are decided there                                                                                                |
| `AI_RUN_HOUSEHOLD_ANALYSIS` | —                                                                                                                                                                                                                                        | **Run Household Analysis**: asks SmartBuildOS to run the household analysis now. Needs the `AI_LEARNING` licence feature; at most one accepted run an hour. See below  |

SmartBuildOS answers each request at once: *accepted* (the result follows as
**AI Response Ready**), *done* (`AI_SET_CONTEXT`, `AI_SEND_NOTIFICATION` and a
recorded `AI_LEARN_PREFERENCE` complete at once: nothing follows and **AI
Status** stays *Ready*), or a refusal such as *not permitted*, *unsupported* or
*rate limited*. A refusal is shown as it is in **Last Error** and **AI Status**;
it is never reported as success. A command on a room excluded in System Studio
is refused (except `AI_ASK` and `AI_SEND_NOTIFICATION`).

### Run Household Analysis (`AI_RUN_HOUSEHOLD_ANALYSIS`)

Asks SmartBuildOS to run the household analysis — the learning that finds
patterns and recommendations in this home's recorded activity. It is not
`AI_ANALYZE_SYSTEM` (an AI health review whose text comes back as **AI Response
Ready**). SmartBuildOS can also run the analysis on a schedule the dealer
chooses in System Studio; this command runs it when your programming says so.

- The normal answer is *accepted (queued)*: SmartBuildOS took the request and
  runs the analysis afterwards. **The driver is never told when the run
  finishes**; the result appears in System Studio. No **AI Response Ready**
  fires and **AI Status** stays *Ready*. *Completed* is shown only when
  SmartBuildOS says the run already finished; any other acceptance is shown as
  plain *accepted*.
- Without the `AI_LEARNING` licence feature it is refused on the controller
  (**Last Error** says so) and nothing is sent.
- At most one **accepted** run an hour from this controller, and one request
  waiting at a time; a press inside that is refused on the controller with
  *refused locally (rate_limited)*, so programming that fires it in a loop sends
  nothing. A refused, offline or timed-out attempt does not use up the hour.
  SmartBuildOS has its own limit of one accepted run an hour per home.
- A refusal from SmartBuildOS is shown with its reason, for example *refused
  (learning_not_allowed)* (learning is off or paused for this home), *refused
  (not_licensed)*, *refused (already_running)* or *refused (rate_limited)* with
  the time to wait.
- *the SmartBuildOS Agent refused it (not_permitted)*: the Agent is older than
  this command; update the SmartBuildOS Agent.

### Events

| Event                           | When                                                                                                            |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| AI Response Ready               | A result arrived (`AI_LAST_RESPONSE`, `AI_LAST_RESPONSE_ID`)                                                    |
| Pattern Detected                | SmartBuildOS found a pattern (`AI_LAST_EVENT_DETAIL`)                                                           |
| Recommendation Available        | A recommendation waits in System Studio (`AI_RECOMMENDATION_COUNT`)                                             |
| Automation Conflict Detected    | Programming or automations conflict (`AI_LAST_EVENT_DETAIL`)                                                    |
| Device Failure Pattern Detected | A device keeps failing (`AI_LAST_EVENT_DETAIL`)                                                                 |
| Approval Required               | An AI-proposed action waits for the homeowner (`AI_PENDING_APPROVALS`)                                          |
| Action Completed                | An approved action completed                                                                                    |
| Action Failed                   | An approved action failed                                                                                       |
| Agent Disconnected              | This driver lost the SmartBuildOS Agent (registration lost, Agent restarted, or the Agent stopped answering)    |
| AI Provider Error               | The AI provider chosen in System Studio returned an error (also shown in `AI_LAST_ERROR` until the next result) |

Wire the events you care about to the Notification Agent for push or email.

### Variables

| Variable                  | Type   | Holds                                                                                                                                                        |
| ------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `AI_STATUS`               | STRING | `ready`, `working`, `no_agent`, `agent_update_required`, `agent_lost`, `registering`, `agent_unpaired`, `cloud_unreachable`, `unlicensed`                    |
| `AI_LAST_RESPONSE`        | STRING | The last result, up to 1024 bytes (an ordinary letter is 1 byte, an accented letter 2, an emoji 4); a longer one is cut between characters and ends in `...` |
| `AI_LAST_RESPONSE_ID`     | STRING | Its id                                                                                                                                                       |
| `AI_LAST_REQUEST_ID`      | STRING | The id of the last command sent                                                                                                                              |
| `AI_LAST_EVENT_DETAIL`    | STRING | Detail of the last event (up to 512 bytes, cut between characters)                                                                                           |
| `AI_PENDING_APPROVALS`    | NUMBER | Actions waiting for approval                                                                                                                                 |
| `AI_RECOMMENDATION_COUNT` | NUMBER | Recommendations available                                                                                                                                    |
| `AGENT_CONNECTED`         | BOOL   | Registered with the Agent and answered                                                                                                                       |
| `LEARNING_ACTIVE`         | BOOL   | Learning is on (false until System Studio switches it on)                                                                                                    |
| `AI_LAST_ERROR`           | STRING | The last error or refusal, including an AI provider error reported by SmartBuildOS (empty when none)                                                         |
| `AI_LAST_CORRELATION_ID`  | STRING | What the last SmartBuildOS event is about — for Approval Required / Action Completed / Action Failed, the action's id (empty when none)                      |

### Conditionals

`AI_READY`, `AGENT_CONNECTED`, `LEARNING_ACTIVE`, `APPROVALS_PENDING`,
`RECOMMENDATIONS_AVAILABLE`.

## Properties

Read-only except **Log Level**, **Log Mode**, **Touchscreen Detail** and **App
Relay Address**.

| Property                       | Shows                                                                                                                                                                                                    |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Driver Status                  | *Online* once started                                                                                                                                                                                    |
| Driver Version                 | The installed build                                                                                                                                                                                      |
| SmartBuildOS Connection Status | *Connected*, or what is wrong (no Agent, Agent update required, not responding, not paired, cloud unreachable)                                                                                           |
| Agent Pairing Status           | Whether the Agent is paired to SmartBuildOS                                                                                                                                                              |
| Property ID                    | The SmartBuildOS property, once System Studio delivers it                                                                                                                                                |
| Controller ID                  | The SmartBuildOS controller id, once delivered                                                                                                                                                           |
| AI Provider                    | The AI provider chosen in System Studio                                                                                                                                                                  |
| AI Model                       | The model chosen in System Studio                                                                                                                                                                        |
| AI API Credential              | Status only, e.g. *Configured in System Studio · Anthropic ••••abcd*. Keys are entered in System Studio and never reach the controller                                                                   |
| AI Status                      | *Ready*, *Working*, or why not; the last refusal is added when there is one                                                                                                                              |
| Telemetry Status               | Events sent through the Agent, or held while no Agent answers, and how many were dropped                                                                                                                 |
| Learning Status                | *Off (not switched on in System Studio)* until it is switched on; then *Active*, or who paused it and why                                                                                                |
| Permission Mode                | *observe*, *recommend* or *execute_low_risk* — set in System Studio, not here                                                                                                                            |
| Flight Recorder Link           | Whether a Flight Recorder is installed and read                                                                                                                                                          |
| License Status                 | This driver's licence, as the Agent reports it                                                                                                                                                           |
| License Source                 | Included with the subscription, or purchased                                                                                                                                                             |
| Subscription Tier              | The company's tier                                                                                                                                                                                       |
| SmartBuildOS Company           | The company the project is licensed to                                                                                                                                                                   |
| Last Synchronization           | The last time SmartBuildOS was heard from                                                                                                                                                                |
| Last Test Result               | The result of *Test Agent Link* or *Test AI Connection*                                                                                                                                                  |
| Last Error                     | The last error or refusal                                                                                                                                                                                |
| Touchscreen Detail (editable)  | What the touchscreen chat may answer: *Basic* (no chat), *Standard* (no household activity) or *Household* (only if the homeowner allows it in the portal). It can only lower what the homeowner allowed |
| Touchscreen Approvals          | The touchscreen chat and approvals in plain words: whether PIN Lock can check an owner PIN here, and whether the homeowner switched approvals on                                                         |
| Webview Address                | Where the AI Core page is served on the home network (port 47871)                                                                                                                                        |
| App Relay Address (editable)   | *Auto*, or the controller's LAN address when **Webview Address** says it is unknown (set the same value on PIN Lock)                                                                                     |
| Log Level                      | How much the driver logs                                                                                                                                                                                 |
| Log Mode                       | Where it logs                                                                                                                                                                                            |

## Actions

| Action             | Does                                                                                      |
| ------------------ | ----------------------------------------------------------------------------------------- |
| Test Agent Link    | Asks the Agent for its directory and shows its version, protocol, pairing and cloud state |
| Test AI Connection | Asks SmartBuildOS to test the AI provider; the result arrives as AI Response Ready        |
| Sync Now           | Re-registers if needed, sends what is waiting, and asks SmartBuildOS for its status       |
| Print Diagnostics  | Prints every state and counter to the Lua output                                          |
| Republish App URL  | Sends the AI Core page's address to Navigator again (close and reopen the tile after it)  |

## What System Studio controls

Configuration arrives through the Agent (SKU `SBOS_AI_CORE`): learning on or
off, rooms and categories to exclude, the permission mode, the provider and
model names, the key's status text, and what the driver collects. The whole
document is checked; if any part is wrong — or anything in it looks like a key —
none of it is applied, the previous one stays, **Last Error** says why, and
learning is turned off until a valid configuration turns it on again.

When learning is paused or resumed, or an exclusion changes — by you in System
Studio or by the homeowner in their portal — SmartBuildOS also tells the driver
at once (`set_learning`, `apply_config`) instead of waiting for the Agent's next
check-in. The configuration still decides: an older instruction arriving late
never undoes a newer configuration. If the controller is offline, nothing is
lost; the next configuration brings it up to date.

Until System Studio says otherwise, everything is off: learning, the Director
system events, the Flight Recorder's topics, the Agent's events and any
variables. Nothing is excluded (with nothing collected there is nothing to
exclude), and the provider, model, key status, permission mode and ids read *Not
configured* or *Not delivered yet*.

SmartBuildOS can also send nine restricted operations through the Agent:
`apply_config`, `refresh_status`, `deliver_result` (a result: variables and AI
Response Ready), `raise_event` (one of the events above, from a closed list;
never Agent Disconnected; it may name what it is about, shown in
`AI_LAST_CORRELATION_ID`), `set_learning`, `run_diagnostic`, `run_driver_query`
and `invoke_driver_action`. None of them runs code. The last two pass a
read-only question, or an action a person approved, to the SmartBuildOS driver
that declared it; an action needs the Agent's Remote Control property at Comfort
or above, goes only to a driver the Agent has verified, and is reported as done
only when that driver says it succeeded.

The ninth, `read_device_state`, reads ONE device's current variables once, when
SmartBuildOS asks a live question about it, and changes nothing: it writes no
variable and sends no command. AI Core filters the answer here, before anything
leaves the home: names and values that look like codes, passwords, keys,
people's names, phone numbers, e-mail or network addresses are never sent;
without the homeowner's permission, presence-revealing names are dropped and
locks, security panels, doors and gates, motion and contact sensors, relays and
lights are refused outright; cameras are always refused. The answer says when
the device was read; Control4 does not say when a value last changed. Tested in
the emulator only; not yet on a controller.

## Reports from other SmartBuildOS drivers

Other SmartBuildOS drivers in the project report to AI Core what they are, their
current state, events and faults (their own **AI Core** property shows whether
that works). AI Core checks every report, keeps a small picture per driver in
memory and sends the reports to SmartBuildOS in batches, at most three a minute.
When SmartBuildOS does not take a batch, AI Core keeps each driver's description
for the next one and waits longer between tries, up to ten minutes. Report text
is treated as data and never as an instruction. Tested in the emulator only; not
yet on a controller.

## The AI Core tile (touchscreen and phone app)

AI Core adds an **AI Core** tile to Navigator. The page works **only on the home
network**: a phone away from home cannot reach it, and there is no cloud
fallback. Three parts:

- **Status** (no PIN): licensed or not, AI provider set up or not, online or
  offline, learning on or off, how many items await approval (a number only) and
  whether PIN Lock can check a PIN on this screen.
- **Chat** (owner PIN to open it and to ask): locked until someone enters an
  **owner** PIN from the **SmartBuildOS PIN Lock** driver. It locks again after
  5 minutes without use, when the page closes, when the driver restarts, and
  when someone presses *Lock*. Each question is answered on its own (no
  follow-ups). Answers stay on that page only: they never go to
  `AI_LAST_RESPONSE` and never fire *AI Response Ready*. Once unlocked, the chat
  offers the three built-in questions and, before them, up to 6 **preset
  questions** your integrator set in System Studio (they arrive with the AI Core
  configuration). A locked chat shows none. Pressing a preset asks exactly that
  question; after the list changes, an old button is refused rather than
  answered as another question.
- **Approvals** (one owner PIN per item): *Review next item* asks for the PIN,
  then shows the item's title, description and risk; *Approve* or *Decline*
  within 60 seconds. Only low- and medium-risk action proposals can be decided
  here, and only after the homeowner switches touchscreen approvals on in the
  SmartBuildOS portal. Everything else says *use the SmartBuildOS portal*.

The PIN is typed on the AI Core page but sent **only to PIN Lock** (its own page
address on the same controller), never to AI Core. Guest, vendor and staff codes
never work here. Wrong PINs count against PIN Lock's own lockout. Without PIN
Lock (not installed, not licensed, no owner PIN, switched off there, locked out
or not answering) the chat and approvals are unavailable and the page says to
use the portal. Tested in the emulator only; the page has not been opened on a
real touchscreen or phone.

## What it collects

With the Flight Recorder installed, AI Core reads its device events, variable
changes and programming traces instead of capturing them again, and records only
what the recorder does not: Director system events (device online and offline,
network bindings, Director address). Without the recorder it also records the
Agent's system events and any variables System Studio selected. Each of these is
collected only once System Studio switches learning and that source on. Nothing
is collected while learning is off or paused, from excluded rooms or categories,
or while the driver is not licensed. Questions, reports, notifications,
diagnostics and your own `AI_RECORD_EVENT` markers work with learning off; a
marker is still refused for an excluded room or category, and SmartBuildOS never
learns household patterns from markers. Events never say who or what caused a
change, or what the value was before: Control4 does not tell a driver.

While no Agent answers, important events (warnings and above) are kept on the
controller (up to 50, dropped ones are counted) and sent, in order, when the
Agent is back.

## Troubleshooting

| Shows                                                  | Do                                                                                                                                         |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| No SmartBuildOS Agent in this project                  | Install `smartbuildos.c4z`                                                                                                                 |
| Agent update required                                  | Update the SmartBuildOS Agent to a build with module contract v2                                                                           |
| SmartBuildOS Agent not responding                      | Check the Agent is running; *Sync Now*                                                                                                     |
| SmartBuildOS Agent not paired                          | Pair the Agent                                                                                                                             |
| SmartBuildOS cloud unreachable                         | Check the internet connection; requests are not retried forever                                                                            |
| Last request refused (not_permitted)                   | SmartBuildOS refused it (permission mode, licence features, homeowner settings)                                                            |
| Refused (not licensed for this controller)             | SmartBuildOS has no AI Core licence for this controller: add one in SmartBuildOS (**Last Error** ends in *(not_entitled)*)                 |
| AI Status Ready, License Status Not Licensed           | Licence enforcement for AI Core is off in SmartBuildOS, so the driver keeps running; SmartBuildOS refuses each request instead             |
| Not Licensed right after a licence was issued          | Not re-checked yet: this Agent does it by itself at its next check-in; an older Agent needs its *Refresh Entitlements Now* action          |
| Refused by SmartBuildOS: words (reason)                | SmartBuildOS said why; the reason it sent is in brackets. A reason without words reads *code (reason)*                                     |
| Run Household Analysis: refused locally (rate_limited) | One accepted run an hour, one at a time: **Last Error** says when the next is allowed                                                      |
| Run Household Analysis: update the SmartBuildOS Agent  | The Agent does not relay this command yet: update it                                                                                       |
| Tile: Available on the home network only               | The phone is away from home, or **Webview Address** is unknown: set **App Relay Address** (and the same on PIN Lock)                       |
| Tile: PIN Lock is not installed / unavailable          | Add or license **SmartBuildOS PIN Lock**, give it an owner code with a PIN; **Touchscreen Approvals** says what is missing                 |
| Learning off / Learning paused                         | Learning is off until switched on in System Studio, or it was turned off there, or the last configuration was refused (see **Last Error**) |

## What is not claimed

- On hardware, one controller has loaded this driver and shown its properties,
  with a real SmartBuildOS cloud accepting its requests. No AI answer has been
  seen on a controller, and the touchscreen page and the PIN flow have not been
  opened on one. Everything else rests on unit tests and a Director emulator.
- The format of Director's system-event payloads is undocumented; only the event
  name is read.
- Programming cannot be observed running, and a change cannot be attributed to a
  person or a routine: Control4 provides neither.
- Results depend on the SmartBuildOS platform route for AI Core, which is
  deployed separately.

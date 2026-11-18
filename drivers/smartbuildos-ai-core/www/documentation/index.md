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

**No physical controller has run this driver yet.** It has been tested with unit
tests and in a Director emulator only. See *What is not claimed*.

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
1. Run *Test AI Connection*.

## Programming

### Commands

Every command checks its parameters first and refuses — sending nothing — when
one is missing, too long or not in its list; the reason is in **Last Error** and
`AI_LAST_ERROR`. `ROOM` is a room name or a room id. At most 10 AI commands a
minute.

| Command                | Parameters                                                                                                                                                                     | What happens                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| `AI_ASK`               | `QUESTION` (up to 500 characters), `ROOM` (optional)                                                                                                                           | Asks the AI. The answer arrives later: **AI Response Ready**, `AI_LAST_RESPONSE`                |
| `AI_ANALYZE_ROOM`      | `ROOM`                                                                                                                                                                         | Asks for an analysis of one room                                                                |
| `AI_ANALYZE_SYSTEM`    | —                                                                                                                                                                              | Asks for an analysis of the whole system                                                        |
| `AI_RECORD_EVENT`      | `NAME` (up to 120), `DETAIL` (up to 400), `ROOM`, `CATEGORY` (General, Lighting, Comfort, Media, Security, Access, Safety, Energy, Presence, System, Programming, Maintenance) | Records a named event for the AI. It says what your programming reports, not an observed result |
| `AI_SET_CONTEXT`       | `KEY` (Occupancy, Guests Present, Vacation, Quiet Hours, Special Event, Cleaning, Maintenance Window), `VALUE` (up to 120)                                                     | Tells the AI about the home's situation                                                         |
| `AI_LEARN_PREFERENCE`  | `STATEMENT` (up to 300), `ROOM` (optional)                                                                                                                                     | Teaches a household preference. Refused while learning is paused                                |
| `AI_SUGGEST_SCENE`     | `ROOM`, `OCCASION` (up to 120)                                                                                                                                                 | Asks for a scene suggestion. A suggestion only: nothing is changed                              |
| `AI_GENERATE_REPORT`   | `TYPE` (System Health, Usage, Energy, Security, Comfort, Device Reliability), `PERIOD` (Today, Last 24 Hours, Last 7 Days, Last 30 Days)                                       | Asks for a report                                                                               |
| `AI_START_DIAGNOSTIC`  | `DEVICE` or `ROOM` (one of them)                                                                                                                                               | Starts a diagnostic, with the Flight Recorder's recent local events for that device or room     |
| `AI_SEND_NOTIFICATION` | `TITLE` (up to 80), `MESSAGE` (up to 400), `AUDIENCE` (Homeowner, Integrator, All)                                                                                             | Sends a notification through SmartBuildOS; recipients are decided there                         |

SmartBuildOS answers each request at once: *accepted* (the result follows) or a
refusal such as *not permitted* or *unsupported*. A refusal is shown as it is in
**Last Error** and **AI Status**; it is never reported as success. A command on
a room excluded in System Studio is refused (except `AI_ASK` and
`AI_SEND_NOTIFICATION`).

### Events

| Event                           | When                                                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| AI Response Ready               | A result arrived (`AI_LAST_RESPONSE`, `AI_LAST_RESPONSE_ID`)                                                 |
| Pattern Detected                | SmartBuildOS found a pattern (`AI_LAST_EVENT_DETAIL`)                                                        |
| Recommendation Available        | A recommendation waits in System Studio (`AI_RECOMMENDATION_COUNT`)                                          |
| Automation Conflict Detected    | Programming or automations conflict (`AI_LAST_EVENT_DETAIL`)                                                 |
| Device Failure Pattern Detected | A device keeps failing (`AI_LAST_EVENT_DETAIL`)                                                              |
| Approval Required               | An AI-proposed action waits for the homeowner (`AI_PENDING_APPROVALS`)                                       |
| Action Completed                | An approved action completed                                                                                 |
| Action Failed                   | An approved action failed                                                                                    |
| Agent Disconnected              | This driver lost the SmartBuildOS Agent (registration lost, Agent restarted, or the Agent stopped answering) |
| AI Provider Error               | The AI provider chosen in System Studio returned an error                                                    |

Wire the events you care about to the Notification Agent for push or email.

### Variables

| Variable                  | Type   | Holds                                                                                                                                     |
| ------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `AI_STATUS`               | STRING | `ready`, `working`, `no_agent`, `agent_update_required`, `agent_lost`, `registering`, `agent_unpaired`, `cloud_unreachable`, `unlicensed` |
| `AI_LAST_RESPONSE`        | STRING | The last result (up to 1024 characters; a longer one ends in `...`)                                                                       |
| `AI_LAST_RESPONSE_ID`     | STRING | Its id                                                                                                                                    |
| `AI_LAST_REQUEST_ID`      | STRING | The id of the last command sent                                                                                                           |
| `AI_LAST_EVENT_DETAIL`    | STRING | Detail of the last event (up to 512 characters)                                                                                           |
| `AI_PENDING_APPROVALS`    | NUMBER | Actions waiting for approval                                                                                                              |
| `AI_RECOMMENDATION_COUNT` | NUMBER | Recommendations available                                                                                                                 |
| `AGENT_CONNECTED`         | BOOL   | Registered with the Agent and answered                                                                                                    |
| `LEARNING_ACTIVE`         | BOOL   | Learning is on                                                                                                                            |
| `AI_LAST_ERROR`           | STRING | The last error or refusal (empty when none)                                                                                               |

### Conditionals

`AI_READY`, `AGENT_CONNECTED`, `LEARNING_ACTIVE`, `APPROVALS_PENDING`,
`RECOMMENDATIONS_AVAILABLE`.

## Properties

Read-only except **Log Level** and **Log Mode**.

| Property                       | Shows                                                                                                                                  |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Driver Status                  | *Online* once started                                                                                                                  |
| Driver Version                 | The installed build                                                                                                                    |
| SmartBuildOS Connection Status | *Connected*, or what is wrong (no Agent, Agent update required, not responding, not paired, cloud unreachable)                         |
| Agent Pairing Status           | Whether the Agent is paired to SmartBuildOS                                                                                            |
| Property ID                    | The SmartBuildOS property, once System Studio delivers it                                                                              |
| Controller ID                  | The SmartBuildOS controller id, once delivered                                                                                         |
| AI Provider                    | The AI provider chosen in System Studio                                                                                                |
| AI Model                       | The model chosen in System Studio                                                                                                      |
| AI API Credential              | Status only, e.g. *Configured in System Studio · Anthropic ••••abcd*. Keys are entered in System Studio and never reach the controller |
| AI Status                      | *Ready*, *Working*, or why not; the last refusal is added when there is one                                                            |
| Telemetry Status               | Events sent through the Agent, or held while no Agent answers, and how many were dropped                                               |
| Learning Status                | *Active*, or who paused it and why                                                                                                     |
| Permission Mode                | *observe*, *recommend* or *execute_low_risk* — set in System Studio, not here                                                          |
| Flight Recorder Link           | Whether a Flight Recorder is installed and read                                                                                        |
| License Status                 | This driver's licence, as the Agent reports it                                                                                         |
| License Source                 | Included with the subscription, or purchased                                                                                           |
| Subscription Tier              | The company's tier                                                                                                                     |
| SmartBuildOS Company           | The company the project is licensed to                                                                                                 |
| Last Synchronization           | The last time SmartBuildOS was heard from                                                                                              |
| Last Test Result               | The result of *Test Agent Link* or *Test AI Connection*                                                                                |
| Last Error                     | The last error or refusal                                                                                                              |
| Log Level                      | How much the driver logs                                                                                                               |
| Log Mode                       | Where it logs                                                                                                                          |

## Actions

| Action             | Does                                                                                      |
| ------------------ | ----------------------------------------------------------------------------------------- |
| Test Agent Link    | Asks the Agent for its directory and shows its version, protocol, pairing and cloud state |
| Test AI Connection | Asks SmartBuildOS to test the AI provider; the result arrives as AI Response Ready        |
| Sync Now           | Re-registers if needed, sends what is waiting, and asks SmartBuildOS for its status       |
| Print Diagnostics  | Prints every state and counter to the Lua output                                          |

## What System Studio controls

Configuration arrives through the Agent (SKU `SBOS_AI_CORE`): learning on or
off, rooms and categories to exclude, the permission mode, the provider and
model names, the key's status text, and what the driver collects. The whole
document is checked; if any part is wrong — or anything in it looks like a key —
none of it is applied, the previous one stays, and **Last Error** says why.

SmartBuildOS can also send six restricted operations through the Agent:
`apply_config`, `refresh_status`, `deliver_result` (a result: variables and AI
Response Ready), `raise_event` (one of the events above, from a closed list;
never Agent Disconnected), `set_learning`, `run_diagnostic`. None of them
controls equipment or runs code.

## What it collects

With the Flight Recorder installed, AI Core reads its device events, variable
changes and programming traces instead of capturing them again, and records only
what the recorder does not: Director system events (device online and offline,
network bindings, Director address). Without the recorder it also records the
Agent's system events and any variables System Studio selected. Nothing is
collected while learning is paused, from excluded rooms or categories, or while
the driver is not licensed. Events never say who or what caused a change, or
what the value was before: Control4 does not tell a driver.

While no Agent answers, important events (warnings and above) are kept on the
controller (up to 50, dropped ones are counted) and sent, in order, when the
Agent is back.

## Troubleshooting

| Shows                                 | Do                                                                              |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| No SmartBuildOS Agent in this project | Install `smartbuildos.c4z`                                                      |
| Agent update required                 | Update the SmartBuildOS Agent to a build with module contract v2                |
| SmartBuildOS Agent not responding     | Check the Agent is running; *Sync Now*                                          |
| SmartBuildOS Agent not paired         | Pair the Agent                                                                  |
| SmartBuildOS cloud unreachable        | Check the internet connection; requests are not retried forever                 |
| Last request refused (not_permitted)  | SmartBuildOS refused it (permission mode, licence features, homeowner settings) |
| Learning paused                       | Learning was turned off in System Studio                                        |

## What is not claimed

- No physical controller has run this driver. Unit tests and a Director emulator
  are the only evidence so far.
- The format of Director's system-event payloads is undocumented; only the event
  name is read.
- Programming cannot be observed running, and a change cannot be attributed to a
  person or a routine: Control4 provides neither.
- Results depend on the SmartBuildOS platform route for AI Core, which is
  deployed separately.

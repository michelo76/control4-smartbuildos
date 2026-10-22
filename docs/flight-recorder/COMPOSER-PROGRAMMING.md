# Flight Recorder — Composer programming guide

The driver **SmartBuildOS Flight Recorder** (`smartbuildos-flight-recorder.c4z`)
adds Device Specific Commands to Composer programming. Every trace command
takes a **CHANNEL**: a short name you type (default `main`). Composer cannot
hand a value a command returns back to programming, so there is no "trace
handle" — the channel IS the handle. One routine, one channel.

## Commands

| Command | Params | Records |
| --- | --- | --- |
| Record Event | NAME, DETAIL, CHANNEL (optional), DEVICE (optional) | `observation.programmed` (evidence `requested`): what the programming asked for; if the channel has an active trace the event is correlated to it |
| Start Trace | NAME, CHANNEL | `trace.start` |
| Record Trace Step | MESSAGE, CHANNEL, DEVICE (optional) | `trace.step` |
| Record Trace Decision | CONDITION, OUTCOME, CHANNEL | `trace.decision` |
| Record Expected Result | EXPECTED, CHANNEL, DEVICE (optional) | `trace.expected` (evidence `requested`): what you expect to observe next. The recorder never checks it. |
| Complete Trace | NOTE, CHANNEL | `trace.end` status `completed` |
| Fail Trace | REASON, CHANNEL | `trace.end` status `failed` |
| Capture Snapshot | NOTE | an asynchronous snapshot job |
| Pause Recording | REASON | listeners released; open traces interrupted |
| Resume Recording | — | sources re-read as initial observations |

## Concurrency rules (please read)

- Two executions of the same routine on the SAME channel are never merged:
  a Start Trace on an active channel ends the earlier trace as
  `interrupted` (reason "superseded") and opens a new one.
- Routines that can overlap use DIFFERENT channels (`good_night`,
  `garage_check`, `welcome_home`). Up to 16 traces may be active at once; a
  17th Start is refused and recorded as `trace.refused`.
- A step on an idle channel is recorded as an **orphan step** (visible in
  Activity, not attached to any trace).
- Complete/Fail on an idle channel records `trace.duplicate_completion` and
  changes nothing.
- A trace with no Complete/Fail within 10 minutes ends as `abandoned`.
- A driver reload or pause ends open traces as `interrupted` (reason given).

## The Good Night routine (acceptance scenario)

```
When "Good Night" button is pressed
  Flight Recorder → Start Trace            NAME "Good Night"           CHANNEL good_night
  Flight Recorder → Record Trace Step      MESSAGE "Kitchen pendants: OFF requested"  DEVICE Kitchen Pendants  CHANNEL good_night
  Kitchen Pendants → Off
  Flight Recorder → Record Expected Result EXPECTED "Kitchen pendants at 0%"  DEVICE Kitchen Pendants  CHANNEL good_night
  Flight Recorder → Record Trace Step      MESSAGE "Garage contact check"  DEVICE Garage Door  CHANNEL good_night
  If Garage Door is Closed
     Flight Recorder → Record Trace Decision CONDITION "Garage door closed?" OUTCOME "yes" CHANNEL good_night
     Flight Recorder → Complete Trace      NOTE "ok"                   CHANNEL good_night
  Else
     Flight Recorder → Record Trace Decision CONDITION "Garage door closed?" OUTCOME "no"  CHANNEL good_night
     Flight Recorder → Fail Trace          REASON "garage open"        CHANNEL good_night
```

With `Kitchen Pendants · LIGHT_LEVEL` and `Garage Door · ContactState`
selected as sources (Recorder settings, or the Lighting + Contacts templates),
the timeline shows: trace start → step (requested) → expected (requested) →
**observation.change LIGHT_LEVEL 75 → 0 (observed)** → step → decision →
trace end. The observed change is NOT correlated to the trace: Studio shows
it beside the expected result and lets a person judge.

## What is recorded about a message

Programmer text (MESSAGE, DETAIL, CONDITION, EXPECTED, NOTE, REASON) is
stored as `quality = unreviewed_text`, bounded to 400 characters, and
redacted for credential-looking content. Do not put codes or names you would
not want in a service record into a trace message.

## Composer properties, events, conditionals, variables

Properties: Recording Status, Agent Link, Agent Connection, License Status,
Configuration (applied/desired), Selected Sources, Active Traces, Buffered
Events, Dropped Events, Last Upload, Last Recording Error, Last Snapshot,
Template (+ action Apply Selected Template), Buffer Warning Threshold.

Events: Recording Degraded, Recording Restored, Buffer Threshold Reached,
Snapshot Completed, Snapshot Failed, Trace Completed, Trace Failed, Agent
Connected, Agent Disconnected.

Conditionals: Recording is active; SmartBuildOS Agent link is ready.

Variables (read-only): RECORDING_STATUS, AGENT_CONNECTION, SELECTED_SOURCES,
ACTIVE_TRACES, BUFFERED_EVENTS, DROPPED_EVENTS, LAST_UPLOAD,
LAST_RECORDING_ERROR, CONFIG_VERSION. The recorder refuses its own device as
a source, so these never feed back into recording.

Actions: Register With Agent Now, Pause/Resume Recording, Capture Snapshot,
Apply Selected Template, Clear Composer Sources, Print Recording Status,
Print Sources, Refresh Status.

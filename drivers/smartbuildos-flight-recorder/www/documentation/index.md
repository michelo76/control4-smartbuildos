# SmartBuildOS Flight Recorder

When a homeowner says "the hall light came on at 3 am" or "the lights did not
go off last night", the question is what the system actually did. The Flight
Recorder keeps that record. It writes down every Composer event your devices
fire, with no configuration; the value before and after each change of the
variables you select; and what your programming says it is doing, step by
step. All three go into one history on the controller, in order, which you
print from the Actions tab, and through the **SmartBuildOS Agent** to System
Studio. Event capture used to be a separate driver, the Event Tracer. It is
now part of this one, and that driver no longer exists.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`, a build with module
services) paired to a SmartBuildOS system. Update the Agent together with this
driver: an Agent build from before the two drivers were merged does not know
that device events belong to the Flight Recorder and refuses them. The Agent is
the licensing authority (SKU `SBOS_FLIGHT_RECORDER`): **License Status** shows
this driver's standing. Recording and the local history work without the Agent
and during an internet outage; uploads wait in the Agent's bounded, journaled
queue. One Flight Recorder per project. Control4 OS 3.3.2 or later.

## Why Composer alone does not answer it

Composer shows what is programmed: pick a device and one of its events and you
read the script. To explain something that happened overnight you need the
other half: which events fired, on which devices, in what order, and what the
values were. As far as we know Composer keeps no history of that which you can
open the next morning, and it shows what a variable holds now, not what it
held at 3 am. The usual method is to read the programming and guess.

A driver cannot ask for it afterwards either. Director hands a device's event
or a variable's change to a driver only when the driver asked for it
beforehand. The Flight Recorder asks when it starts, and writes each one down
as it arrives.

Composer is still the right tool when you already know which event matters
(read its script in Programming), when you can make the problem happen while
you are on site (trigger it and watch), and when you want to know what a
script does: the recorder writes down events, values and what a script
reports about itself; it never reads programming.

## Three layers, one history

| Layer | What it records | Setup | Where it shows |
| --- | --- | --- | --- |
| Events | Every Composer event of every device the driver has a catalogue for: which device, which event, when | None. On as soon as the driver is added (**Event Capture**) | The history, **Last Event**, **Events Captured** |
| Variables | The value before and after each change of the device and room variables you select, and the SmartBuildOS system events you select | Nothing is recorded until you select sources: a **Template**, or Recorder settings in System Studio | The history, *Print Sources*, **Selected Sources** |
| Routines | What your programming says it is doing: traces, markers, expected results. And a diagnostic snapshot on demand | Commands you add to the routines you want to read back | The history, *Print Last Trace*, **Last Trace**, **Last Snapshot** |

The three layers share one status (**Recording Status**), one pause, one
licence and one history: "the door opened, the button was pushed, the routine
started, the light went from 0 to 100" reads as four lines of one list.

## What it is for

| You want | Use |
| --- | --- |
| The events and changes around a moment last night, in order | *Print Recent History* |
| One device's events, changes and trace steps, however busy the rest of the house was | **Inspect Device ID** and *Print History For Inspect Device* |
| To know afterwards what a light's level or a contact's state was, before and after | A source on its variable: **Template** and *Apply Selected Template*, or Recorder settings in System Studio |
| To see whether a routine ran to the end, which branch it took, and what the house did meanwhile | `START_TRACE`, `RECORD_TRACE_STEP`, `RECORD_TRACE_DECISION`, then `COMPLETE_TRACE` or `FAIL_TRACE`; read it with *Print Last Trace* |
| What the routine asked for, next to what the device then reported | `RECORD_EXPECTED_RESULT`, and a source on that device |
| Proof that a routine ran, with no trace | `RECORD_EVENT` as its first line |
| To be told when a sensor or contact is chattering | *Event Storm Detected*, **Active Storms**, the conditional *An event storm is in progress* |
| To know which devices are covered and which are not | **Event Coverage**, *Print Event Coverage* |
| A device whose driver is in no catalogue | **Probe Unknown Drivers**, then *Unknown Event Learned* |
| A noisy or private device left out | **Exclude Device IDs**, **Exclude Driver Files** |
| Controller restarts, project changes and programming changes in the same record | The `SmartBuildOS events` template |
| The recorder's state and its history at the moment of a fault | `CAPTURE_SNAPSHOT`, or the action *Capture Snapshot* |
| To be told when a routine did not finish | The event *Trace Failed* |
| To be told when recording is impaired or events are piling up | *Recording Degraded*, *Buffer Threshold Reached* |
| Nothing recorded during a service visit | `PAUSE_RECORDING` and `RESUME_RECORDING`, or the actions *Pause Recording* and *Resume Recording* |
| To check from programming whether recording is on | The conditional *Recording is active*, or `RECORDING_STATUS` |
| The same record without going to site | The upload through the Agent to System Studio |

## Setup

<!-- walkthrough: Set up Flight Recorder -->
1. Install the SmartBuildOS Agent from Composer's Agents tab and pair it.
1. Add this driver (one per project). **Driver Status** reads `Online`,
   **Agent Link** shows the Agent's device id, **Agent Connection** reads
   `ready` once registered and **License Status** shows the licence.
1. Event capture has already started. **Event Coverage** reports how many
   event subscriptions are active on how many devices, and how many devices
   no catalogue knows. **Event Catalogue** says where the subscriptions came
   from. **Recording Status** reads `recording`.
1. Make a covered device do something. **Last Event** names the device and
   the event about two seconds later, and *Print Recent History* shows it in
   the Lua tab.
1. Run *Print Event Coverage* and check that the devices you care about are
   listed with events. For one that reads `unknown`, see
   [An unknown driver](#an-unknown-driver-probe-learn-then-switch-the-probe-off).
1. Optionally, select the variables to record: in System Studio (Activity →
   Flight Recorder → Recorder settings), or choose a **Template** here and
   run *Apply Selected Template*. **Selected Sources** then reads, for
   example, `1 selected, 1 listening`.
1. Optionally, add the trace commands to the routines you want to read back
   (Device Specific Commands): `START_TRACE`, `RECORD_TRACE_STEP`,
   `RECORD_TRACE_DECISION`, `RECORD_EXPECTED_RESULT`, `COMPLETE_TRACE`,
   `FAIL_TRACE`, and `RECORD_EVENT` for a single marker. Every trace command
   takes a `CHANNEL` you name (default `main`); routines that may overlap use
   different channels.

## The history

Everything the three layers record goes into one list on the controller. Each
entry has a time, a sequence number that only ever goes up, and one line of
text. Each also has a kind of evidence, which the upload carries: the
recorder never turns one kind into another, and never infers success, a
button press or a cause from a nearby entry.

| Entry | A line of it | Evidence |
| --- | --- | --- |
| Device event | `02:59:38  #12  Entry / Front Door: Opened` | `observed`: Director delivered it |
| Device event with a placeholder name | `10:12:30  #50  Pool / Pool Controller: Event 5 (unnamed)` | `observed` |
| First read of a source | `22:30:09  #2  Hall / Hall Keypad: LIGHT_LEVEL = 75 (first read, not a change)` | `initial`: a state, not a change |
| Variable change | `22:41:09  #6  Hall / Hall Keypad: LIGHT_LEVEL 75 → 0` | `observed`: the device reported it |
| Several changes gathered into one | `23:31:13  #24  Hall / Hall Keypad: LIGHT_LEVEL 10 → 30 (2 changes)` | `observed` |
| Trace start, step, decision, end | `22:41:07  #3  TRACE good_night  step 1  Hall light: OFF requested  [Hall Keypad]` | `instrumented`: the programmer's words |
| Expected result | `22:41:07  #4  TRACE good_night  expects 2  Hall light at 0%  [Hall Keypad]` | `requested`: what was asked for, not what happened |
| Marker (`RECORD_EVENT`) | `02:59:51  #14  MARK  Hall light on  — Hall Keypad top button` | `requested` |
| SmartBuildOS system event | `23:10:04  #7  SYSTEM  director_reloaded` | `system` |
| The recorder's own note | `11:00:00  #52  NOTE  Recording paused` | `derived` |

- **Time.** The controller's time. An entry from an earlier day starts with
  the month and day (`11-09 22:41:07`); one from today shows the time alone.
- **Order.** Entries are in the order the recorder wrote them. Events, trace
  steps and markers are written as they arrive. A change is written when its
  source's debounce or coalesce window ends, so it can sit a second or two
  below events that in fact followed it.
- **Notes.** The recorder notes a pause and a resume, a configuration applied
  or refused, a snapshot request, a per-minute budget exceeded, and the
  beginning and end of an event storm.
- **Values.** A text value is kept up to 120 characters and printed up to 60.
  It is kept as `[redacted]` when its variable is named like a code or a
  credential, or when the value looks like a long token. A change whose
  earlier value the recorder never saw reads `→ 0 (previous value not known)`.

The history holds the newest **Local History Size** entries (500 unless you
change it). It is saved every 30 seconds while it is changing and when the
driver stops, and is read back at start, so it survives a driver update or a
restart and the sequence carries on. A power cut can lose about the last half
minute. It needs no Agent and no internet.

Three actions print it to the Lua tab:

- *Print Recent History*: the last 50 entries, oldest first.
- *Print History For Inspect Device*: the last 50 entries of the device in
  **Inspect Device ID**, from the whole history: its events, the changes of
  its variables, and the trace steps, expected results and markers that
  named it in `DEVICE`. Then how its events are covered, and the current
  value of each of its variables that is a selected source.
- *Print Last Trace*: everything between the start and the end of the last
  trace that ended. The routine's own lines (its steps, and the markers on
  its channel) are marked `>`; what the house did in between is not; the
  last line counts each. It reads the history, so it still answers after a
  restart. A trace that is still running is printed only when the history
  holds no trace that has ended.

A device that is not covered and a variable that is not a source leave no
entries, and that is not the same as "nothing happened". Occurrences an event
storm suppressed and changes dropped by the per-minute budget are counted,
not listed.

## Events: what is captured

Director fires a device event to a driver only after the driver subscribes to
that device and event id. A subscription is one device and one event id. The
recorder knows which event ids exist from three catalogues, best first:

| Catalogue | Where the event ids come from | What to know |
| --- | --- | --- |
| Project | The controller's own project data, when the OS includes each device's events in it (**Read Events From Project**) | Meant to cover Control4's built-in drivers. On the bench controller (OS 4.3) the project data carried no events: the line read `project: 0 device(s)`. Project data over 6 MB is not read |
| Built-in | A table inside the driver, generated at build time from one driver library: 187 driver files that declare events, 1,303 events | Matched by the exact driver file name. A driver that was not in that library is not in it |
| Learned | Event ids seen at run time on a probe subscription, kept across restarts | Named "Event N". Learned for the driver file, so every device on that driver gets it |

A device whose driver is in none of them is reported under **Event Coverage**
as "unknown driver" and nothing is captured from it until you probe it (see
[An unknown driver](#an-unknown-driver-probe-learn-then-switch-the-probe-off)).
The Agent is a device like any other: its own events are captured too.

Each captured event becomes one entry in the history and one upload to the
Agent. **Events Captured** counts the device events recorded since the driver
last started; it restarts at 0 after an update, the history does not.

The recorder works out its subscriptions when it starts, when you change an
event capture setting, five seconds after the Agent accepts its registration
or reports that the project changed or Director reloaded, when recording is
resumed, and when you run *Re-apply Event Capture*. It then adds and releases
only the difference; the same plan twice changes nothing. Without the Agent a
newly added device is picked up at the next of the others.

### Protection

| Limit | Setting | Default | Range | At the limit |
| --- | --- | --- | --- | --- |
| Storm | **Storm Threshold** | 30 | 0 to 600 | See below. 0 turns storm detection off |
| Upload | **Event Upload Budget** | 300 a minute | 10 to 1200 | Further device events that minute are not uploaded and are counted in **Dropped Events**, with one note in the history. The history is not budgeted, so *Print Recent History* shows what the uplink did not get |
| Subscriptions | **Max Subscriptions** | 1000 | 50 to 2500 | **Event Coverage** says how many events did not fit |
| History | **Local History Size** | 500 | 50 to 2000 | The oldest entry is dropped for each new one |
| Probe | **Probe Range** | 32 | 1 to 64 | Event ids above it cannot be discovered |

- **Storms.** When one device fires one event **Storm Threshold** times in a
  minute, counted from the first occurrence, that is a storm: one *Event
  Storm Detected* event, one note in the history and one warning uploaded.
  That event is then counted but not recorded until the minute is over, when
  *Event Storm Ended* fires and a second note carries the totals. Other
  devices and other events of the same device are not affected. A chattering
  contact cannot flood the history or the uplink; the storm itself is the
  finding. A contact that keeps chattering gives one storm a minute.
- **Subscription cap.** Events the catalogues know are subscribed first, in
  ascending device id order; probe subscriptions get what is left. What did
  not fit is listed under **Event Coverage**, never skipped silently.
- **Exclusions.** The recorder never subscribes to itself, which is why a
  new install already reads `1 excluded`.

## Variables: what is recorded

A source is one thing the recorder listens to. No variable is recorded that
is not a source. There are three kinds.

| Kind | What it is | Recorded when |
| --- | --- | --- |
| Device variable | One variable of one device, by name | The variable changes |
| Room variable | One variable of one room | The variable changes |
| SmartBuildOS event | A system event the Agent reports | The Agent reports it |

The system events a configuration can select are `director_reloaded`,
`unexpected_restart`, `os_update_started`, `project_changed`,
`programming_changed`, `clock_drift`, `device_offline`, `device_online`,
`cloud_connected` and `cloud_disconnected`.

The list of sources is a versioned configuration. System Studio owns it; the
driver checks a whole revision before applying it. If any part is invalid the
revision is refused, the last valid one stays in force, and **Configuration**
says so. The last valid configuration survives a restart and a driver update.
It holds 64 sources by default and 200 at most.

### Templates

A template adds the sources of one kind of device, for the devices in this
project that have them. Pick it in **Template** and run *Apply Selected
Template*. The driver looks through the project's devices (up to 400) for
variables with the template's names and adds those that exist, up to the source
limit. It adds to what is already selected and never adds a source twice.

| Template | Looks for these variables | Settings it gives each source |
| --- | --- | --- |
| `Lighting` | `LIGHT_LEVEL`, `Brightness Percent`, `LIGHT_STATE` | Debounce 1.5 s, coalesce 1.5 s, minimum change 1 |
| `Contacts and openings` | `ContactState`, `CONTACT_STATE`, `STATE`, `DOOR_STATE`, `GARAGE_STATE`, `OPENED`, `ContactSensorState` | No debounce |
| `Motion and occupancy` | `MotionState`, `MOTION_STATE`, `OCCUPANCY_STATE`, `MOTION` | Debounce 2 s, coalesce 5 s |
| `Room media` | `POWER_STATE`, `CURRENT_VOLUME`, `CURRENT_SELECTED_DEVICE`, `CURRENT MEDIA INFO`, `PLAYING`, as room variables | Debounce 1 s, coalesce 3 s |
| `SmartBuildOS events` | The ten system events above | None |

Names are matched without regard to capitals, spaces or underscores. A
template that finds nothing changes nothing, and **Last Recording Error** reads
`template added no sources (none exist here)` until the next status refresh.

In this build `Room media` adds nothing when applied from Composer: the
driver's own look through the project offers device variables only, and this
template wants room variables. Select room sources in System Studio.

The result is applied as a new revision marked `composer`. The next revision
saved in System Studio replaces it.

### Initial reads, changes and the three filters

- **Initial reads are not changes.** Applying a configuration reads each new
  source once and records it as a first read. The previous value of a source
  stays unknown until its first change after that read.
- **A change that is not a change is not recorded.** If a device announces the
  value it already had, nothing is recorded.
- **Debounce.** Each change restarts the source's timer; when the timer runs
  out, the last value is recorded. One record per quiet period.
- **Minimum change.** A numeric change smaller than the threshold is not
  recorded. It is measured against the last recorded value, so a slow drift
  still shows once it adds up.
- **Coalesce.** After a record, further changes inside the window are gathered
  into one record at the window's end. It carries how many changes it stands
  for, the value before the window and the latest value.

- **Budget.** The configuration allows 120 observations a minute by default,
  600 at most. Beyond it observations are dropped and counted, with one note
  in the history for that minute; a dropped observation is not in the
  history either. Device events have their own budget; trace commands and
  `RECORD_EVENT` are not counted against any.

Debounce, minimum change and coalescing are per source (debounce and coalesce
0 to 60 seconds). A template sets them; otherwise they come with the
configuration from System Studio. Composer has no property for them.

Two cases from the driver's test run. A light with the `Lighting` template is
at 40, ramps down and reports 30, 20, 10 and 0, a fifth of a second apart: the
recorder writes one change, a second and a half after the last report. A
contact with the `Contacts and openings` template has no debounce, so the door
shows twice, as the event its driver fired and as the value of its variable.
A state that is a word is flagged as unreviewed text in the upload, or not
recorded at all when the configuration excludes text values.

```text
  23:05:02  #2  Hall / Hall Keypad: LIGHT_LEVEL 40 → 0
  23:10:00  #3  Entry / Front Door: Opened
  23:10:00  #4  Entry / Front Door: ContactState Closed → Open
```

## Routines: traces, markers and snapshots

### Traces and channels

A trace is the story of one run of a routine: a start, steps, and an end.
Composer programming cannot keep a value a command returns, so there is no
handle to carry from the start to the end. The `CHANNEL` is the handle: a
short name you type, the same on every command of one routine. Left empty, it
is `main`.

| Situation | What is recorded |
| --- | --- |
| `START_TRACE` on a channel with no open trace | A new trace opens |
| `START_TRACE` on a channel that already has one | The earlier trace ends as `interrupted`; a new one opens. Two runs are never merged |
| A step, decision or expected result on a channel with no open trace | An orphan step: visible (`no trace open` in the history), attached to no trace |
| `COMPLETE_TRACE` or `FAIL_TRACE` on a channel with no open trace | A duplicate completion (a warning, `already ended` in the history); nothing else changes |
| No `COMPLETE_TRACE` or `FAIL_TRACE` within 10 minutes | The trace ends as `abandoned` (checked every 30 seconds) |
| A 17th trace while 16 are open | Refused, and the refusal is recorded |
| Recording is paused, or the driver is updated or removed | Every open trace ends as `interrupted` |

A trace that ends `completed` fires *Trace Completed*. Every other ending
(`failed`, `interrupted`, `abandoned`) fires *Trace Failed*. **Last Trace**
then reads, for example, `Good Night: completed (4 step(s), 5 s) at 22:41:12`.
Steps, decisions and expected results are numbered together and all count as
steps. In the history a step or an expected result shows the first 60
characters of its text; the upload carries all of it.

A device event or a change the recorder sees while a trace is open is not
attached to the trace. It is recorded on its own. *Print Last Trace* lists it
between the routine's lines because it happened between them, and System
Studio shows it beside the expected result, for a person to judge.

*Print Last Trace* finds the trace in the history, so it works after an update
or a restart for as long as the trace's entries are held. If the start has
rolled out of the history it says so and prints from the first entry of that
trace it still has. With no trace in the history it prints
`The history holds no trace. Add START_TRACE and COMPLETE_TRACE to a routine.`
**Last Trace** is written at the moment a trace ends.

### Markers

`RECORD_EVENT` writes one named marker: in the history as `MARK`, and in the
upload, once. `NAME` is required; a marker with no name is not recorded. With
a `DEVICE`, the marker also appears in *Print History For Inspect Device* for
that device. If its channel (`main` when left empty) has an open trace, the
marker belongs to that trace: the upload ties it to the trace, and *Print
Last Trace* marks it `>` and counts it among the routine's lines.

### Snapshots

A snapshot is diagnostic evidence, not a project backup. It holds:

- the newest 200 entries of the history, one readable line each;
- the state of event capture (coverage, catalogue, counters, settings) and
  any event storm in progress;
- the current values of the selected sources (up to 200), and the last
  records other than device events made since the driver started (up to 100);
- the driver and Agent versions and registration, this driver's status,
  licence standing and counters, the configuration and its limits, the
  upload queue's health as the Agent last reported it, and warnings about
  what is missing.

It is held to 64 KB by leaving out the oldest history entries first, then
recent records, then observations, and it says what it left out.

A snapshot is built a moment after it is asked for and handed to the Agent.
**Last Snapshot** follows it: `uploading`, then `completed` with the time, or
`failed` with the reason. *Snapshot Completed* fires when the Agent confirms
it; *Snapshot Failed* fires when it could not be built, there is no Agent, the
Agent reports a failure, or the request is refused. If the Agent never
answers, **Last Snapshot** reads `expired` after ten minutes and neither event
fires.

The driver keeps ten snapshot jobs, and a finished one stays on the list for an
hour. An eleventh request inside the hour is refused: **Last Snapshot** reads
`refused: too many snapshot jobs pending`.

## Pausing, switching off, and the licence

**Pausing.** `PAUSE_RECORDING` (or the action *Pause Recording*, or a pause
from System Studio) releases every event subscription and every variable
listener, and ends open traces as `interrupted`. Nothing the house does is
recorded while paused, and what happened in between is not known afterwards.
The pause survives a restart. `RESUME_RECORDING` rebuilds the subscriptions
from the project and re-reads every source as a first read, with the settings
and the configuration as they are at that moment: a configuration with
recording switched off stays off, and the note reads
`Recording resumed (variable sources are switched off)`. Both leave a note in
the history; resuming when nothing is paused does nothing. Commands your
programming runs while paused (`START_TRACE`, `RECORD_EVENT` and the rest)
are still recorded.

**Switching event capture off.** **Event Capture** set to `Off` releases the
event subscriptions only. Selected variables and trace commands go on being
recorded, and the history is kept. Unlike a pause it is a setting, not a
fault: no *Recording Degraded*.

**The licence.** If SmartBuildOS answers that this system is not licensed and
enforcement is on for this driver, every event subscription and every variable
listener is released and **Recording Status** reads `unlicensed`. The history
already held stays printable, and trace commands and markers are still
recorded. A configuration that arrives meanwhile is kept and starts when the
licence returns; so does event capture, without a reload. A resume meanwhile
is noted as `Recording resumed (unlicensed: nothing is listening)`. A licence
check that cannot be completed never stops recording.

## Worked examples

The print-outs below are the driver's own output for a small test project, run
on a computer under the driver's test harness with a stand-in catalogue of
three driver files. In the Lua tab each line also starts with the date and
`[PRINT]:`, left off here. Device, room and driver file names are examples.

In this project the hall light is the load of the Hall Keypad (device 212),
its `LIGHT_LEVEL` was selected with the `Lighting` template, and the Front
Door is a contact (device 231).

### What happened just before 3 am

The homeowner says the hall light came on at about 3 am. The routine on the
hall keypad's top button starts with a `RECORD_EVENT` marker named
"Hall light on".

<!-- walkthrough: Find what happened around a moment -->
1. Connect Composer, select the Flight Recorder and check **Event Coverage**
   and **Selected Sources**: the answer can only contain what they cover.
1. On the Actions tab press *Print Recent History* and open the Lua tab. You
   get the last 50 entries, oldest first.
1. Find the time and read the entries around it. Here the front door opened
   at 02:59:38.
   Thirteen seconds later the top button of the hall keypad was pushed, the
   marker says the routine on that button ran, and two seconds after that the
   light's level went from 0 to 100. The door closed at 03:04:10.
1. Now open Programming and read the script on that device and event, here
   the Hall Keypad's "Top Button Pushed". The recorder has told you where to
   look; Composer tells you what the script does.

The print-out. Entries #2 to #10 are left out here: they are the evening's
Good Night routine, the next example.

```text
== Flight Recorder history: last 17 of 17 held (to #17) ==
  11-09 22:41:07  #1  Hall / Hall Keypad: Bottom Button Pushed
  11-09 22:41:12  #11  TRACE good_night  end  completed; ok; 4 step(s), 5 s
  02:59:38  #12  Entry / Front Door: Opened
  02:59:51  #13  Hall / Hall Keypad: Top Button Pushed
  02:59:51  #14  MARK  Hall light on  — Hall Keypad top button
  02:59:51  #15  Hall / Hall Keypad: Top Button Released
  02:59:53  #16  Hall / Hall Keypad: LIGHT_LEVEL 0 → 100
  03:04:10  #17  Entry / Front Door: Closed
```

The question has changed from "why did the light come on" to "who came in
through the front door at 02:59", which is the useful one.

**In a busy house** the last 50 entries may not reach back to 3 am. Type the
device's id into **Inspect Device ID** (*Print Event Coverage* lists the ids
in its first column) and press *Print History For Inspect Device*:

```text
== Flight Recorder history: last 9 entries of device 212 ==
  11-09 22:41:07  #1  Hall / Hall Keypad: Bottom Button Pushed
  11-09 22:41:07  #3  TRACE good_night  step 1  Hall light: OFF requested  [Hall Keypad]
  11-09 22:41:07  #4  TRACE good_night  expects 2  Hall light at 0%  [Hall Keypad]
  11-09 22:41:07  #5  Hall / Hall Keypad: Bottom Button Released
  11-09 22:41:09  #6  Hall / Hall Keypad: LIGHT_LEVEL 75 → 0
  02:59:51  #13  Hall / Hall Keypad: Top Button Pushed
  02:59:51  #14  MARK  Hall light on  — Hall Keypad top button
  02:59:51  #15  Hall / Hall Keypad: Top Button Released
  02:59:53  #16  Hall / Hall Keypad: LIGHT_LEVEL 0 → 100
  event coverage: Hall Keypad (keypad.c4z) tier=builtin events=4 unsubscribed=0
  variable LIGHT_LEVEL = 100
```

If the history does not last the night, raise **Local History Size** (up to
2000) and exclude the devices that fill it.

### Good Night: a routine you can read back

The Good Night routine switches the hall light off, waits five seconds, then
checks the front door.

<!-- walkthrough: Trace the Good Night routine -->
1. Select the source. Set **Template** to `Lighting` and run *Apply Selected
   Template*. **Selected Sources** reads `1 selected, 1 listening`.
1. On the Good Night button's event, first line: `START_TRACE` with `NAME`
   Good Night and `CHANNEL` good_night. Use the same `CHANNEL` on every line
   below.
1. Before the command that switches the hall light off, add
   `RECORD_TRACE_STEP` with `MESSAGE` "Hall light: OFF requested" and `DEVICE`
   the Hall Keypad. After it, add `RECORD_EXPECTED_RESULT` with `EXPECTED`
   "Hall light at 0%" and the same `DEVICE`.
1. After the routine's five-second Delay, add `RECORD_TRACE_STEP` with
   `MESSAGE` "Front door check".
1. Inside the conditional that the front door is closed, add
   `RECORD_TRACE_DECISION` with `CONDITION` "Front door closed?" and
   `OUTCOME` yes, a `RECORD_EVENT` with `NAME` "House closed for the night"
   and the same `CHANNEL`, then `COMPLETE_TRACE` with `NOTE` ok. In the else
   branch, add `RECORD_TRACE_DECISION` with `OUTCOME` no, then `FAIL_TRACE`
   with `REASON` front door open.
1. Press the button. **Active Traces** goes to 1 and back to 0, *Trace
   Completed* or *Trace Failed* fires, and **Last Trace** reads
   `Good Night: completed (4 step(s), 5 s) at 22:41:12`.
1. Run *Print Last Trace*.

```text
== Flight Recorder trace: Good Night on good_night — completed; ok; 4 step(s), 5 s ==
  > 22:41:07  #2  TRACE good_night  start  Good Night
  > 22:41:07  #3  TRACE good_night  step 1  Hall light: OFF requested  [Hall Keypad]
  > 22:41:07  #4  TRACE good_night  expects 2  Hall light at 0%  [Hall Keypad]
    22:41:07  #5  Hall / Hall Keypad: Bottom Button Released
    22:41:09  #6  Hall / Hall Keypad: LIGHT_LEVEL 75 → 0
    22:41:09  #7  Entry / Front Door: Closed
  > 22:41:12  #8  TRACE good_night  step 3  Front door check
  > 22:41:12  #9  TRACE good_night  decision 4  Front door closed? → yes
  > 22:41:12  #10  MARK  House closed for the night
  > 22:41:12  #11  TRACE good_night  end  completed; ok; 4 step(s), 5 s
  7 line(s) from the trace (>), 3 from the house in between
```

The seven marked lines are what the routine said about itself, its marker
included. The three unmarked lines are what the house did between its start
and its end: the button was released, the light reported 0, and someone
closed the front door before the routine checked it. The button push that
started the routine is entry #1, just above the trace, in *Print Recent
History*.

The expected result is what the routine asked for; the change on
`LIGHT_LEVEL` is what the light reported. With the `Lighting` template the
change is held for its 1.5-second debounce, so here it was written two
seconds after the request. A routine with no delay ends within the same
second, and the change then lands below the trace's end: it is not in *Print
Last Trace*, and it is the next line in *Print Recent History*.

With the front door open the routine takes the other branch: *Trace Failed*
fires and the last line reads `end  failed; front door open` with the steps
and the duration. A routine that can overlap with this one needs its own
channel, for example `front_door_check`.

### A chattering contact

The front door's contact bounces and fires its "Opened" event 50 times in a
minute. With **Storm Threshold** at 30, the first 30 are recorded and
uploaded as usual. At the 30th, *Event Storm Detected* fires; the other 20
are counted and not recorded. **Active Storms** reads
`Front Door: Opened (50)` and the conditional *An event storm is in progress*
is true. Once the minute is over, *Event Storm Ended* fires. The end of
*Print Recent History* afterwards:

```text
  09:15:11  #47  Entry / Front Door: Opened
  09:15:11  #48  NOTE  Event storm: Front Door: Opened; further occurrences this minute are counted, not listed
  09:16:00  #49  NOTE  Storm ended: Front Door: Opened (50 in the minute, 20 not listed)
```

To be told about it, program on *Event Storm Detected* and send yourself a
notification. The event does not carry the device: read **Active Storms**, or
run *Print Recording Status*, which lists each storm in progress. Then fix
the cause (a failing sensor, a loose contact), or take the device out with
**Exclude Device IDs** while you wait for the part, or, if that rate is
normal for this device, raise **Storm Threshold**.

### An unknown driver: probe, learn, then switch the probe off

**Event Coverage** reads
`8 subscriptions on 3 of 5 devices; 1 unknown driver(s); 1 excluded`, and
*Print Event Coverage* shows which device it is:

```text
    270  Pool Controller                  example_pool.c4z                     unknown    0 events
```

<!-- walkthrough: Cover a device whose driver is not catalogued -->
1. Set **Probe Unknown Drivers** to On. The recorder subscribes to event ids
   1 to **Probe Range** on every unknown device. **Event Coverage** now reads
   `40 subscriptions on 4 of 5 devices; 1 excluded` and **Event Catalogue**
   ends in `probe: 32 subs`.
1. Make the device do the thing you want to record, and note the time.
1. An event that arrives is learned: *Unknown Event Learned* fires and the
   history shows it with a placeholder name.
1. Match the placeholder to what you did by the time. Repeat for the other
   things the device does.
1. Set **Probe Unknown Drivers** back to Off. The learned ids stay
   subscribed: **Event Coverage** reads
   `9 subscriptions on 4 of 5 devices; 1 excluded` and **Event Catalogue**
   shows `learned: 1 event(s) → 1 subs; probe: 0 subs`.

```text
  10:12:30  #50  Pool / Pool Controller: Event 5 (unnamed)
```

Probing costs subscriptions: **Probe Range** for each unknown device, 32
unless you change it. Thirty-two unknown devices already ask for more than
the default **Max Subscriptions**. Known events are always subscribed first,
so the probe cannot push them out, but a probe left on keeps the recorder at
the limit: before the merge, the bench controller read
`1000 subscriptions on 96 of 186 devices` with the probe on. Use it to learn,
then switch it off, or lower **Probe Range**, or exclude the devices you do
not care about. *Forget Learned Events* drops everything learned and plans
again.

### Know when recording stops, and keep the evidence when a routine fails

- On *Recording Degraded*, send yourself a notification with the variable
  `RECORDING_STATUS` in it: it reads, for example, `recording_local
  (degraded)`. *Recording Restored* fires when it is healthy again.
- On *Buffer Threshold Reached*, do the same with `BUFFERED_EVENTS`: events
  are waiting for the Agent and have reached **Buffer Warning Threshold**.
- On *Trace Failed*, run `CAPTURE_SNAPSHOT` with a `NOTE` such as "trace
  failed". The snapshot holds the history around the failure, the selected
  sources' values and the state of event capture at that moment. Mind the
  limit of ten snapshots in an hour.

## Programming reference

### Commands

Device Specific Commands, listed in Composer by these names.

| Command | Parameters | What it records |
| --- | --- | --- |
| `RECORD_EVENT` | `NAME`, `DETAIL`, `CHANNEL`, `DEVICE` | One named marker, as a request. `NAME` is required. If the channel (`main` when left empty) has an open trace, the upload ties the marker to it |
| `START_TRACE` | `NAME`, `CHANNEL` | Opens a trace. With no `NAME` the trace is named after the channel |
| `RECORD_TRACE_STEP` | `MESSAGE`, `CHANNEL`, `DEVICE` | A step: something the programming did or asked for |
| `RECORD_TRACE_DECISION` | `CONDITION`, `OUTCOME`, `CHANNEL` | A conditional and the branch taken |
| `RECORD_EXPECTED_RESULT` | `EXPECTED`, `CHANNEL`, `DEVICE` | What the programming expects to see next. The recorder never checks it |
| `COMPLETE_TRACE` | `NOTE`, `CHANNEL` | Ends the trace as `completed` |
| `FAIL_TRACE` | `REASON`, `CHANNEL` | Ends the trace as `failed` |
| `CAPTURE_SNAPSHOT` | `NOTE` | Asks for a snapshot; see **Last Snapshot** |
| `PAUSE_RECORDING` | `REASON` | Pauses recording: event subscriptions and variable listeners are released, open traces are interrupted. Stays paused across a restart |
| `RESUME_RECORDING` | none | Resumes: subscriptions are rebuilt from the project, sources are re-read as first reads |

`DEVICE` is optional everywhere: it ties the record to a device of the project.
Text is cut to length: `CHANNEL` 48 characters; `NAME` 120; `MESSAGE`,
`CONDITION`, `EXPECTED`, `DETAIL`, and the `NOTE` or `REASON` that ends a trace
400; `OUTCOME` 60; a snapshot's `NOTE` 200.

### Events

| Event | Fires when |
| --- | --- |
| *Recording Degraded* | **Recording Status** leaves `recording`, `idle` or `disabled` for anything else: the Agent link is not ready, recording was paused, or the licence stopped it |
| *Recording Restored* | It returns to one of those three. After a restart the driver is not healthy until the Agent has registered it, so this normally fires once after every start |
| *Buffer Threshold Reached* | **Buffered Events** reaches **Buffer Warning Threshold**. It can fire again once the count has fallen below half the threshold |
| *Snapshot Completed* | The Agent confirms a snapshot |
| *Snapshot Failed* | A snapshot could not be built, sent or stored, or was refused |
| *Trace Completed* | A trace ends as `completed` |
| *Trace Failed* | A trace ends as `failed`, `interrupted` or `abandoned` |
| *Agent Connected* | The Agent accepts this driver's registration, including each time it registers again |
| *Agent Disconnected* | The Agent refuses the registration |
| *Event Storm Detected* | One device fired the same event **Storm Threshold** times in a minute |
| *Event Storm Ended* | That minute is over. The driver notices at its next 30-second check, or at the next occurrence |
| *Unknown Event Learned* | A probe subscription received an event id for the first time |

The status is looked at at least once a minute, so *Recording Degraded*,
*Recording Restored* and *Buffer Threshold Reached* can follow their cause by
up to a minute. To be told that the Agent has gone, use *Recording
Degraded*: *Agent Disconnected* fires on a refusal only.

### Conditionals

| Conditional | True when |
| --- | --- |
| *Recording is active* | **Recording Status** is `recording` or starts with `recording_local`: something is being watched, with or without the Agent |
| *SmartBuildOS Agent link is ready* | **Agent Connection** is `ready` |
| *An event storm is in progress* | At least one storm is active right now |

### Variables

All read-only. The recorder never subscribes to its own events and refuses its
own device as a source, so these never feed back into the record.

| Variable | Holds |
| --- | --- |
| `RECORDING_STATUS` | The same text as **Recording Status** |
| `AGENT_CONNECTION` | The same text as **Agent Connection** |
| `SELECTED_SOURCES` | How many sources are selected (a number) |
| `ACTIVE_TRACES` | How many traces are open |
| `BUFFERED_EVENTS` | Events waiting in this driver or sent to the Agent and not yet acknowledged |
| `DROPPED_EVENTS` | Events this driver dropped |
| `LAST_UPLOAD` | When the Agent last acknowledged a batch, in UTC; empty until then |
| `LAST_RECORDING_ERROR` | The same text as **Last Recording Error** |
| `CONFIG_VERSION` | The version of the configuration in force |
| `SUBSCRIPTIONS` | Active event subscriptions |
| `EVENTS_CAPTURED` | Device events recorded since the driver started |
| `ACTIVE_STORMS` | Number of active storms |
| `LAST_EVENT` | The newest device event, as `Device: Event` |
| `LAST_EVENT_DEVICE` | That event's device id |

`LAST_EVENT`, `LAST_EVENT_DEVICE`, `EVENTS_CAPTURED` and `ACTIVE_STORMS`, and
the properties that show them, are written two seconds after the last event
of a burst, not once per event, so they are for display and not a trigger for
every event. Everything else is written with the status, once a minute and
whenever something changes. **Active Storms** and `ACTIVE_STORMS` can
therefore show a storm for up to a minute after *Event Storm Ended*; the
conditional is always current.

## Properties

Status:

| Property | What it shows |
| --- | --- |
| **Driver Status**, **Driver Version** | `Online` once started, and the build |
| **Recording Status**, **Agent Connection** | See [Reading the status](#reading-the-status) |
| **Agent Link** | The Agent's device id and whether this driver is registered with it |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | This driver's licence standing, as the Agent reports it |
| **Configuration** | The version in force and where it came from (`default`, `studio` or `composer`); a refused revision and the reason |
| **Selected Sources** | For example `4 selected, 2 listening, 1 stale` |
| **Event Coverage**, **Event Catalogue** | See [Reading the status](#reading-the-status) |
| **Events Captured** | Device events recorded since the driver started |
| **Last Event** | The newest device event and its time |
| **Active Storms** | Up to three storms in progress, each with its count this minute; `none` otherwise |
| **Active Traces** | Open traces |
| **Last Trace** | The last trace that ended: its name, how it ended, its steps and duration, and when |
| **Buffered Events**, **Dropped Events** | As the variables above |
| **Last Upload** | When the Agent last acknowledged a batch from this driver, in the controller's time; `never` until then |
| **Last Recording Error** | The last problem, or `none` |
| **Last Snapshot** | The last snapshot's job and state |

Settings:

| Property | What it does |
| --- | --- |
| **Event Capture** | `Off` releases every event subscription; variables and traces go on being recorded and the history is kept |
| **Read Events From Project** | `On` reads each device's events from the controller's project data at every plan. `Off` relies on the built-in and learned catalogues |
| **Probe Unknown Drivers** | `On` subscribes to event ids 1 to **Probe Range** on devices no catalogue knows. `Off` by default |
| **Probe Range** | The highest event id a probe tries |
| **Max Subscriptions**, **Storm Threshold**, **Event Upload Budget**, **Local History Size** | See [Protection](#protection) |
| **Exclude Device IDs** | Device ids to leave out of event capture, separated by commas or semicolons. Up to 200 |
| **Exclude Driver Files** | Driver file names to leave out, for example `example_pool.c4z`, written exactly as *Print Event Coverage* shows them. Up to 200 |
| **Inspect Device ID** | The device *Print History For Inspect Device* prints |
| **Template** | The template *Apply Selected Template* will add |
| **Buffer Warning Threshold** | 50 to 300, default 200: the count at which *Buffer Threshold Reached* fires |
| **Log Level**, **Log Mode** | Diagnostic logging. The Print actions write to the Lua tab whatever these say |

An event capture setting that cannot be used does not stop capture: it is
ignored (a number falls back to its default) and **Last Recording Error**
names it. With `231, garage` in **Exclude Device IDs**, device 231 is
excluded and the line reads
`setting ignored: exclude_device_ids not a device id: garage`.

System Studio can send the same event capture settings through the Agent.
They are written into these properties, so Composer shows what is running,
and a later change in Composer wins. A set with one invalid value is refused
whole and changes nothing.

## Actions

| Action | What it does |
| --- | --- |
| *Print Recent History* | The last 50 entries of the history |
| *Print History For Inspect Device* | The last 50 entries of the device in **Inspect Device ID**, its event coverage and its watched variables |
| *Print Last Trace* | The last trace that ended, with what the house did between its start and its end |
| *Print Recording Status* | Status, Agent, licence, configuration, event coverage and catalogue, ignored settings, counters, active storms, the Agent's queue, open traces and how many entries the history holds |
| *Print Sources* | Each source and whether it is on; the stale, unsupported and excluded ones with the reason; each listening source's current value |
| *Print Event Coverage* | Every device: id, name, driver file, catalogue, events subscribed. Names are cut to 32 characters and file names to 36 |
| *Capture Snapshot* | The same as `CAPTURE_SNAPSHOT`, with the note "Composer action" |
| *Pause Recording*, *Resume Recording* | The same as the two commands |
| *Apply Selected Template* | Adds the sources of the chosen **Template** |
| *Clear Composer Sources* | Removes every selected source, whoever selected it, as a new `composer` revision |
| *Re-apply Event Capture* | Plans the event subscriptions again against the current project. Does nothing while paused or unlicensed |
| *Register With Agent Now* | Looks for the Agent and registers again, without waiting for the retry |
| *Refresh Status* | Repaints the properties and sends the status to the Agent |
| *Clear Local History* | Empties the history; the sequence starts again at 1. **Last Event** and **Last Trace** read `none yet (history cleared)` |
| *Forget Learned Events* | Drops the learned catalogue and plans again |

## Reading the status

**Recording Status** is one of these. A value in brackets is the **Agent
Connection** at that moment.

| Recording Status | Meaning | What to do |
| --- | --- | --- |
| `starting` | The driver has not finished starting | Wait |
| `recording` | The Agent is ready and something is being watched: at least one event subscription or one variable source | Nothing |
| `idle` | The Agent is ready and nothing is being watched: no event subscription (event capture off, nothing catalogued, everything excluded) and no variable source listening. Trace commands, markers and selected SmartBuildOS events are still recorded | Read **Event Coverage** and **Selected Sources** |
| `recording_local (…)` | Watching and recording locally; the Agent link is not ready, so uploads wait | Read **Agent Connection** |
| `idle (…)` | Nothing is being watched and the Agent link is not ready | Both of the above |
| `paused` | Paused from Composer, programming or System Studio | *Resume Recording* |
| `disabled` | **Event Capture** is `Off` and the configuration in force has recording switched off | Set **Event Capture** to `On`, or change the configuration in System Studio |
| `unlicensed` | SmartBuildOS answered that this system is not licensed and enforcement is on. Nothing is watched; the history stays printable | Read **License Status**, which ends in `(read-only)` |

| Agent Connection | Meaning | What to do |
| --- | --- | --- |
| `ready` | Registered; the Agent is paired and connected to SmartBuildOS | Nothing |
| `waiting_for_agent` | No Agent in the project, or it has not accepted the registration. The driver asks again by itself, after 30 seconds at first and then less often, up to every 5 minutes. An Agent build without module services never answers | Install or update the Agent; *Register With Agent Now* |
| `incompatible` | The Agent refused the registration: the two do not speak the same protocol version | Update the Agent and this driver to matching builds |
| `unpaired` | Registered, but the Agent is not paired to a SmartBuildOS system | Pair the Agent |
| `degraded` | Registered and paired, but the Agent has no connection to SmartBuildOS. Recording goes on; uploads wait in the Agent | Check the controller's internet |

**Event Coverage** reads `N subscriptions on A of B devices`, where B is every
device in the project, followed by whichever of these apply:

| Part | Meaning |
| --- | --- |
| `N unknown driver(s)` | Devices in no catalogue. Nothing is captured from them |
| `N excluded` | Your exclusions, plus the recorder itself |
| `N event(s) over Max Subscriptions` | Known or probed events that did not fit. *Print Event Coverage* marks each device with `(N not subscribed)` |
| `N refused by Director` | Subscriptions Director did not accept |

It reads `event capture off` when **Event Capture** is `Off` and
`not applied yet` before the first plan. During a pause or a licence stop it
can go on showing the plan from before: **Recording Status** and
`SUBSCRIPTIONS` are the ones to trust.

**Event Catalogue** says how much each catalogue holds and how many
subscriptions it gave. In the test project of the worked examples it read
`project: 0 device(s) → 0 subs; built-in: 3 driver(s) → 8 subs; learned: 1
event(s) → 1 subs; probe: 0 subs`; the shipped built-in catalogue holds 187
driver files.

**Selected Sources.** `selected` is how many sources the configuration holds;
`listening` is how many the driver found and subscribed to. `stale` means the
source's device is no longer in the project. `unsupported` means the device is
there but has no variable of that name. *Print Sources* names each one.

**Configuration.** `v3 applied (studio)` is the normal reading. After a
refused revision it reads, for example, `v3 applied (studio) — desired v4
refused: sources[1].variable: credential-bearing variables are never
recorded`: version 3 is still in force.

**Buffered Events** are on their way to the Agent; the driver holds at most
300 that the Agent has not taken. **Dropped Events** counts what this driver
did not get to the Agent: device events over the **Event Upload Budget**,
observations over their per-minute budget, events pushed out of the 300
waiting, events the Agent rejected, and batches the Agent did not acknowledge
after three tries. A dropped device event is still in the history unless it
has rolled over. Nothing is dropped without being counted.

**Last Upload** is the hand-off to the Agent, not proof that the platform has
the events. The Agent's queue is the Agent's own (2,000 events or 512 KB); it
records the range it had to drop so that System Studio can show a gap. Run
*Print Recording Status* and read the `agent queue` line.

**Last Recording Error** reads `none`, or the last problem: a setting that
was ignored, a refused configuration or registration, the licence. It is
cleared when a configuration is next applied or the licence returns, so a
line can outlast its cause. Check it against **Recording Status**.

## Privacy: what is kept and what leaves the controller

The driver opens no network connection of its own. Everything it sends goes to
the SmartBuildOS Agent on the same controller, and the Agent uploads it.

What it keeps on the controller is the history: device and room names, event
names, the names and values of the selected variables before and after each
change, and the text your programming recorded. Anyone with Composer access
to the project can print it. *Clear Local History* empties it.

What it sends:

- **Each record.** Its kind, the controller's time, a sequence number, the
  label, the device and room, and its content: for a device event the driver
  file name, the event id and name and the catalogue it came from; for an
  observation the variable name, the value and the previous value; for a
  system event its name and the Agent's detail; for a trace or
  `RECORD_EVENT` the text you typed.
- **Its registration and status**: its version at registration, then every
  five minutes and on *Refresh Status* the recording status, the last error
  and its counters. When event capture is planned, its coverage and settings.
- **A snapshot**, only when one is asked for. It carries the newest 200
  entries of the history, so the variable values in those lines travel with
  it.

What is never recorded:

- A variable that is not a selected source.
- A variable whose name contains `USERCODE`, `ACCESSCODE`, `PINCODE`,
  `PASSCODE`, `PASSWORD`, `PASSWD`, `TOKEN`, `SECRET`, `APIKEY`, `DISARMCODE`,
  `ARMCODE`, `KEYCODE`, `LOCKCODE` or `CREDENTIAL`, ignoring capitals, spaces
  and underscores (`User Code` counts). A configuration that names one is
  refused whole. The list is fixed.
- A variable that matches one of the configuration's exclusion patterns.
- This driver's own variables and events.
- Text values, when the configuration's privacy setting excludes them. By
  default they are recorded and flagged as unreviewed text.
- Event parameters (Director passes none), driver properties and logs.
- Events of a device in **Exclude Device IDs** or on a driver in **Exclude
  Driver Files**.

Before a record or a snapshot leaves the driver, any field named like a
credential and any value that looks like a long token is replaced by
`[redacted]`, and every text in a record is cut at 512 characters. This is a
second net, not a filter on variable names: the fixed list above does that.
The history has a net of its own, by variable name and by value, and it is
the stricter one: a source named exactly `PIN`, `CODE`, `KEY`, `AUTH` or
`SIG` is accepted and uploaded with its value, while the history shows
`[redacted]`. The design notes say the platform applies the same rules again
on receipt.

A short number is not redacted: a four-digit code typed into a `MESSAGE` is
recorded as typed, in the history and in the upload. Programmer text (trace
messages, marker names and details, the reason given to `PAUSE_RECORDING`) is
a service record and is flagged as unreviewed text. Do not put codes or
personal details into it.

## What is not claimed

Director does not tell a driver which programming ran, nor whether a person or
an automation caused an event or a change: the recorder cannot tell a person
at a keypad from programming. An entry says which device fired which event,
or which variable went from what to what, and when. The "why" is the sequence
of entries around it. Nothing guesses a cause.

- **Success.** An expected result is never checked against what followed.
  The unmarked lines of *Print Last Trace* happened between the routine's
  lines; that is all they claim.
- **Completeness.** What happened while recording was paused, before a
  source's first read, or beyond a limit is not known. Dropped events are
  counted. The occurrences a storm suppresses are counted and never
  recorded, in the history or in the upload.
- **Only what is covered.** A device in no catalogue is reported, not
  captured, unless probing is on, and probing cannot reach event ids above
  **Probe Range**. No event parameters (Director passes none). Named events
  from Control4's own devices have not been confirmed on a controller: on
  the bench (OS 4.3) the project catalogue was empty, and the event recorded
  there came from a probe subscription, unnamed.
- **A storm under a spent upload budget.** If the **Event Upload Budget** for
  that minute is already used when a storm starts, *Event Storm Detected*
  does not fire, the history gets no note and no warning is uploaded.
  **Active Storms**, the conditional and *Event Storm Ended* still work.
  *Unknown Event Learned* is held back the same way.
- **Exceeding a per-minute budget is not a degraded state.** **Recording
  Status** stays `recording` and *Recording Degraded* does not fire; watch
  **Dropped Events**.
- **Exact times and order.** Times are the controller's clock, which can be
  wrong, and a debounced change is written late (see
  [The history](#the-history)).
- **Names are as recorded.** An entry keeps the device and room names it was
  recorded with; renaming a device later does not change old entries.
- **System Studio.** Until the web side is updated, System Studio's pages
  still treat event capture as a separate module, and the server refuses
  device events uploaded by the Flight Recorder: they may not be accepted or
  shown there. The local history is not affected. How the server handles the
  new parts of a snapshot (the history, event capture, storms) is not
  verified.

### Hardware validation

Simulator-verified (the driver test suite with a scripted Agent). **Nothing in
the merged driver has been run on a controller yet.**

What was seen on a bench controller (OS 4.3, Composer Pro 2026.10.14) was seen
on the two separate drivers, before they were merged:

- The Flight Recorder was imported, updated in place and its status read
  back: `idle`, registered with the Agent. No source, trace, snapshot or
  programming command was exercised.
- The Event Tracer, as it then was, registered with the Agent and held its
  subscriptions with the built-in catalogue of 187 driver files loaded. Its
  last event survived a driver update. Probing was left on for eleven hours
  without disturbing Director, and delivered a real event. A marker command
  was run from a programming line.

Not measured on any controller: how many subscriptions Director accepts above
the default, storm detection on a real chattering input, the licence stop,
settings sent from System Studio, and removal of the driver. See the
repository's `docs/flight-recorder/VERIFICATION.md` and
`docs/event-tracer/VERIFICATION.md` for the bench steps and evidence owed.

<!-- #embed-changelog -->

# SmartBuildOS Event Tracer

The Event Tracer keeps a record of which device fired which event, and when.
It asks the controller for the events of every device it has a catalogue for,
with no configuration, and keeps the sequence in two places: a local history
on the controller that you print from the Actions tab, and the SmartBuildOS
timeline in System Studio through the **SmartBuildOS Agent**. It answers "what
happened just before the hall light came on at 3 am" with the events around
that moment, in order, named the way each device's driver names them.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`, a build with module
services) paired to a SmartBuildOS system. The Agent is the licensing authority
(SKU `SBOS_EVENT_TRACER`): **License Status** shows this driver's standing.
Local capture runs without the Agent and continues during an internet outage;
uploads wait in the Agent's bounded, journaled queue. Control4 OS 3.3.2 or
later.

## Why Composer alone does not answer "what happened just before"

Composer shows what is programmed: pick a device and one of its events and you
read the script. To explain something that happened overnight you need the
other half: which events fired, on which devices, in what order. As far as we
know Composer keeps no history of that which you can open the next morning,
so the usual method is to read the programming and guess.

A driver cannot ask for it afterwards either. Director hands a device's event
to a driver only when the driver asked for that device and that event
beforehand. The tracer asks for all of them when it starts, and writes each
one down as it arrives.

Composer is still the right tool when:

- you already know which event matters: read its script in Programming;
- you can make the problem happen while you are on site: trigger it and watch;
- you want to know what a script does. The tracer records events, never
  programming.

## What it is for

| You want | Use |
| --- | --- |
| The events around a moment last night, in order | *Print Recent Events* |
| One device's recent events, however busy the rest of the house was | **Inspect Device ID** and *Print Events For Inspect Device* |
| Proof that a routine ran, and what fired after it | The command `MARK_TIMELINE` as the first line of the routine |
| To be told when a sensor or contact is chattering | *Event Storm Detected*, **Active Storms**, the conditional *An event storm is in progress* |
| To know which devices are covered and which are not | **Coverage**, *Print Coverage* |
| A device whose driver is in no catalogue | **Probe Unknown Drivers**, then *Unknown Event Learned* |
| A noisy or private device left out | **Exclude Device IDs**, **Exclude Driver Files** |
| Capture stopped during service work | `PAUSE_CAPTURE` and `RESUME_CAPTURE`, or the actions *Pause Capture* and *Resume Capture* |
| To know when capture or its upload is not healthy | *Capture Degraded*, *Capture Restored*, `CAPTURE_STATUS` |
| The same timeline without going to site | The upload through the Agent to System Studio |

## Setup

<!-- walkthrough: Set up Event Tracer -->
1. Install the SmartBuildOS Agent from Composer's Agents tab and pair it.
1. Add this driver (one per project). **Driver Status** reads `Online`,
   **Agent Link** shows the Agent's device id and **Agent Connection** reads
   `ready` once registered.
1. That is all: capture has started. **Coverage** reports how many event
   subscriptions are active on how many devices, and how many devices the
   catalogue does not know. **Catalogue** says where the subscriptions came
   from.
1. Make a covered device do something. **Last Event** names the device and
   the event about two seconds later.
1. Run *Print Coverage* and check that the devices you care about are listed
   with events. For one that reads `unknown`, see
   [An unknown driver](#an-unknown-driver-probe-learn-then-switch-the-probe-off).
1. Optionally add `MARK_TIMELINE` to routines (Device Specific Command) so a
   routine's start shows up as a named marker between the device events.

![Event Tracer in Composer: the Properties tab, status at the top and settings below. On this bench Probe Unknown Drivers is on, which is why Coverage sits at the limit of 1000](images/properties.jpg)

![The Actions tab](images/actions.jpg)

## What is captured

Director fires a device event to a driver only after the driver subscribes to
that device and event id. A **subscription** is one device and one event id.
The tracer knows which event ids exist from three catalogues, best first:

| Catalogue | Where the event ids come from | What to know |
| --- | --- | --- |
| Project | The controller's own project data, when the OS includes each device's events in it (**Read Events From Project**) | Meant to cover Control4's built-in drivers. On the bench controller (OS 4.3) the project data carried no events: **Catalogue** read `project: 0 device(s)` |
| Built-in | A table inside the driver, generated at build time from one driver library: 187 driver files that declare events, 1,303 events | Matched by the exact driver file name. A driver that was not in that library is not in it |
| Learned | Event ids seen at run time on a probe subscription, kept across restarts | Named "Event N". Learned for the driver file, so every device on that driver gets it |

A device whose driver is in none of them is reported under **Coverage** as
"unknown driver" and nothing is captured from it. Turn on
**Probe Unknown Drivers** to subscribe to event ids 1 to **Probe Range** on
those devices; anything that fires is learned and shown as "Event N" until
the catalogue is updated.

So what you get depends on the project. Read **Coverage** before you rely on
the history: a device that is not covered leaves no entries, and that is not
the same as "nothing happened".

### An entry

Each captured event becomes one entry: the time, the room and device names as
they were at that moment, the event's name and a sequence number. A marker is
an entry too. Entries go to two places.

- **The local history** holds the newest **Local History Size** entries on the
  controller (500 unless you change it). It is saved every 30 seconds while it
  is changing and when the driver stops, and is read back at start, so it
  survives a driver update or a restart. A power cut can lose about the last
  half minute. On the bench, **Last Event** still showed the morning's event
  after the driver was updated that evening.
- **The upload** sends each entry to the Agent, which queues it for
  SmartBuildOS. While the Agent is missing or not registered, the driver holds
  the newest 300 entries for it and counts older ones as dropped. The local
  history does not depend on any of this.

**Events Captured** counts events recorded since the driver last started. It
restarts at 0 after an update; the history does not. Markers and events
suppressed by a storm are not in it.

### When the plan changes

The tracer works out its subscriptions when it starts, when you change a
capture setting, when the Agent reports that the project changed or Director
reloaded (five seconds after the last such report), and when you run *Re-apply
Capture Now*. It then adds and releases only the difference; the same plan
twice changes nothing. Without the Agent a newly added device is picked up at
the next of the other three.

## Protection

| Limit | Setting | Default | Range | At the limit |
| --- | --- | --- | --- | --- |
| Storm | **Storm Threshold** | 30 | 0 to 600 | See below. 0 turns storm detection off |
| Upload | **Upload Budget** | 300 a minute | 10 to 1200 | Further entries that minute are not uploaded and are counted in **Dropped Events** |
| Subscriptions | **Max Subscriptions** | 1000 | 50 to 2500 | **Coverage** says how many events did not fit |
| History | **Local History Size** | 500 | 50 to 2000 | The oldest entry is dropped for each new one |
| Probe | **Probe Range** | 32 | 1 to 64 | Event ids above it cannot be discovered |

- **Storms.** When one device fires one event **Storm Threshold** times in a
  minute, that is a storm: one *Event Storm Detected* event and one warning in
  the timeline, then that event is counted but not recorded until the minute
  is over, when *Event Storm Ended* carries the totals. Other devices and
  other events of the same device are not affected. A chattering contact
  cannot flood the history or the uplink; the storm itself is the finding. A
  contact that keeps chattering gives one storm a minute.
- **Upload budget.** Events beyond **Upload Budget** per minute are counted as
  dropped, not uploaded. The local history is not budgeted (it is bounded by
  **Local History Size** instead), so *Print Recent Events* can show what the
  uplink did not get.
- **Subscription cap.** Events the catalogues know are subscribed first, in
  ascending device id order, until **Max Subscriptions**; probe subscriptions
  get what is left. What did not fit is listed under **Coverage**, never
  skipped silently.
- **Exclusions.** **Exclude Device IDs** and **Exclude Driver Files** take
  devices out of capture. The tracer never subscribes to itself, which is why
  a new install already reads `1 excluded`.

## Worked examples

The print-outs below are the driver's own output for a small test project,
run on a computer with the built-in catalogue. In the Lua tab each line also
starts with the date and `[PRINT]:`, left off here. Device and room names are
examples.

### What happened just before 3 am

The homeowner says the hall light came on at about 3 am.

<!-- walkthrough: Find the events around a moment -->
1. Connect Composer, select the Event Tracer and check **Coverage**. The
   answer can only contain devices that are covered.
1. On the Actions tab press *Print Recent Events* and open the Lua tab. You
   get the last 50 entries, oldest first.
1. Find the time. An entry from an earlier day starts with the month and day;
   one from today shows the time alone.
1. Read the entries just before it. Here the garage door opened at 02:59:38
   and the hall sensor saw motion 13 seconds later.
1. Now open Programming and read the script on that device and event, here
   the Hall Sensor's "Motion Detected". The tracer has told you where to
   look; Composer tells you what the script does.

```text
== Event Tracer: last 6 of 6 held (seq to 6) ==
  11-09 22:41:07  #1  MARK  Good Night started  — Hall keypad
  11-09 22:41:08  #2  Hall / Good Night: On
  11-09 22:41:17  #3  Garage / Garage Door: Closed
  02:59:38  #4  Garage / Garage Door: Opened
  02:59:51  #5  Hall / Hall Sensor: Motion Detected
  03:04:10  #6  Garage / Garage Door: Closed
```

The question has changed from "why did the light come on" to "who opened the
garage door at 02:59", which is the useful one.

**In a busy house** the last 50 entries may not reach back to 3 am. Type the
device's id into **Inspect Device ID** and press *Print Events For Inspect
Device*: it prints the last 50 entries of that device alone, from the whole
history, and then how the device is covered. *Print Coverage* lists every
device with its id in the first column.

```text
== Event Tracer: last 3 events of device 231 ==
  11-09 22:41:17  #3  Garage / Garage Door: Closed
  02:59:38  #4  Garage / Garage Door: Opened
  03:04:10  #6  Garage / Garage Door: Closed
  coverage: Garage Door (garagedoor_relay_control.c4z) tier=builtin events=7 unsubscribed=0
```

If the history does not last the night, raise **Local History Size** (up to
2000) and exclude the devices that fill it.

### Mark a routine on the timeline

Device events do not say which programming ran. A marker does, because the
script itself places it.

<!-- walkthrough: Mark the start of a routine -->
1. In Programming, select the event that starts the routine, for example the
   button that runs Good Night.
1. In the Actions pane select the Event Tracer and choose the Device Specific
   Command `MARK_TIMELINE`.
1. Type a `NAME`, for example `Good Night started`. Optionally type a
   `DETAIL`, such as `Hall keypad`, and pick a `DEVICE` to tie the marker to.
1. Drag the command into the script as its first line.
1. Run the routine. **Last Event** reads `MARK Good Night started` with the
   time, and the history shows the marker ahead of what the routine caused:
   entries #1 to #3 in the print-out above.

- `NAME` is required; a marker with no name is not recorded. It is cut to 120
  characters and `DETAIL` to 400.
- With a `DEVICE`, the marker also appears in *Print Events For Inspect
  Device* for that device, and `LAST_EVENT_DEVICE` holds its id. Without one
  the variable holds 0.
- A marker is recorded whenever the command runs, also while capture is paused
  or off.
- On the bench controller the command was run from a programming line with
  the name `bench`, and **Last Event** read `MARK bench`, as in the screenshot
  above.

### A chattering contact

A contact on the hall sensor bounces and fires its "Contact Opened" event 50
times in a minute. With **Storm Threshold** at 30:

- the first 30 are recorded and uploaded as usual;
- at the 30th, *Event Storm Detected* fires and the timeline gets one warning;
- the other 20 are counted and not recorded;
- **Active Storms** reads `Hall Sensor: Contact Opened (50)` and the
  conditional *An event storm is in progress* is true;
- once the minute is over, *Event Storm Ended* fires and the timeline gets the
  totals: 50 occurrences, 20 of them not recorded.

*Print Capture Status* shows the same while it lasts:

```text
  STORM Hall Sensor: Contact Opened — 50 this minute (20 suppressed)
```

To be told about it, program on *Event Storm Detected* and send yourself a
notification. The event does not carry the device: read **Active Storms**, or
run *Print Capture Status*. Then decide:

- fix the cause (a failing sensor, a loose contact);
- or take the device out with **Exclude Device IDs** while you wait for the
  part;
- or, if that rate is normal for this device, raise **Storm Threshold**.

### An unknown driver: probe, learn, then switch the probe off

**Coverage** reads
`49 subscriptions on 4 of 6 devices; 1 unknown driver(s); 1 excluded`, and
*Print Coverage* shows which device it is:

```text
    270  Pool Controller                  example_pool.c4z                     unknown    0 events
```

<!-- walkthrough: Cover a device whose driver is not catalogued -->
1. Set **Probe Unknown Drivers** to On. The tracer subscribes to event ids 1
   to **Probe Range** on every unknown device. **Coverage** now reads
   `81 subscriptions on 5 of 6 devices; 1 excluded` and **Catalogue** ends in
   `probe: 32 subs`.
1. Make the device do the thing you want to trace, and note the time.
1. An event that arrives is learned: *Unknown Event Learned* fires and the
   history shows it with a placeholder name.
1. Match the placeholder to what you did by the time. Repeat for the other
   things the device does.
1. Set **Probe Unknown Drivers** back to Off. The learned ids stay
   subscribed: **Coverage** reads
   `50 subscriptions on 5 of 6 devices; 1 excluded` and **Catalogue** shows
   `learned: 1 event(s) → 1 subs; probe: 0 subs`.

```text
  10:12:30  #37  Pool / Pool Controller: Event 5 (unnamed)
```

Probing costs subscriptions: **Probe Range** for each unknown device, 32
unless you change it. Thirty-two unknown devices already ask for more than
the default **Max Subscriptions**. Known events are always subscribed first,
so the probe cannot push them out, but a probe left on keeps the tracer at the
limit: the bench controller read `1000 subscriptions on 96 of 186 devices`
with the probe on. Use it to learn, then switch it off, or lower **Probe
Range**, or exclude the devices you do not care about.

*Forget Learned Events* drops everything learned and plans again.

## Programming reference

Commands (Device Specific Commands, listed in Composer by these names):

| Command | Parameters | What it does |
| --- | --- | --- |
| `MARK_TIMELINE` | `NAME`, `DETAIL`, `DEVICE` | Places a named marker in the history and the timeline |
| `PAUSE_CAPTURE` | `REASON` | Releases every subscription. The reason is uploaded with the pause. Stays paused across a restart |
| `RESUME_CAPTURE` | none | Rebuilds the subscriptions from the project |

Events:

| Event | Fires when |
| --- | --- |
| *Capture Degraded* | **Capture Status** leaves `capturing`, `idle` or `disabled`: the Agent link is not ready, capture was paused, or the licence stopped it |
| *Capture Restored* | **Capture Status** is back to one of those three |
| *Event Storm Detected* | One device fired the same event **Storm Threshold** times in a minute |
| *Event Storm Ended* | That minute is over |
| *Agent Connected* | The Agent accepted this driver's registration, also after an Agent restart |
| *Agent Disconnected* | The Agent refused this driver's registration |
| *Unknown Event Learned* | A probe subscription received an event id for the first time |

Conditionals:

| Conditional | True when |
| --- | --- |
| *Capture is active* | **Capture Status** starts with `capturing`, with or without the Agent |
| *SmartBuildOS Agent link is ready* | **Agent Connection** is `ready` |
| *An event storm is in progress* | At least one storm is active right now |

Variables (all read-only):

| Variable | Holds |
| --- | --- |
| `CAPTURE_STATUS` | The text of **Capture Status** |
| `AGENT_CONNECTION` | The text of **Agent Connection** |
| `SUBSCRIPTIONS` | Active subscriptions |
| `EVENTS_CAPTURED` | Events recorded since the driver started |
| `ACTIVE_STORMS` | Number of active storms |
| `LAST_EVENT` | The newest entry, as `Device: Event`, or `MARK` and the marker's name |
| `LAST_EVENT_DEVICE` | That entry's device id, 0 for a marker with no device |
| `BUFFERED_EVENTS` | Entries waiting for the Agent |
| `DROPPED_EVENTS` | Entries not uploaded |
| `LAST_CAPTURE_ERROR` | The text of **Last Capture Error** |

`LAST_EVENT`, `LAST_EVENT_DEVICE`, `EVENTS_CAPTURED` and `ACTIVE_STORMS` are
written two seconds after the last event of a burst, not once per event, so
they are for display and not a trigger for every event. The other variables
are written with the status, once a minute and whenever something changes.

## Properties

Settings:

| Property | What it does |
| --- | --- |
| **Capture** | Off releases every subscription; the local history is kept. Unlike a pause it is a setting, not a fault: no *Capture Degraded* |
| **Read Events From Project** | On reads each device's events from the controller's project data at every plan. Off relies on the built-in and learned catalogues |
| **Probe Unknown Drivers** | On subscribes to event ids 1..**Probe Range** on devices no catalogue knows. Off by default |
| **Probe Range** | The highest event id a probe tries |
| **Max Subscriptions**, **Storm Threshold**, **Upload Budget**, **Local History Size** | See [Protection](#protection) |
| **Exclude Device IDs** | Device ids to leave out, separated by commas or semicolons. Up to 200 |
| **Exclude Driver Files** | Driver file names to leave out, for example `example_pool.c4z`, written exactly as *Print Events For Inspect Device* shows them. Up to 200 |
| **Inspect Device ID** | The device *Print Events For Inspect Device* prints |
| **Buffer Warning Threshold** | Has no visible effect in this version |
| **Log Level**, **Log Mode** | Diagnostic logging. The Print actions write to the Lua tab whatever these say |

A value that cannot be used does not stop capture: it is ignored (a number
falls back to its default) and **Last Capture Error** names it. With
`231, garage` in **Exclude Device IDs**, device 231 is excluded and the line
reads `setting ignored: exclude_device_ids not a device id: garage`.

System Studio can send the same settings through the Agent. They are written
into these properties, so Composer shows what is running, and a later change
in Composer wins.

## Actions

| Action | What it does |
| --- | --- |
| *Print Recent Events* | The last 50 entries of the local history to the Lua output |
| *Print Events For Inspect Device* | The last 50 entries of the device in **Inspect Device ID**, with its coverage |
| *Print Coverage* | Every device: id, name, driver file, catalogue, events subscribed. Names are cut to 32 characters and file names to 36 |
| *Print Capture Status* | Status, Agent, licence, coverage, counters, active storms |
| *Re-apply Capture Now* | Plans again against the current project. Does nothing while paused or unlicensed |
| *Pause Capture* / *Resume Capture* | Release / rebuild every subscription (also programming commands) |
| *Register With Agent Now* | Looks for the Agent and registers at once instead of waiting for the next try |
| *Refresh Status* | Repaints the status properties and sends the status to the Agent |
| *Clear Local History* | Empties the local history; the sequence starts again at 1 |
| *Forget Learned Events* | Drops the learned catalogue and plans again |

## Reading the status

**Capture Status**

| Value | Meaning | What to do |
| --- | --- | --- |
| `capturing` | Subscribed, Agent link ready | Nothing |
| `capturing_local (…)` | Subscribed and recording locally; the upload path is not ready. The brackets hold the **Agent Connection** value | See the next table |
| `idle` | Capture is on with no subscriptions: nothing in the project is catalogued, or everything is excluded. It can carry the same brackets | Read **Coverage**; consider the probe |
| `paused` | Paused by command, action or System Studio | *Resume Capture* |
| `disabled` | **Capture** is Off | Set it to On |
| `unlicensed` | SmartBuildOS answered that this system is not licensed and enforcement is on. Every subscription is released; the history stays printable | See **License Status**, which ends in `(read-only)` |

A licence check that cannot be completed never stops capture.

**Agent Connection**

| Value | Meaning | What to do |
| --- | --- | --- |
| `ready` | Registered; the Agent is paired and connected | Nothing |
| `waiting_for_agent` | No Agent found, or it has not accepted the registration yet | Install the Agent; *Register With Agent Now*. The driver also retries by itself |
| `unpaired` | Registered, but the Agent is not paired to a SmartBuildOS system | Pair the Agent |
| `degraded` | Registered and paired, but the Agent is not connected to SmartBuildOS | Check the internet. Entries wait in the Agent's queue |
| `incompatible` | The Agent refused the registration as an incompatible version | Update the Agent or this driver |

**Coverage** reads `N subscriptions on A of B devices`, where B is every
device in the project, followed by whichever of these apply:

| Part | Meaning |
| --- | --- |
| `N unknown driver(s)` | Devices in no catalogue. Nothing is captured from them |
| `N excluded` | Your exclusions, plus the tracer itself |
| `N event(s) over Max Subscriptions` | Known or probed events that did not fit. *Print Coverage* marks each device with `(N not subscribed)` |
| `N refused by Director` | Subscriptions Director did not accept |

It reads `capture off` when **Capture** is Off and `not applied yet` before
the first plan. During a pause it reads `paused`, or goes on showing the plan
from before the pause: **Capture Status** and `SUBSCRIPTIONS` are the ones to
trust.

**Catalogue** says how much each catalogue holds and how many subscriptions
it gave:

```text
project: 0 device(s) → 0 subs; built-in: 187 driver(s) → 49 subs; learned: 1 event(s) → 1 subs; probe: 0 subs
```

**Buffered Events** and **Dropped Events.** Buffered entries are on their way
to the Agent. Dropped entries were not uploaded: over the **Upload Budget**,
pushed out of the 300 held while the Agent was away, sent three times without
an answer, or rejected by the Agent. They are still in the local history
unless it has rolled over. **Last Upload** is the last time the Agent
acknowledged a batch.

**Last Capture Error** reads `none`, or the last problem: a setting that was
ignored, a refused registration, the licence. The line
`no SmartBuildOS Agent in this project (capturing locally)` can remain after
the Agent has been found; it clears the next time a capture setting changes.
Trust **Agent Connection** for the state of the link.

**Timing.** **Last Event**, **Events Captured** and **Active Storms** are
repainted two seconds after the last event of a burst. Everything else is
repainted once a minute and when something changes, so **Active Storms** and
`ACTIVE_STORMS` can show a storm for up to a minute after *Event Storm Ended*.
The conditional is always current.

## What is NOT claimed

Director does not tell a driver which programming ran, nor whether a person or
an automation caused an event. An entry says which device fired which event,
when. The "why" is the sequence of entries around it, which is what the
timeline shows. Nothing guesses a cause.

- **Events only.** No event parameters (Director passes none) and no variable
  values.
- **Only what is covered.** A device in no catalogue is reported, not
  captured, unless probing is on, and probing cannot reach event ids above
  **Probe Range**. Named events from Control4's own devices have not been
  confirmed on a controller: on the bench (OS 4.3) the project catalogue was
  empty, and the event recorded there came from a probe subscription,
  unnamed.
- **Storms are counted.** The occurrences a storm suppresses are never
  recorded, locally or in the timeline.
- **A storm under a spent upload budget.** If the **Upload Budget** for that
  minute is already used when a storm starts, *Event Storm Detected* does not
  fire and no warning is uploaded. **Active Storms**, the conditional and
  *Event Storm Ended* still work. *Unknown Event Learned* is held back the
  same way.
- **Exceeding the upload budget is not a degraded state.** **Capture Status**
  stays `capturing` and *Capture Degraded* does not fire; watch **Dropped
  Events**.
- **A pause is a gap.** What fired while capture was paused or off is not
  known.
- **Names are as captured.** An entry keeps the device and room names it was
  recorded with; renaming a device later does not change old entries.
- **Not measured on a controller:** how many subscriptions Director accepts
  above the default, storm detection on a real chattering input, the licence
  stop, settings sent from System Studio, and removal of the driver. Probing
  was left on for eleven hours on the bench controller without disturbing
  Director, and delivered a real event.

## Privacy

Only event ids and names, device and room labels, the driver file name and
timestamps are captured; no variable values. Marker text and the reason given
to `PAUSE_CAPTURE` are service records written by the programmer; marker text
is flagged as unreviewed text in Studio: do not put codes or personal details
into either.

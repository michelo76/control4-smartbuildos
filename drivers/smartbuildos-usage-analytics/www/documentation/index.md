# SmartBuildOS Usage Analytics

Usage Analytics measures how a house is actually used. For every day it works
out how long each room played media and on which source, how long each light
was on, and how often each keypad was pressed, from variables and events the
project already has. It keeps thirty days of these figures on the controller.
You print them in Composer before a service visit, and once a day the driver
hands a short summary to the **SmartBuildOS Agent**, which uploads it for the
Studio usage view.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`, a build with module
services) paired to a SmartBuildOS system, and Control4 OS 3.3.2 or later. The
Agent is the licensing authority (SKU `SBOS_USAGE_ANALYTICS`): **License
Status** shows this driver's standing. Measuring and the printed report do not
need the Agent or the internet: with no Agent, or during an outage, the driver
goes on measuring and **Measuring Status** says so. Uploads wait in the
Agent's bounded, journaled queue.

## Why not count it in programming

You can count one thing in programming: a number variable, and a line on a
button's event that adds one to it. That is still the right tool when
programming has to act on the count of one particular thing. This driver gives
programming only the day's totals for the whole house.

What programming cannot reasonably do is count everything. It would take a
variable and a script line for every button, and a timer for every light and
every room. And the buttons nobody presses are the ones nobody thought to
count. This driver finds the rooms, lights and keypads by itself, needs no
programming, and lists what was never used as well as what was.

## What it is for

| You want | Use |
| --- | --- |
| To know which rooms really play media, and on what, before you propose a change | *Print Usage Report*: "Rooms by media hours", with each room's top source |
| To find rooms where media is never used | The report line "Rooms with no media use" |
| To find lights that burn for long hours, for a timer or an occupancy rule | The report section "Lights by on-hours", with on-cycles |
| To find lights nobody switches on | The report line "Lights never on" |
| To see which keypads and buttons are pressed, before you reassign buttons | The report section "Keypads by presses" and the line "Keypads never pressed" (see [Keypads](#keypads) for which keypads are counted) |
| To check that a new system is being used after handover | **Today** and **Days Recorded**, or the report with **Report Range** on Today |
| The figures in SmartBuildOS without a site visit | The daily summary, sent by itself; *Send Summary Now* or `SEND_USAGE_SUMMARY` for a range |
| A room or a device kept out of the figures | **Exclude Device IDs** |
| To hear when measuring is not healthy | *Measuring Degraded* and *Measuring Restored* |
| The day's totals in your own programming | `MEDIA_HOURS_TODAY`, `LIGHT_HOURS_TODAY`, `KEYPAD_PRESSES_TODAY` |

## Setup

<!-- walkthrough: Set up Usage Analytics -->
1. Install the SmartBuildOS Agent from Composer's Agents tab and pair it.
1. Add this driver (one per project). **Driver Status** reads `Online`,
   **Agent Link** shows the Agent's device id and **Agent Connection** reads
   `ready` once registered.
1. Read **License Status**. It reads `SmartBuildOS Agent Found - Checking...`
   until the Agent answers, then the licence.
1. Read **Sources**. It reports how many rooms, lights and keypads are
   measured. There is nothing to configure.
1. On the Actions tab press *Print Sources* and compare the list in the Lua
   tab with the project. Put the id of anything that should not be measured in
   **Exclude Device IDs**.
1. Leave it running. **Today** keeps a running total and is refreshed once a
   minute; **Days Recorded** goes up by one each day.

![Usage Analytics in Composer: the Properties tab, status at the top and settings below](images/properties.jpg)

![The Actions tab](images/actions.jpg)

## What is measured

Devices are recognised by the variables they have and the events their driver
declares, never by their name.

| Kind | Which devices | What counts | Recorded per day |
| --- | --- | --- | --- |
| Rooms | Every room that holds a device and has the room variable `POWER_STATE` or `CURRENT_SELECTED_DEVICE` | In use while `POWER_STATE` is on | Hours in use, and hours per selected source |
| Lights | Every device with a variable named `LIGHT_STATE`, `LIGHT_LEVEL` or `Brightness Percent` | On while `LIGHT_STATE` is true or the level is above zero | Hours on, and on-cycles |
| Keypads | Every device whose driver is in the built-in event catalogue with at least one press event | Each press event | Presses, and presses per button |

### Rooms

- The source is the device in `CURRENT_SELECTED_DEVICE`. Its name is the
  device's display name at the moment it was selected, or `Device` and its id
  when the name cannot be read. Time with the room on and no source selected
  is booked under `(no source)`.
- A room whose `POWER_STATE` has never been read counts as in use while a
  source is selected.
- A room with neither variable is counted in **Sources** as "without media
  variables" and is not measured.

### Lights

- An on-cycle is one change from off to on. Reading a light that is already
  on when the driver starts is not a cycle, and the same value announced twice
  is not a second cycle.
- Anything with one of the three variable names is a light, whatever its
  driver.

### Keypads

- A press event is an event whose name contains push, press, click or tap and
  does not contain release. "Top Button Pushed" and "Button 1 - Double Tap"
  count; "Top Button Released" does not. Each event is one button in the
  report.
- The driver can only subscribe to events it knows by id. It knows them from a
  catalogue built into the driver when it is packaged, made from the driver
  files in the builder's library. **A keypad whose driver file is not in that
  catalogue is not measured and does not appear in Sources or in the "never
  pressed" list.**
- In the catalogue on this branch, nine driver files declare press events: a
  few third-party keypads, door stations and camera drivers. Control4's own
  keypad drivers are not in a dealer's driver library, so they are not in the
  catalogue, and in this build their buttons are not counted. *Print Sources*
  shows exactly which devices are.
- A device can be both a light and a keypad. A door station with a
  button-press event is counted as a keypad.

### Limits

| Limit | Value |
| --- | --- |
| Rooms measured | 64 |
| Lights measured | 200 |
| Keypads measured | 100 |
| Variable listeners in all (a room uses up to 2, a light up to 3) | 600 |
| Days kept | 30 |
| Rows printed per report section | 25 |
| Buttons printed per keypad | 4, the most pressed |

Devices are taken in ascending id order, so a limit always cuts the same
ones. What did not fit is counted in **Sources** as "over the cap".

## How the figures are kept

- **Time is booked when it is known.** Running time is added on every change
  and once a minute, so a day boundary puts at most one minute in the wrong
  day.
- **Unknown is not off.** Nothing is counted for a room or a light until its
  state has been read. The driver reads the current values when it plans its
  sources, so a room already playing counts from that moment.
- **Days are the controller's local calendar days.**
- **Hours are shown to one decimal.** Under three minutes shows as 0.0; ten
  minutes shows as 0.2.
- **Sources are planned again** when the driver starts, when it registers
  with the Agent, five seconds after the Agent reports a project change or a
  Director reload, when **Measuring** or **Exclude Device IDs** changes, and
  on *Refresh Sources*. With no Agent registered nobody reports project
  changes: press *Refresh Sources* after adding devices.
- **Saving.** The recorded days are written to the controller's storage at
  most every five minutes, and only after something changed, and again when
  the driver is updated or removed. After a restart the days are back and the
  current states are read again. Time while the driver was not running is not
  counted, and a power cut loses what was counted since the last save.
- **Thirty days are kept.** Older days are dropped.

"Never" in the report means: not once in the days the report covers, among the
devices measured now. A light added yesterday is "never on" in a 30-day
report. A range of 7 or 30 days covers that many recorded days, which are
fewer while **Days Recorded** is still below the range.

## The daily summary

At the first one-minute tick after local midnight the driver closes the day
that ended and builds one summary of it (event type `usage.daily`).

- *Daily Summary Sent* fires and **Last Daily Summary** takes the time. Both
  mean the summary was built and queued for the Agent, not that SmartBuildOS
  has received it.
- With the Agent link registered, the summary goes to the Agent within
  seconds. When the Agent acknowledges it, **Last Upload** takes the time.
  From there the Agent uploads it from its own queue.
- With no Agent registered the summary waits in the driver's memory, up to
  300 queued items, and goes when the Agent registers. This wait does not
  survive a driver restart.
- A day is sent once. If its summary was lost, the day's figures are still on
  the controller and are part of any range summary that covers the day.
- A day that ended while the driver was not running is closed and sent at
  the next midnight, together with that day's own summary.
- **Measuring** set to Off does not stop the summary: days already recorded
  are still closed and sent.

A range summary (event type `usage.summary`) has the same content for the
last 1, 7 or 30 recorded days. Send one with *Send Summary Now*, which uses
**Report Range**, or with the programming command `SEND_USAGE_SUMMARY`.

## What leaves the controller

Usage figures go to one place: the driver hands them to the SmartBuildOS
Agent in the same project, and the Agent uploads them. The driver sends them
nowhere else.

**The summary** (daily and range) holds only these fields:

| Field | What it holds |
| --- | --- |
| `period`, `days` | The date of the day, or `1d`, `7d`, `30d`; and how many recorded days it covers |
| `media_hours`, `light_hours`, `keypad_presses` | The three totals |
| `rooms_measured`, `lights_measured`, `keypads_measured` | How many of each are measured |
| `rooms` | Up to 15 rooms: room name, hours, name of its top source |
| `lights_top` | Up to 10 lights: light name, hours, on-cycles |
| `keypads` | Up to 15 keypads: keypad name, presses |
| `unused_rooms`, `unused_keypads` | Up to 15 names each |
| `unused_lights_count` | A number, no names |

One day of the example in [Worked examples](#worked-examples) is sent as:

```json
{
  "period": "2026-11-09",
  "days": 1,
  "media_hours": 2,
  "light_hours": 2,
  "keypad_presses": 5,
  "rooms_measured": 2,
  "lights_measured": 2,
  "keypads_measured": 2,
  "rooms": [{ "room": "Kitchen", "hours": 2, "top_source": "Apple TV" }],
  "lights_top": [{ "light": "Pendants", "hours": 2, "cycles": 1 }],
  "keypads": [{ "keypad": "Hall Keypad", "presses": 5 }],
  "unused_rooms": ["Office"],
  "unused_keypads": ["Garage Keypad"],
  "unused_lights_count": 1
}
```

Names are the project's own names, cut to 60 characters. Around the summary
the driver adds the event type, a label such as `Usage 2026-11-09`, its own
device id, the controller's time in UTC, a sequence number and fixed fields
that say what kind of event it is.

**Also sent:**

- Each time sources are planned, the counts shown in **Sources** (event type
  `usage.plan_applied`): numbers of devices, rooms, lights, keypads, listeners,
  subscriptions, excluded and over the cap. No names.
- To the Agent, at registration and every five minutes after: the driver
  version, **Measuring Status**, the **Last Error** text and counters (changes
  seen, presses, days closed, days recorded, queue counts).
- For licensing: the SKU and this driver's device id.

**Not in anything sent:** device ids of rooms, lights or keypads, presses per
button, sources other than each room's top one, and the time of day of any
use.

**Kept on the controller only** (in the thirty recorded days): hours per
source for every room, presses per button, each light's room name, and the
times of the day's first and last counted activity.

**Never recorded at all:** media titles, volumes, and the value of any
variable other than the five named under
[What is measured](#what-is-measured). When it plans, the driver reads each
device's list of variables to find those names; it keeps nothing else from
that list.

SmartBuildOS can ask the driver, through the Agent, for three things only: to
send a range summary, to plan the sources again, and to refresh its status.

To keep a room, a light or a keypad out of the figures and out of what is
sent, put its id in **Exclude Device IDs**. That works from then on: days
already recorded keep its figures, in the report and in any range summary,
until they age out or you press *Reset Statistics*. A source cannot be
excluded: its name appears when it is a measured room's top source.

## Worked examples

### Read the house before a service visit

<!-- walkthrough: Print the usage report -->
1. In Composer, select the driver. Check that **Days Recorded** covers the
   period you want; a driver added last week has a week.
1. Set **Report Range** to 30 days (or 7 days, or Today).
1. On the Actions tab press *Print Usage Report*.
1. Open the Lua tab and read the report. Each line starts with the time and
   `[PRINT]:`. It prints whatever **Log Mode** is set to.
1. Note what to raise with the client: rooms with no media use, lights with
   long hours, keypads never pressed.

This is the report for a small house over two recorded days: the Kitchen
played Apple TV for two hours, the Pendants were on for three hours in two
goes, the Hall Keypad was pressed six times, and the Office, the Garage
Keypad and the Desk Lamp were not used.

```text
== Usage 7 days (2 day(s)): media 2.0 h, lights 3.0 h, 6 keypad press(es) ==
-- Rooms by media hours
  Kitchen                         2.0 h  top: Apple TV (2.0 h)
-- Lights by on-hours
  Pendants                        3.0 h    2 cycle(s)  Kitchen
-- Keypads by presses
  Hall Keypad                      6  Top Button Pushed 5, Bottom Button Pushed 1
-- Rooms with no media use: Office
-- Keypads never pressed: Garage Keypad
-- Lights never on: Desk Lamp
```

A last line gives the measuring status, the Agent link and the licence. A
button that was never pressed is not listed under its keypad: compare the
buttons shown with the buttons the keypad has.

### Check on the bench that it measures

1. Play a source in one room for ten minutes. With **Report Range** on Today,
   *Print Usage Report* shows that room with that source as its top source
   and 0.2 h.
1. Switch a measured light on and off twice. The report shows it with 2
   cycle(s).
1. Press a button on a keypad that *Print Sources* lists. **Today** shows the
   press within a minute.

### Leave a room or a device out

*Print Sources* lists every measured room, light and keypad with its id:

```text
  room     3  Kitchen                      CURRENT_SELECTED_DEVICE, POWER_STATE
  room     4  Office                       CURRENT_SELECTED_DEVICE, POWER_STATE
  light   12  Kitchen Pendants             Kitchen
  light   13  Office Lamp                  Office
  keypad  40  Hall Keypad                  2 press event(s)
```

To leave out the Office and the Office Lamp, type `4, 13` in
**Exclude Device IDs**. The driver plans again at once and **Sources** ends
with `2 excluded`. Excluding a room stops its media hours only; a light or a
keypad in that room is excluded by its own id. Days already recorded are not
changed.

### A weekly summary, and a warning when measuring is not healthy

- **Weekly summary.** On a weekly event of the Scheduler, add this driver's
  command `SEND_USAGE_SUMMARY` and type `7` in `DAYS`.
- **Warning.** On this driver's event *Measuring Degraded*, send yourself a
  notification with the variable `MEASURING_STATUS` in it. The event also
  fires when only the Agent link is down, for example during an internet
  outage, while measuring goes on locally. *Measuring Restored* fires when it
  is healthy again, and also once after every driver start, when the Agent
  link becomes ready.

## Programming reference

### Command

| Command | Parameter | What it does |
| --- | --- | --- |
| `SEND_USAGE_SUMMARY` | `DAYS`: `1`, `7` or `30` | Queues a range summary for the Agent. Any other value is sent as 7 days. In the script it reads "Send a usage summary for a range of days to SmartBuildOS (1, 7 or 30)" |

### Events

| Event | Fires when |
| --- | --- |
| *Measuring Degraded* | **Measuring Status** leaves `measuring`, `idle` or `disabled` for any other value: the Agent link is not ready, or the licence halted measuring |
| *Measuring Restored* | **Measuring Status** returns to `measuring`, `idle` or `disabled` |
| *Daily Summary Sent* | Yesterday's summary was built and queued for the Agent |
| *Agent Connected* | The Agent accepted this driver's registration (after every driver start and every Agent restart) |
| *Agent Disconnected* | The Agent refused this driver's registration |

The status is checked once a minute and whenever something changes, so the
two measuring events can follow their cause by up to a minute.

### Conditionals

- *Measuring is active*: true while **Measuring Status** is `measuring` or
  begins with `measuring_local`.
- *SmartBuildOS Agent link is ready*: true while **Agent Connection** is
  `ready`.

### Variables

All are read-only and are refreshed once a minute with the properties.

| Variable | Type | Holds |
| --- | --- | --- |
| `MEASURING_STATUS` | text | The same as **Measuring Status** |
| `AGENT_CONNECTION` | text | The same as **Agent Connection** |
| `MEDIA_HOURS_TODAY` | text | Today's media hours over all rooms, one decimal, such as `2` or `0.5` |
| `LIGHT_HOURS_TODAY` | text | Today's on-hours over all lights, one decimal |
| `KEYPAD_PRESSES_TODAY` | number | Today's presses over all keypads |
| `DAYS_RECORDED` | number | Days held, today included |
| `SOURCES` | text | The same as **Sources** |
| `BUFFERED_EVENTS`, `DROPPED_EVENTS` | number | The same as the two properties |
| `LAST_ERROR` | text | The same as **Last Error** |

Per-room, per-light and per-keypad figures are in the report and the summary,
not in variables.

## Properties

### Status

All are read-only.

| Property | Shows |
| --- | --- |
| **Driver Status**, **Driver Version** | `Online` once started; the installed version |
| **Measuring Status** | Whether it is measuring. See [Reading the status](#reading-the-status) |
| **Agent Link** | `Agent device 72 — registered` with the Agent's device id, or that no Agent was found |
| **Agent Connection** | The state of the link to the Agent |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | The licence as the Agent reports it |
| **Sources** | What is measured, for example `2 room(s), 2 light(s), 1 keypad(s); 7 listener(s), 2 event subscription(s); 1 room(s) without media variables` |
| **Today** | Today's totals, for example `media 2.0 h, lights 3.6 h, 6 keypad press(es)` |
| **Days Recorded** | Days held, today included, up to 30 |
| **Last Daily Summary** | When the last daily summary was built and queued. Kept across restarts |
| **Last Upload** | When the Agent last acknowledged something from this driver |
| **Buffered Events**, **Dropped Events** | Items waiting in this driver for the Agent, and items this driver gave up on since it started |
| **Last Error** | The last problem, or `none` |

### Settings

| Property | Default | What it does |
| --- | --- | --- |
| **Measuring** | On | Off releases every listener and subscription; recorded days are kept. See the note below |
| **Report Range** | 7 days | Today, 7 days or 30 days: the range *Print Usage Report* and *Send Summary Now* cover |
| **Exclude Device IDs** | empty | Room ids and device ids to leave out, separated by commas, semicolons or spaces |
| **Log Level**, **Log Mode** | 2 - Warning, Off | The driver's own log. The Print actions do not depend on them |

**Measuring set to Off stops the listening, not a count already running.** A
light or a room that was on at that moment goes on adding hours until
**Measuring** is On again or the driver restarts. To pause cleanly, switch it
Off while those rooms and lights are off. The same happens while the licence
halts measuring.

## Actions

| Action | What it does |
| --- | --- |
| Print Usage Report | The report for the **Report Range**, in the Lua tab: rooms by media hours with top source, lights by on-hours with cycles, keypads by presses with their four most-pressed buttons, then the three "never" lists |
| Print Sources | Every measured room, light and keypad with its id |
| Refresh Sources | Plans the sources again against the current project |
| Send Summary Now | Queues a range summary for the **Report Range** |
| Reset Statistics | Drops every recorded day and **Last Daily Summary**, and starts again |
| Register With Agent Now | Looks for the Agent and registers again; a successful registration also asks for the licence again |
| Refresh Status | Refreshes the properties now and sends the Agent the status |

## Reading the status

### Measuring Status

| Value | Meaning | What to do |
| --- | --- | --- |
| `starting` | The driver has not finished starting | Wait |
| `measuring` | Listening, and the Agent link is ready | Nothing |
| `idle` | **Measuring** is On but no room, light or keypad was found | Read **Sources**; press *Refresh Sources* |
| `measuring_local (…)`, `idle_local (…)` | The same, but the Agent link is not ready. The brackets hold **Agent Connection** | Measuring goes on. Follow the Agent Connection table |
| `disabled` | **Measuring** is Off | Set it to On |
| `unlicensed` | The licence is definitively refused and SmartBuildOS enforces it. Nothing is listened to; recorded days are kept | **Last Error** names the licence status. Put the licence right in SmartBuildOS; measuring resumes by itself |

A licence check that is unanswered or uncertain never stops measuring.

### Agent Connection

| Value | Meaning | What to do |
| --- | --- | --- |
| `ready` | Registered; the Agent is paired and connected | Nothing |
| `waiting_for_agent` | No Agent in the project, or it has not accepted the registration yet | Install the Agent, or press *Register With Agent Now*. The driver also retries by itself, at most five minutes apart |
| `incompatible` | The Agent refused the registration because the two do not speak the same protocol version | Update the Agent and this driver |
| `unpaired` | Registered, but the Agent is not paired to a SmartBuildOS system | Pair the Agent |
| `degraded` | Registered and paired, but the Agent reports no connection to SmartBuildOS | Check the controller's internet connection. Summaries wait in the Agent's queue |

### Sources, Last Error and the event counters

**Sources** reads `not planned yet` before the first plan and while
**Measuring** is Off. Otherwise it gives the measured counts, the listeners
and event subscriptions in use, and, when they are not zero, rooms without
media variables, exclusions and devices over the cap.

**Last Error** keeps the last message. It is not cleared when the cause goes
away: it returns to `none` when the driver restarts or when a licence halt
ends. Read it together with the two status properties.

| Last Error | Meaning |
| --- | --- |
| `no SmartBuildOS Agent in this project (measuring locally)` | No Agent was found when the driver looked. It stays after the Agent is found |
| `Agent refused registration: …` | The Agent answered no, with its reason. A second copy of this driver in the project is refused |
| `SmartBuildOS licence: …` | Measuring is halted by the licence; the text is **License Status** |
| `event refused: …` | A summary could not be built, for example `payload_too_large`. Nothing was sent |
| `plan failed: …` | Planning the sources raised an error at start. Press *Refresh Sources* |
| `persisted statistics unreadable; starting empty` | The saved days could not be read after a restart; recording began again |

**Buffered Events** above zero for long means the Agent is not acknowledging:
look at **Agent Connection**. **Dropped Events** counts what this driver gave
up on: an item the Agent did not acknowledge after three tries thirty seconds
apart, an item the Agent rejected, or the oldest item when more than 300 were
waiting. It starts from zero when the driver restarts.

## What is not claimed

- Media hours say the room was on and which source was selected, not that
  anyone watched.
- Keypad presses count Composer press events the keypad driver declares. A
  keypad whose driver declares none, or whose driver is not in the built-in
  catalogue, is not measured and is not listed anywhere.
- Light hours follow the light's own variables. A load that reports nothing
  is not seen.
- *Daily Summary Sent*, **Last Daily Summary** and **Last Upload** mark the
  hand-over on the controller. None of them confirms that SmartBuildOS has the
  data, and this manual does not describe what Studio shows.
- A summary lists the top 15 rooms, 10 lights and 15 keypads, and the
  printed report the top 25 of each. In a larger house the rest is recorded
  but not shown.
- On the bench (9 and 10 November 2026, OS 4.3) the driver registered with the
  Agent, read `measuring` with 4 rooms and 2 lights, ran *Print Sources*,
  *Print Usage Report* and *Send Summary Now*, and ran `SEND_USAGE_SUMMARY`
  from programming with **Last Upload** moving. That bench had no measured
  keypad, so keypad counting has been checked in the test suite only.

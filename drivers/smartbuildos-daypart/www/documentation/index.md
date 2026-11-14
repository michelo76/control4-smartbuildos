# SmartBuildOS Daypart Scheduler

The Daypart Scheduler plays the day for a room. The dealer sets up zones (a
dining room, a showroom, an open office), says which music sources each zone
may use, how loud it may get, and which displays go with it. After that, the
manager opens one tile on a touch screen or phone and lays out the week in
blocks, such as "Mon-Fri 07:00-11:00, Morning playlist, volume 30". No
Composer, no programming, no call to the installer when the lunch menu music
changes.

The point is the limit. Staff can only choose from what the dealer allowed:
the sources on the list, a volume inside the range, the displays of that zone.
They cannot pick a source the zone was not given, set a volume above the
maximum, or save two blocks that overlap.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a
SmartBuildOS system. The Agent is the licensing authority (SKU
`SBOS_DAYPART`): **License Status** shows this driver's standing. A
definitive licence denial with enforcement on **halts** the schedule: no more
block actions are sent, the page stays readable and read-only, and nothing is
deleted. Only a definitive denial does this. A missing Agent, an Agent that
has not answered yet or a cloud that cannot be reached leave the schedule
running.

## What it does

- A weekly grid of blocks per zone. Each block has a name, days, a start and
  an end, a source, a volume and a display choice (leave, on, off).
- At a block's start it selects the source, moves the volume to the block's
  level over a set number of seconds, and switches the zone's displays.
- When the last block ends and nothing follows, it holds, fades out, or turns
  the room off, as the dealer chose.
- **Holidays**: a list of dates that use an alternate day, the holiday
  blocks, instead of the weekly ones.
- **Today only**: blocks that replace the weekly ones for today and then
  disappear.
- Blocks may run past midnight (22:00 to 02:00). They belong to the day they
  start on.

## Setup (the dealer)

<!-- walkthrough: Set up a zone -->

1. Add the driver to the project. Wait for **License Status** to show the
   licence.
2. Set **Manager PIN**. Without one the page is read-only. Five wrong PINs
   lock editing for a minute (the action *Reset PIN Lock* clears it).
3. For zone 1, type a **Zone 1 Name** (the name staff see) and pick **Zone 1
   Room**. The lists read `Name (Room) · id`. If a list looks empty, run the
   action *Refresh Device Lists*. Type a few letters in **Device List
   Filter** to shorten the source and display lists.
4. Pick the allowed sources in **Zone 1 Source 1** to **Source 4**, the
   **Min Volume** and **Max Volume**, and up to two **Display** devices.
5. Set **Volume Ramp Seconds**, **End Behaviour** and, for Fade Out, **Fade
   Out Seconds**.
6. Repeat for zones 2 to 4 if needed (a zone with no name or no room is not
   used).
7. Put the **Daypart Scheduler** tile on the Navigators that staff use. The
   page address appears under **App Data Relay**. If the tile does not load on
   a touch screen, set **App Relay Address** to the controller's address.

## Using the page (the manager)

Pick a zone. The top card says what is playing now and what comes next.

- **Weekly** shows Monday to Sunday. Tap a block to change it, or **+ Add
  block**. The list under the grid shows the same blocks with larger
  targets.
- **Holidays** lists the holiday dates and the holiday blocks. On a holiday
  date only the holiday blocks run. If there are none, nothing runs that day.
- **Today only** shows the blocks for today. They vanish after today.
  *Clear today's override* puts the week back.
- **Skip next block** skips the next block in this zone, once.
- **Pause schedule** stops all block actions until resumed.
- In a block, **Run now** starts it at once; it holds until the schedule moves
  on from what it replaced.

The first change asks for the Manager PIN. The page keeps it only until it is
closed. A block that cannot be saved says why in the form: an overlap names
the block it overlaps and the day.

Changing the block that is running right now takes effect right away (a new
volume or source is applied, with the same ramp).

## Programming surface

### Events

| Event | When |
| --- | --- |
| Block Started | A block started in a zone. `EVENT_ZONE` and `EVENT_BLOCK` say which |
| Block Ended | A block ended in a zone. Same variables |
| Schedule Paused / Schedule Resumed | The schedule was paused or resumed |
| Schedule Edited | Someone changed the schedule on the page |
| Schedule Halted / Schedule Restored | The licence halted the schedule, or it is running again |

Use Block Started or Block Ended to hang lighting or shades on a block ("when
*Happy hour* starts in *Dining Room*, dim the lights").

### Actions and commands

| Command | Parameters | What it does |
| --- | --- | --- |
| `RUN_BLOCK_NOW` | `ZONE`, `BLOCK` | Runs the named block now (zone by name or number) |
| `PAUSE_SCHEDULE` | | Stops all block actions |
| `RESUME_SCHEDULE` | | Resumes, and picks up the block that should be running |
| `SKIP_NEXT_BLOCK` | `ZONE` | Skips the next block in a zone (empty or `ALL`: every zone) |
| `RELOAD` | | Re-reads the zone properties and device lists |

### Conditionals

- **Schedule is paused** (true when paused or halted).
- **Zone has an active block**: type the zone name; `=` means it has one,
  `!=` means it has none.

### Variables

`CURRENT_BLOCK_1` to `CURRENT_BLOCK_4` (the running block's name, empty when
none), `NEXT_BLOCK_1` to `NEXT_BLOCK_4`, `NEXT_BLOCK` (the soonest of all),
`SCHEDULE_STATUS`, `EVENT_ZONE`, `EVENT_BLOCK`.

## What happens when

- **Controller restart in a block.** The driver works out which block should
  be running now. If it was already running it carries on without sending the
  source again, and without announcing it. If the volume was still ramping it
  continues from the level the room is at. If a block started or ended while
  the controller was down, the change happens now, with the ramp.
- **No blast.** A room that was off, or whose level cannot be read, comes up
  from the zone's minimum volume, not from the level it last played at. A
  block's volume is clamped to the zone's range again when it runs, so a
  range narrowed later is honoured.
- **Clock and daylight saving.** Blocks follow the wall clock. A block that
  starts in the hour that does not exist (02:30 on a spring-forward night)
  starts when the clock passes that time. In the repeated hour of a fall-back
  night a block starts once and ends once. If the controller's clock is
  changed, or the controller stalls, the schedule re-reads the time within
  about ten seconds and puts the room right.
- **Overlaps.** Refused when saved, never at run time. If two blocks are ever
  live at once (a block running past midnight and the next day's own first
  block), the one that started later wins.
- **Skipped block.** If the skipped block was meant to follow another one,
  the first block's end becomes a gap and the end behaviour applies.
- **No Flight Recorder.** Block starts, ends and every schedule edit (what
  changed, from where, never the PIN) are written to the Flight Recorder when
  the project has one. Without it nothing is lost; the page shows the last
  edit under **Last Edit** in the driver properties.

## Properties

| Property | Meaning |
| --- | --- |
| Schedule Status, Zones, Next Block, Last Edit, Last Refusal | What the schedule is doing |
| Manager PIN | Needed on the page for every change; empty means read-only |
| Volume Ramp Seconds | 0 to 600; 0 sets the level at once |
| End Behaviour, Fade Out Seconds | Hold, Fade Out (to silence, then room off) or Off |
| Zone N Name, Room, Source 1-4, Min/Max Volume, Display 1-2 | The dealer's limits, four zones |
| Device List Filter | Narrows the source and display lists |
| App Relay Address | Leave on `Auto` unless the tile does not load |

## Limits

| What | Limit |
| --- | --- |
| Zones | 4 |
| Sources per zone | 4 |
| Displays per zone | 2 |
| Blocks per list (week, holiday, today) | 40 |
| Holiday dates | 60 |
| Block name | 40 characters |

- Times are to the minute (the page offers five-minute steps).
- A holiday applies to every zone at once; each zone has its own holiday
  blocks.
- There is one "today only" set per zone and it lasts until the end of the
  day.
- A zone controls one room. A display is switched with plain `ON` and `OFF`.
- Remote schedule backup and editing through the SmartBuildOS Agent are not
  built yet (see the design note).

## Unverified on a controller

This driver was written and tested off the controller. Not yet checked on a
real project:

- That `SELECT_AUDIO_DEVICE`, `SET_VOLUME_LEVEL` and `ROOM_OFF` sent to a
  room do what the schedule expects with real media sources, and that a source
  change does not move the volume on its own.
- That a room's `POWER_STATE` and `CURRENT_VOLUME` read as the driver assumes
  (it treats `0`, `OFF` and `FALSE` as off).
- That `ON` and `OFF` switch a real television through its proxy.
- That the room, source and display lists fill with real names, and that an
  id typed after the dot survives a project rename.
- That the page loads in a real Navigator and a phone, that the dialogs and
  the date field work there, and how the grid reads on a small screen. The
  page was only loaded in a desktop browser against a stand-in server.
- The restart, clock-change and daylight-saving behaviour with real
  controller clocks. It is covered by automated tests with a simulated
  clock.
- The Flight Recorder markers appearing in its history.
- The conditionals, variables and events as they appear in Composer.
- The licence halt with a real Agent.

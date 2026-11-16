# SmartBuildOS Daypart Scheduler

**Music, volume and displays that follow the clock, set by the people who work
in the room, inside limits the dealer chose.**

Think of a restaurant. The room should feel different at 08:00 (quiet, a few
people having coffee), at lunch (lively jazz), on a Friday night (the game on
the big screen, louder) and at closing (fade out, lights down). Someone has to
make those changes every day. Today that someone is a manager walking to a wall
panel, or an installer who gets a phone call every time the menu changes.

The Daypart Scheduler removes that person from the loop. The dealer sets up a
**zone** once ("Dining Room"), says what the zone is allowed to do, and then
hands the manager one tile on a touch screen or phone. The manager lays out the
week in **blocks**. The controller does the rest, every day, without anyone
touching it.

The important part is the limits. Staff can only choose what the dealer allowed.
They cannot pick a source the zone was not given, push the volume above the
maximum, or save two blocks that overlap. The room cannot be broken from the
page, so the dealer can give the page to anyone.

> **Requires the SmartBuildOS Agent** (`smartbuildos.c4z`) paired to a
> SmartBuildOS system. The Agent is the licensing authority (SKU
> `SBOS_DAYPART`). See [Licensing](#licensing).

## Contents of this manual

1. [How it fits together](#how-it-fits-together) - zones, blocks, scopes
1. [Real-world examples](#real-world-examples) - five complete setups you can
   copy
1. [Setting it up (the dealer)](#setting-it-up-the-dealer)
1. [Using the page (the manager)](#using-the-page-the-manager)
1. [Programming it from Composer](#programming-it-from-composer) - events,
   commands, recipes
1. [What happens when](#what-happens-when) - restarts, clocks, overlaps
1. [Troubleshooting](#troubleshooting)
1. [Reference](#reference) - properties, limits
1. [What has been verified, and what has not](#what-has-been-verified-and-what-has-not)

## How it fits together

### Zones

A **zone** is one room's worth of control. The dealer defines it with a handful
of properties:

| The dealer chooses             | Why it matters                                 |
| ------------------------------ | ---------------------------------------------- |
| **Name**                       | What staff see ("Dining Room", "Showroom")     |
| **Room**                       | The Control4 room the zone controls            |
| **Up to four sources**         | The only music or video sources staff can pick |
| **Minimum and maximum volume** | The range the volume can ever be in            |
| **Up to two displays**         | The televisions a block can switch on or off   |

There can be up to four zones per Daypart driver.

### Blocks

A **block** is one stretch of the day with one behaviour. It has:

- a **name** ("Happy hour"),
- the **days** it applies to,
- a **start** and an **end** time,
- a **source** (one of the zone's sources, or "music off"),
- a **volume**,
- and a **display** choice: leave the television alone, switch it on, or switch
  it off.

When a block starts, the driver selects the source, moves the volume to the
block's level over a set number of seconds (the *ramp*, so it never jumps), and
switches the displays. A ramp cut short by a pause or a controller restart
carries on to the block's level when the schedule resumes, for a scheduled block
and for one started by hand. When the last block of the day ends and nothing
follows, the driver does what the dealer chose: **hold** (leave the room as it
is), **fade out** (lower the volume to silence, then turn the room off) or
**off**.

A block may run past midnight (22:00 to 02:00). It belongs to the day it starts
on.

### Three layers: Weekly, Holidays, Today only

| Layer          | What it is                                                                          | Use it for                                                      |
| -------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| **Weekly**     | The normal week, Monday to Sunday                                                   | Everyday life                                                   |
| **Holidays**   | A list of dates, plus the blocks that run on those dates instead of the weekly ones | Christmas Day, a bank holiday, the day the restaurant is closed |
| **Today only** | Blocks that replace the weekly ones for today, then disappear                       | A private party, a one-off event, a quiet day                   |

On a holiday date only the holiday blocks run. If there are none, nothing runs
that day. Today's override vanishes by itself at the end of the day.

## Real-world examples

Every example below is a complete setup: what the dealer sets in Composer, what
the manager enters on the page, and what the room does. The first one was built
and run on a real controller on the SmartBuildOS test bench.

### Example 1: The restaurant (set up and run on the bench)

**The situation.** A restaurant with one main dining room. The owner wants calm
music in the morning, livelier music at lunch, a good happy hour, the football
on weekends, and a soft late lounge on Friday and Saturday nights. The staff
must not be able to blast the room or leave the TV on all night.

**What the dealer sets in Composer** (zone 1):

| Property                | Value                                |
| ----------------------- | ------------------------------------ |
| Zone 1 Name             | Dining Room                          |
| Zone 1 Room             | the dining room                      |
| Zone 1 Source 1 / 2 / 3 | Bluetooth Audio, CD Player, Apple TV |
| Zone 1 Min / Max Volume | 15 / 55                              |
| Zone 1 Display 1        | the dining room television           |
| Volume Ramp Seconds     | 20                                   |
| End Behaviour           | Fade Out, 30 seconds                 |
| Manager PIN             | set to something only managers know  |

**What the manager enters on the page:**

| Block           | Days          | Time        | Source          | Volume | Display |
| --------------- | ------------- | ----------- | --------------- | ------ | ------- |
| Opening ambient | Every day     | 07:00-11:30 | Bluetooth Audio | 25     | Leave   |
| Lunch jazz      | Every day     | 11:30-14:00 | CD Player       | 35     | Leave   |
| Afternoon       | Mon-Fri       | 14:00-17:00 | Bluetooth Audio | 30     | Leave   |
| Happy hour      | Mon-Fri       | 17:00-19:00 | CD Player       | 40     | Leave   |
| Game night      | Fri, Sat, Sun | 19:00-23:00 | Apple TV        | 45     | On      |
| Late lounge     | Fri, Sat      | 23:00-02:00 | CD Player       | 30     | Off     |

**What the room does on a Friday.** At 07:00 the controller selects Bluetooth
Audio and brings the volume up to 25 over 20 seconds. At 11:30 it switches to
the CD player and ramps to 35. At 17:00 happy hour lifts it to 40. At 19:00 it
selects Apple TV, ramps to 45 and turns the television on. At 23:00 the
television goes off and the CD player takes over at 30, running past midnight
until 02:00. At 02:00, with no block following, the room fades out and shuts
off. Saturday is the same except the afternoon and happy hour blocks (Mon-Fri)
do not run. On Sunday there is no late lounge, so the room fades out at 23:00.

**What was seen on the bench.** With the schedule resumed, the Game night block
started by itself and sent its commands (select the source, set the volume to
45, television on). A Lunch jazz started by hand ramped from 45 down to 35, one
step every two seconds. At 23:00 Late lounge started on its own, turned the
display off and began ramping to 30. Overlapping blocks were refused, a source
that is not in the zone was refused, a wrong PIN was refused, and a volume above
the zone's maximum was brought down to the maximum with a warning.

### Example 2: A retail showroom with a seasonal sale

**The situation.** A furniture showroom. Soft background music while customers
browse, a brighter playlist on Saturdays, and a promotional video on the display
wall during a sale.

**Dealer setup:** Zone "Showroom", sources *Digital Music* and *Apple TV* (the
promo reel), volume 10 to 35, display *Wall Display*, ramp 10 seconds, End
Behaviour Off.

| Block           | Days    | Time        | Source        | Volume | Display |
| --------------- | ------- | ----------- | ------------- | ------ | ------- |
| Browse          | Mon-Fri | 09:30-17:30 | Digital Music | 18     | Off     |
| Saturday energy | Sat     | 10:00-18:00 | Digital Music | 28     | On      |
| Sunday soft     | Sun     | 11:00-16:00 | Digital Music | 15     | Off     |

**The sale weekend.** The manager does not edit the week. On Friday evening they
open **Today only**, add a block "Sale reel" (Apple TV, volume 22, display On,
09:30-18:00) and save it. For that day it replaces the normal blocks. At
midnight it disappears and the normal week is back. Nobody has to remember to
undo it.

**Bank holiday.** The manager adds the date under **Holidays**, then adds one
holiday block ("Holiday browse", 11:00-16:00). On that date only that block
runs.

### Example 3: An open-plan office

**The situation.** An open office wants low background sound during working
hours and nothing at all the rest of the time. No displays.

**Dealer setup:** Zone "Open Office", one source *Digital Music*, volume 10 to
25, no display, ramp 30 seconds, End Behaviour Off.

| Block       | Days    | Time        | Source        | Volume |
| ----------- | ------- | ----------- | ------------- | ------ |
| Working day | Mon-Fri | 08:30-17:30 | Digital Music | 14     |
| Lunch lift  | Mon-Fri | 12:00-13:30 | Digital Music | 18     |

The ramp of 30 seconds makes the changes feel like the room breathing, not like
a button press. The maximum of 25 means a well-meaning employee cannot turn the
"background" music into a party. If the office is closed for a company day, a
holiday date with no holiday blocks keeps it silent.

### Example 4: A gym with two zones

**The situation.** A gym with a main floor and a studio. They need separate
music, and a spin class that changes the studio at fixed times.

**Dealer setup:** Zone 1 "Main Floor" (sources Digital Music and Radio / Tuner,
volume 25 to 60), Zone 2 "Studio" (sources Digital Music and Bluetooth Audio,
volume 20 to 55, display *Studio Screen*). Each zone has its own room, so the
Studio can be loud while the rest of the building is not.

| Zone       | Block          | Days          | Time        | Source          | Volume | Display |
| ---------- | -------------- | ------------- | ----------- | --------------- | ------ | ------- |
| Main Floor | Open           | Every day     | 06:00-21:00 | Radio / Tuner   | 40     | Leave   |
| Studio     | Spin class     | Mon, Wed, Fri | 18:00-19:00 | Bluetooth Audio | 48     | On      |
| Studio     | Studio ambient | Mon-Fri       | 07:00-17:00 | Digital Music   | 30     | Off     |

Bluetooth Audio is the instructor's phone. The instructor connects it before the
class, the block selects it at 18:00 and sets the volume, and at 19:00 the
studio screen goes off. Blocks in different zones never conflict, because each
zone has its own list.

### Example 5: A community hall that is hired out

**The situation.** A hall used for regular classes and the occasional private
hire. The caretaker needs to start the sound for a booking without understanding
the system.

**Dealer setup:** Zone "Main Hall", sources *Digital Music* and *Bluetooth
Audio*, volume 10 to 50, display *Stage Screen*.

The weekly blocks cover the classes. For a wedding, the caretaker opens **Today
only**, adds "Reception" (Bluetooth Audio, volume 40, display On, 17:00-23:30),
and later in the evening, if the guests want it quieter, taps the block and
**Run now** on a quieter one they prepared. If the evening ends early, **Skip
next block** stops the next scheduled block from running once. The system also
fits a Control4 button: a keypad button programmed to *Run Block Now*
"Reception" gives the caretaker a physical button to press.

## Setting it up (the dealer)

<!-- walkthrough: Set up a zone -->

1. Add the **Daypart Scheduler** driver to the project and wait for **License
   Status** to show the licence. The driver must be added together with a paired
   SmartBuildOS Agent.
1. Set **Manager PIN**. Without a PIN the page is read-only. Five wrong PINs
   lock editing for a minute (the action *Reset PIN Lock* clears it).
1. For zone 1, type a **Zone 1 Name** (the name staff see) and pick **Zone 1
   Room**. The lists read `Name (Room) · id`. If a list looks empty, run the
   action *Refresh Device Lists*. Type a few letters in **Device List Filter**
   to shorten the source and display lists.
1. Pick the allowed sources in **Zone 1 Source 1** to **Source 4**, then **Zone
   1 Min Volume** and **Max Volume**, and up to two **Zone 1 Display** devices.
1. Set **Volume Ramp Seconds**, **End Behaviour** and, for Fade Out, **Fade Out
   Seconds**.
1. Repeat for zones 2 to 4 if needed. A zone with no name or no room is not
   used.
1. Put the **Daypart Scheduler** tile on the Navigators staff use. In Composer's
   Navigator tab it may not appear in the "Device Visibility" list; that list is
   not the one that matters here, the tile shows in the Control4 app. The page
   address appears under **App Data Relay** (run *Print Page Link* to print the
   full address, with its key, into Composer's Lua tab). If the tile does not
   load on a touch screen, set **App Relay Address** to the controller's
   address.

**Tips from the bench**

- After you delete a Daypart driver and add a new one, the controller may keep
  the old one's network port busy until it restarts. If the page says "Could not
  connect to the server", restart the controller.
- Run *Pause Schedule* before you enter a new schedule on a live site, so that a
  block that is "due now" does not start playing while you are still setting up.
- Test the sources before you hand the page over. Pick each source on the room
  once, and set the volume range so that the lowest value is audible and the
  highest is acceptable to the owner.

## Using the page (the manager)

Open the Daypart Scheduler tile. Pick a zone. The card at the top says what is
playing now and what comes next. When the schedule is paused it says so: it
shows what *would* be playing and that nothing is being sent to the room.

- **Weekly** shows Monday to Sunday as a grid. Tap a block to change it, or
  **Add block**. The list under the grid shows the same blocks with larger
  targets, for a phone.
- **Holidays** lists the holiday dates and the holiday blocks. On a holiday date
  only the holiday blocks run.
- **Today only** shows the blocks for today. They vanish after today. *Clear
  today's override* puts the week back.
- **Skip** skips the next block in this zone, once.
- **Pause** stops all block actions until you press **Resume**. The room stays
  as it is.
- In a block, **Run now** starts it at once. It holds until the schedule moves
  on from what it replaced.

<!-- walkthrough: Add a block -->

1. Tap **Add block**.
1. Type a name, pick the days, and set the start and end times (five-minute
   steps).
1. Pick a source (or "music off"), set the volume, and choose what to do with
   the displays.
1. Tap **Save**. The first change asks for the Manager PIN. The page keeps it
   only until the page is closed.

A block that cannot be saved says why in the form. An overlap names the block it
overlaps and the day. A volume outside the zone's range is brought back inside
it.

Changing the block that is running right now takes effect right away (a new
volume or source is applied, with the same ramp).

## Programming it from Composer

Everything the page can do, Control4 programming can use too.

### Events

| Event                               | When                                                                |
| ----------------------------------- | ------------------------------------------------------------------- |
| Block Started                       | A block started in a zone. `EVENT_ZONE` and `EVENT_BLOCK` say which |
| Block Ended                         | A block ended in a zone. Same variables                             |
| Schedule Paused / Schedule Resumed  | The schedule was paused or resumed                                  |
| Schedule Edited                     | Someone changed the schedule on the page                            |
| Schedule Halted / Schedule Restored | The licence halted the schedule, or it is running again             |

### Commands (actions)

| Command         | Parameters      | What it does                                                |
| --------------- | --------------- | ----------------------------------------------------------- |
| Run Block Now   | `ZONE`, `BLOCK` | Runs the named block now (zone by name or number)           |
| Pause Schedule  |                 | Stops all block actions                                     |
| Resume Schedule |                 | Resumes, and picks up the block that should be running      |
| Skip Next Block | `ZONE`          | Skips the next block in a zone (empty or `ALL`: every zone) |
| Reload          |                 | Re-reads the zone properties and device lists               |

### Conditionals

- **Schedule is paused** (true when paused or halted).
- **Zone has an active block**: type the zone name; `=` means it has one, `!=`
  means it has none.

### Variables

`CURRENT_BLOCK_1` to `CURRENT_BLOCK_4` (the running block's name, empty when
none), `NEXT_BLOCK_1` to `NEXT_BLOCK_4`, `NEXT_BLOCK` (the soonest of all),
`SCHEDULE_STATUS`, `EVENT_ZONE`, `EVENT_BLOCK`.

### Recipes

**Dim the lights for happy hour.** In Composer, programming on the Daypart
driver: *When* **Block Started**, *If* `EVENT_BLOCK` equals "Happy hour", *Then*
recall the lighting scene "Dim" in the dining room. The music and the lights now
change together, and the manager only has to manage one schedule.

**Close the blinds on game night.** *When* **Block Started**, *If* `EVENT_BLOCK`
equals "Game night", *Then* close the shades in the room.

**A button on the wall.** Program a keypad button: *Then* **Run Block Now**,
`ZONE` "Dining Room", `BLOCK` "Game night". A server can start the match without
opening the page.

**Quiet for a private event.** Program a button: *Then* **Skip Next Block**,
`ZONE` "Dining Room". The next scheduled block is skipped once; the schedule
carries on afterwards.

**Do something only when the room is playing.** *If* **Zone has an active
block**, zone "Dining Room", `=`. Use it to stop a security routine switching
the room off during opening hours.

**Pause during a fire alarm.** Program the alarm: *Then* **Pause Schedule**.
When the alarm clears: **Resume Schedule**. The room picks up the block that
should be running now.

## What happens when

- **Controller restart in the middle of a block.** The driver works out which
  block should be running now. If it was already running it carries on without
  sending the source again, and without announcing it. If the volume was still
  ramping it continues from the level the room is at. If a block started or
  ended while the controller was down, the change happens now, with the ramp.
- **No blast.** A room that was off, or whose level cannot be read, comes up
  from the zone's minimum volume, not from the level it last played at. A
  block's volume is clamped to the zone's range again when it runs, so a range
  narrowed later is honoured.
- **Clock and daylight saving.** Blocks follow the wall clock. A block that
  starts in the hour that does not exist (02:30 on a spring-forward night)
  starts when the clock passes that time. In the repeated hour of a fall-back
  night a block starts once and ends once. If the controller's clock is changed,
  or the controller stalls, the schedule re-reads the time within about ten
  seconds and puts the room right.
- **Overlaps.** Refused when saved, never at run time. If two blocks are ever
  live at once (a block running past midnight and the next day's own first
  block), the one that started later wins.
- **Skipped block.** If the skipped block was meant to follow another one, the
  first block's end becomes a gap and the end behaviour applies.
- **Paused.** No block action is sent. The page keeps working and shows what
  would be running.
- **Flight Recorder.** Block starts, ends and every schedule edit (what changed,
  from where, never the PIN) are written to the Flight Recorder when the project
  has one. Without it nothing is lost; the page shows the last edit under **Last
  Edit** in the driver properties.

## Licensing

The SmartBuildOS Agent is the licensing authority. **License Status** shows this
driver's standing. A definitive licence denial with enforcement on **halts** the
schedule: no more block actions are sent, the page stays readable and read-only,
and nothing is deleted. Only a definitive denial does this. A missing Agent, an
Agent that has not answered yet or a cloud that cannot be reached leave the
schedule running.

## Troubleshooting

| What you see                                                         | Likely cause and fix                                                                                                                                                            |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The page says "Could not connect to the server"                      | The driver's relay is not listening. Check **App Data Relay** in the properties. If you replaced a Daypart driver, the old one may still hold the port: restart the controller. |
| The page opens but says "The controller did not return the schedule" | The page loaded but the relay did not answer. Run *Print Page Link* and open the printed address from a computer.                                                               |
| The tile is not in Composer's Navigator "Device Visibility" list     | That list does not show it. Check the Control4 app instead; the tile appears there.                                                                                             |
| The page is read-only                                                | No Manager PIN is set, or the schedule is halted by licensing.                                                                                                                  |
| "Too many wrong PINs"                                                | Wait a minute, or run *Reset PIN Lock*.                                                                                                                                         |
| A source or display is missing from the lists                        | Run *Refresh Device Lists*. Check **Device List Filter**.                                                                                                                       |
| A block did nothing                                                  | Check **Schedule Status**. The schedule may be paused. Run *Print Schedule* to see the next block.                                                                              |
| The volume is lower than the block says                              | It was clamped to the zone's minimum and maximum. Change the limits in the properties.                                                                                          |
| A block started late after a restart                                 | The driver caught up on the next check, within about ten seconds.                                                                                                               |

## Reference

### Properties

| Property                                                    | Meaning                                                    |
| ----------------------------------------------------------- | ---------------------------------------------------------- |
| Schedule Status, Zones, Next Block, Last Edit, Last Refusal | What the schedule is doing                                 |
| Manager PIN                                                 | Needed on the page for every change; empty means read-only |
| Volume Ramp Seconds                                         | 0 to 600; 0 sets the level at once                         |
| End Behaviour, Fade Out Seconds                             | Hold, Fade Out (to silence, then room off) or Off          |
| Zone N Name, Room, Source 1-4, Min/Max Volume, Display 1-2  | The dealer's limits, four zones                            |
| Device List Filter                                          | Narrows the source and display lists                       |
| App Relay Address                                           | Leave on `Auto` unless the tile does not load              |

### Limits

| What                                   | Limit         |
| -------------------------------------- | ------------- |
| Zones                                  | 4             |
| Sources per zone                       | 4             |
| Displays per zone                      | 2             |
| Blocks per list (week, holiday, today) | 40            |
| Holiday dates                          | 60            |
| Block name                             | 40 characters |

- Times are to the minute (the page offers five-minute steps).
- A holiday applies to every zone at once; each zone has its own holiday blocks.
- There is one "today only" set per zone and it lasts until the end of the day.
- A zone controls one room. A display is switched with plain `ON` and `OFF`.
- Remote schedule backup and editing through the SmartBuildOS Agent are not
  built yet.

## What has been verified, and what has not

**Seen working on a real controller (SmartBuildOS test bench, November 2026):**
the page loading in the Control4 app, the restaurant schedule entering and
displaying, overlap, wrong-source and wrong-PIN refusals, the volume clamp,
blocks starting on their own at their start time, a ramp stepping on schedule,
the commands sent to the room, and the schedule pausing and resuming.

**Not yet confirmed:** how a real room responds to the commands (a real source
switching, the volume moving, a television turning on and off through its
proxy), the Control4 Navigator on a phone, restart and daylight-saving behaviour
with real controller clocks (covered by automated tests with a simulated clock),
the Flight Recorder markers in its history, and a licence halt with a real
Agent. Screenshots of the page are still to be added to this manual.

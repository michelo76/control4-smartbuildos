# SmartBuildOS Commissioning Matrix

The Commissioning Matrix is a guided test run for the end of an install. It
builds a list of what should be tested, room by room, from the project. A
technician works through it from a phone. For each item the driver does the
thing (ramps a light to full and back, moves a shade, routes a source into a
room at low volume), reads back what the device reports, and then the
technician taps **Pass**, **Fail** or **Skip**, with a note if wanted. Sensors
go the other way round: the page says "trigger the sensor" and the item passes
by itself when the sensor reports a change. When every item has a verdict the
technician signs off, and the driver keeps the run, with a time for each
item, who signed, and the values each device reported. The Agent can take
that record to Property Studio as the as-built record.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system. The Agent is the licensing authority (SKU `SBOS_COMMISSIONING`):
**License Status** shows this driver's standing. A definitive licence denial
with enforcement on makes the driver **read-only**: no run can start or
change, and everything already recorded stays readable. Only a definitive
denial does this. A missing Agent, an Agent that has not answered yet or a
cloud that cannot be reached leave the driver working.

## What it can and cannot tell you

Read this before you promise a client anything.

- **The driver confirms what the device reports, not what happened in the
  room.** If a light reports 100% it may still have a dead lamp. That is why
  every item ends with a person's tap: **Pass** means the technician saw the
  lamp light, the shade move, or heard the source.
- **A readback that disagrees is shown, not hidden.** If a light is asked for
  100% and reports 40%, the page says so in red. The technician can still
  pass it (the record then says "passed despite mismatch") or fail it.
- **Signal health is not measured.** A device that answers once may still be
  a weak link on the Zigbee mesh. The driver does not look at mesh quality and
  the record does not claim anything about it.
- A device that reports nothing the driver can read is marked
  `unreported`. It is not a failure and not a pass: the technician judges it.

## Setup

<!-- walkthrough: Set up the Commissioning Matrix -->
1. Install and pair the SmartBuildOS Agent from Composer's Agents tab.
1. Add this driver (one per project; a Utility room is fine). **Driver
   Status** reads `Online` and **Run Status** reads `idle`.
1. Read **License Status**. The driver asks the Agent by itself until it
   answers; the action *Register With Agent Now* asks at once.
1. Read **Test List**: it says how many items in how many rooms the driver
   found. Lights, shades, sensors and (when an **AV Test Source** is set) AV
   zones that sit in a room are included automatically.
1. Optionally add what the driver missed (next section), and choose the
   **AV Test Source**.
1. Copy **Technician Page** into the technician's phone browser, or add it to
   a Navigator web view. The phone must be on the same network as the
   controller.

## What goes on the list

| Kind | Found from | What the driver does to it |
| --- | --- | --- |
| Light | Dimmers and switches (a driver file with "light" or "dimmer" as a word) | Ramps to 100% over a second, reads the level, ramps back to the level it had, reads again |
| Shade | Blind and shade drivers | Moves to the end it is not at, reads the position, moves back, reads again. Waits four times as long as a light |
| AV zone | Room devices, only when **AV Test Source** is set | Selects the test source in the room at a low volume (**AV Test Volume**), reads the selected source, then returns the room to what it was or turns it off |
| Sensor | Contact, motion and occupancy drivers | Nothing is sent. The page says to trigger it; it passes when its state variable changes |

A device with no room goes under **Unassigned**. The driver never lists
itself.

### Adding an item by hand

1. Choose **Add Item As** (`Light`, `Shade`, `AV zone`, `Sensor`, or
   `Auto-detect` to let the driver decide from the device's driver file).
1. Pick the device in **Add Item**. Each entry reads `Name (Room) · id`. The
   property goes back to `-` and the item is on the list.
1. If a device was added to the project after the driver started, run the
   action *Refresh Device Lists* first.

*Clear Manual Items* removes every item added by hand. Items you add stay
across a restart. The list is never rebuilt while a run is in progress; it
refreshes when the run ends.

## The technician's walkthrough

<!-- walkthrough: Run a room -->
1. Open the **Technician Page**. Type your name and either **Start run, all
   rooms**, or tap one room to test only that room.
1. Pick a room from the strip at the top. Each room shows how many items are
   still open, and a tick when all are done.
1. Tap **Test** on an item. The driver acts, waits **Settle Seconds**
   (4 by default), reads the device back, restores it, and reads again. The
   card then shows what the device reported.
1. Look at the room. Tap **Pass** if the lamp lit, the shade moved or you
   heard the source; **Fail** if not; **Skip** if it cannot be tested now.
   Add a note first if you want one. **Test again** repeats the item.
1. For a sensor, tap **Test** and then trigger it (open the door, walk past).
   It passes by itself. If it never reports, **Fail** or **Skip** it.
1. When every item has a verdict, **Sign off** appears. Type your name and
   tap it. The run is stored and offered to the Agent.

If the controller restarts in the middle of a run, the run comes back as it
was, except that an item that was being tested goes back to "not tested".
**Abort this run** closes the run and keeps what was recorded, marked as
aborted.

## Programming surface

Everything a dealer programs is in the Composer programming window, not in
the properties.

### Events

| Event | Fires when | Read |
| --- | --- | --- |
| *Room Passed* | Every item in a room has a verdict, none failed, at least one passed | `LAST_PASSED_ROOM` |
| *Item Failed* | A technician marks an item failed | `LAST_FAILED_ITEM` (`Name (Room)`) |
| *Run Completed* | A technician signs a run off | `PASSED_COUNT`, `FAILED_COUNT`, `SKIPPED_COUNT` |

The variables are set before the event fires, so a script on the event can
read them. A run that ends with failures still fires *Run Completed*: use the
conditional below to tell the cases apart.

### Commands and actions

| Command | Parameters | What it does |
| --- | --- | --- |
| `START_RUN` | `TECHNICIAN` (optional) | Starts a run over every room. Same as the action *Start Run* |
| `START_ROOM` | `ROOM`, `TECHNICIAN` (optional) | Starts a run over one room, or picks that room inside the run in progress |
| `ABORT_RUN` | | Aborts the run in progress. Same as the action *Abort Run* |
| `PRINT_RESULTS` | | Prints the current run, or the last signed-off run, to the Lua tab |

Other actions on the Actions tab: *Print Test List*, *Rebuild Test List*,
*Refresh Device Lists*, *Clear Manual Items*, *New Page Link* (makes the old
page link stop working), *Register With Agent Now* and *Refresh Status*.

### Conditional

*Commissioning run has failures* is true while the current run, signed off or
not, has at least one failed item. It is false when there is no run.

### Variables

All are read-only.

| Variable | Holds |
| --- | --- |
| `RUN_STATUS` | `idle`, `running`, `complete` (everything judged, waiting for sign-off), `signed_off`, `aborted` or `read-only (licence)` |
| `CURRENT_ROOM` | The room being worked on, or empty |
| `PASSED_COUNT`, `FAILED_COUNT`, `SKIPPED_COUNT` | Items in the current run with each verdict |
| `OPEN_COUNT` | Items with no verdict yet |
| `LAST_FAILED_ITEM`, `LAST_PASSED_ROOM` | The last item failed and the last room passed |

## The record

A signed-off run is stored on the controller (the last five runs are kept) and
offered to the Agent as JSON. It holds, for the run: an id, the start and
finish time, the technician, who signed off, the counts, and then for each
room and item: its verdict, when it was tested and judged, how many attempts,
what the device reported while it was tested, whether that agreed with what
was asked (`match`, `mismatch` or `unreported`), the note, and whether a
sensor passed on its own. Times are UTC.

The record says in plain words that readback is what each device reported,
that a pass is the technician's confirmation, and that radio signal health is
not measured.

When a Flight Recorder driver is in the project, the driver also writes a
marker to its history for the start of a run, each verdict, each room passed,
the sign-off and an abort, on the channel `commissioning`. With no Flight
Recorder nothing is lost: the run record above is the source of truth.

## Properties

| Property | What it shows or sets |
| --- | --- |
| **Driver Status**, **Driver Version** | State of the driver |
| **Run Status**, **Run Summary** | `idle` to `signed_off`, and passed, failed, skipped, open |
| **Test List** | Items and rooms found |
| **Technician Page** | The link to open on the phone |
| **Last Result** | The last signed-off run |
| **Last Refusal** | The last command the driver did not accept, with the reason |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | Licensing, from the Agent |
| **Technician Name** | Who signs off when the page does not ask |
| **Add Item**, **Add Item As** | Add a device to the list by hand |
| **AV Test Source**, **AV Test Volume** | The source to route into each room, and the volume (1 to 40, default 15) |
| **Settle Seconds** | Wait between acting and reading back (1 to 30, default 4) |
| **App Relay Address** | `Auto`, or the controller address the page is served on |
| **Log Level**, **Log Mode** | Diagnostics |

## Limits

| What | Limit |
| --- | --- |
| Note on an item | 300 characters |
| Runs kept | The last 5 |
| Settle time | 1 to 30 seconds (shades four times that) |
| Run in progress | One at a time |

## Unverified on a controller

None of this driver has run on a real controller yet. It has been checked only
by automated tests against a pretend project. In particular:

- The command names sent to lights (`RAMP_TO_LEVEL`) and shades
  (`SET_LEVEL_TARGET`) are the ones the Mode Composer uses; the AV commands
  (`SELECT_AUDIO_DEVICE`, `SET_VOLUME_LEVEL`, `ROOM_OFF`) are documented
  Control4 commands that have not been tried here.
- The variable names read back from lights, shades, AV rooms and sensors are
  best known names. A device that uses other names shows `unreported`.
- Which driver files count as lights, shades, rooms and sensors is a guess
  from file names. A device the guess misses can be added by hand.
- Whether Director delivers a sensor's variable change to the driver while the
  run is open.
- Whether the Flight Recorder shows the `commissioning` markers as expected.
- The phone page, on a real phone and on a Navigator web view.
- The Agent side of the record (see the design note): the driver sends it, but
  the Agent and Property Studio do not accept it yet.

## What is not claimed

- A pass is a person's word; the driver cannot see a room.
- Radio signal strength and mesh health are not tested.
- Nothing is sent outside the controller except the record offered to the
  Agent on the same controller, and the page is served on the local network
  only, behind a link only the dealer sees.
- Anyone with the page link can run and sign off tests. *New Page Link*
  revokes the old link.

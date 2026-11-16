# SmartBuildOS Mode Composer

Mode Composer keeps track of the mode the house is in and makes the house
match it. You define each mode once (Home, Away, Vacation, Sleep, Movie, or
your own): which lights, shades, thermostats, fans, locks, garage doors, rooms
and security panel it sets, and to what. A keypad button, a Navigator button, a
schedule or one line of programming then switches the house to that mode. The
driver sends the commands, lights the keypad LED in the mode's colour, records
who asked, and tells programming through events and variables.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system. The Agent is the licensing authority (SKU `SBOS_MODE_COMPOSER`):
**License Status** shows this driver's standing. Add one Mode Composer per
project; it needs Control4 OS 3.3.2 or newer. If the licence is refused
outright and SmartBuildOS has switched enforcement on for this driver, changes
to the configuration are refused (the Lua tab says `Refused: …`). The modes
already configured keep working from keypads, buttons, schedules and
programming.

Modes appear in Navigator through the companion driver SmartBuildOS Mode
Button: one instance per mode you want on screen. It only shows a mode and
passes the tap on; everything is decided here.

## Why not a variable and a set of scripts per mode

The stock way is a variable such as "House Mode", one script per mode on each
button that should set it, and more programming to drive the LEDs. That works,
and for a small job it is still the right tool:

- **Two modes and a handful of devices.** A variable and two scripts are
  quicker to write, and every technician knows to look for them in Programming.
- **Anything conditional.** A mode here is a fixed list of device settings.
  "Off, unless it is after sunset" is a script.
- **Lighting looks.** An Advanced Lighting Scene is the tool for a lighting
  scene. A mode can sit beside it: run the scene from the mode's event.
- **Devices this driver does not handle.** It sets lights, shades, thermostats,
  fans, locks, garage doors, security panels and room media. Anything else is
  programmed on the mode's event, as before.

What the scripts do not give you, and this driver does:

- **One place that says what a mode does.** *Print Devices In Selected Mode*
  lists every device and its setting. *Dry Run Selected Mode* shows what would
  be sent without sending it.
- **Capture instead of typing.** Set the house the way the mode should leave it
  and capture it, in place of one script line per light.
- **Inheritance.** Vacation is "Away, plus a deeper setback". Change a light in
  Away once and Vacation follows.
- **Two layers.** Movie on top of Home, with the lights put back when the movie
  ends, without a second variable and a pile of "previous level" variables.
- **Gestures on one button.** Tap, double tap, triple tap and three lengths of
  hold are told apart by the driver from the button's press and release.
- **An LED that follows the mode**, a departure countdown that a second press
  cancels, a check that the garage is closed before Away runs, and a history of
  who or what changed the mode.

Keep in mind what it costs: the configuration lives in this driver, not in the
Programming tree. Whoever services the job next has to know to look here.

## What it is for

| You want | Use |
| --- | --- |
| One button that puts the house in Away: lights off, shades closed, doors locked, thermostat set back | A Presence mode with its devices, and a keypad slot with **Slot Hold** set to `Activate: Away` |
| Time to get out of the door first | **Departure Countdown Seconds** |
| The button's LED to show the mode the house is in | **Slot LED Follows** set to `Global Presence Mode` |
| Several modes on one button | **Slot Tap**, **Slot Double Tap**, **Slot Triple Tap**, **Slot Hold** |
| Vacation as "Away, with these differences" | **Mode Inherits From** |
| Movie or Sleep on top of Home, ending by itself and putting lights back | A Lifestyle mode, devices set to `restore`, **Mode Duration Minutes** |
| A mode on the touchscreens and in the Control4 app | SmartBuildOS Mode Button |
| A mode at a fixed time, only while someone is home | `Set Mode Schedule` with `REQUIRED_MODE` |
| Away refused while the garage is open | `Add Preflight Check` with `POLICY` `BLOCK` |
| Your own programming when a mode starts | The event *Away Activated* (one per mode), or *Presence Mode Changed* |
| Programming that depends on the mode | `CURRENT_PRESENCE_MODE`, `CURRENT_LIFESTYLE_MODE` |
| To know why the house changed mode | *Print History*, *Print Last Activation Detail* |

## Setup

<!-- walkthrough: Set up Mode Composer -->
1. Install and pair the SmartBuildOS Agent, then add this driver, one per
   project. **Driver Status** reads `Online` and **License Status** shows the
   licence.
1. Create a mode. Set **New Mode Type**, type a **New Mode Name** if you want a
   different name, and run *Create Mode* on the Actions tab. The new mode
   becomes the **Selected Mode**; the properties below it now edit that mode.
1. Put devices in it. The quick way: set the house exactly as the mode should
   leave it, then run *Capture Current State Into Selected Mode*. The precise
   way is one device at a time; see
   [Putting devices in a mode](#putting-devices-in-a-mode).
1. Check it. *Print Devices In Selected Mode* lists what the mode holds.
   *Dry Run Selected Mode* prints what would be sent and sends nothing.
   *Test Selected Mode* sends it for real and the house enters the mode.
1. Give it a button. In Connections, bind a keypad button's Button Link to
   `Keypad Slot 1`. Back on Properties, choose the slot in
   **Selected Keypad Slot**, set **Slot Tap** or **Slot Hold** to `Activate:`
   and the mode, and set **Slot LED Follows**.
1. Create a Home mode as well and activate it once (*Activate Selected Mode*).
   Until a Presence mode has been activated, **Presence Mode** and
   `CURRENT_PRESENCE_MODE` are empty.
1. For Navigator, add one SmartBuildOS Mode Button per mode and pick the mode
   in its **Mode** property.

## Modes

### Presence and Lifestyle

| | Presence mode | Lifestyle mode |
| --- | --- | --- |
| Says | who is in the house | what the house is doing |
| Examples | Home, Away, Vacation | Sleep, Movie, Party, Morning, Night |
| Active at once | exactly one, once the first has been activated | one or none, on top of the Presence mode |
| Activating another | replaces it | replaces it, and the outgoing mode's `restore` devices are put back |
| Ending it | only by activating another Presence mode | `Deactivate Lifestyle Mode`, its Mode Button, or **Mode Duration Minutes** |

Changing the Presence mode does not end a Lifestyle mode. If Movie is active
when the house goes to Away, Movie is still the Lifestyle mode, and ending it
later puts its `restore` devices back to how they were before the movie.

### Mode types

**New Mode Type** gives a new mode a name, a colour, an icon for the Mode
Button and the few settings below. It never chooses devices, and nothing in the
driver behaves differently because a mode is called Away.

| Type | Kind | Colour | **Mode Priority** | Also set |
| --- | --- | --- | --- | --- |
| Home | Presence | Green | 50 | counts as occupied |
| Away | Presence | Blue | 50 | counts as unoccupied |
| Vacation | Presence | Purple | 60 | counts as unoccupied; **Hold To Confirm Seconds** 3 |
| Sleep | Lifestyle | Amber | 30 | |
| Movie | Lifestyle | Deep Blue | 30 | |
| Party | Lifestyle | Magenta | 30 | |
| Morning, Night | Lifestyle | their own | 30 | |
| Custom Lifestyle | Lifestyle | grey | 30 | named `Custom` unless you type a name |
| Custom Presence | Presence | grey | 50 | occupancy unknown; named `Custom` unless you type a name |

Morning, Night and custom modes start with a colour that is not in the
**Mode Color** list, so the property shows `Blue` until you choose one. Commas
in a name are replaced by spaces. There is no rename: choose the name when you
create the mode.

### Putting devices in a mode

**Capture.** *Capture Current State Into Selected Mode* reads every light,
shade, thermostat, fan, lock and garage door the driver recognises and stores
its state as the mode's setting, replacing what the mode held for those
devices. The Lua tab shows the count per kind and how many could not be read.
Security panels are never captured. A lock that was unlocked is stored as
Locked. Rooms (media) are not captured; use `Include All Media Rooms`.

**One device at a time.** The commands below are used as setup tools. In
Programming, select this driver in the actions pane, choose the command, fill
it in, drag it into any script and press Execute; then delete the line. The
setting is stored in the mode, not in the script.

- `Include Device In Mode`: type the mode's `NAME`, pick the `DEVICE`, type the
  `SETTING`. Including a device again replaces its setting and keeps its delay,
  criticality and sensitive-action approval.
- `Include All Lights` (default `off`), `Include All Shades` (default
  `closed`), `Include All Media Rooms` (every room, media off). Run these
  first, then adjust single devices.
- `Exclude Device From Mode` removes a device from this mode. It does not
  remove one that comes from a parent mode; use the setting `ignore` for that.

| Device | `SETTING` |
| --- | --- |
| Light | `off`, `on`, a level such as `38%` |
| Shade | `open`, `closed`, a level such as `40%` (0 is closed) |
| Thermostat | `cool 76`, `heat 68`, `auto`, `off`. Setpoints are °F and must be 50 to 90 |
| Fan | `off`, `on`, `speed 2` |
| Lock | `locked`; `unlocked` needs `Allow Sensitive Action` |
| Garage door | `closed`; `open` needs `Allow Sensitive Action` |
| Security panel | `arm away`, `arm stay` (the word after `arm` is sent as the arm type); `disarm` needs `Allow Sensitive Action` and the **Security User Code** |
| Any of these | `ignore`: leave it alone, even if a parent mode sets it |
| Light, shade, thermostat, fan | `restore`: send nothing now, read its state, and put it back when the mode ends |

A device the driver cannot place is refused with a line that says it is not a
device type Mode Composer can control. Program it on the mode's event instead.

Two more per-device settings, for devices included directly in that mode:

- `Set Device Delay` (`SECONDS`, 0 to 3600): send this device's command that
  long after the rest of the mode has been sent. "Foyer light off after 90
  seconds."
- `Set Device Criticality` (`OPTIONAL`, `NORMAL`, `CRITICAL`): what a failure
  to send means. See the next section. Every device starts as `NORMAL`.

### What happens when a mode is activated

1. A disabled mode, or a name that does not exist, is refused. A mode that is
   already active does nothing at all: no commands, no events. Use
   `Reapply Mode` to send it again.
1. If the mode has a **Departure Countdown Seconds**, the countdown starts:
   *Departure Countdown Started* fires, `TRANSITIONING` is true and following
   LEDs blink. Nothing is sent yet.
1. The mode's preflight checks run. A failed check with `POLICY` `BLOCK` stops
   here: *Activation Blocked* fires and the house stays as it was.
1. Devices set to `restore` are read, so they can be put back later.
1. *Activation Started* fires. The commands go out one at a time, 50 ms apart
   unless you change **Inter-Command Delay ms**, in the order the
   **Transition Style** gives.
1. When the last one has gone, the mode becomes the active one.
   *Presence Mode Changed* or *Lifestyle Mode Changed* fires, then the mode's
   own event such as *Away Activated*, then *Activation Completed*. Devices
   with a delay follow, counted from this moment.

"Sent" means handed to the device's driver. The driver does not read the device
back to see that it obeyed, and it does not watch for manual changes afterwards.

| Result | When | Event | Mode changes |
| --- | --- | --- | --- |
| `SUCCESS` | every command was sent, or only `OPTIONAL` ones could not be | *Activation Completed* | yes |
| `SUCCESS_WITH_WARNINGS` | a `NORMAL` command could not be sent | *Activation Warning* | yes |
| `FAILED` | a `CRITICAL` command could not be sent; the rest are skipped, delayed ones included | *Activation Failed* | no |
| `BLOCKED` | a preflight check with `BLOCK` failed | *Activation Blocked* | no |

A device that has left the project, a setting the device cannot take (a 45°F
setpoint), and an unlock that was never allowed are skipped without counting as
a failure. *Dry Run Selected Mode* names each one as `MISSING` or `SKIP`.

### Transition styles

| **Transition Style** | What it does |
| --- | --- |
| `Immediate` | All commands in one paced run |
| `Graceful` | The same, with lights ramped over 3 seconds |
| `Sequenced` | By kind of device, each kind starting 2 seconds after the one before: media at 0 s, lights 2 s, shades 4 s, fans 6 s, garage doors 10 s, locks 12 s, thermostats 14 s, security 16 s. A kind the mode does not use still keeps its place |

### Who wins: conflicts and priorities

- **A person always wins.** A keypad, a Mode Button, an action or a programming
  command replaces the active mode whatever the priorities are.
- **A schedule or a sensor rule yields to a higher priority.** It cannot
  replace an active mode of the same kind whose **Mode Priority** is higher
  than its own. Equal priority replaces. This is why Vacation starts at 60: a
  scheduled Home (50) is refused while Vacation is active. A refused automatic
  request is silent: nothing is printed and the history gets no line.
  **Mode Priority** is shown when **Advanced Settings** is `Show`.
- Priorities are compared within a kind. A Presence mode never blocks a
  Lifestyle mode, or the reverse.
- **During a countdown**, an automatic request is refused. A manual request
  replaces the countdown: *Departure Countdown Cancelled* fires and the new
  request runs.

### Inheritance

Set **Mode Inherits From** and the mode receives every device setting of its
parent, then applies its own on top, device by device. A change to the parent
reaches the child at once. Only a mode of the same kind can be a parent, and a
loop is refused.

| Inherited from the parent | The mode's own |
| --- | --- |
| Device settings, unless the mode sets or ignores that device | **Transition Style** |
| Preflight checks | **Mode Color**, **Mode Priority**, **Mode Enabled** |
| **Departure Countdown Seconds**, when the mode's own is 0 | **Hold To Confirm Seconds**, **Mode Duration Minutes**, schedules |

**Devices In Selected Mode** shows both counts, for example
`1 set here + 26 inherited`. Deleting a parent hands its children to its own
parent, if it has one. *Duplicate Selected Mode* makes a separate copy with
` Copy` added to the name; keypads and children stay with the original.

## Keypads

A keypad slot is a connection. Two exist after install; *Add Keypad Slot* adds
more, up to 30. In Connections, bind a keypad button's Button Link to the slot.
Then choose the slot in **Selected Keypad Slot** and give its gestures an
action: `Activate:` and a mode, `Deactivate Lifestyle`,
`Restore Previous Presence` or `Cancel Transition`.

| Gesture | Fires |
| --- | --- |
| **Slot Tap** | at once, when no double or triple tap is assigned on that slot; otherwise after the **Double Tap Window ms** (500) has passed with no further tap |
| **Slot Double Tap** | on the second tap, or after the window when a triple tap is assigned |
| **Slot Triple Tap** | on the third tap |
| **Slot Hold** | at **Hold Seconds** (1), while the button is still down, when it is the only hold assigned |
| **Slot Long Hold**, **Slot Very Long Hold** | at **Long Hold Seconds** (3) and **Very Long Hold Seconds** (5). With more than one hold assigned, nothing fires until release, then the longest one reached |

A button released before the first hold time counts as a tap, if a tap is
assigned. A button that never reports its release is given up on after 30
seconds. A press for the mode that is counting down cancels the countdown. The
timing properties apply to every slot and are shown when
**Advanced Settings** is `Show`.

**LED.** **Slot LED Follows** decides what the button's LED shows:

| **Slot LED Follows** | The LED |
| --- | --- |
| `None` | is left to the keypad |
| `Global Presence Mode` | is lit in the colour of the active Presence mode: green for Home, blue for Away, purple for Vacation with the starting colours. During a countdown to another Presence mode it blinks in that mode's colour |
| a mode | is lit in that mode's colour while it is active, dim otherwise, and blinks while it counts down or while the button is held |

Change **Mode Color** and every button following that mode repaints. A request
from a keypad that ends in `FAILED` blinks that button red for ten seconds; one
that ends with warnings shows amber. LED trouble never stops a mode.

## Navigator buttons

Add one SmartBuildOS Mode Button per mode, place it in a room's Navigator, and
choose the mode in its **Mode** property. It finds this driver by itself, takes
the mode's name and icon from it, and lights while the mode is active or
counting down. The button has its own manual.

- A tap activates the mode. A tap on the active Lifestyle mode's button ends
  it.
- **Hold To Confirm Seconds** guards a mode against a stray tap on a screen.
  With any value above 0, the first tap only asks: the Control4 screens are
  sent the message `Tap Vacation again to confirm`, and a second tap within 10
  seconds activates. The number itself is not used as a time in this release.
  Keypads, actions, schedules and programming are not asked.
- A second tap during a countdown starts the countdown again. To cancel from a
  screen, use a keypad gesture, the *Cancel Transition* action or the
  `Cancel Transition` command.

## Schedules

`Set Mode Schedule` activates a mode at a clock time: `NAME`, `TIME` as `HH:MM`
in 24-hour form, `DAYS` (`Every Day`, `Weekdays`, `Weekends`) and an optional
`REQUIRED_MODE`, the Presence mode that must be active for it to run. Each use
adds a schedule; `Clear Mode Schedules` removes all of a mode's schedules.
*Print Selected Mode Detail* lists them.

- The clock is checked every 30 seconds. A schedule whose time passed while the
  controller was restarting still runs once, up to a day late.
- A schedule is an automatic request: it yields to a higher **Mode Priority**
  and does nothing when its mode is already active.
- Read the line the command prints. With a guard it ends in `while Home.`
  If those words are missing, the `REQUIRED_MODE` was not recognised and the
  schedule runs whatever the Presence mode.
- Activating modes by hand in between does not disturb a schedule.
- Times are clock times. There is no sunrise or sunset offset.

## Preflight checks

`Add Preflight Check` makes a mode look before it acts: `DEVICE`, what you
`EXPECT` (`CLOSED` for a contact or garage door, `LOCKED` for a lock, `READY`
for a security panel) and the `POLICY`.

| `POLICY` | A failed check |
| --- | --- |
| `WARN` | is counted in the activation record; the mode runs |
| `BLOCK` | stops the mode: *Activation Blocked* |
| `IGNORE` | is not evaluated |

A device that cannot be read or has left the project only warns. Checks run
after the departure countdown, not before it. A child mode inherits its
parent's checks. There is no command to remove a check: add the same `DEVICE`
and `EXPECT` again with `IGNORE`. *Run Preflight On Selected Mode* shows the
result without activating.

## Sensor rules

> **Not working in this build.** A rule can be created, stored and printed, and
> the rule logic is covered by the driver's tests, but the driver does not yet
> hand the sensors' values to it correctly, so a rule never fires. Until a
> release says otherwise, do the coming-home sequence in programming: see
> [Welcome home from the alarm panel](#welcome-home-from-the-alarm-panel).

What a rule is, for when it does: `Configure Return Home Rule` stores "when
`DOOR` opens and `PANEL` disarms and `MOTION` trips, all within 2 minutes,
while the Presence mode is `REQUIRED_MODE`, activate `TARGET_MODE`". One signal
alone is not enough, a repeat of the same signal within 2 seconds is ignored,
a rule that fired waits 60 seconds, and at most 6 rules fire per minute. A rule
is an automatic request, so it yields to a higher **Mode Priority**.

Other rules are pasted as JSON into **Add Trigger Rule JSON** (shown with
**Advanced Settings**):

```json
{"mode_id": "Home",
 "signals": [{"type": "CONTACT_OPENED", "device_key": "123"},
             {"type": "SECURITY_DISARMED", "device_key": "456"}],
 "conditions": [{"type": "TIME_RANGE", "from": "17:00", "to": "23:00"}],
 "window_s": 120, "cooldown_s": 60}
```

- Signal types: `CONTACT_OPENED`, `CONTACT_CLOSED`, `MOTION`,
  `SECURITY_DISARMED`, `SECURITY_ARMED`, `VARIABLE` (with `variable` and
  `value`). `device_key` is the device's id.
- Condition types: `PRESENCE_IS`, `LIFESTYLE_IS`, `SECURITY_STATE`,
  `SENSOR_OPEN`, `SENSOR_CLOSED`, `TIME_RANGE`, `DAY_OF_WEEK` (1 is Sunday),
  `VARIABLE_EQUALS`.
- The rule's own `mode_id` may be the mode's name. Inside a condition,
  `mode_id` must be the mode's id, which *Print Selected Mode Detail* prints
  after `id=`.

*Print Trigger Rules* lists the rules; *Clear Trigger Rules* removes them all.

## Locks, garage doors and security

Locking, closing and arming are ordinary settings. Unlocking, disarming and
opening a garage door are never sent unless you run `Allow Sensitive Action`
for that device in that mode. No mode type includes them. Capture stores an
unlocked lock as Locked and never reads a panel; a garage door captured open
is stored as open and still needs the approval. Until they are allowed,
*Dry Run Selected Mode* lists them as `SKIP`. Nothing outside the project can
activate a mode: the driver has no network or cloud entry point.

Type the panel's code into **Security User Code** when a mode arms or disarms.
It is stored encrypted on the controller and the field empties itself. The code
is not in the exported configuration, the history or the diagnostic snapshot.

## Worked examples

The figures below come from running the driver against its test project: 20
lights, 5 shades, one door lock and one thermostat.

### Away on a keypad button, with a minute to leave

<!-- walkthrough: Away on a keypad button -->
1. Create the mode: **New Mode Type** `Away`, then *Create Mode*.
1. From Programming, run `Include All Lights` with `NAME` `Away`, then
   `Include All Shades` with `NAME` `Away`. Leave `SETTING` empty: lights go
   `off`, shades `closed`.
1. Run `Include Device In Mode` for the front door lock with `SETTING`
   `locked`, then `Set Device Criticality` for it with `CRITICAL`. Include the
   thermostat with `cool 80`. For the foyer light, run `Set Device Delay` with
   `SECONDS` 90.
1. Set **Departure Countdown Seconds** to 60. **Devices In Selected Mode** now
   begins `27 set here`.
1. Run *Dry Run Selected Mode* and read the Lua tab.
1. Bind the keypad button to `Keypad Slot 1` in Connections. Select the slot,
   set **Slot Hold** to `Activate: Away` and **Slot LED Follows** to
   `Global Presence Mode`.
1. Hold the button for a second.

The dry run prints:

```text
AWAY WOULD:
  Lighting    20 x Off (1 delayed)
  Locks        1 x Locked
  Shades       5 x Closed
  Climate      1 x Cool 80°
  Total actions: 27
```

Holding the button: *Departure Countdown Started* fires, `TRANSITIONING` is
true and the LED blinks blue. Hold the button again within the minute and
*Departure Countdown Cancelled* fires; the house stays in Home. Left alone, the
countdown ends, *Activation Started* fires and 26 commands go out, 50 ms
apart, in about a second and a quarter. Then *Presence Mode Changed*,
*Away Activated* and *Activation Completed* fire, `CURRENT_PRESENCE_MODE` is
`Away`, `PREVIOUS_PRESENCE_MODE` is `Home`, and the LED is steady blue. The
foyer light goes off 90 seconds after that. *Print History* shows:

```text
2026-11-11 02:00:51  Away  SUCCESS  via KEYPAD (Keypad Slot 1), gesture hold
```

If the lock's command could not be sent, the result would be `FAILED`:
*Activation Failed* fires, the button blinks red and the mode stays Home.
Commands that had already gone out are not undone.

### Vacation: Away with a deeper setback

1. Create a mode of type `Vacation`. Set **Mode Inherits From** to `Away`.
1. Run `Include Device In Mode` with `NAME` `Vacation`, the thermostat and
   `cool 84`.

**Devices In Selected Mode** begins `1 set here + 26 inherited`, and the dry
run is Away's with the climate line reading `Cool 84°`. Vacation takes Away's
60-second countdown, because its own is 0, but not Away's
**Transition Style**. Its Mode Button asks for a second tap. While Vacation is
active a scheduled Home is refused, because 50 is lower than 60; a person
pressing Home is not.

### Movie night that puts the lights back

1. Create a mode of type `Movie`. Include the shade with `closed`.
1. Include the two room lights with the setting `restore`.
1. Set **Mode Duration Minutes** to 180.
1. In Programming, on this driver's event *Movie Activated*, add your own
   lighting command, for example ramp those two lights to 10%.

Activating Movie reads the two lights (65% in the test project) before
anything is sent, closes the shade and fires *Lifestyle Mode Changed*,
*Movie Activated* and *Activation Completed*. Your line then dims the lights.
`CURRENT_LIFESTYLE_MODE` is `Movie`; the Presence mode is still Home. After 180
minutes, or when the Movie button is tapped again, the driver sends both lights
back to 65%, and *Lifestyle Mode Changed* and *Activation Completed* fire.
`CURRENT_LIFESTYLE_MODE` is empty and **Lifestyle Mode** shows `-`. The shade
stays closed: only `restore` devices are put back.

A device is either set by the mode or restored by it, not both. That is why the
dimming is a line on the event and not a level in the mode.

### Welcome home from the alarm panel

In Programming, select the security panel's own disarm event. Add a
conditional on this driver's variable `CURRENT_PRESENCE_MODE`: is equal to
`Away`. Under it, add this driver's command `Activate Mode` with `NAME` `Home`.

Disarming the panel while the house is in Away puts it in Home. While it is in
Vacation nothing happens, because the variable does not say `Away`; add a
second conditional if the panel should end Vacation too.

For Sleep at half past eleven while someone is home, no programming is needed:
run `Set Mode Schedule` once with `NAME` `Sleep`, `TIME` `23:30`, `DAYS`
`Every Day` and `REQUIRED_MODE` `Home`.

## Programming reference

### Events

- *Presence Mode Changed*, *Lifestyle Mode Changed*. The second also fires
  when a Lifestyle mode ends.
- One event per mode, named after it: *Away Activated*, *Movie Activated*. It
  is added when the mode is created.
- *Activation Started*, *Activation Completed*, *Activation Warning*,
  *Activation Failed*, *Activation Blocked*.
- *Departure Countdown Started*, *Departure Countdown Cancelled*.

### Conditionals

- *Presence Mode Name*, *Lifestyle Mode Name*: compare the active mode's name
  with the text you type. Capitals do not matter.
- *House Is Transitioning*: true during a departure countdown.
- *House Is Occupied*: true while the Presence mode is one that counts as
  occupied (the Home type).

### Variables

| Variable | Holds |
| --- | --- |
| `CURRENT_PRESENCE_MODE`, `CURRENT_LIFESTYLE_MODE` | The active modes' names; empty when there is none |
| `PREVIOUS_PRESENCE_MODE`, `PREVIOUS_LIFESTYLE_MODE` | The mode that was active before the last change. After `Reapply Mode` or *Test Selected Mode* on the active mode, that same mode |
| `CURRENT_MODE_ID` | The Presence mode's internal id |
| `TRANSITIONING` | True during a departure countdown |
| `LAST_ACTIVATION_TIME`, `LAST_ACTIVATION_RESULT` | When the last activation ended, and `SUCCESS`, `SUCCESS_WITH_WARNINGS`, `FAILED` or `BLOCKED` |
| `LAST_TRIGGER`, `LAST_TRIGGER_TYPE` | The last schedule or rule that asked, and `SCHEDULE` or `SENSOR`. Not changed by a person's request |
| `LAST_TRIGGER_DEVICE` | Not filled in by this release |
| `OCCUPANCY_STATE` | `OCCUPIED`, `UNOCCUPIED` or `UNKNOWN`, from the Presence mode's type |
| `WARNING_COUNT` | Activations that ended with warnings since the driver last started |

### Commands

| Command | Parameters | What it does |
| --- | --- | --- |
| `Activate Mode` | `NAME` | Activates the mode. Capitals do not matter; an unknown name prints a line and does nothing |
| `Reapply Mode` | `NAME` | Sends the mode again even when it is already active. A departure countdown still applies |
| `Deactivate Lifestyle Mode` | | Ends the Lifestyle mode and puts its `restore` devices back |
| `Restore Previous Presence Mode`, `Restore Previous Lifestyle Mode` | | Activates the mode that was active before the last change |
| `Cancel Transition` | | Cancels a departure countdown |
| `Include Device In Mode` | `NAME`, `DEVICE`, `SETTING` | Setup: one device's setting |
| `Exclude Device From Mode` | `NAME`, `DEVICE` | Setup: removes the device from that mode |
| `Include All Lights`, `Include All Shades` | `NAME`, `SETTING` | Setup: every light or shade in the project |
| `Include All Media Rooms` | `NAME` | Setup: every room, media off |
| `Set Device Delay` | `NAME`, `DEVICE`, `SECONDS` | Setup: send that device later |
| `Set Device Criticality` | `NAME`, `DEVICE`, `CRITICALITY` | Setup: `OPTIONAL`, `NORMAL` or `CRITICAL` |
| `Allow Sensitive Action` | `NAME`, `DEVICE` | Setup: permits that device's unlock, disarm or garage open in that mode |
| `Capture Current State` | `NAME` | Setup: as the action, for the named mode |
| `Add Preflight Check` | `NAME`, `DEVICE`, `EXPECT`, `POLICY` | Setup: a check before the mode runs |
| `Run Preflight` | `NAME` | Prints the checks' results |
| `Set Mode Schedule` | `NAME`, `TIME`, `DAYS`, `REQUIRED_MODE` | Setup: adds a schedule |
| `Clear Mode Schedules` | `NAME` | Setup: removes the mode's schedules |
| `Configure Return Home Rule` | `TARGET_MODE`, `REQUIRED_MODE`, `DOOR`, `PANEL`, `MOTION` | Setup: stores a sensor rule (see [Sensor rules](#sensor-rules)) |

## Properties

| Property | What it is |
| --- | --- |
| **Driver Status**, **Driver Version** | See [Reading the status](#reading-the-status) |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | The licence, as the Agent reports it |
| **Presence Mode**, **Lifestyle Mode** | The active modes; **Lifestyle Mode** shows `-` when there is none |
| **Selected Mode** | The mode that the mode properties and the "Selected Mode" actions work on |
| **Devices In Selected Mode** | How many devices that mode sets, its own and inherited |
| **New Mode Name**, **New Mode Type** | Used by *Create Mode* |
| **Mode Color**, **Mode Enabled**, **Mode Inherits From**, **Mode Priority**, **Transition Style** | The selected mode's settings. A disabled mode cannot be activated and its schedules do not run |
| **Departure Countdown Seconds** | 0 to 600. The wait between the request and the commands |
| **Hold To Confirm Seconds** | Above 0, a Mode Button tap must be repeated within 10 seconds |
| **Mode Duration Minutes** | 0 to 1440, Lifestyle modes only. The mode ends by itself after this long; 0 is never |
| **Selected Keypad Slot**, the six gesture properties, **Slot LED Follows** | See [Keypads](#keypads) |
| **Security User Code** | The panel code for arming and disarming; stored encrypted, then cleared from the field |
| **Advanced Settings** | `Show` reveals the timing properties, **Inter-Command Delay ms**, **History Size**, **Import Configuration**, **Add Trigger Rule JSON** and **Mode Priority** |
| **Inter-Command Delay ms** | 0 to 500, default 50. The gap between two commands of an activation |
| **History Size** | 100, 250 or 500 activations kept |
| **Import Configuration** | Paste an exported configuration here; see *Export Configuration* below |
| **Log Level**, **Log Mode** | Diagnostic logging |

## Actions

| Action | What it does |
| --- | --- |
| *Create Mode* | Creates a mode from **New Mode Type** and **New Mode Name** and selects it |
| *Duplicate Selected Mode*, *Delete Selected Mode* | Copy or remove the selected mode. After a delete, *Print Modes* names any keypad gesture that pointed at it |
| *Activate Selected Mode* | Activates it, as a person's request |
| *Deactivate Lifestyle Mode*, *Cancel Transition* | As the commands of the same name |
| *Capture Current State Into Selected Mode* | See [Putting devices in a mode](#putting-devices-in-a-mode) |
| *Show Device Setup Guide* | Prints the device steps in the Lua tab |
| *Dry Run Selected Mode* | Prints what the mode would send. Sends nothing |
| *Test Selected Mode* | Activates the mode now, without the countdown, even if it is active, and prints the result five seconds later |
| *Run Preflight On Selected Mode* | Prints each check and the overall result |
| *Add Keypad Slot* | Adds a slot to bind in Connections |
| *Print Modes* | Every mode with its kind, own device count, priority, whether it is active, and any problem found in the configuration |
| *Print Selected Mode Detail* | Its id, colour, priority, parent, transition, schedules and plan size |
| *Print Devices In Selected Mode* | Each device and its setting; inherited ones are marked with the parent's name, removed ones `MISSING` |
| *Print History* | The last 25 activations: when, mode, result, and the keypad, gesture, schedule or rule that asked |
| *Print Last Activation Detail* | The last activation since the driver started: source, previous mode, commands sent and each one that failed |
| *Print Trigger Rules*, *Clear Trigger Rules* | List or remove the sensor rules |
| *Generate Diagnostic Snapshot* | Versions, licence, counts, missing devices and configuration problems. It holds no codes |
| *Export Configuration* | Prints the whole configuration as JSON, without the security code. Paste it into **Import Configuration** to restore it: the paste is checked first and a bad one changes nothing |
| *Refresh License* | Asks the Agent again |

## Reading the status

| You see | Meaning | What to do |
| --- | --- | --- |
| **Driver Status** `Online` | Running | |
| **Driver Status** `Config from newer driver (read-only)` | The stored configuration was written by a newer version | Update the driver. Changes are not saved until then |
| **Presence Mode** empty | No Presence mode has been activated yet | Activate Home once |
| **Devices In Selected Mode** begins `None yet` | The mode sets nothing | Capture, or include devices |
| A line beginning `Refused:` in the Lua tab | The licence is refused and enforcement is on | See **License Status**; *Refresh License* asks again |
| A line beginning `No mode named` | A command's `NAME` matches no mode | *Print Modes* lists the names |

| Symptom | Check |
| --- | --- |
| A mode does nothing | Is it already active? That is by design; use `Reapply Mode`. Is **Mode Enabled** `Yes`? Does *Dry Run Selected Mode* list any action? |
| A keypad button does nothing | Is the button's Button Link bound to the slot in Connections? Is a gesture set on that slot? With only a hold assigned, a short press does nothing |
| A tap feels slow | A double or triple tap is assigned on that slot, so the tap waits for the window |
| The LED is wrong | **Slot LED Follows** is `None`, or follows another mode. LEDs repaint on the next mode change |
| A Mode Button needs two taps | **Hold To Confirm Seconds** is above 0 (3 on a new Vacation mode) |
| A schedule did not run | Was a higher-priority mode active, the mode already active, or the `REQUIRED_MODE` not the Presence mode? Is **Mode Enabled** `Yes`? |
| The mode ran but a device did not move | *Dry Run Selected Mode*: is it `SKIP` or `MISSING`? *Print Last Activation Detail*: did its command fail to send? Otherwise the command was sent; look at the device |
| A device was replaced | Its old entry shows `MISSING`. Include the new device and exclude the old one |

## What is not claimed

- This manual describes what the driver's code and its tests do. It does not
  claim a bench confirmation for any of it.
- Sensor rules do not fire in this build. See [Sensor rules](#sensor-rules).
- A command is sent, not verified. A device that ignores its command is not
  detected, and an offline device is not detected before sending.
- The device vocabularies follow Control4's proxy commands for lights, shades,
  thermostats, fans, locks and security panels. A device whose driver differs
  will not respond; program it on the mode's event. Relays and room volume
  cannot be set through the commands in this release.
- Setpoints are Fahrenheit only.
- After a controller restart the driver knows which modes were active and
  repaints the LEDs without sending the modes again. A countdown that was
  running is dropped, a **Mode Duration Minutes** timer is not resumed, and the
  states read for `restore` are gone, so that Lifestyle mode ends only by hand
  and puts nothing back.
- Keypad LEDs have two colours and on or off. Blinking is the driver switching
  the LED once a second during a countdown or a hold.
- An exported configuration refers to devices by their id in this project. It
  is a backup for this project, not a template for another.
- Schedules are clock times only. Occupancy is only what the Presence mode's
  type says. Presence simulation, geofencing and cloud backup are not part of
  this release.
- Setup is through Composer properties, actions and commands; there is no
  configuration page.

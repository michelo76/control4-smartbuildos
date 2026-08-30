# SmartBuildOS Mode Composer

The dealer describes how the house should behave; the driver figures out the
programming. Mode Composer is a state-aware mode engine for Control4: Home,
Away, Vacation, Sleep, Movie, Party and custom modes with device states, keypad
gestures, LED feedback, sensor rules, schedules, history and diagnostics —
configured, not programmed.

## Installation (10 minutes)

1. Add **SmartBuildOS Mode Composer** to the project (one instance per project).
   Add the **SmartBuildOS Agent** too if it isn't already there — Mode Composer
   licenses through it.
1. Check **License Status**. `Included with subscription` or
   `Licensed (purchased)` means you're done; the driver also runs unlicensed in
   read-only-configuration mode during evaluation windows per the license status
   shown.
1. Create modes, select devices, assign a keypad, test. Details below.

## Core concepts

- **Presence modes** (Home / Away / Vacation) say who is home. Exactly one is
  active.
- **Lifestyle modes** (Movie / Party / Sleep / Morning / …) say what the house
  is doing. One can be active *on top of* a Presence mode: the house can be Home
  \+ Movie. Exiting a Lifestyle mode restores what it captured.
- Modes are referenced internally by stable ids — **renaming is always safe**
  and never breaks keypads, inheritance or rules.
- **Inheritance**: Vacation can inherit Away and override only what differs
  (deeper HVAC setback, water off). Change a shared Away light once and Vacation
  follows. Cycles are refused when you try to create them.
- **Set / Ignore / Restore** per device: set a state, leave the device alone, or
  capture-before / restore-after (Lifestyle modes).

## Creating a mode

1. Set **New Mode Type** (template: suggested icon/color — templates never pick
   devices for you) and optionally **New Mode Name**.
1. Run the **Create Mode** action.
1. Select it in **Selected Mode**; adjust color, priority, transition,
   countdown, confirmation and duration properties.

## Selecting devices

**Capture Current State** is the fast path: set the house exactly how the mode
should leave it, then run **Capture Current State Into Selected Mode**. The
driver reads every supported device and reports counts per category plus
anything unsupported or unreadable. Nothing is ever silently claimed: security
panels are never auto-captured, and a captured *unlocked* lock is stored as
Locked (sensitive states are never captured as targets).

Fine-tuning uses Composer **commands** (Programming tab > this driver's commands
— used here as configuration tools, not event programming):

- `Include Device In Mode` — pick a device, type a setting: `off`, `on`, `38%`,
  `closed`, `open`, `locked`, `cool 76`, `heat 68`, `speed 2`, `volume 25`,
  `ignore`, `restore`.
- `Include All Lights` / `Include All Shades` / `Include All Media Rooms` — bulk
  selection with one setting, then override individual devices.
- `Exclude Device From Mode`, `Set Device Delay` (e.g. foyer lights off after 90
  s), `Set Device Criticality` (OPTIONAL / NORMAL / CRITICAL),
  `Add Preflight Check`.

Review with **Print Devices In Selected Mode**; rehearse with **Dry Run Selected
Mode** (prints what WOULD happen, sends nothing); verify with **Test Selected
Mode** (executes and prints per-device results).

## Keypads

Keypad **slots** are connections. Run **Add Keypad Slot** (two exist after
install), then in Composer **Connections** bind a keypad button's *Button Link*
to the slot. Back in Properties, select the slot and map gestures:

```
Kitchen Keypad button 5 -> Keypad Slot 1
Slot Tap          Activate: All Off
Slot Double Tap   Activate: Away
Slot Triple Tap   Activate: Vacation
Slot Hold         Activate: Sleep
```

Gesture recognition is built in — no Composer programming, no keypad double-tap
support required. A tap waits for the double-tap window only when a
double/triple is actually assigned; hold tiers resolve to the longest threshold
crossed; a stuck button cancels safely. Timing lives under **Advanced
Settings**.

**LED feedback**: set **Slot LED Follows** to a mode (LED lights in the mode's
color while active) or **Global Presence Mode** — the HOUSE button: green when
Home, blue when Away, purple when Vacation, updating on every keypad that
follows it. Recolor a mode once and every inheriting button repaints. During
countdowns and hold-confirmations the LED blinks; failures flash red briefly.
LED problems never block a mode from executing.

## Departure countdown & confirmation

- **Departure Countdown Seconds** on Away-style modes: the mode reports
  TRANSITIONING, LEDs blink, and pressing the same button (or **Cancel
  Transition**) cancels. Execution starts when the countdown ends.
- **Hold To Confirm Seconds** guards disruptive modes in Navigator: the first
  tap asks for a second tap within 10 seconds. Keypad Hold gestures are already
  deliberate and skip this.

## Transitions

- **Immediate** — paced but prompt (inter-command spacing keeps the Director
  happy; configurable under Advanced).
- **Graceful** — lights ramp over 3 s.
- **Sequenced** — stages: media off, lights, shades, fans, relays, garage,
  locks, climate, then security, a couple of seconds apart. A critical failure
  (a lock, the panel) still fails the activation; a dead decorative shade only
  produces a warning.

## Sensor rules (coming home)

`Configure Return Home Rule` wires the classic sequence with three device
pickers: door opens AND panel disarms AND motion trips — all within two minutes,
only while presence is Away — then Home activates. One signal alone never fires;
chattering contacts are debounced; a fired rule cools down; and Vacation
outranks sensor rules by default (priority 60 vs 50), so a single motion event
can never cancel Vacation. Advanced rules paste as JSON into **Add Trigger Rule
JSON**:

```
{"mode_id": "Home", "signals": [
   {"type": "CONTACT_OPENED", "device_key": "123"},
   {"type": "SECURITY_DISARMED", "device_key": "456"}],
 "conditions": [{"type": "TIME_RANGE", "from": "17:00", "to": "23:00"}],
 "window_s": 120, "cooldown_s": 60}
```

Signal types: `CONTACT_OPENED/CLOSED`, `MOTION`, `SECURITY_DISARMED/ARMED`,
`VARIABLE` (+`variable`,`value`). Condition types: `PRESENCE_IS`,
`LIFESTYLE_IS`, `SECURITY_STATE`, `SENSOR_OPEN/CLOSED`, `TIME_RANGE`,
`DAY_OF_WEEK`, `VARIABLE_EQUALS`.

## Schedules

`Set Mode Schedule`: HH:MM + Every Day / Weekdays / Weekends + an optional "only
while presence is X" guard. Sleep at 23:30 while Home is one command. Manual
activations never confuse the scheduler. (Sunrise/sunset offsets are on the
roadmap; V1 schedules are clock-based.)

## Navigator buttons

Add one **SmartBuildOS Mode Button** driver instance per mode you want on
screen, place it on a room's experience menu, and pick the mode in its
properties. The button takes its name, icon and active state from the manager —
configure the mode once, everywhere follows.

## Preflight

`Add Preflight Check` attaches conditions evaluated before activation: front
door CLOSED, garage CLOSED, panel READY. Each check warns, blocks, or is ignored
— your choice per check. **Run Preflight** rehearses them. Vacation inherits
Away's checks automatically.

## History & diagnostics

- **Print History** — the last activations, one line each: when, what, result,
  which keypad/gesture/rule asked for it.
- **Print Last Activation Detail** — the full "why did this happen": source,
  gesture and hold time, previous mode, action counts, and every failure with
  the device's name.
- **Generate Diagnostic Snapshot** — versions, license, counts, missing devices,
  validation findings. Safe to paste into a support ticket: it never contains
  codes or secrets.

## Programming surface

Events: mode-changed (presence/lifestyle), activation started / completed /
failed / blocked / warning, countdown started / cancelled, plus a dynamic
"<Mode> Activated" event per mode. Commands: Activate Mode, Deactivate Lifestyle
Mode, Restore Previous, Cancel Transition, Reapply Mode, Run Preflight, Capture
Current State. Variables: CURRENT/PREVIOUS presence and lifestyle modes,
TRANSITIONING, LAST_TRIGGER\*, LAST_ACTIVATION\*, OCCUPANCY_STATE,
WARNING_COUNT. Conditionals: presence/lifestyle name comparisons, Transitioning,
Occupied.

## Security posture

Locking, closing and arming are ordinary mode actions. **Unlocking, disarming
and opening a garage never run unless you explicitly run
`Allow Sensitive Action` for that exact device in that exact mode** — templates
never include them, capture never records them, and there is no remote
activation surface in this release. The security user code letterboxes into
encrypted controller storage and never appears in logs, exports or snapshots.

## Export / import / recovery

**Export Configuration** prints the whole configuration as JSON (no secrets).
Paste into another instance's **Import Configuration** property: it is
validated, migrated and applied atomically — a bad paste never corrupts the
current configuration. Configuration and history survive Director restarts;
after a restart the driver restores its logical state and repaints LEDs without
re-sending device commands.

## Troubleshooting

| Symptom                 | Check                                                                                                           |
| ----------------------- | --------------------------------------------------------------------------------------------------------------- |
| Mode does nothing       | Print Modes (is it enabled? devices selected?), then Dry Run, then Test.                                        |
| Keypad button dead      | Is the button's *Button Link* bound to the slot in Connections? Print the slot's gestures — is anything mapped? |
| LED wrong               | Slot LED Follows set? LEDs repaint on state changes; run any activation.                                        |
| "already active"        | Activating the active mode is a no-op by design; use Reapply Mode to re-send.                                   |
| Sensor rule never fires | Print Trigger Rules; all signals must land within the window; check the required presence condition.            |
| Mode partially failed   | Print Last Activation Detail names each failed device.                                                          |
| Device replaced         | The old entry shows MISSING; Include the new device and Exclude the old key.                                    |
| License warnings        | The Agent's pairing is the source of truth; Refresh License re-asks.                                            |

## Known limitations (this release)

- Composer property/action configuration only (Control4 does not offer
  third-party drivers a configuration webview).
- Keypad LEDs support two colors + on/off; "blinking" is simulated only during
  countdowns/holds and stops immediately after.
- Schedules are clock-based (no sunrise/sunset yet).
- Thermostat, shade, fan and security vocabularies follow the official proxy
  protocols; a device whose driver deviates will show per-action failures in
  Test — report these, they are usually fixable per-driver.
- Vacation presence simulation, occupancy confidence, geofencing and cloud
  backup are on the roadmap (V2).

# SmartBuildOS Load Shedding

Load Shedding switches off heavy loads in priority tiers when the grid drops
or the battery runs low, and brings them back in order once power has held.
It is vendor neutral: it does not talk to a battery, inverter or panel. It is
told two plain facts, "the grid is down" and (optionally) "the battery is at
N percent", from anything Control4 can see: a contact sensor, any variable in
the project, or a programming line. What it does about those facts is the
product.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a
SmartBuildOS system. The Agent is the licensing authority (SKU
`SBOS_LOAD_SHEDDING`): **License Status** shows this driver's standing. A
definitive licence denial with enforcement on makes the driver read-only, and
**before it does, it restores every load it had shed**. A licence problem can
never leave a house with its loads off. Only a definitive denial does this. A
missing Agent, an Agent that has not answered yet or a cloud that cannot be
reached leave the driver fully active.

## What it does

1. **Outage starts.** Tier 1 sheds at once.
1. **Battery falls** (if a battery input is set). Tier 2 sheds at or below
   **Tier 2 Battery Percent**, tier 3 at or below **Tier 3 Battery
   Percent**. A tier sheds only after the tier below it.
1. **No battery data.** With no fresh battery reading, tier 2 sheds after
   **Tier 2 No Data Minutes** of outage and tier 3 after **Tier 3 No Data
   Minutes**. A reading counts as fresh for that many minutes. Setting a
   value to `0` turns the time path off for that tier.
1. **Power returns.** Nothing restores yet. The grid must stay back for
   **Stable Hold Seconds**. If it drops again before then, the wait starts
   over (a flapping grid never restores anything).
1. **Restore.** Tier 3 comes back first, then tier 2, then tier 1, **Tier
   Delay Seconds** apart so everything does not start at once. This is the
   reverse of the order they were shed, so the heaviest loads come back last.
   If the grid drops during the restore, the restore stops: what is not back
   yet stays shed, and tiers that are back are shed again.

Before a load is shed the driver reads and remembers its state. A light that
was off, a relay that was already open or a thermostat already at or past its
setback is left alone and is **not** switched on at restore. Everything the
driver needs to finish an outage is saved on the controller, so an outage
that spans a controller restart still restores correctly.

## Setup

<!-- walkthrough: Set up Load Shedding -->
1. Install and pair the SmartBuildOS Agent from Composer's Agents tab. Add
   this driver (one per project). **Driver Status** reads `Online`.
1. Under **Outage Device** pick the contact sensor or device that tells you
   the grid is down. Set **Outage Variable** to the variable on it (`STATE`
   for a contact sensor) and **Outage When Value Is** to the values that
   mean "down" (`1,closed,true,on` by default). Check on the bench which
   value your sensor reports during an outage. To use only programming, leave
   **Outage Device** on `-` and call the *Set Outage* command.
1. Optional: pick a **Battery Device** and **Battery Variable** that report a
   percentage. Without one, tiers 2 and 3 shed by time.
1. For each load (up to 12): pick its **Device**, its **Kind** (Light,
   Relay, Thermostat setback) and its **Tier** (1, 2 or 3). For a
   thermostat also set **Setback F**: a Heat thermostat is set down to it, a
   Cool thermostat is set up to it; other modes are left alone.
1. Run the action *Test Mode (Dry Run)* and read the Lua output: it lists
   what would shed and restore, in order, and sends nothing.
1. Test it for real with the command *Set Outage* On, watch the loads, then
   *Set Outage* Off.

The device lists show `Name (Room) · id`. If a device you added later is
missing, run *Refresh Device Lists*.

### Picking the input in programming instead

The commands `WATCH_OUTAGE_VARIABLE` and `WATCH_BATTERY_VARIABLE` take a
variable chosen with Composer's own variable picker. `WATCH_OUTAGE_VARIABLE`
also takes `WHEN`, the comma-separated values that mean "down". The choice is
saved and replaces the properties until a property for that input is
changed.

## Programming reference

### Commands

| Command | Parameters | Does |
| --- | --- | --- |
| `SET_OUTAGE` | `STATE` On / Off | Tells the driver the grid is down or back. Works with or without a sensor; a later sensor change still counts. |
| `SET_BATTERY` | `PERCENT` | Tells the driver the battery percentage (0 to 100). |
| `SHED_TIER` | `TIER` 1 / 2 / 3 | Sheds that tier now, outage or not. It stays shed until *Restore All* or the end of an outage. |
| `RESTORE_ALL` | none | Restores every shed load now, tier 3 first, tier delay apart. Skips the stable hold. |
| `TEST_MODE` | none | Dry run: logs what would shed and restore. Sends nothing. |
| `WATCH_OUTAGE_VARIABLE` | `VARIABLE`, `WHEN` | Uses the picked variable as the outage input. |
| `WATCH_BATTERY_VARIABLE` | `VARIABLE` | Uses the picked variable as the battery input. |

### Events

| Event | Fires when |
| --- | --- |
| Outage Started | The outage begins. Tier 1 is shedding. |
| Tier Shed | A tier was shed. `LAST_TIER_SHED` says which. |
| Restored | Every shed load is back. |
| Restore Delayed | Power is back and the hold has started, or the grid dropped again and the hold was abandoned. |
| Load Re-shed | A shed load was switched on and shed again. |
| Load Control Failed | A shed or restore command could not be sent. |
| Load Shedding Read-Only | The licence halted the driver (after it restored everything). |
| Load Shedding Active | The driver is active again. |

### Conditionals

*An outage is active*, *Tier 1 is shed*, *Tier 2 is shed*, *Tier 3 is shed*,
*Load Shedding is active (not read-only)*.

### Variables

`OUTAGE_STATE` (Normal, Outage, Power back, waiting to restore, Restoring),
`OUTAGE_ACTIVE` (True / False), `TIER_SHED` (highest tier shed, 0 for none),
`LAST_TIER_SHED`, `BATTERY_PERCENT` (-1 when unknown), `LOADS_SHED`,
`LS_STATUS`.

### Actions

*Print Status*, *Test Mode (Dry Run)*, *Restore All Loads*, *Refresh Device
Lists*, *Register With Agent Now*, *Refresh Status*.

## History

When a Flight Recorder is in the project, outage start, each tier shed or
restored, restore delays, flaps and re-sheds are sent to it as markers on the
channel `load-shedding` (turn off with **Record To Flight Recorder**). With no
Flight Recorder nothing is recorded and nothing complains. This driver keeps
no long-term log of its own; **Last Event** shows only the latest.

## Re-shed, and an honest limit

**Re-shed Loads Turned On** (off by default) turns a shed load off again if
someone switches it on during an outage, at most five times per load per
outage so it never fights a person. This is the limit: **Control4 Navigator
cannot be locked.** Anyone with the app can turn a shed light or relay back on
and the driver can only switch it off again a moment later. Load Shedding
manages loads; it is not a lock and not an electrical interlock. A load that
must never run on the battery needs a breaker or a hardware contactor.

## Limits

- It acts on lights, relays and Heat/Cool thermostats through their standard
  commands. Dimmers are restored to the level they had; other device types
  are not supported.
- It sheds only when told. If the outage input is wrong or never reports,
  nothing sheds, and loads shed by an input that then stops reporting stay
  shed until the input reports again or *Restore All* runs. Use *Restore All
  Loads* as the manual way out.
- A restore after a long outage uses the prior states saved when each load
  was shed, not what the house wants now.
- Restoring a thermostat sets back the setpoint of the mode it was in when
  shed. A mode change during the outage is not undone.
- Battery thresholds only help if the battery input is a percentage and is
  kept fresh.
- Up to 12 loads, three tiers. Vendor integrations (battery or panel makes)
  are not part of this release.

## Unverified on a controller

Everything below is tested only in the simulator.

- The variable names for the outage sensor, and which value means "down" on a
  real contact sensor or relay in a real project.
- The exact variable names the lights, relays and thermostats report, so that
  prior states are read correctly (`LIGHT_STATE`, `Brightness Percent`,
  `STATE`, `HVAC_MODE`, `HEAT_SETPOINT_F`, `COOL_SETPOINT_F`).
- That the commands `OFF`, `ON`, `RAMP_TO_LEVEL`, `OPEN`, `CLOSE`,
  `SET_SETPOINT_HEAT` and `SET_SETPOINT_COOL` sent straight to a device id are
  accepted by every device type involved.
- Variable-change notifications for the outage input, the battery input and
  re-shed feedback (the driver also polls once a minute).
- The `Name (Room) · id` lists and the variable picker commands in Composer.
- Restore after a real controller restart in the middle of an outage.
- The Flight Recorder markers appearing in its history.
- The licence halt path against a live Agent.

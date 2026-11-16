# SmartBuildOS System Link Thermostat

This driver is a thermostat in this project that stands in for a real thermostat
in another Control4 project. The project that has the thermostat (the owner)
shares it across the link as an export. This driver sits on the receiving side
and presents that export as an ordinary Control4 thermostat: it has a place in a
room, on the Navigators and in programming. It shows the temperature, setpoints
and modes the owner's thermostat has reported, and every change made here is
sent to the owner as a request.

For a temperature reading alone, with no control, SmartBuildOS System Link
Temperature is the smaller tool.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `thermostat` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and that licence must carry the `THERMOSTAT`
  feature: without it the owner cannot export a thermostat at all, view only
  included.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked thermostat -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `thermostat`, pick the thermostat in **Export Device**, fill in
   **Export Name**, set **Export Control** to `Control allowed` if this project
   is to change it, and run *Export Selected Device*. If the licence lacks
   `THERMOSTAT`, **Last Error** there says so.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Hall_Stat (thermostat)`. Pick it in
   **Pending Export** and run *Add Companion For Pending Export*. This driver is
   added, linked to the export and named after it: `Hall_Stat` becomes "Hall
   Stat". *Auto Setup* does the same for every pending export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds thermostat exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** shows the thermostat, for example
   `72°F · heat 68 · cool 76 · Heat`.
1. Move the thermostat to the room where it should appear.
1. On the Actions tab press *Test: Heat Setpoint 68*. **Requested State** reads
   `heat 68` with the time, **Last Result** goes from `sent` to `accepted` to
   `delivered`, and **Confirmed State** changes once the owner's thermostat
   reports the new setpoint.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | Temperature, heat setpoint, cool setpoint, HVAC mode, HVAC state (what the system is doing now), fan mode |
| Here to the owner | Heat setpoint, cool setpoint, HVAC mode, fan mode |
| Not carried | Humidity, a single setpoint, hold, presets and schedules, a change of scale, outdoor temperature, messages |

The owner reads seven variables from its thermostat: the temperature, the two
setpoints, `HVAC_MODE`, `HVAC_STATE`, `FAN_MODE` and `SCALE`. For the
temperature and setpoints it takes the Fahrenheit variable when the thermostat
has one. This driver works in Fahrenheit: it shows the numbers it receives as
Fahrenheit and sends setpoints in Fahrenheit, converting a setpoint entered in
Celsius first. It does not use the scale the owner reports.

A change made here never changes what this thermostat shows. It becomes one
request to the owner, who sends the matching setpoint or mode command to the
real thermostat, and the new value appears here only when that thermostat
reports it. Nothing is sent on a restart: only an explicit change becomes a
request, and each request is sent once.

The lists offered here are fixed, not read from the owner's thermostat: HVAC
modes Off, Heat, Cool and Auto; fan modes Auto and On; heat setpoints from 4 to
32 °C and cool setpoints from 10 to 35 °C in half-degree steps. A mode is passed
to the owner by name; what its thermostat does with a mode it does not have is
up to that thermostat.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no thermostat export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: all seven values are confirmed. `stale`: the link is not synchronised, or the owner has not confirmed a value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's thermostat does not supply at least one of the seven |
| **Control** | `control permitted` when the owner exported the thermostat with control allowed and SmartBuildOS System Link here permits commands (not paused, licence in order); otherwise `view only / suspended` |
| **Control Window** | The owner's schedule for this export and whether it is open now, by the owner's clock. `none` when there is no schedule. While it is closed a change is refused here without being sent: **Last Result** reads `refused: outside the control window` with the schedule, and *Control Refused* fires |
| **Confirmed State** | The owner's last report: temperature, heat setpoint, cool setpoint and mode. A `?` stands for a value that did not arrive |
| **Requested State** | The last request sent from here and when, for example `mode Cool at 18:04:10` |
| **Last Result** | `sent`, then `accepted` (queued for the owner), then `delivered` (the owner sent it to the thermostat) or `failed:` with the reason, for example `failed: feature THERMOSTAT is not licensed` |

## Programming

The thermostat itself is a standard Control4 thermostat (the `thermostatV2`
proxy), so it has the usual thermostat commands, events and conditionals in
programming. Of the commands, the two setpoints, the HVAC mode and the fan mode
are sent to the owner; the others do nothing. The driver adds these of its own:

- Events: *Remote Value Current* and *Remote Value Stale* (**Freshness** became
  `current` or stopped being `current`), *Control Refused* (a request was
  refused; **Last Result** has the reason).
- Conditional: *Remote Value Is Current*.
- Actions: *Test: Heat Setpoint 68*, *Test: Cool Setpoint 76*,
  *Test: Mode Heat*, *Test: Mode Off*, *Refresh From Bridge* (ask for the export
  list and state again), *Rename From Export* (name the device after the export
  even if you renamed it), *Print Diagnostics To Log*.

It has no variables and no commands of its own. The export's values are also
variables of SmartBuildOS System Link, named after the owner's alias and the
export, such as `<Alias>.Hall_Stat_Temperature`.

## Examples

### Set the other house back when this one goes to Away

Add this thermostat's ordinary heat setpoint command to the Away routine, with
62 as the setpoint. **Requested State** reads `heat 62` with the time. On
*Control Refused*, send a notification with the reason. The setback has taken
effect when **Confirmed State** shows `heat 62`.

### Do not act on an old reading

Put any programming that reads this thermostat's temperature inside
*Remote Value Is Current*. When the value is not current, the thermostat here
keeps showing the last numbers it was told; this driver does not report it as
lost.

## Limits

- The thermostat shows confirmed values only. If the owner's thermostat does not
  report back, nothing changes here, whatever **Last Result** says.
- **Freshness** is `current` only when all seven values are. A thermostat on the
  owner's side that lacks one of the seven variables leaves the export
  `unavailable`, and this thermostat is never told a value.
- Fahrenheit only. If the owner's thermostat has no Fahrenheit variables, its
  Celsius numbers are shown here as Fahrenheit.
- Hardware validation: none recorded. The messages exchanged with the thermostat
  proxy are taken from other thermostat drivers, which is why thermostats stay
  behind the `THERMOSTAT` licence feature; there is no test record for this
  driver on a physical controller.

<!-- #embed-changelog -->

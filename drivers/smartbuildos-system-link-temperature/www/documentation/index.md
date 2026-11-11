# SmartBuildOS System Link Temperature

This driver is a temperature reading in this project that comes from a sensor or
thermostat in another Control4 project. The project that has the device (the
owner) shares its temperature across the link as an export. This driver sits on
the receiving side and offers a **Temperature** connection you bind in
Connections, so a driver here that takes a temperature value can use the far
one.

It only listens. It carries a temperature and nothing else: no setpoints, no
modes, no control. For those, see SmartBuildOS System Link Thermostat.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `temperature` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and sensors are part of every pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked temperature -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `temperature`, pick the sensor or thermostat in **Export Device**, fill in
   **Export Name** and run *Export Selected Device*. A temperature export is
   always view only.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Pool_Temp (temperature)`. Pick it in
   **Pending Export** and run *Add Companion For Pending Export*. This driver is
   added, linked to the export and named after it. *Auto Setup* does the same
   for every pending export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds temperature exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** shows the reading, for example `72.5 °F`.
1. In Connections, bind this driver's **Temperature** connection to the driver
   that should receive the reading.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | The temperature in Fahrenheit and in Celsius, to one decimal |
| Here to the owner | Nothing |
| Not carried | Humidity, setpoints, modes, battery, any other value of the device |

The owner reads two variables from the device it exported: a Fahrenheit one
(`TEMPERATURE_F`, or else `TEMPERATURE` or `Temperature`) and a Celsius one
(`TEMPERATURE_C`). It publishes the numbers as it finds them and does not
convert between scales.

Each time the owner confirms a reading, this driver passes both values, with the
time it received them, to the driver bound to its **Temperature** connection.
Whenever the reading is not current, it tells that driver the value is
unavailable, with the reason, instead of leaving an old number in place.

**Freshness** is `current` only when both values are. If the owner's device has
only one of the two variables, the export reads `unavailable` and the bound
driver is told so, even though **Confirmed State** shows the value that did
arrive.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no temperature export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: both values are confirmed. `stale`: the link is not synchronised, or the owner has not confirmed a value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's device does not supply both values |
| **Confirmed State** | The last reading in Fahrenheit, for example `72.5 °F`; in Celsius if there is no Fahrenheit value; `unavailable` if there is neither |
| **Control** | `view only`, or `view only / suspended` once a state has arrived: a temperature export never allows control |
| **Requested State**, **Last Result** | Not used: this driver sends no requests |

## Programming

- Events: *Remote Value Current* and *Remote Value Stale* (**Freshness** became
  `current` or stopped being `current`). *Control Refused* is listed and never
  fires.
- Conditional: *Remote Value Is Current*.
- Actions: *Refresh From Bridge* (ask for the export list and state again),
  *Rename From Export* (name the device after the export even if you renamed
  it), *Print Diagnostics To Log*.
- Variables and commands: none of its own.

The driver has no temperature variable. For programming on the number, use the
variables SmartBuildOS System Link keeps for the export, named after the owner's
alias and the export: `<Alias>.Pool_Temp_Fahrenheit` and
`<Alias>.Pool_Temp_Celsius`. A driver bound to the **Temperature** connection
brings its own programming.

## Examples

### Freeze warning for the other house

Program on the SmartBuildOS System Link variable `<Alias>.Pool_Temp_Fahrenheit`
changing. Inside *Remote Value Is Current* from this driver, test whether the
variable is below 38 and send the notification.

### The far sensor has gone quiet

On *Remote Value Stale*, send a notification that the far temperature is no
longer confirmed. This catches a dropped link and a sensor the owner can no
longer read, which a test on the number alone would miss.

## Limits

- Both scales must come from the owner's device, as described above. A device
  with only one of the two variables cannot feed a bound driver through this
  driver; its value is still in the SmartBuildOS System Link variable.
- The owner does not convert. If the device's `TEMPERATURE` variable holds
  Celsius, that number is shared as Fahrenheit.
- No event fires on a temperature change. Program on the SmartBuildOS System
  Link variable, or on the driver you bound.
- *Remote Value Is Current* is false after a restart until the first `current`
  state arrives.
- Hardware validation: none recorded. The temperature messages follow the
  SmartBuildOS capability matrix; there is no test record for this driver on a
  physical controller.

<!-- #embed-changelog -->

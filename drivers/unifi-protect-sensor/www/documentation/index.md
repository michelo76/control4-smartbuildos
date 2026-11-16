# UniFi Protect Sensor

Brings one UniFi Protect sensor into Control4: its contact and its motion
detector as connections other drivers can use, its readings as variables, and
its alerts (a leak, tampering, a low battery, an alarm sound) as events.

One instance per Protect sensor, bound to the UniFi Protect Gateway (SBOS) in
the Connections view. The Gateway owns the console connection. No credentials
live here.

## What it is for

| You want | Use |
| --- | --- |
| A Protect door or window sensor that the security system, or any driver that takes a contact, can use | The **Contact** connection |
| Its motion detector used the same way | The **Motion** connection (motion active = closed) |
| Programming when the door opens or closes | *Contact Opened*, *Contact Closed*, `CONTACT_STATE` |
| A leak alert | *Water Leak Detected* |
| A warning when a room gets too warm, too cold, too damp or too dry | The four threshold properties and their events |
| A service alert before the battery dies | *Battery Low*, `BATTERY` |
| A reading in your own logic | `TEMPERATURE`, `HUMIDITY`, `LIGHT_LEVEL` |

## Setup

<!-- walkthrough: Add a sensor -->
1. Install the UniFi Protect Gateway (SBOS) first and confirm it shows
   Connected.
1. Run the Gateway's *Auto Provision Protect Devices* action, which adds and
   binds one instance per sensor. Or add one instance by hand and, in
   Connections, bind its **Protect Sensor** connection to the Gateway
   connection named after the sensor.
1. Check the Properties tab. **Gateway Link** reads `OK - identified as`
   followed by the sensor's name, **Sensor** shows that name, **Sensor
   State** reads `CONNECTED`, and the device is renamed after the sensor.
1. Read **Mount Type**, **Contact**, **Temperature**, **Humidity**, **Light
   Level** and **Battery**. A reading appears only for hardware the sensor
   actually has; the rest stay `-`.
1. To use it as a zone, bind **Contact** or **Motion** to whatever takes a
   contact sensor.
1. For a temperature or humidity alert, type a number into a threshold
   property. Blank means off.

## What programming gets

Alerts arrive live from the console through the Gateway. Readings, the
contact's state and online state are read at each Gateway sync (its **Device
Poll Interval**, 1 minute by default).

| Event | Fires when |
| --- | --- |
| *Motion Detected* | Motion starts. `MOTION_DETECTED` is true until it ends, and **Motion** is closed for that time |
| *Contact Opened*, *Contact Closed* | The console reports the contact opening or closing. **Contact** and `CONTACT_STATE` follow |
| *Water Leak Detected*, *Tamper Detected* | The sensor reports a leak, or being tampered with |
| *Alarm Detected* | The sensor hears an alarm (smoke, CO, glass break) |
| *Battery Low*, *Button Pressed*, *CO Fault* | The sensor reports it |
| *Temperature Above Threshold*, *Temperature Below Threshold*, *Humidity Above Threshold*, *Humidity Below Threshold* | A reading crosses the limit you set |
| *Sensor Online*, *Sensor Offline* | A Gateway sync sees the sensor reconnect or disconnect |

- Conditional: *Sensor online status* is Online or Offline (`SENSOR_ONLINE`).
- Variables: `CONTACT_STATE` (`open`, `closed`, or `unknown` before the first
  reading), `MOTION_DETECTED`, `TEMPERATURE`, `HUMIDITY`, `LIGHT_LEVEL`,
  `BATTERY` (percent), `LAST_MOTION` (when motion last started).
- No commands: a sensor only reports.

### Thresholds

**Temperature High Threshold**, **Temperature Low Threshold**, **Humidity
High Threshold** and **Humidity Low Threshold** each take a number, in the
unit **Temperature** and **Humidity** show. The driver passes readings on as
the console gives them and converts nothing.

An event fires once, at the reading that crosses the limit: above the High
value, or below the Low value. It does not fire again while the reading stays
on that side, and it can fire again only after the reading has come back.
With **Temperature High Threshold** at 30:

| Reading | What happens |
| --- | --- |
| 22.5, then 28 | Nothing |
| 31 | *Temperature Above Threshold* fires |
| 32 | Nothing: still above |

The first reading after the driver starts only sets the starting side.

## Worked examples

### A wine room that is getting warm

Type the limit into **Temperature High Threshold**. In Programming, pick this
sensor's event *Temperature Above Threshold* and send your notification; the
variable `TEMPERATURE` holds the reading. One message per excursion: no
repeat every minute while the room stays warm.

### A leak that shuts the water off

Pick *Water Leak Detected* and add the command that closes the valve, then
the notification. For a door, bind **Contact** to the zone instead of
programming it: whatever is bound there is told each time the door opens and
closes.

## Properties and actions

| Property | What it is |
| --- | --- |
| **Sensor**, **Sensor State** | Which Protect sensor this is, and `CONNECTED`, `CONNECTING`, `DISCONNECTED` or `UNKNOWN` |
| **Gateway Link** | `Asked gateway at … - waiting for a reply` until the Gateway answers, then `OK - identified as …`. If it never changes, the connection is not bound or the Gateway is missing |
| **Mount Type** | How the sensor is mounted, as the console reports it |
| **Contact**, **Temperature**, **Humidity**, **Light Level**, **Battery** | The last readings |

| Action | What it does |
| --- | --- |
| Print Diagnostics To Log | Version, device id, Gateway found or not, identity, state |
| Refresh Sensor Info | Asks the Gateway again which sensor this is, and picks up a new name |
| Forget Sensor | Clears the identity, then asks again over the current binding |

The driver names itself after the sensor while the device still has its
install name or the name the driver gave it. A name you typed is kept.

## What is not claimed

- **No tile in Navigator.** The sensor is connections, events and variables.
- *Contact Opened* and *Contact Closed* come from the console's live events.
  The state read at each sync updates **Contact**, `CONTACT_STATE` and the
  connection, but fires no event.
- Motion has no "ended" event: use `MOTION_DETECTED`.
- Online and offline, and the readings, can trail the console by up to one
  Gateway poll. Readings are also updated at once when the console reports
  an extreme value.
- Events arrive only while the Gateway's **Event Stream** is connected.
  Nothing is queued for later.
- A smoke sensor's self-test is not passed on to programming.
- A rename in Protect is picked up at the next *Refresh Sensor Info* or
  driver restart, not by itself.

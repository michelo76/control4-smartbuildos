# UniFi Protect Gateway

The Gateway connects a Control4 project to one UniFi Protect console over
Ubiquiti's **official Protect Integration API**. It is the parent of the UniFi
Protect family: it owns the console connection and the API key, keeps the list
of cameras, sensors, floodlights and viewports the console knows, and gives
each of them a connection for its own device driver to attach to. It also
holds the console's live event stream and passes each event to the driver of
the device it came from.

Add **one instance per console**. The driver talks to the console directly on
the local network: video, events and commands do not go through Ubiquiti's
cloud, and nothing needs to be opened on the firewall.

Licensing is through the SmartBuildOS Agent (`smartbuildos.c4z`, SKU
`SBOS_UNIFI_PROTECT`); **License Status** shows this driver's standing. The
four device drivers do not license separately: they work through the Gateway.
See [Licence](#licence) for what that changes.

## Requirements

- Control4 OS **3.3.2** or later.
- UniFi Protect **5.3 or later** (the release that introduced the official
  Integration API). The alarm, sirens, relays, alarm hubs and fingerprint or
  NFC identity are Protect 7 features; viewports and live views came between
  the two. On a console that lacks one of these the Gateway carries on
  without it: that list comes back empty and the rest still syncs.
- An **API key**, created in UniFi OS under **Settings → Control Plane →
  Integrations** by an administrator.
- The console reachable from the controller (same LAN, VPN, or a routable
  address).

## Why not a generic camera driver

Protect can hand out a stream address per camera, and a generic camera driver
pointed at it shows the picture. For one camera you only want to look at, that
is still the simplest answer.

What it does not bring is anything Protect knows. This family adds what the
console detects (motion, people, vehicles, packages, a doorbell press), the
state of every device, the Protect alarm, and commands back to the console,
and it fetches and refreshes each camera's stream address for you.

Recordings, detection zones and camera set-up stay in the Protect app. This
family does not replace it.

## What it is for

| You want | Use |
| --- | --- |
| Every Protect camera, sensor, floodlight and viewport added to the project and connected, without doing them one by one | *Auto Provision Protect Devices* |
| Motion, person, vehicle, package and doorbell events in programming | The camera driver's events. The Gateway delivers them: check **Event Stream** |
| Protect armed when the house goes to Away, disarmed on return | `Arm With Profile`, `Disarm` |
| Programming that reacts to a Protect alarm breach | *Breach Detected* |
| To know the console or a device dropped off the network | *NVR Offline*, *Device Offline*, **Offline Devices**, `OFFLINE_DEVICES` |
| A Protect siren sounded or silenced from programming | `Play Siren`, `Stop Siren` |
| A Protect relay or an alarm hub output switched from programming | `Activate Relay`, `Trigger Hub Output` |
| Programming on an alarm hub's own sensors | *Entry Opened*, *Glass Break Detected*, *Smoke Alarm Detected* and the other hub events |
| A Protect Alarm Manager rule that starts Control4 programming | *Custom Webhook Received* with `LAST_WEBHOOK_NAME` |
| Control4 programming that starts a Protect Alarm Manager rule | `Trigger Protect Webhook` |
| A camera still in a push notification | **Snapshot Relay**, with the camera driver's Camera Snapshot attachment |

## Setup

<!-- walkthrough: Connect the console and add its devices -->
1. **Load the drivers.** In Composer use Driver > Add or Update Driver for all
   five files: `unifi-protect.c4z`, `unifi-protect-camera.c4z`,
   `unifi-protect-sensor.c4z`, `unifi-protect-light.c4z` and
   `unifi-protect-viewport.c4z`. *Auto Provision Protect Devices* can only add
   a driver the controller already has.
1. **Create the API key.** Sign in to UniFi OS as an administrator, open
   Settings, then Control Plane, then Integrations, create an API key and
   copy it. The driver never asks for a UniFi username or password.
1. **Add the Gateway** (UniFi Protect Gateway (SBOS)) to the project and set
   **Console Address** to the console's IP address or hostname, for example
   `192.0.2.10`.
1. **Paste the key** into **API Key**. The driver stores it encrypted on the
   controller and clears the field: an empty field after pasting means the
   key was accepted.
1. **Check the connection.** **Connection Status** reads `Connected`,
   **Protect Version** and **NVR Name** fill in, **Cameras**, **Lights**,
   **Sensors**, **Chimes** and **Viewers** show a count such as
   `3 (2 online)`, and **Event Stream** reads `Connected`.
1. **Add the devices.** On the Actions tab press *Auto Provision Protect
   Devices*. Each camera, sensor, floodlight and viewport that has no driver
   yet gets one, already connected. Move the new devices into their rooms.
   To do it by hand instead, see [Devices](#devices-discovery-and-connections).
1. **Check the relay.** **Relay Status** should read `Serving http://…`. If
   it reads `Off` while **Snapshot Relay** is On, set **Snapshot Relay** to
   Off and back to On. If it asks for an address, type the controller's IP
   address into **Relay Address**.

Leave **Verify TLS Certificate** off for a console presenting its factory
self-signed certificate. Turn it on only when the console has a certificate
the controller can actually verify.

## How the console is addressed

### Console Address

Type an IP address or a hostname. The driver keeps the host (and a port, if
you gave one) and always uses HTTPS; anything after the host is ignored, so an
address copied from a browser works.

| You type | The driver uses |
| --- | --- |
| `192.0.2.10` | `https://192.0.2.10` |
| `https://192.0.2.10/protect/dashboard` | `https://192.0.2.10` |
| `http://192.0.2.10` | `https://192.0.2.10` |
| `udm.local:8443` | `https://udm.local:8443` |

Changing the address tests the connection again and reopens the event stream
against the new console.

### API key

The key is the only credential in the family. It is sent to the console with
every request, in the header the Integration API expects.

- **Where it lives.** Encrypted, on the controller. **API Key** is a
  letterbox: the driver takes what you paste, stores it, and empties the
  field, so the key is not left in the project file. Spaces and line breaks
  in a pasted key are removed.
- **Replacing it.** Paste the new key. It replaces the stored one and the
  connection is tested at once.
- **Removing it.** *Forget API Key* deletes it. Polling, the event stream and
  the relay stop and **Connection Status** returns to `Not configured - set
  the Console Address and API Key`. Connections and the last inventory are
  kept.
- The device drivers never see the key. Every exchange with the console
  happens in the Gateway.

### What the Gateway does once connected

- Reads the device lists on the **Device Poll Interval** (30s, 1m, 2m, 5m or
  15m; default 1m). This is a *sync*. `Off` stops the timer; *Test
  Connection* and *Sync Devices Now* still run one.
- Holds the live event stream open, separately from the sync.
- Remembers the last inventory. After a controller restart the counts show
  the last-known fleet and **Last Sync** ends in `(cached)` until the first
  sync lands.

## Devices: discovery and connections

Each sync reads cameras, lights, sensors and chimes, then viewports, live
views, sirens, relays, alarm hubs and arm profiles. For every camera, sensor,
floodlight and viewport the Gateway creates one connection on itself, named
after the device as it was called when first seen. A device driver bound to
that connection *is* that device.

| Device in Protect | Driver, one instance per device | Its connection | What it adds |
| --- | --- | --- | --- |
| Camera or doorbell | UniFi Protect Camera (SBOS), `unifi-protect-camera.c4z` | Protect Camera | The camera in Navigator, detection and doorbell events, doorbell and camera commands |
| Sensor | UniFi Protect Sensor (SBOS), `unifi-protect-sensor.c4z` | Protect Sensor | Contact and motion connections, readings, threshold events |
| Floodlight | UniFi Protect Light (SBOS), `unifi-protect-light.c4z` | Protect Light | On, off and mode commands, motion event |
| Viewport | UniFi Protect Viewport (SBOS), `unifi-protect-viewport.c4z` | Protect Viewport | Live view commands, temporary show and restore |
| Chime | none | none | Counted in **Chimes** and watched for going offline |
| Siren, relay, alarm hub | none | none | The Gateway's own commands and hub events |

**Auto Provision Protect Devices** adds the right driver for every device
whose connection has nothing bound, binds it, and asks Control4 to rename it
after the device. It works through its list one device at a time and writes
each step to the Lua output. It never deletes anything, so running it again
is safe: it only picks up what is new. It needs an inventory, so run it after
a sync has succeeded.

**By hand:** add the device driver, open Connections, and bind its connection
(the third column) to the Gateway connection named after the device. Each
kind has its own connection class (`UNIFI_PROTECT_CAMERA` for cameras), so a
camera driver can only be bound to a camera. The driver's **Gateway Link**
then reads `OK - identified as '…'`.

Connections are **never removed automatically**. A camera that is offline for
a rebuild must not cost you your Composer connections. When a camera is gone
for good, **Connection Status** reads `Connected (1 stale camera binding(s) -
see Actions)`; *Prune Missing Camera Bindings* removes those connections, and
whatever was bound to them.

## How events arrive

The Gateway learns things from the console in two ways, and that decides how
quickly programming hears of them.

| What | How it arrives | When |
| --- | --- | --- |
| Camera motion, smart detections, doorbell rings, audio alarms, line crossing, loitering, fingerprint and NFC | Live event stream | As the console sends them |
| Sensor motion, open and close, leak, tamper, button, battery; floodlight motion | Live event stream | As the console sends them |
| Alarm hub events | Live event stream, fired as the Gateway's own events | As the console sends them |
| Device online and offline, the counts, sensor readings, floodlight state and mode, a viewport's current view | Sync | Every **Device Poll Interval** |
| Arm mode, arm profile, breach | Sync | Every **Device Poll Interval** |
| A webhook from Alarm Manager | The relay's listener | When it is received |

- **Event Stream** shows the state of the live connection. If it drops, the
  Gateway tries again every 30 seconds by itself.
- **Last Event** shows the type and time of the newest event on the stream,
  whatever it was, in Protect's own words (`motion`, `smartDetectZone`,
  `ring`).
- An event goes to the driver bound to that device's connection. If nothing
  is bound, or Protect sends a type the family does not use, the event is
  dropped: nothing is queued for later.
- With **Device Poll Interval** `Off`, live events still arrive, but the rows
  marked Sync stop updating.

## The alarm, sirens, relays and hubs

These belong to the Gateway itself: there is no device driver for them.

**Alarm.** **Arm Mode** and **Arm Profile** show what the console reports,
and the same values are in `ARM_MODE` and `ARM_PROFILE`. `Arm With Profile`
arms; give it a profile name to select that profile first, or leave `Profile`
empty to arm with the profile already selected. `Select Arm Profile` changes
the profile without arming. Profile names are matched without regard to
capitals; *Print Arm Profiles To Log* lists them and marks the current one.

**Sirens, relays and alarm hub outputs.** Name the device as Protect names it
(capitals do not matter) or give its id; *Print Security Devices To Log*
lists all three kinds. These commands are sent **exactly once**. If the
console does not answer, the driver reports it and does not try again: a
siren that sounded twice is worse than a line in the log. Check in Protect
before repeating one.

**Results** of all these commands go to the log, not to a property. A
profile, siren, relay or hub name the console does not have is refused
before anything is sent. Set **Log Mode** to Print to see a refusal or a
failure.

## Snapshot relay and webhooks

The console only gives a still image to a request that carries the API key,
and a touchscreen or the Control4 app cannot send one. With **Snapshot
Relay** On, the Gateway listens on **Relay Port** (default 47800), fetches
the image with the key, and serves it on the LAN at:

`http://<controller>:47800/snapshot/<camera-id>`

Add `?hq=1` for the high-quality image. Only cameras that have a Gateway
connection are served; anything else gets a 404. Each camera driver receives
its own address from the Gateway.

**Privacy.** Anyone on the LAN who knows the address can fetch a still
without a key. That is the same exposure as Protect's own Anonymous Snapshot
option. Set **Snapshot Relay** to Off to close it; inbound webhooks stop with
it, because they use the same listener.

**Webhooks from Protect.** Point an Alarm Manager webhook at:

`http://<controller>:47800/webhook/<name>?token=<Webhook Token>`

`<name>` is yours to choose (letters, digits, `-` and `_`). When one arrives
with the right token, `LAST_WEBHOOK_NAME` and `LAST_WEBHOOK_TIME` are set and
*Custom Webhook Received* fires. A wrong or missing token gets a 404 and
fires nothing. The same name within 2 seconds is answered but ignored, and a
request larger than 8 KB is refused.

**Webhook Token** is created for you when the driver starts with the field
empty. It is an ordinary property, shown in plain text. Clear it to refuse
every webhook; a new one is made the next time the driver starts.

**Webhooks to Protect.** `Trigger Protect Webhook` fires an Alarm Manager
webhook trigger. `TriggerId` is the id Alarm Manager shows for that trigger.

## Worked examples

### Protect arms when the house goes to Away

<!-- walkthrough: Arm Protect from Control4 -->
1. Press *Sync Devices Now*, then *Print Arm Profiles To Log*, and read the
   profile names in the Lua output. This example uses one called Away.
1. In Programming, pick the event that means the house is empty (a keypad
   button, your security panel arming). Add the Gateway's `Arm With Profile`
   command and type `Away` in `Profile`.
1. On the event that means someone is home, add the Gateway's `Disarm`
   command.
1. Pick the Gateway's event *Breach Detected* and add what should happen: the
   lights to full, `Play Siren` with the siren's name and a `Duration` of 30.
1. Test it. **Arm Mode** and **Arm Profile** follow within one **Device Poll
   Interval**, and *Armed* fires at that moment, not when the command is
   sent.

### A Protect rule that runs Control4 programming

In Protect's Alarm Manager, give a rule a webhook action with the address
`http://<controller>:47800/webhook/gate?token=<Webhook Token>`. In
Programming, pick the Gateway's event *Custom Webhook Received*, add a
conditional that `LAST_WEBHOOK_NAME` is `gate`, and put the commands inside
it. One event serves every rule: the name tells them apart.

To test without Protect, from a computer on the LAN:

```bash
curl "http://<controller>:47800/webhook/gate?token=<Webhook Token>"
```

The answer is `ok` and the event fires. With a wrong token the answer is
`not found`.

### Tell the service team a device dropped

Program on the Gateway's variable `OFFLINE_DEVICES` changing, with a
conditional that it is greater than 0, and send your notification from
there. The variable is the number of devices that are not connected, set at
every sync; **Offline Devices** lists them by name.

*Device Offline* also fires, once for each device that dropped, but it does
not say which device and it fires just before the count is updated. To act
on one particular camera, use that camera driver's own *Camera Offline*
event.

## Programming reference

**Events**

| Event | Fires when |
| --- | --- |
| *Armed* | The arm mode changed between two syncs to anything that is not a disarmed value |
| *Disarmed* | The arm mode changed to a value containing "disarm", or to `off` |
| *Arm Profile Changed* | The active profile changed between two syncs |
| *Breach Detected* | The console reports a breach time the driver has not seen since it started |
| *Siren Started*, *Siren Stopped* | This driver's `Play Siren` or `Stop Siren` command ran |
| *NVR Offline* | A sync or connection test failed after one had succeeded |
| *NVR Online* | The console answered again |
| *Device Offline* | A device's state became `DISCONNECTED` between two syncs |
| *Device Online* | A device went from `DISCONNECTED` to `CONNECTED` |
| *Custom Webhook Received* | A webhook with the right token arrived |
| *Entry Opened*, *Entry Closed* | An alarm hub entry opened or closed |
| *Glass Break Detected*, *Smoke Alarm Detected*, *Hub Motion Detected* | An alarm hub reported it |
| *Hub Tamper Detected*, *Hub Button Pressed*, *Hub Battery Low*, *Hub Relay Switched* | An alarm hub reported it |

The first reading after the driver starts sets the baseline: *Armed*,
*Disarmed*, *Arm Profile Changed* and *NVR Online* fire on a change, not on
start-up.

**Conditional:** *UniFi Protect connection status* is Connected or
Disconnected (`UNIFI_PROTECT_CONNECTED`).

**Variables:** `ARM_MODE` and `ARM_PROFILE` (text), `OFFLINE_DEVICES` (a
number), `LAST_WEBHOOK_NAME`, `LAST_WEBHOOK_TIME`.

**Commands**

| Command | Parameters | What it does |
| --- | --- | --- |
| `Arm With Profile` | `Profile` (name or id, may be empty) | Selects the profile if one is given, then arms |
| `Disarm` | none | Disarms |
| `Select Arm Profile` | `Profile` | Selects a profile without arming |
| `Play Siren` | `Siren`, `Duration` | Sounds the siren. The console takes 5, 10, 20 or 30 seconds: other numbers are rounded down to the nearest of these (12 becomes 10), and anything under 5 becomes 5. Left empty, no duration is sent |
| `Stop Siren` | `Siren` | Stops it |
| `Test Siren` | `Siren`, `Volume` (1 to 100) | Plays the siren's test sound |
| `Activate Relay` | `Relay`, `Output`, `State`, `PulseMs` | Switches a relay output. `Output` defaults to 1. `State` is `on` or `off`; anything else toggles. `PulseMs` switches it back after that many milliseconds |
| `Trigger Hub Output` | `Hub`, `Output`, `Enable`, `DurationMs` | Triggers an alarm hub output. `Output` defaults to 1. `Enable` is `true` or `false` (`on` and `off` also work); empty toggles. `DurationMs` is sent as the duration in milliseconds |
| `Trigger Protect Webhook` | `TriggerId` | Fires an Alarm Manager webhook trigger |

## Properties

| Property | What it is |
| --- | --- |
| **Console Address**, **API Key**, **Verify TLS Certificate**, **Device Poll Interval** | The connection. See [How the console is addressed](#how-the-console-is-addressed) |
| **Snapshot Relay**, **Relay Port**, **Relay Address**, **Relay Status** | The listener for snapshots and webhooks. **Relay Address** `auto` looks the controller's address up in the project |
| **Webhook Token** | The shared secret for inbound webhooks |
| **Connection Status**, **Event Stream**, **Last Sync**, **Last Event** | See [Reading the status](#reading-the-status) |
| **Protect Version**, **NVR Name** | Read from the console by *Test Connection* |
| **Cameras**, **Lights**, **Sensors**, **Chimes**, **Viewers** | How many, and how many are online |
| **Arm Mode**, **Arm Profile** | The console's alarm state, as of the last sync |
| **Offline Devices** | The names of devices that are not connected, or `None` |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | What the SmartBuildOS Agent answered |
| **SmartBuildOS Reporting** | Off by default. On hands the device list (names, MAC addresses, online state) to the SmartBuildOS Agent in this project whenever it changes |
| **Driver Status**, **Driver Version** | **Driver Version** is the build actually running. If it is not the newest after an update, the project is serving a cached copy |
| **Log Level**, **Log Mode** | Logging. **Log Mode** turns itself Off after 3 hours |

## Actions

| Action | What it does |
| --- | --- |
| Test Connection | Verifies the address and key, then refreshes everything |
| Sync Devices Now | Refreshes the inventory without waiting for the next poll |
| Print Inventory To Log | Writes cameras, lights, sensors and chimes, with state, id and MAC, to the log |
| Print Camera Bindings To Log | Lists each camera connection, its camera, and the device bound to it |
| Prune Missing Camera Bindings | Removes camera connections whose camera no longer exists on the console |
| Auto Provision Protect Devices | Adds and binds a driver for every device that has none |
| Print Arm Profiles To Log | Lists the arm profiles and marks the current one |
| Print Security Devices To Log | Lists sirens, relays and alarm hubs with state and id |
| Refresh License | Registers with the SmartBuildOS Agent again and asks for the licence |
| Forget API Key | Deletes the stored key; the driver goes back to Not configured |

## Reading the status

**Connection Status**

| It reads | Meaning | What to do |
| --- | --- | --- |
| `Not configured - set the Console Address and API Key` | One of the two is missing | Finish [Setup](#setup) |
| `Testing...` | A connection test is running | Wait |
| `Connected` | The last sync succeeded | Nothing |
| `Connected (N stale camera binding(s) - see Actions)` | A camera with a connection is no longer on the console | If it is gone for good, *Prune Missing Camera Bindings* |
| `Refused (HTTP 401) - check the API key` (or 403) | The console answered and rejected the key | Create the key again in UniFi OS and paste it. This is not a network problem |
| `Console error (HTTP N)` | The console answered with an error | Check the console itself and its Protect version |
| `Console unreachable - check the address and network` | The console did not answer at all | Check the address, and that the controller can reach the console |

**Event Stream**

| It reads | Meaning |
| --- | --- |
| `Off` | Not configured, or the key was forgotten |
| `Connecting...` | Opening the stream |
| `Connected` | Live events are arriving |
| `Reconnecting...` | The stream dropped; the next attempt is 30 seconds away |
| `Failed to start` | The stream could not be created. The reason is in the log |

**Relay Status**

| It reads | Meaning |
| --- | --- |
| `Off` | The relay is not listening. If **Snapshot Relay** is On, set it Off and On again: a key pasted after the driver started does not start the relay by itself |
| `Serving http://…/snapshot/<camera>` | Working. This is the address the cameras are given |
| `Listening on port N - set Relay Address to the controller's IP` | The controller's address could not be found in the project. Type it into **Relay Address** |
| `Failed to listen on port N` | The port could not be opened. Choose another **Relay Port** |

## Troubleshooting

**A device driver's Gateway Link stays on "waiting for a reply".** Its
connection is not bound to the Gateway, or the Gateway is missing or running
an older build. *Print Camera Bindings To Log* shows what is bound to what.

**Auto Provision prints `FAILED to add`.** The controller does not have that
driver file. Load it once with Driver > Add or Update Driver and run the
action again.

**Auto Provision left a device with its default name.** The device driver
renames itself when the Gateway next answers it. For a camera, its own
*Rename From Camera* action does it at once.

**Counts look stale after a reboot.** When **Last Sync** ends in `(cached)`,
the counts are the last-known inventory, shown until the first sync lands.

## Licence

The Gateway registers with the SmartBuildOS Agent in the project and shows
the answer in **License Status**: `No SmartBuildOS Agent Found`,
`SmartBuildOS Agent Found - Not Linked` (add and pair the Agent), `Checking...`,
then `Licensed / Subscribed`, `Licensed / Permanent`, `Licensed / Grace`, or
the reason it is not.

The driver runs with or without the Agent. Three things are refused, and only
when SmartBuildOS has switched enforcement on for this driver **and** the
Agent's answer is a definite "not licensed" (**License Status** then ends in
`(read-only)`):

- control commands sent by the device drivers (their **Last Control** shows
  the reason),
- *Auto Provision Protect Devices*,
- **SmartBuildOS Reporting**.

Live video, events, status and the Gateway's own commands keep working in
every case. An uncertain answer (no Agent, an Agent that is not signed in, a
licence service that cannot be reached) is never treated as "not licensed".

## What is not claimed

- **No recorded video.** Recordings are not on the official API. Use the
  Protect app.
- **No storage, CPU or temperature health** for the console: not on the
  official API.
- **Chimes** are counted and watched for going offline, nothing more.
  **Sirens, relays and alarm hubs** have commands and events but no device
  driver and no connections.
- *Siren Started* and *Siren Stopped* follow this driver's own commands. A
  siren started in Protect, or one that stops when its time runs out, fires
  neither.
- *Device Offline* and *Device Online* do not say which device.
- Alarm state is read at each sync, so *Armed*, *Disarmed* and *Breach
  Detected* can trail the console by up to one **Device Poll Interval**. The
  driver does not remember a breach across a restart: a breach time still on
  the console when the driver starts fires *Breach Detected* once more.
- *Prune Missing Camera Bindings* covers cameras only. A sensor, floodlight
  or viewport connection stays once created.
- A connection keeps the name the device had when it was first seen; renaming
  the device in Protect does not rename the connection. The device drivers do
  follow the new name.
- More than one console in one project is not verified. Each device driver
  also looks the Gateway up by its driver file, and finds the first one.
- The driver's log lines do not print the API key. **Webhook Token** is an
  ordinary property and is visible in Composer.
- What SmartBuildOS does with the device list from **SmartBuildOS Reporting**
  is outside this driver.

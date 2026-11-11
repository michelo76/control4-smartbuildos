# UniFi Protect Camera

Puts one UniFi Protect camera or doorbell in Navigator (touchscreens,
on-screen and the Control4 app) and gives programming what Protect sees on
it: motion, a person, a vehicle, a package, a press of the doorbell button.
It works with the **UniFi Protect Gateway** driver, which owns the console
connection; this driver holds no credentials at all.

Add one instance per camera. It needs the Gateway in the same project,
connected to the console, and Control4 OS 3.3.2 or later.

## What it is for

| You want | Use |
| --- | --- |
| The camera's live picture on touchscreens and in the app | The driver itself, once bound. Choose the picture with **Stream Protocol** and **Streams Offered** |
| Lights for a person on the drive, not for every moving branch | *Person Detected* rather than *Motion Detected* |
| An announcement or a picture on a screen when someone rings | *Doorbell Ring* |
| A photo on the phone when a package arrives | *Package Detected* with `Send Snapshot Notification` |
| Something that lasts as long as the motion does | *Motion Detected* and *Motion Ended*, or the variable `MOTION_DETECTED` |
| To react when the camera hears a smoke alarm or breaking glass | *Audio Alarm Detected* and `LAST_AUDIO_TYPE` |
| A welcome for someone who used their fingerprint or NFC card | *Known Person Detected* and `LAST_PERSON` |
| A note on the doorbell's display | `Set Doorbell Message`, `Leave Package`, `Do Not Disturb` |
| Detections in Control4's History view | **History** |
| To know this camera dropped off | *Camera Offline*, or the conditional *Camera online status* |
| A PTZ camera sent to a preset by programming | `Run PTZ Preset` |

## Setup

<!-- walkthrough: Add a camera -->
1. Install the **UniFi Protect Gateway** first and confirm it shows
   Connected.
1. Add the camera driver. The quick way is the Gateway's *Auto Provision
   Protect Devices* action, which adds and binds one instance for every
   camera. By hand: add one instance of this driver per camera, and place
   each in a room.
1. If you added it by hand, open the **Connections** view and bind the
   instance's **Protect Camera** connection to one of the Gateway's camera
   connections (named after the cameras it found).
1. Check the Properties tab. **Gateway Link** reads `OK - identified as`
   followed by the camera's name, **Camera** shows that name and **Camera
   State** reads `CONNECTED`. The device is renamed after the camera.
1. Open the camera in Navigator. The first view fetches stream URLs from the
   console through the Gateway, and **Streams** then lists the qualities it
   got, for example `high, medium, low`.
1. In Protect, turn on the smart detections you want on this camera.
   Detections fire only for what the camera itself is configured to detect.
1. Walk in front of the camera. The Gateway's **Last Event** shows the event
   arriving, and this driver's events fire.

## Stream protocol and resolution

The Gateway asks the console for this camera's stream addresses and switches
on any of the three qualities (high, medium, low) that Protect does not have
yet, so there is nothing to enable per camera in Protect.

**Stream Protocol** defaults to RTSP (port 7447) because that is what Control4
clients actually play. The property's own note records the measurement:
2026-08-28, OS 4.2.1 against Protect 7.2.105, RTSPS rendered a black tile and
RTSP played. RTSPS (port 7441) remains selectable; try it after OS or Protect
updates, and prefer it if it works. If both render black, use *Print Stream
URLs To Log* and test the URLs in VLC to see which side is refusing.

**Streams Offered** is the resolution selector. Control4 clients pick from the
offered stream list silently (there is no picker in the app), so narrowing the
offer to `High only`, `Medium only` or `Low only` is how you choose what
plays. High is the camera's full recording quality; Low keeps a wall of
cameras light. If the chosen quality does not exist on the console,
everything available is offered instead of nothing.

Changing either property tells Navigators to fetch the addresses again.

## Snapshots

Still images come through the Gateway's snapshot relay. When the relay is
running, **Snapshots** reads `Available via gateway relay`, and the driver
gives that address to Navigator when it asks for a snapshot and to the
Control4 notification system for the **Camera Snapshot** attachment (the
high-quality image). When **Snapshots** reads `-`, check **Relay Status** on
the Gateway.

## Events and variables

Events arrive live from the console (no polling: the Gateway holds an event
stream).

| Event | Fires when | Spaced by |
| --- | --- | --- |
| *Motion Detected* | Protect starts a motion event on this camera | **Motion Event Cooldown (seconds)** |
| *Motion Ended* | That motion event ends | Not spaced |
| *Person Detected*, *Vehicle Detected*, *Package Detected*, *Animal Detected*, *License Plate Detected*, *Face Detected* | Protect reports a smart detection of that type. A detection of two types fires both | **Detection Event Cooldown (seconds)**, each type on its own |
| *Line Crossed*, *Loitering Detected* | Protect reports a line crossing or loitering | **Detection Event Cooldown (seconds)** |
| *Audio Alarm Detected* | The camera hears an alarm sound (smoke or CO alarm, siren, glass break and similar) | **Detection Event Cooldown (seconds)** |
| *Doorbell Ring* | The doorbell button is pressed | Not spaced |
| *Known Person Detected* | A fingerprint or NFC card at this doorbell belongs to an active, named user on the console | Not spaced |
| *Unknown Person Detected* | A fingerprint or NFC card the console does not recognise | Not spaced |
| *Camera Online*, *Camera Offline* | The Gateway's sync sees the camera reconnect or disconnect | Not spaced |
| *Snapshot Notification* | The `Send Snapshot Notification` command runs | Not spaced |

**Cooldowns.** A busy camera reports motion almost continuously. A cooldown
is the minimum number of seconds between two firings of the same event
(default 3; 0 turns it off). It spaces the events and their History entries
only: the variables below are updated every time.

| Variable | Holds |
| --- | --- |
| `MOTION_DETECTED` | True from the start of a motion event to its end |
| `LAST_MOTION`, `LAST_RING` | When motion last started, when the doorbell was last pressed |
| `LAST_DETECTION` | The last detection type: `person`, `vehicle`, `package`, `animal`, `licensePlate`, `face` |
| `LAST_PERSON_TIME`, `LAST_VEHICLE_TIME`, `LAST_PACKAGE_TIME`, `LAST_ANIMAL_TIME` | When that type was last detected. `LAST_PERSON_TIME` is also set by *Known Person Detected* |
| `LAST_PERSON` | The name from the last *Known Person Detected* |
| `LAST_LICENSE_PLATE` | The plate text, when the console sends it |
| `LAST_AUDIO_TYPE` | The kind of alarm sound, in the console's own word (for example `alrmSmoke`) |
| `LAST_EVENT`, `LAST_EVENT_TYPE`, `LAST_EVENT_TIME` | The name of the last detection event, its detail (the type, or the person's name) and when |

Times are the controller's own, as `YYYY-MM-DD HH:MM:SS`. Variables are set
before the event fires, so programming on the event can read them.

### History

**History** writes this camera's events into Control4's History view (it
needs the History Agent).

| Setting | Records |
| --- | --- |
| `Smart detections only` (default) | Everything except plain motion: detections, doorbell rings, audio alarms, known and unknown persons, online and offline |
| `All events` | The same, and motion |
| `Off` | Nothing |

An event held back by its cooldown is not recorded either. Audio alarms,
unknown persons and *Camera Offline* are recorded as warnings.

## Worked examples

### A package photo on the phone

<!-- walkthrough: Send a snapshot when a package arrives -->
1. Once: create a push notification that carries this camera's **Camera
   Snapshot** attachment, and trigger it from this camera's *Snapshot
   Notification* event.
1. In Programming, pick this camera's event *Package Detected*.
1. Add this camera's command `Send Snapshot Notification`. Type `Package at
   the door` in `Message` and `Info` in `Severity`.
1. Use the same command anywhere else you want a picture sent: after
   *Doorbell Ring*, after *Person Detected* at night.

The command adds a Snapshot Notification entry to History and fires
*Snapshot Notification*; the notification you paired with that event carries
the picture. Put the words the homeowner should read in that notification:
`Message` goes to the driver's log, and into the History entry only on
controllers that accept the detailed form of an entry.

### Lights for a person, at night only

Pick *Person Detected*. Add your own check that it is night, and inside it
the exterior lights. If the routine should not run again while the same
person lingers, raise **Detection Event Cooldown (seconds)** to 60: the event
then fires at most once a minute, while `LAST_PERSON_TIME` still follows
every detection.

### The doorbell

Pick *Doorbell Ring* and add the announcement or the scene. To answer on the
display, add `Set Doorbell Message` with `Message` set to `On my way` and
`Duration` set to 30: the text shows and the console is told to put the
display back after 30 seconds. With a UniFi Protect Viewport in the project,
add its `Show View Temporarily` command to put the door on that screen.

## Doorbell and camera commands

Commands go to the console through the Gateway, once each. **Last Control**
shows the newest one: `sent`, then `ok`, or `FAILED` with the reason.

| Command | Parameters | What it does |
| --- | --- | --- |
| `Set Doorbell Message` | `Message`, `Duration` | Shows the text on the doorbell display. With a `Duration` in seconds the console is told to revert the display after that time; left empty, no revert is scheduled |
| `Do Not Disturb` | none | Sets the display to Do Not Disturb |
| `Leave Package` | none | Sets the display to Leave Package At Door |
| `Reset Doorbell Display` | none | Puts the display back to its default |
| `Set LED` | `State` | Turns the status LED on for `on`, off for anything else |
| `Set Microphone Volume` | `Volume` | 0 to 100 |
| `Set HDR` | `Mode` | `auto`, `on` or `off` |
| `Set Video Mode` | `Mode` | `default`, `highFps`, `sport` or `slowShutter` |
| `Run PTZ Preset` | `Slot` | Moves a PTZ camera to that preset |
| `Start Patrol` | `Slot` | Starts that PTZ patrol |
| `Stop Patrol` | none | Stops the patrol |
| `Send Snapshot Notification` | `Message`, `Severity` | Adds a Snapshot Notification entry to History (whatever **History** is set to) and fires *Snapshot Notification*. `Severity` is `Info`, `Warning` or `Critical`; anything else counts as `Info` |

A command the camera has no hardware for (a display message on a camera
with no display) is sent all the same; the console's answer shows in **Last
Control**.

## Programming reference

- Events: *Motion Detected*, *Motion Ended*, *Person Detected*, *Vehicle
  Detected*, *Package Detected*, *Animal Detected*, *License Plate Detected*,
  *Face Detected*, *Doorbell Ring*, *Audio Alarm Detected*, *Line Crossed*,
  *Loitering Detected*, *Camera Online*, *Camera Offline*, *Known Person
  Detected*, *Unknown Person Detected*, *Snapshot Notification*.
- Conditional: *Camera online status* is Online or Offline
  (`CAMERA_ONLINE`). Online means the console reports the camera as
  `CONNECTED`.
- Variables: `MOTION_DETECTED`, `LAST_MOTION`, `LAST_DETECTION`,
  `LAST_LICENSE_PLATE`, `LAST_AUDIO_TYPE`, `LAST_RING`, `LAST_EVENT`,
  `LAST_EVENT_TYPE`, `LAST_EVENT_TIME`, `LAST_PERSON`, `LAST_PERSON_TIME`,
  `LAST_VEHICLE_TIME`, `LAST_PACKAGE_TIME`, `LAST_ANIMAL_TIME`.
- Commands: the twelve in the table above.

## Properties

| Property | What it is |
| --- | --- |
| **Camera**, **MAC Address** | Which Protect camera this instance is. `Not bound` until the Gateway answers |
| **Camera State** | `CONNECTED`, `CONNECTING`, `DISCONNECTED`, or `UNKNOWN` until the Gateway says |
| **Gateway Link** | The conversation with the Gateway. See below |
| **Capabilities** | What the camera reports it can do, when the Gateway passes that on |
| **Last Control** | The newest command and its outcome |
| **Motion Event Cooldown (seconds)**, **Detection Event Cooldown (seconds)** | See Cooldowns. Default 3 |
| **Snapshots**, **Streams** | Whether a snapshot address is known; which stream qualities the console gave |
| **Stream Protocol**, **Streams Offered** | See [Stream protocol and resolution](#stream-protocol-and-resolution) |
| **History** | What is written to Control4's History view |
| **Driver Status**, **Driver Version** | **Driver Version** is the build actually running |
| **Log Level**, **Log Mode** | Logging. **Log Mode** turns itself Off after 3 hours |

## Actions

| Action                   | What it does                                                      |
| ------------------------ | ----------------------------------------------------------------- |
| Print Diagnostics To Log | Version, device ids, Gateway found or not, identity, state        |
| Refresh Camera Info      | Re-asks the Gateway which camera this is                          |
| Rename From Camera       | Renames the device after the camera, even over a name you typed   |
| Refresh Stream URLs      | Re-fetches stream URLs from the console via the Gateway           |
| Print Stream URLs To Log | Logs each quality's URL, as stored and as delivered to Navigators |
| Forget Camera            | Clears identity and cache, then re-asks over the current binding  |

## Reading the status

| Property | It reads | Meaning |
| --- | --- | --- |
| **Gateway Link** | `Not bound - bind the Protect Camera connection to the Gateway` | The driver has not asked yet |
| **Gateway Link** | `Asked gateway at … - waiting for a reply` | The driver asked which camera it is. Until it knows, it asks again every minute. If this never changes, the Gateway is missing, unbound, or running an old driver version |
| **Gateway Link** | `OK - identified as …` | Bound and answered |
| **Streams** | `-` | No one has opened the camera yet. Open it, or run *Refresh Stream URLs* |
| **Streams** | `unavailable - …` | The Gateway could not get addresses; the reason follows (not bound, Gateway not configured, or the console's refusal) |
| **Last Control** | `… FAILED - …` | The console or the Gateway refused the command; the reason follows |

A black tile with **Streams** listing qualities is a playback problem, not a
connection problem: try the other **Stream Protocol**.

## Auto-naming

Once bound, the instance renames itself (protocol and proxy device) after the
camera's name in Protect, and follows Protect renames. It never overwrites a
name you typed yourself: the driver only renames while the device still has
the install default or the name the driver set last. *Rename From Camera* is
the deliberate override.

## Behavior worth knowing

- Stream URLs are revocable tokens minted by the console. The driver caches
  them for 12 hours and tells Navigators to refresh whenever they change.
  *Print Stream URLs To Log* writes them out in full: do not share that log.
- The camera's online state comes from the Gateway on every poll, and drives
  the conditional and the *Camera Online* and *Camera Offline* events. The
  first state learned after a restart fires nothing.
- Unbinding does not blank the camera: identity survives a project reshuffle.
  *Forget Camera* is the deliberate reset, for re-purposing an instance.
- Events reach this driver only while it is bound and the Gateway's **Event
  Stream** is connected. Nothing is queued for later.

## What is not claimed

- **No recorded video.** Live streams and stills only; recordings stay in the
  Protect app.
- **No pan, tilt or zoom controls in Navigator.** PTZ is presets and patrols,
  by programming command.
- **No talkback or intercom audio.**
- *Face Detected* means Protect saw a face, not whose. A name comes only from
  a fingerprint or NFC card (*Known Person Detected*).
- `LAST_LICENSE_PLATE` is filled only if the console includes the plate text
  in the event. The project's notes on the official API say it does not yet.
- **Capabilities** stays `-` on this build: the Gateway's answer does not
  carry the list, so no command is held back for missing hardware and the
  console decides.
- The RTSP port (7447) is not documented by Ubiquiti and may disappear in a
  future Protect version; RTSPS is then the only option.
- The doorbell's package camera stream is not requested.
- Snapshots in a push notification and in Navigator depend on the Gateway's
  relay being reachable from the device that shows them. Neither has a bench
  record in this project yet.

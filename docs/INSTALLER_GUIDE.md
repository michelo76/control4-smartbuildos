# UniFi Protect for Control4 (SBOS) — Installer Guide

Build `20260828.193057` · Five drivers · Official Ubiquiti API only ·
No licence, no cloud, no passwords stored.

## What this is

A driver suite connecting UniFi Protect to Control4 as if it were native:
live video, snapshots, AI detections, doorbell control, sensors,
floodlights, viewports, the Protect alarm system, and two-way webhooks —
built entirely on Ubiquiti's **official** Integration API with a single
API key. No admin password ever touches the controller, MFA stays on, and
nothing breaks when Protect updates its unofficial internals.

| Driver | One per | Puts in the project |
| --- | --- | --- |
| **UniFi Protect Gateway (SBOS)** | console | The connection, inventory, alarm, sirens/relays, webhooks, snapshot relay |
| **UniFi Protect Camera (SBOS)** | camera | The Navigator camera: streams, snapshots, detections, doorbell controls |
| **UniFi Protect Sensor (SBOS)** | sensor | Contact + motion bindings, readings, thresholds |
| **UniFi Protect Light (SBOS)** | floodlight | On/off/mode commands, motion events |
| **UniFi Protect Viewport (SBOS)** | viewport | Live-view control incl. temporary show-and-restore |

## Requirements

- Control4 OS **3.3.2+** (developed and field-tested on 4.2.1)
- UniFi Protect **5.3+** for the basics; **7.x** for alarm, sirens,
  relays, hubs, and known-person identity (tested against 7.2.105)
- Console reachable from the controller on the LAN
- An **API key**: UniFi OS → Settings → Control Plane → Integrations →
  Create API Key (admin account; MFA can stay enabled)

## Install — the 10-minute version

1. **Load the drivers onto the controller once**: Composer → Driver →
   *Add or Update Driver or Agent* → select all five `.c4z` files
   together. (Copying files into the Drivers folder is not enough —
   auto-provision pulls from the controller's own driver database.)
2. Add **UniFi Protect Gateway (SBOS)** to the project.
3. **Console Address** = the console's IP (bare IP is fine).
4. Paste the **API Key**. The field clears itself — that means it was
   accepted and stored encrypted. Connection Status → `Connected`, and
   the Cameras/Sensors/Lights counts fill in.
5. Run **Auto Provision Protect Devices** (Actions). Every discovered
   device gets its child driver added *and bound* automatically. Move the
   new devices into their rooms.
   - *Current beta quirk:* instances may keep the default driver name —
     run **Rename From Camera** on each, or wait for the automatic rename
     on the next identity handshake.
6. Open a camera in the Control4 app: live video should play. Done.

Re-running Auto Provision is always safe: it only adds devices whose
connection has nothing bound, and it never deletes anything.

## The Gateway, room by room

**Connection**: Console Address · API Key (letterbox — never stored in
the project file) · Verify TLS Certificate (leave Off for the console's
self-signed cert) · Device Poll Interval (default 1m).

**Status**: Protect Version · NVR Name · per-kind counts · Arm Mode /
Arm Profile · Offline Devices · Last Event · Event Stream (the live
websocket — should read `Connected`) · Last Sync · Driver Version (what
is *actually running* — if it doesn't match your newest build, the
project is serving a cached driver copy).

**Snapshot relay**: the console's snapshot endpoint needs the API key,
which Navigators can't send — so the Gateway serves
`http://<controller>:47800/snapshot/<camera-id>` on the LAN, fetching
with the key. Relay Status tells you if the auto-detected address needs
the **Relay Address** override. This feeds thumbnails, notification
images, and nothing else — unknown paths get 404s.

**Webhooks in** (Protect → Control4): point an Alarm Manager webhook at
`http://<controller>:47800/webhook/<any-name>?token=<Webhook Token>`.
Fires **Custom Webhook Received** with `LAST_WEBHOOK_NAME`. Wrong token =
404; 2-second per-name flood guard.

**Webhooks out** (Control4 → Protect): the **Trigger Protect Webhook**
command fires an Alarm Manager trigger by ID — Control4 programming
driving Protect automations.

**The alarm** (Protect 7.x): Arm Mode and profile are read from the
console every poll. Commands: **Arm With Profile** (name or blank for
current), **Disarm**, **Select Arm Profile**. Events: Armed, Disarmed,
Arm Profile Changed, **Breach Detected**. Profile names are discovered —
run *Print Arm Profiles To Log* to see them.

**Sirens / relays / alarm hubs**: Play/Stop/Test Siren, Activate Relay,
Trigger Hub Output — all marked SECURITY in their descriptions, and none
of them ever retries: a timeout is reported, never re-fired. Alarm-hub
sensors (entry, glass break, smoke, tamper…) fire as Gateway events.

**SmartBuildOS Reporting** (default Off): hands the device roster to the
SmartBuildOS Connector in the project — the on-ramp for cameras in the
equipment registry and offline-camera service tickets.

## The Camera, room by room

**Identity**: binds to a Gateway camera connection; **Gateway Link**
narrates the handshake (`OK - identified as 'Front Door'`). Auto-names
itself and follows Protect renames — but never overwrites a name a
dealer typed; **Rename From Camera** is the deliberate override.

**Streams**: **Stream Protocol** defaults to RTSP port 7447 because
that's what Control4 clients actually play (RTSPS rendered black on OS
4.2.1 — measured, not assumed; try RTSPS again after OS updates).
**Streams Offered** is the resolution selector — Navigators pick silently
from what's offered, so *High/Medium/Low only* IS the picker.

**Detections** → Composer events: Motion (start/end), Person, Vehicle,
Package, Animal, License Plate, Face, Line Crossed, Loitering, Audio
Alarm (smoke/CO/siren/glass/bark…), Doorbell Ring, Camera Online/Offline,
**Known/Unknown Person** (fingerprint/NFC, resolved to real names from
the console's identity store). Variables: `LAST_EVENT` /
`LAST_EVENT_TYPE` / `LAST_EVENT_TIME`, per-type `LAST_*_TIME`,
`LAST_PERSON`, `LAST_LICENSE_PLATE`, `MOTION_DETECTED`, and more.

**Cooldowns**: Motion / Detection Event Cooldown properties space event
*firing* (default 3 s) so a busy driveway doesn't spam programming —
variables always stay current.

**History**: detections land in Control4's History view (requires the
History Agent). The **History** property picks the appetite — *Smart
detections only* by default, because plain motion is a timeline of
nothing.

**Doorbell + settings commands** (capability-gated — a camera without
the hardware refuses locally and says so in **Last Control**): Set
Doorbell Message (with auto-revert), Do Not Disturb, Leave Package,
Reset Display, Set LED, Set Microphone Volume, Set HDR, Set Video Mode,
Run PTZ Preset, Start/Stop Patrol.

**Send Snapshot Notification** (Message, Severity): one command that
writes History and fires the *Snapshot Notification* event — pair that
event once with a push notification carrying the **Camera Snapshot**
attachment, and every future use sends the picture.

## Sensors, Lights, Viewports

- **Sensor**: Contact and Motion CONTACT_SENSOR connections (motion
  active = closed) usable by the Security agent; temperature/humidity
  **threshold events that fire once per crossing**; leak, tamper, CO
  fault, battery, button events; readings as variables.
- **Light**: Light On / Light Off / Set Light Mode
  (always·motion·off, at fulltime·dark); Motion Detected events.
- **Viewport**: Set Live View, Next/Previous, and **Show View
  Temporarily (View, Seconds)** — shows a view and then restores whatever
  was up; overlapping doorbell rings keep the *original* restore target.

## Five programs worth writing on day one

1. **Doorbell → TV**: *Doorbell Ring* → Viewport *Show View Temporarily*
   "Front Door", 20.
2. **Package photo to the phone**: *Package Detected* → *Send Snapshot
   Notification* "Package at the door" → push with Camera Snapshot
   attachment.
3. **Away = armed**: Control4 Away scene → *Arm With Profile* "Away";
   *Breach Detected* → lights 100%, sirens, announce.
4. **Night perimeter**: *Person Detected* + house in Night → exterior
   lights scene.
5. **Known face at the door** (fingerprint/NFC doorbells): *Known Person
   Detected* → announce `LAST_PERSON`.

## Troubleshooting

- **Every driver prints its story**: *Print Diagnostics To Log* on any
  child; *Print Inventory / Camera Bindings / Arm Profiles / Security
  Devices* on the Gateway.
- **Gateway Link stuck "waiting"** → the Gateway is missing, unbound, or
  running an old build (check its Driver Version).
- **`Refused (HTTP 401)`** = bad/revoked API key. **`unreachable`** =
  network. The driver never confuses the two.
- **Updated but nothing changed** → Driver Version property is the truth.
  Composer serves a *project-embedded* driver copy: Update Driver on one
  instance refreshes it for all; a restart of Composer clears its UI
  caches (the programming panel's event list is a known laggard).
- **Black tile** → try the other Stream Protocol; *Print Stream URLs To
  Log* and test in VLC to see which side refuses.
- The commercial UniFi drivers may coexist in your driver database —
  ours are the ones suffixed **(SBOS)**. Never mix suites on one console.

## Security posture (the sales paragraph)

API-key-only (created without disabling MFA), stored encrypted on the
controller, never written to the project file, never logged. Children
hold no credentials at all. The snapshot relay serves only known camera
ids on the LAN; webhooks require a shared secret. Siren/relay/arm
commands execute exactly once — retry storms cannot happen. Everything
rides documented Ubiquiti endpoints, inventoried in
`UBIQUITI_API_MATRIX.md`, so a Protect update is a diff, not an outage.

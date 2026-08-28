# UniFi Protect Camera

Puts one UniFi Protect camera in Navigator — touchscreens, on-screen, and the
Control4 app. Works with the **UniFi Protect Gateway** driver, which owns the
console connection; this driver holds no credentials at all.

## Setup

1. Install the **UniFi Protect Gateway** first and confirm it shows Connected.
1. Add one instance of this driver per camera, and place each in a room.
1. In the **Connections** view, bind each instance's **Protect Camera**
   connection to one of the Gateway's camera connections (named after the
   cameras it found).
1. The **Camera** property fills in with the camera's name. Open the camera in
   Navigator — the first view fetches stream URLs from the console through the
   Gateway.

## If the tile is black

Protect's native stream is RTSPS (encrypted, port 7441). If a touchscreen shows
a black tile on the default setting, switch **Stream Protocol** to **RTSP
(unencrypted, port 7447)** — the same stream without encryption. Note the RTSP
port is undocumented by Ubiquiti and may be absent on some Protect versions; if
both fail, use **Print Stream URLs To Log** and test the URLs in VLC to see
which side is refusing.

## Automation: events and variables

Live from the console (no polling — the Gateway holds an event stream):

- **Events** for Composer programming: Motion Detected/Ended, Person, Vehicle,
  Package, Animal, License Plate, Face, Doorbell Ring, Audio Alarm (smoke/CO
  siren, glass break, and similar), Line Crossed, Loitering, Camera
  Online/Offline.
- **Variables** to branch on: `MOTION_DETECTED`, `LAST_MOTION`,
  `LAST_DETECTION`, `LAST_LICENSE_PLATE`, `LAST_AUDIO_TYPE`, `LAST_RING`.

Detections fire only for what the camera itself is configured to detect in
Protect — enable the smart detections you want on the camera first.

## Auto-naming

Once bound, the instance renames itself (protocol and proxy device) after the
camera's name in Protect, and follows Protect renames. It never overwrites a
name you typed yourself: the driver only renames while the device still has the
install default or the name the driver set last.

## Behavior worth knowing

- Stream URLs are revocable tokens minted by the console. The driver caches them
  and tells Navigators to refresh whenever they change.
- The camera's online state comes from the Gateway on every poll, and drives the
  **camera online** conditional for programming.
- Unbinding does not blank the camera — identity survives a project reshuffle.
  **Forget Camera** is the deliberate reset, for re-purposing an instance.
- Snapshots and PTZ are not in this version; live streams are.

## Actions

| Action                   | What it does                                                      |
| ------------------------ | ----------------------------------------------------------------- |
| Refresh Camera Info      | Re-asks the Gateway which camera this is                          |
| Refresh Stream URLs      | Re-fetches stream URLs from the console via the Gateway           |
| Print Stream URLs To Log | Logs each quality's URL, as stored and as delivered to Navigators |
| Forget Camera            | Clears identity and cache, then re-asks over the current binding  |

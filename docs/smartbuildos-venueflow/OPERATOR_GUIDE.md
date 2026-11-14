# VenueFlow operator guide

For the people who run the venue: bartenders, hosts, managers, meeting-room
users. One page for each screen. Your installer decides which screens your
profile has.

## Opening VenueFlow

Tap the **VenueFlow** tile on the Control4 touch screen, or in the Control4
app on a phone or tablet at the venue.

The screen opens straight away as the profile your installer chose for it
(for example "Bartender"). The name is in the top right corner.

**Signing in with a PIN** (managers): tap the profile name in the top right,
choose your profile, type your PIN. The screen now shows what your profile
may see. Tap the name again and "Sign out" when you leave. Five wrong PINs
lock that screen's sign-in for a minute.

A strip across the top saying **Simulation** means the system is in
demonstration mode: nothing you tap changes the real room. Tell your
installer.

## What the marks mean

Every display and audio zone shows what the system actually knows.

| You see | It means | What to do |
| --- | --- | --- |
| A steady source name, **On** | Control4 confirmed it | Nothing |
| A pulsing mark, "Working" | Your request was sent; the answer is on its way | Wait a few seconds |
| **Sent** | This device cannot report back | Look at the screen in the room |
| **Not confirmed** (amber) | The change did not happen, or cannot be confirmed | Check the TV is on; try again; tell a manager |
| **Unknown** | The system has not read this device yet | Try again in a moment |
| **Offline** | The device is not responding | Tell a manager |

If you change six TVs and two do not change, the screen tells you which two.
It never says "done" for something it could not confirm.

## Floor Plan

The venue from above, with each TV where it hangs.

1. **Tap the TVs** you want. Selected TVs get a bright outline. Tap again to
   deselect. Tap an area's name to select every TV in it, or use a group
   button. **Clear** deselects all.
2. **Pick a source** on the right.
3. Tap **Route Video**.
4. To hear it too, turn on **Listen** and choose the audio zone before you
   route. Without it, the sound in the room does not change.

**Power On / Off** switches the selected TVs. The bar along the bottom has
the scene shortcuts and the volume for an audio zone. If the venue has more
than one floor, switch floors at the top.

## Command Center

The fastest way to change several TVs.

1. **Select displays**: tick the tiles. Use the filter buttons (an area or a
   group) and **Select All** to pick many at once.
2. **Choose source**.
3. **Route**: the large button says how many displays it will change.

**Source first** (the switch above the grid): pick a source, then every TV
you tap changes to it at once. Good for moving one game around the room.

**Audio follow**: choose a zone to send that source's sound there as well.
"No audio change" leaves the sound alone.

The **audio zones** row at the bottom: for each zone, the source playing, the
volume slider, mute, and off. The slider stops at the level your installer
set as the maximum for that zone.

## Room Control

For a meeting room or a small space: a few large buttons.

- Tap **Present Laptop**, **Video Conference**, **Watch TV** or whatever your
  room has. The room sets itself up: displays, sound, lights, shades.
- **Room Off** turns the room off.
- Below: volume and mute, the lighting presets, and shades Open / Close, when
  the room has them.

The strip in the middle shows the current mode and what is on.

## Manager

A summary of the whole venue.

- **The numbers** at the top: displays, how many are on, audio zones, how
  many things need attention, the active scene.
- **Alerts**: each says what is wrong in plain words and has a button.
  **Resolve** re-checks the display with Control4; if the display is really
  showing the right thing, the alert clears. **Unmute** unmutes a zone.
  **Dismiss** removes a notice you have read.
- **Scenes**: what each does, and **Activate**. A scene that switches things
  off shows you what it will do and asks you to confirm.
- **Open venue / Close venue**: marks the venue open or closed. Some scenes
  and schedules only run when the venue is open.
- **All Off**: shows what will be switched off (how many displays, how many
  audio zones, which scene is running), then asks you to confirm.
- **Recent activity**: what was changed, by which screen, and how each device
  answered.

## Scenes

A scene is one button that sets many things (Game Day, Happy Hour, Closing).
After you tap it, the scene's steps run in order and the screen shows them
finishing. If one TV does not answer, the scene finishes the rest and tells
you which TV did not.

"The scene's condition is not met right now" usually means the venue is
marked closed: a manager opens the venue first.

## When something is wrong

| What you see | What to do |
| --- | --- |
| "Cannot reach the controller" | Check the screen is on the venue's wireless network. It reconnects by itself |
| "Your profile is not allowed to do that" | That control belongs to another profile. Ask a manager |
| "That source cannot be shown here" | That TV is not connected to that source. Pick another TV or source |
| "Choose a source to turn this display on" | Select the TV, pick a source and route it: that turns it on |
| A TV stays "Not confirmed" | Check it has power and is on its usual input. A manager can press Resolve |
| The sound changed when you changed a TV | Tell your installer: that TV and that speaker zone are set up as one room |
| "This feature needs a SmartBuildOS licence" | Scenes and schedules are paused. You can still change TVs, volume and power by hand. Tell the owner |
| "This venue has not been set up yet" | The installer has not finished. Nothing is wrong with the screen |
| Everyone was signed out | The system restarted. Sign in again with your PIN |

You cannot break the installation from these screens. The worst a wrong tap
does is put the wrong picture on a TV; tap again to change it back.

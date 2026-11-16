# Bond Keypad

One instance per Bond Sidekick remote (SKN-386, Mate Pro and similar). It
brings the Sidekick's key presses into Control4: an event for every tap,
double tap and hold of each key, button link connections so a key can drive
a Control4 light directly, and the remote's battery level with events when it
runs low. It has no tile in Navigator.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond the Sidekick is paired with, and the Gateway's push updates working. The
Bond reports key presses only over its push connection, so when the Gateway's
**Push Status** does not read `Delivering`, Sidekick keys do not reach
Control4.

## Setup

<!-- walkthrough: Add a Sidekick -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected` and its **Push Status** reads `Delivering`.
1. A Sidekick not yet paired with the Bond: run the Gateway's *Learn New
   Sidekick* action and, within 60 seconds, press any key on the Sidekick near
   the Bond. Then run the Gateway's *Sync Devices Now*.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each Sidekick, binds it and names it after the Sidekick. To do it by
   hand instead, add this driver and, in Connections, bind its **Bond Keypad**
   connection to the Sidekick's connection on the Gateway.
1. Check **Bond Device**: it shows the Sidekick's name. **Gateway Link** reads
   `OK - identified as` and the name. **Keys** shows how many keys the Bond
   reports for it.
1. Press a key. **Last Button** shows the key, the gesture and the time, for
   example key 2, `Tap`.

## What a press gives you

Each of the first eight keys has three surfaces.

| Gesture on key N | Event | Connection |
| --- | --- | --- |
| Tap | *Button N - Tap* | **Button N Tap Link** clicks |
| Double tap | *Button N - Double Tap* | **Button N Double Tap Link** clicks |
| Hold begins | *Button N - Hold Start* | **Button N Hold Link** is pushed |
| Hold ends | *Button N - Hold End* | **Button N Hold Link** is released |

Because the hold link is pushed when the hold starts and released when it
ends, a held Sidekick key can ramp a bound Control4 dimmer the way a held
keypad button does.

The variables hold the most recent press for any key:

- `LAST_BUTTON`: the key number.
- `LAST_EVENT`: `TAP`, `DOUBLE_TAP`, `HOLD_START`, `HOLD` or `HOLD_END`.
  While a key is held the Bond repeats `HOLD`; the driver updates the
  variables for it but fires no event and moves no link.
- `LAST_HOLD_MS`: how long the key has been held, in milliseconds, updated
  during the hold and at its end.

## Battery

**Battery** shows a band and the percentage, for example `OK (90%)`, and
`BATTERY_LEVEL` carries the percentage. The driver sorts the level into three
bands and fires an event when the band changes. The first reading after the
driver starts sets the baseline and fires nothing.

| Level | Band | Event on entering it |
| --- | --- | --- |
| Above 30 | `OK` | *Battery OK* |
| 11 to 30 | `Low` | *Battery Low* |
| 10 or below | `Critical` | *Battery Critical* |

**Signal** shows the signal strength the Bond reports. Battery and signal
are read when the Gateway syncs, not at each key press.

## Programming

- Events: *Button 1 - Tap* through *Button 8 - Hold End* (four per key),
  *Battery OK*, *Battery Low*, *Battery Critical*.
- Variables: `LAST_BUTTON`, `LAST_EVENT`, `LAST_HOLD_MS`, `BATTERY_LEVEL`.
- Connections: **Button 1 Tap Link** through **Button 8 Tap Link**, the same
  for **Double Tap Link** and **Hold Link**.
- No commands and no conditionals.

## Examples

<!-- walkthrough: Hold a Sidekick key to dim a Control4 light -->
1. In Connections, select this driver.
1. Bind **Button 1 Hold Link** to the button link connection of the Control4
   dimmer that you want held, for example the one that raises the light.
1. If a tap should act too, bind **Button 1 Tap Link** to a button link as
   well. A tap sends it a click.
1. Hold key 1 on the Sidekick. The driver pushes the hold link when the hold
   starts and releases it when the hold ends, which is what a held keypad
   button does, so the dimmer ramps for as long as the key is down.

**A message before the battery dies.** On *Battery Low*, send a notification
to whoever services the site. *Battery Critical* is the second warning. The
events fire when the band changes, so each is sent once, not at every sync.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which Sidekick this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the Sidekick's identity, key count, battery band |
| *Forget Device* | Clears what this instance remembers about its Sidekick and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Keypad** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

Keys that do nothing while **Gateway Link** reads OK point to push: check the
Gateway's **Push Updates** and **Push Status**.

## Limits

- The Sidekick keeps doing its own job on the Bond side, whatever it is
  linked to there. This driver adds Control4 to the listeners; it does not
  take the keypad over.
- A Sidekick is an RF remote. It has no LEDs to follow a state, and a key
  cannot be pressed from software.
- Eight keys are surfaced. A press on a higher-numbered key updates the
  variables only.
- Polling does not carry key presses. Without the push connection there are
  none.
- The driver names itself after the Sidekick only while it still has its
  default name or the name it gave itself. The Gateway's *Auto Rename Bound
  Drivers* renames it regardless.

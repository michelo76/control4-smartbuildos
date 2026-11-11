# Bond Switch

One instance per Bond device that is only on and off: a generic device, a
smart switch, a bidet, a heater with no heat level. It puts the device in
Navigator as one tile whose icon shows `On` or `Off`; a tap toggles it. It
also offers a relay connection, so programming and other drivers can treat
the device as a relay.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond that controls the device. This driver does not talk to the Bond itself:
it gets the device's state from the Gateway and sends its commands through
it.

The Gateway uses this driver for a device only when nothing more specific
fits: the Bond lists `TurnOn` or `TogglePower` for it, and none of the actions
that make it a fan, a shade, a fireplace, a light or a heater with a level. A
heater the Bond can set to a heat level gets the Bond Heater driver instead.

## Setup

<!-- walkthrough: Add a Bond switch -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each such device, binds it and names it after the device. To do it by
   hand instead, add this driver and, in Connections, bind its **Bond Switch**
   connection to the device's connection on the Gateway.
1. Check **Bond Device**: it shows the device's name. **Gateway Link** reads
   `OK - identified as` and the name.
1. Tap the tile in Navigator. **Last Control** shows `TogglePower` and `ok`
   with the time, and **Power** reads `On` or `Off`.

## What works

| You do | The driver sends to the Bond |
| --- | --- |
| Tap the tile | `TogglePower` |
| Close the relay | `TurnOn` |
| Open the relay | `TurnOff` |
| Toggle the relay | `TogglePower` |

Feedback comes from the Gateway each time the Bond reports a change. The
tile's icon and **Power** show `On` or `Off`, and the **Relay Control**
connection reports closed while the device is on and opened while it is off.

## Programming

- Events: *Turned On*, *Turned Off*. They fire on a change; the first state
  received after the driver starts sets the baseline and fires nothing.
- Conditional: `BOND_SWITCH_ON`, shown as Switch power state, `On` or `Off`.
- Variable: `SWITCH_ON`.

| Command | Parameter | What it does |
| --- | --- | --- |
| `Turn On` | | Turns the device on |
| `Turn Off` | | Turns the device off |
| `Set Timer` | `Seconds` | Turns the device off after that many seconds; 0 cancels |

Connections:

- **Relay Control**: bind it where a driver or a piece of programming expects
  a relay. Closed is on, open is off.
- **Toggle Button Link**, **On Link**, **Off Link**: for keypad buttons. A
  click acts. The LEDs of buttons bound to the toggle and on links are lit
  while the device is on; the LED on the off link is lit while it is off.

## Examples

**A device that turns itself off.** In the programming that starts it, add
`Turn On` and then `Set Timer` with `Seconds` 1800. Half an hour later the
device turns off.

**Off when the house is left.** On your away event, add `Turn Off` inside the
conditional `BOND_SWITCH_ON`, so the Bond transmits only when its record says
the device is on.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which device this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the device's identity, power |
| *Forget Device* | Clears what this instance remembers about its device and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Switch** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

**Last Control** reads `FAILED` with the Gateway's reason when a command did
not go through.

## Limits

- Power only. Anything else the device can do is out of this driver's reach;
  the Gateway's `Run Bond Action` command can send any action the Bond lists
  for it.
- The state shown is the Bond's own record of what it last transmitted, not a
  reading from the device. A change the Bond does not know about leaves the
  state wrong until the next command.
- `Set Timer` is sent whether or not the Bond lists the action for this
  device. **Last Control** shows whether the Bond accepted it.
- The driver names itself after the device only while it still has its
  default name or the name it gave itself. The Gateway's *Auto Rename Bound
  Drivers* renames it regardless.

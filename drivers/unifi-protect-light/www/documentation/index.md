# UniFi Protect Light

Brings one UniFi Protect floodlight into Control4 programming: commands to
force it on or off and to set how Protect itself switches it, and an event
when its motion sensor trips.

One instance per Protect floodlight, bound to the UniFi Protect Gateway
(SBOS). The Gateway owns the console connection; this driver holds no
credentials.

## What it is for

| You want | Use |
| --- | --- |
| The floodlight on with a scene: an alarm, a doorbell press, arriving home | `Light On`, then `Light Off` |
| Protect's own motion lighting only after dark, or switched off for a party | `Set Light Mode` |
| Other lights or a camera view that follow the floodlight's motion sensor | *Motion Detected* |
| To know the floodlight dropped off | *Light Offline*, or the conditional *Floodlight online status* |
| The floodlight's state in your own logic | `LIGHT_ON`, `LIGHT_MODE` |

## Setup

<!-- walkthrough: Add a floodlight -->
1. Install the UniFi Protect Gateway (SBOS) first and confirm it shows
   Connected.
1. Run the Gateway's *Auto Provision Protect Devices* action, which adds and
   binds one instance per floodlight. Or add one instance by hand and, in
   Connections, bind its **Protect Light** connection to the Gateway
   connection named after the floodlight.
1. Check the Properties tab. **Gateway Link** reads `OK - identified as`
   followed by the floodlight's name, **Floodlight** shows that name,
   **Light State** reads `CONNECTED`, and the device is renamed after the
   floodlight.
1. On the Actions tab press *Light On*, then *Light Off*. **Last Control**
   reads `light_force: ok` with the time, and the floodlight should come on
   and go off.

## What programming gets

| Command | Parameters | What it does |
| --- | --- | --- |
| `Light On` | none | Forces the floodlight on |
| `Light Off` | none | Turns the forced state off |
| `Set Light Mode` | `Mode`, `EnableAt` | Sets how Protect switches the light by itself. `Mode` is `always`, `motion` or `off`. `EnableAt` is `fulltime` or `dark` |

Commands go to the console through the Gateway, once each. **Last Control**
shows the newest one: `sent`, then `ok`, or `FAILED` with the reason.

| Event | Fires when |
| --- | --- |
| *Motion Detected* | The floodlight's motion sensor trips. Arrives live from the console; `LAST_MOTION` holds the time |
| *Light On*, *Light Off* | A Gateway sync sees the forced state change |
| *Light Online* | A Gateway sync sees the floodlight connected again |
| *Light Offline* | A Gateway sync sees it in any other state |

- Conditional: *Floodlight online status* is Online or Offline
  (`LIGHT_ONLINE`).
- Variables: `LIGHT_ON` (true while the light is forced on), `LIGHT_MODE`
  (the mode the console reports), `LAST_MOTION`.

**Light**, `LIGHT_ON`, *Light On* and *Light Off* describe the **forced**
state, the one `Light On` and `Light Off` set. Whether the lamp is lit by
Protect's own motion mode is not reported. The forced state is read at each
Gateway sync (its **Device Poll Interval**, 1 minute by default), so these
follow a command by up to that long.

## Worked examples

### The floodlight on when the camera sees a person

In Programming, pick the UniFi Protect Camera driver's event *Person
Detected*. Add this driver's `Light On`, a delay of your choosing, then
`Light Off`. The camera's detection decides, not the floodlight's own motion
sensor.

### Motion lighting only after dark

On the event that starts the evening, add `Set Light Mode` with `Mode` set
to `motion` and `EnableAt` set to `dark`. For a party, add `Set Light Mode`
with `Mode` set to `off`, and set it back to `motion` afterwards. **Light
Mode** shows what the console reports at the next sync.

## Properties and actions

| Property | What it is |
| --- | --- |
| **Floodlight**, **Light State** | Which Protect floodlight this is, and `CONNECTED`, `CONNECTING`, `DISCONNECTED` or `UNKNOWN` |
| **Gateway Link** | `Asked gateway at … - waiting for a reply` until the Gateway answers, then `OK - identified as …`. If it never changes, the connection is not bound or the Gateway is missing |
| **Light**, **Light Mode** | The forced state (On or Off) and the mode, as of the last sync |
| **Last Control** | The newest command and its outcome |

| Action | What it does |
| --- | --- |
| Print Diagnostics To Log | Gateway found or not, identity, state |
| Light On, Light Off | The same as the commands |
| Refresh Light Info | Asks the Gateway again which floodlight this is, and picks up a new name |
| Forget Light | Clears the identity, then asks again over the current binding |

The driver names itself after the floodlight while the device still has its
install name or the name the driver gave it. A name you typed is kept.

## What is not claimed

- **No light in Navigator.** The floodlight is not a room light: no tile, no
  dimmer, no place in lighting scenes. It is programming only.
- No brightness, and no setting for how long the light stays on after
  motion. Those stay in the Protect app.
- *Light On* and *Light Off* come from the sync and follow the forced state
  only: they can trail by up to one Gateway poll. The first state learned
  after a restart fires nothing.
- *Motion Detected* fires at the start of motion only, and only while the
  Gateway's **Event Stream** is connected. Nothing is queued for later.
- A rename in Protect is picked up at the next *Refresh Light Info* or driver
  restart, not by itself.

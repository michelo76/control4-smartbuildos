# Bond Bridge Gateway

Connects a Control4 project to one **Bond** unit — a Bond Bridge fronting
RF-controlled ceiling fans, fireplaces, and motorized shades, or a Smart by Bond
appliance — over Olibra's documented Local HTTP API. This is the parent driver:
it owns the Bond connection, the local token, and the device inventory. It
exposes one dynamic connection per device *function*: a ceiling fan with a light
gets a fan connection **and** a light connection, each served by its own child
driver, so each shows up in Navigator as its own device.

Add **one instance per Bond unit**. Everything is local — nothing goes through
the cloud, and nothing needs to be opened on the firewall.

## Requirements

- A Bond Bridge, Bond Bridge Pro, or Smart by Bond device on v2 firmware
  (anything sold in the last several years), reachable from the controller.
- The Bond's **Local Token**, from the Bond Home app: select the Bond,
  **Settings (gear) → Advanced → Local Token**.

## Setup

1. Watch **Discovered Bonds**: the driver searches the network (mDNS) at startup
   and lists every Bond it hears as `id @ address`. On a fresh instance the
   first Bond heard fills in the Bond Address automatically. **Discover Bonds On
   Network** re-runs the search any time.
1. Or set **Bond Address** yourself — the Bond's IP or hostname; a bare IP is
   fine. A configured gateway is never re-pointed by discovery.
1. Paste the token into **Local Token**. The driver stores it encrypted on the
   controller and clears the field — an empty field after pasting means the
   token was accepted. It never sits in the project file in plain text.
   - No app access? Power-cycle the Bond and run the **Fetch Token From Bond**
     action within 10 minutes — the Bond serves its token freely in that window.
1. Watch **Connection Status**. On success the driver reads the Bond's identity,
   pulls the device inventory, and creates the device connections.
1. Run **Auto Configure Bond Devices**. The driver adds the right child driver
   for every discovered device function, binds it, and names it after the
   device. Nothing is ever deleted by this action.

## How devices map

The driver reads each Bond device's *actions* (its real capabilities) and
derives functions from them:

| Bond device               | Control4 result                                       |
| ------------------------- | ----------------------------------------------------- |
| Ceiling fan               | Fan child; plus a Light child if the fan has a light  |
| Motorized shade / awning  | Shade child                                           |
| Fireplace                 | Fireplace child; plus a Light child if it has a light |
| Light / dimmer            | Light child                                           |
| Heater with heat levels   | Heater child (thermostat dial, 0-100 = heat level)    |
| Anything else with on/off | Generic switch child                                  |
| Sidekick remote           | Keypad child (events, button links, battery alerts)   |
| Breeze weather sensor     | Weather child (outdoor temp/humidity for thermostats) |

## State updates

Two paths, both on by default:

- **Push (BPUP)**: the driver subscribes to the Bond's push protocol, so a fan
  speed changed from the factory remote shows in Navigator immediately. **Push
  Status** shows whether push traffic is flowing.
- **Polling**: one cheap request per interval answers "did anything change";
  only a change pays for a full re-read. Polling covers everything push would,
  just slower — push being unavailable is never a failure.

## Actions

- **Test Connection** — probe the Bond and re-check the token.
- **Sync Devices Now** — re-read the full inventory immediately.
- **Fetch Token From Bond** — the power-cycle pairing path (see Setup).
- **Auto Configure Bond Devices** — add + bind + name a child driver for every
  device function that has none.
- **Auto Rename Bound Drivers** — re-apply device names to bound children.
- **Print Inventory To Log / Print Device Bindings To Log** — what the Bond
  reports, and which child is bound where.
- **Prune Missing Device Bindings** — remove connections whose device is gone
  from the Bond. Never runs on its own.
- **Forget Token** — wipe the stored token.

## Programming

**Run Bond Action** (advanced) sends any raw Bond action to a device by name or
id — for the occasional capability no child surfaces yet (`BreezeOn`,
`SetTimer`, `Pair`). The argument may be a number or JSON.

## Notes

- Bond **groups** and **schedules (skeds)** are deliberately not surfaced —
  Control4 scenes and the scheduler agent already own those jobs.
- Most Bond devices are one-way RF: state is the Bond's own tracking of what it
  transmitted, not a sensor reading. A wall switch the Bond doesn't know about
  will drift its state — that is a property of the RF system, not the driver.

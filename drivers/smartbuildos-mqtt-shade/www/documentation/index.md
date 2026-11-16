# SmartBuildOS MQTT Shade

This driver turns one MQTT cover, blind or shade into a native Control4
**blind** (proxy `blind`) with open, close, stop and a position. The position
comes from one topic as a percentage (100 is open); open, close, stop and "go
to" publish payloads to the **Set Topic**. The defaults suit Zigbee2MQTT.

Requires a **SmartBuildOS MQTT Broker** in the same project, connected to your
MQTT broker. The child finds it by itself and has no licence of its own; the
Broker's SmartBuildOS licence covers it.

## Setup

<!-- walkthrough: Add an MQTT shade -->
1. Add the **SmartBuildOS MQTT Broker** and get it to *Connected* first.
2. Add **SmartBuildOS MQTT Shade** and put it in a room.
3. Type the cover's topic into **State Topic** (`zigbee2mqtt/blind`) and the
   command topic into **Set Topic** (`zigbee2mqtt/blind/set`).
4. The defaults read `position` and publish `{"state":"OPEN"}`,
   `{"state":"CLOSE"}`, `{"state":"STOP"}` and `{"position":N}`, which is what
   Zigbee2MQTT covers expect.
5. If your shade reports 0 for open and 100 for closed, set **Invert
   Position** to *Yes*. Control4 always shows 100 as open.
6. Use the *Test* actions to try open, close, stop and half, and watch **Last
   Result** and **Current State**.

## Properties

| Property | Meaning |
| --- | --- |
| State Topic | The cover's state topic. One plain topic |
| Position Field | JSON field with the position in percent, 100 open. Default `position`. Empty reads the whole payload as a number |
| Invert Position | *Yes* when the device uses 0 for open |
| Set Topic | Where commands are published. Empty makes the shade view-only |
| Open Payload / Close Payload / Stop Payload | Published for those commands |
| Position Payload | Published for "go to". `{position}` is the number the device expects (with Invert Position applied), `{percent}` is what Control4 asked for. Default `{"position":{position}}` |
| Availability Topic / Field | Optional, see below |
| Broker Link | Whether the Broker driver is found and connected |
| Control | *enabled*, or *view only* when the broker is down or the licence has made the bridge read-only |
| Device Availability | online, offline, or not reported |
| Current State | What the device last reported |
| Last Message | Whether the last message was read, or why not |
| Last Seen | When the device last published, and how many messages |
| Last Result | The outcome of the last command |

## What the proxy shows

The proxy follows the state topic only. Each position message is shown as the
shade's resting position; the driver cannot tell whether the shade is still
moving, so a long travel shows its progress in steps as the device reports
them. A request does not move the picture: it moves when the device reports.
Position 100 fires *Shade Fully Open* and 0 fires *Shade Fully Closed*.

## Availability

Fill **Availability Topic** to know when the device is offline. Zigbee2MQTT
publishes `online` or `offline` to `BASE/DEVICE/availability`, either as plain
text or as `{"state":"online"}`; **Availability Field** (default `state`) says
where the word sits, and may be empty for plain text. The child then shows
**Device Availability**, fires *Device Available* and *Device Unavailable*, has a
**Device is available** condition, and the Broker lists the device as offline in
its health. An offline shade keeps its last position.

## Programming

- **Commands**: open, close, stop, toggle and go to a level, as for any
  Control4 blind.
- **Events**: *Shade Fully Open*, *Shade Fully Closed*, plus *Device Available*,
  *Device Unavailable* and *Command Failed*.
- **Conditionals**: *MQTT shade is at least partly open*, *Device is
  available*, *MQTT broker is connected*.
- **Actions**: *Test: Shade Open*, *Close*, *Stop*, *50%*, *Refresh From
  Broker*, *Print Diagnostics To Log*.
## Limits

- One child is one device, and nothing is created for you: add a child for
  each device. A child needs the **SmartBuildOS MQTT Broker** in the same
  project, and works only while that Broker is connected.
- MQTT 3.1.1 over plain TCP only, as the Broker: no TLS, no MQTT 5.
- A state topic is one plain topic, with no `+` or `#`.
- The child shows what the device reports on its state topic. A command is a request and moves nothing on screen until the device answers. There is no moving state, only resting positions. Commands are refused (not queued) while the broker is down.
- No licence of its own: the Broker's covers it. If the licence makes the bridge
  read-only, the child keeps showing state and refuses commands, saying so
  under **Last Result**.
- Free MQTT and Home Assistant drivers exist. This bridge is for projects that
  want the SmartBuildOS Agent link and device health reporting; if you do not,
  a free driver is simpler.

## Unverified on a controller

Tested against a scripted Broker and the Control4 shim only. Not yet checked on
real hardware:

- The proxy conversation (go-to, open, close, stop, resting position) copies
  the System Link shade, which has not been bench-tested either.
- Real Zigbee2MQTT covers and how they report position while moving.
- Tilt is not offered.

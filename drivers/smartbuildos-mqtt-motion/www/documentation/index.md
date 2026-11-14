# SmartBuildOS MQTT Motion

This driver turns one MQTT topic into a native Control4 **motion sensor**
(proxy `motionsensor`): a PIR sensor, a radar presence sensor, any device with
an on and off occupancy state. You choose the topic, which JSON field to read,
and how its values map to motion and no motion. Use **SmartBuildOS MQTT
Contact** for doors, windows and leak sensors.

Requires a **SmartBuildOS MQTT Broker** in the same project, connected to your
MQTT broker. The child finds it by itself and has no licence of its own; the
Broker's SmartBuildOS licence covers it.

## Setup

<!-- walkthrough: Add an MQTT motion -->
1. Add the **SmartBuildOS MQTT Broker** and get it to *Connected* first.
2. Add **SmartBuildOS MQTT Motion** and put it in a room.
3. Type the device's topic into **State Topic**, for example
   `zigbee2mqtt/hall_motion`.
4. Leave **State Field** at `occupancy` for Zigbee2MQTT motion sensors, or
   type the field your device uses (`presence`, `motion`). Dotted paths work;
   an empty field reads the whole payload.
5. Walk past the sensor and watch **Current State** and **Last Message**.

## Properties

| Property | Meaning |
| --- | --- |
| State Topic | The device's topic. One plain topic, no `+` or `#` |
| State Field | JSON field to read, dotted paths allowed. Empty reads the whole payload |
| Active Values / Inactive Values | Optional comma-separated words for motion and no motion. Empty uses the built-ins |
| Invert | Flips motion and no motion |
| Availability Topic / Field | Optional, see below |
| Broker Link | Whether the Broker driver is found and connected |
| Control | *enabled*, or *view only* when the broker is down or the licence has made the bridge read-only |
| Device Availability | online, offline, or not reported |
| Current State | What the device last reported |
| Last Message | Whether the last message was read, or why not |
| Last Seen | When the device last published, and how many messages |
| Last Result | The outcome of the last command |

## How values are read

`true`, `on`, `1`, `yes`, `detected`, `occupied`, `motion`, `presence`,
`active` and any non-zero number mean **motion**. `false`, `off`, `0`, `no`,
`clear`, `unoccupied`, `none`, `inactive`, `no_motion` and `idle` mean **no
motion**. Case does not matter. Anything else is refused and **Last Message**
says to fill in **Active Values** and **Inactive Values**; with those filled,
only your words count.

The sensor's own hold time decides how long motion stays on: this driver
passes the device's state through and adds no delay. For a timed "off after no
motion" in programming, the SmartBuildOS Logic Pack does that. A message
without the field is ignored and noted in **Last Message**.

## Availability

Fill **Availability Topic** to know when the device is offline. Zigbee2MQTT
publishes `online` or `offline` to `BASE/DEVICE/availability`, either as plain
text or as `{"state":"online"}`; **Availability Field** (default `state`) says
where the word sits, and may be empty for plain text. The child then shows
**Device Availability**, fires *Device Available* and *Device Unavailable*, has a
**Device is available** condition, and the Broker lists the device as offline in
its health. A device that is reported offline keeps its last state.

## Programming

- **Events**: *Motion Detected*, *Motion Cleared*, plus *Device Available*,
  *Device Unavailable* and *Command Failed*. They fire on a change, not on the
  first reading after a restart.
- **Conditionals**: *MQTT sensor reports motion*, *Device is available*,
  *MQTT broker is connected*.
- **Actions**: *Refresh From Broker*, *Print Diagnostics To Log*.
## Limits

- One child is one device, and nothing is created for you: add a child for
  each device. A child needs the **SmartBuildOS MQTT Broker** in the same
  project, and works only while that Broker is connected.
- MQTT 3.1.1 over plain TCP only, as the Broker: no TLS, no MQTT 5.
- A state topic is one plain topic, with no `+` or `#`.
- The child shows what the device reports on its state topic. There is nothing to send, so this child never publishes.
- No licence of its own: the Broker's covers it. If the licence makes the bridge
  read-only, the child keeps showing state and refuses commands, saying so
  under **Last Result**.
- Free MQTT and Home Assistant drivers exist. This bridge is for projects that
  want the SmartBuildOS Agent link and device health reporting; if you do not,
  a free driver is simpler.

## Unverified on a controller

Tested against a scripted Broker and the Control4 shim only. Not yet checked on
real hardware:

- The `motionsensor` proxy, its connection class, and the notifications this
  driver sends for motion and no motion (`MOTION` and `NO_MOTION`) are the
  least certain part of the suite: they follow the pattern of the other
  sensors, not a document from Control4. If Navigator or the room's motion
  handling does not react, this is the first place to look.
- Interoperation with a real Zigbee2MQTT motion sensor.

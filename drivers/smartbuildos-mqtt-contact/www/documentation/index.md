# SmartBuildOS MQTT Contact

This driver turns one MQTT topic into a native Control4 **contact sensor**
(proxy `contactsingle`): a door or window contact, a water-leak sensor, a
smoke alarm output, or anything else that is either active or not. You choose
the topic, which JSON field to read, and how its values map to open and
closed. Use **SmartBuildOS MQTT Motion** for motion and occupancy sensors.

Requires a **SmartBuildOS MQTT Broker** in the same project, connected to your
MQTT broker. The child finds it by itself and has no licence of its own; the
Broker's SmartBuildOS licence covers it.

## Setup

<!-- walkthrough: Add an MQTT contact -->
1. Add the **SmartBuildOS MQTT Broker** and get it to *Connected* first.
2. Add **SmartBuildOS MQTT Contact** and put it in a room.
3. Type the device's topic into **State Topic**, for example
   `zigbee2mqtt/front_door`.
4. Set **State Field** to the JSON field to read. The default is `contact`,
   which is right for Zigbee2MQTT door and window sensors. For a leak sensor
   use `water_leak`. Dotted paths work (`alarm.water.state`); an empty field
   reads the whole payload as one value (`ON`, `detected`).
5. Check the direction. Zigbee2MQTT reports `contact: true` when the door is
   **closed**, so **Invert** defaults to *Yes*. For a leak sensor
   (`water_leak: true` means wet) set **Invert** to *No*: wet then reads as
   *Opened*, which is how Control4 contacts usually flag an alarm.
6. Open and close the door and watch **Current State** and **Last Message**.

## Properties

| Property | Meaning |
| --- | --- |
| State Topic | The device's topic. One plain topic, no `+` or `#` |
| State Field | JSON field to read, dotted paths allowed. Empty reads the whole payload |
| Active Values / Inactive Values | Optional comma-separated words for active and not active. Empty uses the built-ins |
| Invert | Flips active and not active |
| Report Active As | What *active* does at the Control4 contact: *Opened* (default) or *Closed* |
| Availability Topic / Field | Optional, see below |
| Broker Link | Whether the Broker driver is found and connected |
| Control | *enabled*, or *view only* when the broker is down or the licence has made the bridge read-only |
| Device Availability | online, offline, or not reported |
| Current State | What the device last reported |
| Last Message | Whether the last message was read, or why not |
| Last Seen | When the device last published, and how many messages |
| Last Result | The outcome of the last command |

## How values are read

With the lists empty, these count as **active**: `true`, `on`, `1`, `yes`,
`detected`, `open`, `opened`, `active`, `occupied`, `motion`, `presence`,
`pressed`, `wet`, `leak`, `alarm`, `triggered`, `tampered`; any non-zero
number. **Not active**: `false`, `off`, `0`, `no`, `clear`, `closed`,
`inactive`, `unoccupied`, `none`, `dry`, `released`, `normal`, `no_motion`,
`idle`. Case does not matter. Anything else is refused and **Last Message**
says to fill in the lists. When you fill **Active Values** and **Inactive
Values**, only your words count (a list of active words alone makes everything
else inactive). Then **Invert** and **Report Active As** are applied.

A message that does not contain the field (Zigbee2MQTT often sends only the
attributes that changed) is ignored and noted in **Last Message**.

## Availability

Fill **Availability Topic** to know when the device is offline. Zigbee2MQTT
publishes `online` or `offline` to `BASE/DEVICE/availability`, either as plain
text or as `{"state":"online"}`; **Availability Field** (default `state`) says
where the word sits, and may be empty for plain text. The child then shows
**Device Availability**, fires *Device Available* and *Device Unavailable*, has a
**Device is available** condition, and the Broker lists the device as offline in
its health. A device that is reported offline keeps its last state; it is not turned into open or closed.

## Programming

- **Events**: *Contact Opened*, *Contact Closed*, plus *Device Available*,
  *Device Unavailable* and *Command Failed*. They fire on a change, not on the
  first reading after a restart.
- **Conditionals**: *MQTT contact is open*, *Device is available*, *MQTT broker
  is connected*.
- **Actions**: *Refresh From Broker* (say hello again), *Print Diagnostics To
  Log*.
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

- The `contactsingle` proxy and its connection class, and the notifications
  OPENED and CLOSED, are modelled on the System Link contact and not checked
  on a controller. Confirm that Composer binds it as a contact sensor and
  that Navigator and security programming see open and closed.
- Interoperation with a real Zigbee2MQTT door sensor.

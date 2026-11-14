# SmartBuildOS MQTT Light

This driver turns one MQTT light into a native Control4 **light** (proxy
`light_v2`) with on, off and a brightness slider. The light's state comes from
one topic; a tap in Navigator or a line of programming publishes a payload to
the **Set Topic**. The defaults suit Zigbee2MQTT. Colour and colour
temperature are not offered.

Requires a **SmartBuildOS MQTT Broker** in the same project, connected to your
MQTT broker. The child finds it by itself and has no licence of its own; the
Broker's SmartBuildOS licence covers it.

## Setup

<!-- walkthrough: Add an MQTT light -->
1. Add the **SmartBuildOS MQTT Broker** and get it to *Connected* first.
2. Add **SmartBuildOS MQTT Light** and put it in a room.
3. Type the light's topic into **State Topic** (`zigbee2mqtt/lamp`) and the
   command topic into **Set Topic** (`zigbee2mqtt/lamp/set`).
4. The defaults read `state` (ON or OFF) and `brightness`, and publish
   `{"state":"ON"}`, `{"state":"OFF"}` and `{"brightness":N}`. That is
   what Zigbee2MQTT expects. Change them for other systems.
5. Set **Level Max** to the device's top brightness: 254 for Zigbee2MQTT, 255
   for many others, 100 for some. The driver converts to and from Control4's
   0 to 100 percent.
6. Tap the light in Navigator, or use the *Test* actions, and watch **Last
   Result** and **Current State**.

## Properties

| Property | Meaning |
| --- | --- |
| State Topic | The light's state topic. One plain topic |
| State Field | JSON field with ON or OFF. Default `state` |
| Level Field | JSON field with the brightness. Default `brightness`. Empty for a plain switch |
| Level Min / Level Max | The device's numbers for 0 and 100 percent. Defaults 0 and 254 |
| Set Topic | Where commands are published. Empty makes the light view-only |
| On Payload / Off Payload | Published for on and off. Defaults `{"state":"ON"}` and `{"state":"OFF"}` |
| Level Payload | Published for a level. Placeholders: `{level}` in the device's range, `{percent}` 0 to 100, `{seconds}` the ramp time. Default `{"brightness":{level}}` |
| Availability Topic / Field | Optional, see below |
| Broker Link | Whether the Broker driver is found and connected |
| Control | *enabled*, or *view only* when the broker is down or the licence has made the bridge read-only |
| Device Availability | online, offline, or not reported |
| Current State | What the device last reported |
| Last Message | Whether the last message was read, or why not |
| Last Seen | When the device last published, and how many messages |
| Last Result | The outcome of the last command |

## What the proxy shows

The proxy follows the state topic only. A tap is a request: the slider moves
when the light reports the new state, not when the command is sent. A light
that never publishes its state will not move on screen. When the light is
turned on without a brightness in the message, it shows the last level it had
(100 the first time). A brightness of 0 reads as off.

The light shows offline when the Broker is not connected to the MQTT broker or
the device reported itself offline.

## Availability

Fill **Availability Topic** to know when the device is offline. Zigbee2MQTT
publishes `online` or `offline` to `BASE/DEVICE/availability`, either as plain
text or as `{"state":"online"}`; **Availability Field** (default `state`) says
where the word sits, and may be empty for plain text. The child then shows
**Device Availability**, fires *Device Available* and *Device Unavailable*, has a
**Device is available** condition, and the Broker lists the device as offline in
its health. An offline light shows offline on the Control4 proxy.

## Programming

- **Commands**: on, off, toggle, go to a level with a ramp time, as for any
  Control4 light. Level 0 sends the Off Payload.
- **Events**: *Light On*, *Light Off*, plus *Device Available*, *Device
  Unavailable* and *Command Failed*.
- **Conditionals**: *MQTT light is on*, *Device is available*, *MQTT broker is
  connected*.
- **Actions**: *Test: Light On*, *Test: Light Off*, *Test: Light 50%* (the same
  path a tap takes), *Refresh From Broker*, *Print Diagnostics To Log*.
## Limits

- One child is one device, and nothing is created for you: add a child for
  each device. A child needs the **SmartBuildOS MQTT Broker** in the same
  project, and works only while that Broker is connected.
- MQTT 3.1.1 over plain TCP only, as the Broker: no TLS, no MQTT 5.
- A state topic is one plain topic, with no `+` or `#`.
- The child shows what the device reports on its state topic. A command is a request and moves nothing on screen until the device answers. Commands are refused (not queued) while the broker is down.
- No licence of its own: the Broker's covers it. If the licence makes the bridge
  read-only, the child keeps showing state and refuses commands, saying so
  under **Last Result**.
- Free MQTT and Home Assistant drivers exist. This bridge is for projects that
  want the SmartBuildOS Agent link and device health reporting; if you do not,
  a free driver is simpler.

## Unverified on a controller

Tested against a scripted Broker and the Control4 shim only. Not yet checked on
real hardware:

- The proxy conversation (brightness, online, button taps) copies the System
  Link light, which was bench-tested; the MQTT light itself has not.
- Real Zigbee2MQTT lights, including how often they report state during a ramp.
- Colour, colour temperature and light groups are not offered.

# SmartBuildOS MQTT Broker

This driver connects the controller to ONE local MQTT broker (Zigbee2MQTT,
Home Assistant's Mosquitto add-on, or a plain Mosquitto) and turns chosen
topics into ordinary Control4 devices. A Control4 driver cannot create devices
by itself, so the work is split in two. You add this **Broker** driver once,
with the broker's address and login. Then you add one **child driver** for each
device you want in Control4: **SmartBuildOS MQTT Contact**, **MQTT Motion**,
**MQTT Light** or **MQTT Shade**. Each child is told which topic to listen to
and, for lights and shades, where to send commands. In Navigator and in
programming the children behave like any other contact sensor, motion sensor,
light or blind.

The Broker also lists the topics it has seen, so you can pick one, and offers a
few programming extras: publish a message, react to a message, and a condition
that says whether the broker link is up.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system. The Agent is the licensing authority (SKU `SBOS_MQTT_BROKER`):
**License Status** shows this driver's standing. The child drivers have no
licence of their own; the Broker's covers them. A definitive licence denial
with enforcement on makes the bridge **read-only**: messages still reach the
children, but nothing is published and commands say why. Only a definitive
denial does this. A missing Agent, an Agent that has not answered yet or an
unreachable cloud leave the bridge fully working.

## Why this one, when free MQTT drivers exist

Free MQTT and Home Assistant drivers for Control4 exist, and for many jobs one
of them is the right answer. Use this driver when you want what they do not
give:

- **The SmartBuildOS Agent link.** The bridge registers with the Agent as a
  module, so the connection state and every device's health show up in
  SmartBuildOS Studio next to the rest of the project.
- **Per-device health.** The Broker records when each linked device last spoke,
  follows its availability topic, and tells programming (an event, variables)
  and the Agent when a device goes silent or offline.
- **The Flight Recorder timeline.** Broker connected and disconnected are
  markers in the same history as everything else on the controller.

If you only need two lights and have no use for any of that, a free driver is
simpler.

## What it needs

- A broker reachable from the controller on the local network, on a plain TCP
  port (1883 by default).
- A user name and password if the broker requires them.
- One child driver per device, added in the same project.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Connect the broker and add a device -->
1. Add **SmartBuildOS MQTT Broker** to the project. Fill in **Broker Host**,
   and **Broker Port** if it is not 1883. Add **Username** and **Password**
   if the broker needs them. The password field is masked and is never written
   to the log.
2. Wait a few seconds. **Connection** should read *Connected*. If it says
   *Waiting*, **Last Error** says why.
3. Leave **Base Topic** at `zigbee2mqtt` for Zigbee2MQTT, or type the prefix
   your devices use. Set **Log Mode** to *Print*, run the action *Print Topics*
   and read the list in the driver's log: it shows the topics the broker has been carrying.
4. Add a child driver, for example **SmartBuildOS MQTT Contact**. Type the
   device's topic into **State Topic** (for example
   `zigbee2mqtt/sink_leak`) and the JSON field into **State Field** (for
   example `water_leak`).
5. On the child, **Broker Link** should read *Connected*, and **Last Message**
   and **Current State** follow the first message. Retained messages arrive at
   once, so a device that published its state earlier shows it immediately.
6. Put the child in a room as usual.

## Choosing topics

*Print Topics* writes the topics seen to the log (set **Log Mode** to *Print*
or *Print and Log* first), newest first, with a message count. Only topic names are kept, never payloads, because a payload can carry a
credential. The list keeps the 200 most recent topics and forgets the oldest
beyond that. It starts empty after a controller restart. To list topics outside
the base, change **Base Topic** (a filter such as `homeassistant/#` works), or
set it empty to switch the list off.

A child's topic is a plain topic, not a filter: no `+` and no `#`. One child is
one device.

## Programming

### Actions (Composer's Actions tab)

| Action | What it does |
| --- | --- |
| Print Topics | Lists the topics seen in the log |
| Print Devices | Lists every linked child with its topics and last-heard time |
| Reconnect Now | Drops the connection and logs in again |
| Clear Topics Seen | Empties the list |
| Register With Agent Now | Asks the Agent to register this driver and the module |
| Refresh Status | Re-reads health now |

### Commands

**Publish Message**: `TOPIC`, `PAYLOAD`, `RETAIN` (No/Yes), `QOS` (0 or 1).
Publishes one message. Wildcards are refused. For lights and shades use the
child instead; this is for one-offs.

### Events

| Event | Fires when |
| --- | --- |
| Message Received | A message arrives on one of the **Event Topics** (variables `LAST_TOPIC`, `LAST_PAYLOAD`) |
| Broker Connected | The broker accepts the login |
| Broker Disconnected | The connection is lost |
| Device Went Stale | A linked device is silent past **Stale After Minutes**, or reports offline (`LAST_STALE_DEVICE`) |
| Device Recovered | That device spoke again |
| Bridge Read-Only | The licence made the bridge read-only |

**Event Topics** takes up to five filters separated by commas; `+` and `#`
work. At most 20 Message Received events fire per 10 seconds, so a chatty topic
cannot flood programming; the rest are counted and dropped. The variables hold
the latest message only, with the payload cut at 1000 characters.

### Conditional

**MQTT broker is connected**.

### Variables

`BROKER_STATE`, `LAST_TOPIC`, `LAST_PAYLOAD`, `LAST_STALE_DEVICE`,
`DEVICE_COUNT`, `STALE_DEVICE_COUNT`, and `DEVICE_HEALTH`: a JSON list with
one entry per linked device (`id`, `name`, `kind`, `state`, `age_s`, `msgs`).
`state` is `ok`, `stale`, `offline` or `silent` (nothing heard since the
controller started). The SmartBuildOS Agent can read these.

## Health

Each minute the Broker checks every linked device. A device is **stale** when
it has not published on its state topic for **Stale After Minutes** (default
1440, one day; 0 turns this off). It is **offline** when its availability
topic says so. A contact sensor that only speaks when a door opens can be
quiet for days and still be fine: choose the threshold to suit the devices,
and prefer an availability topic where the system offers one (Zigbee2MQTT
does).

A message on a device's availability topic does not count as the device
speaking. The Broker reports health to the Agent as the module `mqtt_broker`;
see the design note for the exact events.

## Properties

| Property | Meaning |
| --- | --- |
| Broker Host, Broker Port | Where the broker is |
| Username, Password | Login (the password is masked and never logged) |
| Client Id | Empty makes one from this driver's device id; two clients with one id evict each other |
| Base Topic | Prefix for the Topics Seen list |
| Keep Alive Seconds | Ping interval; 0 turns pings off |
| Event Topics | Filters for Message Received |
| Stale After Minutes | Silence before a device is stale |
| Connection, Last Error, Bridge Status | Current standing |
| Topics Seen, Devices, Messages, Last Publish | Counters |

Changing a connection property restarts the connection two seconds later.

## Limits

- **MQTT 3.1.1 over plain TCP only.** No TLS (no `mqtts`, no port 8883) and no
  MQTT 5. A broker that insists on TLS cannot be used. Keep the broker on the
  local network.
- QoS 0 and 1. QoS 2 is not supported; the Broker asks for QoS 1 at most.
- **One child per device, and no auto-creation.** Nothing appears in the
  project by itself; you add each child.
- A command is published and forgotten: if the broker is down, the command is
  refused and Last Result says so. Nothing is queued, because a "turn it off"
  that arrives minutes late is worse than one that failed.
- The children show what the device reports on its state topic, not what was
  requested. A device that publishes no state shows nothing after a command.
- Child limits: 128 devices per broker, four topics each.
- Topics Seen is not saved across a controller restart.
- Home Assistant MQTT Discovery is not read; topics are chosen by hand.

## Reading the status

| Connection says | Meaning |
| --- | --- |
| Not configured | **Broker Host** is empty |
| Connecting... | The socket is opening |
| Logging in to the broker... | Waiting for the broker's answer |
| Connected | Working |
| Waiting N s before trying again | Retrying with growing waits (2 s up to 2 min); **Last Error** gives the reason |

A refused login (wrong user or password, not authorised) retries only every
two minutes so a bad password does not fill the broker's log.

## Unverified on a controller

This driver has been tested against a scripted broker and the Control4 shim
only. Not yet checked on real hardware:

- The controller's TCP client behaving as assumed: reading in chunks of any
  size, the disconnect and error callbacks, and a connect to a name that does
  not resolve.
- A long-lived connection across weeks, and reconnection after a broker
  restart or a network change.
- Interoperation with Mosquitto, the Home Assistant add-on and Zigbee2MQTT
  themselves (the packets are byte-checked against the MQTT 3.1.1 rules).
- The Agent accepting the module `mqtt_broker` and its `mqtt.` events.
- Behaviour with the largest installs (128 devices, a very busy broker).

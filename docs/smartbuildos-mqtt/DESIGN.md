# SmartBuildOS MQTT Bridge: design

Status: built and tested against a scripted broker and the shim, 12 Nov 2026.
Not run on a controller. Scope was reduced and approved by the owner: a Broker
driver plus child drivers, no auto-creation, no TLS, no MQTT 5.

## What it is

A local MQTT broker (Zigbee2MQTT, Home Assistant's Mosquitto, Mosquitto)
becomes native Control4 devices. Free MQTT and Home Assistant drivers exist, so
this is not sold on the feature itself. It is sold on the Agent link and the
health reporting: connection state and per-device last-seen reach SmartBuildOS
Studio, and broker up/down lands in the Flight Recorder timeline.

## Drivers

| Driver | File | Proxy | Notes |
| --- | --- | --- | --- |
| SmartBuildOS MQTT Broker | `smartbuildos-mqtt-broker` | none (`lua_gen`, `<combo>true</combo>`) | SKU `SBOS_MQTT_BROKER`, module id `mqtt_broker` |
| SmartBuildOS MQTT Contact | `smartbuildos-mqtt-contact` | `contactsingle` | |
| SmartBuildOS MQTT Motion | `smartbuildos-mqtt-motion` | `motionsensor` | |
| SmartBuildOS MQTT Light | `smartbuildos-mqtt-light` | `light_v2` | |
| SmartBuildOS MQTT Shade | `smartbuildos-mqtt-shade` | `blind` | |

**Two sensor drivers, not one.** The brief allowed one `-sensor` driver if it
could present both proxies. A driver's proxy is fixed in its `driver.xml`, and
the repo's children (System Link, Bond, UniFi Protect) are one driver per proxy
type; a driver declaring two proxies would create both devices on every add.
So contact and motion are separate drivers sharing one base module.

**Licensing.** Children have no SKU and do not call `sbos.license`. This is the
System Link pattern ("inherits the bridge's pair licence") and Bond's. The
broker's licence covers them. When the Agent denies the broker definitively with
enforcement on, the broker tells every child (`SBOS_MQTT_ENTITY.licence =
read-only`) and children refuse to publish; state still flows. Enforcement fails
open exactly as the other drivers do (only `NOT_ENTITLED`, `ENTITLEMENT_EXPIRED`,
`ACCOUNT_SUSPENDED`, `CONTROLLER_MISMATCH` with `enforcement = enforce`).

## Layout

```
src/mqtt/packet.lua       MQTT 3.1.1 codec + streaming parser (pure)
src/mqtt/topics.lua       topic names, filters, + and # matching (pure)
src/mqtt/payload.lua      JSON paths, value maps, scaling, templates (pure)
src/mqtt/backoff.lua      reconnect backoff (pure)
src/mqtt/router.lua       entities, routing, seen topics, health (pure)
src/mqtt/client.lua       session state machine over an injected transport (pure)
src/mqtt/link.lua         broker <-> child wire vocabulary (pure)
src/mqtt/childdriver.lua  common half of every child driver
```

The broker driver owns the TCP socket (`C4:CreateTCPClient`), feeds bytes into
the client session, and routes. Nothing under `src/mqtt` except `childdriver`
touches a Control4 global.

## MQTT scope

MQTT 3.1.1, clean session, plain TCP. CONNECT (user, password, will encoding
supported but unused), CONNACK, SUBSCRIBE/SUBACK (at QoS 1, batches of 20
filters), UNSUBSCRIBE, PUBLISH QoS 0 and 1 both ways, PUBACK, PINGREQ/PINGRESP,
DISCONNECT. The parser buffers across reads, accepts several packets per read,
refuses malformed input (bad varint, reserved types, wrong flags, truncated
fields, QoS 3, wildcard in a PUBLISH topic, oversize packets over 256 KiB) and
then stays dead until the connection is replaced. Not supported: TLS, MQTT 5,
QoS 2 (a QoS 2 delivery is a protocol error), persistent sessions.

**Reconnect.** Backoff 2 s doubling to 120 s with 20 percent jitter; a refused
login (CONNACK 4 or 5) goes straight to the ceiling so a wrong password does not
hammer the broker. Subscriptions are wanted-state: they are re-sent on every
CONNACK. Outgoing publishes are refused while disconnected, never queued.

**Keepalive.** PINGREQ after 75 percent of the keepalive without outgoing
traffic. Any packet from the broker clears an outstanding ping. A ping left
unanswered for half a keepalive (minimum 5 s) drops the connection. Keepalive 0
disables both.

## Child protocol

Bindingless `SendToDevice` to `ExecuteCommand`, the System Link way, with the
broker found by exact driver filename. Empty values are allowed and nothing is
logged (`allowEmptyValues = true`, `logCommand = false`).

| Direction | Command | Params |
| --- | --- | --- |
| child to broker | `SBOS_MQTT_HELLO` | `requester, kind, name, filters` (newline-separated), `availability, availability_field` |
| child to broker | `SBOS_MQTT_PUBLISH` | `requester, topic, payload, retain, qos` |
| broker to child | `SBOS_MQTT_ENTITY` | `state` (connected or disconnected), `detail, licence` (ok or read-only), `rejected` |
| broker to child | `SBOS_MQTT_MESSAGE` | `topic, payload, retain, role` (state or availability) |
| broker to child | `SBOS_MQTT_RESULT` | `status` (sent or failed), `reason` |
| broker to child | `SBOS_MQTT_BROKER_HELLO` | none: "say hello again" |

A child says hello at load, every minute until the broker answers, when its
topic properties change, and when the broker asks. The broker forgets entities
whose device no longer exists (each minute). Payloads over 16 KiB are not
forwarded. The child does the field extraction and mapping (`mqtt.payload`);
the broker only routes. Last-seen is counted on state-role messages only: an
availability message from the bridge is not the device speaking.

## Security and privacy

- The password property is `<type>STRING</type><password>true</password>`.
  `OPC.suppressDebug` lists `Password` and `Username` so the handlers never
  print them. The password is read from `Properties` at the moment the socket is
  up, handed to `Client` for the CONNECT packet, and cleared from the session
  options straight after. No log line, property, variable, event or Agent frame
  carries it (asserted in `test_mqtt_broker_driver.lua`).
- Topics Seen holds names and counts only, never payloads (Zigbee2MQTT's bridge
  topics can carry network keys).
- `Message Received` exposes one payload, cut at 1000 characters, to
  programming, only for topics the dealer chose; a flood is limited to 20
  events per 10 s.
- No TLS: the manual says the broker must be on the local network.

## Health model

Per entity: last_seen (state messages), availability (from the optional
availability topic), message count. States: `ok`, `stale` (silent longer than
**Stale After Minutes**, default 1440, 0 = never), `offline` (availability says
so), `silent` (nothing since the controller started; not alarming). A minute
scan fires *Device Went Stale* / *Device Recovered*, updates the variables
(`DEVICE_COUNT`, `STALE_DEVICE_COUNT`, `DEVICE_HEALTH` JSON, `BROKER_STATE`) and
reports to the Agent.

Flight Recorder: on connect and disconnect the broker sends `RECORD_EVENT`
(`NAME`, `DETAIL`, `CHANNEL = "mqtt"`) to the first Flight Recorder found by
filename; nothing happens when there is none.

## Agent contract needed

The broker registers with the Agent through `sbos.moduleclient` as module
`mqtt_broker` (not a singleton: a project may run two brokers), entitlement
`SBOS_MQTT_BROKER`, `event_types = "mqtt."`, capabilities `mqtt_bridge,
entity_health`. Status frames carry `status` (`ready` when connected, else
`degraded`), a one-line detail, and counters `devices, stale, messages_in,
messages_out, reconnects`.

It emits two event types. Because `mqtt_broker` has no entry in
`Envelope.PREFIXES`, the module may emit only outside reserved prefixes, and
`mqtt.` is outside all of them, so the controller side validates today. What is
needed elsewhere, none of it done here:

1. **`src/sbos/envelope.lua`**: add `mqtt_broker = { "mqtt." }` to `M.PREFIXES`
   so the prefix is owned (and reserved against impersonation), mirrored in the
   web repo's `envelope.ts` (`moduleOwnsEventType`).
2. **Agent and Studio**: accept module `mqtt_broker` and store/display:

   `mqtt.broker_state` (severity `info` on connect, `warning` on disconnect,
   evidence `observed`, quality `confirmed`):

   ```json
   { "state": "connected" }
   { "state": "disconnected", "reason": "no answer from the broker (keepalive of 60 seconds ran out)" }
   ```

   `mqtt.entity_health` (on any change of any device's state, and at least every
   30 minutes; severity `warning` when `stale > 0`, else `info`; label
   `"<n> MQTT device(s), <m> stale or offline"`):

   ```json
   {
     "count": 12,
     "stale": 1,
     "broker": "connected",
     "devices": [
       { "id": 301, "name": "Sink leak", "kind": "contact", "state": "stale", "age_s": 93211, "msgs": 48 }
     ]
   }
   ```

   `devices` is capped at 20 entries, worst first (stale or offline, then
   longest silent), so it fits the 4 KiB payload limit; names are cut at 60
   characters. `state` is `ok | stale | offline | silent`; `age_s` is absent when
   `silent`. The event is a state, not a change, which is why it repeats.
3. **Studio**: an MQTT panel per project (broker connection, device table with
   last-seen), and an alert rule for `stale > 0` using the existing alerts
   machinery. Device ids are Director ids of the child drivers.
4. **Pull alternative** (if Studio prefers asking): the Agent can read the
   `DEVICE_HEALTH` and `BROKER_STATE` variables of the broker device. Nothing
   in the broker needs to change for that.

## Shared-file changes needed (not made; not mine to edit)

- `test/test_driver_license_guard.lua`: the four children need entries in the
  `inherited` table, each pointing at the broker, otherwise the guard fails them
  for not requiring `sbos.license`:

  ```lua
  ["smartbuildos-mqtt-contact"] = "smartbuildos-mqtt-broker",
  ["smartbuildos-mqtt-motion"] = "smartbuildos-mqtt-broker",
  ["smartbuildos-mqtt-light"] = "smartbuildos-mqtt-broker",
  ["smartbuildos-mqtt-shade"] = "smartbuildos-mqtt-broker",
  ```
- `src/sbos/envelope.lua` prefix entry (above).
- `DRIVER_FILENAMES` in `smartbuildos` (the Agent's updater list) and the
  catalogue/pricing records, when these ship.
- `src/mqtt/link.lua` lists the child and Flight Recorder filenames; a new
  child driver must be added there.

## Tests

`make test` runs, among the rest of the suite:

| File | Covers |
| --- | --- |
| `test_mqtt_packet.lua` | byte-exact vectors, varint boundaries, every split point, multi-packet reads, malformed input |
| `test_mqtt_logic.lua` | topic matching with `+` and `#`, JSON paths, value maps, scaling, templates, router, seen cap, health, backoff |
| `test_mqtt_client.lua` | session against a fake broker: login, refusals, subscriptions and batching, QoS 0/1, keepalive, protocol errors, password confinement |
| `test_mqtt_broker_driver.lua` | the broker driver under the shim: licence, login, routing, health, Agent events, reconnect and backoff, refused login, enforcement |
| `test_mqtt_{contact,motion,light,shade}_driver.lua` | each child under the shim with a scripted Broker |

`test/mqtt_harness.lua` is the shared fake Director (not a test; the Makefile
only runs `test_*.lua`).

## Not verified on a controller

See each manual's last section. In short: the controller's TCP client
(`OnRead` re-arming with `ReadUpTo`, disconnect and error callbacks, DNS), long
uptime, the `motionsensor` proxy's notification names and connection class, the
`contactsingle` connection class, the Agent accepting the module, and real
Zigbee2MQTT and Mosquitto traffic.

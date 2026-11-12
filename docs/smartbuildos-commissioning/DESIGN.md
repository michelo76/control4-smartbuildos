# Commissioning Matrix - design

SKU `SBOS_COMMISSIONING`, module id `commissioning`, driver
`drivers/smartbuildos-commissioning`. Status: built and tested under the shim
only; nothing has run on a controller.

## Shape

| Part | File | Pure? |
| --- | --- | --- |
| Test list, run state machine, record, persistence | `src/commissioning/engine.lua` | yes |
| Actuation adapters (what to send, what to read, did it agree) | `src/commissioning/actuate.lua` | yes |
| Phone page router | `src/commissioning/relay.lua` (reuses `atmosphere.uirelay` parse/render) | yes |
| Lifecycle, licence, Director, relay socket, Flight Recorder, Agent push | `driver.lua` | no |
| Phone page | `www/app/index.html` | |

The engine takes everything it touches as `deps`: clock, `schedule(ms, fn)`,
the actuator, `watch/unwatch` for sensors, `emit`. The actuator is a table of
adapters (`light`, `shade`, `av`, `sensor`). An adapter says `steps(item,
phase, baseline)` (commands to send), `read(vars)` and `check(phase, read,
baseline, item)` returning `match`, `mismatch` or `unreported`. The driver
supplies two real operations: `C4:SendToDevice(device, command, params)` and a
name-to-value read of `C4:GetDeviceVariables`.

## Run state machine

Item: `pending` -> `testing` -> `awaiting` -> `passed | failed | skipped`.
A sensor goes `pending` -> `armed` -> `passed` (automatic) or is judged by
hand. Run: `idle` -> `running` -> `complete` (every item has a verdict) ->
`signed_off`; or `aborted`. A retest reopens a complete run. A restart sends
anything `testing` or `armed` back to `pending` (its timers are gone).

Rules that keep it honest:

- A tap cannot pass an item that was not tested, and cannot pass a sensor
  (only the variable change does).
- A readback mismatch is recorded and shown; a human can still pass it, and
  the record then carries `passed_despite_mismatch`.
- A stale timer from an abandoned attempt changes nothing (attempt counter).
- The list is not rebuilt while a run is active.

## Programming surface

Events: Room Passed (1), Run Completed (2), Item Failed (3). Commands:
`START_RUN`, `START_ROOM`, `ABORT_RUN`, `PRINT_RESULTS`. Conditional:
`RUN_HAS_FAILURES` (BOOL). Variables: `RUN_STATUS`, `CURRENT_ROOM`,
`PASSED_COUNT`, `FAILED_COUNT`, `SKIPPED_COUNT`, `OPEN_COUNT`,
`LAST_FAILED_ITEM`, `LAST_PASSED_ROOM`. Properties are setup only.

## Flight Recorder

Found by `GetDevicesByC4iName("smartbuildos-flight-recorder.c4z")`, then by
scanning `GetDevices` for `flight-recorder`. Markers are sent with
`SendToDevice(id, "RECORD_EVENT", { NAME, DETAIL, CHANNEL = "commissioning" })`
(the command the Flight Recorder exposes: `NAME` required, 120 characters;
`DETAIL` 400). Silent when there is no recorder. The recorder is the common
history; the driver keeps no long-term log of its own, only the last five run
records.

## Agent contract needed

The driver does NOT use `sbos.moduleclient`: that path requires the module to
own an event-type prefix in `src/sbos/envelope.lua`, which this change does
not edit. Today the driver and the Agent talk over plain `SendToDevice`, like
the licence handshake. To wire up (owner/web repo, later):

1. **Prefix.** Reserve `commissioning.` for `module_id = "commissioning"` in
   `envelope.lua` `M.PREFIXES`, with event types
   `commissioning.run.started`, `commissioning.item.judged`,
   `commissioning.room.passed`, `commissioning.run.completed`,
   `commissioning.run.aborted` if the Agent should receive run events through
   the module pipeline (the driver does not emit them yet; the history goes to
   the Flight Recorder).
2. **Record push (implemented driver side).** On sign-off, and again from the
   one-minute status timer until acknowledged, the driver sends to the Agent
   device:

   `SendToDevice(agentId, "SBOS_COMMISSIONING_RESULT", { run_id = "<id>", json = "<record JSON>" })`

   The Agent must: accept the command, validate `json`, forward it to the
   server as the as-built record for the installation, and answer the driver
   with `SendToDevice(driverId, "SBOS_COMMISSIONING_ACK", { run_id = "<id>" })`
   once the server has stored it. Until the ack the driver keeps offering it.
   The Agent can also ask for the latest record at any time with
   `SendToDevice(driverId, "SBOS_COMMISSIONING_PULL", {})`, which makes the
   driver offer it again.
3. **Licensing.** Register SKU `SBOS_COMMISSIONING` in the entitlement
   catalogue (the driver already registers through `sbos.license`).
4. **Property Studio mapping.** Rooms and items are keyed by Control4 device
   id (`device_id`), which the server can join to its installed-device list.

### Record shape (`commissioning.run.v1`)

```json
{
  "schema": "commissioning.run.v1",
  "run_id": "run-1800000000-1",
  "status": "signed_off",
  "scope": "all",
  "started_at": "2026-11-12T10:00:00Z",
  "finished_at": "2026-11-12T11:20:00Z",
  "technician": "Sam",
  "signed_off_by": "Sam",
  "counts": { "passed": 40, "failed": 1, "skipped": 2, "pending": 0, "total": 43 },
  "rooms": [
    {
      "name": "Kitchen",
      "result": "failed",
      "items": [
        {
          "key": "light:10", "device_id": 10, "name": "Pendant", "kind": "light",
          "status": "passed", "attempts": 1,
          "tested_at": "2026-11-12T10:05:00Z", "judged_at": "2026-11-12T10:05:09Z",
          "readback": { "act": { "level": 100 }, "restore": { "level": 20 } },
          "reported": "match", "detail": "reported 100% after a ramp to 100%",
          "note": "lamp lit"
        }
      ]
    }
  ],
  "honest_limits": "readback is what each device reported; a pass is the technician's confirmation; radio signal health is not measured"
}
```

Field notes: `kind` is `light | shade | av | sensor`; `status` per item is
`passed | failed | skipped | pending`; `reported` is
`match | mismatch | unreported`; `auto: true` marks a sensor that passed by
itself (its `readback` is `{ before, after, variable }`);
`passed_despite_mismatch: true` marks a pass over a mismatching readback. Times
are UTC ISO 8601. The server should treat `honest_limits` as display text, and
must not turn `match` into a claim that the device worked.

## Phone page relay

Port 47841 (siblings use 47815 and 47821-47823; pick a free one if another
new driver took it). Routes: `GET /ping`, `GET /app` (tokenless), then with
`?k=<token>`: `GET /state`, `GET /result`, `POST /run | /room | /test | /mark |
/signoff | /abort`. The token is minted once, persisted encrypted, and
replaced by the action *New Page Link*. The controller address is resolved by
`lib.relayhost` (App Relay Address, or an address this relay answered on).
The driver has no web-view proxy, so there is nothing for a Navigator to load
until a dealer adds the link to a web view.

## Shared-file notes

None needed. `make build` will pick the driver up through the usual driver
discovery; `tools/gen-squishy.lua` finds `commissioning.*`, `lib.relayhost` and
`atmosphere.uirelay` by loading `driver.lua`.

## Not verified

See the manual's "Unverified on a controller" list. In short: AV commands and
variable names, sensor variable names, driver-file classification, sensor
variable delivery, the phone page on a real phone, and the Agent side.

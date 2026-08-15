# SmartBuildOS Connector

Makes the Control4 Director the source of truth for what is up and what is down
at a property, and reports it to [SmartBuildOS](https://app.smartbuildos.com).

Add one instance per project. The driver talks outbound over HTTPS only —
nothing needs to be opened on the client's firewall.

## Pairing

The driver holds no credentials until you pair it. In SmartBuildOS, open the
property and generate a **pairing code**, then paste it into the driver's
**Pairing Code** field. The driver redeems the code for a long-lived device
token, stores that token encrypted, and clears the code field.

The code is single-use and short-lived. The token is what actually grants
access; it is never displayed, never logged, and never written to the project
file in plain text. **Unpair** discards it — and discards it locally even if
SmartBuildOS cannot be reached at the time, so a driver can never be stranded in
a paired state it cannot leave.

## What it monitors

Three sources, because no single one sees everything:

| Source          | Covers                                                                                                                        | How                                                                          |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **Director**    | Everything bound into the project, Control4 or not — a Sony TV over IP, a Denon receiver, an Araknis switch, keypads, dimmers | `GetNetworkConnections`, giving online state plus address, port and firmware |
| **Ping**        | Anything else with an IP — core switches, access points, NAS, cameras, printers                                               | ICMP against the hosts you list in **Monitored Endpoints**                   |
| **Programming** | Anything neither of the above can see — a rack door contact, a UPS on battery                                                 | The `SEND_EVENT` command                                                     |

Director reports IP, Zigbee, Z-Wave, SSL and hostname bindings. Zigbee and
Z-Wave entries also carry firmware, and Z-Wave adds `network_status`,
`device_status` and `wake_status`, which the driver prefers over the raw
connection state — a sleeping battery device otherwise looks connected while
being unreachable.

**What Director cannot tell you:** devices with no network binding at all —
IR-controlled sources, serial-only gear, dumb loads — never appear, so they have
no online state to report. Put anything you care about that falls in that gap
behind a `SEND_EVENT` in programming, or give it an IP and list it under
Monitored Endpoints.

### Monitored Endpoints

A comma-separated list. Each entry is either `Label=host` or a bare host:

```
Core Switch=192.168.1.2, Rack UPS=192.168.1.3, NAS=192.168.1.10, 192.168.1.50
```

A bare host is labelled with itself. Each endpoint is pinged up to three times
per poll; rounds are five seconds apart, so an unreachable host is reported
roughly fifteen seconds into the poll.

## What it sends

| Payload   | When                                                | Contents                                                           |
| --------- | --------------------------------------------------- | ------------------------------------------------------------------ |
| Snapshot  | On pairing, on **Full Sync Interval**, on demand    | Every monitored device and its current state                       |
| Delta     | On **Device Poll Interval**, when something changed | Only the devices that came up, went down, appeared or were removed |
| Heartbeat | On **Heartbeat Interval**                           | Proof of life, device totals, consecutive failure count            |
| Event     | On `SEND_EVENT`                                     | Event name and free-text detail                                    |

Deltas are what keeps this cheap: a 200-device project that re-sent an unchanged
snapshot every five minutes would generate a great deal of traffic and tell you
nothing new. The periodic snapshot exists so the platform can reconcile away
anything a missed delta left stale.

The first poll after a driver loads is a **baseline** — it records state without
reporting it, so a controller reboot does not look like every device in the
project coming online at once.

## Properties

| Property             | Description                                                                               |
| -------------------- | ----------------------------------------------------------------------------------------- |
| API URL              | Base URL of the SmartBuildOS instance. Trailing slashes are tolerated.                    |
| Pairing Code         | Paste a code from SmartBuildOS here. Clears itself once redeemed.                         |
| Paired Property      | Read-only. The property this controller reports against.                                  |
| Connection Status    | Read-only. `Connected`, `Unreachable`, `HTTP <code>`, `Not paired`, or a pairing failure. |
| Last Successful Sync | Read-only timestamp of the last accepted payload.                                         |
| Device Poll Interval | 1m / 5m / 15m / 30m. Default 5m.                                                          |
| Monitored Endpoints  | Non-Control4 hosts to reach by ping.                                                      |
| Devices Offline      | Read-only count of devices currently down.                                                |
| Last Device Change   | Read-only. The most recent device to change state.                                        |
| Heartbeat Interval   | 5m / 15m / 30m / 1h / 6h. Default 15m.                                                    |
| Full Sync Interval   | 6h / 12h / 24h. Default 24h.                                                              |

## Actions

- **Test Connection** — sends a one-off `test` payload and reports the result.
- **Poll Devices Now** — forces a device poll outside the timer.
- **Send Full Sync** — forces a complete snapshot.
- **Send Heartbeat Now** — forces a heartbeat.
- **Unpair** — discards the stored token.
- **Update Drivers** — checks GitHub releases and updates in place.

## Programming

**Events:** `Connected`, `Disconnected`, `Sync Failed`, `Paired`,
`Device Went Offline`, `Device Came Online`.

Connected/Disconnected fire only on a state *transition*, so an extended outage
produces one notification, not one per heartbeat. The same is true of a device
that stays down: it is reported once when it drops and once when it recovers.

**Conditionals:** `SMARTBUILDOS_CONNECTED`, `SMARTBUILDOS_PAIRED`.

**Command:** `SEND_EVENT` with `NAME` and `DETAIL`.

## Requirements

Control4 OS **3.3.1** or later. The ping interface used for Monitored Endpoints
was added in 3.3.1; on an older controller the driver disables itself and says
so in Driver Status rather than silently monitoring less than you configured.

## Troubleshooting

Set **Log Mode** to `Print` and **Log Level** to `4 - Debug` to see each request
in the Lua output window. Log Mode reverts to `Off` automatically after three
hours.

| Connection Status                             | Meaning                                                                         |
| --------------------------------------------- | ------------------------------------------------------------------------------- |
| `Not paired`                                  | No pairing code has been redeemed yet.                                          |
| `Pairing failed - code is invalid or expired` | Generate a fresh code in SmartBuildOS.                                          |
| `Pairing failed - unexpected response`        | SmartBuildOS accepted the code but did not return a token. Server-side problem. |
| `HTTP 401`                                    | The device token was revoked. Unpair and pair again.                            |
| `HTTP 404`                                    | The property no longer resolves. Confirm it in SmartBuildOS.                    |
| `Unreachable`                                 | DNS, TLS, or routing failure. Check the controller's internet access.           |

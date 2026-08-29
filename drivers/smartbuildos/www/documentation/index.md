# SmartBuildOS Connector

Makes the Control4 Director the source of truth for what is up and what is down
at a property, and reports it to [SmartBuildOS](https://app.smartbuildos.io).

Add one instance per project. In Composer, load it with **Driver → Add or Update
Driver…**, then add **SmartBuildOS Agent** to the project. It is the licensing
authority for every SmartBuildOS driver on the controller; keep just one per
project. It talks outbound over HTTPS only — nothing needs to be opened on the
client's firewall.

> **Updating an existing install:** use **Driver → Add or Update Driver…** and
> load the new `smartbuildos.c4z`; it refreshes the instance in place. If
> Composer will not surface a change, remove `smartbuildos` from the local
> driver database and re-add the file. Pairing identity is preserved in the
> Pairing Backup property, so it re-pairs itself with no new code.

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

### Pair by account number

No pairing code on hand? Enter the client's **account number** in the driver's
**Account Number** field. SmartBuildOS emails a short verification code to the
account's own email address; enter it in **Verification Code** and the driver
pairs. The code is single-use, expires in a few minutes, and is only ever sent
to the address already on the account — so possession of the account number
alone is not enough to pair.

Which system the controller lands in is worked out automatically: a controller
SmartBuildOS has seen before re-pairs into its existing system; a new one gets a
fresh system under the account, which a dealer links to a property from the
console.

## Licensing & subscription

Every SmartBuildOS driver on the controller asks this Agent whether it is
licensed; the Agent answers from a signed entitlement it fetches from
SmartBuildOS and caches. It also surfaces the account picture so a dealer can
read it at a glance:

- **SmartBuildOS Company** — the registered company this controller is paired
  to. A SmartBuildOS driver only runs against a **fully registered company**;
  until the Agent is paired, dependent drivers show *SMARTBUILDOS COMPANY
  REGISTRATION REQUIRED*.
- **Subscription Tier** — the company's SmartBuildOS plan (Free / Essential /
  Professional / Business / Enterprise), with `(grace)` when it is riding the
  grace window.
- **Licensed Drivers** — how many SmartBuildOS drivers in this project currently
  hold a license, over how many are installed (`3 licensed / 4 installed`).

Each dependent SmartBuildOS driver shows its standing with the Agent on one
**License Status** line: *No SmartBuildOS Agent Found* → *SmartBuildOS Agent
Found - Not Linked* (add and pair the Agent) → *Checking...* → then **Licensed /
Subscribed**, **Licensed / Permanent**, **Licensed / Grace**, or a plain reason
it is not (e.g. *Agent Linked - Not Licensed*, *License Expired*, *Cloud
Validation Required*). It also shows its **License Source** — *Included with
subscription* (covered by the plan) or *Purchased outright* (a perpetual license
bought for that driver) — plus the account's tier and company.

The Agent shows the tier and company from the moment it pairs; both refresh on
every entitlement check. A value the platform cannot confirm is left blank
rather than shown wrong, and the last known value is kept until a confirmed one
replaces it.

## What it monitors

Three sources, because no single one sees everything:

| Source          | Covers                                                                                                                        | How                                                                          |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **Director**    | Everything bound into the project, Control4 or not — a Sony TV over IP, a Denon receiver, an Araknis switch, keypads, dimmers | `GetNetworkConnections`, giving online state plus address, port and firmware |
| **Ping**        | Anything else with an IP — core switches, access points, NAS, cameras, printers                                               | ICMP against the hosts you list in **Non Control4 Devices**                  |
| **Programming** | Anything neither of the above can see — a rack door contact, a UPS on battery                                                 | The `SEND_EVENT` command                                                     |

Director reports IP, Zigbee, Z-Wave, SSL and hostname bindings. A binding's
`status` is the authority: anything other than `online` is treated as down, so
an unexpected value fails visibly rather than quietly reporting a dead device as
healthy.

**What Director cannot tell you:** devices with no network binding at all —
IR-controlled sources, serial-only gear, dumb loads — never appear, so they have
no online state to report. Put anything you care about that falls in that gap
behind a `SEND_EVENT` in programming, or give it an IP and list it under Non
Control4 Devices.

### Discover Network Devices

Off by default. When on, the driver listens for devices announcing themselves
over SSDP and reports any that are **not in the Control4 project** — the gear
Composer shows under "Discovered" and that a dealer usually never adds, like
Sonos subs and surrounds.

These arrive with an address and whatever name the device reports about itself,
and nothing else: no device id, no room, no control state. SmartBuildOS marks
them **Not in project**, because there is no driver to open and no binding to
fix. A device that IS in the project is always described by its binding instead
— the announcement never replaces it.

Discovery only sees devices that announce. Anything that stays quiet is
invisible to it, which is what **Non Control4 Devices** below is for.

### Non Control4 Devices

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

| Property             | Description                                                                                  |
| -------------------- | -------------------------------------------------------------------------------------------- |
| API URL              | Base URL of the SmartBuildOS instance. Trailing slashes are tolerated.                       |
| Pairing Code         | Paste a code from SmartBuildOS here. Clears itself once redeemed.                            |
| Account Number       | Alternative to a pairing code: enter the account number to have a verification code emailed. |
| Verification Code    | The emailed code. Enter it to finish account-number pairing. Single-use; clears itself.      |
| Paired Property      | Read-only. The property this controller reports against.                                     |
| SmartBuildOS Company | Read-only. The registered company this controller is paired to.                              |
| Subscription Tier    | Read-only. The company's SmartBuildOS plan, `(grace)` when in the grace window.              |
| Licensed Drivers     | Read-only. Licensed-vs-installed count of SmartBuildOS drivers in this project.              |
| Connection Status    | Read-only. `Connected`, `Unreachable`, `HTTP <code>`, `Not paired`, or a pairing failure.    |
| Last Successful Sync | Read-only timestamp of the last accepted payload.                                            |
| Device Poll Interval | 1m / 5m / 15m / 30m. Default 5m.                                                             |
| Non Control4 Devices | Devices with no Control4 driver, reached directly by IP.                                     |
| Devices Offline      | Read-only count of devices currently down.                                                   |
| Last Device Change   | Read-only. The most recent device to change state.                                           |
| Heartbeat Interval   | 5m / 15m / 30m / 1h / 6h. Default 15m.                                                       |
| Full Sync Interval   | 6h / 12h / 24h. Default 24h.                                                                 |

## Actions

- **Test Connection** — sends a one-off `test` payload and reports the result.
- **Poll Devices Now** — forces a device poll outside the timer.
- **Send Full Sync** — forces a complete snapshot.
- **Send Heartbeat Now** — forces a heartbeat.
- **Unpair** — discards the stored token.
- **Report Diagnostics** — prints what Director actually returns for this
  project to the Lua window. Run it when the device list looks wrong.
- **Report Telemetry Survey** — surveys what this project could support for Home
  Intelligence reporting: rooms, room variables, device variables and programmed
  code items. Run once; it does considerably more work than a device poll and is
  never run on a timer.
- **Update Drivers** — checks GitHub releases and updates in place.

## Programming

**Events:** `Connected`, `Disconnected`, `Sync Failed`, `Paired`,
`Device Went Offline`, `Device Came Online`.

Device state is both **pushed and polled**. The driver registers for Director's
own online/offline system events, so a change is reported within seconds; the
poll remains as the backstop that reconciles anything missed while the driver
was reloading.

Connected/Disconnected fire only on a state *transition*, so an extended outage
produces one notification, not one per heartbeat. The same is true of a device
that stays down: it is reported once when it drops and once when it recovers.

**Conditionals:** `SMARTBUILDOS_CONNECTED`, `SMARTBUILDOS_PAIRED`.

**Command:** `SEND_EVENT` with `NAME` and `DETAIL`.

## Requirements

Control4 OS **3.3.1** or later. The ping interface used for Non Control4 Devices
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

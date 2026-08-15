# SmartBuildOS Connector

Connects a Control4 system to [SmartBuildOS](https://app.smartbuildos.com), so
the controller reports its own health, its device inventory, and dealer-defined
events back to the platform.

Add one instance per project. The driver talks outbound over HTTPS only —
nothing needs to be opened on the client's firewall.

## What it sends

| Payload   | When                             | Contents                                                                |
| --------- | -------------------------------- | ----------------------------------------------------------------------- |
| Heartbeat | Every _Heartbeat Interval_       | Controller type, OS version, driver version, consecutive failure count  |
| Inventory | Every _Inventory Interval_       | Every device in the project: id, name, model, manufacturer, driver file |
| Event     | On `SEND_EVENT` from programming | Event name and free-text detail                                         |

Every payload also carries the system identity block: property ID, controller
type, C4 OS version, driver version, Director device ID and name.

## Setup

1. In SmartBuildOS, open the property and issue a **Control4 device token**.
1. Add this driver to the project.
1. Set **API URL** to your SmartBuildOS instance (default
   `https://app.smartbuildos.com`).
1. Paste the **Device Token** and the **Property ID**.
1. Click **Test Connection**. _Connection Status_ turns to `Connected` and _Last
   Successful Sync_ stamps the time.

## Properties

| Property                | Description                                                                                     |
| ----------------------- | ----------------------------------------------------------------------------------------------- |
| API URL                 | Base URL of the SmartBuildOS instance. Trailing slashes are tolerated.                          |
| Device Token            | Bearer credential issued per property. Stored as a password field and never written to the log. |
| Property ID             | The SmartBuildOS property UUID this controller reports against.                                 |
| Connection Status       | Read-only. `Connected`, `Unreachable`, `HTTP <code>`, or `Not configured - <reason>`.           |
| Last Successful Sync    | Read-only timestamp of the last accepted payload.                                               |
| Heartbeat Interval      | 5m / 15m / 30m / 1h / 6h. Default 15m.                                                          |
| Report Device Inventory | When `Off`, inventory syncs carry identity only and no device list.                             |
| Inventory Interval      | 6h / 12h / 24h. Default 24h.                                                                    |

## Actions

- **Test Connection** — sends a one-off `test` payload and reports the result.
- **Send Heartbeat Now** — forces a heartbeat outside the timer.
- **Send Full Inventory** — forces an inventory sync.
- **Update Drivers** — checks GitHub releases and updates in place.

## Programming

**Events:** `Connected`, `Disconnected`, `Sync Failed`. Connected/Disconnected
fire only on a state *transition*, so an extended outage produces one
notification, not one per heartbeat.

**Conditional:** `SMARTBUILDOS_CONNECTED` — true while the last delivery
succeeded.

**Command:** `SEND_EVENT` with `NAME` and `DETAIL` pushes a named event to
SmartBuildOS. Use it for anything the driver cannot observe on its own — a rack
door contact, a UPS on battery, a client-facing "call me" button.

## Troubleshooting

Set **Log Mode** to `Print` and **Log Level** to `4 - Debug` to see each request
in the Lua output window. Log Mode reverts to `Off` automatically after three
hours.

| Connection Status      | Meaning                                                                |
| ---------------------- | ---------------------------------------------------------------------- |
| `Not configured - ...` | A required property is blank.                                          |
| `HTTP 401`             | The device token was revoked or mistyped. Re-issue it in SmartBuildOS. |
| `HTTP 404`             | The property ID does not resolve. Confirm it in SmartBuildOS.          |
| `Unreachable`          | DNS, TLS, or routing failure. Check the controller's internet access.  |

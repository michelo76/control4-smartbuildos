# UniFi Protect Gateway

Connects a Control4 project to one UniFi Protect console over Ubiquiti's
**official Protect Integration API**. This is the parent driver: it owns the
console connection, the API key, and the device inventory, and it exposes one
connection per camera for the UniFi Protect Camera driver (one instance per
camera) to attach to.

Add **one instance per console**. The driver talks to the console directly on
the local network — nothing goes through the cloud, and nothing needs to be
opened on the firewall.

## Requirements

- UniFi Protect **5.3 or later** (the release that introduced the official
  Integration API).
- An **API key**, created in UniFi OS under **Settings → Control Plane →
  Integrations** by an administrator.
- The console reachable from the controller (same LAN, VPN, or a routable
  address).

## Setup

1. Set **Console Address** to the console's IP or hostname. A bare IP is fine.
1. Paste the API key into **API Key**. The driver stores it encrypted on the
   controller and clears the field — an empty field after pasting means the key
   was accepted. The key never sits in the project file in plain text.
1. Watch **Connection Status**. On success the driver reads the Protect version
   and NVR name, pulls the device inventory, and creates one **camera
   connection** per camera.

Leave **Verify TLS Certificate** off for a console presenting its factory
self-signed certificate. Turn it on only when the console has a certificate the
controller can actually verify.

## What it does

- Polls the console on the **Device Poll Interval** for cameras, lights, sensors
  and chimes, with online/offline counts shown per category.
- Creates a provider connection (class `UNIFI_PROTECT_CAMERA`) for every camera
  it finds, ready for camera driver instances to bind to. Connections are
  **never removed automatically** — a camera that is offline for a rebuild must
  not cost you your Composer connections. Use **Prune Missing Camera Bindings**
  when a camera is gone for good.
- Exposes a **connected** conditional for programming.
- Holds a **live event stream** to the console (the Event Stream property shows
  its state) and routes motion, smart detections and doorbell rings to the bound
  camera instances in real time. Reconnects on its own if the console restarts.

## Actions

| Action                        | What it does                                                            |
| ----------------------------- | ----------------------------------------------------------------------- |
| Test Connection               | Verifies the address and key, then refreshes everything                 |
| Sync Devices Now              | Refreshes the inventory without waiting for the next poll               |
| Print Inventory To Log        | Writes every known device, with state, id and MAC, to the log           |
| Prune Missing Camera Bindings | Removes camera connections whose camera no longer exists on the console |
| Forget API Key                | Deletes the stored key; the driver goes back to Not configured          |

## Troubleshooting

**"Refused (HTTP 401/403) - check the API key"** — the console answered and
rejected the key. Re-create the key in UniFi OS and paste it again. This is not
a network problem.

**"Console unreachable"** — the console did not answer at all. Check the
address, and that the controller can reach the console on the LAN.

**Counts look stale after a reboot** — counts marked `(cached)` are the
last-known inventory shown until the first poll lands.

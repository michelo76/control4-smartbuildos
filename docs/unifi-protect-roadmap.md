# UniFi Protect drivers — competitive roadmap & SmartBuildOS integration

2026-08-28. Sources: the DriverCentral driver's setup guide (Protect 6.0.47-era,
local-admin auth), Chowmain's UniFi suite manual v20260826 (the serious
competitor — Protect + Network + Access + WiFi QR under one licence), the
official Protect Integration API spec, and our shipped drivers
(field-verified working 2026-08-28).

---

## 1. Where the three drivers stand

### Authentication & resilience — we already win here

| | Ours (SBOS) | DriverCentral | Chowmain |
| --- | --- | --- | --- |
| Auth | **API key only**, encrypted at rest, letterbox property | Local **admin username + password** stored in driver | API key **AND** local username/password, **MFA must be disabled** |
| API surface | Official Integration API only | Unofficial (password-era) | Official + unofficial mixed |
| Breaks when Protect updates | Only if Ubiquiti breaks their *published* API | Historically yes | Their playback is labelled EXPERIMENTAL by their own manual |
| Licence | None — ours | $199 + cloud licence driver | Licence + Chowmain Agent + project codes, phones home (error reporting to Chowmain by default in betas) |
| Password stored on controller | Never | Yes | Yes, with MFA off |

That last row is a real selling point for security-conscious clients: both
competitors require an admin credential sitting on the controller; Chowmain
additionally requires weakening the UniFi account (MFA off). We never see a
password.

### Feature matrix (Protect scope)

| Feature | Ours | DriverCentral | Chowmain |
| --- | --- | --- | --- |
| Live streams on Navigators | ✅ (RTSP default, measured) | ✅ | ✅ |
| Per-camera stream quality selection | ✅ Streams Offered | Gateway-wide low/high toggle | per-camera primary stream |
| Auto-discover cameras | ✅ (bindings auto-created) | ✅ Add Drivers action | ✅ AutoSetup |
| Auto-rename from Protect | ✅ (+ follows renames, never clobbers) | ─ | ✅ (format string) |
| Motion/person/vehicle/package/animal events | ✅ live websocket | ✅ | ✅ |
| Licence plate events | ✅ (text when API provides) | ✅ | ✅ + variable |
| Face detection events | ✅ generic | ✅ | ✅ **by name** (unofficial API) |
| Audio alarm events (smoke/CO/glass…) | ✅ | partial | ✅ |
| Doorbell ring events | ✅ | ✅ | ✅ |
| History timeline in app | ✅ History Agent (shipped today) | ✅ (their UI) | ✅ custom UI + snapshots + filters |
| NVR recording playback | ─ (deliberate) | claimed | **EXPERIMENTAL**, PIN-gated, "may not work on all systems" |
| Snapshots / notification attachments | ─ (planned, see §2) | ✅ | ✅ |
| Doorbell LCD (message/DND/leave-package) | ─ (planned, official API) | ─ | ✅ |
| PTZ presets/patrols | client ready, not surfaced | ✅ | ✅ + custom presets framework |
| Camera settings (LED, mic volume, HDR, video mode) | ─ (planned, official API) | ─ | ✅ |
| Alarm Manager webhooks (C4 → Protect) | ─ (planned, official API) | ✅ | ✅ |
| Webhooks Protect → C4 | ─ | ✅ | ✅ (auto-created events) |
| Protect sensors (door/temp/humidity) | inventoried, no child driver | ─ | ✅ |
| Floodlights | inventoried, no child driver | ✅ | ✅ |
| Viewport control | ─ | ✅ | ✅ (views + temporary doorbell view) |
| Protect alarm arm/disarm profiles | ─ | ─ | ✅ |
| Sirens, fobs, bridges, link stations | ─ | ─ | display/test |
| UniFi Network / Access / WiFi QR | (SBOS platform covers Network) | ─ | ✅ in-driver |
| Fleet view across customers | **✅ via SmartBuildOS** (§3) | ─ | ─ |
| Business-platform integration | **✅ SmartBuildOS** (§3) | ─ | ─ |

## 2. Gap-closing roadmap — everything below is on the OFFICIAL API

Ordered by effort-to-value. Items 1–4 are days, not weeks.

1. **Alarm Manager webhook trigger** — `POST /v1/alarm-manager/webhook/{id}`
   already in our client. One Gateway action + command with a Trigger ID
   property = full "Control4 triggers Protect automations" story (arm
   behaviors, Protect-side lights, custom events).
2. **Doorbell LCD + camera settings** — `PATCH /v1/cameras/{id}` covers
   lcdMessage (custom text / DND / leave-package), LED, mic volume, HDR,
   video mode. Surface as camera actions + Composer commands. Closes
   Chowmain's doorbell story minus intercom audio.
3. **PTZ presets** — goto/patrol endpoints are already in the client;
   surface via `has_dynamic_presets` + `PRESETS_CHANGED` so preset recall
   appears in the native camera UI. (Continuous PTZ stays impossible on the
   official API — Chowmain uses the local account for that.)
4. **Sensor + floodlight child drivers** — same parent/child pattern that
   now works: sensors as CONTACT_SENSOR (+ temp/humidity variables),
   floodlights as light_v2. `GET/PATCH /v1/sensors|lights` exist.
5. **Controller-local snapshot relay** — the unlock for snapshots WITHOUT
   the unofficial API and WITHOUT per-camera anonymous-snapshot setup: the
   Gateway runs a tiny HTTP listener on the controller (`C4:CreateServer`),
   fetches `GET /v1/cameras/{id}/snapshot` WITH the API key, and serves the
   JPEG LAN-side. Navigator thumbnails, `notification_attachment_provider`
   push snapshots, and SBOS uploads all feed off it. This is the single
   highest-leverage item on the list.
6. **Viewport driver** — `PATCH /v1/viewers/{id}` sets the live view;
   "doorbell rings → viewport shows front door for 30s" is a beloved
   feature and officially supported.
7. **Protect → C4 webhooks** — an inbound path needs a listener; the same
   `C4:CreateServer` from item 5 can accept Alarm Manager webhook POSTs →
   fire driver events. Two-way automation parity with Chowmain.

**Deliberately not chasing:** NVR recording playback and face-by-name.
Both require the unofficial cookie API (MFA-off local admin) — the
maintenance treadmill and the security posture we advertise against.
Chowmain's own manual calls their playback experimental and system-
dependent. Protect's app does playback perfectly; our answer is the
History timeline + snapshots + (SBOS) event archive.

## 3. The SmartBuildOS tie-in — the moat

Neither competitor has, or can have, a business-platform story. We own both
ends. The platform already has: per-property equipment registry matched **by
MAC**, `property_unifi_alerts` + 48h auto-ticket engine, the System Health
loop, role-aware push notifications, Sentinel (fleet NOC), the client
portal, and the **SmartBuildOS Connector driver running in the same
Composer project** as the Protect Gateway.

**Phase 1 — cameras join the registry (small).** Gateway hands its device
roster (name/MAC/state per camera) to the Connector over `SendToDevice` —
same-project discovery by driver filename, the pattern both drivers already
use. Connector ships it on the existing telemetry channel. Platform matches
by MAC into the property's equipment (Protect MACs are already in the
payloads — verified on the user's real system). Result: cameras appear in
the property's Installed Equipment, Sentinel, and System Health with zero
new platform plumbing.

**Phase 2 — camera health → tickets.** Camera DISCONNECTED events flow the
same path into `property_unifi_alerts`: dealer gets the 48h auto-ticket for
a dead camera before the homeowner notices the black tile. This is a
service-contract feature no camera driver on the market has.

**Phase 3 — detections & snapshots → the platform.** Selected events
(ring, person, smoke-alarm audio) forward with property context; the
snapshot relay (§2.5) posts stills through the Connector's existing
`camera-relay` endpoint (built for D-8, currently hardware-gated — this
unblocks it). Use cases: service verification photos on tickets, doorbell
events in the client portal timeline, an event archive that outlives the
NVR's retention window.

**Phase 4 — fleet camera board.** Sentinel gains a Protect column: every
customer's cameras, online state, last event, firmware — across the whole
book of business. The commercial drivers are single-project tools; this is
a dealer-operations product.

**Positioning:** the driver is free and unlicensed; the fleet features ride
the SmartBuildOS subscription. "The only Protect driver that never stores a
password, never breaks on a Protect update, and reports to your business
platform."

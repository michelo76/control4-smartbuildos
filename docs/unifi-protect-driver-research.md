# Building a UniFi Protect driver for Control4

Research note, 2026-08-28. Sources: the Snap One DriverWorks docs on GitHub
(`snap-one/docs-driverworks-*`), the UniFi Protect OpenAPI spec extracted from
`developer.ui.com`, and this repo's existing driver.

---

## 0. Before you write any Lua: the one experiment that decides the design

Everything below is straightforward except one unknown, and it is load-bearing:

> **Can a Control4 Navigator play `rtsps://<console>:7441/<token>?enableSrtp`
> when the console presents a self-signed certificate?**

Test it in 20 minutes with **no driver at all**:

1. Protect → camera → Settings → Advanced → enable RTSP on the High channel.
   Copy the URL. It looks like `rtsps://192.168.1.1:7441/5nPr7RCmueGTKMP7?enableSrtp`.
2. Add the stock Control4 **Camera (RTSP/H.264)** driver to a project, paste the
   URL, and view it on a T4 and on the OS/on-screen navigator.
3. If it fails, retry the plain-RTSP variant: drop the `s`, change the port to
   `7447`, and delete `?enableSrtp` →
   `rtsp://192.168.1.1:7447/5nPr7RCmueGTKMP7`.

The `7441 → 7447` downgrade is the documented workaround other control-system
vendors publish (RTI ships a tech bulletin telling dealers to do exactly this),
which is itself evidence that **rtsps+SRTP is not universally consumable by
control-system clients**. Port 7447 is undocumented by Ubiquiti and present only
"on some firmware" — treat it as a fallback that can disappear, not a foundation.

The Control4 side *does* know the scheme: the dynamic-streams docs list default
ports per transport including `rtsps - 443`. That is not proof the decoder
accepts SRTP with an untrusted cert. Measure it.

> **ANSWERED 2026-08-28, on real hardware** (Composer 2026.5.27, OS Management
> Package 4.2.1, Protect 7.2.105, Control4 app): **rtsps+SRTP renders a black
> tile; plain rtsp on 7447 plays.** The dealer toggle in the camera driver now
> defaults to RTSP; the "only rtsp:7447 works" row below is the world we live
> in — fragile against Protect removing the undocumented port, exactly as
> written.

**Outcome matrix:**

| Result | What the driver becomes |
| --- | --- |
| rtsps works | Clean. Driver hands Navigator the native Protect URL. Best case. |
| only rtsp:7447 works | Driver rewrites scheme+port. Works, but fragile across Protect updates. |
| neither works | You need a transcode/proxy hop. That is a different (much bigger) project — stop and reconsider buying. |

---

## 1. Reality check: this driver already exists

There is a mature commercial **UniFi Protect driver for Control4** on
DriverCentral, MSRP **$199.99**, single licence unlocks unlimited instances,
30-day trial. It covers G3/G4/G5/G6/AI cameras, Doorbell + Doorbell Pro,
ViewPort, floodlights and sensors, and does event-history playback on T4, AI
detections (person/vehicle/package/licence plate/face), PTZ with presets and
person-tracking, LCD doorbell messages, and webhooks.

Build your own if you want: no per-site licence cost across your fleet,
first-party control of the roadmap, and — the interesting one — a direct path to
feed Protect events into SmartBuildOS rather than only into Composer
programming. Otherwise, buy it; a trial costs a day and tells you what "done"
looks like.

---

## 2. The UniFi side

### 2.1 Two APIs, pick deliberately

**Official Protect Integration API** — this is what you should build on.

- Local: `https://<console>/proxy/protect/integration/v1/...`
- Cloud proxy: `https://api.ui.com/v1/connector/consoles/{consoleId}/proxy/protect/integration/v1/...`
- Auth: **`X-API-KEY`** header. Key is created in UniFi OS → **Settings →
  Control Plane → Integrations**, as an administrator.
- Requires Protect **5.3+**.

The full published surface (OpenAPI 3.1, `servers: [{url: "/integration"}]`):

```
GET    /v1/meta/info                              application info
GET    /v1/nvrs                                   NVR details
GET    /v1/cameras                                all cameras
GET    /v1/cameras/{id}                           camera details
PATCH  /v1/cameras/{id}                           camera settings (OSD, LED, LCD msg, mic…)
GET    /v1/cameras/{id}/rtsps-stream              existing RTSPS URLs
POST   /v1/cameras/{id}/rtsps-stream              create RTSPS URLs for qualities
DELETE /v1/cameras/{id}/rtsps-stream              revoke
GET    /v1/cameras/{id}/snapshot                  image/jpeg  (?highQuality=true|false)
POST   /v1/cameras/{id}/ptz/goto/{slot}           PTZ preset recall
POST   /v1/cameras/{id}/ptz/patrol/start/{slot}   start patrol
POST   /v1/cameras/{id}/ptz/patrol/stop           stop patrol
POST   /v1/cameras/{id}/talkback-session          two-way audio session
POST   /v1/cameras/{id}/disable-mic-permanently
GET    /v1/lights            GET/PATCH /v1/lights/{id}
GET    /v1/sensors           GET/PATCH /v1/sensors/{id}
GET    /v1/chimes            GET/PATCH /v1/chimes/{id}
GET    /v1/viewers           GET/PATCH /v1/viewers/{id}
GET    /v1/liveviews         GET/PATCH/POST /v1/liveviews[/{id}]
GET    /v1/files/{fileType}  POST /v1/files/{fileType}
POST   /v1/alarm-manager/webhook/{id}
GET    /v1/subscribe/devices    WebSocket — device state changes
GET    /v1/subscribe/events     WebSocket — Protect events
```

**Unofficial API** (`/proxy/protect/api/`, cookie auth, `bootstrap`, binary
framed websocket). More capable — continuous PTZ, per-event detail such as
*which* face matched, privacy zones, AI Port. Also undocumented, cookie-based,
and re-broken by Protect releases. Use it only to fill a specific gap you have
measured, behind a property the dealer can turn off.

### 2.2 Getting stream URLs

`POST /v1/cameras/{id}/rtsps-stream` with `{"qualities": ["high","medium","low","package"]}`
returns:

```json
{
  "high":   "rtsps://192.168.1.1:7441/5nPr7RCmueGTKMP7?enableSrtp",
  "medium": "rtsps://192.168.1.1:7441/AbUgnDb5IqIEMidk?enableSrtp",
  "low":    null,
  "package": null
}
```

`GET` returns what already exists; `POST` creates. So the driver can **enable
RTSP itself** rather than making the dealer click through Protect per camera —
a genuine advantage over the stock camera driver.

Note the token is per-channel and can be revoked/regenerated. That is precisely
why the Control4 dynamic-streams API exists (§3.2).

### 2.3 The snapshot problem

`GET /v1/cameras/{id}/snapshot` returns raw `image/jpeg` — but it needs the
`X-API-KEY` header. **A Navigator cannot send that header**; the camera proxy
only knows BASIC/DIGEST auth. So you cannot hand this URL to Control4 directly.

Options, in order of preference:

1. **Per-camera anonymous snapshot.** Log into the *camera's own* web UI at
   `https://<camera-ip>` (user `ubnt`, password = that camera's recovery code
   from Protect) and enable **Anonymous Snapshot**. Then
   `http://<camera-ip>/snap.jpeg` is unauthenticated and Navigator-friendly.
   Caveat: older models return a compressed **640×360**; G6/AI Pro return full
   resolution. Per-camera manual step, which is a dealer-experience cost.
2. **Driver-mediated**, using dynamic snapshot URLs
   (`requires_dynamic_snapshot_urls` + `GET_SNAPSHOT_URLS` +
   `SNAPSHOT_URLS_READY`) — but you still have to return a URL the client can
   fetch, so this only helps if you can mint a credential-bearing URL.
3. **Skip snapshots**, set the camera to stream-only. Acceptable for a v1.

This is also the thing that unblocks the existing SmartBuildOS connector:
`drivers/smartbuildos/driver.lua:1473` is hardware-gated precisely because it
cannot get a snapshot URL out of a generic camera proxy. A Protect driver knows
the answer natively.

### 2.4 The events websocket — much easier than the unofficial one

`wss://<console>/proxy/protect/integration/v1/subscribe/events`, `X-API-KEY`
header, and the payload is **plain JSON** — `{"type": "add"|"update", "item": {…}}`
— not the four-frame deflate-compressed binary format the unofficial API uses.

Event types available:

| Type | Title | Notes |
| --- | --- | --- |
| `ring` | ringEvent | doorbell press |
| `motion` | cameraMotionEvent | |
| `smartDetectZone` | cameraSmartDetectZoneEvent | `person, vehicle, package, licensePlate, face, animal` |
| `smartDetectLine` | cameraSmartDetectLineEvent | line crossing |
| `smartDetectLoiterZone` | cameraSmartDetectLoiterEvent | loitering |
| `smartAudioDetect` | cameraSmartDetectAudioEvent | `alrmSmoke, alrmCmonx, alrmSiren, alrmBabyCry, alrmSpeak, alrmBark, alrmBurglar, alrmCarHorn, alrmGlassBreak` |
| `lightMotion` | lightMotionEvent | floodlight |
| `sensorOpened` / `sensorClosed` | | door/window/garage/leak |
| `sensorMotion`, `sensorAlarm`, `sensorTamper`, `sensorBatteryLow` | | |
| `sensorWaterLeak`, `sensorSmokeTest` | | `smoke, CO, glassBreak` |
| `sensorExtremeValues` | sensorExtremeValueEvent | `temperature, light, humidity` |

Each carries `id`, `modelKey`, `type`, `start`, `end`, `device` (the device id),
plus per-type `metadata`.

`GET /v1/subscribe/devices` is the second socket: device add/update, including
`state: CONNECTED | CONNECTING | DISCONNECTED` — that is your online/offline
signal, and it maps straight onto the status pipeline the platform already runs.

### 2.5 Gaps in the official API you must design around

Measured against the OpenAPI spec, `GET /v1/cameras` returns only:

```
id, modelKey, state, name, mac, isMicEnabled, micVolume, activePatrolSlot,
videoMode, hdrType, osdSettings{}, ledSettings{}, lcdMessage{},
smartDetectSettings{objectTypes, audioTypes},
featureFlags{supportFullHdSnapshot, hasHdr, hasMic, hasLedStatus, hasSpeaker,
             smartDetectTypes, smartDetectAudioTypes, videoModes}
```

So: **no model name, no resolutions, no channel list, no explicit PTZ flag, no
doorbell flag, and no RTSP URLs in the list** (one extra call per camera). You
infer PTZ from `activePatrolSlot`/a probe of `/ptz/goto`, and doorbell-ness from
`hasSpeaker` plus whether it ever emits a `ring` event. The maintainers of the
Home Assistant/`uiprotect` stack list the same gaps and still consider the
official API not yet a replacement for the unofficial one — plan for the
official API to be your floor, not your ceiling.

`mac` is present, which matters: it is the same join key SmartBuildOS already
uses (`installed_devices.mac_normalized`), and the same one Control4 hides in a
network binding's `uuid`.

---

## 3. The Control4 side

### 3.1 Proxy choice

Use the **camera proxy** (`~31` proxy specs live at
`snap-one/docs-driverworks-proxyprotocol-*`; the camera one is
`docs-driverworks-proxyprotocol-camera`). The proxy owns the Navigator UI and
the command vocabulary; your Lua only translates.

Declaration follows the standard pattern — proxy binding ids are **5000–5999**,
`type` 2, and the classname is the proxy name uppercased (`thermostat` →
`THERMOSTAT`, `light_v2` → `LIGHT_V2`, so `camera` → `CAMERA`; confirm against a
stock Control4 camera driver's XML before trusting it):

```xml
<proxies qty="1">
  <proxy proxybindingid="5001" name="UniFi Protect Camera">camera</proxy>
</proxies>
<connections>
  <connection>
    <id>5001</id><facing>6</facing>
    <connectionname>Camera</connectionname>
    <type>2</type><consumer>False</consumer>
    <classes><class><classname>CAMERA</classname></class></classes>
    <hidden>True</hidden>
  </connection>
</connections>
```

### 3.2 Dynamic streams — the mechanism that fits Protect exactly

Protect stream URLs are tokenised and revocable, so do **not** model them as
static addresses. Set:

```xml
<capabilities>
  <requires_dynamic_stream_urls>true</requires_dynamic_stream_urls>
  <dynamic_urls_use_type>MULTIPLE</dynamic_urls_use_type>
  <modes>H264</modes>
  <aspect_ratio>16x9</aspect_ratio>
  <has_extras>true</has_extras>
</capabilities>
```

Then implement `GET_STREAM_URLS`. The client passes optional `CODEC`,
`RESOLUTION`, `FPS`, `useCache`. Two ways to answer:

- **Synchronously**, if you already hold valid URLs — return the XML directly.
- **Asynchronously** — return `<streams generating_key="1234"/>`, go call
  Protect, then fire
  `C4:SendToProxy(5001, 'STREAM_URLS_READY', {KEY=1234, URLS=xml}, 'NOTIFY')`
  with the *same* key. Keys are unique 32-bit ints; start at 1, increment.

Answer shape (map Protect's high/medium/low onto this):

```xml
<streams key="1234" camera_address="192.168.1.1">
  <stream url="rtsps://192.168.1.1:7441/HIGHTOKEN?enableSrtp"   codec="h264" resolution="3840x2160" fps="30">
  <stream url="rtsps://192.168.1.1:7441/MEDIUMTOKEN?enableSrtp" codec="h264" resolution="1920x1080" fps="30">
  <stream url="rtsps://192.168.1.1:7441/LOWTOKEN?enableSrtp"    codec="h264" resolution="640x360"   fps="15">
</streams>
```

Offering low/medium as well as high is not cosmetic — Navigator streaming tiles
show many cameras at once and will pick the cheap stream. Control4's own
guidance asks for a high-res stream for OSD/mobile, 1080p for T4, and a
low-resolution stream for tiles.

When you regenerate or revoke tokens, send
`C4:SendToProxy(5001, 'DYNAMIC_URLS_CHANGED', {}, 'NOTIFY')` so Navigators drop
cached URLs. If you ever mint single-use URLs, switch
`dynamic_urls_use_type` to `SINGLE`.

Dynamic streams landed in **OS 3.3.2**, so `<minimum_os_version>3.3.2</minimum_os_version>`
at the very least; the commercial driver asks for 2.10.6 by using static URLs
instead. Camera Test in Composer Pro will exercise `GET_STREAM_URLS` from
OS 4.0.0 — implement it and dealers get a working Test button for free.

### 3.3 PTZ: presets only

The official API gives you `ptz/goto/{slot}` and patrol start/stop — **no
continuous pan/tilt/zoom**. So:

```xml
<has_pan>false</has_pan> <has_tilt>false</has_tilt> <has_zoom>false</has_zoom>
<has_dynamic_presets>true</has_dynamic_presets>
<number_presets>6</number_presets>
```

and push the preset list on startup and after every change:

```lua
C4:SendToProxy(5001, 'PRESETS_CHANGED', { XML = presetsXml }, 'NOTIFY')
```

where `presetsXml` is `<dynamic_presets><max_presets>N</max_presets><presets><preset><id>…</id><name>base64</name></preset>…</presets></dynamic_presets>`.
Names are **base64**. All preset data must be resent every time, even unchanged
entries.

`has_pan`/`has_tilt`/`has_zoom`/`has_home` are dynamic capabilities, so if you
later add continuous PTZ via the unofficial API you can flip them per-camera at
runtime with `DYNAMIC_CAPABILITY_CHANGED` rather than shipping two drivers.

### 3.4 Events into Control4 programming

Two complementary routes, do both:

- **Driver events** (`<events>` in driver.xml + `C4:FireEvent`) for the rich
  stuff: "Person Detected", "Vehicle Detected", "Package Detected", "Doorbell
  Rang", "Licence Plate Detected". Pair with driver **variables** carrying the
  detail (plate text, zone name) so programming can branch on them — the same
  pattern this repo already uses (`d1d838b`, "The programming bridge: variables
  Composer can branch on").
- **Contact proxy bindings** so motion and Protect sensors appear as first-class
  Control4 contacts, usable by the Security agent and the Sensors screen. The
  contact protocol is two notifications: `OPENED` / `CLOSED` (plus
  `STATE_OPENED` / `STATE_CLOSED` for the steady state). Create them at runtime:

```lua
C4:AddDynamicBinding(101, "CONTROL", true, "Front Door Motion", "CONTACT_SENSOR", false, false)
```

`AddDynamicBinding` accepts `CONTROL` and `PROXY` types. **You must persist and
re-create bindings on every driver init**, or they vanish after a Director
restart; Composer's connections are then restored automatically. And no events
fire before `OnDriverLateInit`, so create them there.

### 3.5 Extras — custom buttons in the camera view

`has_extras=true` plus the Extras interface library gives you buttons, switches,
sliders, text fields and lists inside the camera UI. Natural fits: toggle the
status LED, set the doorbell LCD message, trigger the floodlight, arm/disarm
smart detections. The library ships as `*.lua` files you copy into `src/` and
`require "Extras"`; build the objects in `OnDriverLateInit` (not `OnDriverInit`)
and answer the `PRX_CMD.*` handlers.

### 3.6 Architecture: parent NVR + child camera drivers

A `.c4z` can declare several proxies, but **the count is fixed in XML** — you
cannot grow it to match a site. So:

- **`unifi-protect` (parent)** — holds console address, API key, the two
  websockets, the device inventory, discovery and the shared HTTP client. No
  camera proxy. Exposes a provider CONTROL binding per discovered camera.
- **`unifi-protect-camera` (child)** — one instance per camera, carries the
  camera proxy, a consumer CONTROL binding back to the parent, and forwards
  `GET_STREAM_URLS` / PTZ / Extras over that binding via `C4:SendToDevice`.

This is how NVR drivers are conventionally built, it keeps the project tree
honest (each camera is a device you can place in a room), and it lets the parent
mint stream URLs once and fan them out. Use `C4:AddDynamicBinding` on the parent
to create a camera slot per device found, persisted through `lib.persist`.

### 3.7 TLS against a self-signed console

Two paths, both already solved:

- **HTTP** (`C4:url` via this repo's `lib/http.lua` → `urlDo` → `t:SetOptions`):
  pass `{ ssl_verify_host = false, ssl_verify_peer = false }` as the `options`
  table — `Http:get(url, headers, options)` forwards it. Also consider
  `fail_on_error = false` so you can read a 401 body instead of getting a bare
  rejection.
- **WebSocket** (`vendor/drivers-common-public/module/websocket.lua`):
  `WebSocket:new(url, additionalHeaders, wssOptions)` — `wssOptions` goes
  straight to `C4:NetPortOptions(..., "SSL", opts)`, whose **`VERIFY_MODE`
  defaults to `none`**. wss to a self-signed console works out of the box.

If you would rather verify properly, `ssl_cacerts` (a table of filenames
relative to the `.c4z`) lets you pin the console's certificate.

---

## 4. What you already have in this repo

This is the real argument for building rather than buying — most of the hard
infrastructure is done:

| Asset | Why it matters here |
| --- | --- |
| `vendor/drivers-common-public/module/websocket.lua` | Local fork, upstream v14 + 4 fixes (binding-pool leak, binary opcodes, Host header, 64-bit length). Protect's events socket is a long-lived wss — you want the fixed one. |
| `src/lib/http.lua` | Deferred-based client with credential redaction that already blanks `X-Api-Key`. |
| `src/lib/persist.lua` | Encrypted persistence for the API key + dynamic binding table. |
| `src/lib/bindings.lua`, `events.lua`, `conditionals.lua`, `values.lua` | Handler plumbing. |
| `Makefile` + `dist/driverpackager` | `make build` produces the `.c4z` and copies to `~/Documents/Control4/Drivers`. |
| `test/c4_shim.lua` | Drive `EC.*`/`OPC.*`/`PRX_CMD.*` under LuaJIT with no hardware. |
| `drivers/` holds 2 drivers already | Adding `unifi-protect` + `unifi-protect-camera` is the established shape. |

### Traps this repo already paid for — do not re-pay them

- **`require("drivers-common-public.global.url")` must appear in the driver's own
  require list.** `lib/http.lua` calls the global `urlDo` but does not require
  it. Omit it and `gen-squishy` never bundles the module; every request throws
  inside an xpcall that prints and swallows, so the driver just sits there. This
  shipped once with *no HTTP request having ever worked*.
- **`Http:request` rejects on any non-2xx**, not just transport failure. Branch
  on `err.code` being a number or a 401 API key reads as "console unreachable".
- **Version-stamp per second**, or Composer sees no update.
- **Faked-transport tests cannot catch the require bug.** Assert it with nothing
  faked, driving a real POST into a stubbed `C4:urlPost`.

---

## 5. Suggested build order

1. **Spike the stream** (§0). Everything else is contingent on the answer.
2. **Parent driver, read-only.** Properties: console address, API key, verify-TLS
   toggle. `GET /v1/meta/info` + `GET /v1/nvrs` to prove auth; surface a
   `CONNECTED` conditional. Reuse the pairing-status pattern from
   `drivers/smartbuildos/driver.xml`.
3. **Inventory + dynamic bindings.** `GET /v1/cameras`, `/lights`, `/sensors`,
   `/chimes`. Create one CONTROL binding per camera; persist and restore in
   `OnDriverLateInit`.
4. **Child camera driver, streams only.** Camera proxy,
   `requires_dynamic_stream_urls`, `GET_STREAM_URLS` async +
   `STREAM_URLS_READY`. Confirm Composer's Camera Test passes.
5. **Events socket.** `wss …/v1/subscribe/events`, JSON dispatch → driver events
   + variables. Then `…/v1/subscribe/devices` for online/offline.
6. **Contacts.** Motion and Protect sensors as `CONTACT_SENSOR` bindings.
7. **PTZ presets** (`PRESETS_CHANGED`, `has_dynamic_presets`) and **Extras**
   buttons.
8. **Snapshots**, whichever route §2.3 leaves open.
9. **SmartBuildOS bridge** — optional but this is the differentiator. Forward
   Protect device state and events to the existing ingest routes so Sentinel and
   the property Network tab see cameras alongside UniFi Network gear. Keep
   debounce/escalation policy on the platform, never in the driver.

---

## 6. Open questions to resolve before committing

- **rtsps vs rtsp:7447 on real Navigators** (§0). Blocking.
- **Is port 7447 still open** on the Protect version your fleet runs? Check on a
  current console before designing a fallback around it.
- **Snapshot strategy** — is per-camera Anonymous Snapshot an acceptable dealer
  step, or is stream-only fine for v1?
- **Official vs unofficial API** — is preset-only PTZ enough, or do you need
  continuous PTZ and per-face detail badly enough to take on the cookie-auth
  path?
- **Remote sites.** The driver runs on the controller, on the same LAN as the
  console, so local API access is fine — unlike the platform-side Tier-2 work,
  which is blocked on console reachability. Worth noting that a Protect driver
  *sidesteps* that blocker entirely for any site with a Control4 controller.

---

## Reference links

- DriverWorks camera proxy: https://snap-one.github.io/docs-driverworks-proxyprotocol-camera/
- Dynamic streams: https://snap-one.github.io/docs-driverworks-fundamentals/#proxy-specific-information-camera-proxy-and-dynamic-streams
- DriverWorks API: https://snap-one.github.io/docs-driverworks-api/
- Sample drivers (incl. websocket, dynamic bindings): https://github.com/snap-one/docs-driverworks/tree/master/sample_drivers
- UniFi Protect API reference: https://developer.ui.com/protect/
- Official UniFi API getting started: https://help.ui.com/hc/en-us/articles/30076656117655
- Official-API gap analysis by the uiprotect maintainers: https://github.com/uilibs/uiprotect/discussions/442
- Unofficial API implementation notes: https://github.com/hjdhjd/unifi-protect
- Existing commercial driver: https://drivercentral.io/platforms/control4-drivers/security-systems/unifi-protect/

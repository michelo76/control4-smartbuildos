# VenueFlow: Control4 SDK research

Researched 13 November 2026 from the official documentation sites. Ranking
rule of this repository: documentation is a hypothesis, hardware is the
answer. Each item is marked:

- **DOC**: stated in official Control4 documentation (page named).
- **CODE**: not in the documentation; present in Control4's own published
  driver code.
- **BENCH**: seen on this repository's bench controller (Composer Pro
  2026.10.14, OS 4.3.0), with the driver it was seen in.
- **UNCONFIRMED**: neither. Nothing unconfirmed is a design dependency;
  each is listed again in HARDWARE_VALIDATION.md.

Sources:

- PP: https://snap-one.github.io/docs-driverworks-proxyprotocol/ (UI Button:
  https://snap-one.github.io/docs-driverworks-proxyprotocol-uibutton/)
- API: https://snap-one.github.io/docs-driverworks-api/
- FUND: https://snap-one.github.io/docs-driverworks-fundamentals/
- XML: https://snap-one.github.io/docs-driverworks-xml/
- LIGHT: https://snap-one.github.io/docs-driverworks-proxyprotocol-lightv2/
- BLIND: https://snap-one.github.io/docs-driverworks-proxyprotocol-blind/
- DP: https://github.com/snap-one/drivers-driverpackager
- C4CODE: https://github.com/snap-one/drivers-common-public and
  https://github.com/snap-one/docs-driverworks (sample drivers)

## 1. WebView on the UI Button proxy

| Fact | Standing |
| --- | --- |
| Capability `<web_view_url proxybindingid="5001">controller://driver/<driver_name>/<path></web_view_url>`; the path is rooted at the driver's `www` folder; "the driver name MUST be the same as the driver's filename" | DOC (PP, UI Button Capabilities) |
| `<mobile_web_view_enabled>`: optional boolean, shows the driver in mobile clients when `web_view_url` is present; OS 3.0.0 and later | DOC (PP) |
| UI Button proxy delivered in OS 2.9.0; HTML web view added in OS 2.10.0 | DOC (PP) |
| Rendered on T3, T4 and mobile Navigators ("must self-certify their website on our current browsers (on the T3, T4s and Mobile devices)") | DOC (PP) |
| Browser engines: T4 on OS 3.2.1+ and T3 on OS 3.1.3+ are Gecko 96; T3 on OS 3.1.2 or below is Chrome 30 | DOC (PP) |
| Run-time URL change: `C4:SendToProxy(5001, "URL_CHANGED", { url = "..." })`; an empty value disables the web view; "Navigator will not change the URL of an open web view" | DOC (PP); BENCH (Daypart, PIN Lock, Commissioning) |
| A page served from the driver's own LAN relay at `http://<controller>:<port>/app` loads in the tile | BENCH (Daypart, 13 Nov 2026) |
| Rendering on on-screen (TV) Navigator, the desktop app, OS 4 Navigators | UNCONFIRMED (not stated) |

**Minimum requirement chosen:** `minimum_os_version` 3.3.2, the same as the
other WebView drivers in this repository. That is above the Gecko 96 floor for
both touch screens and above 3.3.1, where `C4:CreateServer` gained its
`identifier` argument. The pages are written for Gecko 96.

## 2. WebView JavaScript API

Requirements (DOC, PP "UI Button Proxy Webview JavaScript API"): Navigator
321.46 or later; mobile app 321.46 or later on OS 3.1.3 or later. "These API
calls can only be made to the driver/protocol hosting the web page."

| Call | Standing |
| --- | --- |
| `C4.sendCommand(commandName: string, params: string, async: boolean, sendToProtocol: boolean = false)`; `params` is "a JSON formatted string of parameters"; `async` true sends to `ExecuteCommand()`, false sends a UI Request; `sendToProtocol` chooses protocol or proxy | DOC |
| `C4.subscribeToDataToUi(sendToProtocol: boolean = false)` | DOC |
| `C4.subscribeToVariable(variableName, protocol)` | DOC (example only) |
| Page callbacks: `onDataToUi(response: string)`, `onSendCommandError(message)`, `onSubscribeToDataToUiError(message)`, `onVariable(response)`, `onSubscribeToVariableError(variableName, message)` | DOC |
| "All responses, even for synchronous commands, will be sent back via the Javascript callback: onDataToUi" | DOC |
| Lua: `C4:SendDataToUI(strCommand, tParams)` (also `C4:SendDataToUI(xml)`), from 1.6.0; "only navigators that have set up subscriptions will receive the sent data"; the Broker converts it to JSON for the page | DOC (API) |
| The exact JSON shape `onDataToUi` receives | UNCONFIRMED (not specified) |
| The reply reaches the page on a real touch screen | **Contradicted in the field**: a touch screen loaded an Atmosphere page whose reply channel "delivers nothing" (this repository, 31 Aug 2026) |

**Consequence.** VenueFlow's primary transport is the LAN relay (section 5),
which is bench-proven. The documented JavaScript API is implemented as the
fallback transport (`EC.VF_COMMAND` and `C4:SendDataToUI("VF_REPLY", ...)`),
the page's reply parser accepts any JSON shape that contains the envelope, and
its use on hardware is a validation item, not an assumption.

## 3. Project enumeration and state

| Call | Standing |
| --- | --- |
| `C4:GetDevices(tFilter, locationFilter)`, 2.10.0; `{}` returns every device, keyed by id, with `driverFileName`, `deviceName`, `roomId`, `roomName` and a `protocol` or `proxies` sub-table | DOC (API); BENCH (`deviceName`, `driverFileName`, `roomId`, `roomName`) |
| Shape of the `proxies` sub-table | UNCONFIRMED. Discovery uses it when present and falls back to the driver file name; the result names its basis |
| `C4:GetProjectItems(...)` with string filters (ALL, LOCATIONS, PROXIES, DEVICES, AGENTS, LIMIT_DEVICE_DATA, JUST_CAPABILITIES, NO_ROOT_TAGS) | DOC; not used by VenueFlow |
| `C4:GetDevicesByC4iName(name)` | DOC; BENCH (used to find the Agent and the Flight Recorder) |
| `C4:GetDeviceVariables(id)`, 2.8.0 | DOC; BENCH (entries carry `name` and `value`, keyed by variable id) |
| `C4:RegisterVariableListener(idDevice, idVariable)` and `OnWatchedVariableChanged(idDevice, idVariable, strValue)`; "will be called immediately after the listener is successfully set"; "will fail if the variable does not exist" | DOC |
| `C4:GetBindingsByDevice(id)` returns a device's network binding with `addr` and `status` | BENCH (Agent inventory) |
| None of these may be called in `OnDriverInit` | DOC |

## 4. Room commands and variables

There is **no Room Driver section** in the proxy/protocol guide, the API
guide, the Fundamentals guide or the XML guide. What VenueFlow sends to a
room therefore rests on Control4's own code and this repository's bench.

| Item | Standing |
| --- | --- |
| `C4:SendToDevice(roomId, "SELECT_VIDEO_DEVICE", { deviceid = id })` | CODE (universal minidriver `um_driver2.lua`) |
| `C4:SendToDevice(roomId, "SELECT_AUDIO_DEVICE", { deviceid = id })` | CODE (media service proxy player); BENCH (Daypart: command seen leaving, 13 Nov 2026) |
| `C4:SendToDevice(roomId, "ROOM_OFF", {})` | CODE (`drivers-common-public/global/msp.lua`) |
| `C4:SendToDevice(roomId, "SET_VOLUME_LEVEL", { LEVEL = n })` | BENCH (Daypart: command seen leaving, 13 Nov 2026); not in official docs as a room command |
| `MUTE_ON` / `MUTE_OFF` sent to a room | **UNCONFIRMED** |
| Room variable ids: CURRENT_AUDIO_DEVICE 1001, CURRENT_VIDEO_DEVICE 1002, POWER_STATE 1010, CURRENT_VOLUME 1011, HAS_DISCRETE_VOLUME 1016, HAS_DISCRETE_MUTE 1017, IS_MUTED 1018 | CODE (`drivers-common-public/global/lib.lua`, `ROOM_VARS`) |
| A room actually changing its picture or sound in response | **UNCONFIRMED on the bench**: the commands were seen leaving the driver; the room's response was not observed |

**Consequence.** Every room command lives in one module
(`src/venueflow/adapter_c4.lua`). VenueFlow never treats a dispatched command
as done: it waits for the room variable to report the requested value, and
reports "not confirmed" otherwise. If a command name proves wrong on
hardware, the symptom is a visible "not confirmed", and the fix is one line.

## 5. Driver-hosted server

| Call | Standing |
| --- | --- |
| `C4:CreateServer(port, [delimiter], [useUDP], [identifier])`, 2.10.0; identifier from 3.3.1; port 0 is ephemeral | DOC (API, Server Socket Interface); BENCH |
| `OnServerDataIn(handle, data, address, port, identifier)`: `address` is "the IP address of the remote endpoint" | DOC |
| `OnServerConnectionStatusChanged(handle, port, status, address, identifier)`, `OnServerStatusChanged(port, status, identifier)` | DOC |
| `C4:ServerSend(handle, payload)`, `C4:ServerCloseClient(handle)`, `C4:DestroyServer(port)` | DOC; BENCH |
| Port restrictions | None documented; drivers must not "steal ports from Director or from each other". VenueFlow uses 47861 (the repository's relays use 47831, 47841, 47851) |
| Largest reply `C4:ServerSend` delivers in one call | UNCONFIRMED. The bench has served a page of about 40 kB; VenueFlow's pages are several hundred kB and a floor-plan picture can be 600 kB |
| A driver cannot read its own packaged files on OS 4.3 (`C4:FileSetDir("C4Z_ROOT")` is refused) | BENCH (13 Nov 2026). Pages are compiled into the driver as Lua modules |

## 6. Persistence

| Call | Standing |
| --- | --- |
| `C4:PersistSetValue(name, value, encrypted)`, `PersistGetValue(name, encrypted)`, `PersistDeleteValue(name)`, 2.10.0; values may be number, string, boolean or table | DOC (API) |
| Size limits | UNCONFIRMED (none documented). VenueFlow bounds what it stores: a draft up to 600 kB encoded, up to 12 pictures of 600 kB, five previous versions |
| Encrypted values have not always survived a driver update | BENCH (earlier finding of this repository). VenueFlow keeps only regenerable values encrypted (the tile token and the random seed) |

## 7. Timers and time

| Call | Standing |
| --- | --- |
| `C4:SetTimer(nDelay, fCallback, bRepeat)`, 2.7.0, milliseconds | DOC; BENCH |
| How many timers a driver may hold | UNCONFIRMED. VenueFlow holds a fixed handful: one tick, one save, one command queue, one confirmation sweep, one per waiting program, one per installer test |
| `C4:GetTimeZone()`, 3.0.0: the project's zone, for example `America/Denver`; "same as Composer, Project Settings, Time Zone" | DOC |
| What `os.date("*t")` returns in a driver (local time in that zone, daylight saving applied) | UNCONFIRMED in the documentation; BENCH for a schedule: Daypart's blocks, which use `os.date("*t")`, started at the right wall-clock minute on 13 Nov 2026. A real daylight-saving change has not been observed |

## 8. Package

| Fact | Standing |
| --- | --- |
| A `.c4z` is a zip with `driver.xml` and `driver.lua` at its root and a `www` folder | DOC (FUND) |
| DriverPackager manifest: `<Driver type="c4z" name="..." squishLua="true">` with `<Item type="dir" c4zDir="www" name="www" recurse="true"/>` and `<Item type="file" .../>` | DOC (DP); BENCH |
| `<script file="driver.lua" jit="1">`; `encryption="2"` only when the driver is to be encrypted | DOC (XML); BENCH |
| A proxy-less driver needs `<combo>true</combo>` to appear in Composer's search | BENCH |
| Property type `PASSWORD` makes Composer Pro 2026.10.14 fail on add; use `STRING` with `<password>true</password>` | BENCH |

## 9. Lighting and shades

| Command | Standing |
| --- | --- |
| Advanced Lighting Scenes agent: `ACTIVATE_SCENE`, `DEACTIVATE_SCENE`, `TOGGLE_SCENE`, each with `SCENE_ID` | DOC (LIGHT, Asynchronous Commands) |
| Light: `SET_BRIGHTNESS_TARGET { LIGHT_BRIGHTNESS_TARGET, RATE }`, `TOGGLE` | DOC (LIGHT) |
| Light: `RAMP_TO_LEVEL { LEVEL, TIME }` | DOC (API example of `C4:SendToDevice`) |
| Blind: `SET_LEVEL_TARGET { LEVEL_TARGET }` | DOC (BLIND) |
| The device id of the Advanced Lighting Scenes agent in a project | UNCONFIRMED: the installer enters it |
| Light `ON` / `OFF`, blind `UP` / `DOWN` / `STOP` as commands from another driver | Not in the documentation; VenueFlow does not offer them as built-in choices |

A lighting preset in VenueFlow is exactly one of the documented commands (or
a custom one the installer types), sent without assuming feedback.

## Not confirmed: the complete list

1. The reply of `C4.sendCommand` reaching the page on a touch screen.
2. The JSON shape `onDataToUi` receives.
3. `MUTE_ON` / `MUTE_OFF` as room commands.
4. A room changing source, volume and power in response to the room commands
   (seen leaving the driver, response not observed).
5. The `proxies` field of `C4:GetDevices`.
6. `C4:ServerSend` with replies of several hundred kB.
7. Persistence size limits.
8. The number of timers a driver may hold.
9. `os.date` across a real daylight-saving change.
10. Rendering on Navigators other than T3, T4 and the mobile apps.
11. A `STRING` command parameter is used for scene names because it is
    bench-proven; a drop-down (`DYNAMIC_LIST` with `GetCommandParamList`)
    would be nicer and has not been tried on the bench.

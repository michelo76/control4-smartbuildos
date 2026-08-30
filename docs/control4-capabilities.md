# Control4 SDK Capabilities — Mode Composer findings

Research date: 2026-08-29. Sources: official snap-one GitHub docs repos
(`docs-driverworks-api`, `docs-driverworks-fundamentals`, `docs-driverworks-xml`,
`docs-driverworks-proxyprotocol-{keypad,uibutton,lightv2,blind,tstat,lock,security,contact,fan}`),
plus local ground-truth drivers (`security-light.c4z`, `room_control_keypad.c4z`,
`driverworks_bond_keypad.c4z`, `door_autolock.c4z`, `LEDWizard.c4z`,
`experience-button-scenario.c4z`, `control4_lux_*` first-party drivers).

Ranking rule of this repo applies: docs are a hypothesis, hardware is the answer.
Everything below is marked **VERIFIED_BY_DOCS**, **VERIFIED_BY_EXAMPLE** (a real
shipped driver does it), or **UNCONFIRMED**. Nothing UNCONFIRMED may be a design
dependency.

## Keypad button input

| Capability | Status | API | Limitation / approach |
| --- | --- | --- | --- |
| Receive button presses | VERIFIED_BY_DOCS + EXAMPLE | `BUTTON_LINK` consumer CONTROL binding (`type 1`, `facing 6`, `consumer True`); events arrive in `ReceivedFromProxy` as `DO_PUSH` / `DO_CLICK` / `DO_RELEASE` | One binding per keypad button; the dealer binds the button's "Button Link" to us in Composer Connections. `security-light.c4z`, `room_control_keypad.c4z` do exactly this. |
| Multi-tap from the keypad itself | VERIFIED_BY_DOCS (proxy level) | `KEYPAD_BUTTON_ACTION` ACTION values 0=Release 1=Push 2=Click 3=Double 4=Triple | These ride the keypad *proxy*, not BUTTON_LINK, and the docs warn many keypads never send multi-click over BUTTON_LINK. **We therefore implement our own gesture state machine from PUSH/CLICK/RELEASE timing** and do not depend on hardware multi-tap. |
| Dynamic BUTTON_LINK bindings | VERIFIED_BY_EXAMPLE | `C4:AddDynamicBinding(id, "CONTROL", true, name, "BUTTON_LINK", false, false)` (`room_control_keypad`) | Must be persisted + restored in `OnDriverInit` (house `lib.bindings` does this). |
| Runaway hold | VERIFIED_BY_DOCS | — | Docs warn DO_RELEASE can arrive late if Director is busy. Gesture engine caps hold duration and treats a missing release as cancel after a bounded timeout. |

## Keypad LEDs

| Capability | Status | API | Limitation / approach |
| --- | --- | --- | --- |
| Two-color LED per bound button | VERIFIED_BY_DOCS + EXAMPLE | Over the BUTTON_LINK binding: `SendToProxy(idBinding, "BUTTON_COLORS", {ON_COLOR={COLOR_STR="RRGGBB"}, OFF_COLOR={COLOR_STR="RRGGBB"}}, "NOTIFY")` + `MATCH_LED_STATE {STATE}`; must answer inbound `REQUEST_BUTTON_COLORS` by re-sending both | This is the hardware-agnostic path and our primary LED mechanism. |
| Direct-to-keypad LED commands | VERIFIED_BY_DOCS + EXAMPLE | `SendToDevice(keypad, "KEYPAD_BUTTON_COLOR", {BUTTON_ID, ON_COLOR, OFF_COLOR, CURRENT_COLOR})`, `KEYPAD_ALL_BUTTON_COLOR`, `..._CLEAR` | Used by the Agent's IDENTIFY_DEVICE already. Requires knowing BUTTON_ID; we prefer the binding path. |
| Blink / pulse behaviors | **UNSUPPORTED (official)** | No blink API exists in the public keypad proxy protocol (zero doc hits). Control4's lux driver has a `BLINK_LEDS` *driver action* — first-party only. | We simulate "activating/countdown" feedback by toggling `MATCH_LED_STATE` on a 1 s timer, only while a transition/hold is in progress (bounded duration, one small NOTIFY per flip, per subscribed binding). Steady states are always static colors. |

## Navigator / Experience buttons

| Capability | Status | API | Limitation / approach |
| --- | --- | --- | --- |
| Tappable mode button in Navigator | VERIFIED_BY_DOCS + EXAMPLE | `uibutton` proxy (OS 2.9+). `<proxy proxybindingid="5001">uibutton</proxy>` + UIBUTTON provider connection. Tap arrives as `SELECT` in `ReceivedFromProxy` with room `Device ID` + `Menu`. | One proxy = one button. Proxy count is fixed in XML → per-mode buttons live in a **child driver** (`smartbuildos-mode-button`), one instance per mode. |
| Custom icons + active state | VERIFIED_BY_DOCS + EXAMPLE | `<navigator_display_option proxybindingid><display_icons>` with sized `<Icon>` entries (300/90/70 px PNG documented; 512/1024 shipped by first-party) using `controller://driver/<c4z-name>/icons/...` paths; runtime switch via `SendToProxy(5001, "ICON_CHANGED", {icon="<stateId>"})` | Icon files are baked into the c4z; `<state id>` entries enumerate the selectable looks. We ship a curated icon library as states and pick per mode. ⚠ icon URLs embed the c4z filename — renaming the driver breaks them. |
| Driver-hosted Navigator webview | VERIFIED_BY_DOCS + EXAMPLE | `web_view_url` capability on the uibutton proxy; JS `C4.sendCommand`/`subscribeToVariable` | Available for a richer V2 mode panel; not a V1 dependency. |

## Commanding devices (the mode engine's hands)

`C4:SendToDevice(idDevice, strCommand, tParams)` is official (since 1.6.0), works
binding-free against any project device's proxy id, and is the documented example
for exactly this use (`RAMP_TO_LEVEL` at a light). Not safe in `OnDriverInit`.

| Class | Commands (VERIFIED_BY_DOCS unless noted) |
| --- | --- |
| Light (light_v2) | `ON`, `OFF`, `TOGGLE`, `RAMP_TO_LEVEL {LEVEL 0-100, TIME ms}`; OS 3.3+ `SET_BRIGHTNESS_TARGET`. `ON`/`OFF` VERIFIED_BY_EXAMPLE (`room_control_keypad`). |
| Blind/shade | `SET_LEVEL_TARGET {LEVEL_TARGET}`, `TOGGLE`; MOVING/STOPPED notifications. |
| Thermostat | Proxy: `INC/DEC_SETPOINT_*`, `SET_PRESET`. Protocol pass-through ("supported by most tstat drivers"): `SET_SETPOINT_HEAT/COOL/SINGLE`, `SET_MODE_HVAC`, `SET_MODE_FAN`, `SET_MODE_HOLD`. Setpoints clamped by us to a sane band. |
| Lock | `LOCK {}`, `UNLOCK {}`. |
| Security partition | `PARTITION_ARM {ArmType, UserCode?, Bypass?, InterfaceID}`, `PARTITION_DISARM {UserCode, InterfaceID}`, `ARM_CANCEL`. |
| Fan | `ON`, `OFF`, `SET_SPEED {SPEED}`, `GET_CURRENT_STATE`. |
| Room (send to room device id) | `ROOM_OFF {}`, `SELECT_AUDIO_DEVICE {deviceid}`, `SELECT_VIDEO_DEVICE {deviceid}`, `SET_VOLUME_LEVEL {LEVEL}` — VERIFIED_BY_EXAMPLE (`room_control_keypad`). Query: `GET_LIGHT_DEVICES` etc. return XML. |
| Garage/relay | `OPEN {}` / `CLOSE {}` (relay-style; already used by the Agent). |
| `C4:RoomSetSource` | **UNCONFIRMED — does not exist in docs or any local driver. Never use.** |

## Reading state (the mode engine's eyes)

| Capability | Status | API |
| --- | --- | --- |
| Read any device's variables | VERIFIED_BY_DOCS + EXAMPLE | `C4:GetDeviceVariables(id)` (all, with metadata, 2.8+), `C4:GetDeviceVariable(id, varId)` |
| Live variable tracking | VERIFIED_BY_DOCS + vendored | `C4:RegisterVariableListener(idDevice, idVariable)` + `OnWatchedVariableChanged`; wrapped by `drivers-common-public/global/handlers.lua:711`. Fails if the variable doesn't exist yet → register in `OnDriverLateInit`, re-register on churn. |
| Contact sensors | VERIFIED_BY_DOCS + EXAMPLE | Consumer binding class `CONTACT_SENSOR`; `OPENED`/`CLOSED` (transitions) and `STATE_OPENED`/`STATE_CLOSED` (steady-state) in `ReceivedFromProxy` (`door_autolock.c4z`). |
| Security state | VERIFIED_BY_DOCS | Partition variables: `PARTITION_STATE` (ARMED, ALARM, DISARMED_READY, DISARMED_NOT_READY, EXIT_DELAY, ENTRY_DELAY, …), `ARMED_TYPE`, `ALARM_STATE`. Listen via `RegisterVariableListener`; find the partition via room var `SECURITY_ID`. |
| Project/rooms | VERIFIED_BY_DOCS + field-measured | `C4:GetDevices({})` (`deviceName`, `driverFileName`, `roomId`, `roomName` — NOT `name`), `C4:GetProjectItems(filters)` (unsafe in OnDriverInit), room variables (1000-series). Device classification must be by variable signature, not name (four measured impostors — see the Agent's `looksLikeThermostat`). |
| Other drivers' events | VERIFIED_BY_DOCS + vendored | `C4:RegisterDeviceEvent` / `OnDeviceEvent`; wrapped at `handlers.lua:400`. |

Field-measured facts that override docs (see `control4-measured-api-facts` notes):
`TEMPERATURE` is deci-Celsius (read `TEMPERATURE_F`/`_C`); `GetBindingsByDevice`
nests under `bindings`; keypad membership needs a positive signature test.

## Timers, persistence, Composer programming surface

| Capability | Status | Notes |
| --- | --- | --- |
| Timers | VERIFIED_BY_DOCS | `C4:SetTimer(ms, cb, repeat)` (2.7+), self-protecting against backlog. House rule: use `drivers-common-public/global/timer.lua` named timers. Max concurrent timer count is **UNCONFIRMED** — we keep a bounded pool (gesture timers per binding + one engine tick + one schedule tick), never one timer per device action. |
| Persistence | VERIFIED_BY_DOCS | `C4:PersistSetValue/GetValue(name, [encrypted])` (2.10+), usable before LateInit; tables OK. House `lib.persist` wraps this with a migrations hook. Field caveat: encrypted persist has not always survived driver updates — nothing irrecoverable may live only in encrypted persist. |
| Variables | VERIFIED_BY_DOCS | `C4:AddVariable` — **must be added in a stable order** (Composer binds computed ids); house `lib.values` preserves ordering with tombstones. |
| Events | VERIFIED_BY_DOCS + house-measured | Static XML `<events>` register only at instance-add; always re-`C4:AddEvent` at init in `pcall`. Dynamic per-mode events supported via `C4:AddEvent(id, name, desc)`; ids frozen forever. |
| Conditionals | VERIFIED_BY_DOCS | Static XML + `TestCondition(name, tParams)`; dynamic via global `GetConditionals()` (house `lib.conditionals`). Types: BOOL, NUMBER(+LOGIC), STRING, LIST, ROOM, DEVICE. |
| Composer commands | VERIFIED_BY_DOCS | `<commands>` with param types incl. `DEVICE_SELECTOR`, `LIST`, `DYNAMIC_LIST` (refreshed via `C4:UpdatePropertyList`), `RANGED_INTEGER`, `STRING`. This is how device selection UX works without a webview. |
| Composer config webview tab | **UNSUPPORTED for third parties** | The `<tabs>` element first-party lux drivers use appears in zero official docs. We do NOT depend on it; configuration is properties + actions + commands, documented as a limitation (spec §63). |

## Consequences baked into the architecture

1. **Gesture detection is ours.** BUTTON_LINK guarantees only PUSH/CLICK/RELEASE;
   the deterministic state machine in `src/modes/gesture.lua` derives
   tap/double/triple/hold from timing, with configurable windows.
2. **LED "pulse" is a bounded simulation.** Static colors for steady states;
   1 Hz `MATCH_LED_STATE` toggling only during transitions/holds/countdowns.
3. **Per-mode Navigator buttons are child driver instances** (fixed proxy count),
   fed name/icon/color/active by the manager over a CONTROL binding + the
   SendToDevice fallback path (same dual-path pattern as the Protect suite).
4. **Device adapters command via SendToDevice and read via variables**, with
   signature-based classification and declared capabilities per adapter.
5. **Restore/capture is capability-gated.** A device whose adapter cannot read
   state is reported `unsupported` for capture/restore — never silently claimed.
6. **No sunrise/sunset dependency in V1** — no official sunrise API was
   confirmed; V1 schedules are time + days-of-week. (`C4:GetLocationInfo`
   exists for a computed V2 approach.)

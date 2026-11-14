# Load Shedding - design

Status: implemented on `feat/dealer-tools`; simulator-tested only
(`test_loadshed_engine.lua`, `test_loadshed_driver.lua`); bench validation
owed. SKU `SBOS_LOAD_SHEDDING`, module id `load_shedding`, combo driver (no
proxy). No Agent module yet (licensing only).

## What it is

A vendor-neutral outage load shedder. Pure rules in `src/loadshed/engine.lua`
(injected clock, timers and device I/O); `driver.lua` maps them to Composer
events, variables, conditionals, properties, the variable listeners and the
Flight Recorder.

## Rules (all tested)

| Topic | Rule |
| --- | --- |
| Tier 1 | Sheds the moment an outage starts. |
| Tier 2, 3 | Shed at or below their battery percent when a fresh reading exists; otherwise after N minutes of outage (0 = off). A tier needs the tier below shed. |
| Prior state | Read before shedding, saved per load with a snapshot of its definition. Already-off / open / past-setback loads are left alone and not restored. Unknown thermostat state: left alone. |
| Power back | Hold `Stable Hold Seconds`; an outage inside the hold abandons it (flap counted, nothing restored). |
| Restore | Reverse order of shedding, tier 3 -> 1, `Tier Delay Seconds` apart. An outage mid-restore stops it; restored tiers are shed again. |
| Restore check | A restore is not trusted: the load is read back after `Restore Retry Seconds` (15); not back -> command resent, up to `Restore Retries` (2), then `restore_failed` (Flight Recorder marker, Load Error event). Unreadable state (`restoreConfirmed` returns nil): retries only, ends in `restore_unverified` (log only). Pending checks (`verify`) are persisted and re-armed on boot; a new shed of the slot drops its check. |
| Manual shed | `SHED_TIER` with no outage starts a `Manual Shed Auto-Restore Minutes` timer (60; 0 = never). It, `RESTORE_ALL` and `SET_OUTAGE` Off all restore it; an outage starting takes it over. Timer re-armed from `manual_at` after a reboot. |
| Persistence | `ls_state_v1`, arrays only (JSON-safe), written **at once** after any shed, restore, outage or hold change (engine `changed` event with `urgent=true`, see `M.URGENT`) and on destroy; only plain chatter (battery readings) keeps the 2 s debounce. Outage, hold (resumes with the time already served) and an interrupted restore all resume. |
| Inputs | Sensor or variable by property, or `WATCH_*_VARIABLE` (VARIABLE_SELECTOR gives `"deviceId,variableId"`, saved in `ls_sources_v1`). Only a changed raw value acts, so `SET_OUTAGE` is not undone by the poll. Listener plus a 60 s poll. |
| Re-shed | Opt in; ignored within 3 s of our own command; at most 5 per load per outage. Navigator cannot be locked; the manual says so. |
| Licence | `license.enforces()` -> `setReadOnly(true)`: restore everything first, then refuse every command and ignore inputs. Uncertain statuses never halt. On un-halt the input is re-read. |
| Test mode | `TEST_MODE` lists the shed and restore plan; no command sent, no state touched. |

## Device I/O (UNVERIFIED on a controller)

Commands go to the device id with `C4:SendToDevice`, as the Mode Composer
does: lights `OFF` / `ON` / `RAMP_TO_LEVEL {LEVEL, TIME}`, relays `OPEN` /
`CLOSE`, thermostats `SET_SETPOINT_HEAT|COOL {FAHRENHEIT}`. State comes from
`C4:GetDeviceVariables`. Variable names are the ones the Mode Composer
adapters use.

## Flight Recorder

`RECORD_EVENT {NAME, DETAIL, CHANNEL="load-shedding"}` to the device whose
driver file is `smartbuildos-flight-recorder.c4z`, found through
`C4:GetDevices` (re-looked-up at most every 5 minutes when absent). Quiet when
absent. No private log. Markers: Outage started, Tier N shed, Tier N restored,
Outage ended, Power back (restore delayed), Grid flapped, Load re-shed, Load restore not confirmed, Manual shed auto-restored.

## Shared-file notes (nothing edited)

- Nothing needed in `src/sbos/*`, `src/lib/*`, the Makefile or the shim. The
  driver tests pass `tostring_return_period` themselves because the repo's
  `JSON.lua` expects it from `drivers-common-public.global.lib`.
- Mode driver integration: `Set Outage` can be called from any Mode.

## Agent contract needed

Not implemented, nothing sent today. To get an outage log into Studio the
Agent would accept it like other module records.

**Envelope prefix.** A new reserved event-type prefix in
`src/sbos/envelope.lua` `M.PREFIXES` (and the web repo's validator):
`outage.` with module id `load_shedding`. Event types:
`outage.started`, `outage.tier_shed`, `outage.tier_restored`,
`outage.restore_delayed`, `outage.flap`, `outage.restored`,
`outage.load_resheded`, `outage.load_error`.

**Payload** (JSON, <= 4 KiB, strings <= 512 chars, as the envelope limits):

```json
{
  "outage_id": "<boot_id>-<sequence of outage.started>",
  "tier": 2,
  "reason": "battery | no battery data | outage | manual",
  "battery_percent": 41,
  "loads": [{ "slot": 2, "kind": "light", "device_id": 102, "name": "Kitchen Lights", "result": "shed | left alone: already off | failed" }],
  "hold_s": 120,
  "flaps": 0,
  "duration_s": 5320
}
```

`evidence_source`: `requested` for sheds and restores (we sent a command; a
device did not confirm), `observed` for the grid input and battery value,
`derived` for tier decisions. `quality`: `confirmed` for typed numeric values,
`unreviewed_text` for the device name. The Agent derives tenant, property and
system as for every record; `correlation_id` is the `outage_id` so the whole
outage reads as one story in Studio.

**Transport.** Through `sbos.moduleclient` to the Agent as the Flight
Recorder does; Load Shedding would emit through the same queue rather than
HTTP. An outage record is also the natural basis for a post-outage summary
(how long, how deep, which tiers, whether anything failed to restore).

**Add-on idea: vendor adapters.** Optional separate drivers or Agent modules
that translate a vendor's feed into the two facts this driver takes: a
`SET_OUTAGE` On/Off and a `SET_BATTERY` percent (or a variable it can watch).
Examples are a battery gateway, a smart panel or a generator controller. The
shedder stays neutral and unlicensed to any vendor; adapters are licensed on
their own SKUs and can be added without touching the shedding rules.

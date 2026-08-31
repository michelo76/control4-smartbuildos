# Atmosphere — SmartBuildOS Platform Integration

**None of this is required for weather automation.** The driver's independence
rule: everything weather-related works with no SmartBuildOS pairing and no
platform reachability. Pairing the project's SmartBuildOS Agent adds management
conveniences on top — it is never in the weather data path.

## What pairing adds

### 1. Licensing

The Agent answers entitlement for `SBOS_ATMOSPHERE` — see
[LICENSING.md](LICENSING.md). Without it: `LEGACY`, fully operational.

### 2. Fleet status

Atmosphere registers with the Agent at startup (`SBOS_REGISTER_DRIVER` with its
SKU and version), which puts it in the Agent's driver inventory. Through the
existing Driver Cloud machinery that inventory feeds `driver_installations`
(which systems run Atmosphere, at what version) and `driver_events`
(Studio-visible event stream), keyed off the SKU with no Atmosphere-specific
plumbing.

*Status:* registration is implemented and the Driver Cloud tables are generic.
The architecture additionally calls for Atmosphere to report weather-service
health (API up/stale, last refresh times, resolved location/office/station) via
the Agent's `SEND_EVENT`/`REPORT_*` path — that reporting is **not yet
implemented** in the driver; today the same detail is available locally via
`Print Diagnostics To Log` and the WebView diagnostics block.

### 3. Remote settings

The design (mirroring the proven `control4_monitor_config` precedent — the
platform never dials the controller):

1. A per-system `atmosphere` config block rides the **Agent heartbeat response**
   — declarative config on an existing outbound poll, no inbound channel.
1. The Agent forwards it to the driver via
   `SendToDevice(…, "SBOS_ATMOSPHERE_CONFIG", { settings = <JSON>, requester = <agent device id> })`.
1. The driver decodes (pcall'd; undecodable payloads are refused loudly) and
   validates the patch against its **versioned settings schema** — the *same*
   validator used by the WebView app and Composer
   (`src/atmosphere/settingsstore.lua`, `settings_version` currently 1, with a
   migration table so schema changes never lose installed settings).
1. Validation is field-by-field: one bad field never discards nine good ones.
   Every refusal carries a `path` + `reason` and is logged. Invalid config is
   never silently applied.
1. The driver acks the requester with `SBOS_ATMOSPHERE_CONFIG_ACK`
   `{ applied = "true"|"false", refused = <count>, settings_version }` so the
   Agent can report the outcome upstream (the architecture routes that into a
   `CONFIGURATION` driver_event as the audit trail).

What remote settings can carry is exactly the settings document: units,
threshold overrides (each bounds-checked — a typo'd `3200` cannot brick a site),
alert sensitivity + class filters, radar options, display
theme/animation/default screen, notification and simulation options.

*Status:* the driver side (steps 2–5) is implemented and tested
(`test_atmosphere_driver.lua` exercises accept + refuse + ack through the same
code path via the WebView verb). The Agent-side forwarding and the platform-side
`driver_atmosphere_config` table + heartbeat block (step 1) are **pending** —
the Agent has no `SBOS_ATMOSPHERE_CONFIG` handling yet and the platform
migration has not been written.

### 4. Notifications (planned)

Weather alert push through the platform's `dispatchNotification` (`control4`
channel): customer kinds (`weather.alert_warning`, `weather.freeze_expected`, …)
and dealer kinds (`driver.atmosphere_offline`, `driver.weather_stale`, …),
deduped on the **alert's own CAP id/onset** — never wall-clock time. Not yet
implemented on either side; the driver's `notifications.push_alerts` setting
reserves the toggle.

## Identity and trust boundaries

- Company/property identity always comes from the Agent's authenticated pairing
  (`authenticateController` on the platform), never from message bodies.
- The driver trusts the Agent's channel for remote settings but still validates
  every field — the schema is the contract, not the sender.
- No platform credentials exist in this driver; the only secrets on the
  controller are the Agent's own (unchanged model).

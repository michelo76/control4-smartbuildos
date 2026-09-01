# Atmosphere — SmartBuildOS Platform Integration

Weather safety remains independent of platform reachability, but the
SmartBuildOS Agent is the required licensing authority for this Control4
product. Its entitlement cache fails open during uncertainty so a cloud outage
never disables weather automation.

## What pairing adds

### 1. Licensing

The Agent answers entitlement for `SBOS_ATMOSPHERE` — see
[LICENSING.md](LICENSING.md). All standalone drivers follow this process;
suite children inherit the entitlement of their licensed gateway.

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

### 4. Cloud state mirror (app data off-LAN)

Off the LAN the Navigator app has no data: the JS API is dead on real Navigators
(field-measured) and the LAN relay is unreachable. Pairing adds the fix — the
driver's UI state is mirrored to SmartBuildOS and the app reads it back as a
read-only channel. End to end:

1. **Driver → Agent (provisioning ask).** Atmosphere sends
   `SBOS_DRIVER_CLOUD_REQUEST {sku, app_token, requester}` over the bindingless
   device path. The Agent answers only for an authorized subscription,
   perpetual, grace or trial entitlement.
1. **Agent → platform (credential exchange).** Using its paired-controller
   bearer, the Agent calls `/api/driver-cloud/state/provision`. The response is
   a narrow upload bearer HMAC-bound to controller + `SBOS_ATMOSPHERE` + this
   installation's app token. The main Agent bearer and per-controller signing
   secret never leave `smartbuildos.c4z`.
1. **Atmosphere → platform (direct HTTPS push).** The Agent forwards the narrow
   bearer as `SBOS_DRIVER_CLOUD`; Atmosphere then POSTs
   `{driver_sku, state, app_token}` directly to
   `/api/driver-cloud/state/direct`. This avoids inter-driver HTTP entirely —
   field hardware proved that an Agent request to a sibling driver's
   `CreateServer` listener hangs through both loopback and the controller LAN
   address.
1. **Capability read becomes ready.** The direct push answers with `view_url`
   and the controller's `SBOS-XXXXXX` support id. Atmosphere adds `cloud=` +
   `cid=` to the app URL alongside its independent LAN relay pointer.
1. **Public capability read.** The app GETs `view_url?c=<support id>&k=<token>`
   with no session — the URL pair is the whole credential, same shape as the
   calendar capability URLs. The read compares the presented token's hash in
   constant time, answers a uniform 404 for *every* failure (malformed params,
   unknown support id, no stored hash, wrong token — the endpoint cannot be used
   to probe which support ids exist), refuses mirrors older than **24 h** (a
   mirror nobody updated in a day is itself the stale artifact — serving it as
   current would be fabrication), and dies with the pairing: **revoking the
   controller kills the capability** (revocation sets `revoked_at`, the row is
   kept, the read 404s). Open CORS + `Cache-Control: no-store`; rate-limited.

The app treats the mirror as strictly read-only (settings disabled, writes
dropped) and climbs back to the JS API / LAN relay every 5 minutes.

*Status:* implemented with cross-language security tests and awaiting a hardware
field pass. The former Agent-pulls-relay path remains only for compatibility
with older drivers; current Atmosphere does not use it.

### 5. Notifications (planned)

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
- No platform credentials exist in this driver; the only platform secrets on the
  controller are the Agent's own (unchanged model). The driver's one credential
  is its self-minted app relay token — see [SECURITY.md](SECURITY.md) for its
  threat model; the platform stores only its hash.

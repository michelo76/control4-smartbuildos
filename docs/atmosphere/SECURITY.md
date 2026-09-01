# Atmosphere — Security & Threat Model

Atmosphere's security story is mostly about what it *doesn't* have: no
third-party accounts, no PII beyond the property's coordinates, no platform
credentials. What remains: untrusted external text, a validated settings
surface, and — since the LAN relay landed — one inbound LAN listener guarded by
one self-minted token.

## Assets and trust boundaries

| Boundary                                                                           | Trust posture                                                                                                                          |
| ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `api.weather.gov` / `radar.weather.gov` / `mapservices.weather.noaa.gov` responses | Untrusted data. Government sources, but treated as hostile input: pcall'd decodes, per-field guards, QC filtering                      |
| Navigator WebView page                                                             | Driver-hosted, but its inputs (NWS text) are untrusted; its settings writes are validated like anyone else's                           |
| LAN relay clients (port 47815)                                                     | Untrusted network peers: token-gated, chunk-capped, routed through the same validators as every other write path                       |
| SmartBuildOS Agent channel                                                         | Authenticated at pairing (platform side); the driver still validates every settings field — the schema is the contract, not the sender |
| Composer / programming                                                             | Trusted operator surface                                                                                                               |

## No secrets in the weather path

NWS is keyless — there is nothing to steal. No API keys, tokens, passwords, or
account identifiers exist anywhere in the weather pipeline. The platform secrets
on the controller belong to the SmartBuildOS Agent (its existing, unchanged
model: per-controller HMAC secret in encrypted persist); this driver never sees
them.

The integration test asserts the WebView document contains no `token`/`secret`
strings — a tripwire, not the whole defense.

## The app relay token

The one credential this driver now owns, guarding the LAN relay's `/state` read
and all its writes (`/settings`, `/refresh`, `/simulate`), and — hashed — the
cloud mirror's public read.

- **Minting.** 32 hex chars from `C4:HMAC("SHA256", …)` over local entropy
  (time, clock, device id, a table address). The seed is not secret; the output
  is unguessable. Minted once, stored in encrypted persist. The 2026-09-01
  relay-host fix rotates the token once because the prior Agent TRACE path
  logged the frozen short `?k=` query key before the HTTP redactor recognized
  it.
- **Posture.** The token's job is keeping casual LAN clients out of the state
  read and the settings writes — the same posture as the Protect webhook token.
  It is a LAN-boundary credential, not a platform credential: anyone who can
  read the controller's persist or sniff LAN HTTP is already inside the trust
  boundary the token defends.
- **URL-carried, deliberately.** The token rides the `web_view_url` query string
  (`?k=`) because that is the only channel proven to reach the page on real
  Navigators. Consequences handled: the page keeps it in memory only (never
  localStorage), scrubs it from every console line, and shows only host:port in
  diagnostics; both drivers redact it from logs and Print Diagnostics
  (`k=[token]` / `k=***REDACTED***`).
- **`/ping` is tokenless** so the page can probe reachability without leaking
  anything; every other route 403s on a missing or wrong token.
- **Hashed at rest in the cloud.** When the cloud mirror is active the token
  travels driver → Agent over the controller's private LAN address, then inside
  TLS to the platform,
  which stores **only its SHA-256 hash** and compares in constant time. Every
  failed read — malformed params, unknown support id, no stored hash, wrong
  token — answers a uniform 404, so the public endpoint cannot probe which
  installs exist.
- **Revocation.** Revoking the controller's pairing kills the cloud capability
  (the read 404s; the row is kept, never deleted). Mirrors older than 24 h are
  refused — a dead controller's last state does not get presented as current
  weather. On the LAN, clearing the driver's persist re-mints the token and the
  old one dies with the next URL publish.

## Relay listener hardening

- Pure parser/router (`src/atmosphere/uirelay.lua`), fully unit-tested off the
  socket. Chunk-safe accumulation with a 64 KB per-connection cap — a flood
  cannot grow memory; oversize connections are dropped.
- Malformed request lines get a 400, never a crash; unknown routes 404; wrong
  methods 405. Settings bodies flow through the *same* versioned validator as
  the JS API, Composer, and remote settings — the relay grants no extra powers,
  it is a transport.
- Serves token-gated JSON only — no files, no directory, no HTML.

## CORS and CSP posture

- **Relay CORS is wide open (`*`), on purpose.** The page's origin is
  Navigator's opaque `controller://` scheme, so an origin allowlist is
  impossible; the token is the gate, and the relay serves only JSON on the LAN.
  Preflight `OPTIONS` is answered before the token wall — preflights are
  browser-generated and carry no secrets.
- **The cloud mirror's public read is also `*`** for the same opaque-origin
  reason, with `Cache-Control: no-store` (a cached state is a stale weather
  display) and rate limiting.
- **The page's CSP** pins `default-src 'none'`, images to `radar.weather.gov` +
  `mapservices.weather.noaa.gov` + `data:`, and `connect-src http: https:` (the
  relay's address is per-install, so it cannot be pinned tighter). Navigator's
  CSP *enforcement* is unconfirmed on hardware — which is why the text-node rule
  below is the primary defense, not the CSP.

## WebView data plane

- **JSON-only.** The page and driver exchange JSON on every channel (JS API,
  relay, cloud mirror). No HTML travels; nothing in the state document is markup
  by contract (`src/atmosphere/uistate.lua` is the one place the document is
  built).
- **All external text renders as text nodes.** Alert headlines, descriptions,
  instructions, station names, forecast text — everything NWS-originated is
  untrusted and must never touch `innerHTML`.
- **Self-contained page.** No external scripts, styles, or fonts — there is
  nothing remote to compromise. The page's external fetches are NWS/NOAA imagery
  and JSON metadata (radar frames, frame catalogs, warning polygons, tropical
  probes) plus its own relay/mirror; the webview guard test pins the allowed
  hosts.

## Settings: versioned schema, field-by-field refusal

Every settings write — WebView (JS API or relay), Composer, or SmartBuildOS
remote — flows through one validator (`settingsstore.validate`, schema
`settings_version` 1):

- Unknown keys refused loudly; enums (units, themes, screens, alert classes,
  sensitivity) checked against closed sets; booleans must be booleans;
  thresholds bounds-checked (a remote typo of `3200` for a wind threshold cannot
  brick a site).
- Refusals are itemized (`path` + `reason`), logged, returned to the WebView
  caller, and acked to the Agent — invalid config is never silently applied, and
  one bad field never discards the rest.
- Documents migrate forward via a migration table; a document from the future
  keeps only fields the current schema understands.

## Remote settings authentication

Remote settings arrive only via the Agent's existing authenticated channel: the
platform writes config through a permission-gated route, the config rides the
Agent's *outbound* heartbeat poll (the platform never dials the controller), and
the Agent forwards it locally via `SendToDevice`. See
[SMARTBUILDOS_INTEGRATION.md](SMARTBUILDOS_INTEGRATION.md) for implementation
status.

## Malformed-response handling

Every NWS decode is `pcall`'d; an undecodable body is a counted failure, never a
crash. Every field is independently null-guarded (six nulls in a healthy
observation is the measured norm). MADIS quality-control flags X/Q/B drop the
value. Unparseable timestamps, durations, periods, and alerts are dropped
individually without failing the batch. A failed alert poll retains the active
set — an attacker (or outage) that can only break connectivity cannot fabricate
an "all clear", and equally cannot fabricate weather: no data path exists from
failure to a weather event.

## What the driver deliberately cannot do

- **No writes to anything external.** Every weather HTTP call is a GET to NWS
  hosts. The one outbound write in the system is the Agent (not this driver)
  POSTing the driver's own display state to SmartBuildOS over its authenticated
  channel — display data the driver would happily print in a log, containing no
  secrets by construction.
- **No PII beyond coordinates.** The most sensitive datum handled is the
  property's lat/lon, sent (rounded to 4 decimals) to a US government API as
  every weather client must, and mirrored in the cloud state's `location` block
  for the app. It appears in logs and properties for the dealer — by design, it
  is the configuration.
- **No accounts, no credentials for third parties, no CAPTCHA-able surfaces, no
  third-party trackers.**
- License enforcement cannot dark the weather path — see
  [LICENSING.md](LICENSING.md): uncertainty fails open, and the weather path
  consults no gate at all.

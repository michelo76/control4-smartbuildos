# Atmosphere — Security & Threat Model

Atmosphere's security story is mostly about what it *doesn't* have: no secrets,
no writes, no PII, no inbound channels. What remains is untrusted external text
and a validated settings surface.

## Assets and trust boundaries

| Boundary                                          | Trust posture                                                                                                                          |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `api.weather.gov` / `radar.weather.gov` responses | Untrusted data. Government source, but treated as hostile input: pcall'd decodes, per-field guards, QC filtering                       |
| Navigator WebView page                            | Driver-hosted, but its inputs (NWS text) are untrusted; its settings writes are validated like anyone else's                           |
| SmartBuildOS Agent channel                        | Authenticated at pairing (platform side); the driver still validates every settings field — the schema is the contract, not the sender |
| Composer / programming                            | Trusted operator surface                                                                                                               |

## No secrets in the weather path

NWS is keyless — there is nothing to steal. No API keys, tokens, passwords, or
account identifiers exist anywhere in the weather pipeline, its persist keys
(deliberately stored plain — nothing there is secret), its logs, or the WebView
state document. The only secrets on the controller belong to the SmartBuildOS
Agent (its existing, unchanged model: per-controller HMAC secret in encrypted
persist); this driver never sees them. The reserved future NWS API key, when it
exists, will be the first secret this driver handles and gets its storage
decision then.

The integration test asserts the WebView document contains no `token`/`secret`
strings — a tripwire, not the whole defense.

## WebView data plane

- **JSON-only.** The page and driver exchange JSON strings over the official
  WebView JS API. No HTML travels; nothing in the state document is markup by
  contract (`src/atmosphere/uistate.lua` is the one place the document is
  built).
- **All external text renders as text nodes.** Alert headlines, descriptions,
  instructions, station names, forecast text — everything NWS-originated is
  untrusted and must never touch `innerHTML`. A strict CSP meta tag is set on
  the page as a second layer (Navigator's CSP *enforcement* is unconfirmed on
  hardware — which is why the text-node rule is the primary defense, not the
  CSP).
- **Self-contained page.** No external scripts, styles, or fonts — there is
  nothing remote to compromise. The only external fetches the page ever makes
  are radar GIFs from `radar.weather.gov` rendered via `<img>` (image decode
  surface only).
- No tokens are ever passed to the page; nothing sensitive lands in
  localStorage.

## Settings: versioned schema, field-by-field refusal

Every settings write — WebView, Composer, or SmartBuildOS remote — flows through
one validator (`settingsstore.validate`, schema `settings_version` 1):

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
the Agent forwards it locally via `SendToDevice`. There is no listener, no open
port, no inbound channel in this driver. See
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

- **No writes to anything.** Every HTTP call is a GET to two NWS hosts. The
  driver cannot modify any external system, and its only outbound non-NWS
  messages are local `SendToDevice` calls to the Agent (register/check/ack).
- **No PII.** The most sensitive datum handled is the property's lat/lon, sent
  (rounded to 4 decimals) to a US government API as every weather client must,
  in the URL path of an HTTPS request. It appears in logs and properties for the
  dealer — by design, it is the configuration.
- **No accounts, no credentials, no CAPTCHA-able surfaces, no third-party
  trackers.**
- License enforcement cannot dark the weather path — see
  [LICENSING.md](LICENSING.md): uncertainty fails open, and the weather path
  consults no gate at all.

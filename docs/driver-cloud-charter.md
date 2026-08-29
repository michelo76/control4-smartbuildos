# SmartBuildOS Driver Cloud — charter & Phase 1 audit

2026-08-28. The distillation of the Agent/licensing/fleet mega-prompt into
what exists, what's decided, and the build order. This is the program
document; the licensing SDK ships alongside it.

---

## Phase 1 audit — the finding that reshapes everything

**The SmartBuildOS Connector already IS the Agent's foundation.** Built,
field-deployed, and live in prod:

| Mega-prompt requirement | Existing implementation |
| --- | --- |
| Secure pairing (account + short-lived code, never a password) | Connector Pairing Code letterbox → `POST /api/integrations/control4/pair` → long-lived per-controller token, encrypted persist. Single-use, short-TTL codes minted per property/company. |
| Controller entity + immutable ID | `control4_controllers` table in prod, keyed rows per controller, company-scoped |
| Heartbeat | `/heartbeat` route + interval property, live for months |
| Telemetry/events gateway | `/devices`, `/event`, `/telemetry` routes + the connector's bounded queue |
| Company/client/property linkage | `customer_studio_control4_relationships` migration (08-23); system→property linking with the "system need not have a property" rule already learned |
| Tenant isolation | RLS on ~260 tables; the three guard tests (api-route-gating §42, admin-tenant-scope, orphan-routes) enforce every new route |
| Update channel | github-updater in every driver + release channel property |

**Decision D1: the Connector evolves into the SmartBuildOS Agent.** Same
driver file (`smartbuildos.c4z`), same pairing, same identity — licensing
becomes a new capability of the existing trusted resident, not a second
resident. A rename to "SmartBuildOS Agent" is cosmetic and can come later;
a second driver would double-pair every project for nothing.

## Constraint findings (researched, not assumed)

**C4:Sign exists (HMAC + RSA); there is NO C4:Verify.** A driver can SIGN
but cannot natively verify an RSA signature. Ramifications:

**Decision D2 — entitlement integrity design** (the documented-limitation
alternative the prompt asks for):
- Entitlements are issued **server-side over TLS** (the controller already
  trusts `app.smartbuildos.io`'s real certificate — verification ON for
  platform calls, unlike the Protect console path).
- At enrollment the backend issues a **per-controller HMAC secret**
  alongside the bearer token (encrypted persist, never in the project
  file). Entitlement payloads are HMAC-SHA256 signed with that secret
  (`C4:Sign("HMAC", ...)` verifies by re-signing and comparing).
- Binding: every assertion carries `company_id + controller_id +
  driver_sku + features + expiry`, MAC'd with the per-controller secret →
  **copying a cached entitlement to another controller fails** (different
  secret), **editing sku/controller in the cache fails** (MAC mismatch).
- What this does NOT give vs. true asymmetric: a fully compromised
  controller can mint entitlements *for itself* — which is equivalent to
  patching the check out of the driver, a bar no client-side scheme
  clears. Cross-controller and cross-company forgery — the attacks that
  matter commercially — are closed. Server-side revalidation (24h cadence)
  remains the authority.
- **Upgrade path**: investigate raw-RSA-public-key operation via
  `C4:Encrypt`/`LoadPKCS12` for true asymmetric verify later; the payload
  format carries a `sig_alg` field so the swap is a rollout, not a redesign.

**Inter-driver API**: the Agent↔driver protocol rides the dual-path
transport (bindingless SendToDevice→EC + exact-filename discovery) proven
across five drivers and four field rounds. No bindings needed for
licensing — a licensing check must work before any dealer wiring.

## The protocol (v1, shipped with this charter)

Dependent driver → Agent (`SendToDevice` to `smartbuildos.c4z`):
- `SBOS_REGISTER_DRIVER {sku, version, requester}` — on init and daily.
  Agent inventories it and replies:
- Agent → driver: `SBOS_ENTITLEMENT {sku, status, license_type, features,
  company, grace_until, checked_at}`
- `SBOS_CHECK_ENTITLEMENT {sku, requester}` — re-ask any time.
- `SBOS_PROTECT_ROSTER {source, payload}` — (existing) device roster for
  the equipment registry; the Agent queues it platform-ward.

Status vocabulary (fixed, from the charter prompt):
`AUTHORIZED_SUBSCRIPTION · AUTHORIZED_PERPETUAL · AUTHORIZED_GRACE ·
TRIAL · NOT_ENTITLED · AGENT_UNAUTHENTICATED · ACCOUNT_SUSPENDED ·
ENTITLEMENT_EXPIRED · CONTROLLER_MISMATCH · CLOUD_VALIDATION_REQUIRED ·
LEGACY` (the migration state: Agent predates entitlement backend, driver
runs normally, properties say so).

**Backward compatibility (D3)**: until the backend issues real
entitlements, the Agent answers `LEGACY` and dependent drivers treat it
as authorized-with-a-note. No deployed system changes behavior. When the
backend ships, the Agent starts answering real statuses; enforcement
policies (per-driver `FULL_DISABLE`/`READ_ONLY`/`LOCAL_FEATURES_ONLY`)
activate driver-by-driver in later releases — never retroactively
bricking a build that shipped without them.

## SKUs (immutable from today)

`SBOS_AGENT · SBOS_UNIFI_PROTECT · SBOS_UNIFI_PROTECT_CAMERA (feature of
parent, not separate) · SBOS_INSIGHTS` — child drivers do not license
separately: **the Gateway holds the entitlement; children inherit through
it** (they already cannot function without it). One purchase = one
console's whole suite. Future: `SBOS_UNIFI_NETWORK, SBOS_TESLA, …`

## Phase plan (calibrated to the two repos)

| Phase | Where | What | State |
| --- | --- | --- | --- |
| 1 Audit | both | this document | ✅ |
| 2 Driver-side SDK | driver repo | `src/sbos/license.lua`, Agent stub handlers, Protect wiring, LEGACY flow | ✅ shipped with this charter |
| 3 Domain model | web repo | `driver_catalog, driver_entitlements(+features), driver_installations, driver_events, driver_purchases, driver_license_transfers, driver_audit_log, driver_risk_flags` — extending, never duplicating, `control4_controllers`. Per-controller HMAC secret column (encrypted). Guard-test fixtures updated (the tenant-tables trap). | next |
| 4 Backend APIs | web repo | `/api/driver-cloud/{entitlements/refresh, events, health}` on the existing DEVICE_SESSION auth bucket; enrollment stays the existing `/pair` (extended to mint the HMAC secret) | next |
| 5 Agent licensing | driver repo | Agent fetches + HMAC-verifies (C4:HMAC re-sign over the canonical string) + caches assertions in encrypted persist; staleness ladder 24h revalidate / 7d cache / dated grace to day 10 → CLOUD_VALIDATION_REQUIRED; unknown skus stay LEGACY; pair mints + Pairing Backup mirrors the per-controller secret; pre-Phase-5 pairings serve unsigned until a re-pair | ✅ 2026-08-29 |
| 6 Driver Cloud UI | web repo | Studio in the Ops console: Overview (+ Support ID search), Fleet, Licenses (issue/revoke/transfer), Catalog, Events | ✅ 2026-08-29 (PR #193) |
| 7 Purchases | web repo | driver_purchases lifecycle on the platform Stripe stack; dealer Driver Store; webhook auto-issues PERPETUAL; refunds + transfers | ✅ 2026-08-29 (PR #196) |
| 8 Hardening | both | clock-anomaly handling (Agent); adversarial + cross-language parity test suites both repos (cross-sku/cross-controller/tamper) | ✅ 2026-08-29 |

## Ground rules adopted verbatim from the charter prompt

Granular entitlements (company+controller+sku+features, never
`licensed=true`) · account number is an identifier, never a credential ·
no secrets in drivers, ever (the letterbox/encrypted-persist pattern is
already the house style) · offline-first (7-day signed cache, exponential
backoff — the connector's retry discipline already models this) · grace
is visible, dated, and never silently destructive · no universal kill
switch; revocation is targeted + audited · perpetual licenses survive
subscription cancellation · clock anomalies flag, never auto-brick ·
every licensing mutation lands in an immutable audit trail · RBAC'd
issuance (`driver_license.issue` etc.) · fail-secure but distinguish
outage from revocation — a SmartBuildOS outage must never dark a home.

## Success snapshot to build toward

Dealer installs Agent → Account `PAV-004218` + pairing code → paired
(already works today). Installs UniFi Protect Gateway → it registers
`SBOS_UNIFI_PROTECT 20260828.x` → Agent answers
`AUTHORIZED_SUBSCRIPTION (Professional)` from a signed cached assertion →
Gateway property reads `License: Authorized — Subscription Included`.
Cancel the subscription → 10-day grace, dated, visible in Composer and
Driver Cloud. Buy the driver outright mid-grace → `PERPETUAL`, forever.
Copy the cache to another controller → `CONTROLLER_MISMATCH`. And through
it all, Driver Cloud shows company → property → controller → drivers →
health, searchable by Support ID.

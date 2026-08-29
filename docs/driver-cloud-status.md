# Driver Cloud — implementation status

The permanent record of what shipped, where, and why. Kept current as the
platform grows; the design rationale lives in `driver-cloud-charter.md`, the
security analysis in `driver-cloud-threat-model.md`.

_Last updated: 2026-08-29._

## Two repositories

- **control4-smartbuildos** — the drivers (the SmartBuildOS Agent =
  `smartbuildos.c4z`, the UniFi Protect suite, the licensing SDK
  `src/sbos/license.lua`, the signing/verify logic). Ships as `.c4z` via GitHub
  Releases.
- **smartbuildos** (web) — the platform: `/api/driver-cloud/*` (controller-
  facing) and `/api/platform/driver-cloud/*` (operator Studio), the domain
  tables, the Stripe purchase path. Ships via Vercel on merge to `main`.

## Phase ledger

| Phase | Focus | Shipped as | State |
| --- | --- | --- | --- |
| 1 | Audit + charter (the "Connector IS the Agent" finding, D1/D2/D3) | `driver-cloud-charter.md` | ✅ |
| 2 | Driver-side licensing SDK + LEGACY-first protocol | driver repo | ✅ |
| 3 | Domain model — 8 revoke-first tables, one-active partial index | web PR #190 | ✅ merged, migration applied to prod, ledger repaired |
| 4 | Backend APIs — `/api/driver-cloud/{entitlements/refresh,events,catalog}`, `/pair` mints the per-controller secret | web PR #190 | ✅ |
| 5 | Agent licensing — fetch + HMAC-verify + encrypted cache; 24h revalidate / 7d cache / 10d grace ladder | driver release `v20260828.233355` | ✅ |
| 6 | Driver Cloud Studio — Overview (+ Support ID search), Fleet (effective entitlements), Licenses (issue/revoke/transfer), Catalog, Events | web PR #193 | ✅ |
| 7 | Purchases — dealer Driver Store, one-time Stripe Checkout, webhook auto-issues PERPETUAL, refunds, transfers | web PR #196 | ✅ |
| 8 | Hardening — clock-anomaly handling; adversarial + cross-language parity suites (cross-sku/cross-controller/tamper) | driver repo + web PR #197 | ✅ |
| — | Enforcement (READ-ONLY when unlicensed) — SDK gate + gateway choke point; **defaults to observe, dormant until the platform enables it per SKU** | driver repo | ✅ built, off by default |
| 12 | **Agent conversion + account display** — `smartbuildos.c4z` is a true DriverWorks Agent (`<agent>true</agent>`); the platform carries subscription tier + company name on pair/refresh; the Agent and every dependent driver show tier, company, per-driver license source (subscription vs perpetual), the project's licensed-driver count, and a loud REGISTRATION REQUIRED when the Agent is present but paired to no registered company | driver repo + web PR #208 | ✅ |

## Architecture decisions (from the charter)

- **D1 — the Connector evolved into the Agent.** One resident Control4-side
  component (`smartbuildos.c4z`), not two. Same pairing, same identity;
  licensing is a capability, not a second driver.
- **D2 — HMAC-per-controller, not RSA.** DriverWorks has no verify primitive,
  so assertions are signed with a per-controller secret derived from a
  server-only master key. Cross-controller/cross-company forgery is closed;
  single-controller self-piracy is the documented residual (see the threat
  model). `sig_alg` reserves the asymmetric upgrade.
- **D3 — LEGACY-first.** Absent/old backends answer `LEGACY`; every driver
  operates normally. Enforcement activates per-SKU, server-controlled, never
  retroactively bricking a shipped build.

- **D4 — the Agent is a true DriverWorks Agent.** `smartbuildos.c4z` declares
  `<agent>true</agent>` (OS 3.1.3+): one singleton per project, loaded from
  Composer's **Agents** panel, not added to a room. This matches what it is —
  the project-wide licensing authority for every SmartBuildOS driver — and a
  singleton is enforced by the platform, not just by convention.
  **Migration:** an install that added the pre-12 build to a *room* must delete
  that instance and re-add it from **Agents → Add → SmartBuildOS**; pairing
  identity survives in the Pairing Backup property, so it re-pairs itself. A
  converted Agent will not load as a room driver, by design.

## Guarantees the tests hold to

- **Never dark a home.** Live video, detections and status reads never consult
  the enforcement gate. Enforcement (when enabled) makes an unlicensed gateway
  READ-ONLY — control, auto-provisioning and platform reporting refuse — but the
  awareness layer keeps running.
- **Outage ≠ revocation.** Uncertainty (`CLOUD_VALIDATION_REQUIRED`,
  `AGENT_UNAUTHENTICATED`) fails open. Only *definitive* denial
  (`NOT_ENTITLED`, `ENTITLEMENT_EXPIRED`, `ACCOUNT_SUSPENDED`,
  `CONTROLLER_MISMATCH`) can enforce, and only when the server turned it on.
- **Staleness never grants.** A refusal never improves with age; a backwards
  clock clamps instead of buying eternal freshness; the grace date is real.
- **Every mutation is audited.** `driver_entitlement_events` (immutable) +
  `platform_audit_log`; no universal kill switch; perpetual survives
  cancellation.

## Test coverage

- Driver (`make test`, 16 suites): entitlement engine incl. the ladder failure
  matrix and adversarial forgeries (`test_sbos_entitlements.lua`, 62 checks);
  licensing SDK incl. the enforcement truth table (`test_sbos_license.lua`, 37);
  gateway enforcement end-to-end (`test_unifi_protect.lua` [23b]).
- Platform (6,940 unit tests): `driver-cloud-security.test.mjs` pins the
  canonical signing string byte-for-byte against the driver suite's fixture —
  reorder either side and both fail.

## Open / deferred

- Platform activation UI for enforcement (per-SKU `enforcement_mode` toggle) —
  deferred; the driver defaults to observe so nothing enforces until it lands.
- Asymmetric-verify upgrade (D2) and master-key rotation (`key_version`).
- The operational roadmap (Fleet Intelligence → Service Automation → Release
  Management → Dealer Experience → Protect deep integration → Developer Platform
  → Security/Scale audit) — the next arc, tracked separately.

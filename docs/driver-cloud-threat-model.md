# Driver Cloud — entitlement integrity threat model

Answering the question directly: **if an attacker extracts the per-controller
HMAC secret from a driver installation, what is the blast radius?**

## The scheme in one paragraph

DriverWorks exposes `C4:Sign`/`C4:HMAC` but **no signature-verify primitive**,
so a driver cannot check an RSA signature it did not itself produce. Entitlement
assertions are therefore signed with a symmetric per-controller secret:

    controller_secret = HMAC-SHA256(MASTER_KEY, "agent-secret:" || controller_id)

The master key lives only on the platform (Vercel env `DRIVER_CLOUD_HMAC_KEY`).
Each controller receives **only its own** secret, at pairing, over TLS (the
controller trusts `app.smartbuildos.io`'s real certificate), stored in encrypted
persist. Assertions bind `company_id + controller_id + driver_sku + status +
features + issued_at + valid_until + grace_until` under that secret; the Agent
verifies by re-signing the canonical string and comparing.

## Blast radius of an extracted controller secret

**Strictly one controller. Confirmed by the tests in both repos.**

1. **Cannot forge for another controller.** Controller B's secret is
   `HMAC(MASTER_KEY, "agent-secret:" || B_id)`. Deriving it from A's secret
   requires the master key, which HMAC does not reveal (it is one-way and the
   master never leaves the server). `tests/unit/driver-cloud-security.test.mjs`
   → "cross-controller theft fails" asserts B rejects A's assertion; the driver
   suite's [15] asserts a whole cache lifted onto another controller fails.

2. **Cannot recover the master key.** HMAC-SHA256 is not invertible; one output
   does not expose the key. Every *other* controller in the fleet is unaffected
   by a single extraction.

3. **CAN self-grant, for that one controller only.** With its own secret, a
   fully compromised controller can mint any assertion *for itself* — any SKU,
   `AUTHORIZED_PERPETUAL`, any features. This is **equivalent to patching the
   licence check out of the driver binary**, which no client-side scheme
   prevents (charter D2 states this explicitly). The bar a symmetric scheme
   cannot clear is exactly the bar a jailbroken client cannot clear.

## Why the residual risk is acceptable — and bounded

- **The server is the authority, on a 24h cadence.** A self-minted assertion
  only survives until the next successful cloud revalidation, where the platform
  sends the *real* status. To ride a forgery indefinitely the controller must
  stay offline — and an offline controller reaches `CLOUD_VALIDATION_REQUIRED`
  after cache (7d) + grace (10d) regardless of what it self-signed, because
  staleness is measured from `fetched_at`, not from the assertion (driver suite
  [16]/[17]: a backwards clock cannot buy eternal freshness; a refusal never
  improves with age).
- **It is detectable server-side.** The platform knows what it issued. A
  controller reporting installations/entitlements that do not match issuance is
  an abuse signal — the natural home for the Phase 15 abuse-detection work
  (`driver_events` + `driver_risk_flags` already exist for it).
- **Revocation is fast and targeted.** One `driver_entitlements` row to
  `revoked`; the controller learns at its next refresh. No fleet-wide action,
  no collateral.
- **The commercial attacks that matter are closed.** Cross-controller and
  cross-company forgery — reselling one licence across a fleet — are
  cryptographically impossible here. Only self-piracy of a single site remains,
  which is low-value and detectable.

## Upgrade path (removes even self-grant)

The assertion carries a `sig_alg` field precisely so a true asymmetric scheme
can roll out as config, not a redesign. Investigate raw-RSA public-key
verification via `C4:Encrypt`/`LoadPKCS12` (the driver holds only a public key;
it cannot mint anything). Until then the symmetric scheme is the correct,
documented tradeoff for a runtime with no verify primitive.

## Master-key rotation (known limitation)

Rotating `DRIVER_CLOUD_HMAC_KEY` re-derives every controller's secret, so paired
Agents hold a stale verifier until re-paired. A `key_version` + dual-key
acceptance window removes the re-pair; until it ships, treat the master key as
long-lived and rotate only on suspected compromise (documented at
`deriveAgentSecret`).

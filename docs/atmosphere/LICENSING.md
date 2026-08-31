# Atmosphere — Licensing

SKU: **`SBOS_ATMOSPHERE`**. Atmosphere invents nothing here: it uses the one
licensing SDK every SmartBuildOS driver uses (`src/sbos/license.lua`) talking to
the SmartBuildOS Agent (`smartbuildos.c4z`), which is the local licensing
authority. The integration is five lines:
`license.setup({ sku = "SBOS_ATMOSPHERE" })` at LateInit, the `SBOS_ENTITLEMENT`
handler, the `Refresh License` / `Test SmartBuildOS Licensing` actions, and the
four display properties.

## The design rule that outranks everything

**Weather safety logic is never license-gated.** The driver does not consult the
enforcement gate anywhere in the weather path — observations, forecasts, alerts,
events, variables, and connections run identically in every license state,
including `NOT_ENTITLED`. If server-side enforcement is ever enabled for this
SKU, the gated surface is premium display features (per the architecture:
WebView premium screens and the predictive engine) — never current conditions,
never alert events. A Tornado Warning fires whether or not anyone paid.

## Status vocabulary

The Agent answers with one of a fixed set (charter vocabulary):

| Status                      | Meaning                                                        | Operational?                       |
| --------------------------- | -------------------------------------------------------------- | ---------------------------------- |
| `AUTHORIZED_SUBSCRIPTION`   | Covered by the company's subscription tier                     | yes                                |
| `AUTHORIZED_PERPETUAL`      | Purchased outright                                             | yes                                |
| `AUTHORIZED_GRACE`          | Authorized, riding the dated offline grace window              | yes                                |
| `TRIAL`                     | Trial license                                                  | yes                                |
| `LEGACY`                    | No Agent, or an Agent that predates licensing — never answered | yes                                |
| `CLOUD_VALIDATION_REQUIRED` | Cache too old; the Agent must re-reach the cloud               | uncertain — never enforced against |
| `AGENT_UNAUTHENTICATED`     | Agent present but not authenticated to the platform            | uncertain — never enforced against |
| `NOT_ENTITLED`              | Definitive: no license for this SKU                            | definitive deny                    |
| `ENTITLEMENT_EXPIRED`       | Definitive: license lapsed                                     | definitive deny                    |
| `ACCOUNT_SUSPENDED`         | Definitive: account-level suspension                           | definitive deny                    |
| `CONTROLLER_MISMATCH`       | Definitive: licensed to another controller                     | definitive deny                    |

The **License Status** property reads relationship-first:
`No SmartBuildOS Agent Found` → `SmartBuildOS Agent Found - Not Linked` →
`SmartBuildOS Agent Found - Checking...` → then the license-state label (e.g.
`Licensed / Subscribed`). **License Source**, **Subscription Tier**, and
**SmartBuildOS Company** complete the display set.

## The offline ladder

The ladder lives in the Agent, not this driver. The Agent fetches HMAC-signed
entitlement assertions from Driver Cloud, verifies them with the per-controller
secret minted at pairing, caches them encrypted, and answers dependent drivers
from that cache:

1. **Revalidate at 24 h** (`revalidate_after_hours`, server-tunable): past this
   the Agent refreshes in the background while the cache keeps serving
   as-issued.
1. **As-issued through 7 days** (`offline_cache_days`, server-tunable): cached
   authorized statuses answer unchanged.
1. **Dated grace through 10 days** (`GRACE_DAYS`): authorized statuses become
   `AUTHORIZED_GRACE` with a visible `grace_until` date.
1. **Past grace: `CLOUD_VALIDATION_REQUIRED`** — the one state that demands the
   cloud be reachable again.

Refusals never improve with age (a cached `NOT_ENTITLED` stays a refusal), and
clock anomalies clamp toward the stricter reading, which grace absorbs.

## Fail-open uncertainty

Enforcement can act **only** when three independent conditions all hold: the
server has set this SKU's mode to `enforce` (default is `observe`, and a backend
that predates the field never enforces), the status is one of the four
definitive denials, *and* the driver actually consults the gate. Uncertainty —
cloud unreachable, Agent unauthenticated, cache expired — is **never** enforced
against: a SmartBuildOS outage must never dark a home. And per the rule above,
Atmosphere's weather path consults the gate nowhere, so today the practical
effect of every status is display only.

## LEGACY: running without an Agent

No Agent in the project (or an Agent that never answers) leaves the driver in
`LEGACY`: fully operational, every feature flag granted (enforcement cannot
precede issuance), with the property reading `No SmartBuildOS Agent Found` and a
log warning suggesting the Agent be installed. Existing installations predating
the Agent requirement must never go dark.

## Supported license models

The entitlement's `license_type` distinguishes how this driver is covered
(display labels in parentheses):

- `SUBSCRIPTION_INCLUDED` (*Included with subscription*) — covered by the
  company's SmartBuildOS tier.
- `PERPETUAL` (*Purchased outright*).
- `TRIAL` (*Trial*).
- `GRACE` (*Grace period*).
- `NFR` (*Not for resale*) — dealer demo systems.
- `DEVELOPER` (*Developer license*).

## Platform-side status (honesty note)

The driver-side client is complete and tested (`test_sbos_license.lua` covers
the SDK; `test_atmosphere_driver.lua` covers the no-Agent LEGACY path). The
platform-side pieces for this SKU are **pending**: the `driver_catalog` seed
migration for `SBOS_ATMOSPHERE` has not been applied, and
`publish-to-store.yml`'s `sku_for()` has no `smartbuildos-atmosphere.c4z` case
yet — until both land, a paired Agent answers as it would for any unknown SKU
and the store cannot distribute the package.

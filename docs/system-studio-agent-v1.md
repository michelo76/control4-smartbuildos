# System Studio Agent Contract v1

## Scope

This implementation extends the existing `SmartBuildOS Agent` package. It does
not create a second controller writer, replace pairing or licensing, or change
any existing Composer identifier. The Agent remains the single authority that
existing SmartBuildOS drivers register with for entitlements and Driver Cloud
capabilities.

## Preserved compatibility

- Existing variable IDs 2000-2005 and event IDs 1-11 are unchanged.
- Existing action and programming-command tokens are unchanged.
- Existing `SBOS_ATMOSPHERE`, `SBOS_MODE_COMPOSER`, and
  `SBOS_UNIFI_PROTECT` configuration forwarding is unchanged.
- Generic `SBOS_REGISTER_DRIVER` / `SBOS_CHECK_ENTITLEMENT` behavior continues
  to accept any SKU; the Agent does not need storefront catalog metadata.
- Package update filenames remain an explicit allowlist. A future Driver Store
  release cannot make the controller install an unknown package implicitly.

## New controller behavior

- Strict, whole-document validation and monotonic self-application of the
  heartbeat's `SBOS_AGENT` configuration.
- Separate persistent configuration, runtime counters, boot baseline, service
  mode, and bounded pending-observation queue.
- `OnDriverLateInit(reason)` handling for `DIT_ADDING`, `DIT_STARTUP`, and
  `DIT_UPDATING`, plus optional `C4:GetBootID()` evidence.
- Authenticated posting to `startup-observation` after the configured
  stabilization deadline, with retry after a later successful heartbeat.
- Contract v1 Composer actions, events, read-only variables, and non-editable
  status properties, including dynamic registration for updated instances.
- Additive `agent_contract` heartbeat evidence. An older platform can ignore
  it; absence on an older Agent never becomes a false status claim.

## Deliberate open boundaries

- The driver cannot verify the primary controller from its current heartbeat;
  it leaves that identity unavailable and never promotes boot-change evidence
  to a verified primary-controller reboot.
- The current platform has no controller-authenticated report-generation or
  report-delivery endpoint. Composer report actions record a request and remain
  `request-recorded`; they do not claim ready, sent, or delivered.
- Local Lua/XML/package checks are not Composer programming retention or
  physical Controller proof. Those require a regression project and supported
  hardware before release.
- No package is published, promoted, installed, or delivered by this branch.

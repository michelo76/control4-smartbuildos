# SmartBuildOS System Link temperature companion

Presents one **temperature** export of the linked project as a native Control4
device. Requires **SmartBuildOS System Link** on this project (it inherits the
pair licence) and an export of kind `temperature` created on the linked project
with the bridge's **Export Device** command.

## Setup

1. Add this driver to the project (or run **Add Companion For Selected Item** on
   the bridge with the export's field selected — one instance per export).
1. In **Linked Export** pick the export. The list comes from the bridge.
1. Bind it like any other device.

## Behaviour

- **Confirmed State** shows only what the owner's device reported. A control
  request is shown in **Requested State** until the owner confirms it; the proxy
  never shows a value it has not been told.
- **Freshness** is `current`, `stale`, `unknown` or `unavailable`; the **Remote
  Value Current / Stale** events and the **Remote Value Is Current** conditional
  follow it.
- **Control** says whether the owner permits control right now (export setting,
  schedule, suspension and licence all apply on the owner side). A refused
  request fires **Control Refused** with the owner's reason in **Last Result**.

## Hardware validation

None yet. The proxy vocabulary used is cited in the SmartBuildOS capability
matrix; it has not been exercised on a physical controller.

<!-- #embed-changelog -->

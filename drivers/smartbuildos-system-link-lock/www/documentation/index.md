# SmartBuildOS System Link lock companion

Presents one **lock** export of the linked project, STATUS ONLY in this release: the `Locked` variable, **Remote Locked / Unlocked** events and a **Remote Lock Is Locked** conditional. The two Test actions send lock / unlock requests, which the owner refuses unless the pair licence carries the LOCK feature and, for unlock, the owner's dealer has run **Allow Unlock For Selected Export** on that export. Unlock is never retried.

Requires **SmartBuildOS System Link** on this project (it inherits the pair
licence) and an export of kind `lock` made on the linked project from the
bridge's Device Exports block. Add it with **Add Companion For Pending Export**
on the bridge (one instance per export), or add this driver and pick the export
in **Linked Export**.

## Behaviour

- **Confirmed State** shows only what the owner's device reported; a request is
  shown in **Requested State** until the owner confirms it.
- **Freshness** is `current`, `stale`, `unknown` or `unavailable`; the **Remote
  Value Current / Stale** events and the **Remote Value Is Current** conditional
  follow it.
- **Control** says whether the owner permits control right now; **Control
  Window** shows the owner's schedule. A refused request fires **Control
  Refused** with the owner's reason in **Last Result**.

## Hardware validation

None yet. The source variable names are the ones Mode Composer's adapters read
in the field; the gate for control opens only with a hardware test record
(`docs/system-link/HARDWARE-VALIDATION.md` in the SmartBuildOS repository).

# SmartBuildOS System Link fan companion

Presents one **fan** export of the linked project: the `Speed` (0–10) and `On` variables, **Remote Fan On / Off** events and a **Remote Fan Is On** conditional. The Test actions send on / off / speed 5; the owner refuses them unless the pair licence carries the FAN feature.

Requires **SmartBuildOS System Link** on this project (it inherits the pair
licence) and an export of kind `fan` made on the linked project from the
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

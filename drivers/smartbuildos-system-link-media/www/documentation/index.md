# SmartBuildOS System Link media room companion

Presents one **media** export of the linked project — a room's playing state —
on this controller, as variables, events and a conditional. It is read-only: a
remote room cannot be driven in this release, only observed. Requires
**SmartBuildOS System Link** on this project (it inherits the pair licence) and
an export of kind `media` made on the linked project from the bridge's Device
Exports block, with the room itself picked as the device.

## Setup

1. Pick the export in **Pending Export** on the bridge and run **Add Companion
   For Pending Export** (one instance per export), or add this driver and pick
   the export in **Linked Export**.

## What it shows

- Variables `Powered` (BOOL), `Source` (STRING, the selected device's name),
  `Volume` (NUMBER) and `Media` (STRING, the room's media info as reported).
- Events **Remote Room On / Off** and **Remote Media Changed**, fired only on a
  live change after the values are current; conditional **Remote Room Is On**.
- **Confirmed State** reads `On · Kitchen TV · volume 32 · …` or `Off`; a room
  that does not expose a field reports it `unavailable` rather than inventing
  it.

The source variables read on the owner's room are the ones Mode Composer reads
in the field (`POWER_STATE`, `CURRENT_SELECTED_DEVICE`, `CURRENT_VOLUME`) and
the media-info variables the SmartBuildOS Agent observes; which of them a room
answers depends on the OS version.

## Hardware validation

None yet. Whether a ROOM answers `GetDeviceVariables` on a given OS is exactly
what the bench must confirm; the Agent reports the same question.

# SmartBuildOS System Link Lock

This driver tells this project whether a door lock in another Control4 project
is locked. The project that has the lock (the owner) shares it across the link
as an export. This driver sits on the receiving side and turns that export into
one variable, two events and a conditional, so programming here can react when
the far door is locked or unlocked.

It is status only in this release. It is a programming device, not a lock on the
Navigators: it has no proxy, no users, no codes and no history, and it gives
programming no way to lock or unlock.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `lock` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link. Lock status works on every pair licence. Lock
  control needs the `LOCK` feature on the pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked lock -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `lock`, pick the lock in **Export Device**, fill in **Export Name**, leave
   **Export Control** on `View only`, and run *Export Selected Device*.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Front_Lock (lock)`. Pick it in **Pending Export**
   and run *Add Companion For Pending Export*. This driver is added, linked to
   the export and named after it. *Auto Setup* does the same for every pending
   export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds lock exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** reads `Locked` or `Unlocked`.
1. Lock and unlock the door on the owner's side and watch **Confirmed State**
   follow.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | Locked or unlocked |
| Here to the owner | Only the two Test actions: lock, unlock |
| Not carried | Who locked or unlocked it, codes and users, battery, jammed or other fault states, history |

The owner reads the lock's status variable (`LOCK_STATUS`, `LOCK STATUS`,
`LOCKED`, `LOCK_STATE` or `LOCKSTATE`, whichever the device has). It understands
locked (`locked`, `1`, `true`) and unlocked (`unlocked`, `0`, `false`). Any
other value the lock reports is published as `unavailable` until the next locked
or unlocked.

The Test actions each send one request, and the owner decides. Both are refused
unless the export was made with `Control allowed`, which the owner can only
choose when the pair licence carries `LOCK`; the licence is checked again at
every request. Unlock needs one thing more: the owner's dealer must have
selected the export in **Selected Export** on SmartBuildOS System Link there and
run *Allow Unlock For Selected Export*. That action is itself refused while
`LOCK` is not licensed, and *Disallow Unlock For Selected Export* takes it back.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no lock export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: the state is confirmed. `stale`: the link is not synchronised, or the owner has not confirmed the value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's lock supplies nothing that reads as locked or unlocked |
| **Control** | `control permitted` when the export allows control and SmartBuildOS System Link here permits commands; otherwise `view only / suspended` |
| **Control Window** | The owner's schedule for this export and whether it is open now. `none` when there is no schedule |
| **Confirmed State** | `Locked`, `Unlocked` or `unavailable` |
| **Requested State** | The last Test request and when |
| **Last Result** | `sent`, `accepted`, then `delivered` or `failed:` with the owner's reason: `export is view-only`, `feature LOCK is not licensed`, or `unlock requires Allow Unlock on this export, set on purpose by the owner` |

## Programming

- Variable: `Locked` (Boolean, read-only).
- Events: *Remote Locked*, *Remote Unlocked*, *Remote Value Current* and
  *Remote Value Stale* (**Freshness** became `current` or stopped being
  `current`), *Control Refused* (a Test request was refused; **Last Result** has
  the reason).
- Conditionals: *Remote Lock Is Locked*, *Remote Value Is Current*.
- Actions: *Test: Remote Lock*, *Test: Remote Unlock*, *Refresh From Bridge*
  (ask for the export list and state again), *Rename From Export* (name the
  device after the export even if you renamed it), *Print Diagnostics To Log*.
- Commands: none.

## Examples

### Know when the far door is unlocked

On *Remote Unlocked*, send a notification, or turn on a light here. The event
fires only when the owner's lock reports a change while the value is current.

### Goodnight check across two houses

In the Goodnight routine here, test *Remote Value Is Current* first. If it is
current and *Remote Lock Is Locked* is false, announce that the far door is
unlocked. If it is not current, say that the far door's state is not known. Do
not use the `Locked` variable alone for this: it reads 0 when there is no value.

## Limits

- Programming cannot lock or unlock. The Test actions on the Actions tab are the
  only way this driver sends anything, and unlock is refused until the owner
  allows it as described above.
- `Locked` reads 0, the same as unlocked, when the owner's lock supplies no
  value. It keeps its last value while **Freshness** is `stale`. Always pair it
  with *Remote Value Is Current*.
- *Remote Lock Is Locked* answers from the last confirmed state seen since this
  driver started, and keeps that answer while the value is not current. After a
  restart it is false until the first `current` state arrives, and that first
  state fires no event.
- A request is sent once and never repeated; an unlock is never retried.
  `delivered` means the owner passed the command to the lock, not that the bolt
  moved: wait for *Remote Locked* or *Remote Unlocked*.
- Hardware validation: none yet. The variable names the owner reads are the ones
  Mode Composer's adapters read in the field. Control stays behind the `LOCK`
  licence feature until there is a hardware test record
  (`docs/system-link/HARDWARE-VALIDATION.md` in the SmartBuildOS repository).

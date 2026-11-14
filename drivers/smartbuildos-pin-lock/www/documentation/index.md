# SmartBuildOS PIN Lock

PIN Lock puts a code in front of an action. You name up to twelve **guarded
actions**, for example "Unlock wine cellar", "Open garage service door" or
"Disable alarm zone". Each one is a gate: when somebody with a valid code asks
for it, from the touchscreen page or by tapping a sequence on a keypad, the
driver fires a Composer event for that gate, and can also send an unlock,
open or toggle command to one lock or relay itself. You attach your own
programming to the events.

Codes are managed on a page in the Navigator (or by programming commands).
Each code has a name, a role, the guarded actions it may fire, weekly hours,
an optional start and expiry date, and an optional limit on how many times it
can be used. Codes are stored as salted digests. A PIN is never logged, never
shown again, and never sent anywhere.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system. The Agent is the licensing authority (SKU `SBOS_PIN_LOCK`): **License
Status** shows this driver's standing.

## What this driver cannot do

Read this before you sell it.

**PIN Lock guards only the actions that pass through it.** A Control4 driver
cannot hide a room, a device or a lock in the native Navigator, and cannot put
a PIN screen in front of the native lock tile. If the wine cellar lock is also
a tile in the Navigator, anyone with the Navigator can still use that tile.

To make the gate real, the dealer must **remove the lock from the Navigator**
(take it out of the room's Navigator list or its experience), so that the only
way to operate it is the PIN Lock page, a keypad sequence, or a script that
the PIN Lock events run. Check this on a phone and on a touchscreen before you
hand over.

Also keep in mind:

- A person who can open Composer, or who has the project administrator login,
  can still operate the lock directly.
- The Web View page is served over the local network without encryption (see
  Limits). Treat it as a convenience gate for a household, not a security
  boundary against someone on the home network who is determined.
- A 4 to 8 digit PIN is a small space. The protection against guessing is the
  lockout, not the digest.

## What it is for

| You want | Use |
| --- | --- |
| A wine cellar, garage service door or alarm zone that needs a code | A guarded action, with the lock chosen as its **target** |
| A cleaner who can only come on Tuesdays 9 to 12 | A *staff* or *vendor* code with weekly hours |
| A guest code that stops working on Sunday night | A code with an expiry date, or the command `ADD_TEMPORARY_CODE` |
| A code that works exactly once for a delivery | **Max uses** of 1 |
| A keypad that does something when 1-3-3-2 is tapped | A code with a keypad sequence, and *Keypad Press* in the keypad's programming |
| A text message when someone enters a wrong code three times | The event *Entry Point Locked Out* with your notification programming |
| A record of who opened what | The Flight Recorder, when installed: one marker per attempt |

## Setup

<!-- walkthrough: Set up PIN Lock -->
1. Install and pair the SmartBuildOS Agent from Composer's Agents tab.
1. Add this driver (one per project). **Driver Status** reads `Online` and
   **Gate Status** reads `setup needed (no owner code yet)`. Add it to a room
   so its Web View tile shows in the Navigator.
1. Name your guarded actions in **Guarded 1 Name** to **Guarded 12 Name**.
   An action with no name does not exist. Leave the rest empty for now.
1. For each action that should command a device itself, pick the device in
   **Guarded N Target** (the list reads `Name (Room) · id`, and is narrowed by
   **Target List Filter**; type `*` there to list everything) and choose the
   command in **Guarded N Target Action**. Leave it on `Event only` if your own
   programming will do the work.
1. Open the PIN Lock tile in the Navigator, go to the **Codes** tab and create
   the first **owner** code. This works only while no owner code exists, and
   anyone who can open the page can do it, so do it yourself before handover.
1. Still on the Codes tab, add the other codes. A PIN must be 4 to 8 digits,
   not a repeat (1111), a run (1234) or an alternation (1212), and not already
   used by another code.
1. In Composer programming, pick this driver and use the events *Guarded N
   Granted* (or *Access Granted*) to run the real work.
1. Test: tap the action on the **Actions** tab, enter a PIN, and watch **Last
   Access** and the event fire. Then test a wrong PIN and watch **Access
   Denied**.

## Guarded actions

A guarded action is a name, an optional target and one event. When a code is
accepted for it:

1. The variables `LAST_CODE_NAME`, `LAST_ACTION`, `LAST_ACTION_NUMBER` and
   `LAST_ENTRY_POINT` are set.
1. The target (if you chose one) gets its command. `Unlock` sends `UNLOCK`,
   `Lock` sends `LOCK`, `Open`, `Close`, `Toggle` and `Trigger` send the relay
   commands of the same name. If **Re-lock After Seconds** is not 0, an
   `Unlock` is followed by a `LOCK` after that many seconds.
1. The events *Access Granted* and *Guarded N Granted* fire.

The programming on those events is yours. For a lock the driver cannot talk to,
use `Event only` and do the work in a script.

## Codes

| Field | Meaning |
| --- | --- |
| Name | Up to 40 characters, unique. This is what logs and events show; it is never the PIN |
| Role | `owner` manages codes and may fire every action. `staff`, `vendor` and `guest` may fire only the actions ticked on the code. The role has no other effect |
| PIN | 4 to 8 digits for the page. Leave it empty on an edit to keep the old one |
| Keypad sequence | Button ids (1 to 4 letters or digits each), exactly **Sequence Length** of them, such as `1-3-3-2`. For keypad taps |
| May fire | The guarded actions this code may fire. Ignored for owners |
| Keypad sequence fires | Which one action the sequence fires (a sequence cannot choose) |
| Days and hours | The days of the week and the hours inside which the code works, on the controller's clock. An overnight window (22:00 to 06:00) belongs to the day it starts on |
| Starts / Expires | Local dates. A code expires at the end of its expiry day |
| Max uses | The code stops after this many accepted uses |

A code that is refused for any reason (wrong hours, expired, used up, disabled,
not allowed that action) looks exactly the same to the person at the page:
"Not allowed". The reason goes into the variable `LAST_DENIAL_REASON` and the
Flight Recorder marker, never to the screen.

Two codes cannot share a PIN, and two cannot share a sequence. An owner code
cannot be disabled, revoked or demoted while it is the last enabled owner;
add a second one first.

## The page

The Navigator tile has two tabs.

**Actions** lists the guarded actions as big buttons. Tap one, enter a PIN on
the on-screen keypad, tap *Open*. The reply is *Done*, *Not allowed* or
*Locked for N minutes*.

**Codes** asks for an owner PIN, then lists the codes with Edit, Disable and
Revoke, shows each entry point's lock state with *Clear lockouts*, and lists
the last 20 attempts (code name, action, entry point, reason). That list is
kept in memory only and starts empty after a restart. The long-term record is
the Flight Recorder.

An owner sign-in lasts ten minutes of inactivity.

## Keypad sequences

A sequence is a code that is tapped instead of typed. It needs three things:

1. **Bind the buttons.** In Composer, program each keypad button you want to
   use: *Pressed* runs this driver's command `KEYPAD_PRESS` with `BUTTON` set
   to the button's id (`1`, `2`, `A`, anything of 1 to 4 letters or digits) and
   `KEYPAD` set to a name for that keypad (`Hall`). Two keypads with different
   names do not mix their presses.
1. **Choose how long a sequence is.** **Sequence Length** (default 4) applies to
   every sequence. **Sequence Window Seconds** (default 6) is how long the
   whole sequence may take, counted from its first press.
1. **Give a code a sequence** on the Codes tab.

When enough presses have been collected inside the window, they are checked
as one attempt. A partial sequence that times out is thrown away and is not an
attempt. With no sequence code defined, presses are ignored completely.

A keypad button sequence is a weaker secret than a PIN: it can be watched, and
the button ids appear in your Composer programming. Use it for convenience
gates, not for the ones that matter most.

## Lockouts

Wrong attempts are counted separately for three **entry points**: `page` (the
Actions tab), `keypad` (sequences) and `admin` (owner sign-in on the Codes
tab). After **Max Wrong Attempts** (default 5) the entry point is locked for
**Lockout Minutes** (default 5). While it is locked, even the right PIN is
refused, and the event *Entry Point Locked Out* fires once, with
`LAST_LOCKED_ENTRY` saying which.

- Every refusal counts, including a correct PIN used outside its hours, so
  the answer never tells a guesser that a guess was close.
- A good attempt does not reset the count (otherwise one valid PIN would allow
  endless guessing). Failures are forgotten only after ten quiet minutes, or
  when a lockout starts or is cleared.
- Lockouts survive a controller restart.
- Someone can lock the page on purpose to annoy the household. Clear it with
  the action *Clear Lockouts*, the command `CLEAR_LOCKOUTS`, or (if `admin` is
  not locked) the Codes tab.

## Licence behaviour

Only a definitive denial from the Agent with enforcement switched on
restricts the driver. A missing Agent, an Agent that has not answered, or a
cloud that cannot be reached leaves everything working.

When the driver is **licence-restricted**, it does not shut: it never locks the
owner out of their own gates.

| While restricted | |
| --- | --- |
| Owner codes | Still fire every action and still sign in to the Codes tab |
| Other codes | Refused (reason `licence`) |
| New or temporary codes, edits, enabling a code | Refused |
| Disable, revoke, *Clear Lockouts*, *Remove All Codes* | Still work |
| Events | *Licence Restricted* fires when it starts, *Licence Restored* when it ends |

## Programming reference

### Commands

| Command | Parameters | What it does |
| --- | --- | --- |
| `ENABLE_CODE` | `NAME` | Turn a disabled code on |
| `DISABLE_CODE` | `NAME` | Turn a code off without removing it |
| `REVOKE_CODE` | `NAME` | Remove a code for good |
| `ADD_TEMPORARY_CODE` | `NAME`, `PIN`, `ACTIONS`, `HOURS`, `MAX_USES` | Add a guest code that expires after `HOURS` (default 24). `ACTIONS` is `all` or numbers or names separated by commas. A second command with the same name replaces an earlier temporary code |
| `KEYPAD_PRESS` | `BUTTON`, `KEYPAD` | Report one keypad button press |
| `CLEAR_LOCKOUTS` | none | Unlock every locked entry point |

**A PIN typed into a Composer programming line is saved in the project file in
clear text**, and anyone who can read the project can read it. The driver does
not print it (these two commands are kept out of the debug output), but it
cannot protect the project file. For `ADD_TEMPORARY_CODE` prefer a PIN your
programming builds from something that is not stored, or use the page.

### Events

| Event | Fires when |
| --- | --- |
| *Access Granted* | Any code was accepted. `LAST_CODE_NAME`, `LAST_ACTION`, `LAST_ENTRY_POINT` are set |
| *Access Denied* | A PIN or sequence was refused. `LAST_DENIAL_REASON` says why |
| *Entry Point Locked Out* | An entry point locked. `LAST_LOCKED_ENTRY` |
| *Guarded 1 Granted* to *Guarded 12 Granted* | A code was accepted for that guarded action |
| *Licence Restricted*, *Licence Restored* | The gate entered or left the restricted state |

*Access Denied* does not fire again for attempts refused during a lockout.
The denial reasons are `wrong_pin`, `wrong_sequence`, `disabled`, `not_yet`,
`expired`, `used_up`, `not_allowed`, `outside_window`, `licence`,
`not_owner` and `no_such_action`.

### Conditionals

| Conditional | Meaning |
| --- | --- |
| *Code is active* | Type a code name. `=` is true when the code is enabled, started, not expired and not used up (weekly hours are not considered); `!=` when not |
| *Entry point is locked out* | Type `page`, `keypad` or `admin`. `=` when locked |

### Variables

`LAST_CODE_NAME`, `LAST_ACTION`, `LAST_ACTION_NUMBER`, `LAST_ENTRY_POINT`,
`LAST_DENIAL_REASON`, `LAST_LOCKED_ENTRY`, `ACTIVE_CODES`, `GATE_STATUS`.
They are set first and the event fires after, so a script on the event can
read them. No variable ever holds a PIN, a sequence or a digest.

## Properties

| Property | Meaning |
| --- | --- |
| Gate Status | `active`, `setup needed`, or `licence-restricted` |
| Codes | How many codes exist and how many are active |
| Entry Points | The lock state of `page`, `keypad`, `admin` |
| Last Access | The last grant, denial or lockout, with the code name |
| App Data Relay | Whether the page's data connection is listening, and on which address |
| Flight Recorder | Whether a Flight Recorder was found to write markers to |
| Last Refusal | The last programming command the driver would not do, with the reason |
| Max Wrong Attempts, Lockout Minutes | The lockout rule (3 to 10, 1 to 1440) |
| Sequence Length, Sequence Window Seconds | Keypad sequence rules |
| Re-lock After Seconds | Send `LOCK` this long after an `Unlock` target action (0 = never) |
| Target List Filter | Words (comma separated) that narrow the target pickers; `*` lists every device |
| App Relay Address | `Auto`, or the controller's address if it cannot be found |
| Guarded N Name / Target / Target Action | The twelve gates |

There is no PIN property: codes are never kept in properties.

## Actions

*Print State* (codes with role, state and use counts, never PINs; entry points;
recent attempts), *Clear Lockouts*, *Refresh Device Lists*, *Republish App URL*
(if the tile shows an old page), *Remove All Codes* (starts over; use it if
every owner PIN is lost), *Register With Agent Now*, *Refresh Status*.

## The record

PIN Lock keeps no long-term log. Each grant, denial and lockout is sent to the
Flight Recorder (when one is in the project) as a marker such as
`PIN Lock granted: Unlock wine cellar` with the detail `code=Marta
entry=page`. The marker holds the code's **name**, the action, the entry point
and the reason. It never holds what was typed. Code names are the names you
typed, often a person's: they go wherever the Flight Recorder's history goes,
including the SmartBuildOS cloud when its upload is on. If there is no
Flight Recorder, nothing is recorded, quietly.

## Limits

| What | Limit |
| --- | --- |
| Guarded actions | 12 |
| Codes | 60 |
| Code name | 40 characters |
| PIN | 4 to 8 digits |
| Sequence | 3 to 8 presses, one button id of 1 to 4 letters or digits each |
| Recent attempts on the page | 20, in memory only |
| Keypads tracked at once | 8 |

- **The page is plain HTTP on your LAN.** A PIN travels in the body of a
  request from the phone or panel to the controller, never in a web address,
  but it is not encrypted on the wire. The page's address contains an access
  token; anyone who reads the page's URL (a shoulder surfer, a screenshot) can
  reach it.
- Anyone who can open the page can create the first owner code until one
  exists.
- A hostile person on the network can lock the page by guessing, which stops
  the household from using it for **Lockout Minutes**.
- The weekly hours use the controller's own date, time and time zone.
- Remote issue or revoke of codes from the SmartBuildOS cloud is not built
  (see the design note); today all code changes are made on site.

## Unverified on a controller

The driver's rules, page routes, licence handling and secrecy checks are
covered by automated tests that run off the controller. None of the following
has been run on a real controller yet:

- That `C4:HMAC` is available and returns the digest as expected on every OS
  version (the driver refuses to fall back to anything weaker).
- The Web View page on a touchscreen, phone and the Navigator proxy path, and
  its address detection.
- That `UNLOCK`, `LOCK`, `OPEN`, `CLOSE`, `TOGGLE` and `TRIGGER` are accepted
  by the lock or relay driver you pick as a target. A driver that uses other
  command names needs `Event only` and a script.
- That Director does not write command parameters (such as a PIN in
  `ADD_TEMPORARY_CODE`) to its own logs outside the driver's control.
- That the keypad's button programming delivers `KEYPAD_PRESS` promptly enough
  for a sequence to be collected inside the window.
- The `Name (Room) · id` target lists for large projects, and a list entry whose
  name contains unusual characters.
- Event and variable names as shown in Composer, including the twelve
  *Guarded N Granted* events.
- Behaviour across a real controller reboot (the lockout and codes are stored
  in the encrypted persist store; the store itself is the platform's).
- The Flight Recorder markers arriving and reading well in its history.

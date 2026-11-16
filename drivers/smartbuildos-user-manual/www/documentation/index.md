# SmartBuildOS Home Guide

Home Guide is a user manual for one house, written by the system itself. It
adds one tile to Navigator. The homeowner opens it and reads their own rooms,
the devices in each room under plain headings (lights, keypads, shades,
climate, locks, TV and music, cameras, garage and gates, security, sensors),
a short paragraph on how each kind is used, your contact details, your notes
per room and a short "what to do if" list. The driver builds the guide from
the project and rebuilds it every hour, so a renamed device or a new room
shows up without anyone editing a document.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system; the Agent is the licensing authority (SKU `SBOS_USER_MANUAL`) and
**License Status** shows this driver's standing. The controller needs OS
3.3.2 or later. The guide itself runs entirely on the controller: no cloud,
no internet needed to read it.

## Why not a handover document

The usual way is a document you write at handover. It is right on the day
you write it. Then a lamp is renamed, a room is added or a keypad is moved,
and the document is wrong although nobody touched it.

Home Guide reads the room and device names from the project, so they are the
names the homeowner sees in Navigator, and it sits on the same screen as the
rooms it describes.

Keep a written document for what the project does not hold: warranty papers,
photographs of the rack, anything longer than a line or two per room, and how
the house behaves. Home Guide lists devices. It does not list scenes,
schedules or programming.

## What it is for

| You want | Use |
| --- | --- |
| A guide to this house on the touch screens and in the app, with the names the homeowner already knows | The Home Guide tile; nothing to write |
| Your number where the homeowner looks when something is wrong | **Dealer Name**, **Dealer Phone**, **Dealer Email**, **Support Hours**, **Emergency Note** |
| One house-specific instruction in a room ("the pendants dim from the keypad by the fridge") | **Room Note 1** to **Room Note 6** |
| The guide to show a change you just made, without waiting for the hourly rebuild | *Refresh Manual*, or the command `REBUILD_MANUAL` from programming |
| To read what the homeowner will get without leaving Composer, and how many devices were left out and why | *Print Manual Outline* |
| A quick check at handover that the guide covers the house | **Devices In Manual** |
| To be told when the guide stops being served | *Guide Unavailable* and *Guide Restored*, or the variable `MANUAL_STATUS` |
| The tile to work on a network where the controller's address is not found | **App Relay Address** |

## What the homeowner sees

The tile opens one page, laid out for a phone:

- The title is **Home Name**, or "Your home" when that is empty. Under it:
  how many devices in how many rooms, and when the guide was last rebuilt
  (in UTC).
- A search box. Typing part of a room's name shows that whole room; anything
  else shows only the devices whose name matches.
- A Refresh button. It rebuilds the guide from the project and loads it
  again.
- Your dealer: the name, the phone number as a call link, the email as a
  mail link, the support hours and the emergency note. A field you left empty
  is not shown, and with all five empty the block is not shown at all.
- One card per room: the room's name, your note for it, then each kind of
  device under its heading with a "How to use" line that opens the paragraph,
  and the device names.
- What to do if: five fixed entries (a touch screen or the app is blank or
  slow; a remote does not respond; music or TV plays in the wrong room; Wi-Fi
  works but the app cannot connect; a light, shade or lock stops responding).

The headings, always in this order inside a room, and what each paragraph
tells the homeowner:

| Heading | The paragraph says |
| --- | --- |
| Lights | Tap to switch, hold and drag to dim; scenes on keypads and in the app; a double-tap on a keypad's top button usually takes the room to full |
| Keypads | Each engraved button runs a scene; many toggle off on a second tap; a lit button means its scene is still active |
| Shades and blinds | Open, close, stop or drag to a position; they may follow the sun or a schedule, and the dealer adjusts the times |
| Heating and cooling | Set the temperature and the mode on the thermostat screen; a manual change holds until the next scheduled time |
| Door locks | Lock and unlock from the app or with a code; each person can have a code; change low batteries soon, the key still works |
| TV and music | Choose Watch or Listen and pick a source; Room Off turns the room off, the house-wide Off every room |
| Cameras and doorbells | Live views are under Cameras; a doorbell press rings the touch screens and the app and shows the door camera |
| Garage, gates and doors | Open and close from the room screen or Security; a door left open can send a reminder, timed by the dealer |
| Security system | Arm and disarm with your code; Away arms every sensor, Stay leaves the inside motion sensors off |
| Sensors | They feed the automation and the security system and need only a battery change |
| Other equipment | Equipment the dealer set up for this room; ask the dealer what it does |

The paragraphs are the same in every house and cannot be edited. Read them
once against this house. Where the house differs (no reminder on the garage
door, a lock with no key), say so in a Room Note.

## Setup

<!-- walkthrough: Set up Home Guide -->
1. Install the SmartBuildOS Agent from Composer's Agents tab and pair it.
1. Add this driver to any room (one per project is enough). Composer lists it
   as SmartBuildOS Home Guide. The Home Guide tile appears in that room's
   Navigator menu; make it visible in other rooms through Room Experience
   Visibility if you like.
1. Fill in **Home Name**, **Dealer Name**, **Dealer Phone**,
   **Dealer Email**, **Support Hours** and **Emergency Note**.
1. Optionally add up to six **Room Note** lines, each written as
   `Room name: text`. For example:
   `Kitchen: The pendants dim from the keypad by the fridge.`
   Notes for the same room join together.
1. Read **Devices In Manual**, then press *Print Manual Outline* on the
   Actions tab and read the rooms, headings and devices in the Lua tab. That
   is what the homeowner gets.
1. Check **App Data Relay** reads
   `Listening :47821 - serving http://<controller>:47821 to the app`.
   The driver finds the controller's address by asking itself on each
   candidate address and keeping the one that answers, so another Control4
   device on the network (a remote, a touch screen) is never taken for the
   controller. If it says the address is unknown, or that there was no
   answer on it, type the controller's LAN IP into **App Relay Address**.
1. Open the Home Guide tile on a touch screen or in the app, on the home
   network, and read it as the homeowner will.

![Home Guide in Composer: the Properties tab, status at the top and settings below](images/properties.jpg)

![The Actions tab](images/actions.jpg)

## How the guide is built

The driver asks Director for every device in the project: its name, its
driver file name and its room. From that list it decides which devices to
leave out, which entries are the same device, and which heading each one goes
under. The guide lists what exists. It never reads a device's state.

### Rooms

A room is in the guide when at least one of its devices is. A room with only
equipment the homeowner never operates does not appear. Rooms are sorted by
name, and so are the devices under a heading, so two rebuilds of the same
project give the same guide. The sort puts capital letters before small
ones: a room named `attic` comes after `Zoo`.

### What is left out

| Left out | The rule | Counted in the outline as |
| --- | --- | --- |
| Devices with no room | The room name is empty | `no room` |
| SmartBuildOS drivers, agents, the UniFi Protect hub and the UniFi gateway | The driver file name starts with `smartbuildos`, `control4_agent`, `agent_`, `agent-`, `unifi-protect.c4z` or `unifi_gateway` | `infrastructure driver` |
| Controllers, room and UI plumbing, power controllers, timers, scenario buttons, processors and bridges | The driver file name contains `roomdevice`, `director`, `controller`, `wattbox`, `timer_`, `snapshot`, `occupancy_simulation`, `scenario`, `webview`, `c4_av-`, `av-path`, `security-light`, `luminalogic-probe`, `bond-bridge`, `driverworks_bond_bridge`, `lutron_leap_processor`, `lutron_leap_ra3_processor`, `nest_sdm_master` or `control4_thermostat_ecobee_network` | `infrastructure driver` |
| Touch screens, controllers and other UI devices, by name | The device name contains `uidevice`, `director`, `controller`, `navigator`, `touch screen`, `touchscreen`, `ea-` or `core` | `infrastructure device` |

Capitals do not matter, and a fragment matches anywhere in the name. Two
things follow that you should know before handover:

- Every driver whose file name starts with `smartbuildos` is left out. That
  is this driver, the Agent and the tools, and it is also the SmartBuildOS
  System Link devices (`smartbuildos-system-link-light.c4z` and the others).
- The name rule is on letters, not words. A device named `Pool Controller`,
  `Encore Speakers` or `Area-1 Light` is left out, because the names contain
  `controller`, `core` and `ea-`. Rename the device if the homeowner should
  see it.

### How a device's kind is decided

The driver file name is checked first, against the fragments below, top to
bottom. The first fragment found decides. Capitals do not matter.

| Order | Driver file name contains | Heading |
| --- | --- | --- |
| 1 | `keypad` | Keypads |
| 2 | `lock_`, `lock.`, `yale`, `schlage`, `kwikset` | Door locks |
| 3 | `blind`, `shade`, `somfy`, `lutron_leap_venetian` | Shades and blinds |
| 4 | `thermostat`, `tstat`, `ecobee`, `nest_sdm`, `hvac` | Heating and cooling |
| 5 | `camera`, `doorstation`, `doorbell`, `protect_` | Cameras and doorbells |
| 6 | `garage`, `gate_`, `gdo`, `door_relay` | Garage, gates and doors |
| 7 | `security`, `securitypanel`, `alarm`, `hsim` | Security system |
| 8 | `motion`, `contact`, `doorwindow`, `hingesensor`, `sensor` | Sensors |
| 9 | `light`, `lamp`, `dimmer` | Lights |
| 10 | `avswitch`, `nintendo` | TV and music |
| 11 | `switch`, `lux_`, `hue`, `bulb`, `ketra`, `lumaris` | Lights |
| 12 | `tv_`, `_tv`, `appletv`, `apple_tv`, `roku`, `shield`, `receiver`, `amplifier`, `amp`, `sonos`, `spotify`, `pandora`, `tidal`, `deezer`, `qobuz`, `tunein`, `siriusxm`, `music`, `dvd`, `bluray`, `cable`, `tivo`, `matrix`, `hdmi`, `uibutton_`, `media`, `triad`, `episode` | TV and music |
| 13 | `fan`, `fireplace` | Other equipment |

When the file name matches nothing, the device's own name is checked the
same way:

| Order | Device name contains | Heading |
| --- | --- | --- |
| 1 | `keypad` | Keypads |
| 2 | `lock` | Door locks |
| 3 | `shade`, `blind` | Shades and blinds |
| 4 | `thermostat` | Heating and cooling |
| 5 | `camera`, `doorbell` | Cameras and doorbells |
| 6 | `garage`, `gate` | Garage, gates and doors |
| 7 | `alarm` | Security system |
| 8 | `motion`, `sensor` | Sensors |
| 9 | `light`, `lamp` | Lights |
| 10 | `tv`, `speaker`, `sonos`, `receiver` | TV and music |

A device that matches nothing in either table is listed under Other
equipment. It is not dropped.

The order is what makes a keypad dimmer a keypad, and a lamp driver a light
and not an amplifier. It also has edges. These are the driver's own answers:

| Driver file | Device name | Heading |
| --- | --- | --- |
| `control4_lux_keypad_dimmer_switch.c4i` | any | Keypads |
| `avswitch_hdmi_4x4.c4z` | any | TV and music |
| `hdmi_switch_4x2.c4z` | any | Lights (`switch` is checked before `hdmi`) |
| `garage_light.c4z` | any | Garage, gates and doors (`garage` is checked before `light`) |
| `bond-fan.c4z` | Ceiling Fan | Other equipment |
| `uibutton.c4i` | PlayStation 5 | Other equipment (neither name matches) |
| a file that matches nothing | Zigbee Gateway | Garage, gates and doors (`gate` is in the name) |
| a file that matches nothing | Alarm Clock | Door locks (`lock` is checked before `alarm`) |

There is no setting that moves one device to another heading. Renaming the
device changes its heading only when its driver file name matched nothing.

### Devices that share a name

Director lists a driver and each of its proxies as separate devices with one
name, so a games console would appear twice. The driver joins them: in one
room, entries with the same name are one line. Capitals and spaces at the
ends of the name do not count. The same name in another room is its own
line.

How many real devices the line stands for is the largest number of those
entries that share one driver file. A driver and its proxy have different
files, so they count as one. Two lamps on the same driver have the same file,
so they count as two and the line reads `Reading Lamp (2)`.

The line takes its heading from the entry with the lowest device id, unless
that one falls under Other equipment and another entry does not: the entry
that says what the device is wins.

**Devices In Manual** and the count on the page are real devices, counted
this way. The "not shown" figure counts Director's entries one by one, so a
driver and its proxy that are both left out count as two.

### Room notes

Each **Room Note** is one line: the room's name, a colon, the text.

- The room name must be the room's name in the project. Capitals and spaces
  around it do not matter.
- Everything after the first colon is the note, so the note can contain
  colons.
- Two notes for the same room are joined with a space, in property order.
- A line with no colon, with nothing before the colon or with nothing after
  it is ignored. So is a note for a room that is not in the guide. Nothing
  says so: check with *Print Manual Outline*, which marks each room that
  has a note.

### When it rebuilds

| When | Notes |
| --- | --- |
| The driver starts | A controller restart, or the driver being added or updated |
| Every hour | Counted from the driver's start |
| *Refresh Manual* | From the Actions tab |
| `REBUILD_MANUAL` | From programming |
| You change **Home Name**, a dealer property or a **Room Note** | At once |
| The homeowner presses Refresh on the page | The page then loads the new guide |

Every rebuild reads the whole project again and fires *Manual Rebuilt*. The
driver is not told when the project changes, so a renamed device shows up at
the next rebuild: within the hour, or at once with *Refresh Manual*.

## How the page reaches Navigator

The page ships inside this driver. The driver runs a small web server, the
relay, on the controller's port 47821 (the same mechanism as the SmartBuildOS
Atmosphere app), and tells the tile which address to open.

| Request to the relay | Token | Answer |
| --- | --- | --- |
| `GET /ping` | no | `{"ok":true,"service":"home-guide"}` |
| `GET /app` | no | The page itself, which holds no secrets; `503` when the driver could not read it from its package |
| `GET /manual` | yes | The guide, as JSON |
| `POST /refresh` | yes | Rebuilds the guide |

The token is minted once on the controller, kept across restarts and handed
to the tile inside its address. A request with no token or the wrong one gets
`403 Forbidden`.

### Finding the controller's address

Director does not give a driver its own LAN address, so the driver works it
out:

1. **App Relay Address**, when it holds anything other than `Auto`. It is
   used as written and not checked.
1. The address Director reports for the master controller. It is published at
   once and still asked, so the status can say whether it answered.
1. Every address on the network binding of a device whose driver file name
   starts with `control4_`, lowest device id first. Such an address is
   published only after it has answered.

"Asked" means the driver sends `GET /ping` to its own relay at that address
and accepts only its own answer. Each address gets four seconds. A confirmed
address is asked again every 15 minutes, in case the controller's lease has
changed. After a pass with no answer the driver asks again after 1, 2, 4 and
8 minutes, then every 15. When nothing answers and Director gave no address,
no address is published: **App Data Relay** asks for **App Relay Address**.

### What the tile is given

| The driver has | The tile opens |
| --- | --- |
| An address, and the page read from its own package | `http://<controller>:47821/app` with the token: page and data both come from the relay |
| An address, but the page could not be read | The copy of the page Navigator loads from the controller, with the relay's address and the token passed to it |
| No address, or the relay is stopped | The same copy with no relay address. It cannot load the guide and shows a message instead of rooms |

The address is sent to the tile when the driver starts, again 60 seconds
later, whenever the address changes or you change **App Relay Address**, when
licensing stops or restores the guide, and on *Republish App URL*.

## Worked examples

### Hand over a house

<!-- walkthrough: Check the guide before handover -->
1. Set **Home Name** to `Example House` and fill in the dealer block with
   `Your Company`, `555-0100`, `help@example.com` and `Mon-Fri 9-5`.
1. Set **Room Note 1** to
   `Kitchen: The pendants dim from the keypad by the fridge.`
   and **Room Note 2** to `living: Press Room Off before bed.` The small
   first letter is fine.
1. Press *Refresh Manual*, then *Print Manual Outline*, and open the Lua tab.
1. Read the outline against the house: every room the homeowner uses, every
   device under a heading that makes sense, and the note mark on the rooms
   you wrote about.
1. Read the last line. It says how many entries were left out, by reason. If
   a device the homeowner uses is missing, see
   [What is left out](#what-is-left-out).

For a project with a kitchen, a hall, a living room and a rack room, the
outline reads as follows. Three lines for the status, the licence and the
relay come first, and each line has a time stamp in front.

```text
Example House — 3 room(s), 11 device(s), generated 2026-11-10T14:00:00Z
Dealer: Your Company 555-0100 help@example.com
Hall (2)
  Door locks: Front Door
  Cameras and doorbells: Door Station
Kitchen (3)  — note
  Lights: Island Lights, Pendants
  Keypads: Fridge Keypad
Living (6)  — note
  Lights: Reading Lamp (2)
  TV and music: Apple TV, Living TV, Sonos
  Other equipment: PlayStation 5
Not in the manual: 1 infrastructure device; 1 no room; 2 infrastructure driver
```

**Devices In Manual** for the same project reads
`11 device(s) in 3 room(s); 4 not shown`. The four are the Agent, a power
controller, a UI device and a dimmer that has no room. The rack room is not
in the guide because nothing in it is.

### Two lamps and a games console

In the living room above, two of Director's entries are named
`PlayStation 5`: the console's driver (`icon_console.c4z`) and its Navigator
button (`uibutton.c4i`). They have different files, so they are one device on
one line. Neither file name nor the device name matches a rule, so the line
is under Other equipment.

Two more entries are named `Reading Lamp`, both on `lamp_driver.c4z`. Same
name, same file: one line, `Reading Lamp (2)`, counted as two devices. That
is why the room says 6 with five lines under it.

If the homeowner needs to tell the two lamps apart, give them different names
in the project.

### Know when the guide stops

In Programming, pick this driver and the event *Guide Unavailable*, and add
the command that reaches you, for example a notification. Add the matching
line on *Guide Restored* if you want the all-clear.

*Guide Unavailable* fires when **Manual Status** leaves `serving`, and
*Guide Restored* when it returns. In this driver that is licensing: a
definite refusal with enforcement on stops the relay, and the events fire
then. The status the driver starts with fires nothing, and an unknown
controller address is not "unavailable": for that, read **App Data Relay**.

Do not hang a notification on *Manual Rebuilt*. It fires on every rebuild,
which is at least once an hour.

## Programming reference

- Events: *Manual Rebuilt* (every rebuild), *Guide Unavailable*,
  *Guide Restored*.
- Conditionals: none.
- Command: `REBUILD_MANUAL`, no parameters. In a script it reads "Rebuild
  the Home Guide from the project now". It does what *Refresh Manual* does.

| Variable | Type | Holds |
| --- | --- | --- |
| `MANUAL_STATUS` | text | The same value as **Manual Status**: `starting`, `building`, `serving`, `built (relay not listening)` or `unlicensed` |
| `MANUAL_ROOMS` | number | Rooms in the guide |
| `MANUAL_DEVICES` | number | Devices in the guide |
| `LAST_REBUILT` | text | The time of the last rebuild in UTC, as `2026-11-10T14:00:00Z` |

All four are read-only. They are written when the status is repainted: after
a rebuild from an action, the command, a property change or the hourly
timer, and once a minute.

## Properties

| Property | What it is |
| --- | --- |
| **Driver Status**, **Driver Version** | `Online` once started, and the version of this driver. A status starting `DRIVER DISABLED` means the controller's OS is older than 3.3.2 |
| **Manual Status**, **App Data Relay** | See [Reading the status](#reading-the-status) |
| **Devices In Manual** | `N device(s) in M room(s); K not shown` |
| **Last Rebuilt** | The time of the last rebuild, in the controller's local time. It does not move between rebuilds |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | The licence as the Agent reports it |
| **Home Name** | The page's title. Empty gives "Your home" |
| **Dealer Name**, **Dealer Phone**, **Dealer Email**, **Support Hours**, **Emergency Note** | The dealer block on the page. Each is optional; spaces at the ends are removed |
| **Room Note 1** to **Room Note 6** | `Room name: text`, one per property |
| **App Relay Address** | `Auto` (the default) lets the driver find the controller's address. Anything else is used as the address, unchecked |
| **Log Level**, **Log Mode** | Logging. *Print Manual Outline* prints whatever these are set to |

## Actions

| Action | What it does |
| --- | --- |
| Refresh Manual | Rebuild from the project now |
| Print Manual Outline | The status, the licence and the relay line, then rooms, headings and devices to the Lua output, then how many entries were left out for each reason, and the last error if there is one |
| Republish App URL | Send the web view URL to Navigator again (close and reopen the tile to see it) |
| Register With Agent Now | Re-register the licence with the SmartBuildOS Agent |
| Refresh Status | Repaint the status properties; they also repaint every minute |

## Reading the status

### Manual Status

| Value | Meaning | What to do |
| --- | --- | --- |
| `starting` | The driver has not finished starting | Wait |
| `building` | No guide has been built yet | *Refresh Manual*; if it stays, *Print Manual Outline* shows the last error |
| `serving` | The guide is built and the relay is listening. It does not say a Navigator can reach it: read **App Data Relay** for that | Nothing |
| `built (relay not listening)` | The guide is built but the relay could not open port 47821 | See `Not listening` below |
| `unlicensed` | Licensing stopped the guide | Read **License Status** |

### App Data Relay

| Value | Meaning | What to do |
| --- | --- | --- |
| `Listening :47821 - serving http://<controller>:47821 to the app` | The relay answered on this address, or you typed it in **App Relay Address** | Nothing |
| The same, ending `(checking)` | Director's address is published and has not answered yet | Wait a minute, or press *Refresh Status* |
| The same, ending `(no answer on it: check App Relay Address)` | Director's address is published but the relay did not answer on it | Set **App Relay Address** to the controller's LAN IP |
| `Listening :47821 - controller address UNKNOWN, set App Relay Address` | No address answered and Director gave none. The tile has no relay | Set **App Relay Address** |
| `Not listening - port 47821 unavailable` | The relay could not open its port. The driver tries again only when it next starts | Free the port, then restart the controller or update the driver |
| `Stopped - ` and the licence line | Licensing stopped the relay | Read **License Status** |

### License Status

`No SmartBuildOS Agent Found`, `SmartBuildOS Agent Found - Not Linked` and
`SmartBuildOS Agent Found - Checking...` describe the link to the Agent.
After that the line shows the licence, for example `Licensed / Subscribed`.
If it stays on Checking, press *Register With Agent Now*.

Only one case stops the guide: a definite refusal (not licensed, expired,
suspended, or registered to another controller) while SmartBuildOS has
enforcement turned on for this driver. The line then ends `(read-only)`,
**Manual Status** reads `unlicensed` and the relay stops. No Agent, no answer
yet or an unreachable cloud never stops it. When the Agent next reports a
valid licence, the relay starts again by itself.

### Problems on site

| You see | Why | What to do |
| --- | --- | --- |
| The tile says "This guide needs the controller connection" | The page was given no relay address | Read **App Data Relay**: it says UNKNOWN, Stopped or Not listening. Fix that, then *Republish App URL* |
| The tile says "Could not load the guide" | The page opened but the relay did not answer it, or refused the token (`HTTP 403` in the message) | Read **App Data Relay** first. Then, from a laptop on the same network, open `http://<controller>:47821/ping`. No answer: the address is wrong, set **App Relay Address**. An answer naming `home-guide`: *Republish App URL*, then close and reopen the tile |
| The tile says "No rooms yet" | The guide has no devices in it | *Print Manual Outline* and read the last line |
| A device is missing | It has no room, or its driver file or its name matches [What is left out](#what-is-left-out) | Give it a room; rename it if the name is the cause. The outline gives a count per reason, not the names |
| A device is under the wrong heading, or under Other equipment | The first matching fragment decides: see [How a device's kind is decided](#how-a-devices-kind-is-decided) | Rename it if its driver file matches nothing. Otherwise explain it in a Room Note |
| Two devices show as one line | They have the same name in the same room | Give them different names |
| A room note does not appear | No colon, or the room name does not match, or the room is not in the guide | Correct the line; the outline marks rooms that have a note |
| The page shows an old name | The guide is rebuilt hourly, not when the project changes | *Refresh Manual*, or Refresh on the page |

## What is not claimed

The guide lists what exists, never what state it is in, and it does not
control anything. The how-to paragraphs are generic for each kind of device;
your Room Notes are where house-specific instructions belong.

- Scenes, schedules and programming are not listed.
- There are six room notes, and no way to hide one device or to choose its
  heading other than the rules above. On the bench project most media-source
  tiles landed under Other equipment, because they share one driver file the
  rules do not know.
- The page's fixed text is in English. There is no PDF or printed export.
- Bench, 10 November 2026: the driver read `serving` with the relay
  listening, *Refresh Manual* and *Print Manual Outline* were run,
  `REBUILD_MANUAL` was run from a programming line, the relay answered
  `/ping` on the controller's address and **App Data Relay** named that
  address.
- On that bench controller `/app` answered `503 app not loadable`: the driver
  could not read the page from its own package there. The tile therefore
  used the second row of
  [What the tile is given](#what-the-tile-is-given), which is the designed
  fallback. The first row, page and data both from the relay, has not been
  seen working.
- The bench record does not say the page was read on a touch screen or in
  the app. Whether it opens in the app away from the home network has not
  been measured; the page's own message says "on the home network".
- Port 47821 is assumed free on the controller. What happens when another
  driver already holds it has not been tested.

## Privacy

The manual holds device and room names and the dealer block you typed.
Nothing leaves the controller. The relay answers the manual only to a request
carrying the token Navigator was given; `/ping` answers to anyone on the LAN
and reveals nothing, and `/app` is the page with none of the house's data in
it. Everything you type in a **Room Note** or the **Emergency Note** is shown
to whoever opens the tile: do not put door or alarm codes there.

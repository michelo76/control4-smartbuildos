# SmartBuildOS VenueFlow

VenueFlow turns an existing Control4 project into a control surface that
venue staff can use without training: a bar, a restaurant, an office, a
conference room. Staff see their venue, tap the displays they mean, pick what
to watch, and VenueFlow asks Control4 to do it. They never see a Control4
room list, a matrix output or an HDMI input.

The installer sets all of that up once, in **Installer Studio**, a page this
driver serves on the venue's network: which displays exist and which Control4
rooms they are, where they hang on the floor plan, which sources each can
show, the audio zones and their volume limits, the scenes and schedules, and
what each staff profile may see and do.

> **Release standing.** This build is **simulation verified**. Its logic is
> tested against a simulated Control4 project. On a bench controller it has
> been installed and run in Simulation only: it has not yet controlled real
> equipment. Start in Simulation, and follow the hardware validation list
> in the repository (`docs/smartbuildos-venueflow/HARDWARE_VALIDATION.md`)
> before a venue relies on it.

## What it is for

| You want | VenueFlow gives you |
| --- | --- |
| A bartender to put the game on six TVs in two taps | Command Center: tick displays, pick a source, Route. Each display reports back |
| Staff to see the room, not a device list | Visual Floor Plan: TVs where they hang, on your own floor plan picture |
| A meeting room anyone can run | Simplified Room Control: four big buttons (Present Laptop, Video Conference, Watch TV, Room Off) with volume, lights and shades |
| A manager to see what is wrong | Manager Overview: what is on, what did not confirm, what is muted, Open and Close, All Off |
| One button for "Game Day" | Scenes: power, video, audio, volume, lighting, in order, with a report of what each device did |
| The venue to open itself | Schedules, on the controller's clock |
| The bar tablet to control only the bar | Staff profiles with areas, sources, zones and scenes, enforced by the driver |
| To set a venue up without writing programming for each one | Installer Studio: wizard, device mapping with test buttons, layout designer, visual programming |
| To know a route really happened | Every change is confirmed against Control4's room state, or reported as "not confirmed" |

What it is not: a matrix driver. VenueFlow selects a source in a display's
Control4 room and Control4 routes the video through whatever the project has
(HDMI matrix, AV-over-IP, direct). The project's AV connections must already
work in Composer.

## Before you start

- Control4 OS 3.3.2 or later.
- Each display that should show its own picture is **its own Control4 room**
  (the usual commercial arrangement), with its video path to the shared
  sources connected in Composer.
- Each audio zone is a Control4 room with volume control. A zone that must be
  independent of the pictures needs its own room, and audio hardware that can
  really play a different source there.
- The SmartBuildOS Agent in the project, for licensing.

## Set it up

<!-- walkthrough: Add the driver -->

1. In Composer Pro, check the title bar names the system you mean to work on.
2. Driver, Add or Update Driver, and choose `smartbuildos-venueflow.c4z`.
3. System Design, Items, Search: type VenueFlow, select a room, double-click
   the driver to add it.
4. Open its Properties. **Driver Status** reads "Online - Simulation": the
   driver starts in Simulation and sends nothing to Control4.
5. Set **Installer Passcode** to six or more characters and press Set.
   Without a passcode, Installer Studio stays off.
6. Read the **Installer Studio** property: it shows the address, for example
   `http://<controller address>:47861/studio`. If it says the address is
   unknown, see "The tile does not load" below.
7. In Navigator, make the VenueFlow tile visible in the rooms where staff
   will use it.

<!-- walkthrough: Build the venue in Installer Studio -->

1. On a laptop or tablet on the venue network, open the Installer Studio
   address and sign in with the passcode.
2. **Setup Wizard, step 1**: pick the business type and name the venue. The
   template brings areas, scenes and staff profiles you can change.
3. **Step 2, Discover**: list the project's devices. The categories are a
   suggestion; you can map anything by hand.
4. **Step 3, Map devices**: for each display, choose its Control4 room and
   device; add the sources; add the audio zones with their volume limits.
5. **Step 4, Layout**: upload a floor plan or start blank, and drag each
   display to where it hangs.
6. **Step 5, Staff profiles**: who may see which areas, use which sources and
   scenes, and which screens they get. Give managers a PIN. Choose the
   profile a tile opens with.
7. **Step 6, Review and publish**: fix the errors, tick each warning you have
   checked, publish.
8. While still in Simulation, open the tile and try everything: the page
   behaves as it will, against a simulated project.

<!-- walkthrough: Go live -->

1. Make sure nobody is relying on the rooms.
2. In Installer Studio, Devices: select a display and press **Query Status**.
   It should show what Composer shows for that room.
3. Set the property **Control Mode** to **Live** and press Set.
4. Devices: **Test Route** on one display (it warns that this interrupts the
   display). The display should change, and the Studio should say
   "confirmed". If it says "not confirmed", the room's video path in Composer
   is the first thing to check.
5. Repeat for each display and each audio zone, then try the operator page.

## The four operator screens

Each staff profile gets the screens the installer allows.

- **Floor Plan.** The venue from above. Tap displays to select them, pick a
  source, Route Video. "Listen" sends that source's sound to an audio zone.
  Scene shortcuts and zone volume sit along the bottom.
- **Command Center.** A grid of displays with filters by area and group.
  Select, choose a source, route; or pick the source first and tap displays.
  Audio zones have a mixer row.
- **Room Control.** Large buttons that run the room's scenes, with volume,
  lighting presets and shades when the room has them.
- **Manager.** Counts, alerts with a way to resolve each, scenes, Open and
  Close venue, All Off with a preview of what it will switch off.

What the marks mean on every screen:

| Mark | Meaning |
| --- | --- |
| Confirmed | Control4 reports the display or zone in that state |
| Working | The command was sent; the answer is awaited (up to about 8 seconds) |
| Sent | The device gives no feedback; VenueFlow cannot confirm it |
| Not confirmed | Control4 did not report the change, or reported another state |
| Unknown | Not read yet |
| Offline | Control4 reports the display's link down |

A route to six displays reports six outcomes. If four changed and two did
not, the screen says so and names them.

## Scenes, rules and schedules

In Installer Studio, a scene reads as **WHEN / IF / DO**:

- WHEN Game Day is pressed
- IF the venue is open
- DO: power on the Main Bar displays; route Sports 1 to TVs 01 to 06; route
  Sports 2 to TVs 07 to 12; play Sports 1 in the Bar zone; set the Bar zone
  to 65%; lighting preset Game Day; send a notification.

Steps come from a fixed list: power displays, route video, route audio, set
volume, mute, turn a zone off, lighting preset, shade, wait, IF / ELSE, run
another scene, set a variable, mark the venue open or closed, send a
notification. Nothing you type is run as code.

**Dry Run** shows what a scene would do and sends nothing. **Execute Test**
runs it for real and shows each step and each device. A scene marked "ask
first" shows operators a preview and waits for confirmation.

A **rule** adds a trigger: a schedule, another scene, the venue opening or
closing, a display or zone changing state, a Control4 variable, or a Control4
event sent from Composer programming (see Programming).

Schedules follow the controller's clock and the project's time zone. A
schedule missed while the controller was off is not run late; the manager is
told it was missed.

## Staff profiles and sign-in

A tile opens as the profile the installer chose (for example Bartender, bar
only), with no sign-in. Staff with a PIN (a manager) tap the profile chip and
sign in on that screen; the screen then shows what that profile may see.

Permissions are enforced by the driver. A screen that has been tampered with
still cannot route a display its profile does not have. Changing the venue's
configuration is never a profile permission: it needs the Installer Passcode.

## Properties

| Property | Meaning |
| --- | --- |
| Driver Status | Online, Online - Simulation, or an error |
| Driver Version | The build stamp |
| Venue | The published venue's name |
| Configuration | The published version and what it holds |
| Draft | The draft's revision in Installer Studio |
| Venue Status | open or closed |
| Active Scene | The scene last run |
| Alerts | How many alerts the manager is being shown |
| Installer Studio | Its address, or why it is off |
| App Data Relay | The address the tile is served from, and whether it answered |
| Last Error | The last refused Composer command or internal error |
| License Status, License Source, Subscription Tier, SmartBuildOS Company | From the SmartBuildOS Agent |
| Control Mode | Simulation (nothing is sent to Control4) or Live |
| Installer Passcode | Opens Installer Studio. Hidden. Empty keeps the Studio off |
| App Relay Address | Auto, or the controller's address when the tile will not load |
| Log Level, Log Mode | At "3 - Info" with Print, every command sent to Control4 is printed in the Lua tab |

## Actions

| Action | What it does |
| --- | --- |
| Print Installer Studio Link | Prints the Studio address in the Lua tab |
| Print Operator Page Link | Prints the tile's address (it carries the tile's token: treat it as private) |
| Print Status | Prints a summary and the latest warnings |
| Reload Configuration | Re-reads the published venue and Control4's state. Sends no command |
| Refresh Status | Re-reads every mapped room |
| End Staff Sessions | Signs every staff member out |
| Reset Sign-in Locks | Clears a lock after too many wrong PINs or passcodes |
| Register With Agent Now | Asks the SmartBuildOS Agent for the licence again |

## Programming

Commands (Device Specific Command):

| Command | Use |
| --- | --- |
| Activate the VenueFlow scene SCENE | Run a scene by name from a keypad button or a schedule |
| Trigger the VenueFlow event NAME | Start the rules that wait for that event name |
| Route the source SOURCE to TARGET | TARGET is a display, a display group, or All |
| Mark the venue STATUS | Open or Closed |
| Turn off every VenueFlow display and audio zone | All Off |

Events: Scene Activated, Notification, Alert Raised, Configuration Published,
Venue Opened, Venue Closed, Licence Restricted, Licence Restored.

Variables: VENUE_STATUS, ACTIVE_SCENE, NOTIFICATION_TEXT, ALERT_COUNT.

Conditionals: Venue is open; Active scene is (name); VenueFlow has alerts.

**Worked example: a notification when a scene asks for one.** In the scene,
add the step "Send notification" with the text "Keg change needed". In
Composer, on the VenueFlow event **Notification**, add your notification
driver's command and insert the variable NOTIFICATION_TEXT as the message.
To test: run the scene with Execute Test; the Lua tab shows the event, and
the message arrives with the text.

**Worked example: a Control4 event starts a VenueFlow rule.** In Installer
Studio, add a rule with the trigger "A Control4 event" named `Doorbell`. In
Composer, on the doorbell's event, add the command **Trigger the VenueFlow
event** with NAME `Doorbell`. To test: press Execute on that programming line
and look at the rule's last run in the Studio.

A command that is refused (an unknown scene, a condition not met) says why in
the **Last Error** property.

## Licensing

VenueFlow licenses through the SmartBuildOS Agent (SKU SBOS_VENUEFLOW).

| Standing | Effect |
| --- | --- |
| No Agent, Agent checking, licensed, trial, grace | Everything works |
| A definite "not licensed" that the platform enforces | Scenes, rules, schedules, publishing and rollback stop |

Routing, power, audio, lighting, shades, All Off, venue status and backup
export always work, and no licence change ever switches a display off.

## Backup

Installer Studio, Configuration Backup: Export downloads one file with the
venue, its floor plan pictures and the staff PIN hashes (never the Installer
Passcode). Restore fills the draft; the venue keeps running on what is
published until you publish. Keep the file private.

## Troubleshooting

**The tile does not load.** Read **App Data Relay**. If the address is
unknown or unconfirmed, set **App Relay Address** to the controller's address,
wait a minute, reopen the tile. From a laptop,
`http://<controller address>:47861/ping` should answer.

**"This venue has not been set up yet".** Nothing is published. If
**Configuration** reads "Sample venue - not run in Live mode", a sample venue
is published and Control Mode is Live: build the real venue or return to
Simulation.

**A display says "Not confirmed".** Control4 did not report the change. Check
the display, the source and the room's video path in Composer; then Resolve
(Manager screen) or Query Status (Studio, Devices).

**Sound changes when the picture changes.** The display and the audio zone
are the same Control4 room. The Studio warns about this. Give the zone its
own room.

**Nothing reaches Control4.** Control Mode is Simulation.

**A schedule did not run.** It was missed while the controller was off (an
alert says so), or its rule is disabled, or the day is not ticked.

**Signed out.** Sessions end when the driver restarts, when a PIN or the
passcode changes, and after the time limits.

The full troubleshooting guide, the installer, operator and programmer
guides, the data model and the hardware validation list are in the
repository under `docs/smartbuildos-venueflow`.

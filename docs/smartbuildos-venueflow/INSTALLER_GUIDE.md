# VenueFlow installer guide

For the dealer setting a venue up. Read "What the project needs" before
quoting a job: VenueFlow makes a working Control4 AV project easy to operate;
it does not replace the project's AV design.

> **This build is simulation verified, not hardware validated.** On a bench
> controller, installation, the pages, Installer Studio and publishing have
> been walked through in Simulation, on a build of 14 November 2026
> (HARDWARE_VALIDATION.md, Results). The Live-mode steps below, everything
> that touches real equipment, have not; nor have sections 10 to 12 (the
> Venue Studio, Remote Management, source controls), which came later.
> Work through HARDWARE_VALIDATION.md on a bench before a venue relies on it.

## 1. What the project needs

| Need | Why |
| --- | --- |
| Control4 OS 3.3.2 or later; T3 on OS 3.1.3+ or T4 on OS 3.2.1+, or the Control4 app | The pages are written for the browser those have |
| **One Control4 room per display** that must show its own picture | Control4 routes video per room. Two TVs in one Control4 room always show the same thing |
| Each room's video path to the shared sources connected in Composer | VenueFlow asks the room to select a source; Control4 routes it through the matrix or AV-over-IP system you bound |
| One Control4 room per audio zone, with volume control | A zone is a room. For sound that is independent of the pictures, the zone's room must not also be a display's room, and the audio hardware must be able to do it |
| The control screens on a network guests cannot join | The pages are plain HTTP on the LAN |
| A reserved address (DHCP) for the controller, and for any screen you make a "station" | The tile and the Studio are served from the controller's address |
| The SmartBuildOS Agent in the project | Licensing |

VenueFlow does **not**: drive a matrix by itself (Control4 does), discover
how the venue is wired (you map it), or work from outside the venue network
without your own remote access.

## 2. Install the driver

1. Read Composer's title bar: it must name the system you mean.
2. Driver, Add or Update Driver: choose `smartbuildos-venueflow.c4z`.
3. System Design, Items, Search "VenueFlow". Select a room, then double-click
   the driver.
4. Properties: **Driver Status** is "Online - Simulation". The driver sends
   nothing to Control4 until you set **Control Mode** to Live.
5. Set **Installer Passcode** (six or more characters). Press Set.
6. **Installer Studio** now shows an address like
   `http://<controller address>:47861/studio`. If it does not, see
   TROUBLESHOOTING.md, "The tile or a page does not load".
7. In each room where staff will use it, make the VenueFlow tile visible in
   Navigator.

## 3. Open Installer Studio

On a laptop or tablet on the venue network, open the address and sign in
with the passcode. The Studio keeps one **draft** of the venue on the
controller. Every change saves to the draft by itself (the header shows
"Saved" and the revision). Nothing reaches the venue until you **publish**.

The header also shows: Simulation or Live, the published version, and how
many issues the draft has. The left side lists the sections:

| Group | Sections |
| --- | --- |
| Setup | Overview, Setup Wizard |
| Venue | Devices, Sources, Audio Zones, Layout Designer, Display Groups, Lighting and Shades, Room Panels |
| Automation | Scenes, Visual Programming, Scheduling |
| Access | Staff Profiles, Stations |
| System | Diagnostics, Licensing, Configuration Backup, Publish and Rollback |

## 4. The Setup Wizard, step by step

### Step 1. Venue

Pick the business type: Sports Bar, Restaurant, Corporate Office, Conference
Center, Hotel, Fitness Center, Retail or Custom. Name the venue and press
"Start from this template". The template brings a floor, areas, scene
templates and staff profiles for that kind of venue; change any of it.

If a draft already exists, the Studio says the whole draft will be replaced
and asks before doing it.

Then set the default screen, the subsystems in use (video, audio, lighting,
shades), and the floors and areas. Areas matter: staff permissions are given
per area, and a display belongs to one.

In Simulation mode you can instead load a **sample venue** (a 24-display
sports bar or a conference centre) to see everything working. Samples use
invented Control4 ids and are refused in Live mode.

### Step 2. Discover devices

"Discover" lists the project's devices by category (rooms, displays,
projectors, video switches, AV-over-IP, sources, audio, lighting, shades) and
says how each was recognised: by its proxy type, or by its driver's file
name. Treat it as a suggestion. Anything can be mapped by hand in the next
step.

### Step 3. Map devices

Opens **Devices**. For each display:

| Field | What to enter |
| --- | --- |
| Name | What staff call it ("Bar TV 01") |
| Floor, Area | Where it is |
| Control4 room | **The room this display is the video destination of.** Pick it from the discovered rooms or type its id |
| Control4 device | The display's own device (used for link state, and for device power) |
| Route | *Room*: Control4 selects the source in that room (the normal choice). *Custom command*: one command to a device you name, for something Control4 does not route by itself; `${source}` in a parameter becomes the source's device id. *None*: the display cannot be routed |
| Supported sources | All, or the list this display can show |
| Default source | What to select when the display is powered on with no previous source |
| Power | *Room*: off is the room's off; on is selecting a source. *Device*: ON and OFF to the display device. *None* |
| Feedback | *Room*: VenueFlow reads the room's state to confirm changes. *None*: changes show as "sent" |
| Audio zone | The zone "Listen" offers for this display. An association, never an automatic route |
| Groups | Which display groups it is in |

Then **Sources** (name, kind, the Control4 device a room selects, video and
audio) and **Audio Zones** (name, area, its Control4 room, allowed sources,
minimum, maximum and default volume, presets). **Lighting and Shades**: a
lighting control's presets (each one Control4 command to one device) and
each shade's device, with its open and closed levels: numbers from 0 to 100,
100 and 0 when left empty; anything else is refused at save and publish
("Open level must be between 0 and 100.").

**Test as you go.** In the display's inspector:

- **Query Status** reads the room and sends nothing.
- **Test Power On / Off** and **Test Route** send real commands (in Live
  mode) and then read the room back. They warn first: a test interrupts what
  the display is showing. A test is "confirmed" only when Control4 reports
  the change.
- **A sample venue cannot be tested in Live mode.** Its Control4 ids are
  invented and could belong to real devices in the project, so with a sample
  in the draft every test, Query Status included, answers "simulation only".
  Map the real devices (Setup Wizard with a template), or go back to
  Simulation.

In Simulation the tests run against the simulator, which is how to learn the
tool; they prove nothing about the venue.

### Step 4. Layout

Opens the **Layout Designer**.

- Upload the venue's floor plan (a photo or an export from a drawing; it is
  reduced to fit) or work on a blank canvas. Set the floor's size.
- Drag each display from "Unplaced displays" to where it hangs. Resize and
  rotate it. Turn on Snap for a tidy plan.
- Draw areas, place audio zones, add labels ("Main Entry") and scene buttons.
- Undo and redo; zoom and pan; lock what is finished; hide layers while you
  work.
- **Preview** shows the plan as a chosen staff profile will see it.

Moving or hiding an icon never changes what it is mapped to. "Remove from
floor plan" only takes the icon off the plan; the display stays mapped and
controllable. "Delete display" is separate and asks first. Nothing in the
Studio can delete or change a Control4 device.

### Step 5. Staff profiles

Opens **Staff Profiles**. Start from a role (Owner, Manager, Bartender, Host,
Conference Staff, Restricted Operator) and adjust:

- which screens the profile gets, and which opens first;
- what it may do: route video, switch displays, control audio, lighting,
  shades, run scenes, open and close the venue, All Off, see alerts, use
  source controls (section 12), open the Venue Studio (section 10);
- where: floors, areas, sources, audio zones, scenes.

Give a **PIN** (4 to 8 digits) to any profile that can run venue-wide
actions. The Studio warns when one has none.

"A tile opens as": the profile every tile shows without a sign-in. Choose a
restricted one without a PIN (the bartender, the room panel). Staff with a
PIN sign in on any screen from the profile chip.

**Stations** (optional): give one fixed screen its own profile by its
network address, for example the host stand opens as Host while the bar
tablets open as Bartender. Reserve the screen's address in the router. A
station can only be given a profile without a PIN.

Permissions are enforced by the driver, not by the screen.

### Step 6. Review and publish

Every issue is listed with a link to where it is fixed.

- **Errors** must be fixed (a display on a floor that no longer exists, two
  displays in one Control4 room).
- **Warnings** must be fixed or ticked "I have checked this" (an unmapped
  display, a display and an audio zone sharing a Control4 room, a manager
  without a PIN, a custom route command).

Publish. The venue switches to the new version at once. Staff whose PIN
changed or whose profile was removed are signed out.

## 5. Scenes, rules and schedules

**Scenes**: add one from a template (Opening, Closing, Game Day, Happy Hour,
Dinner, Presentation, Conference, Cleaning) or blank. A scene reads WHEN / IF
/ DO. Add steps, reorder them, duplicate, remove; nest IF / ELSE. Tick "Ask
operators to confirm" for scenes that switch things off.

Before relying on a scene:

1. **Validate**: reports anything the driver would refuse.
2. **Dry run**: shows what each step would do, per display, and sends
   nothing. It uses the published venue, so publish first.
3. **Execute test**: runs it for real and shows each step and each device as
   they finish. A step is done only when its devices confirm.

**Tune a channel** (under Displays in Add step) puts a source's box on a
favourite or a channel number. Only switched-on sources with the number
keypad are offered (section 12). The step is "sent", never confirmed, and
the scene does not wait for the last digit: if a later step needs the
channel, put a Wait before it. If you remove a favourite that a step uses,
the Studio names the scene, schedule or rule and the venue cannot be
published until the step is changed. Staff who may run the scene do not
need "Use source controls". Like the source controls, it has never been
seen to move a real box.

**Visual Programming** holds the rules: a trigger (a schedule, a scene
running, the venue opening or closing, a display or zone changing, a Control4
variable, a Control4 event sent from Composer), an optional condition, and
steps.

**Scheduling** shows the week. Schedules follow the controller's clock and
the project's time zone (Composer, Project Settings).

## 6. Room panels

For an office or a meeting room: **Room Panels**. A panel is up to six large
buttons, each running a scene (Present Laptop, Video Conference, Watch TV,
Room Off), with optional volume (an audio zone), lighting presets and shades.
Give the room's panel a restricted profile limited to that room's area, and
make it the tile's profile there (a station, when other rooms differ).

## 7. Go live

1. Nobody should be relying on the rooms.
2. Devices: Query Status on a few displays: the values should match Composer.
3. Set **Control Mode** to **Live** (driver property). If the published venue
   is a sample, the driver refuses to run it: build the real venue first.
4. Test Route each display and Test Source each zone.
5. Try the operator screens as each profile.
6. Run each scene with Execute test.
7. Export a backup (section 8) and keep it private.

## 8. Backup, rollback, hand-over

- **Configuration Backup**: Export downloads one file (the venue, its floor
  plan pictures, staff PIN hashes; never the Installer Passcode). Restore
  fills the draft; publish to use it. This is also how to move a venue to a
  replacement controller.
- **Publish and Rollback**: the last five published versions are kept. Roll
  back to any of them; the version you leave is kept too.
- At hand-over: give the owner the operator guide, the manager's PIN, and
  keep the Installer Passcode yourself. Changing the passcode ends every
  Studio session.

## 9. Diagnostics and licensing

**Diagnostics** is the driver's log: every refusal, failed route, scene run,
sign-in problem and configuration change, with a code. It never holds PINs,
the passcode or tokens. It is kept in memory (the newest 400 entries) and
starts empty after a driver restart; the project's Flight Recorder, when
present, keeps the long history.

**Licensing** shows the standing with the SmartBuildOS Agent and what it
affects. A venue without a licence, or cut off from the internet, keeps full
manual control.

## 10. The Venue Studio: what the client can change

The venue's owner or manager can look after the day-to-day themselves,
without the Installer Passcode.

1. In Staff Profiles, open the profile (the Owner role has it already) and
   switch on **May open the Venue Studio**. Give the profile a PIN: the Studio
   only opens with one.
2. Publish.
3. The client signs in with that PIN on a control screen, opens the profile
   menu and chooses **Venue Studio**; or opens
   `http://<controller>:47861/studio` and picks their name.

They can change scenes, schedules, staff profiles and PINs, source names,
channel labels and favourite channels, and volume presets, and publish that.
They cannot change devices, routing, the layout, groups, lighting, shades,
rooms, stations, rules on events, the venue record, Control Mode, backups or
licensing, and they cannot give the Venue Studio permission to anyone. Two
kinds of staff profile stay entirely yours: the one a tile opens as, and any
profile a station opens as. Anyone on the venue network acts as those, so
the client cannot change, rename or remove them, or set or clear their PIN.
The driver refuses all of this, whatever the page sends.

Every save is recorded with who made it. Once you have saved anything in
the draft (a change, a staff PIN, a template), or the dealer has sent a
draft through Remote Management, the draft is your unfinished work until it
is published or discarded: the client can keep editing but cannot publish
or discard. Their Studio says why, in plain words, in its header, on Home
and on Publish and Rollback (where the buttons are disabled): "Your
installer saved changes that are not live yet", "Your dealer saved changes
remotely that are not live yet", or that the draft has a change only you can
make; and it says who to ask. Publish or discard your work first. In the
client's Staff Profiles, the profile a tile opens as and any station's
profile are shown read-only ("This is the profile screens open with. Only
your installer can change it."). The station case has not been seen in a
browser (the samples have no stations).

Publish and Discard, yours and the client's, name the draft revision the
page last loaded or saved. If someone else saved the draft since, nothing is
published or discarded: the page says the draft changed since it was
loaded, reloads it and does not try again.

**Not yet tried on a touch screen or in the Control4 app** (checked in
desktop Chromium against the simulator, at 390 x 844, 820 x 1180, 1024 x 600
and 1280 x 800).

## 11. Remote Management (smartbuildos.io)

The driver property **Remote Management** decides what smartbuildos.io may
do with this venue's configuration through the SmartBuildOS Agent:

| Setting | smartbuildos.io may |
| --- | --- |
| Off (default) | nothing |
| Draft only | read the configuration and fill the draft; someone on site publishes |
| Draft and publish | also publish a draft and roll back |

It never routes video, changes a volume, runs a scene or sets a PIN.

The smartbuildos.io side exists: in your System Studio, Drivers & Licenses,
VenueFlow (Overview, Sources, Audio, Schedules, Whole configuration,
Publish, Driver). **It has never been run together with a controller**, so
keep the switch Off on a venue that relies on VenueFlow until the bench run
in HARDWARE_VALIDATION.md has passed. The `SBOS_VENUEFLOW` licence cannot be
issued yet either (SMARTBUILDOS_INTEGRATION.md).

What to know before switching it on:

- A remote draft makes the draft your unfinished work (section 10): the
  client waits until it is published or discarded.
- A remote draft must name the revision it was made from, and a remote
  publish the revision that was reviewed; work done on site is never
  overwritten silently.
- **Device mapping is yours, on site.** Which Control4 room or device a
  display, source, audio zone, lighting preset or shade addresses, a
  display's power, feedback and route (its custom route command included),
  a lighting preset's command, and the device and variable of a rule's
  Control4-variable trigger or condition: only you change these, in
  Installer Studio. A remote draft that would change any of them is refused
  as a whole ("Remote Management cannot change device mapping or device
  commands: Display 'TV 03' room. Change these on site in Installer
  Studio."), and nothing is stored. A display or source added remotely
  arrives unmapped, for you to map on site; one removed remotely is simply
  gone.
- **Making a mapping live is yours too.** A remote publish is refused while
  the draft's mapping differs from what is live, even when you put that
  change in the draft yourself; a remote rollback is refused when the older
  version had another mapping. So while a mapping change of yours sits
  unpublished in the draft, the dealer can save other edits on top of it
  but cannot publish: publish it on site first.
- **What the dealer can still change remotely:** names, the layout,
  scenes, rules and schedules (including "Tune a channel" steps), groups,
  volume limits and presets, staff profiles, channel labels, favourites, a
  source's control groups, shade open and closed levels. With **Draft and
  publish** that can go live with nobody on site, and a scene or schedule
  written remotely can route any mapped source to any mapped display and
  tune any mapped box. Choose it only where you trust the dealer's platform
  account to run the venue's equipment as you mapped it
  (SECURITY_REVIEW.md).
- A refresh from the platform (`refresh_status`) asks the driver for a
  one-line summary (what runs, the mode, the venue status, the alerts, the
  draft) and the published version the controller runs.

## 12. Basic source controls (channel keys, keypad, favourites)

In Sources, each source has a **Basic controls** card:

| Group | Keys |
| --- | --- |
| Channel | CH +, CH -, Last |
| Number keypad and favourites | 0 to 9, dash, Enter, and the favourite channels |
| Arrows, guide, info, menu | Up, Down, Left, Right, OK, Guide, Info, Menu, Exit, Page + and - |
| Play, pause, skip | Prev, Rew, Play, Pause, Stop, Fwd, Next |

A cable or satellite source starts with the first two; a streaming source
with the last two. Switch on only what the device really has.

- The keys go to the Control4 device the source is mapped to.
- **Favourite channels** (up to 24 per source) dial the number with one
  press: each digit, then Enter. Switch "Press Enter after the digits" off
  for a box that tunes by itself. The venue can edit favourites in the Venue
  Studio.
- Give staff the permission **Use source controls** in Staff Profiles. Staff
  then see a remote button beside the source.
- One box often feeds several screens: a key changes all of them. The remote
  says how many screens are showing the source.
- Nothing comes back from a box. VenueFlow shows a press as sent; it does not
  know the channel.
- Scenes, rules and schedules can tune a box too, with the **Tune a
  channel** step (section 5). If a run that was dialling a number is
  stopped, the rest of the number is not sent. After a number is cut off,
  or on a box that dials without Enter, the next number for that box waits
  about 3 seconds so the digits do not run together; other boxes are not
  held up. That pause is an assumption about boxes, not seen on one: check
  it on site.

**Test this on site in Live mode before you rely on it** (HARDWARE_VALIDATION.md).
It has only been run against the simulator. If a favourite drops a digit on
a real box, tell us: the gap between digits is fixed at 350 ms in this build.

# SmartBuildOS System Link Export Light

This driver shares one real light of this project with the linked Control4
project. You bind the light to it in Composer's Connections, give the export a
name, and it registers that light with SmartBuildOS System Link in this project.
From then on the light's state crosses the link, and, if you allow it, the other
project can switch the light.

It is the sending half of a pair, and it does not present anything itself:

| Driver | Goes in | What it does |
| --- | --- | --- |
| SmartBuildOS System Link Export Light (this one) | The project that has the real light (the owner) | Shares the light as an export |
| SmartBuildOS System Link Light | The other project | Shows that export as a Control4 light |

The same export can be made without this driver, from the **Device Exports**
block of SmartBuildOS System Link. This driver exists because binding in
Connections leaves nothing to guess: the bound device is the light itself, the
one that carries its state, never the hardware driver that shares its name.

## What it needs

- **SmartBuildOS System Link** in this project, with the link to the other
  project set up. This driver finds it by itself.
- A light in this project: the Control4 light for a dimmer or a switch.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and lights are part of every pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Share a light -->
1. Add this driver to the project that has the real light. Use one per light you
   want to share. **Export Status** reads
   `Bind the light to this driver's Light connection in Composer Connections`.
1. In Connections, bind the light to this driver's **Light** connection.
1. Look at **Export Name**. If it was empty it is now filled in from the light's
   name: "MBR Baseboard" becomes `MBR_Baseboard`. Change it if you want.
   Letters, digits and underscores, starting with a letter, 40 characters at
   most.
1. Set **Export Control**. `View only` shares the state. `Control allowed` also
   lets the other project switch and dim the light. To allow only some
   operations, list them in **Export Operations**: `on`, `off`, `set_level`,
   separated by commas. Blank allows all three.
1. Read **Export Status**. `Exported as MBR_Baseboard (exported)` means
   SmartBuildOS System Link has taken it. `Refused:` is followed by the reason.
1. On the other project, add SmartBuildOS System Link Light for this export:
   select SmartBuildOS System Link there, pick the export in **Pending Export**
   and run *Add Companion For Pending Export*.

## What crosses the link

Once the export is registered, SmartBuildOS System Link does the work. This
driver neither reads nor drives the light.

| Direction | What |
| --- | --- |
| Here to the other project | On or off, and the level from 0 to 100, each time the light reports a change |
| Other project to here, with `Control allowed` | On, off, and a level with a ramp time, limited to the operations you listed |
| Not carried | Colour, presets, button and LED behaviour |

On the other project the two values appear as the variables `<Alias>.<Name>_On`
and `<Alias>.<Name>_Level`, where the alias is this project's name on the link.
A command from the other project is checked here every time (the export must
allow control and that operation, commands must not be paused, any schedule on
the export must be open) and is then sent to the light as its own on, off or
ramp command.

## Reading the status

| **Export Status** | Meaning |
| --- | --- |
| `Bind the light to this driver's Light connection in Composer Connections` | Nothing is bound yet |
| `No SmartBuildOS System Link found in this project` | Add SmartBuildOS System Link first |
| `Fill in Export Name` | The light's name gave nothing usable; type a name |
| `Registering … with the bridge…` | Sent, no answer yet. If it stays, SmartBuildOS System Link did not answer |
| `Exported as … (exported)` | The export was created |
| `Exported as … (already exported)` | The same light was already exported under this name; nothing changed |
| `Refused: …` | SmartBuildOS System Link turned it down. `link is not provisioned yet`: finish linking the two projects. A message about variables: the bound device is not a light |
| `Unbound — export removed` | The binding was removed and the export with it |
| `Export … removed` | *Remove Export* was run |
| `Nothing exported yet` | *Remove Export* was run with nothing to remove |

## Programming

None. The driver has no events, conditionals, variables or commands. It has two
actions:

- *Register Export* sends the registration again.
- *Remove Export* stops sharing the light. The binding stays, so the light is
  shared again at the next *Register Export*, the next change to
  **Export Name**, **Export Control** or **Export Operations**, or the next
  start of the driver. To stop for good, unbind the light or delete the driver.

## Examples

### Share a porch light, state only

Bind the porch light, leave **Export Control** on `View only`. The other project
gets a light it can see and program on (for example its *Remote Light On* event)
but cannot switch: a tap there comes back as a refusal.

### Give control later

Set **Export Control** to `Control allowed`, run *Remove Export*, then
*Register Export*. Changing **Export Control** or **Export Operations** on an
export that already exists does not change it: SmartBuildOS System Link answers
`already exported` and keeps the old setting. Removing and registering creates
the export again, so check the linked light on the other project afterwards.

## Limits

- Lights only, and one driver per light. Sensors, temperature, rooms, scenes and
  the other kinds are shared from the **Device Exports** block of SmartBuildOS
  System Link.
- Changing **Export Name** removes the old export and creates a new one. The old
  export's variables become hidden and are never reused, and the light on the
  other project must be linked to the new name.
- Give every export its own name. Registering a name that another export already
  uses, for a different device, replaces that export.
- Rename and remove the export here, not with **Selected Export** on
  SmartBuildOS System Link: this driver registers its own **Export Name** again
  each time it starts.
- Unbinding the light or deleting this driver removes the export.
- Hardware validation: none yet. The binding is a consumer `LIGHT_V2`
  connection; the bound device is the one Control4 reports when the binding
  changes, and SmartBuildOS System Link reads the light's variables from it as
  it does for any export.

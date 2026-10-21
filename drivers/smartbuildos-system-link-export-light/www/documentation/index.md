# SmartBuildOS System Link export light

The Composer Connections way to share a light with the linked project. Add
this driver, then in **Connections** bind the real light (Control4's light
proxy for the dimmer or switch) to its **Light** connection. Name the export in
**Export Name** (prefilled from the light's name), choose **Export Control**,
and the driver registers the export with the System Link bridge in this
project. The bridge does everything else: the same validation, the same watch
on the light's variables and the same shared items as **Export Selected
Device** on the bridge. **Export Status** says what happened, including a
refusal with its reason.

Unbinding the light, or deleting this driver, removes the export. One
instance per exported light. Sensors, temperature, rooms and scenes keep
using the bridge's Device Exports block.

## Hardware validation

None yet. The binding is a consumer `LIGHT_V2` connection; the bound device
id is what Control4 reports in `OnBindingChanged`, and the bridge reads the
light's variables from it as it does for any export.

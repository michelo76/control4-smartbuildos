# Bond Color Light

One instance per Bond full-color light — Firefly bulbs and strips, or any Bond
device with the Color feature. Add it with the Gateway's **Auto Configure Bond
Devices** action (the Gateway picks this driver over the plain Bond Light
automatically when the device can do color), or bind its **Bond Color Light**
connection to the Bond Bridge Gateway manually.

It appears in Navigator as a full color light: dimmer slider, color wheel, and
white color-temperature picker. Requires **OS 3.3.0** (the color conversion
APIs).

## How color maps

- The **color wheel** sends hue and saturation to the Bond; brightness stays on
  the slider — picking a color never yanks the level.
- The **CCT picker** sets the device's native color temperature when it has one
  (clamped to its real range), and degrades to white (saturation zero) on
  devices without the ColorTemp feature.
- White at a known color temperature reports back in CCT mode so the picker
  lands on the right tab.

## Programming

- **Set Color** (Hue 0-359, Saturation 0-100) and **Set Color Temperature**
  (Kelvin) commands.
- Events: **Light On**, **Light Off**, **Color Changed**; variables `LIGHT_ON`,
  `LIGHT_BRIGHTNESS`, `HUE`, `SATURATION`, `COLOR_TEMP`.
- Keypad button links: Toggle / On / Off with LED tracking.

## Troubleshooting

**Gateway Link** narrates the identity handshake. "Waiting for a reply" means
the connection is not bound, or the Gateway has no inventory yet.

# Bond Shade

One instance per Bond motorized shade, awning, or screen. Add it with the
Gateway's **Auto Configure Bond Devices** action, or bind its **Bond Shade**
connection to the Bond Bridge Gateway manually.

It appears in Navigator as a normal shade: open / stop / close buttons, plus a
position slider when the shade supports positions (Bond Bridge Pro, or shades
with two-way protocols). Positionless shades keep the three buttons and drop the
slider — honest controls only.

Awnings and top-down shades are handled by the Bond itself (`open` means what
the Bond Home app says it means); the driver adds no surprises on top.

## Programming

- **Open / Close / Stop / Go To Preset** commands.
- Events: **Opened**, **Closed**; variables `SHADE_OPEN`, `SHADE_LEVEL` (percent
  open, -1 while unknown).

## Notes

After **Go To Preset** or a **Stop** mid-travel, the Bond reports the position
as unknown until the next full open or close — one-way RF has no way to know
where the shade actually stopped. The Position property says so rather than
guessing.

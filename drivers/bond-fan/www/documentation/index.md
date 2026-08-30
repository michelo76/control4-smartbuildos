# Bond Fan

One instance per Bond ceiling fan. Add it with the Gateway's **Auto Configure
Bond Devices** action (which also binds and names it), or add it manually and
bind its **Bond Fan** connection to the Bond Bridge Gateway.

The fan appears in Navigator as a normal fan with discrete speeds. The proxy
offers 6 speed steps; fans with fewer real speeds clamp to their true top speed
automatically. **ON** restores the fan's own last speed (the Bond remembers it).

If the fan has a light, the Gateway creates a separate **Bond Light** connection
for it — the light is its own device, not part of this one.

## Programming

- **Set Direction / Toggle Direction** — seasonal reverse, where the fan
  supports it.
- **Breeze On / Breeze Off** — the Bond's natural-breeze mode.
- **Set Timer** — turn off after N seconds (0 cancels).
- Events: **Fan On**, **Fan Off**, **Speed Changed**; variables `FAN_ON`,
  `FAN_SPEED`, `FAN_DIRECTION`.

## Troubleshooting

**Gateway Link** narrates the identity handshake. "Waiting for a reply" means
the connection is not bound, or the Gateway has no inventory yet — run the
Gateway's **Sync Devices Now**, then **Refresh From Gateway** here.

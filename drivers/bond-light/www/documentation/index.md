# Bond Light

One instance per Bond light — a ceiling fan's light kit, a fireplace light, or a
standalone Bond light/dimmer. Add it with the Gateway's **Auto Configure Bond
Devices** action, or bind its **Bond Light** connection to the Bond Bridge
Gateway manually.

It appears in Navigator as a normal light. Lights whose Bond device supports
brightness dim for real; on/off-only lights snap the slider to 0/100 and behave
as a switch — the driver never pretends a brightness the RF protocol cannot do.

## Programming

- Events: **Light On**, **Light Off**; variables `LIGHT_ON`, `LIGHT_BRIGHTNESS`.
- **Start Dimmer / Stop Dimmer** — the Bond's hold-to-dim cycle, for fans with
  non-stateful dimmers.

## Troubleshooting

**Gateway Link** narrates the identity handshake. "Waiting for a reply" means
the connection is not bound, or the Gateway has no inventory yet.

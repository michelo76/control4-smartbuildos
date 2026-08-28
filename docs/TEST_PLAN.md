# Field test plan

Run after each update pass on a real project. The automated suite covers
logic; this list covers what only hardware can prove.

## Update mechanics (A1)

- [ ] Update Driver on Gateway + one camera IN PLACE; Driver Version
      property shows the new build on both; no re-add needed.
- [ ] New events appear in Composer programming on the UPDATED instance.

## Regression floor (B)

- [ ] All cameras stream in the C4 app (RTSP default).
- [ ] Auto-rename holds; dealer-renamed instance untouched.
- [ ] Motion/person events fire; History shows entries; snapshot URL
      renders in a LAN browser.
- [ ] Event Stream: Connected; pull console power → Reconnecting…, then
      Connected again.

## New in this pass (C)

- [ ] Doorbell: Set Doorbell Message shows on the LCD; Leave Package,
      DND, Reset each work.
- [ ] Fingerprint/NFC (if enrolled): known person fires with the right
      name; unknown fires Unknown.
- [ ] Sensor child: door open/close flips the Contact binding and the
      Security agent sees it; thresholds fire once per crossing.
- [ ] Light child: Light On/Off actually switches the floodlight.
- [ ] Viewport: Show View Temporarily flips the TV and restores.
- [ ] Arm/Disarm from Composer changes Protect's state; arming in the
      Protect app fires Armed in Composer within one poll.
- [ ] Play Siren sounds ONCE (verify no repeat on slow network).
- [ ] curl the webhook URL with the token → Custom Webhook Received;
      without → 404.
- [ ] SmartBuildOS Reporting On → roster reaches the Connector log.

## Abuse cases

- [ ] Revoke the API key → status says "check the API key", not
      "unreachable"; relay serves 502; nothing crash-loops.
- [ ] Reboot the console mid-poll → sync fails visibly, next poll
      recovers, no duplicate events on reconnect.
- [ ] Director restart → identities restore from persist before the
      Gateway answers; no spurious online/offline events.
- [ ] Rapid motion (walk in front of a camera 10×) → events spaced by
      cooldown, variables current.

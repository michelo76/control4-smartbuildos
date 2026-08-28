# One-pass upgrade — working state (delete when pass complete)

Batches (commit after each; keep `make test` green):
- [ ] B1 lib.http PATCH + client expansion (all v7 endpoints)
- [ ] B2 parent: inventory kinds + bindings + PROTECT_GET_DEVICE + PROTECT_CONTROL executor + event routing (sensor/light/hub/identity) + alarm subsystem + sirens/relays/hubs + inbound webhooks + trigger webhook + health + SBOS push + XML (events/vars/props/actions/commands) + init registration
- [ ] B3 camera child: capabilities/gating + cooldowns + doorbell/settings/PTZ commands + known-person events + enriched vars + snapshot-notification command + XML
- [ ] B4 sensor + light + viewport child drivers (+c4zproj+docs stubs)
- [ ] B5 tests: parent/camera extensions + 3 child suites
- [ ] B6 docs (API_MATRIX, EVENT_MATRIX, CURRENT_DRIVER_BEHAVIOR, TEST_PLAN, KNOWN_LIMITATIONS) + build + scorecard in asks doc + memory

Key contracts decided:
- PROTECT_CONTROL {op, ...} child→parent; reply PROTECT_CONTROL_RESULT {op, ok, reason}. Ops: lcd_message(text,duration_s), lcd_dnd, lcd_leave_package, lcd_reset, led(on), mic_volume(v), hdr(mode), video_mode(mode), ptz_goto(slot), ptz_patrol_start(slot), ptz_patrol_stop, light_force(on), light_mode(mode,enable_at), viewer_liveview(liveview_id)
- PROTECT_GET_DEVICE→PROTECT_DEVICE {kind,id,name,mac,state,...extras} for sensor/light/viewer children (cameras keep PROTECT_CAMERA)
- Binding namespaces/classes: cameras/UNIFI_PROTECT_CAMERA (exists), sensors/UNIFI_PROTECT_SENSOR, lights/UNIFI_PROTECT_LIGHT, viewers/UNIFI_PROTECT_VIEWER
- Camera caps params (flat strings): caps="mic,speaker,led,hdr,lcd", detects="person,...", audio_detects=..., video_modes=...
- PROTECT_EVENT kinds add: identity (value=name, known=true/false, method=fingerprint|nfc)
- Parent self events ids: 1 ARMED,2 DISARMED,3 ARM PROFILE CHANGED,4 BREACH DETECTED,5 SIREN STARTED,6 SIREN STOPPED,7 NVR OFFLINE,8 NVR ONLINE,9 DEVICE OFFLINE,10 DEVICE ONLINE,11 CUSTOM WEBHOOK RECEIVED,12 ENTRY OPENED,13 ENTRY CLOSED,14 GLASS BREAK DETECTED,15 SMOKE ALARM DETECTED,16 HUB MOTION DETECTED,17 HUB TAMPER DETECTED,18 HUB BUTTON PRESSED,19 HUB BATTERY LOW,20 HUB RELAY SWITCHED
- Camera child new events ids: 15 KNOWN PERSON DETECTED, 16 UNKNOWN PERSON DETECTED, 17 Snapshot Notification
- Webhook inbound: POST|GET /webhook/<name>?token=<Webhook Token property>; wrong/absent → 404; fires CUSTOM WEBHOOK RECEIVED + LAST_WEBHOOK_NAME/TIME; per-name 2s cooldown; body cap 8KB
- v7 shapes: docs/v7-shapes-reference.txt (lights on/off = isLightForceEnabled; arm = PATCH arm-profiles/settings {armProfileId} + POST enable/disable; siren play {duration 5|10|20|30}; relay activate {state,pulseDuration}; hub trigger {enable,delay,duration}; viewer PATCH {liveview})

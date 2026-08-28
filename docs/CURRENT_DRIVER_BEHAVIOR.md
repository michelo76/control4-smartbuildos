# Current driver behavior — the regression floor

Everything on this list works, is covered by the test suite (13 files),
and must survive every future change. Update this file when behavior is
deliberately changed; never let it drift silently.

## Suite

Five drivers: `unifi-protect` (Gateway), `unifi-protect-camera`,
`unifi-protect-sensor`, `unifi-protect-light`, `unifi-protect-viewport`.
Shared client `src/unifi/protect.lua` (official API only, X-API-KEY,
PATCH-capable). Children hold no credentials; every console exchange runs
through the Gateway over dual-path messaging (bindings + SendToDevice).

## Gateway

- API-key letterbox → encrypted persist; field wiped; no password anywhere.
- Sync (Device Poll Interval): cameras/lights/sensors/chimes required;
  viewers/liveviews/sirens/relays/hubs/arm-profiles optional (degrade).
- Per-kind provider bindings, create-only; Prune action for stale cameras.
- 401/403 → "check the API key"; transport → "unreachable".
- Events websocket, 30s reconnect, Event Stream property; full routing per
  EVENT_MATRIX; unrouted types logged, never fatal.
- Alarm: armMode/profile/breach off the NVR; transition-only events;
  empty-is-unknown; arm/disarm/select commands resolve profile names.
- Sirens/relays/hub outputs: single-shot commands, never retried.
- Snapshot relay (port 47800): /snapshot/<known-id> only; hq=1; 404/405/
  413/502/503 honest; torn down on Forget API Key.
- Inbound webhooks /webhook/<name>?token=…: token or 404, 2s per-name
  cooldown, 8KB cap; Custom Webhook Received + LAST_WEBHOOK_* variables.
- Device Offline/Online transition events + Offline Devices roster.
- SBOS roster push: default Off; change-driven; exact-filename connector
  discovery.
- Diagnostics: Print Inventory/Camera Bindings/Arm Profiles/Security
  Devices; Driver Version written by running code.

## Camera child

- Identity handshake w/ 60s retry + state-push self-heal; auto-rename with
  clobber guard + Rename From Camera; capability flags from featureFlags.
- Streams: RTSP default (rtsps measured black on C4 app), Streams Offered
  quality selector w/ fallback, dynamic streams, 12h cache, KEY echo,
  UIR+RFP double doors.
- Snapshots via gateway relay: GET_SNAPSHOT_URLS + notification
  attachment (hq).
- 17 Composer events; enriched variables (LAST_EVENT trio, per-type
  times, LAST_PERSON); cooldowns space firing, never variables; History
  Agent records per History property (audio alarms + offline = Warning).
- Controls (LCD/LED/mic/HDR/video/PTZ) via single-shot PROTECT_CONTROL;
  local capability refusal; Last Control shows outcomes.
- Send Snapshot Notification = history + event in one command.

## Sensor / light / viewport children

Per the B4 commit: contact+motion bindings and threshold crossings;
light force + motion; live-view set/step/temporary-with-restore
(original restore target survives overlapping shows). All: identity
handshake, auto-rename, online/offline transition events, diagnostics,
Driver Version.

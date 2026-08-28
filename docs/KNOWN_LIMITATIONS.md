# Known limitations — the honest NOs

Verified against the v7.2.105 official spec, not assumed.

- **No recorded-video playback.** Recordings are not on the official API.
  The History timeline + snapshots + the Protect app are the answer.
  (Competitors' playback rides the unofficial cookie API and is labelled
  experimental by their own documentation.)
- **No face names from video.** `smartDetectZone` carries detection TYPES
  only. Known-person identity here is fingerprint/NFC (official), which
  is what our Known Person events are — said plainly in the UI.
- **No license-plate text in events** (yet). The defensive metadata read
  is in place; the day the console sends it, LAST_LICENSE_PLATE fills.
- **No NVR storage/CPU/temperature health.** Not in the official spec;
  no storage forecasting will be faked.
- **No continuous PTZ.** Presets and patrols only (official surface).
- **No talkback.** The endpoint exists; the Control4 intercom
  architecture question is unresolved. Research before any audio hack.
- **Navigator presence for floodlights** (light_v2 proxy) is a follow-up;
  today floodlights are programmable, not tiles.
- ~~Auto-provisioning cannot create driver instances~~ — **corrected
  2026-08-28**: `C4:AddDevice` (official, OS 3.2.0+) does exactly this, and
  the Gateway's Auto Provision Protect Devices action now uses it. The
  earlier claim was wrong; the field pointed it out.
- **RTSP port 7447 is undocumented** by Ubiquiti and could vanish in a
  Protect release; RTSPS stays selectable for that day.

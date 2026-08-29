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

## Licensing (Driver Cloud Phase 5)

- **Pairings made before Phase 5 have no signing secret.** The Agent still
  fetches and serves entitlements over TLS, but the offline cache is
  unsigned (License Cloud says so). One re-pair upgrades the installation
  to signed assertions. Nothing darkens either way.
- **Rotating the platform's master HMAC key re-keys every controller.**
  There is no key-version/rekey path yet, so a rotation forces fleet-wide
  re-pairing. Treat the master key as long-lived; rotate only on suspected
  compromise. A dual-key acceptance path is planned before enforcement.
- **Enforcement is still off.** Statuses are real (AUTHORIZED_*, TRIAL,
  NOT_ENTITLED, CLOUD_VALIDATION_REQUIRED...) and visible in properties,
  but every driver continues to operate under any status. Enforcement
  policies arrive per-driver, per-release (charter D3).

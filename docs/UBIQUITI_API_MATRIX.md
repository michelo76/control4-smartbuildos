# Ubiquiti API matrix

Every endpoint the suite calls. Spec pinned at
`docs/protect-openapi-v7.2.105.json`; request shapes at
`docs/v7-shapes-reference.txt`. All rows are the OFFICIAL Integration API
(`/proxy/protect/integration`, header `X-API-KEY`). Nothing undocumented is
called anywhere in the suite.

Fallback legend: **degrade** = optional sync step, lands empty with the
feature reporting itself unsupported; **error** = surfaced to the caller's
status/result; **required** = a failure fails the operation visibly.

| Function | Endpoint | Min Protect | Used by | Fallback |
| --- | --- | --- | --- | --- |
| Connection test | GET /v1/meta/info | 5.3 | gateway testConnection | required |
| NVR + alarm state | GET /v1/nvrs | 5.3 (arm fields 7.x) | every sync | error (alarm fields absent → no alarm events) |
| Camera list + capabilities | GET /v1/cameras | 5.3 | sync | required |
| Camera settings | PATCH /v1/cameras/{id} | 5.3 (lcd 7.x-ish) | PROTECT_CONTROL (lcd/led/mic/hdr/video) | error → CONTROL_RESULT |
| Snapshot | GET /v1/cameras/{id}/snapshot | 5.3 | snapshot relay | 502 to the relay client |
| RTSPS read | GET /v1/cameras/{id}/rtsps-stream | 5.3 | stream answers | error |
| RTSPS create | POST /v1/cameras/{id}/rtsps-stream | 5.3 | stream answers (missing qualities only) | error |
| PTZ preset / patrol | POST /v1/cameras/{id}/ptz/goto·patrol | 5.3 | PROTECT_CONTROL | error → CONTROL_RESULT |
| Lights | GET /v1/lights, PATCH /v1/lights/{id} | 5.3 | sync; light child ops | degrade / error |
| Sensors | GET /v1/sensors | 5.3 | sync | required |
| Chimes | GET /v1/chimes | 5.3 | sync (counts only) | required |
| Viewers | GET /v1/viewers, PATCH /v1/viewers/{id} | 6.x | sync; viewport ops | degrade / error |
| Live views | GET /v1/liveviews | 6.x | sync (name↔id resolution) | degrade |
| Events websocket | GET /v1/subscribe/events | 5.3 (vocab grows per version) | live event engine | reconnect w/ 30s backoff; poll continues |
| Arm profiles | GET /v1/arm-profiles | 7.x | sync | degrade |
| Select profile | PATCH /v1/arm-profiles/settings | 7.x | Arm/Select commands | error, said in log |
| Arm / disarm | POST /v1/arm-profiles/enable·disable | 7.x | Arm/Disarm commands | error, said in log |
| Sirens | GET /v1/sirens; POST …/play·stop·test-sound | 7.x | sync; siren commands | degrade / error, NEVER retried |
| Relays | GET /v1/relays; POST …/outputs/{o}/activate | 7.x | sync; Activate Relay | degrade / error, NEVER retried |
| Alarm hubs | GET /v1/alarm-hubs; POST …/outputs/{o}/trigger | 7.x | sync; Trigger Hub Output | degrade / error, NEVER retried |
| Identity store | GET /v1/ulp-users | 7.x | fingerprint/NFC resolution (10-min cache) | unknown-person path |
| Alarm Manager trigger | POST /v1/alarm-manager/webhook/{id} | 6.x | Trigger Protect Webhook | error, said in log |

Not called, deliberately: talkback-session, disable-mic-permanently,
files/{fileType}, users, pos transactions, speakers (inventory display
only when present), fobs/bridges/link-stations (absent from spec use
cases so far). See KNOWN_LIMITATIONS for what the official API cannot do.

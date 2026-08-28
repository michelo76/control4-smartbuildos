# Event matrix

Every event type the v7.2.105 `/v1/subscribe/events` websocket can deliver,
and where the gateway routes it. Frames are plain JSON
`{ type: add|update, item: {...} }`; phase = "end" iff `item.end` is set.

| Protect event type | Route | Lands as |
| --- | --- | --- |
| motion | camera child | Motion Detected / Motion Ended (+MOTION_DETECTED, cooldown-spaced) |
| ring | camera child | Doorbell Ring (+LAST_RING) |
| smartDetectZone | camera child | Person/Vehicle/Package/Animal/License Plate/Face Detected per type (+LAST_*_TIME, cooldown per type) |
| smartDetectLine | camera child | Line Crossed |
| smartDetectLoiterZone | camera child | Loitering Detected |
| smartAudioDetect | camera child | Audio Alarm Detected (+LAST_AUDIO_TYPE), history Warning |
| fingerprintIdentified | camera child via ulp-users | Known/Unknown Person Detected (+LAST_PERSON) |
| nfcCardScanned | camera child via ulp-users | Known/Unknown Person Detected |
| sensorMotion | sensor child | Motion Detected + Motion contact CLOSED |
| sensorOpened / sensorClosed | sensor child | Contact Opened/Closed + Contact binding |
| sensorAlarm | sensor child | Alarm Detected |
| sensorExtremeValues | sensor child | reading update → threshold events on crossings |
| sensorBatteryLow / sensorSmokeBatteryLow | sensor child | Battery Low |
| sensorWaterLeak | sensor child | Water Leak Detected |
| sensorTamper | sensor child | Tamper Detected |
| sensorButtonPressed | sensor child | Button Pressed |
| sensorCoFault | sensor child | CO Fault |
| sensorSmokeTest | sensor child | (routed; no event v1) |
| lightMotion | light child | Motion Detected (+LAST_MOTION) |
| alarmHubEntryOpened/Closed | gateway event | Entry Opened / Entry Closed |
| alarmHubGlassBreak | gateway event | Glass Break Detected |
| alarmHubSmoke | gateway event | Smoke Alarm Detected |
| alarmHubMotion | gateway event | Hub Motion Detected |
| alarmHubTamper / alarmHubDeviceTamper | gateway event | Hub Tamper Detected |
| alarmHubButtonPress | gateway event | Hub Button Pressed |
| alarmHubBatteryLow | gateway event | Hub Battery Low |
| alarmHubRelaySwitched | gateway event | Hub Relay Switched |
| alarmHubBatteryConnected | dropped (restoration; log only) | — |
| cameraDigitalInputChanged | dropped v1 (log) | — |
| relayInputChanged | dropped v1 (log) | — |

Alarm state (Armed/Disarmed/Arm Profile Changed/Breach Detected) and
Device Offline/Online are POLL-derived off /v1/nvrs and the inventory —
not websocket events — refreshed each Device Poll Interval.

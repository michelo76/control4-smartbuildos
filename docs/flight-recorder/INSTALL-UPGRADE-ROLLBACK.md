# Flight Recorder — installation, upgrade, rollback

## Order of operations (new site)

1. **Platform first.** Apply `supabase/migrations/20261022120000_flight_recorder.sql`
   (web repo) and deploy the web branch. The migration adds the two command
   verbs, the tables, the bucket and the `SBOS_FLIGHT_RECORDER` catalogue row.
   An Agent that sends `modules` / `event_pipeline` to an older platform is
   harmless (unknown keys are dropped; `/events` 404s → the Agent backs off and
   keeps its queue).
2. **Agent.** Install the `smartbuildos.c4z` built from this branch (Composer
   Pro → Agents, per PR #31; an older project-driver instance is removed from
   System Design first; Pairing Backup restores the pairing). Confirm the
   heartbeat shows `capabilities` containing `modules_v1`.
3. **Flight Recorder driver.** Add `smartbuildos-flight-recorder.c4z` in
   Composer (System Design, Utility). One per project. Properties paint
   "Agent device N — registered" and Agent Connection `ready` once the Agent
   answered; the Agent's log says `module registered: flight_recorder@<id>`.
4. **Sources.** System Studio → Activity → Flight Recorder → Recorder
   settings: pick sources or a template, Save revision. The next heartbeat
   delivers it; "applied" updates when the recorder reports back.
5. **Programming.** Add trace commands to routines (COMPOSER-PROGRAMMING.md).

## Upgrade

- Agent in place (Composer Update Driver): modules get `SBOS_MODULE_AGENT_HELLO`
  and re-register; the event journal is checkpointed on destroy and restored
  on start. No re-pair.
- Flight Recorder in place: configuration (last valid), paused flag and the
  persisted sequence survive; listeners are rebuilt from the configuration at
  LateInit; open traces end as `interrupted` (reason "driver removed or
  reloaded") and are visible as such.

## Rollback

- Driver: install the previous `.c4z` (Composer Update Driver). The Agent
  tolerates a missing Flight Recorder; an older Agent ignores module frames
  (the module reads `waiting_for_agent`).
- Platform: `docs/flight-recorder/ROLLBACK-20261022120000.sql` (web repo).
  Queued `MODULE_COMMAND` rows must be deleted first; snapshot objects must be
  removed before the bucket.

## Build (driver repo)

```
cd ~/Documents/Codex/control4-smartbuildos-flight-recorder
make test && make build
```

`make build` installs EVERY `.c4z` into `~/Documents/Control4/Drivers`; the
bench branch's builds there are overwritten by this branch's. Rebuild the bench
branch afterwards if you need its exact binaries; `smartbuildos-flight-recorder.c4z`
has no bench equivalent and stays.

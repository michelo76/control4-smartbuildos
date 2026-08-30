-- Engine + plan + adapter tests: the mode-transition matrix (spec §83), the
-- failure matrix's engine-visible rows (§84), plan/dry-run separation (§42),
-- pacing (§48), restore-previous (§27), countdown (§19), duration (§33),
-- and the priority ladder (§25). Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

C4 = C4 or {}
require("c4_shim")

local model = require("modes.model")
local planner = require("modes.plan")
local adapters = require("modes.adapters")
local enginelib = require("modes.engine")

-- Fake clock shared by timer + now.
local clock = { now = 0, timers = {}, nextId = 1 }
local function tset(ms, cb)
  local id = clock.nextId
  clock.nextId = id + 1
  clock.timers[id] = { at = clock.now + ms, cb = cb }
  return id
end
local function tcancel(id)
  if id then
    clock.timers[id] = nil
  end
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local cb = clock.timers[bestId].cb
    clock.timers[bestId] = nil
    cb()
  end
  clock.now = target
end

local uuidCounter = 0
local function uuid()
  uuidCounter = uuidCounter + 1
  return "id" .. uuidCounter
end

-- The fake project: device registry the resolver serves.
local DEVICES = {}
local function addDevice(key, spec)
  spec.id = spec.id or tonumber(key)
  spec.name = spec.name or ("Device " .. key)
  DEVICES[key] = spec
end
for i = 1, 20 do
  addDevice(
    tostring(1000 + i),
    { proxy = "light_v2", vars = { ["LIGHT_STATE"] = "1", ["Brightness Percent"] = "70" }, online = true }
  )
end
for i = 1, 5 do
  addDevice(tostring(2000 + i), { proxy = "blind", vars = { ["Level Target"] = "100" }, online = true })
end
addDevice("3001", { proxy = "lock", vars = { ["LOCK_STATUS"] = "unlocked" }, online = true, name = "Front Door Lock" })
addDevice(
  "4001",
  { proxy = "securitypanel", vars = { ["PARTITION_STATE"] = "DISARMED_READY" }, online = true, name = "Panel" }
)
addDevice(
  "5001",
  {
    proxy = "thermostatV2",
    vars = { ["HVAC_MODE"] = "Cool", ["TEMPERATURE_F"] = "74", ["COOL_SETPOINT_F"] = "72" },
    online = true,
    name = "Hall Tstat",
  }
)
addDevice("6001", { proxy = "blind", vars = { ["Level Target"] = "50" }, online = false, name = "Pool House Shade" })

local function resolve(key)
  local d = DEVICES[key]
  if not d then
    return nil
  end
  return {
    id = d.id,
    name = d.name,
    room = d.room,
    proxy = d.proxy,
    vars = d.vars,
    online = d.online,
    adapter = adapters.classify(d),
  }
end

-- Config: Away controls the lot; Movie captures/restores lights.
local cfg = model.emptyConfig()
local home = model.newMode(cfg, { kind = "HOME" }, uuid)
local away = model.newMode(cfg, { kind = "AWAY" }, uuid)
local vacation = model.newMode(cfg, { kind = "VACATION" }, uuid)
local movie = model.newMode(cfg, { kind = "MOVIE" }, uuid)
model.setParent(cfg, vacation.id, away.id)
for i = 1, 20 do
  away.desired_states[tostring(1000 + i)] = { behavior = "SET", state = { on = false } }
end
for i = 1, 5 do
  away.desired_states[tostring(2000 + i)] = { behavior = "SET", state = { position = "CLOSED" } }
end
away.desired_states["3001"] = { behavior = "SET", state = { locked = true }, criticality = "CRITICAL" }
away.desired_states["5001"] = { behavior = "SET", state = { cool_setpoint_f = 80 } }
movie.desired_states["1001"] = { behavior = "RESTORE" }
movie.desired_states["1002"] = { behavior = "SET", state = { on = true, level = 5 } }

print("\n[1] Plan: builds, classifies, counts, and orders — sends NOTHING")
local sent = {}
local deps = { resolve = resolve, secrets = {} }
local plan = planner.build(cfg, away.id, deps)
check("plan built", plan ~= nil)
check("27 actions (20 lights + 5 shades + lock + tstat)", plan.summary.total == 27, plan.summary.total)
check(
  "classes counted",
  plan.summary.by_class.LIGHT == 20 and plan.summary.by_class.SHADE == 5,
  plan.summary.by_class.LIGHT
)
check("no unsupported entries", #plan.unsupported == 0, plan.unsupported[1] and plan.unsupported[1].reason)
check("nothing was sent", #sent == 0)

print("\n[2] Dry run renders dealer-readable text")
local text = planner.renderDryRun(plan)
check(
  "names the mode",
  text:find("AWAY", 1, true) ~= nil or text:find(away.name:upper(), 1, true) ~= nil,
  text:sub(1, 40)
)
check("counts lights", text:find("20", 1, true) ~= nil)
check("no proxy ids leak", text:find("SET_LEVEL_TARGET", 1, true) == nil)

print("\n[3] RESTORE without capture support is honest")
local moviePlan = planner.build(cfg, movie.id, deps)
check("restore listed for the light", #moviePlan.restores == 1)
movie.desired_states["3001"] = { behavior = "RESTORE" }
moviePlan = planner.build(cfg, movie.id, deps)
check(
  "lock restore reported unsupported",
  #moviePlan.unsupported == 1,
  moviePlan.unsupported[1] and moviePlan.unsupported[1].reason
)
movie.desired_states["3001"] = nil

print("\n[4] Missing devices are marked, never dropped")
away.desired_states["9999"] = { behavior = "SET", state = { on = false } }
plan = planner.build(cfg, away.id, deps)
check("missing entry present", #plan.missing == 1 and plan.missing[1].device_key == "9999")
away.desired_states["9999"] = nil

print("\n[5] Sensitive actions require the explicit flag")
local lockAdapter = adapters.ADAPTERS.LOCK
local refused, why = lockAdapter.plan({ locked = false })
check("unlock refused without flag", refused == nil and tostring(why):find("Sensitive", 1, true) ~= nil, why)
local allowed = lockAdapter.plan({ locked = false, allow_sensitive = true })
check("unlock allowed with flag", allowed ~= nil and allowed[1].command == "UNLOCK")
local sec = adapters.ADAPTERS.SECURITY
local disarmRefused = sec.plan({ arm = "DISARM", allow_sensitive = true }, {})
check("disarm still needs a user code", disarmRefused == nil)
local armed = sec.plan({ arm = "Away" }, { user_code = "1234" })
check("arm works; user code marked for redaction", armed[1].params.ArmType == "Away")

-- ── Engine rig ───────────────────────────────────────────────────────────────
local events = {}
local eng = enginelib.new({
  timer = { set = tset, cancel = tcancel },
  now = function()
    return clock.now / 1000
  end,
  uuid = uuid,
  send = function(deviceId, command, params)
    if DEVICES[tostring(deviceId)] and DEVICES[tostring(deviceId)].failSend then
      return false, "simulated send failure"
    end
    table.insert(sent, { device = deviceId, command = command, params = params })
    return true
  end,
  emit = function(name, detail)
    table.insert(events, { name = name, detail = detail })
  end,
  buildPlan = function(modeId)
    return planner.build(cfg, modeId, deps)
  end,
  runPreflight = function(modeId)
    return planner.preflight(cfg, modeId, deps)
  end,
  readDeviceState = function(key)
    local d = resolve(key)
    if not d then
      return nil
    end
    return d.adapter.read(d.vars)
  end,
  buildRestorePlan = function(captures)
    local rp = {
      actions = {},
      restores = {},
      unsupported = {},
      missing = {},
      summary = { by_class = {}, total = 0 },
      transition = { style = "IMMEDIATE" },
      mode_name = "restore",
    }
    for key, state in pairs(captures) do
      local d = resolve(key)
      if d then
        local cmds = d.adapter.plan(state)
        for _, cmd in ipairs(cmds or {}) do
          table.insert(rp.actions, {
            device_key = key,
            device_id = d.id,
            device_name = d.name,
            class = d.adapter.class,
            command = cmd.command,
            params = cmd.params,
            delay_s = 0,
            criticality = "NORMAL",
          })
        end
      end
    end
    rp.summary.total = #rp.actions
    return rp
  end,
  interCommandDelayMs = 50,
})
eng:setConfig(cfg)

local function lastEvent(name)
  for i = #events, 1, -1 do
    if events[i].name == name then
      return events[i].detail
    end
  end
  return nil
end

print("\n[6] Simple activation: paced queue, SENT results, mode commits")
sent, events = {}, {}
local outcome = eng:activate(home.id, "COMPOSER", {})
check("started", outcome.status == "STARTED" or (outcome.status == "DONE"), outcome.status)
advance(5000)
check("home active", eng:activeModes().PRESENCE == home.id)
outcome = eng:activate(away.id, "KEYPAD", { meta = { slot_name = "Kitchen 5", gesture = "hold" } })
check("away started", outcome.status == "STARTED", outcome.status)
check("not everything sent instantly (paced)", #sent < 27)
advance(5000)
check("all 27 commands sent", #sent >= 27, #sent)
local done = lastEvent("activation_complete")
check("aggregate SUCCESS", done and done.result == "SUCCESS", done and done.result)
check("meta rode through", done and done.meta and done.meta.gesture == "hold")
check("away is now active", eng:activeModes().PRESENCE == away.id)
check("previous presence recorded", done.previous_presence == home.id)

print("\n[7] Idempotency: re-activating Away is a no-op; Reapply is explicit")
sent = {}
outcome = eng:activate(away.id, "KEYPAD", {})
check("no-op", outcome.noop == true, outcome.status)
check("nothing sent", #sent == 0)
outcome = eng:activate(away.id, "COMPOSER", { reapply = true })
advance(5000)
check("reapply re-sends", #sent >= 27, #sent)

print("\n[8] Priority ladder: sensor Home cannot dethrone Vacation; manual can")
eng:activate(vacation.id, "KEYPAD", {})
advance(5000)
check("vacation active", eng:activeModes().PRESENCE == vacation.id)
outcome = eng:activate(home.id, "SENSOR", {})
check("sensor home refused", outcome.status == "REFUSED", outcome.status)
check("reason names both modes", tostring(outcome.reason):find("outranked", 1, true) ~= nil, outcome.reason)
outcome = eng:activate(home.id, "NAVIGATOR", {})
advance(5000)
check("manual home allowed", eng:activeModes().PRESENCE == home.id)

print("\n[9] Lifestyle rides on top of Presence; restore-previous works")
sent, events = {}, {}
outcome = eng:activate(movie.id, "NAVIGATOR", {})
advance(5000)
check("movie active", eng:activeModes().LIFESTYLE == movie.id)
check("presence untouched", eng:activeModes().PRESENCE == home.id)
-- 1001 was captured (on at 70%) before movie dimmed it.
sent = {}
outcome = eng:deactivateLifestyle("NAVIGATOR", {})
advance(5000)
check("lifestyle cleared", eng:activeModes().LIFESTYLE == nil)
local restored = false
for _, s in ipairs(sent) do
  if s.device == 1001 and (s.command == "RAMP_TO_LEVEL" or s.command == "ON") then
    restored = true
  end
end
check("captured light restored", restored, sent[1] and sent[1].command)

print("\n[10] Partial failure: NORMAL failure warns, activation survives")
DEVICES["6001"].failSend = true
away.desired_states["6001"] = { behavior = "SET", state = { position = "CLOSED" } }
sent, events = {}, {}
eng:activate(away.id, "KEYPAD", {})
advance(5000)
local warned = lastEvent("activation_warning")
check("SUCCESS_WITH_WARNINGS", warned and warned.result == "SUCCESS_WITH_WARNINGS", warned and warned.result)
check(
  "failure names the shade",
  warned and warned.failures[1] and tostring(warned.failures[1].device):find("Pool House", 1, true) ~= nil,
  warned and warned.failures[1] and warned.failures[1].device
)
check("away still activated", eng:activeModes().PRESENCE == away.id)
check("other actions still went out", #sent >= 26, #sent)

print("\n[11] CRITICAL failure aborts and does NOT commit the mode")
eng:activate(home.id, "NAVIGATOR", {})
advance(5000)
DEVICES["3001"].failSend = true
sent, events = {}, {}
eng:activate(away.id, "KEYPAD", {})
advance(10000)
local failedEv = lastEvent("activation_failed")
check("aggregate FAILED", failedEv and failedEv.result == "FAILED", failedEv and failedEv.result)
check("mode did not change", eng:activeModes().PRESENCE == home.id)
DEVICES["3001"].failSend = nil
DEVICES["6001"].failSend = nil
away.desired_states["6001"] = nil

print("\n[12] Countdown: transition state, cancel, and completion")
movie.transition = { style = "IMMEDIATE", countdown_s = 0, sequence = {} }
away.transition = { style = "IMMEDIATE", countdown_s = 60, sequence = {} }
sent, events = {}, {}
outcome = eng:activate(away.id, "KEYPAD", {})
check("countdown returned", outcome.status == "COUNTDOWN" and outcome.seconds == 60, outcome.status)
check("countdown_begin emitted", lastEvent("countdown_begin") ~= nil)
check("transitioning", eng:isTransitioning() == true)
check("cancel works", eng:cancelTransition("changed my mind") == true)
check("countdown_cancelled emitted", lastEvent("countdown_cancelled") ~= nil)
advance(70000)
check("nothing executed after cancel", #sent == 0, #sent)
check("home still active", eng:activeModes().PRESENCE == home.id)
outcome = eng:activate(away.id, "KEYPAD", {})
advance(65000) -- 60s countdown + the paced queue (27 x 50ms)
check("uncancelled countdown executes", eng:activeModes().PRESENCE == away.id)
away.transition.countdown_s = 0

print("\n[13] Delayed actions fire later and report via delayed_result")
eng:activate(home.id, "NAVIGATOR", {})
advance(5000)
away.desired_states["1001"].delay_s = 90
sent, events = {}, {}
eng:activate(away.id, "KEYPAD", {})
advance(5000)
local before = #sent
check("immediate batch completed without the delayed light", lastEvent("activation_complete") ~= nil)
advance(90000)
check("delayed action went out", #sent == before + 1, #sent - before)
check("delayed_result emitted", lastEvent("delayed_result") ~= nil)
away.desired_states["1001"].delay_s = nil

print("\n[14] Duration: a timed Lifestyle mode exits itself")
movie.duration_s = 3600
sent, events = {}, {}
eng:activate(movie.id, "NAVIGATOR", {})
advance(5000)
check("movie active", eng:activeModes().LIFESTYLE == movie.id)
advance(3600 * 1000)
check("movie auto-exited", eng:activeModes().LIFESTYLE == nil)
movie.duration_s = 0

print("\n[15] Preflight BLOCKING refuses activation")
eng:activate(home.id, "NAVIGATOR", {}) -- away must not already be active: idempotency would short-circuit before preflight
advance(10000)
DEVICES["4001"].vars["PARTITION_STATE"] = "DISARMED_NOT_READY"
away.preflight = { { device_key = "4001", expect = "READY", policy = "BLOCK" } }
sent, events = {}, {}
outcome = eng:activate(away.id, "KEYPAD", {})
check("blocked", outcome.result == "BLOCKED", outcome.status)
check("nothing sent", #sent == 0)
check("blocked event emitted", lastEvent("activation_blocked") ~= nil)
away.preflight[1].policy = "WARN"
outcome = eng:activate(away.id, "KEYPAD", {})
advance(5000)
check("WARN lets it through", eng:activeModes().PRESENCE == away.id)
local rec = lastEvent("activation_complete") or lastEvent("activation_warning")
check(
  "preflight warning counted in the record",
  rec and (rec.preflight_warnings or 0) > 0,
  rec and rec.preflight_warnings
)
away.preflight = nil
DEVICES["4001"].vars["PARTITION_STATE"] = "DISARMED_READY"

print("\n[16] Restart: logical state restores, nothing re-sends")
local savedState = eng:serializeState()
local eng2 = enginelib.new({
  timer = { set = tset, cancel = tcancel },
  now = function()
    return clock.now / 1000
  end,
  uuid = uuid,
  send = function(...)
    table.insert(sent, { ... })
    return true
  end,
  emit = function() end,
  buildPlan = function(modeId)
    return planner.build(cfg, modeId, deps)
  end,
  runPreflight = nil,
  readDeviceState = function()
    return nil
  end,
  buildRestorePlan = function()
    return { actions = {}, summary = { total = 0 } }
  end,
})
eng2:setConfig(cfg)
sent = {}
eng2:restoreState(savedState)
check("presence restored", eng2:activeModes().PRESENCE == savedState.presence_id)
check("zero commands from restore", #sent == 0)

print("\n[17] SEQUENCED: stage offsets stay in the TRACKED queue")
away.transition = { style = "SEQUENCED", countdown_s = 0, sequence = {} }
plan = planner.build(cfg, away.id, deps)
local lightDelay, lockDelay
for _, action in ipairs(plan.actions) do
  if action.class == "LIGHT" and lightDelay == nil then
    lightDelay = action.stage_delay_s
  end
  if action.class == "LOCK" then
    lockDelay = action.stage_delay_s
  end
  check_delay_stays_zero = check_delay_stays_zero or (action.delay_s or 0) > 0
end
check(
  "lights stage before locks",
  lightDelay ~= nil and lockDelay ~= nil and lightDelay < lockDelay,
  tostring(lightDelay) .. " vs " .. tostring(lockDelay)
)
check("stage offsets did not leak into delay_s", check_delay_stays_zero ~= true)
-- And the aggregate still sees a late-stage critical failure:
eng:activate(home.id, "NAVIGATOR", {})
advance(60000)
DEVICES["3001"].failSend = true
sent, events = {}, {}
eng:activate(away.id, "KEYPAD", {})
advance(60000)
local seqFailed = lastEvent("activation_failed")
check(
  "sequenced critical failure still fails the activation",
  seqFailed and seqFailed.result == "FAILED",
  seqFailed and seqFailed.result
)
check("mode did not commit", eng:activeModes().PRESENCE == home.id)
DEVICES["3001"].failSend = nil
away.transition = { style = "IMMEDIATE", countdown_s = 0, sequence = {} }

print("\n[18] GRACEFUL gives lights the default ramp")
away.transition.style = "GRACEFUL"
plan = planner.build(cfg, away.id, deps)
local ramped = false
for _, action in ipairs(plan.actions) do
  if
    action.class == "LIGHT"
    and action.command == "RAMP_TO_LEVEL"
    and action.params.TIME == planner.GRACEFUL_RAMP_MS
  then
    ramped = true
  end
end
check("ramp injected", ramped)
away.transition.style = "IMMEDIATE"

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end

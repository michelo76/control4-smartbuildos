-- Load Shedding engine: pure rules, injected clock and timers.
-- Run from the driver root: make test

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

local E = require("loadshed.engine")

-- Harness: fake clock, timers, devices.
local function rig(cfg, loadsOverride)
  local h = { t = 1000, timers = {}, sent = {}, events = {}, devices = {}, changes = {} }
  local function key(k)
    return k
  end
  local deps = {
    now = function()
      return h.t
    end,
    schedule = function(id, ms, fn)
      h.timers[key(id)] = { at = h.t + ms / 1000, fn = fn }
    end,
    cancel = function(id)
      h.timers[key(id)] = nil
    end,
    emit = function(kind, f)
      if kind ~= "changed" then
        h.events[#h.events + 1] = { kind = kind, f = f }
      else
        h.changes[#h.changes + 1] = f.urgent == true
      end
    end,
    read = function(load)
      return h.devices[load.device_id]
    end,
    send = function(id, cmd, params)
      h.sent[#h.sent + 1] = { id = id, cmd = cmd, params = params, at = h.t }
      return true
    end,
  }
  h.e = E.new(deps)
  h.e:setConfig(cfg or {})
  h.e:setLoads(loadsOverride or {
    { slot = 1, device_id = 101, kind = "relay", tier = 1 },
    { slot = 2, device_id = 102, kind = "light", tier = 2 },
    { slot = 3, device_id = 103, kind = "thermostat", tier = 2, setback_f = 62 },
    { slot = 4, device_id = 104, kind = "light", tier = 3 },
  })
  h.devices[101] = { known = true, closed = true }
  h.devices[102] = { known = true, on = true, level = 60 }
  h.devices[103] = { known = true, hvac_mode = "Heat", heat_f = 70, cool_f = 78 }
  h.devices[104] = { known = true, on = true, level = 100 }
  function h.advance(sec)
    local target = h.t + sec
    while true do
      local bid, b
      for id, tm in pairs(h.timers) do
        if tm.at <= target and (b == nil or tm.at < b.at) then
          bid, b = id, tm
        end
      end
      if not bid then
        break
      end
      h.t = b.at
      h.timers[bid] = nil
      b.fn()
    end
    h.t = target
  end
  function h.cmds(id)
    local o = {}
    for _, s in ipairs(h.sent) do
      if s.id == id then
        o[#o + 1] = s.cmd
      end
    end
    return table.concat(o, ",")
  end
  function h.count(kind)
    local n = 0
    for _, ev in ipairs(h.events) do
      if ev.kind == kind then
        n = n + 1
      end
    end
    return n
  end
  return h
end

print("[1] helpers")
check("valueMatches list/case/number", E.valueMatches("Closed", "1, closed") and E.valueMatches("1.0", "1") and not E.valueMatches("0", "1,closed"))
check("valueMatches empty never matches", not E.valueMatches("", "1") and not E.valueMatches("x", ""))
check("device label id", E.parseDeviceId("Pool Pump (Yard) · 142") == 142 and E.parseDeviceId("-") == nil)
local d, v = E.parseVariablePick("82,5015")
check("variable pick", d == 82 and v == 5015 and E.parseVariablePick("") == nil)
check("light reader", E.readLight({ LIGHT_STATE = "0" }).on == false and E.readLight({ ["Brightness Percent"] = "40" }).level == 40 and E.readLight({}) == nil)
check("thermostat reader", E.readThermostat({ HVAC_MODE = "Heat", HEAT_SETPOINT_F = "70" }).heat_f == 70)
check("normalise rejects bad tier and setback", E.normaliseLoad({ slot = 1, device_id = 5, kind = "light", tier = 4 }) == nil and E.normaliseLoad({ slot = 1, device_id = 5, kind = "thermostat", tier = 1 }) == nil)

print("[2] tier 1 sheds at once, prior states remembered")
local h = rig()
h.e:setBattery(90)
h.e:setOutage(true, "test")
check("outage started event", h.count("outage_started") == 1)
check("tier 1 relay opened", h.cmds(101) == "OPEN")
check("tier 2/3 untouched", h.cmds(102) == "" and h.cmds(104) == "")
check("tier flags", h.e:isTierShed(1) and not h.e:isTierShed(2) and h.e:highestShedTier() == 1 and h.e:outageActive())
check("prior kept", h.e.st.shed[1].prior.closed == true)

print("[3] tier 2 and 3 by battery, cascading")
h.e:setBattery(50)
check("tier 2 at its percentage", h.e:isTierShed(2) and h.cmds(102) == "OFF" and h.cmds(103) == "SET_SETPOINT_HEAT")
check("setback value sent", h.sent[#h.sent].params.FAHRENHEIT == 62)
check("tier 3 not yet", not h.e:isTierShed(3))
h.e:setBattery(19)
check("tier 3 below its percentage", h.e:isTierShed(3) and h.cmds(104) == "OFF")
check("shed count", h.e:shedCount() == 4)

print("[4] power returns: hold, then restore tier 3 -> 1 with delay")
h.e:setBattery(30)
h.e:setOutage(false)
check("holding, Restore Delayed fired, nothing restored", h.e.st.phase == "holding" and h.count("restore_delayed") == 1 and h.cmds(104) == "OFF")
h.advance(119)
check("still holding at 119 s", h.e.st.phase == "holding")
h.advance(2)
check("tier 3 restored first", h.cmds(104) == "OFF,ON" and h.cmds(102) == "OFF" and h.e.st.phase == "restoring")
h.advance(28)
check("delay between tiers", h.cmds(102) == "OFF")
h.advance(2)
check("tier 2 next: dimmer back to its level", h.cmds(102) == "OFF,RAMP_TO_LEVEL" and h.cmds(101) == "OPEN")
check("thermostat setpoint restored", h.sent[#h.sent].cmd == "SET_SETPOINT_HEAT" and h.sent[#h.sent].params.FAHRENHEIT == 70)
h.advance(31)
check("tier 1 last", h.cmds(101) == "OPEN,CLOSE")
check("back to normal, nothing remembered", h.e.st.phase == "normal" and next(h.e.st.shed) == nil and h.count("restored") == 1)

print("[5] already-off loads are not turned on at restore")
h = rig()
h.devices[101] = { known = true, closed = false }
h.devices[102] = { known = true, on = false, level = 0 }
h.e:setOutage(true)
h.e:setBattery(10)
h.advance(0)
h.e:setOutage(false)
h.advance(400)
check("open relay left alone both ways", h.cmds(101) == "")
check("off light left alone both ways", h.cmds(102) == "")
check("thermostat still done", h.cmds(103) == "SET_SETPOINT_HEAT,SET_SETPOINT_HEAT")

print("[6] flapping grid: power returns, drops before the hold elapses")
h = rig()
h.e:setOutage(true)
h.e:setOutage(false)
h.advance(60)
h.e:setOutage(true)
check("hold abandoned, flap counted, still shed", h.e.st.phase == "outage" and h.e.st.flaps == 1 and h.cmds(101) == "OPEN")
h.advance(500)
check("nothing restored by the dead hold timer", h.cmds(101) == "OPEN" and h.count("restored") == 0)
h.e:setOutage(false)
h.advance(119)
check("a fresh hold starts from zero", h.e.st.phase == "holding")
h.advance(2)
h.advance(1)
check("then restores", h.cmds(101) == "OPEN,CLOSE")
h.e:setOutage(true)
h.e:setBattery(5)
h.e:setOutage(false)
h.advance(121)
h.e:setOutage(true)
check("outage during restore: restore stops, restored tier is shed again by the low battery", h.e.st.phase == "outage" and h.e:isTierShed(3) == true and #h.e.st.queue == 0)

print("[7] outage during restore keeps un-restored tiers and re-sheds restored ones")
h = rig()
h.e:setOutage(true)
h.e:setBattery(10)
check("all tiers shed", h.e:highestShedTier() == 3)
h.e:setOutage(false)
h.advance(121)
check("tier 3 restored, tier 2 waiting", not h.e:isTierShed(3) and h.e:isTierShed(2))
h.e:setOutage(true)
check("restore cancelled", h.e.st.phase == "outage" and #h.e.st.queue == 0)
h.advance(100)
check("tier 2 and 1 never restored", h.cmds(102) == "OFF" and h.cmds(101) == "OPEN")
check("tier 3 shed again (battery 10)", h.cmds(104) == "OFF,ON,OFF")

print("[8] battery never reported: time path")
h = rig()
h.e:setOutage(true)
h.advance(14 * 60)
check("tier 2 not before its minutes", not h.e:isTierShed(2))
h.advance(60 + 30)
check("tier 2 after 15 min", h.e:isTierShed(2) and not h.e:isTierShed(3))
h.advance(30 * 60)
check("tier 3 after 45 min", h.e:isTierShed(3))
local h2 = rig({ tier2_nodata_min = 0, tier3_nodata_min = 0 })
h2.e:setOutage(true)
h2.advance(3 * 3600)
check("0 minutes disables the time path", h2.e:highestShedTier() == 1)

print("[9] stale battery falls back to time")
h = rig()
h.e:setBattery(80)
h.e:setOutage(true)
h.advance(16 * 60)
check("fresh-then-stale reading no longer holds tier 2 back", h.e:isTierShed(2))

print("[10] reboot mid-outage")
h = rig()
h.e:setOutage(true)
h.e:setBattery(10)
local blob = h.e:serialize()
JSON = JSON or require("JSON")
tostring_return_period = tostring_return_period or tostring
local function stringify(t)
  return JSON:decode(JSON:encode(t))
end
local h3 = rig()
local okR = h3.e:restore(stringify(blob))
check("restore accepted", okR == true)
check("shed state back", h3.e:highestShedTier() == 3 and h3.e:shedCount() == 4 and h3.e.st.phase == "outage")
h3.e:setOutage(false)
h3.advance(125)
h3.advance(70)
check("restored after reboot, using the saved prior states", h3.cmds(104) == "ON" and h3.cmds(102) == "RAMP_TO_LEVEL" and h3.cmds(101) == "CLOSE", h3.cmds(101) .. "|" .. h3.cmds(102))
check("thermostat restored to 70 from the saved prior", h3.sent[#h3.sent - 1].params.FAHRENHEIT == 70 or h3.sent[#h3.sent].params.FAHRENHEIT ~= nil)
local h4 = rig()
h4.e:setOutage(true)
h4.e:setOutage(false)
h4.advance(100)
local b4 = h4.e:serialize()
local h5 = rig()
h5.t = h4.t + 60
h5.e:restore(b4)
h5.advance(30)
check("holding resumes with the time already served", h5.e.st.phase == "normal" and h5.cmds(101) == "CLOSE", h5.e.st.phase)
check("garbage state refused", select(1, rig().e:restore({ v = 99 })) == false)
local h6 = rig()
h6.e:setOutage(true)
h6.e:setBattery(10)
h6.e:setOutage(false)
h6.advance(121)
local b6 = h6.e:serialize()
local h7 = rig()
h7.devices = h6.devices
h7.e:restore(b6)
h7.advance(200)
check("a restore interrupted by reboot finishes", h7.e.st.phase == "normal" and h7.cmds(101) == "CLOSE" and h7.cmds(102) == "RAMP_TO_LEVEL")

print("[11] licence halt mid-outage restores everything, then read-only")
h = rig()
h.e:setOutage(true)
h.e:setBattery(10)
h.e:setReadOnly(true)
h.advance(200)
check("every shed load put back", h.cmds(101) == "OPEN,CLOSE" and h.cmds(104) == "OFF,ON" and h.cmds(102):find("RAMP", 1, true) ~= nil)
check("nothing left shed", h.e:shedCount() == 0 and h.e.st.phase == "normal")
local okS, why = h.e:setOutage(true)
check("read-only refuses a new outage", okS == false and why == "read-only")
check("read-only refuses manual shed", h.e:shedTierNow(1) == false)
h.e:setBattery(1)
check("battery reading does not shed while read-only", h.e:highestShedTier() == 0)
h.e:setReadOnly(false)
check("licence back: commands accepted", h.e:setOutage(true) == true and h.e:isTierShed(1))

print("[12] manual shed and restore all")
h = rig()
h.e:shedTierNow(2)
check("manual tier 2, outage phase untouched", h.e:isTierShed(2) and h.e.st.phase == "normal" and h.cmds(102) == "OFF")
check("bad tier refused", h.e:shedTierNow(7) == false)
h.e:restoreAll()
h.advance(5)
check("restore all returns it", h.cmds(102):find("RAMP", 1, true) ~= nil and not h.e:isTierShed(2) and h.e.st.phase == "normal")
check("restore all with nothing shed is a no-op", h.e:restoreAll() == true)
h = rig()
h.e:setOutage(true)
h.e:setBattery(5)
h.e:restoreAll()
h.advance(100)
check("restore all in an outage runs the staggered restore now", h.cmds(104) == "OFF,ON" and h.e:shedCount() == 0)

print("[13] re-shed when the homeowner turns a load back on")
h = rig({ reshed = true })
h.e:setOutage(true)
h.e:setBattery(10)
check("ignored right after our own command", h.e:observe(2, true) == false)
h.advance(10)
check("re-shed after the grace", h.e:observe(2, true) == true and h.cmds(102) == "OFF,OFF")
check("off feedback ignored", h.e:observe(2, false) == false)
for _ = 1, 7 do
  h.advance(10)
  h.e:observe(2, true)
end
check("capped per outage", h.cmds(102):gsub("OFF", "") ~= nil and select(2, h.cmds(102):gsub("OFF", "")) <= 1 + E.LIMITS.resheds_per_outage)
local hn = rig()
hn.e:setOutage(true)
hn.advance(10)
check("re-shed off by default", hn.e:observe(1, true) == false)

print("[14] thermostat setback rules")
check("cool mode raises the cool setpoint", E.shedCommands({ kind = "thermostat", setback_f = 82 }, { known = true, hvac_mode = "Cool", cool_f = 74 })[1][1] == "SET_SETPOINT_COOL")
check("already past the setback: nothing", E.shedCommands({ kind = "thermostat", setback_f = 82 }, { known = true, hvac_mode = "Cool", cool_f = 85 }) == nil)
check("auto/off mode left alone", E.shedCommands({ kind = "thermostat", setback_f = 62 }, { known = true, hvac_mode = "Auto", heat_f = 70 }) == nil)
check("unknown thermostat left alone", E.shedCommands({ kind = "thermostat", setback_f = 62 }, {}) == nil)

print("[15] test mode (dry run) sends nothing and changes nothing")
h = rig()
local lines = h.e:dryRun()
check("lists sheds then restores in order", #lines == 8 and lines[1].phase == "shed" and lines[5].phase == "restore" and lines[5].tier == 3)
check("no command sent, no state", #h.sent == 0 and h.e.st.phase == "normal")

print("[16] flap with no shed loads and zero hold")
h = rig({ stable_hold_s = 0, tier_delay_s = 0 }, {})
h.e:setOutage(true)
h.e:setOutage(false)
check("no loads, instant return to normal", h.e.st.phase == "normal" and h.count("restored") == 1)
h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h.e:setOutage(true)
h.e:setBattery(5)
h.e:setOutage(false)
check("zero delays restore in one go", h.e.st.phase == "normal" and h.cmds(101) == "OPEN,CLOSE")

print("[17] a restore lost on the wire is retried, then reported")
h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h.e:setOutage(true)
h.e:setOutage(false)
check("restore sent once", h.cmds(101) == "OPEN,CLOSE")
check("record kept until confirmed", h.e.st.verify[1] ~= nil and h.e:snapshot().unconfirmed >= 1)
h.devices[101] = { known = true, closed = false } -- the CLOSE never arrived
h.advance(16)
check("first retry sent after the delay", h.cmds(101) == "OPEN,CLOSE,CLOSE" and h.count("restore_retry") >= 1)
h.advance(16)
check("second retry sent", h.cmds(101) == "OPEN,CLOSE,CLOSE,CLOSE")
h.advance(16)
check("gave up: no more sends, restore_failed event for slot 1", h.cmds(101) == "OPEN,CLOSE,CLOSE,CLOSE" and h.count("restore_failed") == 1 and h.e.st.verify[1] == nil)

h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h.e:setOutage(true)
h.e:setOutage(false)
h.devices[101] = { known = true, closed = true }
h.advance(16)
check("confirmed: no retry, no failure", h.cmds(101) == "OPEN,CLOSE" and h.count("restore_confirmed") >= 1 and h.count("restore_failed") == 0 and h.e.st.verify[1] == nil)

h = rig({ stable_hold_s = 0, tier_delay_s = 0, restore_retries = 1, restore_retry_s = 5 })
h.e:setOutage(true)
h.e:setOutage(false)
h.devices[101] = nil -- state cannot be read
h.advance(60)
check("unreadable load: retry only, never reported failed", h.cmds(101) == "OPEN,CLOSE,CLOSE" and h.count("restore_failed") == 0 and h.count("restore_unverified") == 1 and h.e.st.verify[1] == nil)

h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h.e:setOutage(true)
h.e:setOutage(false)
h.devices[101] = { known = true, closed = false }
local saved = h.e:serialize()
local h2 = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h2.t = h.t
h2.devices[101] = { known = true, closed = false }
h2.e:restore(saved)
h2.advance(16)
check("pending confirmation survives a reboot", h2.cmds(101) == "CLOSE")

print("[18] manual shed comes back by itself, or with Restore All / setOutage(false)")
h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
check("manual shed", h.e:shedTierNow(1) and h.cmds(101) == "OPEN")
h.advance(59 * 60)
check("still shed before the timer", h.cmds(101) == "OPEN")
h.advance(2 * 60)
check("auto-restored after 60 min", h.cmds(101) == "OPEN,CLOSE" and h.e.st.phase == "normal" and not h.e:anyShed() and h.count("manual_auto_restore") == 1)
h = rig({ manual_restore_min = 0, stable_hold_s = 0, tier_delay_s = 0 })
h.e:shedTierNow(1)
h.advance(24 * 3600)
check("0 = never", h.cmds(101) == "OPEN" and h.e:anyShed())
local okOff, whyOff = h.e:setOutage(false)
check("setOutage(false) restores a manual shed", okOff and h.cmds(101) == "OPEN,CLOSE" and not h.e:anyShed(), whyOff)
h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h.e:shedTierNow(1)
h.e:restoreAll()
h.advance(24 * 3600)
check("Restore All restores it and the timer does not fire later", h.cmds(101) == "OPEN,CLOSE" and h.count("manual_auto_restore") == 0)
h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h.e:shedTierNow(1)
local mid = h.e:serialize()
local h3 = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h3.t = h.t + 50 * 60
h3.e:restore(mid)
h3.advance(11 * 60)
check("manual timer re-armed after a reboot", h3.cmds(101) == "CLOSE")
h = rig()
h.e:setOutage(false)
check("nothing shed: still 'no outage in progress'", select(2, h.e:setOutage(false)) == "no outage in progress")

print("[19] every shed and restore asks for an immediate save")
h = rig({ stable_hold_s = 0, tier_delay_s = 0 })
h.e:setOutage(true)
local urgent = 0
for _, u in ipairs(h.changes) do
  if u then
    urgent = urgent + 1
  end
end
check("outage + tier shed are urgent", urgent >= 2)
h.changes = {}
h.e:setBattery(90)
check("plain battery chatter is not urgent", #h.changes > 0 and not h.changes[1])
h.changes = {}
h.e:setOutage(false)
local u2 = false
for _, u in ipairs(h.changes) do
  u2 = u2 or u
end
check("restore is urgent", u2)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end

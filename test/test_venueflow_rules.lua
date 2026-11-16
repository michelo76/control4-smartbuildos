-- VenueFlow visual programming engine, on the SIMULATOR: scene execution,
-- conditions and logic, every trigger kind, validation (unknown steps, bad
-- references, cycles, limits), dry run (sends nothing), waits, recursion
-- bounds, overlap protection, the execution log and last-success record.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Rules = require("venueflow.rules")
local Schema = require("venueflow.schema")
local T = H.checker()
local check, eq = T.check, T.eq

local env = H.new()
local studio = env.publishSample("sports_bar")
local manager = env.login("manager", "2580")
local M, S = { session = manager }, { session = studio }

local function steps(exec)
  local out = {}
  for _, s in ipairs(exec.steps) do
    out[#out + 1] = s.path .. ":" .. s.status
  end
  return table.concat(out, " ")
end

local function lastExecution(name)
  for _, e in ipairs(env.core.runner:list(true)) do
    if e.name == name then
      return e
    end
  end
  return nil
end

-- ── a scene with a condition ────────────────────────────────────────────────
print("scene condition")
eq("the venue starts closed", env.core.runtime.venueStatus, "closed")
local calls = env.sim():callCount()
local r = env.send("SCENE_ACTIVATE", { sceneId = "game-day" }, M)
check("condition not met: not ok", not r.ok)
eq("condition not met: code", r.errorCode, "VF_CONDITION_FALSE")
eq("condition not met: skipped", r.data.execution.status, "skipped")
eq("condition not met: nothing sent", env.sim():callCount(), calls)

env.send("VENUE_STATUS", { status = "open" }, M)
env.settle(3000)

-- ── the Game Day example ────────────────────────────────────────────────────
print("Game Day")
r = env.send("SCENE_ACTIVATE", { sceneId = "game-day" }, M)
check("accepted", r.ok)
check(
  "not reported finished while devices are still confirming",
  r.data.execution.status == "settling" or r.data.execution.status == "running",
  r.data.execution.status
)
eq("eight steps recorded", #r.data.execution.steps, 8)
env.settle(9000)
local exec = lastExecution("Game Day")
eq("finished ok once every device confirmed", exec.status, "ok")
eq("every step ok", steps(exec), "1:ok 2:ok 3:ok 4:ok 5:ok 6:ok 7:ok 8:ok")
eq("TV 01 on Sports 1", env.cell("display", "tv-01", "source").value, "sports-1")
eq("TV 06 on Sports 1", env.cell("display", "tv-06", "source").value, "sports-1")
eq("TV 07 on Sports 2", env.cell("display", "tv-07", "source").value, "sports-2")
eq("TV 12 on Sports 2", env.cell("display", "tv-12", "source").value, "sports-2")
eq("Bar zone plays Sports 1", env.cell("zone", "zone-bar", "source").value, "sports-1")
eq("Bar zone at 65%", env.cell("zone", "zone-bar", "volume").value, 65)
eq("Game Day lighting", env.cell("lighting", "house-lights", "preset").value, "game-day")
eq("variable set", env.core.runtime.variables["big-game-on"], true)
eq("active scene", env.core.runtime.activeScene.name, "Game Day")
eq("Composer variable ACTIVE_SCENE", env.variables.ACTIVE_SCENE, "Game Day")
check("Composer event fired", table.concat(env.events, ","):find("scene_activated", 1, true) ~= nil)
check("notification event fired", table.concat(env.events, ","):find("notification", 1, true) ~= nil)
eq("NOTIFICATION_TEXT", env.variables.NOTIFICATION_TEXT, "Game Day is running")
check("last successful execution recorded", type(env.core.runtime.lastSuccess["scene:game-day"]) == "number")
eq("each step names its operation", type(exec.steps[2].operationId), "string")
eq("per-display results kept", #exec.steps[2].results, 6)

-- ── a failing device makes the step, and the run, partial ───────────────────
print("partial run")
-- TV 03 is put on another source behind VenueFlow's back, then stops reacting.
env.sim():external(1103, { power = true, videoDevice = 3005 })
env.sim():setFault(1103, "silent")
local successBefore = env.core.runtime.lastSuccess["scene:game-day"]
env.clock.advance(2000)
r = env.send("SCENE_ACTIVATE", { sceneId = "game-day" }, M)
env.settle(12000)
exec = lastExecution("Game Day")
eq("run is partial", exec.status, "partial")
eq("the step with the silent display is partial", exec.steps[2].status, "partial")
local named = false
for _, t in ipairs(exec.steps[2].results) do
  if t.id == "tv-03" and t.status == "failed" then
    named = true
  end
end
check("the failing display is named in the step's results", named)
eq("other steps still ok", exec.steps[3].status, "ok")
eq("last success is not advanced by a partial run", env.core.runtime.lastSuccess["scene:game-day"], successBefore)
eq("last run records the partial", env.core.runtime.lastRun["scene:game-day"].status, "partial")
env.sim():setFault(1103, nil)

-- ── dry run sends nothing ───────────────────────────────────────────────────
print("dry run")
calls = env.sim():callCount()
local version = env.core.state.version
r = env.send("SCENE_PREVIEW", { sceneId = "closing" }, M)
eq("preview is planned", r.status, "planned")
eq("preview lists every step", #r.data.execution.steps, 7)
eq("first step planned", r.data.execution.steps[1].status, "planned")
eq("dry run: no adapter call", env.sim():callCount(), calls)
env.settle(3000)
eq("dry run: still no adapter call after time passes", env.sim():callCount(), calls)
eq("dry run: venue status unchanged", env.core.runtime.venueStatus, "open")
eq("dry run: displays untouched", env.cell("display", "tv-01", "power").value, "on")

local program = {
  steps = {
    { type = "route_video", sourceId = "sports-1", target = { displayIds = { "tv-01", "tv-20" } } },
    { type = "wait", seconds = 30 },
    { type = "set_variable", variableId = "big-game-on", value = false },
    { type = "notify", message = "hello" },
    { type = "set_venue_status", status = "closed" },
  },
}
calls = env.sim():callCount()
r = env.send("PROGRAM_DRY_RUN", { program = program, name = "plan" }, S)
eq("inline dry run planned", r.status, "planned")
eq("a step that would partly fail says so in the plan", r.data.execution.steps[1].status, "partial")
eq(
  "the plan names the display that would refuse",
  r.data.execution.steps[1].results[2].errorCode,
  "VF_SOURCE_NOT_ALLOWED"
)
eq("a dry run does not wait", r.data.execution.steps[2].status, "planned")
eq("dry run finishes at once", r.data.execution.status ~= "running", true)
eq("dry run: nothing sent", env.sim():callCount(), calls)
eq("dry run: variable untouched", env.core.runtime.variables["big-game-on"], true)
eq("dry run: no notification raised", env.variables.NOTIFICATION_TEXT, "Game Day is running")
eq("dry run: venue still open", env.core.runtime.venueStatus, "open")

-- ── logic: IF / ELSE, AND, OR, NOT ──────────────────────────────────────────
print("conditions and logic")
local function evalWith(cond, hour, wday)
  return Rules.evaluate(cond, {
    venueStatus = function()
      return "open"
    end,
    localtime = function()
      return { hour = hour or 18, min = 30, wday = wday or 2 } -- wday 2 = Monday
    end,
    displayState = function(id)
      return id == "tv-01" and { power = "on", source = "sports-1" } or nil
    end,
    zoneState = function()
      return { power = "on", muted = true, source = "music" }
    end,
    sourceAvailable = function(id)
      return id == "sports-1"
    end,
    variable = function(id)
      return ({ count = 5, flag = true, name = "cup" })[id]
    end,
    c4Variable = function(deviceId, name)
      return (deviceId == 77 and name == "TEMPERATURE") and "21" or nil
    end,
    context = { areaId = "bar" },
  })
end
eq("venue_status", evalWith({ op = "venue_status", is = "open" }), true)
eq("time_range inside", evalWith({ op = "time_range", from = "17:00", to = "23:00" }), true)
eq("time_range outside", evalWith({ op = "time_range", from = "17:00", to = "23:00" }, 9), false)
eq("time_range over midnight, late", evalWith({ op = "time_range", from = "22:00", to = "02:00" }, 23), true)
eq("time_range over midnight, early", evalWith({ op = "time_range", from = "22:00", to = "02:00" }, 1), true)
eq("time_range over midnight, day", evalWith({ op = "time_range", from = "22:00", to = "02:00" }, 12), false)
eq("day_of_week Monday", evalWith({ op = "day_of_week", days = { 1 } }), true)
eq("day_of_week Sunday is 7", evalWith({ op = "day_of_week", days = { 7 } }, 18, 1), true)
eq(
  "display_state",
  evalWith({ op = "display_state", displayId = "tv-01", field = "source", equals = "sports-1" }),
  true
)
eq(
  "display_state unknown display is false",
  evalWith({ op = "display_state", displayId = "tv-x", field = "power", equals = "on" }),
  false
)
eq("zone_state muted", evalWith({ op = "zone_state", zoneId = "z", field = "muted", equals = true }), true)
eq("source_available", evalWith({ op = "source_available", sourceId = "sports-1" }), true)
eq("source not available", evalWith({ op = "source_available", sourceId = "sports-2" }), false)
eq("variable gt", evalWith({ op = "variable", variableId = "count", cmp = "gt", value = 3 }), true)
eq("variable le", evalWith({ op = "variable", variableId = "count", cmp = "le", value = 3 }), false)
eq("variable bool eq", evalWith({ op = "variable", variableId = "flag", cmp = "eq", value = true }), true)
eq("variable string ne", evalWith({ op = "variable", variableId = "name", cmp = "ne", value = "league" }), true)
eq(
  "unknown variable is false, never guessed",
  evalWith({ op = "variable", variableId = "missing", cmp = "eq", value = 0 }),
  false
)
eq(
  "c4_variable compares numbers read as text",
  evalWith({ op = "c4_variable", deviceId = 77, variable = "TEMPERATURE", cmp = "ge", value = 20 }),
  true
)
eq("context_area", evalWith({ op = "context_area", areaId = "bar" }), true)
eq(
  "AND",
  evalWith({ op = "and", items = { { op = "venue_status", is = "open" }, { op = "bool", value = true } } }),
  true
)
eq(
  "AND with a false member",
  evalWith({ op = "and", items = { { op = "venue_status", is = "open" }, { op = "bool", value = false } } }),
  false
)
eq(
  "OR",
  evalWith({ op = "or", items = { { op = "bool", value = false }, { op = "venue_status", is = "open" } } }),
  true
)
eq("NOT", evalWith({ op = "not", item = { op = "venue_status", is = "closed" } }), true)
eq(
  "nested",
  evalWith({
    op = "and",
    items = {
      {
        op = "or",
        items = { { op = "day_of_week", days = { 6, 7 } }, { op = "time_range", from = "17:00", to = "23:00" } },
      },
      { op = "not", item = { op = "variable", variableId = "count", cmp = "eq", value = 0 } },
    },
  }),
  true
)
eq("an unknown op is false", evalWith({ op = "launch" }), false)

-- IF / ELSE inside a program picks one branch.
r = env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "branch",
  program = {
    steps = {
      {
        type = "if",
        condition = { op = "variable", variableId = "big-game-on", cmp = "eq", value = true },
        ["then"] = { { type = "volume", zoneId = "zone-bar", level = 70 } },
        ["else"] = { { type = "volume", zoneId = "zone-bar", level = 20 } },
      },
      { type = "set_variable", variableId = "big-game-on", value = false },
    },
  },
}, S)
check("branch program accepted", r.ok)
env.settle(3000)
exec = lastExecution("branch")
eq("THEN branch taken", exec.steps[1].branch, "then")
eq("the branch's step ran with its path", exec.steps[2].path, "1.then.1")
eq("bar volume from the THEN branch", env.cell("zone", "zone-bar", "volume").value, 70)
eq("the step after the IF ran", env.core.runtime.variables["big-game-on"], false)

r = env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "branch2",
  program = {
    steps = {
      {
        type = "if",
        condition = { op = "variable", variableId = "big-game-on", cmp = "eq", value = true },
        ["then"] = { { type = "volume", zoneId = "zone-bar", level = 70 } },
        ["else"] = { { type = "volume", zoneId = "zone-bar", level = 20 } },
      },
    },
  },
}, S)
env.settle(3000)
eq("ELSE branch taken when the variable changed", lastExecution("branch2").steps[1].branch, "else")
eq("bar volume from the ELSE branch", env.cell("zone", "zone-bar", "volume").value, 20)

eq(
  "execute needs confirmation",
  env.send("PROGRAM_EXECUTE", { program = { steps = {} } }, S).errorCode,
  "VF_CONFIRM_REQUIRED"
)

-- ── wait, cancel ────────────────────────────────────────────────────────────
print("waits")
r = env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "waiter",
  program = {
    steps = {
      { type = "volume", zoneId = "zone-dining", level = 30 },
      { type = "wait", seconds = 20 },
      { type = "volume", zoneId = "zone-dining", level = 50 },
    },
  },
}, S)
env.settle(5000)
eq("first step done before the wait ends", env.cell("zone", "zone-dining", "volume").value, 30)
eq("still running during the wait", env.core.runner.running[r.data.execution.id] ~= nil, true)
env.settle(18000)
eq("the step after the wait ran", env.cell("zone", "zone-dining", "volume").value, 50)
eq("finished", lastExecution("waiter").status, "ok")

r = env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "cancel-me",
  program = { steps = { { type = "wait", seconds = 60 }, { type = "volume", zoneId = "zone-dining", level = 10 } } },
}, S)
env.settle(2000)
eq("cancel", env.send("EXECUTION_CANCEL", { executionId = r.data.execution.id }, S).ok, true)
env.settle(70000)
eq("a cancelled run never runs its remaining steps", env.cell("zone", "zone-dining", "volume").value, 50)
eq("cancelled status", lastExecution("cancel-me").status, "cancelled")

-- Stopping a run also stops the commands its current step had queued and not
-- yet sent (reviewer finding on PR #40: they kept arriving after "cancelled").
print("stopping a run stops its queued commands")
do
  local e = H.new()
  local st = { session = e.publishSample("sports_bar") }
  local mgr = { session = e.login("manager", "2580") }
  e.settle(10000)
  local twelve = {}
  for i = 1, 12 do
    twelve[i] = string.format("tv-%02d", i)
  end
  local function videoCalls(from)
    local n = 0
    for i = from + 1, e.sim():callCount() do
      if e.sim().calls[i].command == "SELECT_VIDEO_DEVICE" then
        n = n + 1
      end
    end
    return n
  end
  local function big(name)
    return e.send("PROGRAM_EXECUTE", {
      confirm = true,
      name = name,
      program = {
        steps = {
          { type = "route_video", sourceId = "sports-3", target = { displayIds = twelve } },
          { type = "wait", seconds = 30 },
        },
      },
    }, st)
  end
  local function find(name)
    for _, x in ipairs(e.core.runner:list(true)) do
      if x.name == name then
        return x
      end
    end
  end

  local before12 = e.cell("display", "tv-12", "source")
  local wasValue, wasStatus = before12.value, before12.status
  local mark = e.sim():callCount()
  local run = big("stop-me")
  eq("one command has left, eleven wait in the queue", e.core.queue:size(), 11)
  eq("a queued display shows as pending", e.cell("display", "tv-12", "source").status, "pending")
  local hooked, hook = 0, e.core.state.onChange
  e.core.state.onChange = function(kind, id, ...)
    if id == "tv-12" then
      hooked = hooked + 1
    end
    return hook(kind, id, ...)
  end
  eq("the installer stops the run", e.send("EXECUTION_CANCEL", { executionId = run.data.execution.id }, st).ok, true)
  e.core.state.onChange = hook
  eq("the queue is empty at once", e.core.queue:size(), 0)
  eq("withdrawing a command is not reported as a device change (no rule fires on it)", hooked, 0)
  e.settle(20000)
  eq("only the command already sent reached Control4", videoCalls(mark), 1)
  eq("the display that was sent to is confirmed", e.cell("display", "tv-01", "source").value, "sports-3")
  eq("a display never sent to shows what it showed before", e.cell("display", "tv-12", "source").value, wasValue)
  eq("...with the standing it had before, not pending", e.cell("display", "tv-12", "source").status, wasStatus)
  local op = e.core.tracker.ops[1]
  eq("the operation is finished", op.done, true)
  eq("...one target confirmed", op.summary.confirmed, 1)
  eq("...eleven stopped", op.summary.superseded, 11)
  eq("...and they say why", op.targets[12].errorCode, "VF_CANCELLED")
  eq("the run is recorded as cancelled", find("stop-me").status, "cancelled")
  check(
    "the diagnostic log says how many commands were not sent",
    (function()
      for _, entry in ipairs(e.core.diag:list({ limit = 30 })) do
        if entry.message:find("11 queued commands not sent", 1, true) then
          return true
        end
      end
      return false
    end)()
  )
  -- The next manual command is not held up by the stopped ones.
  mark = e.sim():callCount()
  e.send("ROUTE_VIDEO", { sourceId = "sports-2", displayIds = { "tv-12" } }, mgr)
  eq("a manual command right after the stop leaves at once", videoCalls(mark), 1)
  e.settle(8000)
  eq("...and is confirmed", e.cell("display", "tv-12", "source").value, "sports-2")

  -- A command someone else also asked for is not stopped with the run.
  e.send("ROUTE_VIDEO", { sourceId = "sports-4", displayIds = twelve }, mgr)
  e.settle(10000)
  mark = e.sim():callCount()
  e.send("ROUTE_VIDEO", { sourceId = "sports-3", displayIds = twelve }, mgr) -- 1 sent, 11 queued
  local manualOp = e.core.tracker.ops[1]
  run = e.send("PROGRAM_EXECUTE", {
    confirm = true,
    name = "same-as-manual",
    program = {
      steps = {
        { type = "route_video", sourceId = "sports-3", target = { displayIds = { "tv-10", "tv-11", "tv-12" } } },
        { type = "wait", seconds = 30 },
      },
    },
  }, st)
  eq("the run is stopped", e.send("EXECUTION_CANCEL", { executionId = run.data.execution.id }, st).ok, true)
  e.settle(20000)
  eq("every command of the manual request still went out", videoCalls(mark), 12)
  eq("...and the manual request is confirmed on all twelve", manualOp.summary.confirmed, 12)
  eq("...including a display the stopped run also named", e.cell("display", "tv-11", "source").value, "sports-3")

  -- All Off stops running scenes: their queued routes must not arrive after it.
  e.send("ROUTE_VIDEO", { sourceId = "sports-4", displayIds = twelve }, mgr)
  e.settle(10000)
  big("before-all-off")
  mark = e.sim():callCount()
  check("All Off is accepted", e.send("ALL_OFF", { confirm = true }, mgr).ok)
  e.settle(30000)
  eq("no route from the stopped scene arrives after All Off", videoCalls(mark), 0)
  eq("...and the displays end off", e.cell("display", "tv-12", "power").value, "off")
end

-- ── overlap protection ──────────────────────────────────────────────────────
print("overlapping runs")
local a = env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "slow A",
  program = {
    steps = {
      { type = "route_video", sourceId = "sports-3", target = { displayIds = { "tv-16" } } },
      { type = "wait", seconds = 30 },
      { type = "route_video", sourceId = "sports-4", target = { displayIds = { "tv-16" } } },
    },
  },
}, S)
env.settle(3000)
local alertsBefore = #env.core.runtime.alerts
local b = env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "fast B",
  program = { steps = { { type = "route_video", sourceId = "news", target = { displayIds = { "tv-16" } } } } },
}, S)
env.settle(40000)
eq("the older run was stopped", lastExecution("slow A").status, "cancelled")
eq("...and says by what", lastExecution("slow A").cancelledBy, "fast B")
eq("...with the reason", lastExecution("slow A").cancelReason, "VF_SUPERSEDED")
eq("the newer run's value stands", env.cell("display", "tv-16", "source").value, "news")
check("the interruption is not silent: an alert was raised", #env.core.runtime.alerts > alertsBefore)
check("both runs exist in the log", a.ok and b.ok)

-- Runs that touch different devices do not stop each other.
env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "left",
  program = { steps = { { type = "wait", seconds = 10 }, { type = "volume", zoneId = "zone-bar", level = 33 } } },
}, S)
env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "right",
  program = { steps = { { type = "volume", zoneId = "zone-dining", level = 44 } } },
}, S)
env.settle(15000)
eq("independent runs both finish", lastExecution("left").status .. "/" .. lastExecution("right").status, "ok/ok")

-- ── triggers ────────────────────────────────────────────────────────────────
print("triggers")
-- venue_status: the sample rule routes signage to the patio board on open.
env.send("VENUE_STATUS", { status = "closed" }, M)
env.sim():external(1120, { power = true, videoDevice = 3005 })
env.send("VENUE_STATUS", { status = "open" }, M)
env.settle(3000)
eq("venue_status trigger ran its rule", env.cell("display", "tv-20", "source").value, "signage")

-- Build rules for the other trigger kinds on a fresh venue.
local e2 = H.new()
local st2 = e2.studio()
local config = H.Templates.sportsBar()
config.rules = {
  {
    id = "on-scene",
    name = "After Happy Hour",
    enabled = true,
    trigger = { type = "scene_activated", sceneId = "happy-hour" },
    program = { steps = { { type = "volume", zoneId = "zone-patio", level = 22 } } },
  },
  {
    id = "on-event",
    name = "Doorbell",
    enabled = true,
    trigger = { type = "c4_event", name = "Doorbell" },
    program = { steps = { { type = "volume", zoneId = "zone-lounge", level = 11 } } },
  },
  {
    id = "on-state",
    name = "TV 01 goes off",
    enabled = true,
    trigger = { type = "device_state", entity = "display", id = "tv-01", field = "power", equals = "off" },
    program = { steps = { { type = "set_variable", variableId = "big-game-on", value = true } } },
  },
  {
    id = "on-c4var",
    name = "Fire panel",
    enabled = true,
    trigger = { type = "c4_variable", deviceId = 9001, variable = "ALARM" },
    program = { steps = { { type = "notify", message = "Fire panel changed", level = "warning" } } },
  },
  {
    id = "manual-only",
    name = "By hand",
    enabled = true,
    trigger = { type = "manual" },
    program = { steps = { { type = "volume", zoneId = "zone-bar", level = 5 } } },
  },
  {
    id = "disabled",
    name = "Disabled",
    enabled = false,
    trigger = { type = "c4_event", name = "Doorbell" },
    program = { steps = { { type = "volume", zoneId = "zone-bar", level = 99 } } },
  },
}
local saved = e2.send("DRAFT_SAVE", { config = config }, { session = st2 })
check("rules for every trigger kind validate", saved.ok and saved.data.summary.errors == 0, saved.detail)
local acks = {}
for _, i in ipairs(saved.data.issues) do
  acks[#acks + 1] = i.id
end
check("published", e2.send("PUBLISH", { acknowledged = acks }, { session = st2 }).ok)
e2.settle(1000)
e2.core:setVenueStatus("open", "test")
e2.settle(2000)

e2.send("SCENE_ACTIVATE", { sceneId = "happy-hour" }, { session = st2 })
e2.settle(5000)
eq("scene_activated trigger", e2.cell("zone", "zone-patio", "volume").value, 22)

local ok, msg = e2.core:composer("TRIGGER_EVENT", { NAME = "doorbell" })
check("c4_event trigger (from Composer programming), name is case-blind", ok, msg)
e2.settle(3000)
eq("c4_event rule ran", e2.cell("zone", "zone-lounge", "volume").value, 11)
check("a disabled rule on the same event did not run", e2.cell("zone", "zone-bar", "volume").value ~= 85)
eq("an unknown event runs nothing", e2.core:composer("TRIGGER_EVENT", { NAME = "nothing" }), false)

e2.send("DISPLAY_POWER", { displayIds = { "tv-01" }, power = "on" }, { session = st2 })
e2.settle(2000)
e2.core.runtime.variables["big-game-on"] = false
e2.send("DISPLAY_POWER", { displayIds = { "tv-01" }, power = "off" }, { session = st2 })
e2.settle(3000)
eq("device_state trigger", e2.core.runtime.variables["big-game-on"], true)

local before = #e2.core.runtime.alerts
e2.sim():setVariable(9001, "ALARM", "1")
e2.settle(1000)
check("c4_variable trigger", #e2.core.runtime.alerts > before)

eq("a manual rule is not run by events", e2.cell("zone", "zone-bar", "volume").value ~= 5, true)

-- ── validation ──────────────────────────────────────────────────────────────
print("validation")
local function issuesOf(mutate)
  local c = H.Templates.sportsBar()
  mutate(c)
  local codes = {}
  for _, i in ipairs(Schema.validate(Schema.normalize(c))) do
    codes[i.code] = (codes[i.code] or 0) + 1
  end
  return codes
end
eq(
  "unknown step type refused",
  issuesOf(function(c)
    c.scenes[1].program.steps[1] = { type = "run_lua", code = "os.exit()" }
  end).STEP_UNKNOWN,
  1
)
eq(
  "unknown condition refused",
  issuesOf(function(c)
    c.scenes[2].condition = { op = "eval", code = "true" }
  end).CONDITION_UNKNOWN,
  1
)
eq(
  "unknown trigger refused",
  issuesOf(function(c)
    c.rules[1].trigger = { type = "webhook" }
  end).TRIGGER_UNKNOWN,
  1
)
check("a missing reference is an error", (issuesOf(function(c)
  c.scenes[2].program.steps[2].sourceId = "ghost"
end).REF_UNKNOWN or 0) >= 1)
eq(
  "an unset subject is a warning to resolve or acknowledge",
  issuesOf(function(c)
    c.scenes[2].program.steps[2].sourceId = nil
  end).STEP_INCOMPLETE,
  1
)
eq(
  "an audio-only source in a video route",
  issuesOf(function(c)
    c.scenes[2].program.steps[2].sourceId = "music"
  end).STEP_INVALID,
  1
)
eq(
  "a wait over the limit",
  issuesOf(function(c)
    c.scenes[1].program.steps[1] = { type = "wait", seconds = 3600 }
  end).STEP_INVALID,
  1
)
eq(
  "a scene that runs itself",
  issuesOf(function(c)
    c.scenes[1].program.steps[1] = { type = "run_scene", sceneId = c.scenes[1].id }
  end).SCENE_CYCLE,
  1
)
check("a cycle through two scenes", (issuesOf(function(c)
  c.scenes[1].program.steps[1] = { type = "run_scene", sceneId = c.scenes[2].id }
  c.scenes[2].program.steps[1] = { type = "run_scene", sceneId = c.scenes[1].id }
end).SCENE_CYCLE or 0) >= 1)
check("a cycle through a scene-triggered rule", (issuesOf(function(c)
  c.rules[1] = {
    id = "loop",
    name = "loop",
    enabled = true,
    trigger = { type = "scene_activated", sceneId = "opening" },
    program = { steps = { { type = "run_scene", sceneId = "opening" } } },
  }
end).SCENE_CYCLE or 0) >= 1)
eq(
  "too many steps",
  issuesOf(function(c)
    local many = {}
    for i = 1, 61 do
      many[i] = { type = "wait", seconds = 1 }
    end
    c.scenes[1].program.steps = many
  end).PROGRAM_TOO_LONG,
  1
)
eq(
  "IF nested too deep",
  issuesOf(function(c)
    local inner = { type = "wait", seconds = 1 }
    for _ = 1, 6 do
      inner = { type = "if", condition = { op = "bool", value = true }, ["then"] = { inner }, ["else"] = {} }
    end
    c.scenes[1].program.steps = { inner }
  end).STEP_TOO_DEEP,
  1
)
eq(
  "two schedules at one minute on the same devices",
  issuesOf(function(c)
    c.rules[2].trigger = { type = "schedule", days = { 1 }, time = "11:00" }
    c.rules[2].condition = nil
    c.rules[2].program = { steps = { { type = "run_scene", sceneId = "opening" } } }
  end).SCHEDULE_OVERLAP,
  1
)

r = env.send("PROGRAM_VALIDATE", { program = { steps = { { type = "shell", cmd = "rm" } } } }, S)
check("PROGRAM_VALIDATE refuses an unknown step", not r.ok and r.data.summary.errors == 1)
r = env.send(
  "PROGRAM_DRY_RUN",
  { program = { steps = { { type = "route_video", sourceId = "ghost", target = { all = true } } } } },
  S
)
eq("a program that names something unpublished cannot be run", r.errorCode, "VF_VALIDATION_FAILED")

-- ── the runner refuses what validation would have refused ───────────────────
print("runner bounds")
local seen = {}
local runner = Rules.newRunner({
  ops = {
    volume = function(zoneId, level)
      seen[#seen + 1] = zoneId .. "=" .. level
      return { ok = true, status = "ok" }
    end,
  },
  env = function()
    return {
      venueStatus = function()
        return "open"
      end,
    }
  end,
  config = function()
    return { displays = {} }
  end,
  index = function()
    return {
      displays = {},
      sources = {},
      zones = {},
      groups = {},
      areas = {},
      lighting = {},
      shades = {},
      variables = {},
      scenes = {
        loop = {
          id = "loop",
          name = "Loop",
          program = {
            steps = { { type = "volume", zoneId = "z", level = 1 }, { type = "run_scene", sceneId = "loop" } },
          },
        },
      },
    }
  end,
  timers = env.clock.api,
  now = env.clock.now,
})
local looped = runner:start({
  kind = "scene",
  refId = "loop",
  name = "Loop",
  program = { steps = { { type = "volume", zoneId = "z", level = 1 }, { type = "run_scene", sceneId = "loop" } } },
})
eq("a self-running scene is stopped, not looped", looped.steps[2].errorCode, "VF_RECURSION_LIMIT")
eq("its first step ran once", #seen, 1)
local unknown = runner:start({ kind = "adhoc", name = "x", program = { steps = { { type = "format_disk" } } } })
eq("an unknown step type is never executed", unknown.steps[1].status, "failed")
eq("unknown step code", unknown.steps[1].errorCode, "VF_UNSUPPORTED")

-- ── the log ─────────────────────────────────────────────────────────────────
print("execution log")
r = env.send("EXECUTIONS", {}, S)
check("the log lists runs", #r.data.executions >= 8, #r.data.executions)
check("the log carries last runs", r.data.lastRun["scene:game-day"] ~= nil)
check("the log carries last successes", r.data.lastSuccess["scene:game-day"] ~= nil)
check("upcoming schedules are listed", #r.data.upcoming >= 1)
local sawSceneDiag = false
for _, e in ipairs(env.core.diag:list({ limit = 200, category = "scene" })) do
  if e.message:find("Game Day", 1, true) and e.message:find("partial", 1, true) then
    sawSceneDiag = type(e.data) == "table" and type(e.data.problems) == "table"
  end
end
check("a partial run is in diagnostics with its failing steps", sawSceneDiag)

-- ── a schedule due just after a start or a publish ──────────────────────────
-- Reviewer finding on PR #40: the scheduler learned its baseline from its
-- first tick, 20 s after it was installed, so a schedule falling due inside
-- that gap never ran. The tick timer here runs from the driver's start.
print("schedules across a start and a publish")
do
  local ELEVEN = H.MONDAY_NOON - 3600
  local function withSchedule(e, session)
    local draft = e.send("DRAFT_GET", {}, session).data.draft
    local rules = draft.config.rules
    rules[#rules + 1] = {
      id = "t-open",
      name = "Test open",
      enabled = true,
      trigger = { type = "schedule", days = { 1 }, time = "11:00" },
      program = { steps = { { type = "volume", zoneId = "zone-dining", level = 33 } } },
    }
    local saved = e.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, session)
    assert(saved.ok, "draft not saved: " .. tostring(saved.errorCode) .. " " .. tostring(saved.detail))
    local acks = {}
    for _, i in ipairs(e.send("DRAFT_GET", {}, session).data.draft.issues) do
      acks[#acks + 1] = i.id
    end
    local p = e.send("PUBLISH", { acknowledged = acks }, session)
    assert(p.ok, "not published: " .. tostring(p.errorCode) .. " " .. tostring(p.detail))
  end
  local function ranAt(e)
    local last = e.core.runtime.lastRun["rule:t-open"]
    return last and last.status or nil
  end

  -- A publish at 10:59:55, between the 10:59:50 tick and the 11:00:10 one.
  local e = H.new({ start = ELEVEN - 610 }) -- 10:49:50; ticks land on :10, :30, :50
  local st = { session = e.publishSample("sports_bar") }
  e.clock.advance((ELEVEN - 5 - e.clock.now()) * 1000) -- to 10:59:55
  withSchedule(e, st)
  eq("published at 10:59:55, nothing has run yet", ranAt(e), nil)
  e.clock.advance(30000) -- past the 11:00:10 tick
  e.settle(8000)
  eq("the 11:00 schedule runs although the publish replaced the scheduler", ranAt(e), "ok")
  eq("...and did what it says", e.cell("zone", "zone-dining", "volume").value, 33)

  -- A driver start at 10:59:50 with that venue already stored.
  local again = H.new({ kv = e.kv, start = ELEVEN + 7 * 86400 - 10 }) -- the next Monday, 10:59:50
  again.core.runtime.lastRun["rule:t-open"] = nil
  again.clock.advance(25000) -- the first tick, at 11:00:10
  again.settle(8000)
  eq("started at 10:59:50, the 11:00 schedule runs at the first tick", ranAt(again), "ok")

  -- A start after the minute has passed is downtime: not run late.
  local late = H.new({ kv = e.kv, start = ELEVEN + 14 * 86400 + 65 }) -- 11:01:05
  late.core.runtime.lastRun["rule:t-open"] = nil
  late.clock.advance(60000)
  late.settle(8000)
  eq("started at 11:01:05, the 11:00 schedule is not run late", ranAt(late), nil)
end

-- ── regressions found while building the editor ───────────────────────────
print("regressions")
-- A scene whose own step fires a rule on the same devices must not be
-- stopped by that rule (Opening marks the venue open; a rule waits for that).
local e5 = H.new()
local st5 = e5.publishSample("sports_bar")
r = e5.send("SCENE_ACTIVATE", { sceneId = "opening" }, { session = st5 })
check("Opening accepted", r.ok)
e5.settle(12000)
local opening
for _, e in ipairs(e5.core.runner:list(true)) do
  if e.name == "Opening" then
    opening = e
  end
end
eq("Opening ran all eight steps and was not stopped by the rule it triggered", opening.status, "ok")
eq("...every step", #opening.steps, 8)
eq("...and the triggered rule ran too", e5.core.runtime.lastRun["rule:patio-follows-status"].status, "ok")
eq("the patio board shows signage", e5.cell("display", "tv-20", "source").value, "signage")

-- An installer's test of a saved scene is recorded as that scene's run.
r = e5.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "Happy Hour",
  refKind = "scene",
  refId = "happy-hour",
  program = { steps = { { type = "volume", zoneId = "zone-bar", level = 52 } } },
}, { session = st5 })
e5.settle(3000)
eq("a test with refKind/refId is the item's last run", e5.core.runtime.lastRun["scene:happy-hour"].status, "ok")
check("...and its last success", e5.core.runtime.lastSuccess["scene:happy-hour"] ~= nil)
eq("...without making the scene active", e5.core.runtime.activeScene.id, "opening")
eq(
  "an unknown refKind is refused",
  e5.send(
    "PROGRAM_EXECUTE",
    { confirm = true, refKind = "macro", refId = "x", program = { steps = {} } },
    { session = st5 }
  ).errorCode,
  "VF_INVALID_PAYLOAD"
)
r = e5.send(
  "PROGRAM_EXECUTE",
  { confirm = true, name = "Scratch", program = { steps = { { type = "volume", zoneId = "zone-bar", level = 40 } } } },
  { session = st5 }
)
e5.settle(3000)
eq("an unnamed test is in the log only", e5.core.runtime.lastRun["Scratch"], nil)

-- A dry run that would work ends "planned", never "ok".
r = e5.send(
  "PROGRAM_DRY_RUN",
  { program = { steps = { { type = "volume", zoneId = "zone-bar", level = 40 } } } },
  { session = st5 }
)
eq("a clean dry run's status is planned", r.data.execution.status, "planned")

-- A lighting step with no preset yet is "not set up", like any other unset subject.
eq(
  "a lighting step without a preset is a warning",
  issuesOf(function(c)
    c.scenes[1].program.steps[1] = { type = "lighting", lightingId = "house-lights" }
  end).STEP_INCOMPLETE,
  1
)
eq(
  "...and a preset that does not exist is still an error",
  issuesOf(function(c)
    c.scenes[1].program.steps[1] = { type = "lighting", lightingId = "house-lights", presetId = "disco" }
  end).REF_UNKNOWN,
  1
)
local ctl = e5.send("EXECUTIONS", {}, { session = st5 }).data.controller
check(
  "EXECUTIONS carries the controller's current local time",
  type(ctl.localTime) == "string" and #ctl.localTime == 16
)

T.done()

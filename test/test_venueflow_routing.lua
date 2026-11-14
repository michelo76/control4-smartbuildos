-- VenueFlow video routing and display power, on the SIMULATOR (the reference
-- sports bar: 24 displays, 8 sources). Single and multi-display routes,
-- invalid destinations, unsupported sources, the six-display partial result,
-- every state class (confirmed, pending, commanded, unknown, failed),
-- command serialisation and supersession, custom-command routes, power.
--
-- "Verified" here means: verified against src/venueflow/sim.lua. Nothing in
-- this file is evidence about a real controller.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local T = H.checker()
local check, eq = T.check, T.eq

local function byId(results)
  local out = {}
  for _, r in ipairs(results or {}) do
    out[r.id] = r
  end
  return out
end

local env = H.new()
env.publishSample("sports_bar")
local manager = env.login("manager", "2580")
check("manager signs in", manager ~= nil)
local M = { session = manager }

-- ── single display ──────────────────────────────────────────────────────────
print("single display")
local calls = env.sim():callCount()
local r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, M)
check("reply is accepted, not 'ok'", r.ok and r.status == "accepted", r.status)
eq("one result", #r.results, 1)
eq("result is pending", r.results[1].status, "pending")
check("an operation id is returned", type(r.operationId) == "string")
eq("cell is pending at once", env.cell("display", "tv-01", "source").status, "pending")
eq("cell shows the requested source while pending", env.cell("display", "tv-01", "source").value, "sports-1")
eq("exactly one command reached the adapter", env.sim():callCount() - calls, 1)
local call = env.sim().calls[#env.sim().calls]
eq("command is SELECT_VIDEO_DEVICE", call.command, "SELECT_VIDEO_DEVICE")
eq("sent to the display's Control4 room", call.target, 1101)
eq("with the source's Control4 device", call.params.deviceid, 3001)
env.settle(1500)
eq("cell is confirmed after feedback", env.cell("display", "tv-01", "source").status, "confirmed")
eq("power follows from the room", env.cell("display", "tv-01", "power").value, "on")
local op = env.operation(r.operationId)
check("operation is done", op.done)
eq("operation: 1 confirmed", op.summary.confirmed, 1)
eq("operation: 0 bad", op.summary.bad, 0)

-- ── multi display ───────────────────────────────────────────────────────────
print("multi display")
calls = env.sim():callCount()
r = env.send("ROUTE_VIDEO", { sourceId = "sports-2", displayIds = { "tv-02", "tv-03", "tv-04", "tv-09", "tv-10" } }, M)
eq("five accepted", r.summary.accepted, 5)
eq("none rejected", r.summary.rejected, 0)
eq("status accepted", r.status, "accepted")
-- Serialisation: the queue spaces commands; not all five leave in the same instant.
check("commands are spaced, not sent in one burst", env.sim():callCount() - calls < 5, env.sim():callCount() - calls)
env.settle(2500)
eq("all five commands left", env.sim():callCount() - calls, 5)
for _, id in ipairs({ "tv-02", "tv-03", "tv-04", "tv-09", "tv-10" }) do
  eq(
    id .. " confirmed on sports-2",
    env.cell("display", id, "source").value .. "/" .. env.cell("display", id, "source").status,
    "sports-2/confirmed"
  )
end
eq("tv-01 was not touched", env.cell("display", "tv-01", "source").value, "sports-1")

-- duplicates are dropped
r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-02", "tv-02", "tv-02" } }, M)
eq("duplicate ids resolve to one display", #r.results, 1)
env.settle(1500)

-- ── invalid destinations and sources ────────────────────────────────────────
print("invalid destinations and unsupported sources")
r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-99" } }, M)
check("unknown display: not ok", not r.ok)
eq("unknown display: failed", r.status, "failed")
eq("unknown display code", r.results[1].errorCode, "VF_NOT_FOUND")

r = env.send("ROUTE_VIDEO", { sourceId = "nope", displayIds = { "tv-01" } }, M)
eq("unknown source refused", r.errorCode, "VF_NOT_FOUND")

r = env.send("ROUTE_VIDEO", { sourceId = "music", displayIds = { "tv-01" } }, M)
eq("audio-only source cannot be routed as video", r.errorCode, "VF_SOURCE_UNAVAILABLE")

r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = {} }, M)
eq("no displays", r.errorCode, "VF_INVALID_PAYLOAD")

calls = env.sim():callCount()
r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-20" } }, M)
eq("signage-only display refuses sports", r.results[1].errorCode, "VF_SOURCE_NOT_ALLOWED")
check("the refusal has an operator sentence", type(r.results[1].message) == "string" and #r.results[1].message > 5)
eq("nothing was sent for a refused route", env.sim():callCount(), calls)
eq("a refused route leaves the cell alone", env.cell("display", "tv-20", "source").status ~= "pending", true)

-- ── the six-display example: four routed, one unavailable, one unsupported ──
print("partial success, reported per display")
env.sim():setFault(2105, "offline") -- TV 05's device stops answering
r = env.send(
  "ROUTE_VIDEO",
  { sourceId = "sports-3", displayIds = { "tv-01", "tv-02", "tv-03", "tv-04", "tv-05", "tv-20" } },
  M
)
check("partial is ok (something was sent)...", r.ok)
eq("...and is reported as partial, never as success", r.status, "partial")
eq("six results", #r.results, 6)
eq("four accepted", r.summary.accepted, 4)
eq("two rejected", r.summary.rejected, 2)
local res = byId(r.results)
eq("tv-05 unavailable", res["tv-05"].errorCode, "VF_DEVICE_OFFLINE")
eq("tv-20 unsupported", res["tv-20"].errorCode, "VF_SOURCE_NOT_ALLOWED")
eq("tv-01 pending", res["tv-01"].status, "pending")
env.settle(3000)
op = env.operation(r.operationId)
eq("operation: 4 confirmed", op.summary.confirmed, 4)
eq("operation: 2 failed", op.summary.failed, 2)
eq("operation good count", op.summary.good, 4)
eq("operation bad count", op.summary.bad, 2)
eq("tv-04 shows sports-3", env.cell("display", "tv-04", "source").value, "sports-3")
env.sim():setFault(2105, nil)

-- ── state classes ───────────────────────────────────────────────────────────
print("state classes")
-- failed: the room accepts the command and never changes.
env.sim():setFault(1106, "silent")
r = env.send("ROUTE_VIDEO", { sourceId = "sports-4", displayIds = { "tv-06" } }, M)
eq("silent room: still accepted at dispatch", r.status, "accepted")
env.settle(2000)
eq("silent room: pending while waiting", env.cell("display", "tv-06", "source").status, "pending")
env.settle(6000)
local cell = env.cell("display", "tv-06", "source")
eq("silent room: failed after the confirmation window", cell.status, "failed")
eq("silent room: code", cell.errorCode, "VF_NOT_CONFIRMED")
eq("silent room: what was asked is kept", cell.requested, "sports-4")
check("silent room: never shows the unconfirmed source as the value", cell.value ~= "sports-4", cell.value)
op = env.operation(r.operationId)
eq("silent room: operation failed 1", op.summary.failed, 1)
env.sim():setFault(1106, nil)

-- failed: the room switched to something else.
env.sim():setFault(1107, "wrong")
r = env.send("ROUTE_VIDEO", { sourceId = "sports-4", displayIds = { "tv-07" } }, M)
env.settle(7000)
eq("wrong device: failed", env.cell("display", "tv-07", "source").status, "failed")
env.sim():setFault(1107, nil)

-- failed at dispatch: the room refuses the command.
env.sim():setFault(1108, "offline")
r = env.send("ROUTE_VIDEO", { sourceId = "sports-4", displayIds = { "tv-08" } }, M)
env.settle(1000)
eq("offline room: failed", env.cell("display", "tv-08", "source").status, "failed")
eq("offline room: code", env.cell("display", "tv-08", "source").errorCode, "VF_DEVICE_OFFLINE")
env.sim():setFault(1108, nil)

-- commanded: a display with no feedback (the projector on a custom command).
calls = env.sim():callCount()
r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-24" } }, M)
env.settle(1000)
cell = env.cell("display", "tv-24", "source")
eq("no-feedback display: commanded, never confirmed", cell.status, "commanded")
call = env.sim().calls[#env.sim().calls]
eq("custom route: the installer's command", call.command, "SET_INPUT")
eq("custom route: the installer's device", call.target, 2900)
eq("custom route: ${source} became the source's device id", call.params.INPUT, 3001)
eq("custom route: other parameters pass through", call.params.OUTPUT, 24)
op = env.operation(r.operationId)
eq("no-feedback: operation commanded 1", op.summary.commanded, 1)
eq("no-feedback: not counted as confirmed", op.summary.confirmed, 0)

-- unknown: nothing read yet.
eq("a never-read cell is unknown", env.cell("display", "tv-24", "power").status, "unknown")

-- A failure carries an operator sentence and installer detail.
local diag = env.core.diag:list({ limit = 40, category = "routing" })
local sawDetail = false
for _, e in ipairs(diag) do
  if e.code == "VF_NOT_CONFIRMED" and type(e.data) == "table" and e.data.detail ~= nil then
    sawDetail = true
  end
end
check("diagnostics keep the installer detail of a failure", sawDetail)

-- ── conflicts: a newer request replaces an older one ────────────────────────
print("conflicting commands")
calls = env.sim():callCount()
local first = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-11", "tv-12", "tv-13" } }, M)
local second = env.send("ROUTE_VIDEO", { sourceId = "sports-2", displayIds = { "tv-12", "tv-13" } }, M)
env.settle(4000)
eq("tv-12 ends on the newer request", env.cell("display", "tv-12", "source").value, "sports-2")
eq("tv-12 confirmed", env.cell("display", "tv-12", "source").status, "confirmed")
eq("tv-11 keeps the first request", env.cell("display", "tv-11", "source").value, "sports-1")
local op1, op2 = env.operation(first.operationId), env.operation(second.operationId)
eq("first operation: two targets superseded", op1.summary.superseded, 2)
eq("first operation: one confirmed", op1.summary.confirmed, 1)
eq("second operation: two confirmed", op2.summary.confirmed, 2)
local sent = 0
for i = calls + 1, env.sim():callCount() do
  if env.sim().calls[i].target == 1112 then
    sent = sent + 1
  end
end
check("a superseded command that had not left yet is never sent", sent <= 2, sent)

-- The SAME source asked for twice is not a conflict: both requests end confirmed,
-- and only one command is needed while the first has not left yet.
calls = env.sim():callCount()
env.send("ROUTE_VIDEO", { sourceId = "sports-3", displayIds = { "tv-18", "tv-19" } }, M)
local a1 = env.send("ROUTE_VIDEO", { sourceId = "news", displayIds = { "tv-19" } }, M)
local a2 = env.send("ROUTE_VIDEO", { sourceId = "news", displayIds = { "tv-19" } }, M)
env.settle(4000)
eq("same value twice: the first request ends confirmed", env.operation(a1.operationId).summary.confirmed, 1)
eq("same value twice: so does the second", env.operation(a2.operationId).summary.confirmed, 1)
eq("same value twice: nothing is reported superseded", env.operation(a1.operationId).summary.superseded, 0)
eq("same value twice: the display shows it", env.cell("display", "tv-19", "source").value, "news")
local toRoom = 0
for i = calls + 1, env.sim():callCount() do
  if env.sim().calls[i].target == 1119 and env.sim().calls[i].params.deviceid == 3005 then
    toRoom = toRoom + 1
  end
end
eq("same value twice: one command to the room, not two", toRoom, 1)

-- A burst on one display leaves one confirmed value and no pending cell.
for _, src in ipairs({ "sports-1", "sports-2", "sports-3", "sports-4" }) do
  env.send("ROUTE_VIDEO", { sourceId = src, displayIds = { "tv-14" } }, M)
end
env.settle(4000)
eq("burst: last request wins", env.cell("display", "tv-14", "source").value, "sports-4")
eq("burst: confirmed", env.cell("display", "tv-14", "source").status, "confirmed")
eq("nothing is left waiting in the queue", env.core.queue:size(), 0)

-- ── passive feedback: someone used a Control4 remote ────────────────────────
print("feedback from outside VenueFlow")
env.sim():external(1115, { power = true, videoDevice = 3005 })
eq("an outside change is taken as confirmed state", env.cell("display", "tv-15", "source").value, "news")
env.sim():external(1115, { power = true, videoDevice = 4242 })
eq("an unknown outside device shows as no known source", env.cell("display", "tv-15", "source").value, nil)
eq("...still confirmed, not guessed", env.cell("display", "tv-15", "source").status, "confirmed")

-- ── display power ───────────────────────────────────────────────────────────
print("display power")
r = env.send("DISPLAY_POWER", { displayIds = { "tv-01", "tv-02" }, power = "off" }, M)
eq("power off accepted", r.status, "accepted")
env.settle(1500)
eq(
  "tv-01 off confirmed",
  env.cell("display", "tv-01", "power").value .. "/" .. env.cell("display", "tv-01", "power").status,
  "off/confirmed"
)
eq("an off display has no source", env.cell("display", "tv-01", "source").value, nil)
call = env.sim().calls[#env.sim().calls]
eq("room power off is ROOM_OFF", call.command, "ROOM_OFF")

r = env.send("DISPLAY_POWER", { displayIds = { "tv-01" }, power = "on" }, M)
env.settle(1500)
eq("power on brings back the source it last showed", env.cell("display", "tv-01", "source").value, "sports-3")
eq("power on confirmed", env.cell("display", "tv-01", "power").value, "on")

r = env.send("DISPLAY_POWER", { displayIds = { "tv-21" }, power = "on" }, M)
env.settle(1500)
eq(
  "a display that never showed anything powers on to its default source",
  env.cell("display", "tv-21", "source").value,
  "sports-1"
)

r = env.send("DISPLAY_POWER", { displayIds = { "tv-24" }, power = "on" }, M)
env.settle(800)
eq("device power: commanded (no feedback)", env.cell("display", "tv-24", "power").status, "commanded")
eq("device power: ON to the display device", env.sim().calls[#env.sim().calls].target, 2124)

r = env.send("DISPLAY_POWER", { displayIds = { "tv-01" }, power = "sideways" }, M)
eq("bad power value refused by the protocol", r.errorCode, "VF_INVALID_PAYLOAD")

-- QUERY_STATUS clears a stale failure with a fresh reading.
r = env.send("QUERY_STATUS", { displayIds = { "tv-06" } }, M)
eq("query status reads the room", r.results[1].status, "read")
eq("the stale failure is replaced by what Control4 reports", env.cell("display", "tv-06", "source").status, "confirmed")

T.done()

-- Logic Blocks: the draft, the sandbox, the app document and the relay
-- routes (src/logic/blockdraft.lua, sandbox.lua, appstate.lua, relay.lua).
--
-- Invariants:
--   * a draft changes nothing until it is applied, and applies whole or not
--     at all; an invalid draft leaves the live block exactly as it was;
--   * the sandbox cannot fire a live event, change live state or save, at
--     the OUTPUT boundary (not merely in the page's controls);
--   * the same sandbox steps always give the same timeline;
--   * the app document separates input / evaluation / event / confirmation
--     and never carries a token; the export is redacted and bounded;
--   * no relay route changes a block.
--
-- Run from the driver root: make test

package.path = "src/?.lua;test/?.lua;vendor/?.lua;" .. package.path
C4 = C4 or {}
require("c4_shim")
require("drivers-common-public.global.lib")
JSON = require("JSON")

local H = require("logic_blocks_harness")
local Blocks = require("logic.blocks")
local Defs = require("logic.blockdefs")
local Draft = require("logic.blockdraft")
local Sandbox = require("logic.sandbox")
local AppState = require("logic.appstate")
local Relay = require("logic.relay")

local c = H.checker()
local check = c.check

-- ── Draft ───────────────────────────────────────────────────────────────────

do
  local w = H.world()
  local b = Blocks.new(w.deps)
  local legacy = { good_night = { counter = 7 }, guest = { flag = true } }
  local draft = Draft.new(b, {
    legacy = {
      describe = function(text)
        return legacy[tostring(text):lower():gsub("[^%w]+", "_")]
      end,
    },
  })
  check("no draft: validate says how to start one", select(2, draft:validate())[1]:find("no draft") ~= nil)
  check("no draft: a field edit is ignored", draft:set("name", "x") == false)
  check("start needs a type", draft:start("", "x") == false)
  check("start a new draft", draft:start("Restartable Timer", "Bath") == true and draft:active())
  check("a draft creates nothing", b:counts().used == 0 and w.changed == 0)
  draft:set("duration", "soon")
  local ok, problems = draft:validate()
  check("an invalid draft is reported whole", not ok and problems[1]:find("Duration") ~= nil)
  check("applying an invalid draft does nothing", draft:apply() == false and b:counts().used == 0)
  draft:set("duration", "15m")
  ok, problems = draft:validate()
  check("a valid draft says what applying it does", ok and problems[1]:find("Creates Block 01") ~= nil)
  check("validation marks the draft ready", draft:describe():find("ready to apply") ~= nil)
  draft:set("tag", "Bathroom")
  check("any edit after a check un-checks it", draft:describe():find("not checked") ~= nil)
  local applied, slot = draft:apply()
  check(
    "apply creates the block in one step",
    applied and slot == 1 and b.blocks[1].name == "Bath" and b.blocks[1].tag == "Bathroom"
  )
  check("the draft is gone after apply", not draft:active())

  -- Editing: nothing reaches the live block until Apply.
  b:input(1, "start")
  w.advance(60)
  check(
    "edit loads the block's settings",
    draft:load(1) and draft.raw.duration == "15m" and draft.raw.repeat_start == "Restart the countdown"
  )
  draft:set("duration", "5m")
  draft:set("name", "Bath Fan")
  check(
    "editing a draft does not touch the live block",
    b.blocks[1].name == "Bath" and b.blocks[1].settings.duration_ms == 900000
  )
  check("the running countdown is untouched by the draft", b:outputs(1).active)
  ok, problems = draft:validate()
  local impact = table.concat(problems, " ")
  check(
    "validate previews the rename and the running countdown",
    ok and impact:find("Renames") ~= nil and impact:find("CANCELLED") ~= nil,
    impact
  )
  check("validate itself changes nothing", b.blocks[1].name == "Bath" and b:outputs(1).active)
  draft:set("duration", "never")
  check("an invalid edit is refused", draft:apply() == false)
  check(
    "and the live block keeps its last valid settings and its countdown",
    b.blocks[1].settings.duration_ms == 900000 and b:outputs(1).active
  )
  draft:set("duration", "5m")
  local id = b.blocks[1].id
  applied, slot = draft:apply()
  check(
    "a valid edit applies in one step",
    applied and slot == 1 and b.blocks[1].name == "Bath Fan" and b.blocks[1].settings.duration_ms == 300000
  )
  check("identity is kept across the edit", b.blocks[1].id == id)

  check("load refuses an empty slot", draft:load(9) == false)
  check(
    "a duplicate name is caught at validation",
    draft:start("Flag / Latch", "bath fan") and select(2, draft:validate())[1]:find("already named") ~= nil
  )
  draft:discard()

  -- Templates fill a draft only, and never map a device.
  local okT, template = draft:fromTemplate("Rack temperature (threshold with deadband)")
  check("a template fills a draft", okT and template.id == "rack_temperature" and draft.raw.upper == "85")
  check("a template creates no block", b:counts().used == 1)
  check(
    "a template maps no device",
    draft.raw.inputs[1].device_id == nil and draft.raw.inputs[1].label == "Rack temperature"
  )
  ok, problems = draft:validate()
  check(
    "its validation tells the dealer how the input is fed",
    ok and table.concat(problems, " "):find("BLOCK_INPUT") ~= nil
  )
  draft:setInput(1, "device_id", 82)
  check("a device without a variable is refused", draft:validate() == false)
  draft:setInput(1, "variable_id", 1000)
  draft:setInput(1, "device_name", "Rack Sensor")
  check("picking the dealer's device makes it valid", draft:validate() == true)
  check(
    "every template is itself a valid definition",
    (function()
      for _, t in ipairs(Defs.TEMPLATES) do
        if Defs.normalize(t.raw) == nil then
          return false
        end
      end
      return #Defs.TEMPLATES == 5
    end)()
  )
  draft:discard()

  -- Legacy keys: never adopted by name; adoption is explicit and previewed.
  draft:start("Counter", "Good Night")
  ok, problems = draft:validate()
  check(
    "a block named like a free-form key adopts nothing",
    ok and table.concat(problems, " "):find("adopts nothing") ~= nil
  )
  local _, plainSlot = draft:apply()
  check("and starts from zero", b:outputs(plainSlot).value == 0)
  draft:start("Counter", "Good Night Adopted")
  draft:set("adopt_legacy", "Good Night")
  ok, problems = draft:validate()
  check(
    "explicit adoption is previewed with the value",
    ok and table.concat(problems, " "):find('"Good Night" %(7%)') ~= nil,
    table.concat(problems, " ")
  )
  check("the preview says the free-form key is not deleted", table.concat(problems, " "):find("not deleted") ~= nil)
  w.clear()
  local _, adopted = draft:apply()
  check("adoption copies the value once, without firing", b:outputs(adopted).value == 7 and #w.fired == 0)
  draft:start("Flag / Latch", "Guest Block")
  draft:set("adopt_legacy", "nothing here")
  check("adopting a key that does not exist is refused", draft:validate() == false)
  draft:start("Cooldown", "No Adoption")
  draft:set("duration", "1m")
  draft:set("adopt_legacy", "guest")
  check(
    "adoption is refused for types where it means nothing",
    select(2, draft:validate())[1]:find("only to a Flag or a Counter") ~= nil
  )
  draft:load(1)
  draft:set("adopt_legacy", "guest")
  check("adoption is refused when editing an existing block", draft:validate() == false)
  check("the draft remembers only what it is for", draft:serialize().target == 1 and draft:serialize().type == "timer")
end

-- ── Sandbox ─────────────────────────────────────────────────────────────────

do
  local w = H.world({ variables = { ["82:1000"] = true } })
  local b = Blocks.new(w.deps)
  local cool = H.make(b, { type = "cooldown", name = "Driveway Welcome", duration = "10m" })
  local rack = H.make(b, {
    type = "threshold",
    name = "Rack",
    upper = "85",
    lower = "78",
    inputs = { { used = true, label = "Temp", device_id = 82, variable_id = 1000 } },
  })
  b:variable(82, 1000, "80")
  b:input(cool, "trigger")
  w.advance(60)
  local liveFired, liveChanged, liveWrites = #w.fired, w.changed, w.writes
  local liveHistory, liveTimers, liveWatched = #b.history, w.timerCount(), #w.watched
  local liveDoc = Blocks.fingerprint(b:serialize())

  local sb =
    assert(Sandbox.open({ def = Blocks.copy(b.blocks[cool]), slot = cool, now = w.t, localDay = w.deps.localDay }))
  sb:input("trigger")
  sb:advance(120)
  sb:input("trigger")
  sb:advance(600)
  sb:input("trigger")
  sb:input("reset")
  sb:advance(86400)
  local state = sb:state()
  local kinds = {}
  for _, e in ipairs(state.timeline) do
    kinds[#kinds + 1] = e.kind == "event" and ("E:" .. e.event) or e.decision
  end
  check(
    "sandbox: shows the decisions and the events that WOULD fire",
    table.concat(kinds, ",") == "passed,E:Block 01 Passed,suppressed,passed,E:Block 01 Passed,reset",
    table.concat(kinds, ",")
  )
  check("sandbox: time is simulated", state.elapsed == 120 + 600 + 86400 and state.simulated == true)
  check(
    "sandbox: the simulated block is labelled with the live slot",
    state.view.label == "Block 01" and state.view.name == "Driveway Welcome"
  )

  -- The isolation, at the live runtime's output boundary.
  check("sandbox: fired no live event", #w.fired == liveFired)
  check("sandbox: wrote no live variable", w.writes == liveWrites)
  check("sandbox: asked for nothing to be saved", w.changed == liveChanged)
  check("sandbox: added nothing to the live history", #b.history == liveHistory)
  check("sandbox: started no live timer", w.timerCount() == liveTimers)
  check("sandbox: started no live listener", #w.watched == liveWatched)
  check("sandbox: the live state document is byte-for-byte the same", Blocks.fingerprint(b:serialize()) == liveDoc)
  check("sandbox: the live block still has its own cooldown", b:outputs(cool).state == "cooling")
  check("sandbox: is built from plain data, not from the live runtime", sb.rt ~= b and sb.opts.def ~= b.blocks[cool])
  check("sandbox: its records are marked simulated", sb.rt.history[#sb.rt.history].origin == "sim")

  -- Deterministic replay.
  local function shape(timeline)
    local out = {}
    for _, e in ipairs(timeline) do
      out[#out + 1] = string.format("%s|%s|%s|%s", e.offset, e.kind, e.decision or e.event, e.reason or "")
    end
    return table.concat(out, "\n")
  end
  local before = shape(sb:state().timeline)
  sb:replay()
  check("sandbox: replaying the same steps gives the same timeline", shape(sb:state().timeline) == before)
  sb:replay()
  check("sandbox: and again", shape(sb:state().timeline) == before and #sb:state().steps == 7)
  sb:reset()
  check(
    "sandbox: reset returns to the start",
    sb:state().elapsed == 0 and #sb:state().steps == 0 and #sb:state().timeline == 0
  )
  sb:replay({
    { op = "input", command = "trigger" },
    { op = "advance", seconds = 601 },
    { op = "input", command = "trigger" },
  })
  check(
    "sandbox: a scripted scenario runs",
    (function()
      local n = 0
      for _, e in ipairs(sb:state().timeline) do
        if e.kind == "event" then
          n = n + 1
        end
      end
      return n == 2
    end)()
  )

  -- A mapped input is fed by hand; nothing is watched.
  local rs = assert(
    Sandbox.open({
      def = Blocks.copy(b.blocks[rack]),
      slot = rack,
      now = w.t,
      localDay = w.deps.localDay,
      sources = { [1] = "80" },
    })
  )
  check(
    "sandbox: starts from the source value the live block has",
    rs:state().view.sources[1].value == "80" and #rs:state().timeline == 1
  )
  rs:source(1, "90")
  rs:source(1, nil, true)
  rs:source(1, "70")
  local silent = rs:state().timeline[#rs:state().timeline]
  rs:source(1, "95")
  local events = {}
  for _, e in ipairs(rs:state().timeline) do
    if e.kind == "event" then
      events[#events + 1] = e.event_kind
    end
  end
  check(
    "sandbox: mapped inputs can be driven and made unreadable",
    table.concat(events, ",") == "became_true,faulted,became_true",
    table.concat(events, ",")
  )
  check(
    "sandbox: a source that comes back is read silently, exactly as live",
    silent.kind == "decision" and silent.decision == "baseline"
  )
  check("sandbox: driving a mapped input touched no live listener", #w.watched == liveWatched and #w.fired == liveFired)

  check("sandbox: a negative advance is refused", select(1, rs:advance(-5)) == false)
  rs:advance(10 * 86400 * 365)
  check("sandbox: one advance is bounded", rs:state().elapsed <= Sandbox.LIMITS.advance_s)
  for _ = 1, Sandbox.LIMITS.steps + 20 do
    rs:advance(1)
  end
  check("sandbox: remembered steps are bounded", #rs:state().steps == Sandbox.LIMITS.steps)
  check(
    "sandbox: refuses a definition that cannot be read",
    Sandbox.open({ def = { type = "nope" }, slot = 1, now = 0 }) == nil
  )
  check("sandbox: refuses nothing to copy", Sandbox.open({}) == nil)
end

-- ── App document ────────────────────────────────────────────────────────────

do
  local w = H.world({ variables = { ["82:1000"] = true, ["90:1"] = true } })
  local b = Blocks.new(w.deps)
  local empty = AppState.build(b, { now = w.t })
  check(
    "app document: an empty pack is a valid document",
    empty.schema == AppState.SCHEMA and #empty.blocks == 0 and empty.capacity.used == 0
  )
  check("app document: says where blocks are configured", empty.authority:find("Composer") ~= nil)
  check("app document: carries the recipes and the type reference", #empty.templates == 5 and #empty.types == 10)

  local cool =
    H.make(b, { type = "cooldown", name = "Driveway Welcome", tag = "Driveway", duration = "10m", notes = "scene 12" })
  local rack = H.make(b, {
    type = "threshold",
    name = "Rack",
    upper = "85",
    lower = "78",
    inputs = {
      {
        used = true,
        label = "Temp",
        device_id = 82,
        variable_id = 1000,
        device_name = "Rack Sensor",
        variable_name = "TEMP",
      },
    },
    feedback = { device_id = 90, variable_id = 1, expect = "1", within = "10s" },
  })
  local gone = H.make(b, {
    type = "stable",
    name = "Gone",
    duration = "5s",
    inputs = { { used = true, label = "Lost", device_id = 7, variable_id = 7 } },
  })
  b:variable(82, 1000, "80")
  b:variable(90, 1, "0")
  w.advance(5)
  b:input(cool, "trigger")
  b:input(cool, "trigger")
  w.advance(30)
  b:variable(82, 1000, "90")
  w.advance(2)
  b:variable(90, 1, "1")
  local doc = AppState.build(b, {
    now = w.t,
    version = "20261121.000000",
    pack_status = "active",
    license = { status = "Licensed / Subscribed", source = "Included with subscription", tier = "Professional" },
  })
  check(
    "app document: lists the blocks in slot order",
    #doc.blocks == 3 and doc.blocks[1].slot == cool and doc.blocks[2].slot == rack
  )
  local view = doc.blocks[1]
  check(
    "app document: a plain-English explanation",
    view.explanation:find("suppresses every repeat for 10 minutes") ~= nil
  )
  check(
    "app document: last accepted and last suppressed are separate",
    view.last_accepted.decision == "passed" and view.last_suppressed.decision == "suppressed"
  )
  check("app document: the next eligible time", view.deadline ~= nil and view.deadline.what == "is eligible again")
  check(
    "app document: wiring names the exact command and event",
    view.wiring.inputs[1].command == "BLOCK_TRIGGER"
      and view.wiring.outputs[1].event == "Block 01 Passed"
      and view.wiring.outputs[1].id == 1011
  )
  local src = doc.blocks[2].sources[1]
  check(
    "app document: a source shows its device, value, validity and its own timestamp",
    src.device_id == 82
      and src.variable_id == 1000
      and src.value == "90"
      and src.status == "ok"
      and src.observed_at == w.t - 2
  )
  check(
    "app document: timestamps are per fact, not one for the page",
    view.last_accepted.at ~= src.observed_at and doc.generated_at == w.t
  )
  check("app document: a mapped input needs no command in its wiring", #doc.blocks[2].wiring.inputs == 0)
  check(
    "app document: missing mappings are listed",
    #doc.diagnostics.missing_mappings == 1 and doc.diagnostics.missing_mappings[1].name == "Gone"
  )
  check("app document: blocks needing attention are counted", doc.faults == 1)

  local passed, became
  for _, e in ipairs(doc.activity) do
    if e.decision == "passed" and passed == nil then
      passed = e
    end
    if e.decision == "became_true" then
      became = e
    end
  end
  check(
    "activity: input, decision and event are separate fields",
    passed.input == "Trigger" and passed.decision == "passed" and passed.events[1] == "passed"
  )
  check("activity: with no feedback mapped, confirmation is 'not monitored'", passed.confirmed == "not_monitored")
  check("activity: with feedback mapped and reported, it is confirmed", became.confirmed == "confirmed")
  check(
    "activity: an emitted event alone is never 'confirmed'",
    (function()
      for _, e in ipairs(doc.activity) do
        if e.confirmed == "confirmed" and e.slot ~= rack then
          return false
        end
      end
      return true
    end)()
  )
  check(
    "activity: records carry their origin and a run id",
    passed.origin == "live" and tostring(passed.run):find("^r%d+$") ~= nil
  )
  check("activity: newest first", doc.activity[1].seq > doc.activity[#doc.activity].seq)
  local filtered = AppState.activity(b, { slot = tostring(cool), decision = "suppressed" })
  check(
    "activity: filter by block and decision",
    #filtered.activity == 1 and filtered.activity[1].decision == "suppressed"
  )
  check("activity: filter by time", #AppState.activity(b, { since = tostring(w.t - 1) }).activity < #doc.activity)
  check("activity: the page is bounded", #AppState.activity(b, { limit = "100000" }).activity <= Blocks.LIMITS.history)

  -- Nothing secret, anywhere.
  local encoded = JSON:encode(doc)
  check("app document: encodes", type(encoded) == "string" and #encoded > 1000)
  check("app document: is small enough to send", #encoded < 96 * 1024, #encoded)
  local exported = AppState.export(b, {
    now = w.t,
    license = { status = "Licensed", source = "x", tier = "y", company = "Secret Co" },
    transport = { host = "192.168.1.20", url = "http://192.168.1.20:47871/app?k=abcdef0123456789abcdef0123456789" },
    relay_token = "abcdef0123456789abcdef0123456789",
  })
  local text = JSON:encode(exported)
  check("export: the relay token is not in it", text:find("abcdef0123456789abcdef0123456789", 1, true) == nil)
  check("export: a token riding a URL is blanked", text:find("k=%[redacted%]") ~= nil)
  check("export: the licensed company is left out", text:find("Secret Co", 1, true) == nil)
  check("export: dealer notes are left out", text:find("scene 12", 1, true) == nil)
  check(
    "export: keeps what support needs",
    exported.blocks[1].name == "Driveway Welcome" and #exported.activity > 0 and exported.diagnostics ~= nil
  )
  check("export: is bounded", #exported.activity <= AppState.EXPORT_ACTIVITY and #text < 256 * 1024)
  check(
    "redact: sensitive keys",
    AppState.redact({ token = "x", Authorization = "y", ok = "z" }).token == "[redacted]"
      and AppState.redact({ Authorization = "y" }).Authorization == "[redacted]"
  )
  check(
    "redact: bearer text and long hex runs",
    AppState.redact("Bearer abc.def") == "Bearer [redacted]"
      and AppState.redact("id 0123456789abcdef0123456789abcdef") == "id [redacted]"
  )
  check(
    "redact: ordinary text is left alone",
    AppState.redact("Rack reading 90 at 16:04") == "Rack reading 90 at 16:04"
  )

  local summary = AppState.summary(b, { now = w.t, version = "1" })
  local summaryText = JSON:encode(summary)
  check(
    "cloud summary: names, types and health only",
    summary.blocks[1].name == "Driveway Welcome" and summary.blocks[2].state == "active"
  )
  check(
    "cloud summary: no source values, no history, no notes",
    summaryText:find('"sources"', 1, true) == nil
      and summaryText:find("scene 12", 1, true) == nil
      and summaryText:find('"activity"', 1, true) == nil
  )
  check("cloud summary: small", #summaryText < 8 * 1024)
  local _ = gone
end

-- ── Relay routes ────────────────────────────────────────────────────────────

do
  local TOKEN = "tok0123456789abcdef0123456789abc"
  local calls = {}
  local provider = {
    appHtml = function()
      return "<html>page</html>"
    end,
    state = function()
      return { schema = "x" }
    end,
    activity = function(query)
      return { activity = {}, slot = query.slot }
    end,
    export = function()
      return { exported = true }
    end,
    sandbox = function(op, body)
      calls[#calls + 1] = { op = op, body = body }
      if op == "advance" and body.seconds == nil then
        return { ok = false, error = "seconds must be 0 or more" }
      end
      return { ok = true, open = op ~= "close" }
    end,
    encode = function(t)
      return JSON:encode(t)
    end,
    decode = function(s)
      return JSON:decode(s)
    end,
  }
  local function req(method, path, k, body, query)
    query = query or {}
    query.k = k
    return Relay.route({ method = method, path = path, query = query, body = body or "" }, TOKEN, provider)
  end
  check(
    "relay: /ping needs no token and names the service",
    req("GET", "/ping").body == '{"ok":true,"service":"logic-blocks"}'
  )
  check(
    "relay: /app needs no token and holds no data",
    req("GET", "/app").status == "200 OK" and req("GET", "/app").contentType:find("text/html") ~= nil
  )
  check("relay: /state without a token is refused", req("GET", "/state").status == "403 Forbidden")
  check("relay: /state with a wrong token is refused", req("GET", "/state", "wrong").status == "403 Forbidden")
  check(
    "relay: an empty configured token refuses everything",
    Relay.route({ method = "GET", path = "/state", query = { k = "" }, body = "" }, "", provider).status
      == "403 Forbidden"
  )
  check("relay: /state with the token answers", req("GET", "/state", TOKEN).status == "200 OK")
  check(
    "relay: no answer ever contains the token",
    req("GET", "/state", TOKEN).body:find(TOKEN, 1, true) == nil
      and req("GET", "/state", "wrong").body:find(TOKEN, 1, true) == nil
  )
  check(
    "relay: /activity passes its filters",
    JSON:decode(req("GET", "/activity", TOKEN, nil, { slot = "3" }).body).slot == "3"
  )
  check("relay: /export answers", JSON:decode(req("GET", "/export", TOKEN).body).exported == true)
  check("relay: a malformed request is 400", req("BAD", "/").status == "400 Bad Request")
  check("relay: a preflight is answered before the token wall", req("OPTIONS", "/state").status == "204 No Content")

  check(
    "relay: sandbox open is routed with its body",
    req("POST", "/sandbox/open", TOKEN, '{"slot":3}').status == "200 OK"
      and calls[#calls].op == "open"
      and calls[#calls].body.slot == 3
  )
  check(
    "relay: a refused sandbox step is 422 with the reason",
    req("POST", "/sandbox/advance", TOKEN, "{}").status == "422 Unprocessable Entity"
  )
  check(
    "relay: a sandbox body that is not JSON is 400",
    req("POST", "/sandbox/input", TOKEN, "not json").status == "400 Bad Request"
  )
  check(
    "relay: sandbox writes need the token",
    req("POST", "/sandbox/open", "wrong", '{"slot":3}').status == "403 Forbidden"
  )
  check("relay: reading the sandbox", req("GET", "/sandbox", TOKEN).status == "200 OK" and calls[#calls].op == nil)
  check(
    "relay: a sandbox write route refuses GET",
    req("GET", "/sandbox/open", TOKEN).status == "405 Method Not Allowed"
  )
  check("relay: a read route refuses POST", req("POST", "/state", TOKEN, "{}").status == "405 Method Not Allowed")

  -- There is no route that configures a block.
  local before = #calls
  local none = true
  for _, path in ipairs({
    "/block",
    "/blocks",
    "/config",
    "/configure",
    "/settings",
    "/apply",
    "/draft",
    "/create",
    "/retire",
    "/enable",
    "/disable",
    "/rename",
    "/command",
    "/input",
    "/trigger",
    "/set",
    "/state/apply",
    "/sandbox/apply",
    "/sandbox/live",
    "/export/import",
    "/restore",
    "/reset",
  }) do
    for _, method in ipairs({ "POST", "PUT", "PATCH", "DELETE" }) do
      local answer = req(method, path, TOKEN, '{"slot":1,"name":"x","enabled":false}')
      if answer.status ~= "404 Not Found" and answer.status ~= "405 Method Not Allowed" then
        none = false
        print("    unexpected", method, path, answer.status)
      end
    end
  end
  check("relay: no route configures, commands or resets a block", none and #calls == before)
  check(
    "relay: PUT and DELETE are refused even on real paths",
    req("PUT", "/sandbox/open", TOKEN, "{}").status == "405 Method Not Allowed"
      and req("DELETE", "/state", TOKEN).status == "405 Method Not Allowed"
  )
end

c.finish()

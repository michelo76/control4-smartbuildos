--- Shared harness for the VenueFlow suites: a fake clock with named timers, an
--- in-memory key-value store, and a core wired to the simulator. Everything a
--- suite "verifies" through this harness is SIMULATION-verified: the adapter
--- is src/venueflow/sim.lua, never a controller.

-- The vendored JSON encoder calls this global, which the driver gets from
-- drivers-common-public.global.lib. Same behaviour, without needing Control4.
tostring_return_period = tostring_return_period
  or function(v)
    local s = tostring(v)
    if type(v) == "number" then
      s = s:gsub(",", ".")
    end
    return s
  end

local Core = require("venueflow.core")
local Templates = require("venueflow.templates")
local JSON = require("JSON")

local H = {}

--- A tiny check counter in the style of the repository's other suites.
function H.checker()
  local t = { pass = 0, fail = 0 }
  function t.check(name, ok, detail)
    if ok then
      t.pass = t.pass + 1
      print(string.format("  ok   %s", name))
    else
      t.fail = t.fail + 1
      print(string.format("  FAIL %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or ""))
    end
  end
  function t.eq(name, got, want)
    t.check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
  end
  function t.done()
    print(string.format("\n%d passed, %d failed", t.pass, t.fail))
    if t.fail > 0 then
      os.exit(1)
    end
  end
  return t
end

--- Deterministic stand-in for C4:HMAC: same inputs give the same hex,
--- different inputs a different one.
function H.hmac(key, data)
  local acc = 5381
  local input = tostring(key) .. "\1" .. tostring(data)
  for i = 1, #input do
    acc = (acc * 33 + input:byte(i)) % 0xFFFFFFFF
  end
  local acc2 = 7919
  for i = #input, 1, -1 do
    acc2 = (acc2 * 31 + input:byte(i)) % 0xFFFFFFFF
  end
  return string.format("%08x%08x", acc, acc2):rep(4)
end

--- 2026-11-09 was a Monday. Epochs are treated as UTC wall time unless a
--- suite supplies its own localtime (the daylight-saving tests do).
H.MONDAY_NOON = 1794225600 -- 2026-11-09 12:00:00 UTC

function H.clock(start)
  local c = { nowMs = 0, base = start or H.MONDAY_NOON, timers = {} }
  c.api = {
    set = function(id, ms, fn, repeating)
      c.timers[id] = { at = c.nowMs + ms, fn = fn, every = repeating and ms or nil }
    end,
    cancel = function(id)
      c.timers[id] = nil
    end,
  }
  function c.now()
    return c.base + math.floor(c.nowMs / 1000)
  end
  function c.advance(ms)
    local target = c.nowMs + ms
    while true do
      local bestId, bestAt
      for id, t in pairs(c.timers) do
        if
          t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId)))
        then
          bestId, bestAt = id, t.at
        end
      end
      if bestId == nil then
        break
      end
      c.nowMs = bestAt
      local t = c.timers[bestId]
      if t.every then
        t.at = c.nowMs + t.every
      else
        c.timers[bestId] = nil
      end
      t.fn()
    end
    c.nowMs = target
  end
  return c
end

function H.kv(store)
  store = store or {}
  local function copy(v)
    if type(v) ~= "table" then
      return v
    end
    local out = {}
    for k, x in pairs(v) do
      out[k] = copy(x)
    end
    return out
  end
  return {
    data = store,
    get = function(key)
      return copy(store[key])
    end,
    set = function(key, value)
      store[key] = copy(value)
    end,
    delete = function(key)
      store[key] = nil
    end,
  }
end

--- opts = { kv?, clock?, mode?, passcode?, license?, localtime?, spacingMs?, latencyMs?, confirmMs? }
--- Returns an environment: { core, clock, kv, events, variables, records, send(...), ... }
function H.new(opts)
  opts = opts or {}
  local env = {}
  env.clock = opts.clock or H.clock(opts.start)
  env.kv = opts.kv or H.kv()
  env.events, env.variables, env.records = {}, {}, {}
  env.mode = opts.mode or "simulation"
  env.passcode = opts.passcode == nil and "install-123" or opts.passcode
  env.license = opts.license or { enforce = false, label = "Licensed / Subscribed" }
  local seq = 0
  env.core = Core.new({
    kv = env.kv,
    now = env.clock.now,
    localtime = opts.localtime or function(epoch)
      return os.date("!*t", epoch)
    end,
    timers = env.clock.api,
    json = {
      encode = function(t)
        return JSON:encode(t)
      end,
      decode = function(s)
        return JSON:decode(s)
      end,
    },
    hmac = H.hmac,
    random = function()
      seq = seq + 1
      return H.hmac("random", tostring(seq) .. ":" .. tostring(env.clock.nowMs))
    end,
    liveAdapter = opts.liveAdapter or function()
      error("the harness has no live adapter")
    end,
    mode = function()
      return env.mode
    end,
    license = {
      enforces = function()
        return env.license.enforce == true
      end,
      label = function()
        return env.license.label
      end,
      describe = function()
        return { status = env.license.enforce and "NOT_ENTITLED" or "AUTHORIZED_SUBSCRIPTION" }
      end,
      refresh = function() end,
    },
    passcode = function()
      return env.passcode
    end,
    fireEvent = function(key)
      env.events[#env.events + 1] = key
    end,
    setVariable = function(name, value)
      env.variables[name] = value
    end,
    record = function(name, detail)
      env.records[#env.records + 1] = { name = name, detail = detail }
    end,
    version = "test",
    queueSpacingMs = opts.spacingMs or 50,
    simLatencyMs = opts.latencyMs or 300,
    confirmMs = opts.confirmMs or 5000,
  })
  local reqSeq = 0
  --- Sends one protocol request. o = { session?, tile?, client?, since? }
  function env.send(command, payload, o)
    o = o or {}
    reqSeq = reqSeq + 1
    return env.core:handle({
      requestId = "t-" .. reqSeq,
      command = command,
      payload = payload,
      ts = env.clock.now(),
      session = o.session,
      since = o.since,
    }, { tile = o.tile == true, client = o.client or "10.0.0.50", via = "relay" })
  end
  function env.studio()
    local r = env.send("STUDIO_LOGIN", { passcode = env.passcode })
    assert(r.ok, "studio login failed: " .. tostring(r.errorCode))
    return r.data.session
  end
  function env.login(profileId, pin)
    local r = env.send("PROFILE_LOGIN", { profileId = profileId, pin = pin })
    return r.ok and r.data.session or nil, r
  end
  --- Loads a reference venue into the draft and publishes it.
  function env.publishSample(which)
    local studio = env.studio()
    local r = env.send(
      "TEMPLATE_APPLY",
      { venueType = which or "sports_bar", sample = true, confirm = true },
      { session = studio }
    )
    assert(r.ok, "template failed: " .. tostring(r.errorCode) .. " " .. tostring(r.detail))
    local acks = {}
    for _, i in ipairs(r.data.draft.issues) do
      acks[#acks + 1] = i.id
    end
    local p = env.send("PUBLISH", { acknowledged = acks, note = "reference venue" }, { session = studio })
    assert(p.ok, "publish failed: " .. tostring(p.errorCode) .. " " .. tostring(p.detail))
    env.clock.advance(1000)
    return studio
  end
  function env.settle(ms)
    env.clock.advance(ms or 2000)
  end
  function env.cell(kind, id, field)
    return env.core.state:cell(kind, id, field)
  end
  function env.sim()
    return env.core.sim
  end
  function env.operation(id)
    return env.core.tracker:find(id)
  end
  env.core:start()
  return env
end

H.Templates = Templates
H.JSON = JSON

return H

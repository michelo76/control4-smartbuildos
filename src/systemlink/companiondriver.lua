--- The common half of every System Link companion driver: lifecycle,
--- properties, freshness → events/conditionals, the Linked Export list and
--- the desired-versus-confirmed bookkeeping. A companion driver supplies
--- the proxy mapping (apply state → proxy notifies; proxy commands → ops).
---
--- Usage from drivers/smartbuildos-system-link-<kind>/driver.lua:
---   local base = require("systemlink.companiondriver")
---   base.install({
---     kind = "light",
---     logName = "SystemLinkLight",
---     applyState = function(fields, fresh, meta) … end,   -- fields: { suffix = value|JSON.null }
---     describeState = function(fields) return "On 40%" end,
---   })
--- and then define the RFP.* handlers calling base.control(op, params).

local log = require("lib.logging")
local companion = require("systemlink.companion")

local M = {}

local EVENT_CURRENT, EVENT_STALE, EVENT_REFUSED = 1, 2, 3
local state = { opts = {}, wasCurrent = nil, requested = nil, lastFields = nil }

local function fire(id)
  pcall(function()
    C4:FireEventByID(id)
  end)
end

local function paintList(list)
  local names = { "-" }
  for _, e in ipairs(list or {}) do
    names[#names + 1] = e.name
  end
  pcall(function()
    C4:UpdatePropertyList("Linked Export", table.concat(names, ","), companion.export() or "-")
  end)
end

function M.isCurrent()
  return companion.fresh() == "current"
end

function M.fields()
  return state.lastFields or {}
end

--- Sends a control request and records the desired state separately from
--- the confirmed state (which only the owner's feedback updates).
--- The owner's control window, as last pushed: text and whether it is open
--- now (the owner's own verdict, from its own clock). nil = no schedule.
local function windowState()
  local fields = state.lastFields or {}
  local open = fields.Window
  if open == JSON.null then
    open = nil
  end
  return state.window, open
end

function M.control(op, params, requestedText)
  if not companion.export() then
    UpdateProperty("Last Result", "no export selected")
    return false
  end
  local text, open = windowState()
  if open == false then
    -- Refused here, with the window shown, instead of a round trip that
    -- comes back "outside the permitted schedule".
    UpdateProperty("Last Result", "refused: outside the control window (" .. tostring(text or "schedule") .. ")")
    fire(EVENT_REFUSED)
    return false
  end
  state.requested = { op = op, params = params, at = os.time() }
  UpdateProperty("Requested State", tostring(requestedText or op) .. " at " .. os.date("%H:%M:%S"))
  UpdateProperty("Last Result", "sent")
  return companion.control(op, params)
end

function M.install(opts)
  state.opts = opts or {}
  companion.setup({
    kind = opts.kind,
    onExports = paintList,
    onState = function(fields, fresh, meta)
      state.lastFields = fields
      UpdateProperty("Freshness", fresh)
      UpdateProperty("Remote System State", tostring(meta.remote_state or "Offline"))
      UpdateProperty("Control", meta.control and "control permitted" or "view only / suspended")
      state.window = meta.window ~= "" and meta.window or nil
      local open = fields.Window
      if open == JSON.null then
        open = nil
      end
      UpdateProperty(
        "Control Window",
        state.window and (state.window .. (open == false and " — closed now" or open == true and " — open now" or "")) or "none"
      )
      UpdateProperty("Bridge Link", "Connected to bridge " .. tostring(companion.findBridge() or "?"))
      local current = fresh == "current"
      if state.wasCurrent ~= current then
        if state.wasCurrent ~= nil then
          fire(current and EVENT_CURRENT or EVENT_STALE)
        end
        state.wasCurrent = current
      end
      if opts.applyState then
        pcall(opts.applyState, fields, fresh, meta)
      end
      if opts.describeState then
        local ok, text = pcall(opts.describeState, fields)
        UpdateProperty("Confirmed State", ok and tostring(text) or "?")
      end
    end,
    onResult = function(op, status, reason)
      UpdateProperty("Last Result", status .. (reason ~= "" and (": " .. reason) or ""))
      if status == "failed" then
        fire(EVENT_REFUSED)
      end
    end,
  })

  EC.SBOS_LINK_COMPANION_ASSIGN = function(tParams)
    local name = tostring((tParams or {}).export or "")
    if name ~= "" then
      UpdateProperty("Linked Export", name)
      companion.selectExport(name)
    end
  end
  EC.REFRESH_FROM_BRIDGE = function()
    companion.hello()
  end
  EC.PRINT_DIAGNOSTICS = function()
    log:print("== %s diagnostics ==", opts.logName or "System Link companion")
    log:print("  bridge: %s", tostring(companion.findBridge() or "NOT FOUND"))
    log:print("  export: %s  fresh: %s", tostring(companion.export()), companion.fresh())
    for k, v in pairs(state.lastFields or {}) do
      log:print("  %s = %s", tostring(k), tostring(v))
    end
    if state.requested then
      log:print(
        "  requested: %s at %s (confirmed state is separate)",
        tostring(state.requested.op),
        os.date("%H:%M:%S", state.requested.at)
      )
    end
  end
  TC.REMOTE_CURRENT = function()
    return M.isCurrent()
  end
  OPC.Linked_Export = function(value)
    if gInitialized then
      companion.selectExport(value)
    end
  end
  OPC.Log_Level = function(value)
    log:setLogLevel(value)
  end
  OPC.Log_Mode = function(value)
    log:setLogMode(value)
  end

  function OnDriverInit()
    --#ifdef DRIVERCENTRAL
    require("cloud-client-byte")
    C4:AllowExecute(false)
    --#else
    C4:AllowExecute(true)
    --#endif
    gInitialized = false
    log:setLogName(opts.logName or "SystemLinkCompanion")
    log:setLogLevel(Properties["Log Level"])
    log:setLogMode(Properties["Log Mode"])
  end

  function OnDriverLateInit()
    if not CheckMinimumVersion("Driver Status") then
      return
    end
    for p, _ in pairs(Properties) do
      pcall(OnPropertyChanged, p)
    end
    if opts.onLateInit then
      pcall(opts.onLateInit)
    end
    gInitialized = true
    UpdateProperty("Driver Status", "Online")
    pcall(function()
      UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
    end)
    local stored = companion.export()
    if stored then
      UpdateProperty("Linked Export", stored)
    end
    companion.hello()
    companion.armRetry()
  end

  function OnDriverDestroyed()
    companion.cancelRetry()
  end
end

function M._reset()
  state = { opts = {}, wasCurrent = nil, requested = nil, lastFields = nil }
  companion._reset()
end

return M

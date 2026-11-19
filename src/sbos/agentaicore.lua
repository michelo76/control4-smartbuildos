--- The SmartBuildOS Agent's own read-only "AI Core" Composer property
--- (conductor ruling 20), derived from the Agent's module registry
--- (sbos.modules). The Agent is the bus hub and sends no reports, so it
--- never says "reporting"; it says what its registry knows about the
--- `ai_core` module, with values from sbos.aivalues only:
---
---   Searching…                              the registry is not loaded yet
---   Not installed                           no `ai_core` registration
---   Found — not responding                  the best `ai_core` row is stale
---   Found — AI Core update required (v‹ver›) it registered at protocol 1, or
---                                           its manifest lacks
---                                           ai_core.report v1
---   Found — not licensed (v‹ver›)            its own status is `unlicensed`
---   Installed — this driver does not report AI Core is registered and live
---
--- The row is chosen as sbos.aireport chooses it: live first, protocol 2
--- first, verified first. Whether that row is verified (identity binding)
--- does not change the value: no closed value says it, and the heartbeat
--- and the directory carry `verified` already.
---
--- Called from the Agent's existing hooks (module services start, every
--- directory change, every module status frame); the Agent's main chunk
--- holds no new local for it. Nothing here has run on a physical controller.

local values = require("sbos.aivalues")

local M = {}

M.AI_CORE_MODULE = "ai_core"
M.CAPABILITY = "ai_core.report"
M.CAPABILITY_VERSION = 1

local S = { value = nil, values_refused = 0, property = values.PROPERTY }

local function hasReportCap(entry)
  local manifest = type(entry.manifest) == "table" and entry.manifest or {}
  for _, c in ipairs(type(manifest.capabilities) == "table" and manifest.capabilities or {}) do
    if
      type(c) == "table"
      and c.id == M.CAPABILITY
      and (tonumber(c.version) or 0) >= M.CAPABILITY_VERSION
      and (c.kind == nil or c.kind == "request")
    then
      return true
    end
  end
  return false
end

--- The `ai_core` entry the value describes (nil when none), and its stale flag.
local function pick(registry)
  local best, bestScore, bestStale = nil, -1, nil
  for _, e in ipairs(registry:list()) do
    if e.module_id == M.AI_CORE_MODULE then
      local stale = registry:isStale(e)
      local score = 0
      if not stale then
        score = score + 4
      end
      if (tonumber(e.protocol) or 1) >= 2 then
        score = score + 2
      end
      if e.verified == true then
        score = score + 1
      end
      if score > bestScore then
        best, bestScore, bestStale = e, score, stale
      end
    end
  end
  return best, bestStale
end

--- The closed value for a registry (sbos.modules Registry, or nil).
function M.computeValue(registry)
  if type(registry) ~= "table" or type(registry.list) ~= "function" then
    return values.V.searching
  end
  local e, stale = pick(registry)
  if e == nil then
    return values.V.not_installed
  end
  if stale then
    return values.V.not_responding
  end
  local ver = values.validVersion(e.driver_version) and e.driver_version or "unknown"
  if (tonumber(e.protocol) or 1) < 2 or not hasReportCap(e) then
    return string.format(values.V.ai_update, ver)
  end
  if e.status == "unlicensed" then
    return string.format(values.V.unlicensed, ver)
  end
  return values.V.no_report
end

local function paint(text)
  if not values.isValue(text) then
    S.values_refused = S.values_refused + 1
    return false
  end
  if S.value == text then
    return true
  end
  S.value = text
  if type(Properties) == "table" and Properties[S.property] ~= nil and type(UpdateProperty) == "function" then
    pcall(UpdateProperty, S.property, text)
  end
  return true
end
M._paint = paint

--- Repaints the property from the registry. Never raises.
function M.refresh(registry)
  local ok, text = pcall(M.computeValue, registry)
  return paint(ok and text or values.V.searching)
end

function M.value()
  return S.value
end

function M.valuesRefused()
  return S.values_refused
end

--- Tests only.
function M._reset()
  S = { value = nil, values_refused = 0, property = values.PROPERTY }
end

return M

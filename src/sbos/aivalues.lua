--- The closed value list of the read-only "AI Core" Composer property, in ONE
--- place (conductor ruling 20). Three modules paint that property and each
--- requires this one and paints nothing else:
---   sbos.aireport    root drivers that report (start / attach)
---   sbos.aipresence  child drivers, and a root that does not report now
---   sbos.agentaicore the SmartBuildOS Agent, from its own module registry
--- A test (test/test_sbos_aivalues.lua) fails if any of them can paint a
--- value this module does not hold, or carries a value as a literal.
---
--- Kept tiny on purpose: a child driver carries it (no bus, no JSON).

local M = {}

M.PROPERTY = "AI Core"
M.AI_CORE_FILE = "smartbuildos-ai-core.c4z"

M.V = {
  searching = "Searching…",
  no_agent = "SmartBuildOS Agent not found",
  agent_update = "SmartBuildOS Agent update required",
  registry_full = "Not registered — Agent module list full",
  not_installed = "Not installed",
  not_responding = "Found — not responding",
  ai_update = "Found — AI Core update required (v%s)",
  unlicensed = "Found — not licensed (v%s)",
  unpaired = "Found — SmartBuildOS Agent not paired (v%s)",
  cloud_offline = "Found — reporting, cloud offline (v%s)",
  reporting = "Found — reporting (v%s)",
  passive_installed = "Installed — reports through %s",
  no_report = "Installed — this driver does not report",
  -- Agent only (sbos.agentaicore): a live AI Core, by identity binding.
  registered = "Found — registered (v%s)",
  unverified = "Found — not verified (v%s)",
}

--- In spec order (§3.6), then the one value ruling 20 added, then the two
--- values only the Agent paints (a live AI Core it verified / could not
--- verify; sbos.aireport and sbos.aipresence never use them).
M.VALUES = {
  M.V.searching,
  M.V.no_agent,
  M.V.agent_update,
  M.V.registry_full,
  M.V.not_installed,
  M.V.not_responding,
  M.V.ai_update,
  M.V.unlicensed,
  M.V.unpaired,
  M.V.cloud_offline,
  M.V.reporting,
  M.V.passive_installed,
  M.V.no_report,
  M.V.registered,
  M.V.unverified,
}

--- Display name of every driver a child can report through (its driver.xml
--- <name>): the slot of "Installed — reports through ‹root›", and the
--- describe name fallback of a root. The Agent is listed because
--- smartbuildos-insights is its child (and shows no_report, not this).
M.LABELS = {
  ["smartbuildos.c4z"] = "SmartBuildOS Agent",
  ["smartbuildos-ai-core.c4z"] = "SmartBuildOS AI Core",
  ["smartbuildos-flight-recorder.c4z"] = "SmartBuildOS Flight Recorder",
  ["smartbuildos-usage-analytics.c4z"] = "SmartBuildOS Usage Analytics",
  ["smartbuildos-mqtt-broker.c4z"] = "SmartBuildOS MQTT Broker",
  ["smartbuildos-venueflow.c4z"] = "SmartBuildOS VenueFlow",
  ["smartbuildos-pin-lock.c4z"] = "SmartBuildOS PIN Lock",
  ["smartbuildos-atmosphere.c4z"] = "SmartBuildOS Atmosphere",
  ["smartbuildos-mode-composer.c4z"] = "SmartBuildOS Mode Composer",
  ["bond-bridge.c4z"] = "Bond Bridge Gateway (SBOS)",
  ["smartbuildos-commissioning.c4z"] = "SmartBuildOS Commissioning Matrix",
  ["smartbuildos-daypart.c4z"] = "SmartBuildOS Daypart Scheduler",
  ["smartbuildos-dealer-panel.c4z"] = "SmartBuildOS Dealer Settings",
  ["smartbuildos-guest-mode.c4z"] = "SmartBuildOS Guest Mode",
  ["smartbuildos-load-shedding.c4z"] = "SmartBuildOS Load Shedding",
  ["smartbuildos-logic-pack.c4z"] = "SmartBuildOS Logic Pack",
  ["smartbuildos-notification-router.c4z"] = "SmartBuildOS Notification Router",
  ["smartbuildos-solar.c4z"] = "SmartBuildOS Solar Position",
  ["smartbuildos-system-link.c4z"] = "SmartBuildOS System Link",
  ["smartbuildos-user-manual.c4z"] = "SmartBuildOS Home Guide",
  ["smartbuildos-variable-inspector.c4z"] = "SmartBuildOS Variable Inspector",
  ["unifi-protect.c4z"] = "UniFi Protect Gateway (SBOS)",
}

local function validVersion(s)
  return type(s) == "string" and #s >= 1 and #s <= 32 and s:match("^[%w%._%-]+$") ~= nil
end
M.validVersion = validVersion

local function rootLabelAllowed(label)
  for _, l in pairs(M.LABELS) do
    if l == label then
      return true
    end
  end
  return false
end

--- Whether `text` is one of the closed values (a template is matched with
--- its slot: a bounded version, or a root label from LABELS).
function M.isValue(text)
  if type(text) ~= "string" then
    return false
  end
  for _, v in ipairs(M.VALUES) do
    local at = v:find("%s", 1, true)
    if at == nil then
      if text == v then
        return true
      end
    else
      local head, tail = v:sub(1, at - 1), v:sub(at + 2)
      if #text > #head + #tail and text:sub(1, #head) == head and text:sub(#text - #tail + 1) == tail then
        local slot = text:sub(#head + 1, #text - #tail)
        if v == M.V.passive_installed then
          if rootLabelAllowed(slot) then
            return true
          end
        elseif validVersion(slot) then
          return true
        end
      end
    end
  end
  return false
end

return M

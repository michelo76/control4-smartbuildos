--[[==========================================================================
  SmartBuildOS Agent — telemetry helpers (pure)

  Everything a controller can TELL us beyond device online/offline, as pure
  functions the Agent wires to Director. Pure so the rules are testable
  without hardware; every input shape below is either measured on a live
  controller, documented in the DriverWorks API, or taken from a shipped
  driver — and the doc comment on each says which.

  Evidence classes (docs/AGENT_TELEMETRY.md): VERIFIED_BY_DOCS,
  VERIFIED_BY_EXAMPLE (a shipped driver does it), MEASURED (seen on our
  controllers), PROBE (tried and reported, never depended on).
============================================================================]]

local M = {}

-- ─── Director system events ──────────────────────────────────────────────────
--
-- Ids from the C4SystemEvents table as vendored in
-- drivers-common-public/global/handlers.lua (VERIFIED_BY_DOCS); the names
-- 6/7/8/11/12/15/85/86 are registered by shipped first-party and Chowmain
-- drivers (VERIFIED_BY_EXAMPLE: communication_agent_v2, nowplaying-hdmiout,
-- triad_ams16, room_control_keypad, LuminaLogic). 17/18/48/49/78 are what
-- the Agent already registered. The callback payload is "event specific and
-- in most cases can be ignored" (docs); shipped drivers read its name with
-- string.match(event, '.-name="(.-)"') (bond, Integra) — so does
-- eventNameFrom, and an unparseable payload is "unknown", which the Agent
-- treats exactly as it treated every event before: one debounced poll.

M.SYSTEM_EVENT_NAMES = {
  [3] = "OnProjectChanged",
  [6] = "OnPIP",
  [7] = "OnItemAdded",
  [8] = "OnItemNameChanged",
  [11] = "OnItemRemoved",
  [12] = "OnItemMoved",
  [13] = "OnDriverAdded",
  [15] = "OnBindingAdded",
  [16] = "OnBindingRemoved",
  [17] = "OnNetworkBindingAdded",
  [18] = "OnNetworkBindingRemoved",
  [21] = "OnCodeItemAdded",
  [22] = "OnCodeItemRemoved",
  [23] = "OnCodeItemMoved",
  [46] = "OnProjectLocked",
  [47] = "OnProjectLeaveLock",
  [48] = "OnDeviceOnline",
  [49] = "OnDeviceOffline",
  [56] = "OnControllerDisabled",
  [57] = "OnDeviceFirmwareChanged",
  [58] = "OnLocaleChanged",
  [59] = "OnZigbeeNodesChanged",
  [61] = "OnZigbeeMeshChanged",
  [64] = "OnTimezoneChanged",
  [69] = "OnProjectEnterLock",
  [76] = "OnZigbeeNodeOnline",
  [77] = "OnZigbeeNodeOffline",
  [78] = "OnSDDPDeviceStatus",
  [85] = "OnSystemShutDown",
  [86] = "OnSystemUpdateStarted",
  [90] = "OnDirectorIPAddressChanged",
}

local CLASS_OF = {
  OnDeviceOnline = "device",
  OnDeviceOffline = "device",
  OnNetworkBindingAdded = "device",
  OnNetworkBindingRemoved = "device",
  OnSDDPDeviceStatus = "device",
  OnProjectChanged = "project",
  OnPIP = "project",
  OnItemAdded = "project",
  OnItemNameChanged = "project",
  OnItemRemoved = "project",
  OnItemMoved = "project",
  OnDriverAdded = "project",
  OnBindingAdded = "project",
  OnBindingRemoved = "project",
  OnDeviceFirmwareChanged = "project",
  OnProjectLocked = "composer",
  OnProjectEnterLock = "composer",
  OnProjectLeaveLock = "composer",
  OnCodeItemAdded = "programming",
  OnCodeItemRemoved = "programming",
  OnCodeItemMoved = "programming",
  OnZigbeeNodesChanged = "zigbee",
  OnZigbeeMeshChanged = "zigbee",
  OnZigbeeNodeOnline = "zigbee",
  OnZigbeeNodeOffline = "zigbee",
  OnSystemShutDown = "shutdown",
  OnSystemUpdateStarted = "os_update",
  OnLocaleChanged = "identity",
  OnTimezoneChanged = "identity",
  OnDirectorIPAddressChanged = "identity",
  OnControllerDisabled = "controller_disabled",
}

--- The event's name from Director's payload, or "unknown".
--- @param data any The OnSystemEvent argument.
--- @return string
function M.eventNameFrom(data)
  if type(data) == "string" then
    local name = data:match('name="(.-)"') or data:match("<name>(.-)</name>")
    if name and name ~= "" then
      return name
    end
    -- A bare name, as a test or a future OS might hand it.
    if data:match("^On%a+$") then
      return data
    end
    return "unknown"
  elseif type(data) == "table" then
    local name = data.name or data.event or data.Name
    if type(name) == "string" and name ~= "" then
      return name
    end
    local id = tonumber(data.id or data.eventid)
    if id and M.SYSTEM_EVENT_NAMES[id] then
      return M.SYSTEM_EVENT_NAMES[id]
    end
  elseif type(data) == "number" and M.SYSTEM_EVENT_NAMES[data] then
    return M.SYSTEM_EVENT_NAMES[data]
  end
  return "unknown"
end

--- What the Agent should do about an event of this name.
--- @return string class device|project|composer|programming|zigbee|shutdown|os_update|identity|controller_disabled|unknown
function M.classifySystemEvent(name)
  return CLASS_OF[name] or "unknown"
end

-- ─── Programming census ──────────────────────────────────────────────────────
--
-- C4:GetAllCodeItems (VERIFIED_BY_DOCS; MEASURED 2026-08: groups of event
-- attachments whose `codeitem` nests the actual lines under `subitems`, each
-- with `enabled` and `display`). Counting only the top level reports "123
-- attachments" and nothing about how much programming exists, which is the
-- number a maintenance report needs; `enabled = false` is programming nobody
-- remembers switching off.

--- @param codeItems table The GetAllCodeItems result.
--- @return table { groups, attachments, lines, with_text, disabled }
function M.programmingCensus(codeItems)
  local out = { groups = 0, attachments = 0, lines = 0, with_text = 0, disabled = 0 }
  if type(codeItems) ~= "table" then
    return out
  end
  local function countItem(ci, depth)
    if type(ci) ~= "table" or depth > 12 then
      return
    end
    out.lines = out.lines + 1
    if ci.enabled == false then
      out.disabled = out.disabled + 1
    end
    if type(ci.display) == "string" and ci.display ~= "" then
      out.with_text = out.with_text + 1
    end
    if type(ci.subitems) == "table" then
      for _, sub in pairs(ci.subitems) do
        countItem(sub, depth + 1)
      end
    end
  end
  for _, list in pairs(codeItems) do
    out.groups = out.groups + 1
    if type(list) == "table" then
      for _, item in pairs(list) do
        out.attachments = out.attachments + 1
        if type(item) == "table" then
          countItem(item.codeitem, 0)
        end
      end
    end
  end
  return out
end

--- One line for a Composer property.
function M.programmingText(census)
  if type(census) ~= "table" then
    return "not read"
  end
  return string.format(
    "%d attachment(s) · %d line(s) · %d disabled",
    census.attachments or 0,
    census.lines or 0,
    census.disabled or 0
  )
end

-- ─── Clock offset from the platform's Date header ────────────────────────────
--
-- lib.http hands back the response headers (C4:url's responseHeaders, a
-- documented table). Every HTTPS answer from the platform carries RFC 7231
-- `Date`; comparing it with os.time() at receipt gives the controller's clock
-- offset within the request's latency — no second API, no NTP. The ladder in
-- the licence cache and every scheduled programming line depend on this
-- clock, so a drifting one is a finding, not a curiosity.

local MONTHS = {
  jan = 1,
  feb = 2,
  mar = 3,
  apr = 4,
  may = 5,
  jun = 6,
  jul = 7,
  aug = 8,
  sep = 9,
  oct = 10,
  nov = 11,
  dec = 12,
}

local function daysFromCivil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Parses an RFC 1123 date ("Wed, 21 Oct 2026 07:35:00 GMT") to a UTC epoch.
--- @return number|nil
function M.parseHttpDate(text)
  if type(text) ~= "string" then
    return nil
  end
  local d, mon, y, hh, mm, ss = text:match("(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)")
  if not d then
    return nil
  end
  local m = MONTHS[mon:lower()]
  if not m then
    return nil
  end
  local days = daysFromCivil(tonumber(y), m, tonumber(d))
  return days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
end

--- The `Date` header whatever its case.
function M.dateHeader(headers)
  if type(headers) ~= "table" then
    return nil
  end
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == "date" then
      return v
    end
  end
  return nil
end

--- Platform time minus controller time, in whole seconds, or nil when the
--- answer carried no usable Date.
--- @param headers table|nil
--- @param localNow number os.time() at receipt
--- @return number|nil
function M.clockOffsetSeconds(headers, localNow)
  local server = M.parseHttpDate(M.dateHeader(headers))
  if server == nil or type(localNow) ~= "number" then
    return nil
  end
  return server - math.floor(localNow)
end

--- How to show an offset: sign, seconds, and whether it is drift.
M.CLOCK_DRIFT_SECONDS = 120
function M.clockOffsetText(offset)
  if offset == nil then
    return "not measured"
  end
  local text = string.format("%+d s", offset)
  if math.abs(offset) >= M.CLOCK_DRIFT_SECONDS then
    return text .. " — DRIFT (programming and schedules run off this clock)"
  end
  return text
end

-- ─── Controller vitals from /proc ────────────────────────────────────────────
--
-- PROBE. Composer's Director page shows CPU and memory, but no DriverWorks
-- call exposes them (the 2026-09 sweep found none among the documented
-- calls). The controller is Linux and the Lua `io` library is present in
-- shipped drivers (bond-bridge reads its own XML with io.open), so these try
-- the kernel's own files. Whether the sandbox lets a driver read /proc is
-- unknown until measured: a nil reader result is "not readable", reported as
-- such, never as a value.

--- "0.52 0.58 0.59 1/160 1234" → { load1, load5, load15, running, tasks }
function M.parseLoadavg(text)
  if type(text) ~= "string" then
    return nil
  end
  local a, b, c, running, tasks = text:match("^%s*([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+(%d+)/(%d+)")
  if not a then
    return nil
  end
  return {
    load1 = tonumber(a),
    load5 = tonumber(b),
    load15 = tonumber(c),
    running = tonumber(running),
    tasks = tonumber(tasks),
  }
end

--- /proc/meminfo → { total_kb, available_kb, free_kb }. MemAvailable when
--- the kernel has it (3.14+), else MemFree + Buffers + Cached.
function M.parseMeminfo(text)
  if type(text) ~= "string" then
    return nil
  end
  local function kb(key)
    local v = text:match("\n?" .. key .. ":%s*(%d+)%s*kB")
    return v and tonumber(v) or nil
  end
  local total = kb("MemTotal")
  if not total then
    return nil
  end
  local available = kb("MemAvailable")
  local free = kb("MemFree")
  if not available and free then
    available = free + (kb("Buffers") or 0) + (kb("Cached") or 0)
  end
  return { total_kb = total, available_kb = available, free_kb = free }
end

--- /proc/uptime → seconds up (first number).
function M.parseProcUptime(text)
  if type(text) ~= "string" then
    return nil
  end
  local s = text:match("^%s*([%d%.]+)")
  return s and math.floor(tonumber(s)) or nil
end

--- /sys/class/thermal/thermal_zone0/temp → degrees C. The kernel reports
--- millidegrees; a value under 1000 is taken as whole degrees (some SoCs).
function M.parseThermal(text)
  if type(text) ~= "string" then
    return nil
  end
  local n = tonumber(text:match("^%s*(-?%d+)"))
  if n == nil then
    return nil
  end
  if math.abs(n) >= 1000 then
    return math.floor(n / 100 + 0.5) / 10
  end
  return n
end

M.VITALS_FILES = {
  loadavg = "/proc/loadavg",
  meminfo = "/proc/meminfo",
  uptime = "/proc/uptime",
  thermal = "/sys/class/thermal/thermal_zone0/temp",
}

--- Reads what it can through `readFile(path) -> string|nil`. Returns nil when
--- nothing was readable, so the heartbeat carries no block rather than an
--- empty one, and `readable` lists what answered.
function M.readVitals(readFile)
  if type(readFile) ~= "function" then
    return nil
  end
  local out, readable = {}, {}
  local load = M.parseLoadavg(readFile(M.VITALS_FILES.loadavg))
  if load then
    out.load1, out.load5, out.load15 = load.load1, load.load5, load.load15
    out.tasks = load.tasks
    readable[#readable + 1] = "loadavg"
  end
  local mem = M.parseMeminfo(readFile(M.VITALS_FILES.meminfo))
  if mem then
    out.mem_total_kb, out.mem_available_kb = mem.total_kb, mem.available_kb
    if mem.total_kb and mem.available_kb and mem.total_kb > 0 then
      out.mem_used_pct = math.floor((1 - mem.available_kb / mem.total_kb) * 1000 + 0.5) / 10
    end
    readable[#readable + 1] = "meminfo"
  end
  local up = M.parseProcUptime(readFile(M.VITALS_FILES.uptime))
  if up then
    out.proc_uptime_seconds = up
    readable[#readable + 1] = "uptime"
  end
  local temp = M.parseThermal(readFile(M.VITALS_FILES.thermal))
  if temp then
    out.cpu_temp_c = temp
    readable[#readable + 1] = "thermal"
  end
  if #readable == 0 then
    return nil
  end
  out.readable = readable
  return out
end

function M.vitalsText(v)
  if type(v) ~= "table" then
    return "not readable on this OS"
  end
  local parts = {}
  if v.load1 then
    parts[#parts + 1] = string.format("load %.2f/%.2f/%.2f", v.load1, v.load5, v.load15)
  end
  if v.mem_used_pct then
    parts[#parts + 1] = string.format("mem %.1f%% used", v.mem_used_pct)
  end
  if v.cpu_temp_c then
    parts[#parts + 1] = string.format("cpu %.1f°C", v.cpu_temp_c)
  end
  return #parts > 0 and table.concat(parts, " · ") or "readable, nothing parsed"
end

-- ─── How did the controller come back? ───────────────────────────────────────
--
-- OnSystemShutDown (85) and OnSystemUpdateStarted (86) fire BEFORE Director
-- goes down (registered by triad_ams16, VERIFIED_BY_EXAMPLE). The Agent
-- persists the moment it saw each; at the next start, a "reload" is then a
-- clean restart, an OS update, or — with no marker at all — an unexpected
-- one (power loss, crash, hard reset), which is the case worth a visit.

M.MARKER_MAX_AGE = 6 * 3600

--- @param kind string the start kind from classifyStart: first|update|reload
--- @param markers table|nil { shutdown_at = epoch|nil, os_update_at = epoch|nil }
--- @param now number epoch
--- @return string|nil restart  nil for first/update; else "os-update" | "clean" | "unexpected"
function M.classifyRestart(kind, markers, now)
  if kind ~= "reload" then
    return nil
  end
  markers = type(markers) == "table" and markers or {}
  local function fresh(at)
    return type(at) == "number" and now - at >= 0 and now - at <= M.MARKER_MAX_AGE
  end
  if fresh(markers.os_update_at) then
    return "os-update"
  end
  if fresh(markers.shutdown_at) then
    return "clean"
  end
  return "unexpected"
end

-- ─── Zigbee counters ─────────────────────────────────────────────────────────

function M.zigbeeText(z)
  if type(z) ~= "table" then
    return "no events"
  end
  return string.format(
    "%d node offline · %d node online · %d mesh/nodes changed since start",
    z.node_offline or 0,
    z.node_online or 0,
    z.mesh_changes or 0
  )
end

return M

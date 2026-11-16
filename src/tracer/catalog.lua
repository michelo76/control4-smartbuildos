--- Event Tracer — the event catalogue (pure).
---
--- Director fires `OnDeviceEvent(firingDeviceId, eventId)` for a device event
--- a driver subscribed to with `C4:RegisterDeviceEvent(deviceId, eventId)`,
--- but offers no documented call that LISTS another device's events
--- (CAPABILITY-MATRIX row 7). The tracer therefore needs to know, per
--- driver file, which event ids exist. Three tiers, best first:
---
---   • `project`  — events parsed from the project XML on the controller
---                  (`C4:GetProjectItems` without LIMIT_DEVICE_DATA). Whether
---                  that XML carries each device's `<events>` is a bench
---                  PROBE; this module parses it when present and is silent
---                  when it is not. Covers Control4's own c4i drivers, which
---                  never sit in a dealer's library.
---   • `builtin`  — `tracer.catalog_data`, generated at build time from the
---                  dealer's driver library (tools/gen-event-catalog.py).
---   • `learned`  — event ids seen at runtime from a probe subscription,
---                  persisted so the next apply subscribes to them by name
---                  "Event <id>" without probing again.
---
--- Names are what the driver's own XML declares — exactly what Composer shows.

local M = {}

local CDATA = "<!%[CDATA%[(.-)%]%]>"

local function unescape(s)
  s = tostring(s or ""):gsub(CDATA, "%1")
  s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
  s = s:gsub("%s+", " ")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The device's own `<events>` block of a driver XML → { [id] = name }.
--- The first `<events>` block is the device's (proxy sub-documents may carry
--- their own later). Returns an empty table when none is declared.
--- @param xml string
--- @return table<number, string>
function M.parseDriverXml(xml)
  local out = {}
  if type(xml) ~= "string" then
    return out
  end
  local block = xml:match("<[Ee][Vv][Ee][Nn][Tt][Ss]>(.-)</[Ee][Vv][Ee][Nn][Tt][Ss]>")
  if block == nil then
    return out
  end
  for body in block:gmatch("<[Ee][Vv][Ee][Nn][Tt]>(.-)</[Ee][Vv][Ee][Nn][Tt]>") do
    local id = tonumber(body:match("<[Ii][Dd]>%s*(%d+)%s*</[Ii][Dd]>") or "")
    local name = body:match("<[Nn][Aa][Mm][Ee]>%s*(.-)%s*</[Nn][Aa][Mm][Ee]>")
    if id ~= nil and name ~= nil then
      name = unescape(name):sub(1, 120)
      if name ~= "" then
        out[id] = name
      end
    end
  end
  return out
end

--- Project XML (the unlimited `GetProjectItems`) → { [deviceId] = events }
--- for every `<item>` whose `<itemdata>` carries an `<events>` block. The
--- PROBE path: when the OS strips device data this returns an empty table
--- and a count of 0, and the caller falls back to the other tiers.
--- Items are matched non-greedily to the first `</itemdata>`; the id is read
--- from the same item, never assumed by position.
--- @param xml string
--- @return table<number, table<number, string>> byDevice, number count
function M.parseProjectItems(xml)
  local byDevice, count = {}, 0
  if type(xml) ~= "string" or xml == "" then
    return byDevice, count
  end
  for head, itemdata in xml:gmatch("<item[^>]*>(.-)<itemdata>(.-)</itemdata>") do
    -- `head` may span earlier items whose <itemdata> was self-closing; the
    -- LAST <id> before this <itemdata> is the one of the same item.
    local id = nil
    for found in head:gmatch("<id>%s*(%d+)%s*</id>") do
      id = tonumber(found)
    end
    if id ~= nil and itemdata:find("<[Ee][Vv][Ee][Nn][Tt][Ss]>") then
      local events = M.parseDriverXml(itemdata)
      if next(events) ~= nil then
        byDevice[id] = events
        count = count + 1
      end
    end
  end
  return byDevice, count
end

local Catalog = {}
Catalog.__index = Catalog

--- @param opts table { builtin = table<string, table<number,string>>|nil, learned = table|nil }
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Catalog)
  self.builtin = type(opts.builtin) == "table" and opts.builtin or {}
  self.learned = {} -- driverFile -> { [id] = true }
  self.project = {} -- deviceId -> { [id] = name }
  self.projectCount = 0
  if type(opts.learned) == "table" then
    for file, ids in pairs(opts.learned) do
      if type(ids) == "table" then
        -- Accepts both the persisted array form { 6, 40 } and a set
        -- form { [6] = true, [40] = true }.
        local set = {}
        for k, v in pairs(ids) do
          local id = (v == true) and tonumber(k) or tonumber(v)
          if id ~= nil then
            set[id] = true
          end
        end
        if next(set) ~= nil then
          self.learned[tostring(file)] = set
        end
      end
    end
  end
  return self
end

--- Replaces the project tier from a project XML string (or clears it).
--- @return number count of devices whose events the XML carried
function Catalog:loadProjectXml(xml)
  self.project, self.projectCount = M.parseProjectItems(xml)
  return self.projectCount
end

local function learnedName(id)
  return "Event " .. tostring(id)
end

--- Known events for a device: `{ [id] = { name = string, known = boolean } }`
--- and the tier the ids came from (`project`, `builtin`, `learned`, or nil
--- when nothing is known). Learned ids are merged into every tier so a
--- probe's discoveries survive once the driver file is later catalogued.
--- @param deviceId number
--- @param driverFile string|nil
--- @return table events, string|nil tier
function Catalog:eventsFor(deviceId, driverFile)
  local out, tier = {}, nil
  local project = self.project[tonumber(deviceId) or -1]
  if project ~= nil then
    tier = "project"
    for id, name in pairs(project) do
      out[id] = { name = name, known = true }
    end
  elseif driverFile ~= nil and self.builtin[driverFile] ~= nil then
    tier = "builtin"
    for id, name in pairs(self.builtin[driverFile]) do
      out[id] = { name = name, known = true }
    end
  end
  local learned = driverFile ~= nil and self.learned[driverFile] or nil
  if learned ~= nil then
    for id in pairs(learned) do
      if out[id] == nil then
        out[id] = { name = learnedName(id), known = false }
      end
    end
    tier = tier or "learned"
  end
  return out, tier
end

--- The display name of one event, or "Event <id>" with known=false.
function Catalog:name(deviceId, driverFile, eventId)
  local events = self:eventsFor(deviceId, driverFile)
  local e = events[tonumber(eventId) or -1]
  if e ~= nil then
    return e.name, e.known
  end
  return learnedName(eventId), false
end

--- Records that `eventId` exists for `driverFile`. Returns true when new.
function Catalog:learn(driverFile, eventId)
  local id = tonumber(eventId)
  if driverFile == nil or driverFile == "" or id == nil then
    return false
  end
  local set = self.learned[driverFile]
  if set == nil then
    set = {}
    self.learned[driverFile] = set
  end
  if set[id] then
    return false
  end
  set[id] = true
  return true
end

--- Persistable form of the learned tier: { [driverFile] = { id, id, ... } }.
function Catalog:learnedDoc()
  local doc = {}
  for file, set in pairs(self.learned) do
    local ids = {}
    for id in pairs(set) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
    doc[file] = ids
  end
  return doc
end

function Catalog:counts()
  local builtin, learned = 0, 0
  for _ in pairs(self.builtin) do
    builtin = builtin + 1
  end
  for _, set in pairs(self.learned) do
    for _ in pairs(set) do
      learned = learned + 1
    end
  end
  return { builtin_drivers = builtin, learned_events = learned, project_devices = self.projectCount }
end

return M

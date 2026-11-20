--[[==========================================================================
  SmartBuildOS Agent — Studio release G1 (pure)

  The six additions in docs/studio-g1/AGENT-CONTRACT-G1.md, as pure functions
  the Agent wires to Director. Pure so every wire shape is testable without a
  controller; the driver supplies the Director reads as functions.

    1. device_poll           digest of what the last poll saw   (device_poll_v1)
    2. honest `online`       JSON null for "no state to report" (device_online_null_v1)
    3. room identity         room_id per row, rooms on full sync (room_identity_v1)
    4. driver census         drivers on full sync               (driver_census_v1)
    5. controller identity   heartbeat `controller` block       (controller_identity_v1)
    6. failure reasons       heartbeat `last_errors`            (last_errors_v1)

  Every block is OPTIONAL on the wire: absent means "this Agent did not say",
  never a claim. A platform that predates G1 ignores the new keys.

  Global in the driver (`AgentStudio`), not a local: the main chunk is at
  Lua's 200-local ceiling.
============================================================================]]

local M = {}

--- The capability strings this module implements, declared on every heartbeat.
M.CAPABILITIES = {
  "device_poll_v1",
  "device_online_null_v1",
  "room_identity_v1",
  "driver_census_v1",
  "controller_identity_v1",
  "last_errors_v1",
}

--- Ceilings from the contract (and the platform's ingest limits).
M.MAX_DEVICE_ROWS = 2000
M.MAX_ROOMS = 500
M.ROOM_NAME_MAX = 80
M.MAX_DRIVERS = 500
M.DRIVER_STRING_MAX = 120
M.ERROR_MESSAGE_MAX = 200
M.TEXT_MAX = 200

--- The JSON null placeholder.
---
--- Lua has no value that survives in a table and means "null": a nil field is
--- simply absent, and the vendored encoder (Friedl's JSON.lua) drops it. That
--- encoder emits JSON null for any value equal to `options.null`, but the
--- transport (drivers-common-public/global/url.lua) calls `JSON:encode(data)`
--- with no options. installJsonNull() makes this placeholder the default, so a
--- row can carry an explicit null all the way to the wire. Two NUL bytes make
--- it a value no Director read, device name or platform answer can produce.
M.NULL = "\0sbos:json-null\0"

--- Makes `json` (the shared JSON.lua instance) encode M.NULL as JSON null by
--- default. Idempotent; an explicit `options.null` from a caller still wins.
--- Only encode is touched: decoding, and every value that is not exactly the
--- placeholder, encode exactly as before.
--- @param json table the instance `require("JSON")` returns
--- @return table json
function M.installJsonNull(json)
  if type(json) ~= "table" or rawget(json, "__sbos_null_installed") then
    return json
  end
  local encode = json.encode
  if type(encode) ~= "function" then
    return json
  end
  rawset(json, "encode", function(self, value, etc, options)
    local opts = {}
    if type(options) == "table" then
      for k, v in pairs(options) do
        opts[k] = v
      end
    end
    if opts.null == nil then
      opts.null = M.NULL
    end
    return encode(self, value, etc, opts)
  end)
  rawset(json, "__sbos_null_installed", true)
  return json
end

-- ─── Small helpers ───────────────────────────────────────────────────────────

--- Truncates to at most `max` BYTES without splitting a UTF-8 sequence, so a
--- room named in Arabic or with an accent never arrives as invalid UTF-8.
--- @param value any
--- @param max integer
--- @return string|nil
function M.truncate(value, max)
  if value == nil then
    return nil
  end
  local s = tostring(value)
  if #s <= max then
    return s
  end
  local cut = max
  -- Step back over continuation bytes (10xxxxxx) to the lead byte, and drop
  -- the lead byte too: the sequence it starts no longer fits.
  while cut > 0 do
    local b = s:byte(cut + 1)
    if b == nil or b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut)
end

--- A non-empty string from a Director answer, or nil. Numbers are accepted
--- (an id may come back numeric); tables, booleans and blanks are not facts.
--- @param value any
--- @param max integer|nil
--- @return string|nil
function M.text(value, max)
  if type(value) == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil
    end
    value = (value == math.floor(value)) and string.format("%d", value) or tostring(value)
  end
  if type(value) ~= "string" then
    return nil
  end
  local trimmed = value:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil
  end
  return M.truncate(trimmed, max or M.TEXT_MAX)
end

--- ISO-8601 UTC with a Z, second resolution.
--- @param t integer|nil epoch seconds (default now)
--- @return string
function M.isoUtc(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t or os.time())
end

--- Byte-wise string ordering.
---
--- ⚠ NOT `a < b`. Stock Lua 5.1 compares strings with strcoll(), so the order
--- depends on the controller's C locale; LuaJIT (the test runner) compares
--- bytes. The digest is checked by the platform against its own byte-order
--- sort, so the Agent must sort by bytes on every OS whatever its locale.
--- @param a string
--- @param b string
--- @return boolean
function M.byteLess(a, b)
  local la, lb = #a, #b
  local n = la < lb and la or lb
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then
      return x < y
    end
  end
  return la < lb
end

--- Decodes the five XML entities Composer names are escaped with.
--- @param s string
--- @return string
function M.xmlUnescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

-- ─── 1. device_poll ──────────────────────────────────────────────────────────

--- A device row's state as the digest spells it: "1" online, "0" offline,
--- "u" unknown. Mirrors what the row says ON THE WIRE (see wireRow), so the
--- digest describes exactly the payload the platform stored.
--- @param row table
--- @return string
function M.pollState(row)
  if row.addressable == false or row.online == nil or row.online == M.NULL then
    return "u"
  end
  return row.online and "1" or "0"
end

--- The digest input, byte-exact per the contract: one `<key>:<state>` line per
--- reported device, sorted ascending by KEY as byte strings (not by line — a
--- key that is a prefix of another, `c4:1` / `c4:10`, sorts differently by
--- line), joined with "\n", no trailing newline. Zero devices → "".
--- @param rows table map or list of device rows (removed rows are skipped)
--- @return string input
--- @return integer devices
--- @return integer offline
--- @return integer unknown
function M.digestInput(rows)
  local entries = {}
  local offline, unknown = 0, 0
  for _, row in pairs(rows or {}) do
    if type(row) == "table" and type(row.key) == "string" and not row.removed then
      local state = M.pollState(row)
      if state == "0" then
        offline = offline + 1
      elseif state == "u" then
        unknown = unknown + 1
      end
      entries[#entries + 1] = { key = row.key, state = state }
    end
  end
  table.sort(entries, function(x, y)
    return M.byteLess(x.key, y.key)
  end)
  local lines = {}
  for i, e in ipairs(entries) do
    lines[i] = e.key .. ":" .. e.state
  end
  return table.concat(lines, "\n"), #entries, offline, unknown
end

--- The heartbeat `device_poll` block.
--- @param rows table the devices the poll saw (gDeviceState)
--- @param completedAt integer epoch seconds the poll completed
--- @param intervalS integer the poll interval in force
--- @param sha256hex fun(s: string): string|nil SHA-256 as hex; nil = unavailable
--- @return table block
function M.devicePollBlock(rows, completedAt, intervalS, sha256hex)
  local input, devices, offline, unknown = M.digestInput(rows)
  local block = {
    completed_at = M.isoUtc(completedAt),
    interval_s = intervalS,
    devices = devices,
    offline = offline,
    unknown = unknown,
  }
  -- Absent when the hash primitive did not answer: a block without a digest
  -- can never match, so it never confirms anything it could not prove.
  local ok, hex = pcall(sha256hex, input)
  if ok and type(hex) == "string" then
    hex = hex:lower()
    if #hex == 64 and hex:match("^%x+$") then
      block.digest = hex
    end
  end
  return block
end

-- ─── 2. honest `online` ──────────────────────────────────────────────────────

--- Ids that are the PROXY of another project device. A protocol device lists
--- its proxies as `proxies = { [id] = { deviceName, driverFileName } }`
--- (Director emulator, field fact OS 4.3 2026-10-11: 36 of 36 protocol/proxy
--- pairs). A proxy is the same equipment as its protocol device, so reporting
--- it again as an unbound row would be a second, always-unknown twin.
--- @param devices table GetDevices({}) answer
--- @return table<integer, boolean>
function M.proxyIds(devices)
  local out = {}
  for rawId, device in pairs(devices or {}) do
    local owner = tonumber(rawId)
    if type(device) == "table" and type(device.proxies) == "table" then
      for rawProxy in pairs(device.proxies) do
        local pid = tonumber(rawProxy)
        if pid ~= nil and pid ~= owner then
          out[math.floor(pid)] = true
        end
      end
    end
  end
  return out
end

--- Room items, should Director ever list them as devices, are rooms, not gear.
local ROOM_DRIVER_FILES = { ["roomdevice.c4i"] = true }

--- The row for a project device with NO network binding (IR, serial, relay,
--- contact): included with `connection_type` and `online` both null on the
--- wire, so the platform can show "Unknown / not monitored" instead of
--- nothing. Internally `online` stays false (and `addressable` false) so the
--- poll's transition logic and the offline count treat it exactly as they
--- treat an unaddressed binding today.
--- @param id integer
--- @param device table the GetDevices entry
--- @param proxies table<integer, boolean> from proxyIds
--- @return table|nil row nil when the id is a proxy or a room
function M.unboundRow(id, device, proxies)
  if type(device) ~= "table" or (proxies and proxies[id]) then
    return nil
  end
  local file = type(device.driverFileName) == "string" and device.driverFileName or nil
  if file ~= nil and ROOM_DRIVER_FILES[file:lower()] then
    return nil
  end
  local roomId = tonumber(device.roomId)
  return {
    addressable = false,
    unmonitored = true,
    key = "c4:" .. id,
    source = "director",
    device_id = id,
    name = device.deviceName or device.name,
    online = false,
    room = device.roomName,
    room_id = roomId ~= nil and math.floor(roomId) or nil,
    driver_file = file,
  }
end

--- Keeps the device map within the payload ceiling. Network-bound rows win
--- (they are the ones with a state to report), then byte order of the key, so
--- the same devices survive every poll and the digest stays stable.
--- @param devices table<string, table> keyed by device key
--- @param max integer|nil
--- @return table<string, table> devices
--- @return boolean truncated
function M.capRows(devices, max)
  max = max or M.MAX_DEVICE_ROWS
  local keys = {}
  for key in pairs(devices) do
    keys[#keys + 1] = key
  end
  if #keys <= max then
    return devices, false
  end
  table.sort(keys, function(a, b)
    local ua = devices[a].unmonitored == true
    local ub = devices[b].unmonitored == true
    if ua ~= ub then
      return ub
    end
    return M.byteLess(a, b)
  end)
  local kept = {}
  for i = 1, max do
    kept[keys[i]] = devices[keys[i]]
  end
  return kept, true
end

--- The row as it goes on the wire. A copy: the driver's own row keeps its
--- boolean `online` for transition tracking.
---   * an unaddressed binding (`addressable == false`) → online null
---   * an unbound device → connection_type null, online null
---   * the driver-local `unmonitored` marker is not sent
--- Every other field is passed through unchanged.
--- @param row table
--- @return table
function M.wireRow(row)
  local out = {}
  for k, v in pairs(row) do
    if k ~= "unmonitored" then
      out[k] = v
    end
  end
  if row.addressable == false then
    out.online = M.NULL
  end
  if row.unmonitored == true then
    out.connection_type = M.NULL
  end
  return out
end

--- @param list table[]
--- @return table[]
function M.wireRows(list)
  local out = {}
  for i, row in ipairs(list) do
    out[i] = type(row) == "table" and M.wireRow(row) or row
  end
  return out
end

--- Whether two observations of the same device read differently ON THE WIRE
--- although their internal `online` is equal (offline ↔ unknown). The poll
--- reports such a change in its delta (without firing online/offline events)
--- so the platform's stored state, and with it the digest, keeps up.
--- @param previous table
--- @param current table
--- @return boolean
function M.wireStateChanged(previous, current)
  return M.pollState(previous) ~= M.pollState(current)
    or (previous.unmonitored == true) ~= (current.unmonitored == true)
end

-- ─── 3. rooms ────────────────────────────────────────────────────────────────

--- Location item types in GetProjectItems / GetProjectHierarchy (MEASURED,
--- OS 4.2: 2 site, 3 building, 4 floor, 8 room; 1 is the project root).
local TYPE_BUILDING, TYPE_FLOOR, TYPE_ROOM = 3, 4, 8
local LOCATION_TYPES = { [1] = true, [2] = true, [3] = true, [4] = true, [8] = true }

--- Walks the GetProjectItems("LOCATIONS") XML as a tree.
---
--- The XML NESTS (`<item>…<subitems><item>…</item></subitems></item>`), so a
--- non-greedy `<item>(.-)</item>` match — fine for a name lookup — cannot tell
--- a room's parent. This keeps an element stack and reads `<id>`, `<name>` and
--- `<type>` only when their parent element is the `<item>` itself, never from
--- inside `<itemdata>`.
--- @param xml string
--- @return table[] items { id, name, type, parent } in document order
function M.parseProjectItems(xml)
  local items = {}
  if type(xml) ~= "string" or xml == "" then
    return items
  end
  local elements = {} -- element-name stack
  local open = {} -- open <item> records
  local pos = 1
  while true do
    local s, e, slash, name, rest = xml:find("<(/?)([%w_:%-]+)([^>]*)>", pos)
    if s == nil then
      break
    end
    pos = e + 1
    local selfClosing = rest:sub(-1) == "/"
    if slash == "" then
      if name == "item" then
        local item = { parent = open[#open] }
        items[#items + 1] = item
        if not selfClosing then
          open[#open + 1] = item
        end
      elseif (name == "id" or name == "name" or name == "type") and elements[#elements] == "item" then
        local item = open[#open]
        local value = xml:match("^([^<]*)", pos)
        if item ~= nil and item[name] == nil and value ~= nil then
          item[name] = value
        end
      end
      if not selfClosing then
        elements[#elements + 1] = name
      end
    else
      -- Tolerant close: unwind to the matching open element.
      for i = #elements, 1, -1 do
        if elements[i] == name then
          for j = #elements, i, -1 do
            elements[j] = nil
          end
          break
        end
      end
      if name == "item" then
        open[#open] = nil
      end
    end
  end
  for _, item in ipairs(items) do
    item.id = tonumber(item.id and item.id:match("^%s*(.-)%s*$"))
    item.type = tonumber(item.type and item.type:match("^%s*(.-)%s*$"))
    item.name = item.name and M.xmlUnescape(item.name:match("^%s*(.-)%s*$")) or nil
  end
  return items
end

--- The full-sync `rooms` list: every room (type 8) including empty ones, with
--- the nearest enclosing location as `parent_id` and the nearest floor and
--- building by name — each only when the project has one. Sorted by id;
--- at most 500; names at most 80 bytes.
--- @param xml string GetProjectItems("LOCATIONS", …) answer
--- @return table[]
function M.roomsFromLocations(xml)
  local rooms = {}
  for _, item in ipairs(M.parseProjectItems(xml)) do
    if item.type == TYPE_ROOM and item.id ~= nil then
      local room = { id = math.floor(item.id), name = M.truncate(item.name or "", M.ROOM_NAME_MAX) }
      local up = item.parent
      while up ~= nil do
        if up.id ~= nil and LOCATION_TYPES[up.type or -1] and room.parent_id == nil then
          room.parent_id = math.floor(up.id)
        end
        if up.type == TYPE_FLOOR and room.floor == nil and up.name ~= nil and up.name ~= "" then
          room.floor = M.truncate(up.name, M.ROOM_NAME_MAX)
        end
        if up.type == TYPE_BUILDING and room.building == nil and up.name ~= nil and up.name ~= "" then
          room.building = M.truncate(up.name, M.ROOM_NAME_MAX)
        end
        up = up.parent
      end
      rooms[#rooms + 1] = room
    end
  end
  table.sort(rooms, function(a, b)
    return a.id < b.id
  end)
  while #rooms > M.MAX_ROOMS do
    rooms[#rooms] = nil
  end
  return rooms
end

-- ─── 4. driver census ────────────────────────────────────────────────────────

--- The full-sync `drivers` list: one entry per distinct driver file in the
--- project, counted over every GetDevices entry that is not the proxy of
--- another device (a proxy reports Control4's own proxy file — tv.c4i,
--- light_v2.c4i — and is part of its protocol driver's install, not a second
--- driver; counted, the Agent's own self-proxy read as a non-SmartBuildOS
--- "smartbuildos.c4i").
---
--- `name` and `version` are read from the lowest-id device of each file with
--- `readData(id, field)` (C4:GetDeviceData, which answers from that driver's
--- driver.xml). `version` is a PROBE: sent only when it answered. Ordered by
--- count (largest first) then file, so a project past 500 files keeps the
--- drivers that matter most.
--- @param devices table GetDevices({}) answer
--- @param readData fun(id: integer, field: string): any
--- @param isSbos fun(file: string): boolean
--- @return table[]
function M.driverCensus(devices, readData, isSbos)
  local byFile, files = {}, {}
  local proxies = M.proxyIds(devices)
  for rawId, device in pairs(devices or {}) do
    local id = tonumber(rawId)
    local file = type(device) == "table" and M.text(device.driverFileName, 400) or nil
    if id ~= nil and file ~= nil and not proxies[math.floor(id)] then
      local entry = byFile[file]
      if entry == nil then
        entry = { file = file, count = 0, first = id }
        byFile[file] = entry
        files[#files + 1] = entry
      end
      entry.count = entry.count + 1
      if id < entry.first then
        entry.first = id
      end
    end
  end
  table.sort(files, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return M.byteLess(a.file, b.file)
  end)
  local out = {}
  for i = 1, math.min(#files, M.MAX_DRIVERS) do
    local entry = files[i]
    local id = math.floor(entry.first)
    local function read(field)
      local ok, value = pcall(readData, id, field)
      return ok and M.text(value, M.DRIVER_STRING_MAX) or nil
    end
    local okS, sbos = pcall(isSbos, entry.file)
    out[i] = {
      file = M.truncate(entry.file, M.DRIVER_STRING_MAX),
      name = read("name"),
      version = read("version"),
      count = entry.count,
      sbos = okS and sbos == true or false,
    }
  end
  return out
end

-- ─── 5. controller identity ──────────────────────────────────────────────────

--- Field order of the `controller` block (fixed, so its signature is stable).
M.CONTROLLER_FIELDS = { "timezone", "locale", "hostname", "project_id", "boot_id" }

--- The heartbeat `controller` block.
---
--- `readers[field] = { read = fn, probe = bool }`. Every read is pcall'd; a
--- field is sent only when its read answered a non-empty string or number.
--- `probed` lists the fields present here whose source call the released
--- Agent did not already make (contract: a PROBE), so Studio can label them.
--- @param readers table<string, {read: function, probe: boolean}>
--- @return table|nil block nil when nothing answered
function M.controllerBlock(readers)
  local block, probed = {}, {}
  for _, field in ipairs(M.CONTROLLER_FIELDS) do
    local reader = readers[field]
    if reader ~= nil then
      local ok, value = pcall(reader.read)
      local text = ok and M.text(value, M.TEXT_MAX) or nil
      if text ~= nil then
        block[field] = text
        if reader.probe then
          probed[#probed + 1] = field
        end
      end
    end
  end
  if next(block) == nil then
    return nil
  end
  if #probed > 0 then
    block.probed = probed
  end
  return block
end

--- A stable string for change detection ("sent whenever a value changes").
--- @param block table|nil
--- @return string
function M.controllerSignature(block)
  if block == nil then
    return ""
  end
  local parts = {}
  for _, field in ipairs(M.CONTROLLER_FIELDS) do
    parts[#parts + 1] = field .. "=" .. tostring(block[field])
  end
  parts[#parts + 1] = "probed=" .. table.concat(block.probed or {}, ",")
  return table.concat(parts, "\1")
end

-- ─── 6. last_errors ──────────────────────────────────────────────────────────

--- Ingest path → upload channel. Only these three are reported.
local CHANNELS = { devices = "devices", telemetry = "telemetry", events = "events" }

--- @param path string the ingest path send() posted to
--- @return string|nil channel
function M.channelFor(path)
  return CHANNELS[path]
end

--- Key fragments whose VALUE is a credential (compared with spaces, "_" and
--- "-" removed, lower case). Matches the platform's redaction vocabulary plus
--- the Agent's own advisory identity headers.
local SECRET_KEY_FRAGMENTS = {
  "password",
  "passphrase",
  "passwd",
  "apikey",
  "token",
  "secret",
  "credential",
  "authorization",
  "cookie",
  "sessionid",
  "pairingcode",
  "activationcode",
  "privatekey",
  "signature",
  "xsmartbuildos",
}

local REDACTED = "[redacted]"

local function isSecretKey(key)
  local k = key:lower():gsub("[%s_%-]", "")
  for _, fragment in ipairs(SECRET_KEY_FRAGMENTS) do
    if k:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

--- Strips header and credential values out of a failure text, then trims it
--- to 200 bytes. The platform redacts again; this is the Agent's half.
---   * `Bearer …` / `Basic …` values
---   * any `key: value`, `key=value`, `"key":"value"` whose key names a
---     credential or one of the X-SmartBuildOS-* headers
---   * JWT-shaped strings and long opaque runs (≥ 40 token characters)
--- @param text any
--- @return string
function M.sanitizeMessage(text)
  local s = tostring(text == nil and "" or text)
  s = s:gsub("[%c]", " ")
  s = s:gsub("([Bb][Ee][Aa][Rr][Ee][Rr])%s+[^%s,;\"']+", "%1 " .. REDACTED)
  s = s:gsub("([Bb][Aa][Ss][Ii][Cc])%s+[%w%+/=]+", "%1 " .. REDACTED)
  s = s:gsub("([%a][%w_%-]*)(%s*[\"']?%s*[:=]%s*[\"']?)([^%s\"',;&}%]]+)", function(key, sep, value)
    if isSecretKey(key) and value ~= REDACTED and not value:find("^%[redacted") then
      return key .. sep .. REDACTED
    end
  end)
  -- "Bearer [redacted]" survives the pass above; a credential key followed by
  -- a scheme word ("Authorization: Bearer x") was already caught by the first.
  s = s:gsub("[%w_%-]+%.[%w_%-]+%.[%w_%-]+", function(m)
    if #m > 60 then
      return REDACTED
    end
  end)
  s = s:gsub("[%w_%-%+=]+", function(m)
    if #m >= 40 then
      return REDACTED
    end
  end)
  s = s:gsub("%s+", " "):match("^%s*(.-)%s*$")
  return M.truncate(s, M.ERROR_MESSAGE_MAX)
end

--- The short reason inside lib/http's transport error ("HTTP POST request to
--- <url> failed; Timeout was reached" → "Timeout was reached"); the whole text
--- when it has another shape.
--- @param text any
--- @return string
function M.transportReason(text)
  local s = tostring(text == nil and "" or text)
  local tail = s:match("failed;%s*(.+)$")
  if tail ~= nil and tail ~= "" then
    return tail
  end
  return s
end

--- Per-channel failure memory. One entry per channel that has failed since
--- start; a channel's entry is removed on its next success.
--- @return table
function M.newLastErrors()
  local self = { entries = {} }
  --- @param channel string|nil
  --- @param status integer|nil HTTP status, or nil/0 for a transport failure
  --- @param message any
  --- @param at integer|nil epoch seconds
  function self.failure(channel, status, message, at)
    if channel == nil then
      return
    end
    local code = tonumber(status)
    self.entries[channel] = {
      at = M.isoUtc(at),
      status = (code ~= nil and code > 0) and math.floor(code) or 0,
      message = M.sanitizeMessage(message),
    }
  end
  function self.success(channel)
    if channel ~= nil then
      self.entries[channel] = nil
    end
  end
  --- @return table|nil the heartbeat block, nil when nothing has failed
  function self.block()
    if next(self.entries) == nil then
      return nil
    end
    local out = {}
    for channel, entry in pairs(self.entries) do
      out[channel] = { at = entry.at, status = entry.status, message = entry.message }
    end
    return out
  end
  return self
end

return M

--- Notification Router — message variables (pure).
---
--- A TITLE or MESSAGE may carry tokens that the router replaces with the
--- live VALUE of a Control4 variable at the moment it sends. Only the value
--- goes out, never the variable's name. The syntax is the one Control4's own
--- Push Notification and Email agents use:
---
---   ${1} .. ${4}                     the variable picked in the command's
---                                    VARIABLE 1..4 parameter (Composer's own
---                                    "Select variable…" tree, in the
---                                    programming window)
---   ${Room->Device::VARIABLE}        a variable written out, as the agents
---                                    write it
---   ${Device::VARIABLE}              the same, when the device name is unique
---   ${231::STATE}  ${231::1004}      by device id; the variable by name or id
---   ${Variables::NAME}               one of the project's custom variables
---
--- After a `|`, a token says how to show the value:
---
---   ${1|Open|Closed}                 on/off values: first text when the value
---                                    is 1 / true / on / yes or a non-zero
---                                    number, second when it is 0 / false /
---                                    off / no / empty; other text as it is
---   ${2|.1}                          a number rounded to 0..3 decimals
---
--- A variable that is picked but not written into the text is added at the
--- end of the message, so picking alone is enough.
---
--- Rules a dealer relies on:
---
---   • NEVER BLOCKS A SEND. A token that cannot be filled becomes `?` and is
---     reported back (the driver logs it and fires an event).
---   • NEVER SENDS A CREDENTIAL. A variable whose name is on the Flight
---     Recorder's fixed list (USERCODE, PINCODE, PASSWORD, TOKEN, …) is sent
---     as `[hidden]`. These messages leave the house.
---   • ONE PASS. A value that itself contains `${…}` is not expanded again.
---   • ONLY TOKENS ARE TOUCHED. `${…}` that is neither a number nor a
---     `device::variable` pair, and every plain `{…}`, is left as written.
---
--- Nothing here does I/O: the driver injects what was picked, how to read a
--- device's variables and the project's device list.

local Config = require("flightrecorder.config")

local M = {}

M.PICKS = 4
M.MISSING = "?"
M.HIDDEN = "[hidden]"

--- The Variables agent: where Composer's custom variables live.
M.PROJECT_VARIABLES_DEVICE = 100001

M.LIMITS = {
  value = 120, -- characters of one value in a message
  tokens = 20, -- per text
  token = 160, -- characters between the braces
}

local TOKEN = "%${([^{}\n]*)}"

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Splits "a|b|c" keeping empty parts ("${1|On|}" has an empty second text).
local function splitBar(s)
  local out = {}
  for part in (s .. "|"):gmatch("(.-)|") do
    out[#out + 1] = part
  end
  return out
end

--- What is between `${` and `}` → a reference, or nil when the text is not
--- a token (and must be left as written).
function M.parseToken(inner)
  inner = tostring(inner or "")
  local parts = splitBar(inner)
  local head = trim(parts[1])
  local options = {}
  for i = 2, #parts do
    options[#options + 1] = trim(parts[i])
  end
  if head:match("^%d$") then
    return { kind = "pick", pick = tonumber(head), options = options }
  end
  local device, variable = head:match("^(.-)::(.*)$")
  if device ~= nil then
    device, variable = trim(device), trim(variable)
    if device ~= "" and variable ~= "" then
      return { kind = "named", device = device, variable = variable, options = options }
    end
  end
  return nil
end

--- What a VARIABLE parameter carries: "deviceId,variableId" → two numbers,
--- or nil when nothing was picked.
function M.parsePick(text)
  local device, variable = tostring(text or ""):match("^%s*(%d+)%s*,%s*(%d+)%s*$")
  if device == nil then
    return nil
  end
  return tonumber(device), tonumber(variable)
end

--- true / false for an on-off looking value, nil for anything else.
function M.truth(value)
  local s = trim(value):lower()
  if s == "" or s == "0" or s == "false" or s == "off" or s == "no" then
    return false
  end
  if s == "1" or s == "true" or s == "on" or s == "yes" then
    return true
  end
  local n = tonumber(s)
  if n ~= nil then
    return n ~= 0
  end
  return nil
end

--- A raw variable value as message text: one line, bounded.
function M.clean(value)
  if type(value) == "boolean" then
    value = value and "1" or "0"
  end
  local s = trim(tostring(value == nil and "" or value):gsub("%c+", " "))
  if #s > M.LIMITS.value then
    s = s:sub(1, M.LIMITS.value)
  end
  return s
end

--- The value as the token asks to show it.
function M.format(value, options)
  local s = M.clean(value)
  options = options or {}
  if #options >= 2 then
    local t = M.truth(s)
    if t == true then
      return options[1]
    elseif t == false then
      return options[2]
    end
    return s
  end
  if #options == 1 then
    local decimals = options[1]:match("^%.(%d)$")
    local n = tonumber(s)
    if decimals ~= nil and n ~= nil and tonumber(decimals) <= 3 then
      local out = string.format("%." .. decimals .. "f", n)
      if out:match("^%-0%.?0*$") then
        out = out:sub(2)
      end
      return out
    end
  end
  return s
end

local function normName(name)
  return (trim(name):upper():gsub("[%s_]+", "_"))
end

--- Whether a variable's name marks it as a credential.
function M.isHidden(variableName)
  return Config.isFixedExclusion(variableName)
end

--- Finds one variable in a C4:GetDeviceVariables table (keyed by id, each
--- { name, value }) by its id or by its name (case, spaces and underscores
--- ignored). Returns { id, name, value } or nil.
function M.lookup(vars, key)
  if type(vars) ~= "table" then
    return nil
  end
  key = trim(key)
  if key == "" then
    return nil
  end
  if key:match("^%d+$") then
    for rawId, v in pairs(vars) do
      if tostring(rawId) == key and type(v) == "table" then
        return { id = tonumber(rawId), name = tostring(v.name or ""), value = v.value }
      end
    end
  end
  local want = normName(key)
  local found = nil
  for rawId, v in pairs(vars) do
    if type(v) == "table" and type(v.name) == "string" and normName(v.name) == want then
      local id = tonumber(rawId) or 0
      -- Two variables with one name: the lower id, so the answer is stable.
      if found == nil or id < found.id then
        found = { id = id, name = v.name, value = v.value }
      end
    end
  end
  return found
end

local function deviceName(d)
  return trim(d.deviceName or d.name or "")
end

--- A device from how a token names it: an id ("231"), "Room->Device" as
--- Control4 writes it, or a device name alone. `devices` has the
--- C4:GetDevices shape. Returns id, or nil + reason.
function M.findDevice(devices, text)
  text = trim(text)
  if text == "" then
    return nil, "no device"
  end
  if text:match("^%d+$") then
    return tonumber(text)
  end
  local room, name = text:match("^(.-)%->(.+)$")
  if room ~= nil then
    room, name = trim(room):lower(), trim(name):lower()
  else
    name = text:lower()
  end
  local matches = {}
  for rawId, d in pairs(devices or {}) do
    if type(d) == "table" and deviceName(d):lower() == name then
      if room == nil or trim(d.roomName):lower() == room then
        matches[#matches + 1] = tonumber(rawId)
      end
    end
  end
  if #matches == 1 then
    return matches[1]
  end
  if #matches > 1 then
    return nil, string.format("%d devices are called '%s': write Room->Device or the device id", #matches, text)
  end
  if room == nil and (name == "variables" or name == "project") then
    return M.PROJECT_VARIABLES_DEVICE
  end
  return nil, "no device called '" .. text .. "'"
end

--- Builds the function that turns a reference into a value.
--- @param deps table {
---   picked = fun(n):string|nil         -- the VARIABLE n parameter ("82,5015")
---   devices = fun():table|nil          -- C4:GetDevices shape
---   readVariables = fun(id):table|nil  -- C4:GetDeviceVariables shape
--- }
--- The returned function gives (value) or (nil, reason) or (HIDDEN, reason).
--- It reads each device once, however many tokens name it.
function M.resolver(deps)
  local cache, deviceList = {}, nil
  local function variablesOf(id)
    if cache[id] == nil then
      cache[id] = deps.readVariables(id) or false
    end
    return cache[id] or nil
  end
  local function read(deviceId, variable, where)
    local vars = variablesOf(deviceId)
    if vars == nil then
      return nil, string.format("%s: device %d has no readable variables", where, deviceId)
    end
    local v = M.lookup(vars, variable)
    if v == nil then
      return nil, string.format("%s: device %d has no variable '%s'", where, deviceId, tostring(variable))
    end
    if M.isHidden(v.name) then
      return M.HIDDEN, where .. ": a credential-named variable is never sent"
    end
    return v.value == nil and "" or v.value
  end
  return function(ref)
    if ref.kind == "pick" then
      local where = "variable " .. tostring(ref.pick)
      if ref.pick < 1 or ref.pick > M.PICKS then
        return nil, string.format("%s: VARIABLE parameters run from 1 to %d", where, M.PICKS)
      end
      local deviceId, variableId = M.parsePick(deps.picked(ref.pick))
      if deviceId == nil then
        return nil, where .. ": nothing picked in VARIABLE " .. ref.pick
      end
      return read(deviceId, tostring(variableId), where)
    end
    if deviceList == nil then
      deviceList = deps.devices() or {}
    end
    local deviceId, why = M.findDevice(deviceList, ref.device)
    if deviceId == nil then
      return nil, tostring(why)
    end
    return read(deviceId, ref.variable, "'" .. ref.device .. "'")
  end
end

--- Fills the tokens of one text.
--- @return string text, table problems ({ token, reason } each), table used (pick numbers written in the text)
function M.render(text, resolve)
  local problems, used, count = {}, {}, 0
  local out = tostring(text or ""):gsub(TOKEN, function(inner)
    if #inner > M.LIMITS.token then
      return nil
    end
    local ref = M.parseToken(inner)
    if ref == nil then
      return nil
    end
    local token = "${" .. inner .. "}"
    if ref.kind == "pick" then
      used[ref.pick] = true
    end
    count = count + 1
    if count > M.LIMITS.tokens then
      problems[#problems + 1] = { token = token, reason = "more than " .. M.LIMITS.tokens .. " variables in one text" }
      return M.MISSING
    end
    local value, reason = resolve(ref)
    if value == nil then
      problems[#problems + 1] = { token = token, reason = reason or "not found" }
      return M.MISSING
    end
    if value == M.HIDDEN and reason ~= nil then
      problems[#problems + 1] = { token = token, reason = reason }
      return M.HIDDEN
    end
    return M.format(value, ref.options)
  end)
  return out, problems, used
end

--- Fills a notification: the tokens of the title and the message, then every
--- picked variable that neither text wrote out, added at the end of the
--- message in order.
--- @param picked fun(n):string|nil  the VARIABLE n parameter
--- @return string title, string body, table problems
function M.fill(title, body, resolve, picked)
  local problems = {}
  local filledTitle, p1, usedTitle = M.render(title, resolve)
  local filledBody, p2, usedBody = M.render(body, resolve)
  for _, list in ipairs({ p1, p2 }) do
    for _, p in ipairs(list) do
      problems[#problems + 1] = p
    end
  end
  for n = 1, M.PICKS do
    if M.parsePick(picked(n)) ~= nil and not usedTitle[n] and not usedBody[n] then
      local added, p3 = M.render("${" .. n .. "}", resolve)
      for _, p in ipairs(p3) do
        problems[#problems + 1] = p
      end
      filledBody = filledBody == "" and added or (filledBody .. " " .. added)
    end
  end
  return filledTitle, filledBody, problems
end

return M

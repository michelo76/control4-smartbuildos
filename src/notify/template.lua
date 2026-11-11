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
--- The message is written in pieces, top to bottom, the way it reads:
---
---   MESSAGE      "The system rebooted"
---   VARIABLE 1   (picked)                -> 3
---   MESSAGE 2    "times since"
---   VARIABLE 2   (picked)                -> Monday
---   MESSAGE 3 .. MESSAGE 5, VARIABLE 3, VARIABLE 4
---
--- sends "The system rebooted 3 times since Monday". Each picked variable
--- goes where its row is, between the texts around it, so picking alone is
--- enough. A variable written as ${n} somewhere in the texts goes there
--- instead, and is not repeated at its row.
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
--- Texts of one message: MESSAGE, then MESSAGE 2 .. MESSAGE 5 (one after
--- each VARIABLE).
M.TEXTS = M.PICKS + 1
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

--- What sits tight against the word before it, and what sits tight against
--- the word after it. Composer may trim the spaces a dealer types at the
--- ends of a text, so the pieces are joined with one space, except here:
--- "rebooted" + "3" + "." reads "rebooted 3.", and "$" + "40" reads "$40".
local NO_SPACE_BEFORE = { ".", ",", ";", ":", "!", "?", "%", ")", "]", "}", "°" }
local NO_SPACE_AFTER = { "(", "[", "{", "$", "#", "£", "€" }

local function startsWith(s, list)
  for _, p in ipairs(list) do
    if s:sub(1, #p) == p then
      return true
    end
  end
  return false
end

local function endsWith(s, list)
  for _, p in ipairs(list) do
    if s:sub(-#p) == p then
      return true
    end
  end
  return false
end

--- Joins the pieces of a message in order, skipping the empty ones. A piece
--- is a text (a string) or a value ({ value = "3" }); only what the dealer
--- wrote decides the spacing, never what a variable happens to hold.
function M.join(pieces)
  local out, lastWasText = "", false
  for _, piece in ipairs(pieces) do
    local isText = type(piece) ~= "table"
    local text = trim(isText and piece or piece.value)
    if text ~= "" then
      local tight = out == ""
        or (isText and startsWith(text, NO_SPACE_BEFORE))
        or (lastWasText and endsWith(out, NO_SPACE_AFTER))
      out = out .. (tight and "" or " ") .. text
      lastWasText = isText
    end
  end
  return out
end

--- Fills a notification written in pieces.
--- @param title string|nil
--- @param texts table  { [1] = MESSAGE, [2] = MESSAGE 2, ... } (holes allowed)
--- @param resolve function  from M.resolver
--- @param picked fun(n):string|nil  the VARIABLE n parameter
--- @return string title, string body, table problems
function M.compose(title, texts, resolve, picked)
  local problems = {}
  local function keep(list)
    for _, p in ipairs(list) do
      problems[#problems + 1] = p
    end
  end
  local filledTitle, p0, used = M.render(title, resolve)
  keep(p0)
  local filled = {}
  for i = 1, M.TEXTS do
    local text, p, usedHere = M.render(texts[i], resolve)
    keep(p)
    filled[i] = text
    for n in pairs(usedHere) do
      used[n] = true
    end
  end
  local pieces = { filled[1] }
  for n = 1, M.PICKS do
    if M.parsePick(picked(n)) ~= nil and not used[n] then
      local value, p = M.render("${" .. n .. "}", resolve)
      keep(p)
      pieces[#pieces + 1] = { value = value }
    end
    pieces[#pieces + 1] = filled[n + 1]
  end
  return filledTitle, M.join(pieces), problems
end

--- Fills a notification with one text: the tokens of the title and the
--- message, then every picked variable that neither wrote out, in order.
--- @return string title, string body, table problems
function M.fill(title, body, resolve, picked)
  return M.compose(title, { body }, resolve, picked)
end

return M

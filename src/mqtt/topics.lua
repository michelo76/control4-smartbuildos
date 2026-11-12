--- MQTT topic names and filters (pure).
---
--- A topic NAME is what a message is published to; a topic FILTER is what a
--- subscription asks for and may carry `+` (exactly one level) and `#` (this
--- level and everything below, last level only). Spec rules kept:
---   * `sport/#` also matches `sport` (the parent level).
---   * A topic that starts with `$` (broker internals such as $SYS) is not
---     matched by a filter whose first level is a wildcard.
---   * Empty levels are real levels: `a//b` has three.

local M = {}

M.MAX_LENGTH = 65535

function M.split(s)
  local out, from = {}, 1
  while true do
    local i = s:find("/", from, true)
    if i == nil then
      out[#out + 1] = s:sub(from)
      return out
    end
    out[#out + 1] = s:sub(from, i - 1)
    from = i + 1
  end
end

--- A name a PUBLISH may carry.
--- @return boolean ok, string|nil why
function M.validName(topic)
  if type(topic) ~= "string" or topic == "" then
    return false, "topic is empty"
  end
  if #topic > M.MAX_LENGTH then
    return false, "topic is longer than 65535 bytes"
  end
  if topic:find("[#+]") then
    return false, "a topic to publish to cannot contain + or #"
  end
  if topic:find("\0", 1, true) then
    return false, "topic contains a NUL character"
  end
  return true
end

--- A filter a SUBSCRIBE may carry.
--- @return boolean ok, string|nil why
function M.validFilter(filter)
  if type(filter) ~= "string" or filter == "" then
    return false, "filter is empty"
  end
  if #filter > M.MAX_LENGTH then
    return false, "filter is longer than 65535 bytes"
  end
  if filter:find("\0", 1, true) then
    return false, "filter contains a NUL character"
  end
  local levels = M.split(filter)
  for i, level in ipairs(levels) do
    if level:find("#", 1, true) then
      if level ~= "#" then
        return false, "# must stand alone as a level"
      end
      if i ~= #levels then
        return false, "# is only allowed as the last level"
      end
    elseif level:find("+", 1, true) and level ~= "+" then
      return false, "+ must stand alone as a level"
    end
  end
  return true
end

function M.hasWildcard(filter)
  return type(filter) == "string" and filter:find("[#+]") ~= nil
end

--- Does `filter` match the published `topic`?
function M.matches(filter, topic)
  if type(filter) ~= "string" or type(topic) ~= "string" or filter == "" or topic == "" then
    return false
  end
  local f, t = M.split(filter), M.split(topic)
  if t[1]:sub(1, 1) == "$" and (f[1] == "#" or f[1] == "+") then
    return false
  end
  for i = 1, #f do
    local level = f[i]
    if level == "#" then
      return true -- also matches the parent: `a/#` against `a`
    end
    if t[i] == nil then
      return false
    end
    if level ~= "+" and level ~= t[i] then
      return false
    end
  end
  return #f == #t
end

return M

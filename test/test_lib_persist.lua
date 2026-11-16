--- lib.persist: what was stored is what comes back after a restart.
---
--- On the controller, C4:Base64Decode of text that is not Base64 gives an
--- empty string, and JSON:decode of an empty string gives nil without an
--- error. Read back through Deserialize, a plain stored string with a space,
--- a comma, a dot or a dash therefore came back as nil. The bench showed it
--- on 10 Nov 2026: the Agent's company name was painted after an entitlement
--- refresh and gone after every driver update, while the tier (one word of
--- Base64 letters) stayed.
JSON = require("JSON")
-- The real Serialize / Deserialize / PersistGetValue: the ones under test.
PersistGetValue, PersistSetValue, PersistDeleteValue = nil, nil, nil
require("drivers-common-public.global.lib")
local store = {}
function C4:PersistSetValue(key, value)
  store[key] = value
end
function C4:PersistGetValue(key)
  return store[key]
end
function C4:PersistDeleteValue(key)
  store[key] = nil
end
require("lib.utils")
local persist = require("lib.persist")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

-- The controller's decoder, as far as this bug goes: nothing for input that
-- is not Base64. The shim's own decoder skips the characters it does not
-- know, which is why no test saw this.
local realDecode = C4.Base64Decode
local function strictDecode(_, data)
  if type(data) ~= "string" or data:find("[^%w%+/=]") or #data % 4 ~= 0 then
    return ""
  end
  return realDecode(C4, data)
end

--- A driver restart: the stored values stay, the in-memory copy goes.
local function restart()
  persist._persist = {}
end

local function roundTrip(key, value, encrypted)
  persist:set(key, value, encrypted)
  restart()
  return persist:get(key, "", encrypted)
end

print("== plain strings survive a restart, with the controller's decoder")
C4.Base64Decode = strictDecode
check(
  "a name with spaces and a comma",
  roundTrip("t_name", "Example Audio And Video, LLC") == "Example Audio And Video, LLC"
)
check("a version with a dot", roundTrip("t_version", "20261110.070950") == "20261110.070950")
check("a day with dashes", roundTrip("t_day", "2026-11-09") == "2026-11-09")
check("a token with dots, dashes and underscores", roundTrip("t_token", "abc.def-ghi_jkl", true) == "abc.def-ghi_jkl")
check("one word of Base64 letters", roundTrip("t_tier", "Enterprise") == "Enterprise")
check("text that is valid Base64 of a JSON number stays text", roundTrip("t_b64", "MTIz") == "MTIz")
check("an empty string", roundTrip("t_empty", "") == "")

print("== everything else is unchanged")
local t = roundTrip("t_table", { a = 1, list = { "x", "y" }, name = "Two Words" })
check("a table comes back a table", type(t) == "table" and t.a == 1 and t.list[2] == "y" and t.name == "Two Words")
check("a number", roundTrip("t_number", 42) == 42)
check("a boolean", roundTrip("t_bool", true) == true)
check("false is kept, not defaulted", roundTrip("t_false", false) == false)
persist:set("t_gone", "x")
persist:delete("t_gone")
restart()
check("a deleted key gives the default", persist:get("t_gone", "default") == "default")
check("a key never set gives the default", persist:get("t_never", "default") == "default")

C4.Base64Decode = realDecode
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

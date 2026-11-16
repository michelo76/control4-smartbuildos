-- luacheck configuration for the SmartBuildOS Control4 drivers.
-- Run with `make lint`. See CONTRIBUTING.md, "Linting".
--
-- Control4 drivers lean on globals: Director supplies some (C4, Properties),
-- the vendored drivers-common-public library supplies more (EC, SetTimer,
-- JSON), and src/lib/utils.lua adds helpers (IsEmpty, tointeger). This file
-- names them so that luacheck stays quiet about those and still reports an
-- unknown name, which on a controller is a nil at run time.

std = "lua51"

-- StyLua owns layout (`make fmt`), so luacheck does not measure lines.
max_line_length = false

-- Director calls handlers with a fixed argument list; most handlers use only
-- part of it.
unused_args = false

ignore = {
  -- Re-declaring a local in the same function (`local ok, err = ...` twice)
  -- is house style. Shadowing an outer function's variable is still reported.
  "411",
  "421",
  -- A leading underscore marks a value that is unused on purpose.
  "21./_.*",
  -- An empty branch that holds only a comment documents a deliberate no-op.
  "542",
}

exclude_files = { "vendor/**", "build/**", "dist/**", ".venv/**", ".lua/**" }

-- Supplied by Director. Read-only for driver code.
local DIRECTOR = { "C4" }

-- Functions and constants defined by vendor/drivers-common-public/global/*.lua
-- and vendor/deferred.lua. Read-only in src/ modules, where assigning to one
-- would replace library behaviour for every driver that loads the module.
local VENDOR = {
  -- handlers.lua
  "AddVariable",
  "ExecuteCommand",
  "HandlerDebug",
  "OnBindingChanged",
  "OnConnectionStatusChanged",
  "OnDeviceEvent",
  "OnSystemEvent",
  "OnVariableChanged",
  "ReceivedFromNetwork",
  "ReceivedFromProxy",
  "RegisterDeviceEvent",
  "RegisterVariableListener",
  "SetVariable",
  "TestCondition",
  "UIRequest",
  "UnregisterDeviceEvent",
  "UnregisterVariableListener",
  "UpdateProperty",
  -- lib.lua
  "C2F",
  "ConstructJWT",
  "ConvertTime",
  "CopyTable",
  "CreateXML",
  "Deserialize",
  "EscapeForLuaPattern",
  "F2C",
  "FileRead",
  "FileWrite",
  "GetConnections",
  "GetFileName",
  "GetLocationInfo",
  "GetNextSchedulerOccurrence",
  "GetPathToDevice",
  "GetProject",
  "GetRandomString",
  "GetTableSize",
  "GetTimeNumber",
  "GetTimeString",
  "GetTruthy",
  "HideCurrentPopupEverywhere",
  "HideProxyInAllRooms",
  "IsFirstInstanceOfDriver",
  "MakeAscii",
  "MakeTagged",
  "PersistDeleteValue",
  "PersistGetValue",
  "PersistSetValue",
  "Print",
  "RefreshNavs",
  "RelativeTime",
  "RenameDevice",
  "SaltedDecrypt",
  "SaltedEncrypt",
  "Select",
  "Serialize",
  "ShowPopupEverywhere",
  "VersionCheck",
  "XMLCapture",
  "XMLDecode",
  "XMLEncode",
  "XMLTag",
  "XMLgCapture",
  "dbg",
  "dbgdump",
  "gettext",
  "getvartext",
  "tonumber_expect_comma",
  "tonumber_expect_period",
  "tonumber_native",
  "tostring_native",
  "tostring_return_comma",
  "tostring_return_period",
  -- timer.lua
  "CancelTimer",
  "ChangeTimer",
  "ExpireTimer",
  "KillAllTimers",
  "ONE_DAY",
  "ONE_HOUR",
  "ONE_MINUTE",
  "ONE_SECOND",
  "SetTimer",
  -- url.lua
  "MakeURL",
  "URLDecode",
  "URLEncode",
  "urlCustom",
  "urlDelete",
  "urlDo",
  "urlGet",
  "urlPost",
  "urlPut",
}

-- Helpers defined as globals by src/lib/utils.lua.
local UTILS = {
  "CheckMinimumVersion",
  "ConcatLists",
  "DeserializeSafe",
  "DeviceUpdated",
  "GCPL",
  "GetAgentId",
  "GetCommandParamList",
  "GetDevice",
  "GetDeviceBindings",
  "GetDeviceData",
  "GetDeviceProperties",
  "GetDriverVersion",
  "GetPropertyResetValues",
  "InRange",
  "IsEmpty",
  "IsList",
  "MinifyXml",
  "NearestValue",
  "ParseDeviceIdList",
  "ParseDeviceIdPropertyList",
  "ParseXml",
  "RegexEscape",
  "SendToDevice",
  "SendToNetwork",
  "SendToProxy",
  "SendUIRequest",
  "SerializeSafe",
  "SetDeviceProperties",
  "SortList",
  "TableDeepCopy",
  "TableKeys",
  "TableLength",
  "TableMap",
  "TableReverse",
  "TableValues",
  "UniqueList",
  "assertInt",
  "bininsert",
  "c2f",
  "delay",
  "f2c",
  "reject",
  "resolve",
  "round",
  "roundNearestHalf",
  "to_hex",
  "toboolean",
  "tointeger",
  "tonumber_locale",
  "toport",
}

-- Other helpers that one src/lib module defines for every driver.
local LIB = { "Bind", "GetConditionals" }

-- Clock overrides that only the test suite sets. A driver reads one, finds it
-- nil on a controller, and falls back to the real clock.
local TEST_HOOKS = {
  "DAYPART_LOCALTIME",
  "DAYPART_NOW",
  "FLIGHT_RECORDER_NOW",
  "GUEST_MODE_NOW",
  "LOGIC_PACK_NOW",
  "PIN_LOCK_NOW",
  "SOLAR_NOW",
}

local function join(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, name in ipairs(list) do
      out[#out + 1] = name
    end
  end
  return out
end

read_globals = join(DIRECTOR, VENDOR, UTILS, LIB, TEST_HOOKS)

-- `table.unpack` is absent in Lua 5.1; code that reads it must guard the call.
read_globals.table = { fields = { "unpack" } }

-- Names that driver code is meant to assign: Director's property tables, the
-- handler tables that drivers add functions to, the entry points Director
-- calls, and the switches the vendored library reads.
globals = {
  -- Director tables
  "Properties",
  "Variables",
  "PersistData",
  -- handler tables (drivers-common-public/global/handlers.lua)
  "EC",
  "OBC",
  "OCS",
  "ODE",
  "OPC",
  "OSE",
  "OVC",
  "OWVC",
  "RFN",
  "RFP",
  "TC",
  "UIR",
  -- entry points Director calls by name
  "OnDriverInit",
  "OnDriverLateInit",
  "OnDriverDestroyed",
  "OnPropertyChanged",
  "OnServerConnectionStatusChanged",
  "OnServerDataIn",
  "OnServerStatusChanged",
  "OnWatchedVariableChanged",
  "GetNotificationAttachmentURL",
  -- set by every driver.lua, read by the library and src modules
  "JSON",
  "DEBUGPRINT",
  "gInitialized",
  "DRIVER_GITHUB_REPO",
  "DRIVER_FILENAMES",
  "DC_PID",
  "DC_X",
  "DC_FILENAME",
  -- library switches and hooks
  "ON_HANDLER_ERROR",
  "ON_TIMER_ERROR",
  "ON_UNHANDLED_REJECTION",
  "DEBUG_RFN",
  "DEBUG_TIMER",
  "DEBUG_URL",
  "DEBUG_WEBSOCKET",
  "USER_AGENT",
  "USE_NEW_URL",
  "SSDP",
  "WebSocket",
}

-- src/lib/utils.lua, bindings.lua and conditionals.lua are where the helper
-- globals are defined, so there they are writable.
files["src/lib/utils.lua"] = { globals = UTILS }
files["src/lib/bindings.lua"] = { globals = { "Bind" } }
files["src/lib/conditionals.lua"] = { globals = { "GetConditionals" } }

-- A driver.lua keeps its own state and helpers in globals (gEngine,
-- runEngine). Any global the file assigns counts as defined; reading one that
-- is never assigned anywhere in the file is still reported, and so is one that
-- is assigned and never read. The names below are assigned for the packager
-- and the vendored library to read, so "never read here" is expected.
local DRIVER_FILE = {
  allow_defined = true,
  ignore = { "131/DC_.*", "131/DEBUGPRINT", "131/DEBUG_.*" },
}
files["drivers/*/driver.lua"] = DRIVER_FILE
files["src/mqtt/childdriver.lua"] = DRIVER_FILE
files["src/systemlink/companiondriver.lua"] = DRIVER_FILE

-- Tests and tools run on LuaJIT on a development machine. Tests stub C4,
-- replace os.time and print, and reach into the globals of the driver under
-- test, so global checks are off there. Tests also keep a result they do not
-- assert on (`local ok, why = f()`) and reuse short names across cases, so
-- those two checks are off for tests as well. Unused locals and functions are
-- still reported everywhere.
local NO_GLOBAL_CHECKS = { "11.", "12.", "13.", "14." }
files["test/**"] = { std = "luajit", ignore = join(NO_GLOBAL_CHECKS, { "311", "43." }) }
files["tools/**"] = { std = "luajit", ignore = NO_GLOBAL_CHECKS }

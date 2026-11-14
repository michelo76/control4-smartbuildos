--- VenueFlow: the command protocol between a page and the driver (pure).
---
--- This is VenueFlow's own message format. It is carried either as the body
--- of an HTTP POST to the driver's LAN relay, or as one JSON string inside the
--- documented WebView call C4.sendCommand(...). It is not a Control4 API.
---
--- Request:
---   { requestId = "req-123", command = "ROUTE_VIDEO",
---     payload = { sourceId = "sports-1", displayIds = { "tv-01", "tv-02" } },
---     ts = 1763000000, session = "<token>"?, since = <state version>? }
---
--- Reply (always, for every request):
---   { requestId, command, ok = true|false,
---     status = "ok" | "accepted" | "partial" | "planned" | "failed" | "denied",
---     errorCode?, message?, detail? (installer sessions only),
---     results? = { { id, name, status, errorCode?, message? }, ... },
---     data?, stateVersion, state? (when `since` was given and the state moved on), ts }
---
--- `accepted` means commands were sent and confirmation is awaited: the final
--- outcome per device is in the state document's `operations`. It never
--- means the devices changed.

local U = require("venueflow.util")
local Errors = require("venueflow.errors")

local M = {}

M.VERSION = 1
M.MAX_REQUEST_ID = 64
M.MAX_LIST = 256
--- The largest request body the relay accepts. A backup with several floor
--- plans is the largest thing a page sends.
M.MAX_REQUEST_BYTES = 4 * 1024 * 1024

--- Field kinds: s string, n number, b boolean, t table (object), l list of ids,
--- any. `?` after the kind makes it optional.
--- scope: public (no identity needed), operator (a profile or tile identity),
--- installer (an Installer Studio session).
M.COMMANDS = {
  -- public
  PING = { scope = "public", fields = {} },
  HELLO = { scope = "public", fields = {} },
  PROFILE_LOGIN = { scope = "public", fields = { profileId = "s", pin = "s" } },
  STUDIO_LOGIN = { scope = "public", fields = { passcode = "s" } },
  LOGOUT = { scope = "public", fields = {} },
  -- operator
  GET_STATE = { scope = "operator", fields = {} },
  ROUTE_VIDEO = { scope = "operator", fields = { sourceId = "s", displayIds = "l", audioZoneId = "s?" } },
  DISPLAY_POWER = {
    scope = "operator",
    fields = { displayIds = "l", power = "s" },
    enum = { power = { "on", "off" } },
  },
  AUDIO_SOURCE = { scope = "operator", fields = { zoneId = "s", sourceId = "s" } },
  AUDIO_VOLUME = { scope = "operator", fields = { zoneId = "s", level = "n" } },
  AUDIO_MUTE = { scope = "operator", fields = { zoneId = "s", muted = "b" } },
  AUDIO_POWER = { scope = "operator", fields = { zoneId = "s", power = "s" }, enum = { power = { "off" } } },
  AUDIO_PRESET = { scope = "operator", fields = { zoneId = "s", presetId = "s" } },
  LIGHTING_PRESET = { scope = "operator", fields = { lightingId = "s", presetId = "s" } },
  SHADE = { scope = "operator", fields = { shadeId = "s", action = "s" }, enum = { action = { "open", "close" } } },
  SCENE_PREVIEW = { scope = "operator", fields = { sceneId = "s" } },
  SCENE_ACTIVATE = { scope = "operator", fields = { sceneId = "s", confirm = "b?", areaId = "s?" } },
  ALL_OFF_PREVIEW = { scope = "operator", fields = {} },
  ALL_OFF = { scope = "operator", fields = { confirm = "b?" } },
  VENUE_STATUS = { scope = "operator", fields = { status = "s" }, enum = { status = { "open", "closed" } } },
  QUERY_STATUS = { scope = "operator", fields = { displayIds = "l?" } },
  ALERT_DISMISS = { scope = "operator", fields = { alertId = "s" } },
  IMAGE_GET = { scope = "operator", fields = { key = "s" } },
  OPERATION_GET = { scope = "operator", fields = { operationId = "s" } },
  -- installer
  STUDIO_BOOTSTRAP = { scope = "installer", fields = {} },
  DRAFT_GET = { scope = "installer", fields = {} },
  DRAFT_SAVE = { scope = "installer", fields = { config = "t", baseRevision = "n?" } },
  DRAFT_VALIDATE = { scope = "installer", fields = {} },
  DRAFT_DISCARD = { scope = "installer", fields = { confirm = "b?" } },
  TEMPLATE_APPLY = {
    scope = "installer",
    fields = { venueType = "s", name = "s?", sample = "b?", confirm = "b?" },
  },
  PROFILE_PIN_SET = { scope = "installer", fields = { profileId = "s", pin = "s?", baseRevision = "n?" } },
  IMAGE_PUT = { scope = "installer", fields = { dataUrl = "s" }, large = true },
  -- One id per acknowledged warning: a large unmapped venue has many.
  PUBLISH = { scope = "installer", fields = { acknowledged = "l?", note = "s?" }, maxList = 4000, maxItem = 200 },
  VERSIONS = { scope = "installer", fields = {} },
  ROLLBACK = { scope = "installer", fields = { versionId = "s", confirm = "b?" } },
  BACKUP_EXPORT = { scope = "installer", fields = {} },
  BACKUP_RESTORE = { scope = "installer", fields = { backup = "t", which = "s?", confirm = "b?" }, large = true },
  DISCOVER = { scope = "installer", fields = {} },
  TEST_DEVICE = {
    scope = "installer",
    fields = { test = "s", displayId = "s?", zoneId = "s?", sourceId = "s?", confirm = "b?" },
    enum = { test = { "power_on", "power_off", "source", "route", "status" } },
  },
  TEST_RESULT = { scope = "installer", fields = { testId = "s" } },
  PROGRAM_VALIDATE = { scope = "installer", fields = { program = "t", condition = "t?", trigger = "t?" } },
  PROGRAM_DRY_RUN = { scope = "installer", fields = { program = "t", condition = "t?", name = "s?" } },
  PROGRAM_EXECUTE = {
    scope = "installer",
    fields = { program = "t", condition = "t?", name = "s?", confirm = "b?", refKind = "s?", refId = "s?" },
    enum = { refKind = { "scene", "rule" } },
  },
  EXECUTION_CANCEL = { scope = "installer", fields = { executionId = "s" } },
  EXECUTIONS = { scope = "installer", fields = {} },
  DIAG_GET = { scope = "installer", fields = { limit = "n?", level = "s?", category = "s?", sinceSeq = "n?" } },
  DIAG_CLEAR = { scope = "installer", fields = {} },
  LICENSE_GET = { scope = "installer", fields = {} },
  LICENSE_REFRESH = { scope = "installer", fields = {} },
  SESSIONS_REVOKE = { scope = "installer", fields = {} },
  SIM_FAULT = { scope = "installer", fields = { targetId = "n", fault = "s?" } },
  SIM_EXTERNAL = { scope = "installer", fields = { roomId = "n", changes = "t" } },
}

local KIND_TYPE = { s = "string", n = "number", b = "boolean", t = "table", l = "table" }

local function bad(code, detail)
  return nil, Errors.fail(code, detail)
end

--- Validates a decoded request. Returns the cleaned request, or nil + failure.
function M.validate(request)
  if type(request) ~= "table" then
    return bad("VF_BAD_REQUEST", "the request is not an object")
  end
  local requestId = request.requestId
  if type(requestId) ~= "string" or requestId == "" or #requestId > M.MAX_REQUEST_ID then
    return bad("VF_BAD_REQUEST", "requestId is missing or too long")
  end
  if not requestId:match("^[%w%-_%.:]+$") then
    return bad("VF_BAD_REQUEST", "requestId has unexpected characters")
  end
  local name = request.command
  if type(name) ~= "string" then
    return bad("VF_BAD_REQUEST", "command is missing")
  end
  local spec = M.COMMANDS[name]
  if spec == nil then
    return bad("VF_UNKNOWN_COMMAND", "unknown command " .. U.oneLine(name, 40))
  end
  local payload = request.payload
  if payload == nil then
    payload = {}
  end
  if type(payload) ~= "table" then
    return bad("VF_INVALID_PAYLOAD", "payload must be an object")
  end
  if request.ts ~= nil and type(request.ts) ~= "number" then
    return bad("VF_BAD_REQUEST", "ts must be a number")
  end
  if request.session ~= nil and type(request.session) ~= "string" then
    return bad("VF_BAD_REQUEST", "session must be a string")
  end
  if request.since ~= nil and type(request.since) ~= "number" then
    return bad("VF_BAD_REQUEST", "since must be a number")
  end
  local clean = {}
  for field, kind in pairs(spec.fields) do
    local optional = kind:sub(-1) == "?"
    local base = optional and kind:sub(1, -2) or kind
    local value = payload[field]
    if value == nil then
      if not optional then
        return bad("VF_INVALID_PAYLOAD", field .. " is required")
      end
    else
      if base ~= "any" and type(value) ~= KIND_TYPE[base] then
        return bad("VF_INVALID_PAYLOAD", field .. " has the wrong type")
      end
      if base == "s" and #value > (spec.large and 2 * 1024 * 1024 or 4096) then
        return bad("VF_TOO_LARGE", field .. " is too long")
      end
      if base == "n" and (value ~= value or value == math.huge or value == -math.huge) then
        return bad("VF_INVALID_PAYLOAD", field .. " is not a finite number")
      end
      if base == "l" then
        if not U.isList(value) then
          return bad("VF_INVALID_PAYLOAD", field .. " must be a list")
        end
        if #value > (spec.maxList or M.MAX_LIST) then
          return bad("VF_INVALID_PAYLOAD", field .. " has too many entries")
        end
        for _, item in ipairs(value) do
          if type(item) ~= "string" or #item > (spec.maxItem or 96) then
            return bad("VF_INVALID_PAYLOAD", field .. " must list ids")
          end
        end
      end
      if spec.enum and spec.enum[field] and not U.contains(spec.enum[field], value) then
        return bad("VF_INVALID_PAYLOAD", field .. " has an unknown value")
      end
      clean[field] = value
    end
  end
  for field in pairs(payload) do
    if spec.fields[field] == nil then
      return bad("VF_INVALID_PAYLOAD", "unexpected field " .. U.oneLine(field, 40))
    end
  end
  return {
    requestId = requestId,
    command = name,
    payload = clean,
    ts = request.ts,
    session = request.session,
    since = request.since,
    scope = spec.scope,
  }
end

--- Builds the reply envelope from an engine result.
function M.reply(request, result, extra)
  result = type(result) == "table" and result or { ok = false, errorCode = "VF_INTERNAL" }
  local out = {
    requestId = type(request) == "table" and request.requestId or nil,
    command = type(request) == "table" and request.command or nil,
    ok = result.ok == true,
    status = result.status or (result.ok and "ok" or "failed"),
    errorCode = result.errorCode,
    message = result.message or (result.errorCode and Errors.operatorText(result.errorCode) or nil),
    detail = result.detail,
    results = result.results,
    summary = result.summary,
    operationId = result.operationId,
    data = result.data,
  }
  for k, v in pairs(extra or {}) do
    out[k] = v
  end
  return out
end

--- The schema as data, for the documentation and the Studio.
function M.describe()
  local out = {}
  for _, name in ipairs(U.sortedKeys(M.COMMANDS)) do
    local spec = M.COMMANDS[name]
    local fields = {}
    for _, field in ipairs(U.sortedKeys(spec.fields)) do
      fields[#fields + 1] = { name = field, kind = spec.fields[field] }
    end
    out[#out + 1] = { command = name, scope = spec.scope, fields = fields, enum = spec.enum }
  end
  return out
end

return M

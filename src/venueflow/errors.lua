--- VenueFlow: the one catalogue of error codes.
---
--- Every refusal and every failed device operation carries one of these. The
--- `operator` text is what a bartender may read; installer detail is added by
--- the caller as `detail`. `http` is the status the LAN relay answers with.

local M = {}

M.CODES = {
  -- transport and protocol
  VF_BAD_REQUEST = { http = 400, operator = "That request could not be read." },
  VF_UNKNOWN_COMMAND = { http = 400, operator = "This screen asked for something the system does not know." },
  VF_INVALID_PAYLOAD = { http = 422, operator = "That request was incomplete." },
  VF_TOO_LARGE = { http = 413, operator = "That is too large to save." },
  -- identity and permission
  VF_UNAUTHENTICATED = { http = 401, operator = "Please sign in." },
  VF_FORBIDDEN = { http = 403, operator = "Your profile is not allowed to do that." },
  VF_LOCKED = { http = 429, operator = "Too many wrong attempts. Wait a minute and try again." },
  VF_BAD_PIN = { http = 403, operator = "That PIN is not right." },
  VF_BAD_PASSCODE = { http = 403, operator = "That passcode is not right." },
  VF_STUDIO_DISABLED = { http = 403, operator = "Installer Studio is off until an Installer Passcode is set." },
  VF_CONFIRM_REQUIRED = { http = 409, operator = "Please confirm this action." },
  VF_LICENSE_RESTRICTED = { http = 403, operator = "This feature needs a SmartBuildOS licence." },
  -- configuration
  VF_NO_PUBLISHED_CONFIG = { http = 409, operator = "This venue has not been set up yet." },
  VF_VALIDATION_FAILED = { http = 422, operator = "The configuration has problems to fix first." },
  VF_STALE_DRAFT = { http = 409, operator = "Someone else changed the draft. Reload and try again." },
  VF_NOT_FOUND = { http = 404, operator = "That item no longer exists." },
  VF_STORAGE_FAILED = { http = 500, operator = "The change could not be saved." },
  -- device operations
  VF_DEVICE_UNMAPPED = { http = 422, operator = "This device is not connected to Control4 yet." },
  VF_UNSUPPORTED = { http = 422, operator = "This device cannot do that." },
  VF_SOURCE_UNAVAILABLE = { http = 422, operator = "That source is not available." },
  VF_SOURCE_NOT_ALLOWED = { http = 422, operator = "That source cannot be shown here." },
  VF_ROUTE_UNSUPPORTED = { http = 422, operator = "That source cannot reach this display." },
  VF_NO_SOURCE_FOR_POWER_ON = { http = 422, operator = "Choose a source to turn this display on." },
  VF_DEVICE_OFFLINE = { http = 503, operator = "This device is not responding." },
  VF_DISPATCH_FAILED = { http = 502, operator = "The command could not be sent." },
  VF_NOT_CONFIRMED = { http = 504, operator = "The device did not confirm the change." },
  VF_SUPERSEDED = { http = 409, operator = "A newer request replaced this one." },
  VF_CANCELLED = { http = 409, operator = "This was stopped before it finished." },
  -- programming
  VF_RECURSION_LIMIT = { http = 422, operator = "This scene runs itself in a loop." },
  VF_CONDITION_FALSE = { http = 200, operator = "The scene's condition is not met right now." },
  -- other
  VF_SIMULATION_ONLY = { http = 403, operator = "That is only available in Simulation mode." },
  VF_INTERNAL = { http = 500, operator = "Something went wrong inside the driver." },
}

function M.operatorText(code)
  local entry = M.CODES[code]
  return entry and entry.operator or "Something went wrong."
end

function M.httpStatus(code)
  local entry = M.CODES[code]
  return entry and entry.http or 500
end

--- A failed result. `detail` is for the installer; it is never shown to an
--- operator profile (core strips it).
function M.fail(code, detail, extra)
  if M.CODES[code] == nil then
    detail = string.format("(unknown code %s) %s", tostring(code), tostring(detail or ""))
    code = "VF_INTERNAL"
  end
  local out = { ok = false, errorCode = code, message = M.operatorText(code), detail = detail }
  for k, v in pairs(extra or {}) do
    out[k] = v
  end
  return out
end

return M

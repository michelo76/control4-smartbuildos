-- Fixture for test/test_drivers_smoke.lua: a driver with one bug in each
-- place the smoke harness looks, so the test proves the harness reports them.
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

function OnDriverLateInit()
  -- A timer whose callback fails once it fires (phase "init" advance).
  SetTimer("broken", 30 * 1000, function()
    local missing = nil
    return missing.field
  end)
end

function EC.FINE() end

function EC.BROKEN_ACTION()
  error("action failed on purpose")
end

function EC.BROKEN_COMMAND(params)
  -- Composer sends parameters as strings; arithmetic on a nil one fails.
  return params.NOT_SENT + 1
end

function OPC.Host(value)
  -- Fails only for the empty string the harness sends.
  if value == "" then
    error("empty host not handled")
  end
end

function OPC.Mode(value)
  -- A driver that catches its own error and prints the traceback.
  local ok, err = xpcall(function()
    error("mode change failed")
  end, debug.traceback)
  if not ok then
    print(err)
  end
end

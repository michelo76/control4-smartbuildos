-- Tests for src/sbos/agenttelemetry.lua — the pure half of what the Agent
-- reads off Director beyond device online/offline: system event names and
-- routes, the programming census, the clock offset from the platform's Date
-- header, the /proc vitals parsers, and the restart cause.
--
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/src/?/init.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_agent_telemetry.lua

local T = require("sbos.agenttelemetry")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

print("\n[1] system event names, as shipped drivers read them")
check(
  "the name attribute of Director's XML payload",
  T.eventNameFrom('<event name="OnItemAdded" deviceid="312"/>') == "OnItemAdded"
)
check("a <name> element", T.eventNameFrom("<event><name>OnPIP</name></event>") == "OnPIP")
check("a bare name", T.eventNameFrom("OnSystemShutDown") == "OnSystemShutDown")
check("a table with a name", T.eventNameFrom({ name = "OnZigbeeNodeOffline" }) == "OnZigbeeNodeOffline")
check("a numeric id through the vendored table", T.eventNameFrom(85) == "OnSystemShutDown")
check("garbage is unknown, never an error", T.eventNameFrom("<x/>") == "unknown" and T.eventNameFrom(nil) == "unknown")
check(
  "every registered id has a name",
  (function()
    for id, name in pairs(T.SYSTEM_EVENT_NAMES) do
      if type(id) ~= "number" or type(name) ~= "string" or not name:match("^On") then
        return false
      end
    end
    return true
  end)()
)

print("\n[2] routes")
check("online/offline stay on the poll path", T.classifySystemEvent("OnDeviceOffline") == "device")
check("Composer edits are project changes", T.classifySystemEvent("OnItemNameChanged") == "project")
check("programming edits", T.classifySystemEvent("OnCodeItemAdded") == "programming")
check("zigbee", T.classifySystemEvent("OnZigbeeMeshChanged") == "zigbee")
check("shutdown", T.classifySystemEvent("OnSystemShutDown") == "shutdown")
check("os update", T.classifySystemEvent("OnSystemUpdateStarted") == "os_update")
check("identity", T.classifySystemEvent("OnDirectorIPAddressChanged") == "identity")
check("an unknown name routes to unknown (the old behaviour)", T.classifySystemEvent("unknown") == "unknown")

print("\n[3] programming census counts nested lines, not only attachments")
local census = T.programmingCensus({
  event_mgr = {
    {
      codeitem = {
        enabled = true,
        display = "When the front door opens",
        subitems = {
          { enabled = true, display = "Turn on the Porch Light" },
          { enabled = false, display = "Send a push notification" },
          { enabled = true, display = "", subitems = { { enabled = true, display = "Delay 5 s" } } },
        },
      },
    },
    { codeitem = { enabled = false, display = "Old: dim at dusk" } },
  },
  schedule = { { codeitem = { enabled = true, display = "Every day at sunset" } } },
})
check(
  "groups, attachments, lines, text, disabled",
  census.groups == 2
    and census.attachments == 3
    and census.lines == 7
    and census.with_text == 6
    and census.disabled == 2,
  JSON and JSON:encode(census) or tostring(census.lines)
)
check("a non-table is an empty census", T.programmingCensus(nil).lines == 0)
check("the property line", T.programmingText(census) == "3 attachment(s) · 7 line(s) · 2 disabled")

print("\n[4] clock offset from the Date header")
check("RFC 1123 parses to a UTC epoch", T.parseHttpDate("Wed, 21 Oct 2026 07:35:00 GMT") == 1792568100)
check("the epoch itself", T.parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT") == 0)
check("a leap day", T.parseHttpDate("Tue, 29 Feb 2028 12:00:00 GMT") == 1835438400)
check("garbage is nil", T.parseHttpDate("yesterday") == nil and T.parseHttpDate(nil) == nil)
check(
  "the header is found whatever its case",
  T.dateHeader({ ["date"] = "x" }) == "x" and T.dateHeader({ Date = "y" }) == "y"
)
check(
  "offset is platform minus controller",
  T.clockOffsetSeconds({ Date = "Wed, 21 Oct 2026 07:35:00 GMT" }, 1792568100 - 90) == 90
)
check("no header, no offset", T.clockOffsetSeconds({}, 1792568100) == nil)
check("drift wording", T.clockOffsetText(130):find("DRIFT", 1, true) ~= nil and T.clockOffsetText(3) == "+3 s")
check("unmeasured wording", T.clockOffsetText(nil) == "not measured")

print("\n[5] /proc parsers")
local load = T.parseLoadavg("0.52 0.58 0.59 1/160 1234\n")
check("loadavg", load and load.load1 == 0.52 and load.load15 == 0.59 and load.tasks == 160)
local mem = T.parseMeminfo(
  "MemTotal:        2048000 kB\nMemFree:          512000 kB\nMemAvailable:    1024000 kB\nBuffers:           10000 kB\n"
)
check("meminfo with MemAvailable", mem and mem.total_kb == 2048000 and mem.available_kb == 1024000)
local memOld = T.parseMeminfo("MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 150 kB\n")
check("meminfo on an old kernel sums free+buffers+cached", memOld and memOld.available_kb == 300)
check("uptime", T.parseProcUptime("12345.67 23456.78\n") == 12345)
check("thermal in millidegrees", T.parseThermal("45678\n") == 45.7)
check("thermal in degrees", T.parseThermal("46") == 46)
check("nothing parses nil", T.parseLoadavg(nil) == nil and T.parseMeminfo("") == nil and T.parseThermal("x") == nil)

local files = {
  ["/proc/loadavg"] = "0.10 0.20 0.30 2/100 99",
  ["/proc/meminfo"] = "MemTotal: 1000 kB\nMemAvailable: 250 kB\n",
}
local vitals = T.readVitals(function(path)
  return files[path]
end)
check(
  "readVitals reports only what answered",
  vitals and vitals.load1 == 0.10 and vitals.mem_used_pct == 75 and vitals.cpu_temp_c == nil and #vitals.readable == 2,
  vitals and table.concat(vitals.readable, ",")
)
check("nothing readable is nil, not an empty block", T.readVitals(function()
  return nil
end) == nil)
check("vitals wording", T.vitalsText(vitals):find("mem 75.0%% used", 1, false) ~= nil, T.vitalsText(vitals))
check("not readable wording", T.vitalsText(nil) == "not readable on this OS")

print("\n[6] restart cause from the markers Director leaves")
local now = 1792568100
check("a first start has no cause", T.classifyRestart("first", {}, now) == nil)
check("a driver update has no cause", T.classifyRestart("update", { shutdown_at = now - 10 }, now) == nil)
check(
  "a reload after OnSystemShutDown is clean",
  T.classifyRestart("reload", { shutdown_at = now - 120 }, now) == "clean"
)
check(
  "a reload after OnSystemUpdateStarted is an OS update, even with a shutdown too",
  T.classifyRestart("reload", { shutdown_at = now - 100, os_update_at = now - 600 }, now) == "os-update"
)
check("no marker: unexpected", T.classifyRestart("reload", {}, now) == "unexpected")
check(
  "a stale marker (older than 6 h) does not explain a restart",
  T.classifyRestart("reload", { shutdown_at = now - 7 * 3600 }, now) == "unexpected"
)
check(
  "a marker from the future is ignored",
  T.classifyRestart("reload", { shutdown_at = now + 60 }, now) == "unexpected"
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

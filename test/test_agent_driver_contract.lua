local pass, fail = 0, 0

local function read(path)
  local file = assert(io.open(path, "rb"))
  local value = file:read("*a")
  file:close()
  return value
end

local function check(name, ok)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name)
  end
end

local xml = read("drivers/smartbuildos/driver.xml")
local lua = read("drivers/smartbuildos/driver.lua")

print("\n[1] Existing Composer identifiers remain frozen")
for id, name in pairs({
  [2000] = "DIRECTOR_RELOADS",
  [2001] = "LAST_RELOAD",
  [2002] = "NOTICE_TYPE",
  [2003] = "ISSUE_SEVERITY",
  [2004] = "ISSUE_TEXT",
  [2005] = "NOTICE_TEXT",
}) do
  check(
    "variable " .. id .. " remains " .. name,
    xml:find("<id>" .. id .. "</id>%s*<name>" .. name .. "</name>") ~= nil
  )
end
for id, name in pairs({
  [1] = "Connected",
  [2] = "Disconnected",
  [3] = "Sync Failed",
  [4] = "Paired",
  [5] = "Device Went Offline",
  [6] = "Device Came Online",
  [7] = "Director Reloaded",
  [8] = "Service Update",
  [9] = "Issue Detected",
  [10] = "Issue Resolved",
  [11] = "Issue Updated",
}) do
  check("event " .. id .. " remains " .. name, xml:find("<id>" .. id .. "</id>%s*<name>" .. name .. "</name>") ~= nil)
end

print("\n[2] Contract v1 Composer surfaces are present")
for id, name in pairs({
  [2006] = "SYSTEM_STARTUPS_TODAY",
  [2007] = "CONTROLLER_REBOOTS_OBSERVED_TODAY",
  [2008] = "SERVICE_MODE_ACTIVE",
  [2009] = "CLOUD_CONNECTED",
  [2010] = "REPORT_STATUS",
  [2011] = "LICENSE_STATE",
}) do
  check("read-only variable " .. name, xml:find("<id>" .. id .. "</id>%s*<name>" .. name .. "</name>") ~= nil)
end
for id, name in pairs({
  [12] = "System Startup Observed",
  [13] = "Controller Reboot Observed",
  [14] = "Startup Threshold Reached",
  [15] = "Report Ready",
  [16] = "Report Failed",
  [17] = "Notification Failed",
  [18] = "Cloud Connection Changed",
  [19] = "License Status Changed",
  [20] = "Controller Mismatch",
}) do
  check("event " .. name, xml:find("<id>" .. id .. "</id><name>" .. name .. "</name>") ~= nil)
end
for _, command in ipairs({
  "GENERATE_SYSTEM_REPORT",
  "SEND_SYSTEM_REPORT",
  "SEND_TEST_NOTIFICATION",
  "REFRESH_INVENTORY",
  "RECORD_SERVICE_NOTE",
  "CHECK_FOR_UPDATES",
  "ENTER_SERVICE_MODE",
  "EXIT_SERVICE_MODE",
  "REFRESH_STATUS",
  "CAMERA_READ_ONLY_PROBE",
}) do
  check(
    "command " .. command,
    xml:find("<command>" .. command .. "</command>", 1, true) ~= nil
      or xml:find("<name>" .. command .. "</name>", 1, true) ~= nil
  )
end

print("\n[3] Runtime delivery and evidence boundaries are wired")
check("Agent config self-applies", lua:find("ApplyAgentConfigBlock%(cfg%)") ~= nil)
check("other SKU configs still forward", lua:find("forwardDriverConfig%(cfg%)") ~= nil)
check("heartbeat declares Agent contract", lua:find("agent_contract = {%s*contract_version") ~= nil)
check("init reason is consumed", lua:find("function OnDriverLateInit%(reason%)") ~= nil)
check("boot identity is optional", lua:find("C4.GetBootID == nil") ~= nil)
check("startup observations use authenticated route", lua:find('send%("startup%-observation"') ~= nil)
check("pending observations persist", lua:find("AGENT_PENDING_OBSERVATION_KEY") ~= nil)
check("report requests do not claim delivery", lua:find('lastReportStatus = "request%-recorded"') ~= nil)
check("existing generic driver registration remains", lua:find("function EC.SBOS_REGISTER_DRIVER") ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end

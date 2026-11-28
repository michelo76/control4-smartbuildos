-- Smoke test over EVERY driver: tools/smoke-driver.lua loads each one under
-- the shim in its own interpreter and drives it as Director would (defaults,
-- init, every writable property, every command and action, ten minutes of
-- timers, a reload with the persisted data kept). Any Lua error fails here.
--
-- A per-driver suite tests behaviour; this one catches what no suite was
-- written for. Its first run (28 Nov 2026) found Guest Mode calling the
-- global `urlDo` without loading the library that defines it, so the built
-- package lacked it; Guest Mode's own suite had supplied the library itself.
--
-- The harness is checked first against test/fixtures/smoke-broken, a driver
-- with one bug in each place it looks, so a harness that stops seeing errors
-- fails this test instead of passing every driver.
--
-- Run from the driver root: make test (LUA=lua5.1 make test for Lua 5.1).

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local LUA = os.getenv("LUA")
if LUA == nil or LUA == "" then
  LUA = "luajit"
end

--- Runs the harness on one driver directory: exit code and output lines.
local function smoke(dir)
  local p = io.popen(LUA .. " tools/smoke-driver.lua " .. dir .. ' 2>&1; echo "RC=$?"')
  local lines, rc = {}, nil
  for line in p:lines() do
    local code = line:match("^RC=(%d+)$")
    if code then
      rc = tonumber(code)
    else
      lines[#lines + 1] = line
    end
  end
  p:close()
  return rc, lines
end

local function has(lines, pattern)
  for _, line in ipairs(lines) do
    if line:find(pattern) then
      return true
    end
  end
  return false
end

print("[1] the harness reports each kind of error (fixture driver)")
do
  local rc, lines = smoke("test/fixtures/smoke-broken")
  check("fixture fails", rc == 1, rc)
  check("a failing timer callback", has(lines, "^ERROR init timer broken: .*attempt to index"))
  check("a failing property handler", has(lines, "^ERROR properties OPC%.Host: .*empty host not handled"))
  check("a failing command", has(lines, "^ERROR commands EC%.BROKEN_COMMAND: .*arithmetic"))
  check("a failing action (LUA_ACTION)", has(lines, "^ERROR commands EC%.BROKEN_ACTION: .*on purpose"))
  check(
    "a traceback the driver printed itself",
    has(lines, "^ERROR properties printed traceback: .*mode change failed")
  )
  check("the reload runs the driver again", has(lines, "^ERROR reload timer broken"))
  check("a working action is not reported", not has(lines, "FINE"))
  local handlerLines = 0
  for _, line in ipairs(lines) do
    if line:find("EC.BROKEN_ACTION", 1, true) or line:find("action failed on purpose", 1, true) then
      handlerLines = handlerLines + 1
    end
  end
  check("a handler error is reported once, not twice", handlerLines == 1, handlerLines)
end

print("[2] every driver runs without a Lua error")
local dirs = {}
local p = io.popen("ls -d drivers/*/ 2>/dev/null")
for line in p:lines() do
  dirs[#dirs + 1] = line:gsub("/$", "")
end
p:close()
check("found drivers", #dirs > 0, #dirs)

local totals = { commands = 0, actions = 0, properties = 0, timers = 0 }
for _, dir in ipairs(dirs) do
  local rc, lines = smoke(dir)
  local errs = {}
  for _, line in ipairs(lines) do
    if line:match("^ERROR ") then
      errs[#errs + 1] = line:sub(7)
    end
    local summary = line:match("^SUMMARY (.*)")
    if summary then
      for k, v in summary:gmatch("(%a+)=(%d+)") do
        if totals[k] then
          totals[k] = totals[k] + tonumber(v)
        end
      end
    end
  end
  local detail = rc ~= 0 and (#errs > 0 and table.concat(errs, "\n         ") or table.concat(lines, " | ")) or nil
  check(dir, rc == 0, detail)
end

print(
  string.format(
    "  (exercised %d commands, %d actions, %d property changes, %d timer runs)",
    totals.commands,
    totals.actions,
    totals.properties,
    totals.timers
  )
)
check(
  "the run exercised commands, actions, properties and timers",
  totals.commands > 0 and totals.actions > 0 and totals.properties > 0 and totals.timers > 0
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

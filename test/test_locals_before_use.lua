-- No driver may read a file-level local before the line that declares it.
--
-- ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
--
-- Lua resolves a name at COMPILE time. `local function foo()` on line 6272
-- does not exist on line 6222: a `foo` written there is a read of the GLOBAL
-- `foo`, which nobody set, so it is nil. Nothing complains when the file
-- loads. The SmartBuildOS Agent did exactly this with the function that
-- registers for Director's system events, inside a table of guarded init
-- steps: the guard logged one line and carried on, and the Agent never
-- received a single system event on a controller. The driver tests could not
-- see it, because OnDriverLateInit does not run under the shim.
--
-- So this file reads every driver's source and fails on the pattern itself:
-- a name declared `local` at the start of a line, used as a bare identifier
-- on an earlier line. Comments and strings are removed first; a field
-- (`x.name`, `x:name`), a table key (`name = ...`) and an earlier nested
-- declaration of the same name (a parameter, a `local`, a loop variable) are
-- not uses of the later local.
--
-- Run from the driver root:
--   make test

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

--- Source with comments and string contents blanked, line count preserved.
local function stripped(source)
  local keepLines = function(text)
    return (text:gsub("[^\n]", ""))
  end
  -- Long comments and long strings first (they span lines), then the rest.
  source = source:gsub("%-%-%[(=*)%[.-%]%1%]", keepLines)
  source = source:gsub("%[(=*)%[.-%]%1%]", keepLines)
  local out = {}
  for line in (source .. "\n"):gmatch("(.-)\n") do
    line = line:gsub('\\"', ""):gsub("\\'", "")
    line = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
    line = line:gsub("%-%-.*$", "")
    out[#out + 1] = line
  end
  return out
end

--- @return string[] findings "line N uses NAME (declared local at line M)"
local function usesBeforeDeclaration(source)
  local lines = stripped(source)
  local findings, declared = {}, {}
  for i, line in ipairs(lines) do
    local name = line:match("^local function ([%a_][%w_]*)")
      or line:match("^local ([%a_][%w_]*)%s*=")
      or line:match("^local ([%a_][%w_]*)%s*$")
    if name and not declared[name] then
      declared[name] = true
      for j = 1, i - 1 do
        local text = lines[j]
        local from = 1
        while true do
          local a, b = text:find("%f[%w_]" .. name .. "%f[^%w_]", from)
          if not a then
            break
          end
          local before = text:sub(1, a - 1)
          local previous = before:sub(-1)
          local isField = previous == "." or previous == ":"
          local isKey = text:sub(b + 1):match("^%s*=[^=]") ~= nil and before:match("[{,]%s*$") ~= nil
          local isNested = text:match("local%s+[%w_,%s]*%f[%w_]" .. name .. "%f[^%w_]") ~= nil
            or text:match("function%s*[%w_.:]*%([^)]*%f[%w_]" .. name .. "%f[^%w_]") ~= nil
            or text:match("for%s+[%w_,%s]*%f[%w_]" .. name .. "%f[^%w_]") ~= nil
          if not (isField or isKey or isNested) then
            findings[#findings + 1] = string.format("line %d uses %s (declared local at line %d)", j, name, i)
          end
          from = b + 1
        end
      end
    end
  end
  return findings
end

print("\n[1] The check itself sees the mistake and nothing else")

local broken = table.concat({
  "function Init()",
  "  for _, step in ipairs({ { 'register', register } }) do",
  "    pcall(step[2])",
  "  end",
  "end",
  "local function register() end",
}, "\n")
check("a local function named before its declaration is found", #usesBeforeDeclaration(broken) == 1)

local fine = table.concat({
  "--[[ register is described here,",
  "     and register again ]]",
  "-- register in a comment",
  "local text = 'register in a string'",
  "local t = { register = 1 }",
  "print(t.register, t:register())",
  "local function early(register) return register end",
  "local function register() end",
  "function Init() register() end",
}, "\n")
check(
  "comments, strings, fields, keys and parameters are not uses",
  #usesBeforeDeclaration(fine) == 0,
  table.concat(usesBeforeDeclaration(fine), "; ")
)

print("\n[2] Every driver")

local listing = io.popen("ls drivers/*/driver.lua 2>/dev/null")
local count = 0
for path in listing:lines() do
  count = count + 1
  local handle = assert(io.open(path, "r"))
  local source = handle:read("*a")
  handle:close()
  local findings = usesBeforeDeclaration(source)
  check(path .. " reads no local before it is declared", #findings == 0, table.concat(findings, "; "))
end
listing:close()
check("the drivers were found (run from the repo root)", count >= 40, tostring(count))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

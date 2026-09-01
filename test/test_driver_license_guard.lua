-- Repository guard: every Control4 product is licensed through the
-- SmartBuildOS Agent. A suite's child/proxy drivers inherit the entitlement of
-- their licensed root because they cannot function without it; every other
-- driver must require sbos.license directly. The Agent itself is the authority.

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

local authority = { smartbuildos = true }
local inherited = {
  ["bond-color-light"] = "bond-bridge",
  ["bond-fan"] = "bond-bridge",
  ["bond-fireplace"] = "bond-bridge",
  ["bond-generic"] = "bond-bridge",
  ["bond-heater"] = "bond-bridge",
  ["bond-keypad"] = "bond-bridge",
  ["bond-light"] = "bond-bridge",
  ["bond-shade"] = "bond-bridge",
  ["bond-weather"] = "bond-bridge",
  ["smartbuildos-insights"] = "smartbuildos",
  ["smartbuildos-mode-button"] = "smartbuildos-mode-composer",
  ["unifi-protect-camera"] = "unifi-protect",
  ["unifi-protect-light"] = "unifi-protect",
  ["unifi-protect-sensor"] = "unifi-protect",
  ["unifi-protect-viewport"] = "unifi-protect",
}

local roots = {}
local pipe = assert(io.popen("rg --files drivers -g driver.lua | sort"))
for path in pipe:lines() do
  local name = path:match("^drivers/([^/]+)/driver%.lua$")
  if name ~= nil then
    roots[name] = path
  end
end
pipe:close()

for name, path in pairs(roots) do
  if authority[name] then
    check(name .. " is the licensing authority", true)
  elseif inherited[name] ~= nil then
    local parent = inherited[name]
    check(name .. " explicitly inherits " .. parent, roots[parent] ~= nil, "missing licensed parent")
  else
    local handle = assert(io.open(path, "rb"))
    local source = handle:read("*a")
    handle:close()
    check(
      name .. " registers through sbos.license",
      source:find('require%("sbos%.license"%)') ~= nil,
      "standalone drivers may not bypass SmartBuildOS licensing"
    )
  end
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end

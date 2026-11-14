--- Reads a driver's own packaged file (the WebView page in www/) from Lua.
---
--- Bench, 13 Nov 2026: `C4:FileSetDir("C4Z_ROOT", name)` followed by
--- `FileRead("www/app/index.html")` came back empty on a real controller, so
--- every relay answered `/app` with "app not loadable" and the page could be
--- reached only through Navigator's controller:// scheme. FileRead (the
--- drivers-common helper) returns "" when the file is not found and says
--- nothing, so the cause was invisible.
---
--- This tries each way a controller is known to expose a packaged file, in
--- order, and reports what it tried, so the first run on a controller names
--- the one that works. Pure apart from the C4 file calls it is handed.
---
---   read(c4zName, relPath, c4) -> content | nil, report(string)
---
--- `c4` is the C4 object (the tests pass a fake); it needs FileSetDir,
--- FileExists, FileOpen, FileGetSize, FileSetPos, FileRead, FileClose.

local M = {}

--- {setDir arguments, path} pairs, most likely first. A nil dir means "do not
--- call FileSetDir" (the directory the driver started in).
function M.candidates(c4zName, relPath)
  local out = {}
  local function add(dir, path)
    out[#out + 1] = { dir = dir, path = path }
  end
  -- A dir spec is the argument list for FileSetDir: the two-argument form
  -- the drivers always used, the one-argument form, then none.
  for _, dir in ipairs({ { "C4Z_ROOT", c4zName }, { "C4Z_ROOT" }, false }) do
    for _, prefix in ipairs({ "www/", "", "/www/", "driver/" .. c4zName .. "/www/", "drivers/" .. c4zName .. "/www/" }) do
      add(dir, prefix .. relPath)
    end
  end
  return out
end

local function readAll(c4, path)
  local file = c4:FileOpen(path)
  if file == nil then
    return nil
  end
  local size = c4:FileGetSize(file) or 0
  c4:FileSetPos(file, 0)
  local content = size > 0 and c4:FileRead(file, size) or nil
  c4:FileClose(file)
  return content
end

--- Returns the first candidate that yields at least `minBytes` of text.
function M.read(c4zName, relPath, c4, minBytes)
  minBytes = minBytes or 1
  local notes = {}
  for _, cand in ipairs(M.candidates(c4zName, relPath)) do
    local label = (cand.dir and table.concat(cand.dir, ",") or "(no dir)") .. " + " .. cand.path
    local ok, result = pcall(function()
      if cand.dir then
        c4:FileSetDir(table.unpack and table.unpack(cand.dir) or unpack(cand.dir))
      end
      if not c4:FileExists(cand.path) then
        return "missing"
      end
      return readAll(c4, cand.path)
    end)
    if ok and type(result) == "string" and result ~= "missing" and #result >= minBytes then
      notes[#notes + 1] = label .. " -> " .. #result .. " bytes (used)"
      return result, table.concat(notes, "; ")
    end
    notes[#notes + 1] = label
      .. " -> "
      .. (ok and (result == "missing" and "not found" or "empty") or ("error: " .. tostring(result):sub(1, 90)))
  end
  return nil, table.concat(notes, "; ")
end

return M

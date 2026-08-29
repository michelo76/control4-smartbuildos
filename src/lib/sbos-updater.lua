--- Updates SmartBuildOS drivers from the SmartBuildOS platform instead of public
--- GitHub releases. The Agent is already paired and token-authenticated, so it
--- asks `/api/driver-cloud/updates` what newer builds SmartBuildOS hosts for its
--- channel and installs the ones that are newer than what is on the controller.
---
--- The install half is identical to the GitHub updater's: write each `.c4z` into
--- C4Z_ROOT, then hand it to the local Director over the composer TCP port with
--- an UpdateProjectC4i. Only the SOURCE differs — a token-authed platform call
--- and per-file signed download URLs, rather than the GitHub releases API.

local http = require("lib.http")
local log = require("lib.logging")
local deferred = require("deferred")
local version = require("version")

local M = {}

--- Installs already-downloaded .c4z files by asking the local Director to
--- update each project driver. Mirrors the GitHub updater's install step.
--- @param filenames string[]
--- @return Deferred<string[], string>
local function installDrivers(filenames)
  local d = deferred.new()
  if IsEmpty(filenames) then
    return d:resolve(filenames)
  end
  C4:CreateTCPClient()
    :OnConnect(function(client)
      for _, driverFilename in pairs(filenames) do
        local c4soap = XMLTag(
          "c4soap",
          XMLTag("param", driverFilename, nil, nil, { name = "name", type = "string" }),
          false,
          false,
          { name = "UpdateProjectC4i", session = "0", operation = "RWX", category = "composer", async = "0" }
        ) .. "\0"
        client:Write(c4soap)
      end
      client:Close()
      d:resolve(filenames)
    end)
    :OnError(function(client, errCode, errMsg)
      client:Close()
      d:reject("Error " .. errCode .. ": " .. errMsg)
    end)
    :Connect("127.0.0.1", 5020)
  return d
end

--- Returns the packages that are newer than what is installed. A package for a
--- driver that is NOT installed in this project is ignored — the updater only
--- ever refreshes what a project already runs, never adds new drivers.
--- @param packages table[] The `packages` array from the updates response.
--- @param driverFilenames string[] The suite's known filenames.
--- @param forceUpdate? boolean
--- @return table[] outdated Packages to download.
function M.outdated(packages, driverFilenames, forceUpdate)
  local known = TableReverse(driverFilenames)
  local out = {}
  for _, pkg in pairs(packages or {}) do
    local fn = type(pkg) == "table" and pkg.filename or nil
    if
      fn ~= nil
      and known[fn] ~= nil
      and not IsEmpty(C4:GetDevicesByC4iName(fn) or {})
      and not IsEmpty(pkg.download_url)
    then
      local newVersion, newErr = version(tostring(pkg.version or ""))
      local curVersion, curErr = version(GetDriverVersion(fn))
      if IsEmpty(newErr) and IsEmpty(curErr) and (forceUpdate or newVersion > curVersion) then
        table.insert(out, pkg)
      end
    end
  end
  return out
end

--- Update installed SmartBuildOS drivers from the platform.
--- @param url string The absolute `/api/driver-cloud/updates` URL.
--- @param headers table Auth headers (the controller's Bearer token).
--- @param driverFilenames string[] The suite's filenames.
--- @param appetite string "Production" | "Prerelease" (the Update Channel).
--- @param forceUpdate? boolean Re-download even when already current.
--- @return Deferred<string[], string> Deferred resolving to the updated filenames.
function M.updateAll(url, headers, driverFilenames, appetite, forceUpdate)
  local reqHeaders = {}
  for k, v in pairs(headers or {}) do
    reqHeaders[k] = v
  end
  local fullUrl = url .. "?appetite=" .. (appetite == "Prerelease" and "Prerelease" or "Production")

  return http
    :get(fullUrl, reqHeaders)
    :next(function(response)
      local body = response.body
      if type(body) == "string" then
        local ok, decoded = pcall(function()
          return JSON:decode(body)
        end)
        body = ok and decoded or nil
      end
      if type(body) ~= "table" or type(body.packages) ~= "table" then
        return reject("SmartBuildOS returned an unexpected updates response")
      end

      local toDownload = M.outdated(body.packages, driverFilenames, forceUpdate)
      local downloads = {}
      for _, pkg in pairs(toDownload) do
        -- The download URL is short-lived and signed; it carries its own auth, so
        -- no bearer header goes with it.
        local download = http:get(pkg.download_url, {}):next(function(resp)
          if string.len(resp.body or "") < 1 then
            return reject(string.format("SmartBuildOS build %s downloaded empty", pkg.filename))
          end
          C4:FileSetDir("C4Z_ROOT")
          local previous = C4:FileExists(pkg.filename) and FileRead(pkg.filename) or nil
          if FileWrite(pkg.filename, resp.body, true) == -1 then
            if previous ~= nil then
              FileWrite(pkg.filename, previous, true)
            end
            return reject(string.format("failed to write %s", pkg.filename))
          end
          log:info(
            "Downloaded %s %s from SmartBuildOS (%d bytes)",
            pkg.filename,
            tostring(pkg.version),
            string.len(resp.body)
          )
          return pkg.filename
        end, function(resp)
          return reject(resp.error or "download failed")
        end)
        table.insert(downloads, download)
      end
      return deferred.all(downloads)
    end, function(response)
      return reject(response.error or "SmartBuildOS unreachable")
    end)
    :next(function(downloaded)
      return installDrivers(downloaded)
    end)
end

return M

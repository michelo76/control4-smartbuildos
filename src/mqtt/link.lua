--- The wire between the MQTT Broker driver and its child drivers (pure
--- vocabulary and helpers; the transport is the same bindingless
--- SendToDevice → ExecuteCommand path the System Link companions use).
---
--- child → broker
---   SBOS_MQTT_HELLO     { requester, kind, name, filters (json list), availability }
---   SBOS_MQTT_PUBLISH   { requester, topic, payload, retain ("true"|"false"), qos ("0"|"1") }
--- broker → child
---   SBOS_MQTT_ENTITY    { state, detail, licence, rejected }   answer to HELLO and on every change
---   SBOS_MQTT_MESSAGE   { topic, payload, retain, role ("state"|"availability") }
---   SBOS_MQTT_RESULT    { status ("sent"|"failed"), reason }
---   SBOS_MQTT_BROKER_HELLO {}                                   "broker (re)started: say hello again"
---
--- Params are strings on a controller. Empty strings are allowed through
--- (payload may legitimately be empty), so senders pass allowEmptyValues.

local M = {}

M.CMD = {
  HELLO = "SBOS_MQTT_HELLO",
  PUBLISH = "SBOS_MQTT_PUBLISH",
  ENTITY = "SBOS_MQTT_ENTITY",
  MESSAGE = "SBOS_MQTT_MESSAGE",
  RESULT = "SBOS_MQTT_RESULT",
  BROKER_HELLO = "SBOS_MQTT_BROKER_HELLO",
}

M.BROKER_FILES = {
  ["smartbuildos-mqtt-broker.c4z"] = true,
  ["smartbuildos-mqtt-broker.c4i"] = true,
}

M.CHILD_FILES = {
  ["smartbuildos-mqtt-contact.c4z"] = true,
  ["smartbuildos-mqtt-contact.c4i"] = true,
  ["smartbuildos-mqtt-motion.c4z"] = true,
  ["smartbuildos-mqtt-motion.c4i"] = true,
  ["smartbuildos-mqtt-light.c4z"] = true,
  ["smartbuildos-mqtt-light.c4i"] = true,
  ["smartbuildos-mqtt-shade.c4z"] = true,
  ["smartbuildos-mqtt-shade.c4i"] = true,
}

M.FLIGHT_RECORDER_FILES = {
  ["smartbuildos-flight-recorder.c4z"] = true,
  ["smartbuildos-flight-recorder.c4i"] = true,
}

--- Device ids in a C4:GetDevices() result whose driver file is in `files`,
--- ascending.
function M.findDevices(devices, files)
  local out = {}
  if type(devices) ~= "table" then
    return out
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id and files[file] then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

--- A topic may contain a comma, so filters travel one per line, not as CSV.
function M.encodeFilters(list)
  return table.concat(list or {}, "\n")
end

function M.decodeFilters(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    out[#out + 1] = line
  end
  return out
end

return M

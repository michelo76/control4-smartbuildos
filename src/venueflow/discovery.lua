--- VenueFlow: device discovery (pure over the adapter).
---
--- The adapter lists every project device (C4:GetDevices). This module sorts
--- them into the categories the Studio needs and records what each can do.
--- Classification is a SUGGESTION: it comes from the device's proxy type when
--- Director reports one, otherwise from its driver file name, and the result
--- says which (`basis`). The installer can map any device to any role by
--- hand, because no enumeration API tells a driver how a venue is wired.

local M = {}

M.CATEGORIES = {
  "room",
  "display",
  "projector",
  "video_switch",
  "av_over_ip",
  "source",
  "audio",
  "amplifier",
  "light",
  "lighting_scene",
  "shade",
  "other",
}

--- Control4 proxy type -> category.
local BY_PROXY = {
  tv = "display",
  projector = "projector",
  avswitch = "video_switch",
  receiver = "audio",
  amplifier = "amplifier",
  audio_switch = "audio",
  tuner = "source",
  satellite = "source",
  cable = "source",
  dvd = "source",
  disc_changer = "source",
  media_player = "source",
  media_service = "source",
  vcr = "source",
  light_v2 = "light",
  light = "light",
  blind = "shade",
}

--- Driver file name fragments, checked in order. Lower-case plain finds.
local BY_NAME = {
  { "roomdevice", "room" },
  { "projector", "projector" },
  { "videowall", "display" },
  { "video_wall", "display" },
  { "matrix", "video_switch" },
  { "hdmi_switch", "video_switch" },
  { "avswitch", "video_switch" },
  { "moip", "av_over_ip" },
  { "avoip", "av_over_ip" },
  { "nvx", "av_over_ip" },
  { "just_add_power", "av_over_ip" },
  { "amplifier", "amplifier" },
  { "amp_", "amplifier" },
  { "receiver", "audio" },
  { "triad", "audio" },
  { "audio_matrix", "audio" },
  { "_tv", "display" },
  { "tv_", "display" },
  { "television", "display" },
  { "display", "display" },
  { "satellite", "source" },
  { "cable", "source" },
  { "appletv", "source" },
  { "apple_tv", "source" },
  { "roku", "source" },
  { "bluray", "source" },
  { "media_player", "source" },
  { "signage", "source" },
  { "brightsign", "source" },
  { "dimmer", "light" },
  { "light", "light" },
  { "advanced_lighting", "lighting_scene" },
  { "blind", "shade" },
  { "shade", "shade" },
}

function M.classify(device)
  if device.category ~= nil then
    return device.category, "adapter"
  end
  for _, proxy in ipairs(device.proxies or {}) do
    local category = BY_PROXY[tostring(proxy):lower()]
    if category ~= nil then
      return category, "proxy"
    end
  end
  local file = tostring(device.driverFile or ""):lower()
  for _, pair in ipairs(BY_NAME) do
    if file:find(pair[1], 1, true) then
      return pair[2], "driver file name"
    end
  end
  return "other", "none"
end

--- Returns { devices = {...}, counts = {category -> n}, rooms = {...} }.
--- A room entry records the capabilities its variables show.
function M.scan(adapter)
  local ok, list = pcall(adapter.listDevices)
  if not ok or type(list) ~= "table" then
    return { devices = {}, counts = {}, rooms = {}, error = "device list unavailable" }
  end
  local devices, counts, rooms = {}, {}, {}
  for _, d in ipairs(list) do
    local category, basis = M.classify(d)
    local entry = {
      id = d.id,
      name = d.name,
      room = d.room,
      roomId = d.roomId,
      driverFile = d.driverFile,
      category = category,
      basis = basis,
      capabilities = {},
    }
    if category == "room" then
      local okRoom, room = pcall(adapter.readRoom, d.id)
      if okRoom and type(room) == "table" then
        entry.capabilities = {
          readable = true,
          power = room.power ~= nil,
          volume = room.volume ~= nil,
          mute = room.muted ~= nil,
          video = room.videoDevice ~= nil,
          audio = room.audioDevice ~= nil,
        }
      else
        entry.capabilities = { readable = false }
      end
      rooms[#rooms + 1] = entry
    else
      local okOnline, online = pcall(adapter.deviceOnline, d.id)
      if okOnline and online ~= nil then
        entry.capabilities.linkState = true
        entry.online = online
      end
    end
    counts[category] = (counts[category] or 0) + 1
    devices[#devices + 1] = entry
  end
  return { devices = devices, counts = counts, rooms = rooms }
end

return M

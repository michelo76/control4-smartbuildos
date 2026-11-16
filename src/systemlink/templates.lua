--- Programming templates — reusable setup recipes. Pure module.
---
--- The Lua twin of smartbuildos/src/lib/system-link/templates.ts (decision
--- SL-11: configuration happens in the driver). A template creates ITEM
--- DEFINITIONS on this bridge (the owner) through the same path Create
--- Shared Item uses, and prints the Composer programming the dealer still
--- has to write, step by step, for both sides. It never injects Composer
--- programming (no verified API for that, and the spec forbids silent
--- injection) and never creates exports or companions: those stay deliberate
--- dealer actions, named in the printed steps.

local M = {}

M.TEMPLATES = {
  {
    id = "away-home",
    title = "Away / Home coordination",
    summary = "The owner publishes whether anyone is home; the other project reacts.",
    ownerItems = {
      {
        name = "Away",
        type = "BOOLEAN",
        description = "Nobody is home",
        group = "Arrival",
        filter = { debounce_s = 5 },
      },
      {
        name = "System_Mode",
        type = "CHOICE",
        description = "Presence mode",
        group = "Arrival",
        allowed_values = { "Home", "Away", "Vacation" },
      },
    },
    peerItems = {},
    exports = {},
    programming = {
      owner = {
        "When the house goes away → Set Local Boolean ITEM=Away VALUE=True and Set Local Choice ITEM=System_Mode VALUE=Away.",
        "When someone arrives → Set Local Boolean ITEM=Away VALUE=False.",
      },
      peer = {
        "When <Owner>.Away changed (live) fires and <Owner>.Away is 1 and Remote System Is Ready → run the unattended scene.",
        "Guard native variable triggers with Link Is Synchronized.",
      },
    },
    sensitive = false,
  },
  {
    id = "guesthouse-occupancy",
    title = "Guesthouse occupancy",
    summary = "The guesthouse publishes occupancy and guest count with a stability window.",
    ownerItems = {
      {
        name = "Occupied",
        type = "BOOLEAN",
        description = "Guesthouse occupied",
        group = "Guesthouse",
        filter = { debounce_s = 5 },
      },
      {
        name = "Guest_Count",
        type = "INTEGER",
        description = "Guests expected",
        group = "Guesthouse",
        min = 0,
        max = 50,
      },
    },
    peerItems = {},
    exports = {},
    programming = {
      owner = {
        "When motion/occupancy changes → Set Local Boolean ITEM=Occupied.",
        "When the guest count is set → Set Local Integer ITEM=Guest_Count.",
      },
      peer = {
        "When <Owner>.Occupied changed (live) fires → adjust HVAC/lighting presets; use Shared Item Is Current before acting.",
      },
    },
    sensitive = false,
  },
  {
    id = "remote-light",
    title = "Remote light (native companion)",
    summary = "Export one light from the owner and present it natively on the other project.",
    ownerItems = {},
    peerItems = {},
    exports = {
      {
        kind = "light",
        name = "Porch_Light",
        control = false,
        note = "Start view-only; switch to Control allowed after commissioning confirms feedback.",
      },
    },
    programming = {
      owner = {
        "Device Exports block: Export Kind=light, pick the light in Export Device, Export Name=Porch_Light, Export Control=View only (Control allowed once verified) → Export Selected Device.",
      },
      peer = {
        "Pending Export=Porch_Light → Add Companion For Pending Export → bind the new System Link Light in a room.",
      },
    },
    sensitive = true,
  },
  {
    id = "remote-thermostat",
    title = "Remote thermostat (feature-gated)",
    summary = "Export a thermostat natively. Requires the THERMOSTAT feature on the pair licence and hardware validation.",
    ownerItems = {},
    peerItems = {},
    exports = {
      {
        kind = "thermostat",
        name = "Hall_Stat",
        control = false,
        note = "Gated: refused until the licence carries THERMOSTAT. Never pushes cached setpoints on restart.",
      },
    },
    programming = {
      owner = {
        "Device Exports block: Export Kind=thermostat, Export Control=View only first → Export Selected Device.",
      },
      peer = { "Pending Export=Hall_Stat → Add Companion For Pending Export → System Link Thermostat." },
    },
    sensitive = true,
  },
  {
    id = "arrival-request",
    title = "Arrival request with result",
    summary = "One project asks the other to prepare the home and waits for an explicit result.",
    ownerItems = {},
    peerItems = {},
    exports = {},
    programming = {
      owner = {
        "When Request Received fires and <Owner>.Request_1_Routine is Prepare_Home → run the welcome programming, then Report Request Success SLOT=1 RESULT=done.",
        "If it cannot run → Report Request Failure SLOT=1 RESULT=<why>.",
      },
      peer = {
        "On departure → Send Remote Request ROUTINE=Prepare_Home PAYLOAD=guests=2 DEADLINE=300.",
        "When Request Completed fires and Request Slot Status is '1 completed' → announce; when Request Expired fires → notify the dealer (the outcome was not confirmed).",
      },
    },
    sensitive = false,
  },
  {
    id = "readonly-sensors",
    title = "Read-only temperature and contact",
    summary = "Share a temperature and a door contact as read-only sensors.",
    ownerItems = {},
    peerItems = {},
    exports = {
      {
        kind = "temperature",
        name = "Outdoor_Temp",
        control = false,
        note = "Units are carried as Fahrenheit and Celsius fields.",
      },
      {
        kind = "contact",
        name = "Front_Door",
        control = false,
        note = "A contact is a sensor, not an access-control device.",
      },
    },
    programming = {
      owner = {
        "Device Exports block: Export Kind=temperature, Export Name=Outdoor_Temp; then Export Kind=contact, Export Name=Front_Door.",
      },
      peer = { "Add Companion For Pending Export on each; bind the Temperature and Contact companions." },
    },
    sensitive = false,
  },
  {
    id = "gate-request",
    title = "Gate request with actual feedback",
    summary = "Open a gate remotely through a request, and confirm with the gate's own position feedback.",
    ownerItems = {
      {
        name = "Gate_Open",
        type = "BOOLEAN",
        description = "Actual gate position from its sensor",
        group = "Gate",
        freshness = { max_age_s = 120 },
      },
    },
    peerItems = {},
    exports = {
      {
        kind = "relay",
        name = "Gate_Relay",
        control = true,
        note = "Pulse only (ops=trigger). Acceptance is not position; Gate_Open is.",
      },
    },
    programming = {
      owner = {
        "Device Exports block: Export Kind=relay, Export Name=Gate_Relay, Export Control=Control allowed, Export Operations=trigger → Export Selected Device; Set Export Schedule as required.",
        "When the gate position sensor changes → Set Local Boolean ITEM=Gate_Open.",
      },
      peer = {
        "Add the Relay companion; pulse it. Then wait for <Owner>.Gate_Open changed (live) before announcing 'gate open' — never on acceptance.",
      },
    },
    sensitive = true,
  },
}

function M.find(id)
  for _, t in ipairs(M.TEMPLATES) do
    if t.id == id then
      return t
    end
  end
  return nil
end

--- "id — title" labels for a Composer list, in catalogue order.
function M.labels()
  local out = {}
  for _, t in ipairs(M.TEMPLATES) do
    out[#out + 1] = t.id .. " — " .. t.title
  end
  return out
end

--- The template behind a list label ("id — title") or a bare id.
function M.fromLabel(label)
  local id = tostring(label or ""):match("^([%w%-]+)")
  return id and M.find(id) or nil
end

--- The item definitions a template creates on this bridge (the owner side).
--- A fresh table per call: the caller may add id/owner.
function M.ownerDefinitions(template)
  local out = {}
  for _, i in ipairs(template.ownerItems or {}) do
    local def = {
      name = i.name,
      type = i.type,
      description = i.description,
      group = i.group,
      min = i.min,
      max = i.max,
      precision = i.precision,
      export_enabled = true,
    }
    if i.allowed_values then
      def.allowed_values = {}
      for k, v in ipairs(i.allowed_values) do
        def.allowed_values[k] = v
      end
    end
    if i.freshness then
      def.freshness = { max_age_s = i.freshness.max_age_s }
    end
    if i.filter then
      def.filter = {}
      for k, v in pairs(i.filter) do
        def.filter[k] = v
      end
    end
    out[#out + 1] = def
  end
  return out
end

--- The lines the dealer reads after applying (or when printing) a template,
--- with <Owner> replaced by this bridge's alias prefix when known.
function M.describe(template, ownerPrefix, created, skipped)
  local lines = {}
  local function sub(s)
    return (s:gsub("<Owner>", ownerPrefix or "<Owner>"))
  end
  lines[#lines + 1] = string.format("Template %s: %s", template.title, template.summary)
  if template.sensitive then
    lines[#lines + 1] =
      "This recipe involves control the dealer must enable on purpose; nothing here allows it by itself."
  end
  if created and #created > 0 then
    lines[#lines + 1] = "Created on this bridge: " .. table.concat(created, ", ")
  end
  if skipped and #skipped > 0 then
    lines[#lines + 1] = "Already present, left as is: " .. table.concat(skipped, ", ")
  end
  for _, e in ipairs(template.exports or {}) do
    lines[#lines + 1] = string.format(
      "Export to make here (never automatic): %s as %s, %s. %s",
      e.kind,
      e.name,
      e.control and "Control allowed" or "View only",
      e.note
    )
  end
  for n, step in ipairs(template.programming.owner or {}) do
    lines[#lines + 1] = string.format("This side, step %d: %s", n, sub(step))
  end
  for n, step in ipairs(template.programming.peer or {}) do
    lines[#lines + 1] = string.format("Linked project, step %d: %s", n, sub(step))
  end
  return lines
end

return M

#!/usr/bin/env luajit
--- Writes the per-slot Composer surface of the Logic Pack into its
--- driver.xml: the slot conditionals, variables and events, and the BLOCK_*
--- programming commands with their Block picker.
---
--- The ids are a function of the slot only (src/logic/blockdefs.lua), so
--- regenerating never moves an id, and the capacity is the one constant
--- Defs.SLOTS. Everything outside the marked regions is hand-written and is
--- left exactly as it is.
---
--- Run from the repository root:  luajit tools/logic-blocks-xml.lua [--check]
---   --check  exit 1 when driver.xml is stale, writing nothing.

package.path = "src/?.lua;" .. package.path
local Defs = require("logic.blockdefs")

local PATH = "drivers/smartbuildos-logic-pack/driver.xml"

local function read(path)
  local f = assert(io.open(path, "rb"), "cannot read " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

local function conditionals()
  local out = {}
  for slot = 1, Defs.SLOTS do
    local label = Defs.slotLabel(slot)
    out[#out + 1] = string.format(
      "    <conditional><id>%d</id><name>%s</name><type>BOOL</type><condition_statement>%s is active</condition_statement><description>NAME %s is STRING</description><true_text>active</true_text><false_text>not active</false_text></conditional>",
      Defs.conditionalId(slot, 1),
      Defs.conditionalName(slot, "IS_ACTIVE"),
      label,
      label
    )
    out[#out + 1] = string.format(
      "    <conditional><id>%d</id><name>%s</name><type>NUMBER</type><condition_statement>%s value</condition_statement><description>NAME %s value is LOGIC INTEGER</description><minimum>-1000000000</minimum><maximum>1000000000</maximum></conditional>",
      Defs.conditionalId(slot, 2),
      Defs.conditionalName(slot, "VALUE"),
      label,
      label
    )
    out[#out + 1] = string.format(
      "    <conditional><id>%d</id><name>%s</name><type>STRING</type><condition_statement>%s state (type the state; = is, != is not)</condition_statement><description>NAME %s state LOGIC STRING</description></conditional>",
      Defs.conditionalId(slot, 3),
      Defs.conditionalName(slot, "STATE"),
      label,
      label
    )
  end
  return table.concat(out, "\n")
end

local function variables()
  local out = {}
  for slot = 1, Defs.SLOTS do
    for k, v in ipairs(Defs.VARIABLES) do
      out[#out + 1] = string.format(
        "    <variable><id>%d</id><name>%s</name><type>%s</type><default>%s</default><readonly>true</readonly><hidden>false</hidden></variable>",
        Defs.variableId(slot, k),
        Defs.variableName(slot, v.suffix),
        v.type,
        v.default
      )
    end
  end
  return table.concat(out, "\n")
end

local EVENT_TEXT = {
  passed = "let a trigger through",
  started = "started its countdown",
  expired = "reached the end of its countdown",
  cancelled = "had what was pending cancelled by BLOCK_CANCEL",
  value_changed = "changed its value or state",
  became_true = "became true / on / active",
  became_false = "became false / off / clear",
  faulted = "cannot give a result: an input cannot be read, or it was isolated",
}

local function events()
  local out = {}
  for slot = 1, Defs.SLOTS do
    for _, kind in ipairs(Defs.EVENTS) do
      out[#out + 1] = string.format(
        "    <event><id>%d</id><name>%s</name><description>%s %s (the Blocks property and the dealer app say which block is in this slot)</description></event>",
        Defs.eventId(slot, kind),
        Defs.eventName(slot, kind),
        Defs.slotLabel(slot),
        EVENT_TEXT[kind]
      )
    end
  end
  return table.concat(out, "\n")
end

local function blockParam()
  local items = {}
  for slot = 1, Defs.SLOTS do
    items[#items + 1] = "<item>" .. Defs.slotLabel(slot) .. "</item>"
  end
  return "<param><name>BLOCK</name><type>LIST</type><items>" .. table.concat(items) .. "</items></param>"
end

local function inputParam()
  local items = {}
  for i = 1, Defs.MAX_INPUTS do
    items[#items + 1] = "<item>Input " .. i .. "</item>"
  end
  return "<param><name>INPUT</name><type>LIST</type><items>" .. table.concat(items) .. "</items></param>"
end

local COMMANDS = {
  { "BLOCK_TRIGGER", "Run the rule of BLOCK: cooldown, quiet period, once per day, timer start, or a gate's conditions" },
  { "BLOCK_START", "Start the countdown of the timer in BLOCK (follows its Repeated Start setting)" },
  { "BLOCK_RESTART", "Start the countdown of the timer in BLOCK again from now" },
  { "BLOCK_CANCEL", "Cancel what is pending in BLOCK: a countdown, a quiet period or a change waiting to hold" },
  { "BLOCK_SET", "Set BLOCK to VALUE: a flag (true/false), a counter (whole number), a state selector (state name) or a threshold reading", "value" },
  { "BLOCK_CLEAR", "Turn the flag in BLOCK off, or set the counter in BLOCK to 0" },
  { "BLOCK_TOGGLE", "Flip the flag in BLOCK" },
  { "BLOCK_INCREMENT", "Add BY (default 1) to the counter in BLOCK", "by" },
  { "BLOCK_DECREMENT", "Subtract BY (default 1) from the counter in BLOCK", "by" },
  { "BLOCK_RESET", "Make BLOCK forget its history: the cooldown, today's pass, the count, the state. Nothing fires for a cleared countdown" },
  { "BLOCK_INPUT", "Send VALUE to INPUT of BLOCK (true/false for conditions, a number for a threshold, a state for a stable filter)", "input", "value" },
  { "BLOCK_INPUT_UNAVAILABLE", "Tell BLOCK that INPUT cannot be read right now. The block's result becomes unknown, not false", "input" },
}

local function commands()
  local out = {}
  for _, c in ipairs(COMMANDS) do
    local params = { "          " .. blockParam() }
    for i = 3, #c do
      if c[i] == "input" then
        params[#params + 1] = "          " .. inputParam()
      elseif c[i] == "value" then
        params[#params + 1] = "          <param><name>VALUE</name><type>STRING</type></param>"
      elseif c[i] == "by" then
        params[#params + 1] = "          <param><name>BY</name><type>STRING</type></param>"
      end
    end
    out[#out + 1] = string.format(
      "      <command>\n        <name>%s</name>\n        <description>%s</description>\n        <params>\n%s\n        </params>\n      </command>",
      c[1],
      c[2],
      table.concat(params, "\n")
    )
  end
  return table.concat(out, "\n")
end

local REGIONS = { conditionals = conditionals, variables = variables, events = events, commands = commands }

local function render(xml)
  for name, fn in pairs(REGIONS) do
    local open = "<!-- LOGIC-BLOCKS:" .. name .. " (generated by tools/logic-blocks-xml.lua; do not edit) -->"
    local close = "<!-- /LOGIC-BLOCKS:" .. name .. " -->"
    local a, b = xml:find(open, 1, true)
    local c, d = xml:find(close, 1, true)
    assert(a and c and c > b, "markers for " .. name .. " not found in " .. PATH)
    xml = xml:sub(1, b) .. "\n" .. fn() .. "\n    " .. xml:sub(c, -1)
    local _ = d
  end
  return xml
end

local current = read(PATH)
local wanted = render(current)
if arg[1] == "--check" then
  if current ~= wanted then
    io.stderr:write(PATH .. " is stale: run luajit tools/logic-blocks-xml.lua\n")
    os.exit(1)
  end
  print(PATH .. " is current (" .. Defs.SLOTS .. " slots)")
  os.exit(0)
end
if current ~= wanted then
  local f = assert(io.open(PATH, "wb"))
  f:write(wanted)
  f:close()
  print("wrote " .. PATH .. " (" .. Defs.SLOTS .. " slots)")
else
  print(PATH .. " already current")
end

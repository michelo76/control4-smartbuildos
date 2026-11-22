--- SmartBuildOS AI Core -- the touchscreen chat, version 2 (pure).
---
--- The contract with the platform (docs/ai-core/DRIVER.md §7b, "Chat v2"):
---
---   capability  the module registers `chat_v2` beside its restricted
---               operations (the same `commands` list that carries
---               read_device_state), so the cloud knows it may send the keys
---               below. It is not an operation: the Agent never forwards it.
---   ask         one optional body key, `thread`: 8..64 of [A-Za-z0-9_-],
---               random, minted per chat session (webui.lua) and replaced
---               when the chat locks, the session ends or the driver
---               restarts. The cloud continues the conversation for it.
---   deliver_result
---               two optional args, `display` (up to 6 blocks, the whole
---               value at most 4096 bytes serialised) and `suggestions` (up
---               to 3 follow-up questions, 80 characters each). Each may
---               arrive as a JSON-encoded string or as a structured value.
---
--- Validated here AGAIN (the cloud validated first): a closed block set,
--- closed keys per block, closed tones, plain text with bounded length.
--- What fails is dropped and only COUNTED: the text answer is always shown,
--- and an answer with neither key renders exactly as text. Nothing here is
--- ever executed or treated as markup: the page renders every string with
--- textContent.

JSON = JSON or require("JSON")

local M = {}

M.CAPABILITY = "chat_v2"

M.LIMITS = {
  blocks = 6,
  display_bytes = 4096,
  items = 12,
  text = 120, -- characters, every string of a block
  note = 300, -- characters, note.text
  suggestions = 3,
  suggestion = 80, -- characters
  thread_min = 8,
  thread_max = 64,
}

M.BLOCK_TYPES = { "stat", "list", "note" }
M.TONES = { ok = true, warn = true, bad = true, info = true }

--- The keys each block may carry (closed; `t` names the type).
local KEYS = {
  stat = { t = true, label = true, value = true, unit = true, tone = true },
  list = { t = true, title = true, items = true },
  note = { t = true, text = true, tone = true },
}
local ITEM_KEYS = { label = true, value = true, tone = true }

-- ── thread ids ─────────────────────────────────────────────────────────────

--- Whether `s` is a thread id the contract allows.
function M.validThread(s)
  return type(s) == "string"
    and #s >= M.LIMITS.thread_min
    and #s <= M.LIMITS.thread_max
    and s:match("^[A-Za-z0-9_%-]+$") ~= nil
end

--- A new thread id from `newHex` (32 lowercase hex: the relay's own random
--- source), or nil when it gave nothing usable (no thread is sent then).
function M.mintThread(newHex)
  local ok, hex = pcall(newHex)
  if ok and M.validThread(hex) then
    return hex
  end
  return nil
end

--- The optional keys among `sent` (a table: key -> value) that a refused
--- ask names as UNKNOWN: a platform that predates them. The exact shape,
--- traced from the platform (rpc/ops.ts validateOpBody → jobOp invalid() →
--- refusalPayload, HTTP 200) through the Agent (sbos/modulebus cloudAnswer,
--- sbos/modulerpc onCloudResponse) is
---   { status = "error", error_code = "invalid_args",
---     result = { reason = "unknown_fields", fields = { "thread" } } }
--- Only `reason = "unknown_fields"` counts: a key the platform KNOWS and
--- refuses (`invalid_thread`, `thread_requires_touchscreen`,
--- `invalid_fields`) is this driver's bug, not a version gap, so it is not
--- retried and is shown as refused (and kept in Print Diagnostics).
--- Field names may be paths (`body.thread`). Sorted list; empty otherwise.
function M.refusedKeys(answer, sent)
  local out = {}
  if type(answer) ~= "table" or answer.error_code ~= "invalid_args" or type(sent) ~= "table" then
    return out
  end
  if type(answer.result) ~= "table" or answer.result.reason ~= "unknown_fields" then
    return out
  end
  local r = type(answer.result) == "table" and answer.result or {}
  local named = {}
  for _, f in ipairs(type(r.fields) == "table" and r.fields or {}) do
    if type(f) == "string" then
      named[f:match("([^.]+)$") or f] = true
    end
  end
  for k in pairs(sent) do
    if named[k] then
      out[#out + 1] = k
    end
  end
  table.sort(out)
  return out
end

-- ── values ─────────────────────────────────────────────────────────────────

--- A table that is a JSON array: keys 1..n and nothing else.
local function isArray(v)
  if type(v) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(v) do
    n = n + 1
  end
  return n == #v
end

--- The code points of well-formed UTF-8 `s`, or nil when it is not
--- well-formed (a stray continuation byte, an overlong form, a surrogate,
--- past U+10FFFF, a cut sequence). Control4's Lua has no utf8 library.
local function codePoints(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len, cp, min
    if b < 0x80 then
      len, cp, min = 1, b, 0
    elseif b >= 0xC2 and b <= 0xDF then
      len, cp, min = 2, b - 0xC0, 0x80
    elseif b >= 0xE0 and b <= 0xEF then
      len, cp, min = 3, b - 0xE0, 0x800
    elseif b >= 0xF0 and b <= 0xF4 then
      len, cp, min = 4, b - 0xF0, 0x10000
    else
      return nil
    end
    for k = 1, len - 1 do
      local c = s:byte(i + k)
      if c == nil or c < 0x80 or c > 0xBF then
        return nil
      end
      cp = cp * 64 + (c - 0x80)
    end
    if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
      return nil
    end
    out[#out + 1] = cp
    i = i + len
  end
  return out
end
M.codePoints = codePoints

--- How many code points `s` holds (the contract's limits are in code
--- points, never bytes), or nil when it is not well-formed UTF-8.
function M.length(s)
  local cps = type(s) == "string" and codePoints(s) or nil
  return cps and #cps or nil
end

--- Code points a shown string may never carry, because they are control,
--- format, invisible, blank or spoofing characters:
---   controls (C0, DEL, C1); U+00A0 no-break space; U+00AD soft hyphen;
---   U+034F combining grapheme joiner; U+061C; U+115F, U+1160, U+3164,
---   U+FFA0 Hangul fillers; U+1680 and U+2000..U+200A, U+202F, U+205F,
---   U+3000 spaces other than the ASCII one; U+200B..U+200F; U+2028/9;
---   U+202A..U+202E and U+2066..U+2069 bidi; U+2060..U+2064; U+2800 braille
---   blank; U+FE00..U+FE0F and U+E0100..U+E01EF variation selectors (so an
---   emoji written with U+FE0F is refused; one without it passes);
---   U+FEFF; U+FF00..U+FFEF full-width / half-width forms; U+FFF9..U+FFFD
---   (interlinear annotation, U+FFFC, U+FFFD); U+17B4, U+17B5 (Khmer
---   inherent vowels); U+180B..U+180E (Mongolian selectors, vowel
---   separator); U+1D173..U+1D17A (musical format controls);
---   private use (U+E000..U+F8FF, planes 15 and 16); tags U+E0000..U+E007F.
local function forbidden(cp)
  return cp < 0x20
    or (cp >= 0x7F and cp <= 0xA0)
    or cp == 0xAD
    or cp == 0x034F
    or cp == 0x061C
    or cp == 0x115F
    or cp == 0x1160
    or cp == 0x1680
    or cp == 0x17B4
    or cp == 0x17B5
    or (cp >= 0x180B and cp <= 0x180E)
    or (cp >= 0x2000 and cp <= 0x200F)
    or (cp >= 0x2028 and cp <= 0x202F)
    or (cp >= 0x205F and cp <= 0x2064)
    or (cp >= 0x2066 and cp <= 0x2069)
    or cp == 0x2800
    or cp == 0x3000
    or cp == 0x3164
    or (cp >= 0xE000 and cp <= 0xF8FF)
    or (cp >= 0xFE00 and cp <= 0xFE0F)
    or cp == 0xFEFF
    or (cp >= 0xFF00 and cp <= 0xFFEF)
    or (cp >= 0xFFF9 and cp <= 0xFFFD)
    or (cp >= 0x1D173 and cp <= 0x1D17A)
    or (cp >= 0xE0000 and cp <= 0xE01EF)
    or cp >= 0xF0000
end
M.forbidden = forbidden

--- Combining marks, in every script a device name is written in: the
--- generic diacritic blocks, Cyrillic, Hebrew points, Arabic harakat, the
--- Indic vowel signs and viramas (one layout per 0x80 block from U+0900 to
--- U+0DFF), Thai and Lao. Used to refuse stacks of more than two in a row
--- and to keep a mark from counting as a letter.
local INDIC_MARKS = { { 0x00, 0x03 }, { 0x3A, 0x3C }, { 0x3E, 0x4F }, { 0x51, 0x57 }, { 0x62, 0x63 } }
function M.combining(cp)
  if
    (cp >= 0x300 and cp <= 0x36F)
    or (cp >= 0x483 and cp <= 0x489)
    or (cp >= 0x591 and cp <= 0x5BD)
    or cp == 0x5BF
    or cp == 0x5C1
    or cp == 0x5C2
    or cp == 0x5C4
    or cp == 0x5C5
    or cp == 0x5C7
    or (cp >= 0x610 and cp <= 0x61A)
    or (cp >= 0x64B and cp <= 0x65F)
    or cp == 0x670
    or (cp >= 0x6D6 and cp <= 0x6DC)
    or (cp >= 0x6DF and cp <= 0x6E4)
    or cp == 0x6E7
    or cp == 0x6E8
    or (cp >= 0x6EA and cp <= 0x6ED)
    or cp == 0xE31
    or (cp >= 0xE34 and cp <= 0xE3A)
    or (cp >= 0xE47 and cp <= 0xE4E)
    or cp == 0xEB1
    or (cp >= 0xEB4 and cp <= 0xEBC)
    or (cp >= 0xEC8 and cp <= 0xECD)
    or (cp >= 0x1AB0 and cp <= 0x1AFF)
    or (cp >= 0x1DC0 and cp <= 0x1DFF)
    or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE20 and cp <= 0xFE2F)
  then
    return true
  end
  if cp >= 0x900 and cp <= 0xDFF then
    local o = (cp - 0x900) % 0x80
    for _, r in ipairs(INDIC_MARKS) do
      if o >= r[1] and o <= r[2] then
        return true
      end
    end
  end
  return false
end

--- Whether `s` looks like a link: a URL, a www. address or a bare domain
--- (`name.tld`, a letters-only top-level label of 2+ letters).
local function linkLike(s)
  local l = s:lower()
  if l:find("%a[%w+.-]*://") or l:find("www%.") or l:find("mailto:", 1, true) then
    return true
  end
  for label in l:gmatch("([%w-]+)%.%a%a+") do
    if label:find("%a") then
      return true
    end
  end
  return false
end

--- Plain text of 1..max characters, or nil. The platform's rules, checked
--- again: a string (never a number or anything else), no leading or
--- trailing whitespace, no control, invisible, bidirectional, tag or
--- full-width characters (M.forbidden), no malformed UTF-8, no markup
--- (`<` or `>`), no URL or bare domain; at most `max` CODE POINTS. A value
--- over its limit is dropped, never cut.
local function plain(v, max)
  if type(v) ~= "string" or v == "" then
    return nil
  end
  if v:find("^%s") or v:find("%s$") or v:find("[<>]") or linkLike(v) then
    return nil
  end
  local cps = codePoints(v)
  if cps == nil or #cps > max then
    return nil
  end
  local marks = 0
  for _, cp in ipairs(cps) do
    if forbidden(cp) then
      return nil
    end
    -- More than two combining marks in a row (stacked "zalgo" text) is
    -- refused; an accented letter carries one or two.
    marks = M.combining(cp) and marks + 1 or 0
    if marks > 2 then
      return nil
    end
  end
  return v
end

--- Whether `s` (well-formed UTF-8) holds at least one letter or digit (a
--- combining mark never counts): an
--- ASCII one, or a code point in the letter blocks of the scripts a device
--- name is written in (Latin, Greek, Cyrillic, Armenian, Hebrew, Arabic,
--- Indic, Thai, Lao, Hangul, kana, CJK).
local LETTER_RANGES = {
  { 0xC0, 0x24F },
  { 0x370, 0x3FF },
  { 0x400, 0x52F },
  { 0x531, 0x58F },
  { 0x5D0, 0x5EA },
  { 0x620, 0x6FF },
  { 0x900, 0xDFF },
  { 0xE01, 0xEFF },
  { 0x1100, 0x115E },
  { 0x1161, 0x11FF },
  { 0x1E00, 0x1FFF },
  { 0x3041, 0x30FF },
  { 0x3400, 0x9FFF },
  { 0xAC00, 0xD7AF },
}
function M.hasWordChar(s)
  local cps = type(s) == "string" and codePoints(s) or nil
  for _, cp in ipairs(cps or {}) do
    if (cp >= 0x30 and cp <= 0x39) or (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) then
      return true
    end
    if cp ~= 0xD7 and cp ~= 0xF7 and not M.combining(cp) then
      for _, r in ipairs(LETTER_RANGES) do
        if cp >= r[1] and cp <= r[2] then
          return true
        end
      end
    end
  end
  return false
end
M.plain = plain

local function tone(v)
  if v == nil then
    return true, nil
  end
  if type(v) == "string" and M.TONES[v] then
    return true, v
  end
  return false
end

local function closedKeys(t, allowed)
  for k in pairs(t) do
    if not allowed[k] then
      return false
    end
  end
  return true
end

--- One block, normalised, or nil (dropped).
local function block(b)
  if type(b) ~= "table" or type(b.t) ~= "string" or KEYS[b.t] == nil or not closedKeys(b, KEYS[b.t]) then
    return nil
  end
  local L = M.LIMITS
  if b.t == "stat" then
    local label, value = plain(b.label, L.text), plain(b.value, L.text)
    local okT, t = tone(b.tone)
    local unit = b.unit ~= nil and plain(b.unit, L.text) or nil
    if label == nil or value == nil or not okT or (b.unit ~= nil and unit == nil) then
      return nil
    end
    return { t = "stat", label = label, value = value, unit = unit, tone = t }
  elseif b.t == "note" then
    local text = plain(b.text, L.note)
    local okT, t = tone(b.tone)
    if text == nil or not okT then
      return nil
    end
    return { t = "note", text = text, tone = t }
  end
  -- list
  local title = b.title ~= nil and plain(b.title, L.text) or nil
  if (b.title ~= nil and title == nil) or not isArray(b.items) or #b.items < 1 or #b.items > L.items then
    return nil
  end
  local items = {}
  for _, it in ipairs(b.items) do
    if type(it) ~= "table" or not closedKeys(it, ITEM_KEYS) then
      return nil
    end
    local label = plain(it.label, L.text)
    local value = it.value ~= nil and plain(it.value, L.text) or nil
    local okT, t = tone(it.tone)
    if label == nil or (it.value ~= nil and value == nil) or not okT then
      return nil
    end
    items[#items + 1] = { label = label, value = value, tone = t }
  end
  return { t = "list", title = title, items = items }
end

--- A JSON-encoded string or a structured value, bounded to `maxBytes`
--- serialised. Returns the decoded value, or nil and false when it could
--- not be read (nil and true: absent).
local function decoded(v, maxBytes)
  if v == nil then
    return nil, true
  end
  if type(v) == "string" then
    if #v > maxBytes then
      return nil, false
    end
    local ok, t = pcall(function()
      return JSON:decode(v)
    end)
    if not ok or type(t) ~= "table" then
      return nil, false
    end
    return t, true
  end
  if type(v) ~= "table" then
    return nil, false
  end
  local n = M.serialisedBytes(v, 0, maxBytes)
  if n == nil or n > maxBytes then
    return nil, false
  end
  return v, true
end

--- The JSON size of a structured value, in bytes (escapes counted as JSON
--- writes them), or nil when it is not plain data or nests deeper than 6.
--- Stops counting once past `limit`. Measured here rather than by encoding,
--- so the bound never depends on the JSON library's number formatting.
function M.serialisedBytes(v, depth, limit)
  local t = type(v)
  if t == "string" then
    local extra = 0
    for c in v:gmatch('[%c"\\]') do
      extra = extra + ((c == '"' or c == "\\" or c == "\n" or c == "\t" or c == "\r") and 1 or 5)
    end
    return #v + 2 + extra
  elseif t == "number" then
    return #string.format("%.14g", v)
  elseif t == "boolean" then
    return v and 4 or 5
  elseif t ~= "table" or depth >= 6 then
    return nil
  end
  local n = 2
  local count = 0
  for k, x in pairs(v) do
    count = count + 1
    local size = M.serialisedBytes(x, depth + 1, limit)
    if size == nil or (type(k) ~= "string" and type(k) ~= "number") then
      return nil
    end
    n = n + size + 1 + (type(k) == "string" and (#k + 3) or 0)
    if limit ~= nil and n > limit then
      return n
    end
  end
  return n - (count > 0 and 1 or 0)
end

--- deliver_result `display` → blocks (nil when none survive), and the
--- number of things dropped: each block that failed (a block beyond the
--- sixth counts too), or 1 for a whole value that could not be read.
function M.display(v)
  local t, readable = decoded(v, M.LIMITS.display_bytes)
  if t == nil then
    return nil, readable and 0 or 1
  end
  if not isArray(t) then
    return nil, 1
  end
  local out, dropped = {}, 0
  for _, b in ipairs(t) do
    local nb = #out < M.LIMITS.blocks and block(b) or nil
    if nb == nil then
      dropped = dropped + 1
    else
      out[#out + 1] = nb
    end
  end
  return #out > 0 and out or nil, dropped
end

--- deliver_result `suggestions` → up to 3 strings (nil when none survive),
--- and how many were dropped (or 1 for a value that could not be read).
--- A suggestion given twice is kept once.
function M.suggestions(v)
  local t, readable = decoded(v, 2048)
  if t == nil then
    return nil, readable and 0 or 1
  end
  if not isArray(t) then
    return nil, 1
  end
  local out, seen, dropped = {}, {}, 0
  for _, s in ipairs(t) do
    local c = #out < M.LIMITS.suggestions and plain(s, M.LIMITS.suggestion) or nil
    if c ~= nil and c:sub(-1) ~= "?" then
      c = nil -- a follow-up is a question (the platform's rule)
    end
    if c == nil or seen[c] then
      dropped = dropped + 1
    else
      seen[c] = true
      out[#out + 1] = c
    end
  end
  return #out > 0 and out or nil, dropped
end

return M

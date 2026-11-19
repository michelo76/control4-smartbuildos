-- VenueFlow engine floor: the page sources (ui/venueflow) and the two built
-- pages must use nothing that Gecko 96 lacks.
--
-- Why: Control4 T3 and T4 touch screens (T4 on OS 3.2.1+, T3 on OS 3.1.3+)
-- render a WebView driver's page with Gecko 96 (Firefox 96, January 2022);
-- see docs/smartbuildos-venueflow/SDK_RESEARCH.md, section 1. One unsupported
-- SYNTAX feature in a <script> block stops that whole block on a touch
-- screen; an unsupported CSS feature breaks the layout silently. The pages
-- are also served over plain HTTP on the LAN, so APIs that exist only in a
-- secure context (https or localhost) are missing there too, whatever the
-- engine version.
--
-- What it does: a deny-list of features, each with the Firefox version that
-- first shipped it, scanned in the JavaScript, the CSS and the markup of
-- every source file and of both built pages. JavaScript is scanned twice:
-- once with comments, strings and regular expression bodies blanked out (for
-- API names), once with only the comments blanked out (for event, element and
-- attribute names, which are written as strings). CSS is scanned with its
-- comments and strings blanked out. So a feature named in a comment or in UI
-- text is not reported.
--
-- What it does NOT do: run anything in Gecko. A pass here means "none of the
-- listed features appears", not "works on a touch screen". Nothing in this
-- repository has been run on a T3 or a T4 by this suite. The pages have been
-- run against the simulator in desktop Chromium, WebKit and Firefox (see
-- ui/venueflow/README.md, rule 9): desktop engines, not a touch screen or a
-- phone, and Firefox 159 is not Firefox 96.
--
-- Run from the driver root: make venueflow-test (or make test)

local H = require("venueflow_harness")
local T = H.checker()
local check = T.check

local function read(path)
  local f = io.open(path, "rb")
  if f == nil then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function list(command)
  local out = {}
  local pipe = io.popen(command)
  for line in pipe:lines() do
    out[#out + 1] = line
  end
  pipe:close()
  return out
end

-- ── the deny-list ───────────────────────────────────────────────────────────
-- { Lua pattern, what it is, Firefox version that first shipped it }.
-- A version of "secure context" means the API exists only on https or
-- localhost, and the pages are served on plain http from the controller.

-- JavaScript, matched with comments, strings and regex bodies blanked out.
local JS_CODE = {
  { "%.findLast%s*%(", "Array.prototype.findLast", "104" },
  { "%.findLastIndex%s*%(", "Array.prototype.findLastIndex", "104" },
  { "%f[%w_$]Object%s*%.%s*groupBy%f[^%w_$]", "Object.groupBy", "115" },
  { "%f[%w_$]Map%s*%.%s*groupBy%f[^%w_$]", "Map.groupBy", "115" },
  { "%.toSorted%s*%(", "Array.prototype.toSorted", "115" },
  { "%.toReversed%s*%(", "Array.prototype.toReversed", "115" },
  { "%.toSpliced%s*%(", "Array.prototype.toSpliced", "115" },
  { "%.with%s*%(", "Array.prototype.with", "115" },
  { "%f[%w_$]Array%s*%.%s*fromAsync%f[^%w_$]", "Array.fromAsync", "115" },
  { "%f[%w_$]Promise%s*%.%s*withResolvers%f[^%w_$]", "Promise.withResolvers", "121" },
  { "%f[%w_$]Promise%s*%.%s*try%f[^%w_$]", "Promise.try", "134" },
  { "%f[%w_$]RegExp%s*%.%s*escape%f[^%w_$]", "RegExp.escape", "134" },
  { "%f[%w_$]URL%s*%.%s*canParse%f[^%w_$]", "URL.canParse", "115" },
  { "%f[%w_$]URL%s*%.%s*parse%f[^%w_$]", "URL.parse", "126" },
  { "%.isWellFormed%s*%(", "String.prototype.isWellFormed", "119" },
  { "%.toWellFormed%s*%(", "String.prototype.toWellFormed", "119" },
  { "%.union%s*%(", "Set.prototype.union (and the other Set methods)", "127" },
  { "%.intersection%s*%(", "Set.prototype.intersection", "127" },
  { "%.symmetricDifference%s*%(", "Set.prototype.symmetricDifference", "127" },
  { "%.isSubsetOf%s*%(", "Set.prototype.isSubsetOf", "127" },
  { "%.isSupersetOf%s*%(", "Set.prototype.isSupersetOf", "127" },
  { "%.isDisjointFrom%s*%(", "Set.prototype.isDisjointFrom", "127" },
  { "%f[%w_$]Iterator%s*%.%s*from%f[^%w_$]", "Iterator helpers", "131" },
  { "%f[%w_$]Intl%s*%.%s*Segmenter%f[^%w_$]", "Intl.Segmenter", "125" },
  { "%f[%w_$]AbortSignal%s*%.%s*timeout%f[^%w_$]", "AbortSignal.timeout", "100" },
  { "%f[%w_$]AbortSignal%s*%.%s*any%f[^%w_$]", "AbortSignal.any", "124" },
  { "%.showModal%s*%(", "HTMLDialogElement.showModal", "98" },
  { "%f[%w_$]HTMLDialogElement%f[^%w_$]", "HTMLDialogElement", "98" },
  { "%.inert%f[^%w_$]", "HTMLElement.inert", "112" },
  { "%f[%w_$]inert%s*:", "the inert attribute (VF.h attrs key)", "112" },
  { "%.showPopover%s*%(", "Popover API", "125" },
  { "%.hidePopover%s*%(", "Popover API", "125" },
  { "%.togglePopover%s*%(", "Popover API", "125" },
  { "%.popover%f[^%w_$]", "Popover API", "125" },
  { "%f[%w_$]popover%s*:", "the popover attribute (VF.h attrs key)", "125" },
  { "%.showPicker%s*%(", "HTMLInputElement.showPicker", "101" },
  { "%.checkVisibility%s*%(", "Element.checkVisibility", "106" },
  { "%.scrollIntoViewIfNeeded%s*%(", "scrollIntoViewIfNeeded (never in Firefox)", "none" },
  { "%.startViewTransition%s*%(", "View Transitions", "144" },
  { "%f[%w_$]scheduler%s*%.%s*postTask%f[^%w_$]", "scheduler.postTask", "142" },
  { "%f[%w_$]scheduler%s*%.%s*yield%f[^%w_$]", "scheduler.yield", "none" },
  -- Secure-context-only (the LAN relay is plain http).
  { "%f[%w_$]crypto%s*%.%s*randomUUID%f[^%w_$]", "crypto.randomUUID", "95, secure context" },
  { "%f[%w_$]crypto%s*%.%s*subtle%f[^%w_$]", "crypto.subtle", "secure context" },
  { "%f[%w_$]navigator%s*%.%s*clipboard%f[^%w_$]", "navigator.clipboard", "secure context" },
  { "%f[%w_$]navigator%s*%.%s*serviceWorker%f[^%w_$]", "service workers", "secure context" },
  { "%f[%w_$]navigator%s*%.%s*locks%f[^%w_$]", "navigator.locks", "96, secure context" },
  { "%f[%w_$]navigator%s*%.%s*share%f[^%w_$]", "navigator.share", "secure context" },
  { "%f[%w_$]navigator%s*%.%s*wakeLock%f[^%w_$]", "Screen Wake Lock", "126, secure context" },
  { "%f[%w_$]navigator%s*%.%s*storage%f[^%w_$]", "StorageManager", "secure context" },
  { "%f[%w_$]navigator%s*%.%s*mediaDevices%f[^%w_$]", "media devices", "secure context" },
}

-- JavaScript, matched with only the comments blanked out (names in strings).
local JS_STRINGS = {
  { "addEventListener%s*%(%s*['\"]scrollend['\"]", "the scrollend event", "109" },
  { "%f[%w_$]onscrollend%f[^%w_$]", "the scrollend event", "109" },
  { "createElement%s*%(%s*['\"]dialog['\"]", "the <dialog> element", "98" },
  { "%f[%w_$]h%s*%(%s*['\"]dialog[.#'\"]", "the <dialog> element (VF.h)", "98" },
  { "%f[%w_$]h%s*%(%s*['\"]search[.#'\"]", "the <search> element", "118" },
  { "setAttribute%s*%(%s*['\"]inert['\"]", "the inert attribute", "112" },
  { "['\"]inert['\"]%s*:", "the inert attribute (VF.h attrs key)", "112" },
  { "setAttribute%s*%(%s*['\"]popover", "the popover attribute", "125" },
  { "['\"]popover['\"]%s*:", "the popover attribute (VF.h attrs key)", "125" },
  { "type%s*:%s*['\"]week['\"]", "<input type=week> (no picker in Firefox)", "none" },
  { "type%s*:%s*['\"]month['\"]", "<input type=month> (no picker in Firefox)", "none" },
}

-- CSS, matched with comments and strings blanked out. Nesting is checked
-- separately (cssNesting below).
local NUM = "%f[%w.%-]%-?%d*%.?%d+"
local CSS = {
  { ":has%s*%(", "the :has() selector", "121" },
  { "@container%f[^%w%-]", "container queries", "110" },
  { "%f[%w%-]container%-type%s*:", "container queries", "110" },
  { "%f[%w%-]container%-name%s*:", "container queries", "110" },
  { NUM .. "cq[whib]%f[^%w%-]", "container query units", "110" },
  { NUM .. "cqmin%f[^%w%-]", "container query units", "110" },
  { NUM .. "cqmax%f[^%w%-]", "container query units", "110" },
  { NUM .. "[dsl]v[hwib]%f[^%w%-]", "dynamic/small/large viewport units", "101" },
  { NUM .. "[dsl]vmin%f[^%w%-]", "dynamic/small/large viewport units", "101" },
  { NUM .. "[dsl]vmax%f[^%w%-]", "dynamic/small/large viewport units", "101" },
  { NUM .. "r?lh%f[^%w%-]", "the lh / rlh units", "120" },
  { NUM .. "cap%f[^%w%-]", "the cap unit", "97" },
  { NUM .. "ic%f[^%w%-]", "the ic unit", "97" },
  { "%f[%w%-]color%-mix%s*%(", "color-mix()", "113" },
  { "%f[%w%-]light%-dark%s*%(", "light-dark()", "120" },
  { "%f[%w%-]oklch%s*%(", "oklch()", "113" },
  { "%f[%w%-]oklab%s*%(", "oklab()", "113" },
  { "%f[%w%-]lab%s*%(", "lab()", "113" },
  { "%f[%w%-]lch%s*%(", "lch()", "113" },
  { "%f[%w%-]rgba?%s*%(%s*from%f[^%w%-]", "relative colour syntax", "128" },
  { "%f[%w%-]hsla?%s*%(%s*from%f[^%w%-]", "relative colour syntax", "128" },
  { "%f[%w%-]round%s*%(", "round()", "118" },
  { "%f[%w%-]mod%s*%(", "mod()", "118" },
  { "%f[%w%-]rem%s*%(", "rem()", "118" },
  { "%f[%w%-]abs%s*%(", "abs()", "118" },
  { "%f[%w%-]sign%s*%(", "sign()", "118" },
  { "%f[%w%-]sin%s*%(", "CSS trigonometric functions", "108" },
  { "%f[%w%-]cos%s*%(", "CSS trigonometric functions", "108" },
  { "%f[%w%-]tan%s*%(", "CSS trigonometric functions", "108" },
  { "%f[%w%-]backdrop%-filter%s*:", "backdrop-filter", "103" },
  { "@layer%f[^%w%-]", "cascade layers (@layer)", "97" },
  { "%f[%w%-]scrollbar%-gutter%s*:", "scrollbar-gutter", "97" },
  { "%f[%w%-]text%-wrap%s*:%s*balance", "text-wrap: balance", "121" },
  { "%f[%w%-]text%-wrap%s*:%s*pretty", "text-wrap: pretty", "none" },
  { "%f[%w%-]text%-wrap%-style%s*:", "text-wrap-style", "124" },
  { "@property%f[^%w%-]", "@property", "128" },
  { "@scope%f[^%w%-]", "@scope", "146" },
  { "@starting%-style%f[^%w%-]", "@starting-style", "129" },
  { "%f[%w%-]anchor%-name%s*:", "anchor positioning", "none" },
  { "%f[%w%-]position%-anchor%s*:", "anchor positioning", "none" },
  { "%f[%w%-]field%-sizing%s*:", "field-sizing", "none" },
  { "%f[%w%-]content%-visibility%s*:", "content-visibility", "125" },
  { "%f[%w%-]contain%-intrinsic%-size%s*:", "contain-intrinsic-size", "107" },
  { "%f[%w%-]hyphenate%-character%s*:", "hyphenate-character", "98" },
  { "%f[%w%-]view%-transition%-name%s*:", "View Transitions", "144" },
  { "%f[%w%-]animation%-timeline%s*:", "scroll-driven animations", "none" },
  { "%f[%w%-]scroll%-timeline%s*:", "scroll-driven animations", "none" },
  { "%f[%w%-]interpolate%-size%s*:", "interpolate-size", "none" },
  { ":popover%-open%f[^%w%-]", ":popover-open", "125" },
  { ":nth%-child%s*%([^)]*%sof%s", ":nth-child(An+B of S)", "113" },
  { ":nth%-last%-child%s*%([^)]*%sof%s", ":nth-last-child(An+B of S)", "113" },
}

-- Markup (outside <script> and <style>).
local HTML = {
  { "<dialog[%s>]", "the <dialog> element", "98" },
  { "<search[%s>]", "the <search> element", "118" },
  { "<[%a][^>]-%sinert[%s=/>]", "the inert attribute", "112" },
  { "<[%a][^>]-%spopover[%s=/>]", "the popover attribute", "125" },
  { "<[%a][^>]-%spopovertarget%s*=", "the popover attribute", "125" },
  { "type%s*=%s*['\"]?week", "<input type=week> (no picker in Firefox)", "none" },
  { "type%s*=%s*['\"]?month", "<input type=month> (no picker in Firefox)", "none" },
}

-- ── scanners ────────────────────────────────────────────────────────────────
-- Everything keeps its length and its newlines, so a match's line number is
-- the line in the file.

local function blank(s)
  return (s:gsub("[^\n]", " "))
end

-- Characters after which a "/" starts a regular expression, not a division.
local REGEX_AFTER = {}
for c in ("(,=:[!&|?{};+-*%<>~^"):gmatch(".") do
  REGEX_AFTER[c] = true
end
local REGEX_KEYWORD = {
  ["return"] = true,
  ["typeof"] = true,
  ["case"] = true,
  ["do"] = true,
  ["else"] = true,
  ["in"] = true,
  ["of"] = true,
  ["new"] = true,
  ["delete"] = true,
  ["void"] = true,
  ["throw"] = true,
}

--- JavaScript -> code (comments, string and regex bodies blanked),
--- strings (only comments blanked), and the list of regex literals
--- ({ flags, offset }). A template literal is blanked whole, ${...} included
--- (the pages write none; the README asks for plain strings).
local function scanJs(src)
  local code, keep, regexes = {}, {}, {}
  local i, n = 1, #src
  local function emit(text, inCode, inKeep)
    code[#code + 1] = inCode and text or blank(text)
    keep[#keep + 1] = inKeep and text or blank(text)
  end
  local function lastSignificant()
    for k = #code, 1, -1 do
      local piece = code[k]:match("(%S+)%s*$")
      if piece then
        return piece
      end
    end
    return ""
  end
  while i <= n do
    local c, d = src:sub(i, i), src:sub(i + 1, i + 1)
    if c == "/" and d == "/" then
      local j = src:find("\n", i, true) or n + 1
      emit(src:sub(i, j - 1), false, false)
      i = j
    elseif c == "/" and d == "*" then
      local _, j = src:find("*/", i + 2, true)
      j = j or n
      emit(src:sub(i, j), false, false)
      i = j + 1
    elseif c == "'" or c == '"' or c == "`" then
      local j = i + 1
      while j <= n do
        local e = src:sub(j, j)
        if e == "\\" then
          j = j + 2
        elseif e == c then
          break
        elseif e == "\n" and c ~= "`" then
          break
        else
          j = j + 1
        end
      end
      emit(c, true, true)
      emit(src:sub(i + 1, j - 1), false, true)
      emit(src:sub(j, j), true, true)
      i = j + 1
    elseif c == "/" then
      local prev = lastSignificant()
      local last = prev:sub(-1)
      local word = prev:match("[%w_$]+$")
      if
        prev == ""
        or REGEX_AFTER[last]
        or (word ~= nil and word == prev:match("[%a_$][%w_$]*$") and REGEX_KEYWORD[word])
      then
        local j, inClass = i + 1, false
        while j <= n do
          local e = src:sub(j, j)
          if e == "\\" then
            j = j + 2
          elseif e == "[" then
            inClass = true
            j = j + 1
          elseif e == "]" then
            inClass = false
            j = j + 1
          elseif e == "/" and not inClass then
            break
          elseif e == "\n" then
            break
          else
            j = j + 1
          end
        end
        local flags = src:match("^[%a]*", j + 1)
        regexes[#regexes + 1] = { flags = flags, offset = i }
        emit("/", true, true)
        emit(src:sub(i + 1, j - 1), false, true)
        emit(src:sub(j, j + #flags), true, true)
        i = j + #flags + 1
      else
        emit(c, true, true)
        i = i + 1
      end
    else
      local j = src:find("[/'\"`]", i) or n + 1
      emit(src:sub(i, j - 1), true, true)
      i = j
    end
  end
  return table.concat(code), table.concat(keep), regexes
end

--- CSS -> the text with comments and string contents blanked.
local function scanCss(src)
  src = src:gsub("/%*.-%*/", blank)
  src = src:gsub("(['\"])(.-)%1", function(q, body)
    return q .. blank(body) .. q
  end)
  return src
end

--- A rule inside a style rule is CSS nesting (Firefox 117). At-rule blocks
--- (@media, @supports, @keyframes ...) may hold rules; a style rule may not.
--- Returns the offset of the first nested rule, or nil. `css` is scanned.
local function cssNesting(css)
  local stack, start = {}, 1
  for i = 1, #css do
    local c = css:sub(i, i)
    if c == "{" then
      local prelude = css:sub(start, i - 1):match("^%s*(.-)%s*$")
      if stack[#stack] == "rule" then
        return i, prelude
      end
      stack[#stack + 1] = prelude:sub(1, 1) == "@" and "at" or "rule"
      start = i + 1
    elseif c == "}" then
      stack[#stack] = nil
      start = i + 1
    elseif c == ";" then
      start = i + 1
    end
  end
  return nil
end

local function lineOf(text, offset)
  return select(2, text:sub(1, offset):gsub("\n", "")) + 1
end

--- Every match of every pattern of `rules` in `text`: "file:line feature (Firefox N)".
local function findAll(text, rules, file, found)
  for _, r in ipairs(rules) do
    local from = 1
    while true do
      local s, e = text:find(r[1], from)
      if not s then
        break
      end
      found[#found + 1] = string.format("%s:%d %s (Firefox %s)", file, lineOf(text, s), r[2], r[3])
      from = e + 1
    end
  end
end

local function scanJsText(src, file, found)
  local code, keep, regexes = scanJs(src)
  findAll(code, JS_CODE, file, found)
  findAll(keep, JS_STRINGS, file, found)
  for _, re in ipairs(regexes) do
    if re.flags:find("v", 1, true) then
      found[#found + 1] = string.format("%s:%d regex flag v (Firefox 116)", file, lineOf(src, re.offset))
    end
  end
end

local function scanCssText(src, file, found)
  local css = scanCss(src)
  findAll(css, CSS, file, found)
  local at, prelude = cssNesting(css)
  if at then
    found[#found + 1] = string.format("%s:%d CSS nesting (%s) (Firefox 117)", file, lineOf(css, at), prelude)
  end
end

--- A built page: the markup, each <style> and each <script>, each scanned in
--- place (other regions blanked) so line numbers are the page's own.
local function scanHtmlText(src, file, found)
  local markup = src
  local function region(tag, scanner)
    local out = {}
    local pos = 1
    for open, body, close in src:gmatch("()<" .. tag .. "[^>]*>(.-)()</" .. tag .. ">") do
      local bodyAt = src:find(">", open, true) + 1
      out[#out + 1] = blank(src:sub(pos, bodyAt - 1))
      out[#out + 1] = body
      pos = close
    end
    out[#out + 1] = blank(src:sub(pos))
    scanner(table.concat(out), file, found)
    markup = markup:gsub("(<" .. tag .. "[^>]*>)(.-)(</" .. tag .. ">)", function(a, b, c)
      return a .. blank(b) .. c
    end)
  end
  region("script", scanJsText)
  region("style", scanCssText)
  markup = markup:gsub("<!%-%-.-%-%->", blank)
  findAll(markup, HTML, file, found)
end

local function scanFile(path, found)
  local src = read(path)
  if src == nil then
    found[#found + 1] = path .. ": cannot be read"
    return
  end
  if path:match("%.js$") then
    scanJsText(src, path, found)
  elseif path:match("%.css$") then
    scanCssText(src, path, found)
  else
    scanHtmlText(src, path, found)
  end
end

-- ── the scanners catch what they should, and only that ──────────────────────
print("scanners: a feature is found in code, not in a comment or a string")
local function scanned(kind, text)
  local found = {}
  if kind == "js" then
    scanJsText(text, "x.js", found)
  elseif kind == "css" then
    scanCssText(text, "x.css", found)
  else
    scanHtmlText(text, "x.html", found)
  end
  return found
end
local positives = {
  { "js", "var last = list.findLast(function (x) { return x; });", "findLast" },
  { "js", "var g = Object.groupBy(items, f);", "Object.groupBy" },
  { "js", "var id = crypto.randomUUID();", "randomUUID" },
  { "js", "navigator.clipboard.writeText(t);", "clipboard" },
  { "js", "box.showModal();", "showModal" },
  { "js", "el.inert = true;", "inert" },
  { "js", "VF.h('div.x', { inert: true });", "inert" },
  { "js", "el.addEventListener('scrollend', f);", "scrollend" },
  { "js", "var d = h('dialog.box', 'x');", "dialog" },
  { "js", "fetch(u, { signal: AbortSignal.timeout(5000) });", "AbortSignal.timeout" },
  { "js", "var ok = /[\\p{L}--[a-z]]/v.test(s);", "regex flag v" },
  { "js", "var a = b / 2, c = s.replace(/x/g, ''), d = xs.toSorted();", "toSorted" },
  { "css", ".a:has(.b) { color: red; }", ":has()" },
  { "css", ".a { height: 100dvh; }", "viewport units" },
  { "css", "@container (min-width: 400px) { .a { color: red; } }", "container queries" },
  { "css", ".a { background: color-mix(in srgb, red, blue); }", "color-mix" },
  { "css", ".a { color: red; .b { color: blue; } }", "CSS nesting" },
  { "css", ".a { color: red; &:hover { color: blue; } }", "CSS nesting" },
  { "css", "@layer base { .a { color: red; } }", "@layer" },
  { "css", ".a { -webkit-backdrop-filter: blur(4px); backdrop-filter: blur(4px); }", "backdrop-filter" },
  { "css", ".a { scrollbar-gutter: stable; }", "scrollbar-gutter" },
  { "css", ".a { text-wrap: balance; }", "text-wrap" },
  { "html", "<body><dialog open>x</dialog></body>", "dialog" },
  { "html", "<style>.a:has(b) { color: red; }</style>", ":has()" },
  { "html", "<script>var x = [1].findLast(f);</script>", "findLast" },
}
for _, p in ipairs(positives) do
  local found = scanned(p[1], p[2])
  check(p[1] .. " scanner finds " .. p[3], #found >= 1 and table.concat(found, " "):find(p[3], 1, true) ~= nil, p[2])
end
local negatives = {
  { "js", "// list.findLast(f) and crypto.randomUUID() are not allowed\nvar a = 1;" },
  { "js", "/* el.showModal(); Object.groupBy(x) */ var a = 1;" },
  { "js", "VF.toast('Use findLast( here and AbortSignal.timeout( there');" },
  { "js", "var m = { role: 'dialog', 'aria-label': 'Dialog' }; var r = /\\.findLast\\(/;" },
  { "js", "var half = total / 2 / 3; var at = list.at(-1); var o = Object.hasOwn(x, 'k');" },
  { "css", "/* :has(.x) and 100dvh and color-mix() */ .a { color: red; }" },
  { "css", ".a::after { content: ':has( 100dvh @layer'; }" },
  { "css", "@media (max-width: 600px) { .a { color: red; } .b { color: blue; } }" },
  { "css", "@keyframes spin { from { transform: rotate(0); } to { transform: rotate(1turn); } }" },
  { "css", ".a { width: min(440px, 100%); inset: 0; gap: 8px; accent-color: teal; }" },
  { "html", "<!-- <dialog> --><script>// el.inert = true\n</script><p>A popover and an inert dialog</p>" },
}
for i, p in ipairs(negatives) do
  local found = scanned(p[1], p[2])
  check(
    string.format("%s scanner reports nothing in comments, strings or allowed code (%d)", p[1], i),
    #found == 0,
    table.concat(found, "; ")
  )
end

-- ── the page sources ────────────────────────────────────────────────────────
print("sources: ui/venueflow uses nothing Gecko 96 lacks")
local sources = list("find ui/venueflow -type f \\( -name '*.js' -o -name '*.css' -o -name '*.html' \\) | sort")
check("page sources found", #sources >= 20, #sources)
local kinds = { js = 0, css = 0, html = 0 }
for _, path in ipairs(sources) do
  local ext = path:match("%.(%a+)$")
  kinds[ext] = (kinds[ext] or 0) + 1
  local found = {}
  scanFile(path, found)
  check(path .. " is inside the Gecko 96 floor", #found == 0, table.concat(found, "; "))
end
check("JavaScript, CSS and HTML sources were all scanned", kinds.js >= 10 and kinds.css >= 5 and kinds.html == 2)

-- ── the built pages ─────────────────────────────────────────────────────────
print("built pages: the files the driver serves use nothing Gecko 96 lacks")
for _, path in ipairs({
  "drivers/smartbuildos-venueflow/www/app/index.html",
  "drivers/smartbuildos-venueflow/www/studio/index.html",
}) do
  local html = read(path)
  check(path .. " is built", type(html) == "string" and #html > 20000, html and #html)
  if html ~= nil then
    check(path .. " holds inline scripts and styles", html:find("<script>", 1, true) and html:find("<style>", 1, true))
    local found = {}
    scanFile(path, found)
    check(path .. " is inside the Gecko 96 floor", #found == 0, table.concat(found, "; "))
  end
end

-- ── the page icon ────────────────────────────────────────────────────────────
-- Without an icon in the page, Firefox asks for /favicon.ico; the relay's
-- Content Security Policy (img-src data: blob:) refuses it and Firefox logs a
-- console error on every page load (seen in Firefox 159, 19 November 2026).
-- An empty data: icon keeps the console clean.
print("page icon: both pages name an inline data: icon")
for _, path in ipairs({
  "ui/venueflow/operator/index.html",
  "ui/venueflow/studio/index.html",
  "drivers/smartbuildos-venueflow/www/app/index.html",
  "drivers/smartbuildos-venueflow/www/studio/index.html",
}) do
  local html = read(path) or ""
  local head = html:match("<head>(.-)</head>") or ""
  check(path .. " has <link rel=\"icon\" href=\"data:...\"> in its head", head:find('<link rel="icon" href="data:', 1, true) ~= nil)
end

T.done()

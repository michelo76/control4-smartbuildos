-- VenueFlow staff permissions and sign-in, enforced in the DRIVER (core.lua
-- and the engines), never by what a page chooses to show. Hand-made requests
-- stand in for a tampered page throughout.
--
-- Covers: what each profile's screen receives, refusal per display / source /
-- zone / scene, unauthorized and unauthenticated commands, a page claiming a
-- profile it is not, PIN sign-in and lockout, session expiry and revocation,
-- Installer Studio sign-in, and the tile's default profile.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Protocol = require("venueflow.protocol")
local T = H.checker()
local check, eq = T.check, T.eq

local env = H.new()
local studio = env.publishSample("sports_bar")
local S = { session = studio }
local TILE = { tile = true }

-- ── what the tile's default profile (Bartender: bar only) receives ──────────
print("the bartender tablet")
local hello = env.send("HELLO", {}, TILE)
eq("tile opens as the default profile", hello.data.profile.id, "bartender")
eq("not marked as signed in", hello.data.signedIn, false)
eq("only the bar's displays are sent", #hello.data.config.displays, 8)
eq("only the bar zone is sent", #hello.data.config.audioZones, 1)
eq("only its scenes are sent", #hello.data.config.scenes, 2)
local encoded = H.JSON:encode(hello)
check(
  "no Control4 id reaches an operator page",
  not encoded:find("c4RoomId", 1, true) and not encoded:find("c4DeviceId", 1, true)
)
check(
  "no PIN material reaches an operator page",
  not encoded:find("pinHash", 1, true) and not encoded:find("pinSalt", 1, true)
)
check("no program reaches an operator page", not encoded:find('"program"', 1, true))
local state = hello.data.state
local n = 0
for _ in pairs(state.displays) do
  n = n + 1
end
eq("state covers only visible displays", n, 8)
eq("alerts are not sent to a profile without viewAlerts", state.alerts, nil)
eq("counts cover only what the profile sees", state.counts.displays.total, 8)

-- ── refusals, per target ────────────────────────────────────────────────────
print("refusals")
local calls = env.sim():callCount()
local r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01", "tv-09", "tv-17" } }, TILE)
eq("a mixed request is partial", r.status, "partial")
eq("the bar display is accepted", r.results[1].status, "pending")
eq("a dining display is refused", r.results[2].errorCode, "VF_FORBIDDEN")
eq("a patio display is refused", r.results[3].errorCode, "VF_FORBIDDEN")
env.settle(1500)
eq("exactly one command was sent", env.sim():callCount() - calls, 1)
eq("the refused display's state is untouched", env.cell("display", "tv-09", "source").status, "confirmed")
eq("...and unchanged", env.cell("display", "tv-09", "source").value, nil)

calls = env.sim():callCount()
r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-09" } }, TILE)
check("a request with nothing allowed fails", not r.ok)
eq("nothing sent", env.sim():callCount(), calls)

eq(
  "another zone's volume",
  env.send("AUDIO_VOLUME", { zoneId = "zone-dining", level = 80 }, TILE).errorCode,
  "VF_FORBIDDEN"
)
eq("own zone's volume", env.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = 40 }, TILE).ok, true)
eq(
  "a scene outside the profile",
  env.send("SCENE_ACTIVATE", { sceneId = "closing", confirm = true }, TILE).errorCode,
  "VF_FORBIDDEN"
)
eq(
  "previewing a scene outside the profile",
  env.send("SCENE_PREVIEW", { sceneId = "closing" }, TILE).errorCode,
  "VF_FORBIDDEN"
)
eq("All Off", env.send("ALL_OFF", { confirm = true }, TILE).errorCode, "VF_FORBIDDEN")
eq("All Off preview", env.send("ALL_OFF_PREVIEW", {}, TILE).errorCode, "VF_FORBIDDEN")
eq("venue status", env.send("VENUE_STATUS", { status = "open" }, TILE).errorCode, "VF_FORBIDDEN")
eq(
  "lighting",
  env.send("LIGHTING_PRESET", { lightingId = "house-lights", presetId = "bright" }, TILE).errorCode,
  "VF_FORBIDDEN"
)
eq("dismissing alerts", env.send("ALERT_DISMISS", { alertId = "a1" }, TILE).errorCode, "VF_FORBIDDEN")
r = env.send("QUERY_STATUS", {}, TILE)
eq("query status covers only visible displays", #r.results, 8)
check("a refusal carries no installer detail for an operator", r.detail == nil)
r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-09" } }, TILE)
check("per-display results carry no installer detail either", r.results[1].detail == nil)
env.settle(1500)

-- The host profile may run scenes and nothing else.
local c = H.Templates.sportsBar(function(pin)
  return "s", H.hmac("s", "vf-pin:" .. pin)
end)
eq("the host template cannot route", c.profiles[3].permissions.routeVideo, false)

-- ── a page cannot claim an identity ─────────────────────────────────────────
print("forged identity")
r = env.core:handle({
  requestId = "forge-1",
  command = "ALL_OFF",
  payload = { confirm = true, profileId = "manager" },
}, { tile = true })
eq("an extra profileId field is refused by the protocol", r.errorCode, "VF_INVALID_PAYLOAD")
r = env.core:handle({
  requestId = "forge-2",
  command = "ALL_OFF",
  payload = { confirm = true },
  profile = "manager",
  role = "installer",
  installer = true,
}, { tile = true })
eq("claimed role fields are ignored: still the bartender", r.errorCode, "VF_FORBIDDEN")
r = env.core:handle(
  { requestId = "forge-3", command = "ALL_OFF", payload = { confirm = true }, session = "manager" },
  { tile = true }
)
eq("a made-up session token is no session", r.errorCode, "VF_FORBIDDEN")
r = env.core:handle(
  { requestId = "forge-4", command = "DRAFT_GET", payload = {}, session = string.rep("a", 64) },
  { tile = true }
)
eq("a made-up token cannot reach the Studio", r.errorCode, "VF_UNAUTHENTICATED")

-- ── no identity at all ──────────────────────────────────────────────────────
print("unauthenticated")
local NONE = {}
hello = env.send("HELLO", {}, NONE)
eq("no identity: asked to sign in", hello.data.needsSignIn, true)
eq("no identity: no configuration", hello.data.config, nil)
eq("no identity: no state", hello.data.state, nil)
eq("the sign-in list names only PIN profiles", #hello.data.profiles, 1)
for name, spec in pairs(Protocol.COMMANDS) do
  if spec.scope == "operator" then
    r = env.core:handle({ requestId = "anon-" .. name, command = name, payload = {} }, { tile = false })
    check(
      "unauthenticated " .. name .. " refused",
      r.ok == false and (r.errorCode == "VF_UNAUTHENTICATED" or r.errorCode == "VF_INVALID_PAYLOAD"),
      r.errorCode
    )
  elseif spec.scope == "installer" then
    r = env.core:handle({ requestId = "anon-" .. name, command = name, payload = {} }, { tile = false })
    check(
      "unauthenticated " .. name .. " refused",
      r.ok == false and (r.errorCode == "VF_UNAUTHENTICATED" or r.errorCode == "VF_INVALID_PAYLOAD"),
      r.errorCode
    )
    r = env.core:handle({ requestId = "tile-" .. name, command = name, payload = {} }, { tile = true })
    check(
      "the tile cannot run installer command " .. name,
      r.ok == false and (r.errorCode == "VF_UNAUTHENTICATED" or r.errorCode == "VF_INVALID_PAYLOAD"),
      r.errorCode
    )
  end
end
-- with valid payloads, to be sure the refusal is about identity
eq(
  "unauthenticated route",
  env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, NONE).errorCode,
  "VF_UNAUTHENTICATED"
)
eq("unauthenticated publish", env.send("PUBLISH", {}, NONE).errorCode, "VF_UNAUTHENTICATED")
eq(
  "a staff session cannot publish",
  env.send("PUBLISH", {}, { session = (env.login("manager", "2580")) }).errorCode,
  "VF_UNAUTHENTICATED"
)
eq(
  "a staff session cannot read the draft",
  env.send("DRAFT_GET", {}, { session = (env.login("manager", "2580")) }).errorCode,
  "VF_UNAUTHENTICATED"
)
eq(
  "a staff session cannot inject simulator faults",
  env.send("SIM_FAULT", { targetId = 1101, fault = "offline" }, { session = (env.login("manager", "2580")) }).errorCode,
  "VF_UNAUTHENTICATED"
)

-- ── PIN sign-in ─────────────────────────────────────────────────────────────
print("PIN sign-in")
local session, reply = env.login("manager", "2580")
check("right PIN signs in", session ~= nil)
eq("the reply names the profile", reply.data.profile.id, "manager")
eq("the manager sees every display", #reply.data.config.displays, 24)
check("the manager gets alerts", type(reply.data.state.alerts) == "table")
eq("the manager may run All Off preview", env.send("ALL_OFF_PREVIEW", {}, { session = session }).ok, true)
check("signing in from the tile works too", env.send("PROFILE_LOGIN", { profileId = "manager", pin = "2580" }, TILE).ok)

local _, bad = env.login("manager", "0000")
eq("wrong PIN", bad.errorCode, "VF_BAD_PIN")
eq("a profile without a PIN cannot be signed into", select(2, env.login("bartender", "1234")).errorCode, "VF_FORBIDDEN")
eq("an unknown profile looks like a wrong PIN", select(2, env.login("nobody", "1234")).errorCode, "VF_BAD_PIN")
eq("a non-numeric PIN", select(2, env.login("manager", "25a0")).errorCode, "VF_BAD_PIN")

-- lockout, per client address
local attacker = { client = "10.0.0.99" }
for _ = 1, 4 do
  env.send("PROFILE_LOGIN", { profileId = "manager", pin = "1111" }, attacker)
end
r = env.send("PROFILE_LOGIN", { profileId = "manager", pin = "1111" }, attacker)
eq("the fifth wrong PIN locks", r.errorCode, "VF_LOCKED")
check("the lock says how long", r.data.retryIn > 0 and r.data.retryIn <= 60, r.data.retryIn)
eq(
  "the right PIN is refused while locked",
  env.send("PROFILE_LOGIN", { profileId = "manager", pin = "2580" }, attacker).errorCode,
  "VF_LOCKED"
)
check(
  "another device is not locked out",
  env.send("PROFILE_LOGIN", { profileId = "manager", pin = "2580" }, { client = "10.0.0.51" }).ok
)
env.clock.advance(61000)
check("the lock ends", env.send("PROFILE_LOGIN", { profileId = "manager", pin = "2580" }, attacker).ok)
local locked = false
for _, e in ipairs(env.core.diag:list({ limit = 100, category = "auth" })) do
  if e.code == "VF_LOCKED" then
    locked = true
  end
  check(
    "no PIN in the auth log",
    not tostring(e.message):find("1111", 1, true) and not H.JSON:encode(e):find("2580", 1, true)
  )
end
check("the lock is in diagnostics", locked)

-- ── sessions end ────────────────────────────────────────────────────────────
print("sessions")
session = env.login("manager", "2580")
eq("LOGOUT ends the session", env.send("LOGOUT", {}, { session = session }).ok, true)
eq("...for real", env.send("ALL_OFF_PREVIEW", {}, { session = session }).errorCode, "VF_UNAUTHENTICATED")

session = env.login("manager", "2580")
env.clock.advance(17 * 3600 * 1000)
eq("a staff session expires", env.send("GET_STATE", {}, { session = session }).errorCode, "VF_UNAUTHENTICATED")

local st = env.studio()
check("a studio session works", env.send("DRAFT_GET", {}, { session = st }).ok)
env.clock.advance(31 * 60 * 1000)
eq("an idle studio session expires", env.send("DRAFT_GET", {}, { session = st }).errorCode, "VF_UNAUTHENTICATED")

st = env.studio()
session = env.login("manager", "2580")
eq("End all staff sessions", env.send("SESSIONS_REVOKE", {}, { session = st }).data.revoked >= 1, true)
eq("the staff session is gone", env.send("GET_STATE", {}, { session = session }).errorCode, "VF_UNAUTHENTICATED")
check("the studio session is not", env.send("DRAFT_GET", {}, { session = st }).ok)

-- changing a profile's PIN ends that profile's sessions at publish
session = env.login("manager", "2580")
check(
  "PIN changed in the draft",
  env.send("PROFILE_PIN_SET", { profileId = "manager", pin = "13579" }, { session = st }).ok
)
check("the old session still works until publish", env.send("GET_STATE", {}, { session = session }).ok)
local draft = env.send("DRAFT_GET", {}, { session = st }).data.draft
local acks = {}
for _, i in ipairs(draft.issues) do
  acks[#acks + 1] = i.id
end
check("published", env.send("PUBLISH", { acknowledged = acks }, { session = st }).ok)
eq(
  "the old session ended with the PIN change",
  env.send("GET_STATE", {}, { session = session }).errorCode,
  "VF_UNAUTHENTICATED"
)
eq("the old PIN no longer works", select(2, env.login("manager", "2580")).errorCode, "VF_BAD_PIN")
check("the new PIN works", env.login("manager", "13579") ~= nil)
eq(
  "a malformed PIN cannot be set",
  env.send("PROFILE_PIN_SET", { profileId = "manager", pin = "12" }, { session = st }).errorCode,
  "VF_INVALID_PAYLOAD"
)

-- ── Installer Studio sign-in ────────────────────────────────────────────────
print("Installer Studio sign-in")
local wrongPass = env.send("STUDIO_LOGIN", { passcode = "wrong-one" }, { client = "10.0.0.70" })
eq("wrong passcode", wrongPass.errorCode, "VF_BAD_PASSCODE")
eq("...and the message says passcode, not PIN", wrongPass.message, "That passcode is not right.")
for _ = 1, 5 do
  env.send("STUDIO_LOGIN", { passcode = "guess" }, { client = "10.0.0.71" })
end
eq(
  "studio lockout",
  env.send("STUDIO_LOGIN", { passcode = env.passcode }, { client = "10.0.0.71" }).errorCode,
  "VF_LOCKED"
)

local off = H.new({ passcode = "" })
eq("no passcode: the Studio is off", off.send("STUDIO_LOGIN", { passcode = "" }).errorCode, "VF_STUDIO_DISABLED")
eq(
  "no passcode: an empty guess does not get in",
  off.send("STUDIO_LOGIN", { passcode = "anything" }).errorCode,
  "VF_STUDIO_DISABLED"
)
eq("no passcode: installer commands say why", off.send("DRAFT_GET", {}).errorCode, "VF_STUDIO_DISABLED")
eq("HELLO says the Studio is off", off.send("HELLO", {}).data.studioEnabled, false)
local short = H.new({ passcode = "12345" })
eq(
  "a passcode under six characters keeps the Studio off",
  short.send("STUDIO_LOGIN", { passcode = "12345" }).errorCode,
  "VF_STUDIO_DISABLED"
)

-- ── a venue with no default profile: every screen starts at sign-in ─────────
print("no default profile")
local e3 = H.new()
local st3 = e3.studio()
local cfg = H.Templates.sportsBar(function(pin)
  return "salt", H.hmac("salt", "vf-pin:" .. pin)
end)
cfg.defaultProfileId = nil
local saved = e3.send("DRAFT_SAVE", { config = cfg }, { session = st3 })
-- The harness hashes PINs itself here, and DRAFT_SAVE must NOT trust hashes a page sends.
eq("PIN hashes sent by a page are dropped", e3.core.store:draft().config.profiles[1].pinHash, nil)
acks = {}
for _, i in ipairs(saved.data.issues) do
  acks[#acks + 1] = i.id
end
check("published", e3.send("PUBLISH", { acknowledged = acks }, { session = st3 }).ok)
eq("the tile has no identity without a default profile", e3.send("HELLO", {}, TILE).data.needsSignIn, true)
eq(
  "...and cannot control anything",
  e3.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, TILE).errorCode,
  "VF_UNAUTHENTICATED"
)

-- ── stations: a fixed screen, by its LAN address, opens as its own profile ──
print("stations")
local e4 = H.new()
local st4 = e4.studio()
local c4 = H.Templates.sportsBar()
c4.stations = {
  { id = "host-stand", name = "Host station", address = "10.0.0.31", profileId = "host" },
  { id = "bar-tablet", name = "Bartender tablet", address = "10.0.0.32", profileId = "bartender" },
}
saved = e4.send("DRAFT_SAVE", { config = c4 }, { session = st4 })
eq("stations validate", saved.data.summary.errors, 0)
acks = {}
for _, i in ipairs(saved.data.issues) do
  acks[#acks + 1] = i.id
end
check("published", e4.send("PUBLISH", { acknowledged = acks }, { session = st4 }).ok)
local h1 = e4.send("HELLO", {}, { tile = true, client = "10.0.0.31" })
eq("the host station opens as Host", h1.data.profile.id, "host")
eq("...and is told which station it is", h1.data.station.name, "Host station")
eq(
  "the bar tablet opens as Bartender",
  e4.send("HELLO", {}, { tile = true, client = "10.0.0.32" }).data.profile.id,
  "bartender"
)
eq(
  "any other tile opens as the default profile",
  e4.send("HELLO", {}, { tile = true, client = "10.0.0.99" }).data.profile.id,
  "bartender"
)
eq(
  "the host station cannot route (Host may only run scenes)",
  e4.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, { tile = true, client = "10.0.0.31" }).errorCode,
  "VF_FORBIDDEN"
)
eq(
  "a station address without the tile token is no identity",
  e4.send("HELLO", {}, { tile = false, client = "10.0.0.31" }).data.needsSignIn,
  true
)
local function stationCodes(mutate)
  local c = H.Templates.sportsBar(function(pin)
    return "salt", H.hmac("salt", "vf-pin:" .. pin)
  end)
  c.stations = { { id = "s1", name = "S1", address = "10.0.0.31", profileId = "bartender" } }
  mutate(c)
  local out = {}
  for _, i in ipairs(require("venueflow.schema").validate(require("venueflow.schema").normalize(c))) do
    out[i.code] = i.severity
  end
  return out
end
eq(
  "a station can never be given a PIN profile",
  stationCodes(function(c)
    c.stations[1].profileId = "manager"
  end).STATION_PROFILE_HAS_PIN,
  "error"
)
eq(
  "a station needs a real address",
  stationCodes(function(c)
    c.stations[1].address = "the bar"
  end).STATION_ADDRESS,
  "error"
)
eq(
  "two stations cannot share an address",
  stationCodes(function(c)
    c.stations[2] = { id = "s2", name = "S2", address = "10.0.0.31", profileId = "host" }
  end).STATION_ADDRESS_SHARED,
  "error"
)
eq(
  "a station needs an existing profile",
  stationCodes(function(c)
    c.stations[1].profileId = "ghost"
  end).REF_UNKNOWN,
  "error"
)

T.done()

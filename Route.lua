-- Reads a route string copied from pullwise.gg and checks it before anything is shown or saved.
--
-- Format, version 1: "!PW1!" followed by standard base64 of raw-DEFLATE-compressed JSON.
--   v        1
--   dungeon  challenge map id (what C_ChallengeMode.GetActiveChallengeMapID returns in a key)
--   season   optional number
--   total    enemy forces the dungeon needs
--   stops    in order: a pull { forces = count, note = text } or a boss { boss = journal encounter id }
--   title    optional text; author optional text
-- Fields this version doesn't use are ignored, so the site can add to the format without breaking it.

local _, ns = ...

local Route = {}
ns.Route = Route

Route.PREFIX = "!PW1!"
Route.MAX_STRING = 20000 -- characters in a pasted string
Route.MAX_JSON = 200000 -- bytes after decompressing
Route.MAX_STOPS = 120
Route.MAX_TITLE = 80 -- bytes
Route.MAX_NOTE = 200 -- bytes
Route.MAX_ID = 2147483647

-- What the player sees when a string can't be used.
Route.MESSAGES = {
  empty = "Paste a route from pullwise.gg first.",
  too_long = "That text is too long to be a Pullwise route.",
  not_pullwise = "That isn't a Pullwise route. Copy it again from pullwise.gg.",
  newer_version = "That route was made by a newer version of Pullwise. Update the add-on, then try again.",
  no_api = "This version of the game can't read routes.",
  corrupt = "That route is damaged or incomplete. Copy it again from pullwise.gg.",
  invalid = "That route is missing something it needs. Copy it again from pullwise.gg.",
  too_many_stops = "That route has more stops than the add-on can show.",
}

local function isCount(n)
  return type(n) == "number" and n >= 0 and n <= Route.MAX_ID and n == math.floor(n)
end

local function isId(n)
  return isCount(n) and n > 0
end

-- Cuts a string to at most max bytes without splitting a UTF-8 character.
local function truncateUtf8(s, max)
  if #s <= max then
    return s
  end
  s = s:sub(1, max)
  local i = #s
  while i > 0 do
    local b = s:byte(i)
    if b < 0x80 then
      return s
    elseif b >= 0xC0 then
      local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
      if i + need - 1 > #s then
        return s:sub(1, i - 1)
      end
      return s
    end
    i = i - 1
  end
  return ""
end

-- Player-written text: one line, no game formatting codes, limited length. Returns nil for
-- missing or empty text.
function Route.CleanText(s, max)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("%c", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if s == "" then
    return nil
  end
  -- "|" starts colour, link and texture codes in game text; doubling it shows it as typed.
  return (truncateUtf8(s, max):gsub("|", "||"))
end

local function fail(code)
  return nil, code
end

-- Checks decoded data and returns a clean route, or nil and a message code.
function Route.Validate(data)
  if type(data) ~= "table" or data.v ~= 1 then
    return fail("invalid")
  end
  if not isId(data.dungeon) or not isId(data.total) then
    return fail("invalid")
  end
  if data.season ~= nil and not isCount(data.season) then
    return fail("invalid")
  end
  local stops = data.stops
  if type(stops) ~= "table" or stops[1] == nil then
    return fail("invalid")
  end
  local count = #stops
  if count > Route.MAX_STOPS then
    return fail("too_many_stops")
  end

  local route = {
    v = 1,
    dungeon = data.dungeon,
    season = data.season,
    total = data.total,
    title = Route.CleanText(data.title, Route.MAX_TITLE),
    author = Route.CleanText(data.author, Route.MAX_TITLE),
    stops = {},
  }
  local pulls = 0
  for i = 1, count do
    local stop = stops[i]
    if type(stop) ~= "table" then
      return fail("invalid")
    end
    if stop.boss ~= nil then
      if not isId(stop.boss) then
        return fail("invalid")
      end
      route.stops[i] = { boss = stop.boss }
    elseif stop.forces ~= nil then
      if not isCount(stop.forces) then
        return fail("invalid")
      end
      route.stops[i] = { forces = stop.forces, note = Route.CleanText(stop.note, Route.MAX_NOTE) }
      pulls = pulls + 1
    else
      return fail("invalid")
    end
  end
  if pulls == 0 then
    return fail("invalid")
  end
  return route
end

-- Reads a pasted string. Returns the route and the cleaned string (kept for sharing), or nil and
-- a message code.
function Route.Decode(text)
  if type(text) ~= "string" then
    return fail("empty")
  end
  -- Pasting can add spaces or line breaks; base64 never contains them.
  text = text:gsub("%s+", "")
  if text == "" then
    return fail("empty")
  end
  if #text > Route.MAX_STRING then
    return fail("too_long")
  end
  if text:sub(1, #Route.PREFIX) ~= Route.PREFIX then
    if text:match("^!PW%d+!") then
      return fail("newer_version")
    end
    return fail("not_pullwise")
  end

  local util = C_EncodingUtil
  if not (util and util.DecodeBase64 and util.DecompressString and util.DeserializeJSON) then
    return fail("no_api")
  end
  local deflate = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate or 0

  local ok, packed = pcall(util.DecodeBase64, text:sub(#Route.PREFIX + 1))
  if not ok or type(packed) ~= "string" or packed == "" then
    return fail("corrupt")
  end
  local json
  ok, json = pcall(util.DecompressString, packed, deflate)
  if not ok or type(json) ~= "string" or json == "" or #json > Route.MAX_JSON then
    return fail("corrupt")
  end
  local data
  ok, data = pcall(util.DeserializeJSON, json)
  if not ok then
    return fail("corrupt")
  end
  local route, code = Route.Validate(data)
  if not route then
    return fail(code)
  end
  return route, text
end

-- Each stop with the numbers the list shows: a pull's number, its share of the forces and the
-- running total. Percentages are 0 to 100.
function Route.Rows(route)
  local rows, pull, running = {}, 0, 0
  for i, stop in ipairs(route.stops) do
    if stop.boss then
      rows[i] = { boss = stop.boss }
    else
      pull = pull + 1
      running = running + stop.forces
      rows[i] = {
        pull = pull,
        forces = stop.forces,
        percent = stop.forces / route.total * 100,
        running = running / route.total * 100,
        note = stop.note,
      }
    end
  end
  return rows
end

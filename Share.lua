-- Sends a saved route to party members who also have Pullwise, and receives theirs.
--
-- Add-on messages are capped at 255 characters, so a route goes out in numbered pieces:
-- "<id>:<piece>:<pieces>:<text>". The game blocks add-on messages inside dungeons (Midnight's
-- chat lockdown), so routes are shared before the group goes in.

local _, ns = ...

local Share = {}
ns.Share = Share

Share.PREFIX = "PullwiseRoute"
Share.PIECE = 200 -- characters of route text per message
Share.MAX_PIECES = 110 -- enough for the longest string Route accepts
Share.TIMEOUT = 15 -- seconds to wait for the next piece (a long route takes minutes to arrive)
Share.MAX_PENDING = 10 -- unfinished routes held at once, across all senders

-- Splits a route string into messages.
function Share.Split(text, id)
  local pieces = math.ceil(#text / Share.PIECE)
  local out = {}
  for i = 1, pieces do
    local part = text:sub((i - 1) * Share.PIECE + 1, i * Share.PIECE)
    out[i] = id .. ":" .. i .. ":" .. pieces .. ":" .. part
  end
  return out
end

-- Collects pieces per sender. Returns the whole route text once its last piece arrives.
-- `pending` is the receiver's own table; `now` is the time in seconds.
function Share.Accept(pending, sender, message, now)
  for key, entry in pairs(pending) do
    if now - entry.last > Share.TIMEOUT then
      pending[key] = nil
    end
  end

  local id, piece, pieces, part = message:match("^(%w+):(%d+):(%d+):(.*)$")
  piece, pieces = tonumber(piece), tonumber(pieces)
  if not id or not piece or not pieces or pieces < 1 or pieces > Share.MAX_PIECES or piece < 1 or piece > pieces then
    return nil
  end

  local key = sender .. "\0" .. id
  local entry = pending[key]
  if not entry then
    -- Each sender gets two unfinished routes at most (a late piece of an older route must not
    -- push out the one they just started), and everyone together MAX_PENDING.
    local held, theirs, oldestKey, oldest = 0, 0, nil, nil
    for k, e in pairs(pending) do
      held = held + 1
      if e.sender == sender then
        theirs = theirs + 1
        if not oldest or e.started < oldest.started then
          oldestKey, oldest = k, e
        end
      end
    end
    if theirs >= 2 then
      pending[oldestKey] = nil
      held = held - 1
    end
    if held >= Share.MAX_PENDING then
      return nil
    end
    entry = { sender = sender, pieces = pieces, parts = {}, got = 0, started = now, last = now }
    pending[key] = entry
  elseif entry.pieces ~= pieces then
    pending[key] = nil
    return nil
  end

  entry.last = now
  if entry.parts[piece] == nil then
    entry.parts[piece] = part
    entry.got = entry.got + 1
  end
  if entry.got < entry.pieces then
    return nil
  end
  pending[key] = nil
  return table.concat(entry.parts, "", 1, entry.pieces)
end

-- Game side below: needs the WoW client.

-- Enum.SendAddonMessageResult values.
local SEND_OK = 0
local SEND_THROTTLED = 3
local SEND_NOT_IN_GROUP = 5
local SEND_CHANNEL_THROTTLED = 8
local SEND_LOCKDOWN = 11
local LOCKDOWN_MESSAGE = "The game blocks sharing inside dungeons. Share before you go in."

local function inLockdown()
  return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

local function groupChannel()
  if not IsInGroup(LE_PARTY_CATEGORY_HOME) then
    return nil
  end
  return IsInRaid(LE_PARTY_CATEGORY_HOME) and "RAID" or "PARTY"
end

local sending = false

-- Sends `text` to the group. `done(ok, message)` is called once with the outcome.
function Share.Send(text, done)
  if sending then
    return done(false, "Still sending the last route. Try again in a moment.")
  end
  local channel = groupChannel()
  if not channel then
    return done(false, "Join a group first, then share.")
  end
  if inLockdown() then
    return done(false, LOCKDOWN_MESSAGE)
  end

  local id = string.format("%04x", math.random(0, 0xFFFF))
  local messages = Share.Split(text, id)
  local i, retries = 1, 0
  sending = true

  local function finish(ok, detail)
    sending = false
    done(ok, detail)
  end

  local step -- runs `send` safely; the timers call this
  local function send()
    if i > #messages then
      return finish(true, #messages)
    end
    -- The result code is the last value returned (older clients put a boolean first).
    -- Routes carry players' own text, so they go by the logged variant Blizzard asks add-ons to
    -- use for user-written content (it arrives as CHAT_MSG_ADDON_LOGGED).
    local sendFn = C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage
    local returned = { sendFn(Share.PREFIX, messages[i], channel) }
    local result = returned[#returned]
    if result == true then
      result = SEND_OK
    end
    if result == nil or result == SEND_OK then
      i, retries = i + 1, 0
      -- The game allows a short burst per prefix, then about one message a second.
      C_Timer.After(i <= 8 and 0.2 or 1.1, step)
    elseif (result == SEND_THROTTLED or result == SEND_CHANNEL_THROTTLED) and retries < 5 then
      retries = retries + 1
      C_Timer.After(1.5, step)
    elseif result == SEND_LOCKDOWN then
      finish(false, LOCKDOWN_MESSAGE)
    elseif result == SEND_NOT_IN_GROUP then
      finish(false, "You're no longer in a group, so the route wasn't sent.")
    else
      finish(false, "The route couldn't be sent. Try again in a moment.")
    end
  end

  -- An error part way through must not leave sharing stuck until a reload.
  step = function()
    local ok = pcall(send)
    if not ok and sending then
      finish(false, "The route couldn't be sent. Try again in a moment.")
    end
  end
  step()
end

local pending = {}

-- True when `name` (as the game gives it in CHAT_MSG_ADDON) is someone in our group.
local function inOurGroup(name)
  local short = Ambiguate(name, "none")
  return UnitInParty(short) or UnitInRaid(short)
end

local function isMe(name)
  return Ambiguate(name, "none") == UnitName("player")
end

function Share.OnMessage(prefix, message, channel, sender)
  if prefix ~= Share.PREFIX or (channel ~= "PARTY" and channel ~= "RAID") then
    return
  end
  if isMe(sender) or not inOurGroup(sender) then
    return
  end
  local text = Share.Accept(pending, sender, message, GetTime())
  if text and ns.OnRouteReceived then
    ns.OnRouteReceived(Ambiguate(sender, "none"), text)
  end
end

function Share.Register()
  C_ChatInfo.RegisterAddonMessagePrefix(Share.PREFIX)
end

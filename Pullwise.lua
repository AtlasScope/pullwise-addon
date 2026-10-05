-- Saved routes, the /pullwise command, and what happens when someone shares a route.

local ADDON, ns = ...

-- PullwiseDB.routes holds one route per dungeon (a newer import replaces the older one);
-- PullwiseDB.shown is the dungeon whose route the window shows.
local db

local function say(text)
  print("|cffd4af37Pullwise:|r " .. text)
end
ns.Say = say

local function savedIds()
  local ids = {}
  for id in pairs(db.routes) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

local function dungeonName(id)
  local name = C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(id)
  return name or ("Dungeon " .. id)
end

local function show(id)
  db.shown = id
  local entry = id and db.routes[id]
  ns.Window.ShowRoute(entry and entry.route, #savedIds() > 1)
end

-- The route to open: the key being run, else the last one shown, else any saved route.
local function bestId()
  local active = C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
  if active and db.routes[active] then
    return active
  end
  if db.shown and db.routes[db.shown] then
    return db.shown
  end
  return savedIds()[1]
end

local function save(route, text)
  local replaced = db.routes[route.dungeon] ~= nil
  db.routes[route.dungeon] = { route = route, text = text }
  return replaced
end

-- Saves a pasted route and shows it. Returns true, or false and what to tell the player.
function ns.ImportText(text)
  local route, result = ns.Route.Decode(text)
  if not route then
    return false, ns.Route.MESSAGES[result] or ns.Route.MESSAGES.corrupt
  end
  local replaced = save(route, result)
  show(route.dungeon)
  ns.Window.SetStatus(replaced and ("Replaced your route for " .. dungeonName(route.dungeon) .. ".") or "Route saved.")
  return true
end

function ns.ShareShown()
  local entry = db.shown and db.routes[db.shown]
  if not entry then
    return ns.Window.SetStatus("Import a route first.")
  end
  ns.Window.SetStatus("Sharing...")
  ns.Share.Send(entry.text, function(ok, detail)
    if ok then
      ns.Window.SetStatus("Shared with your group. Members with Pullwise are asked to keep it.")
    else
      ns.Window.SetStatus(detail)
    end
  end)
end

function ns.RemoveShown()
  if db.shown then
    db.routes[db.shown] = nil
  end
  show(savedIds()[1])
end

function ns.StepShown(delta)
  local ids = savedIds()
  if #ids == 0 then
    return show(nil)
  end
  local at = 1
  for i, id in ipairs(ids) do
    if id == db.shown then
      at = i
    end
  end
  show(ids[(at - 1 + delta) % #ids + 1])
end

-- Someone in the group shared a route: check it, then ask before saving.
local offered -- the route waiting for an answer
StaticPopupDialogs["PULLWISE_ROUTE_RECEIVED"] = {
  text = "%s shared a Pullwise route for %s.\nKeep it?",
  button1 = "Keep",
  button2 = "No thanks",
  OnAccept = function()
    if offered then
      save(offered.route, offered.text)
      show(offered.route.dungeon)
      offered = nil
    end
  end,
  OnCancel = function()
    offered = nil
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

function ns.OnRouteReceived(sender, text)
  local route, cleaned = ns.Route.Decode(text)
  if not route then
    return
  end
  local entry = db.routes[route.dungeon]
  if entry and entry.text == cleaned then
    return -- already have exactly this route
  end
  offered = { route = route, text = cleaned }
  local what = dungeonName(route.dungeon)
  if route.title then
    what = what .. " (" .. route.title .. ")"
  end
  StaticPopup_Show("PULLWISE_ROUTE_RECEIVED", sender, what)
end

local function toggle()
  if ns.Window.IsRouteShown() then
    ns.Window.HideRoute()
  else
    show(bestId())
  end
end

SLASH_PULLWISE1 = "/pullwise"
SlashCmdList.PULLWISE = function(input)
  local command = (input or ""):lower():match("^%s*(%S*)")
  if command == "" or command == "route" then
    toggle()
  elseif command == "import" then
    ns.Window.ShowImport()
  elseif command == "share" then
    show(bestId())
    ns.ShareShown()
  else
    say("/pullwise opens your route. /pullwise import pastes a new one. /pullwise share sends it to your group.")
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("CHALLENGE_MODE_START")
events:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then
      return
    end
    PullwiseDB = PullwiseDB or {}
    PullwiseDB.routes = PullwiseDB.routes or {}
    db = PullwiseDB
    ns.Share.Register()
  elseif event == "CHAT_MSG_ADDON" then
    if db then
      ns.Share.OnMessage(...)
    end
  elseif event == "CHALLENGE_MODE_START" then
    local active = C_ChallengeMode.GetActiveChallengeMapID()
    if db and active and db.routes[active] then
      say("Your route for this key is ready. Type /pullwise to open it.")
    end
  end
end)

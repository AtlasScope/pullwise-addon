-- A stand-in for the parts of the game the add-on calls, so the whole add-on can be loaded and
-- driven outside the game. Any widget method not listed returns nothing, which is how most of
-- them behave; calls to game functions that don't exist here fail loudly.

local fake = { sent = {}, popups = {}, printed = {}, frames = {}, now = 100 }
FAKE = fake

local Widget = {}
Widget.__index = function(_, key)
  return Widget[key] or function() end
end
function Widget:SetScript(event, fn) self.scripts[event] = fn end
function Widget:GetScript(event) return self.scripts[event] end
function Widget:RegisterEvent(event) self.events[event] = true end
function Widget:CreateFontString() return fake.widget("FontString") end
function Widget:SetText(t) self.text = t end
function Widget:GetText() return self.text or "" end
function Widget:GetStringHeight() return self.text and self.text ~= "" and 12 or 0 end
function Widget:SetWidth(w) self.width = w end
function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:GetWidth() return self.width or 100 end
function Widget:SetHeight(h) self.height = h end
function Widget:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function Widget:Hide() self.shown = false end
function Widget:SetShown(v) self.shown = v and true or false end
function Widget:IsShown() return self.shown == true end
function Widget:SetEnabled(v) self.enabled = v end
function Widget:Click() self.scripts.OnClick(self) end

function fake.widget(kind, name)
  local w = setmetatable({ kind = kind, scripts = {}, events = {}, name = name }, Widget)
  fake.frames[#fake.frames + 1] = w
  if name then _G[name] = w end
  return w
end

function CreateFrame(kind, name) return fake.widget(kind, name) end
UIParent = fake.widget("Frame")
UISpecialFrames = {}
ChatFontNormal = {}
function print(...) fake.printed[#fake.printed + 1] = table.concat({ ... }, " ") end
function GetTime() return fake.now end

SlashCmdList = {}
-- Popups behave like the game's: showing one that is already up reuses it, first calling its
-- OnCancel with the old data (unless noCancelOnReuse is set).
StaticPopupDialogs = {}
fake.open = {} -- which -> data of the popup on screen
function StaticPopup_Show(which, a, b, data)
  local info = StaticPopupDialogs[which]
  if fake.open[which] ~= nil and info.OnCancel and not info.noCancelOnReuse then
    info.OnCancel({}, fake.open[which], "override")
  end
  fake.open[which] = data or false
  fake.popups[#fake.popups + 1] = { which = which, a = a, b = b, data = data }
end
function StaticPopup_Visible(which) return fake.open[which] ~= nil end
function fake.answerPopup(which, accept)
  local data = fake.open[which]
  fake.open[which] = nil
  local info = StaticPopupDialogs[which]
  local fn = accept and info.OnAccept or info.OnCancel
  if fn then fn({}, data or nil) end
end

-- Timers run in time order, and running one moves the clock to when it was due.
C_Timer = { After = function(delay, fn)
  fake.timers[#fake.timers + 1] = { at = fake.now + delay, fn = fn }
end }
fake.timers = {}
function fake.runTimers()
  local n = 0
  while #fake.timers > 0 do
    table.sort(fake.timers, function(x, y) return x.at < y.at end)
    local t = table.remove(fake.timers, 1)
    fake.now = math.max(fake.now, t.at)
    t.fn()
    n = n + 1
    assert(n < 1000, "timers never stop")
  end
end

fake.lockdown = false
fake.sendResults = {}
C_ChatInfo = {
  RegisterAddonMessagePrefix = function(p) fake.prefix = p; return true end,
  InChatMessagingLockdown = function() return fake.lockdown end,
  SendAddonMessage = function(prefix, msg, channel)
    local result = table.remove(fake.sendResults, 1) or 0
    if result == "error" then
      error("send failed")
    end
    if result == 0 then
      fake.sent[#fake.sent + 1] = { prefix = prefix, msg = msg, channel = channel, at = fake.now }
    end
    return result
  end,
}

fake.activeMap = nil
fake.inGroup = true
C_ChallengeMode = {
  GetMapUIInfo = function(id) if id == 9999 then return "Test Dungeon" end end,
  GetActiveChallengeMapID = function() return fake.activeMap end,
  IsChallengeModeActive = function() return fake.activeMap ~= nil end,
}
function EJ_GetEncounterInfo(id) if id == 99991 then return "Test Boss" end end
LE_PARTY_CATEGORY_HOME = 1
function IsInGroup() return fake.inGroup end
function IsInRaid() return false end
function UnitInParty(name) return fake.inGroup and name ~= "Stranger" end
function UnitInRaid() return nil end
function UnitName() return "Me" end
function Ambiguate(name) return (name:gsub("%-.*", "")) end

fake.logging = false
function LoggingCombat(on)
  if on ~= nil then fake.logging = on end
  return fake.logging
end

function fake.fire(event, ...)
  for _, f in ipairs(fake.frames) do
    if f.events[event] and f.scripts.OnEvent then
      f.scripts.OnEvent(f, event, ...)
    end
  end
end

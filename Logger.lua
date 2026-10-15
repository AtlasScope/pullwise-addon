-- Combat logging: on from the moment you enter one of the season's Mythic+ dungeons, off when the
-- key ends or you leave, and only if this add-on turned it on. The log file the game writes is
-- read by tools outside the game, such as the Pullwise Helper.
--
-- Logging starts on entering the dungeon, not when the key starts: the game writes the key's
-- CHALLENGE_MODE_START line the moment the key is activated, and a log turned on in reaction to
-- that moment can miss the line, which is the one line the Helper needs to find the key at all.
-- A dungeon run with no key (a Mythic 0) is left alone again at its first boss, so it never fills
-- the log for nothing.

local frame = CreateFrame("Frame")

local DIFFICULTY_MYTHIC_KEYSTONE = 8
local DIFFICULTY_MYTHIC = 23

-- True only while this add-on is the one that turned logging on, so we never turn off logging
-- the player started themselves. Saved, so a reload or disconnect mid-key doesn't forget it.
local function startedByUs()
  return PullwiseDB and PullwiseDB.loggingByUs == true
end

local function setStartedByUs(on)
  if PullwiseDB then
    PullwiseDB.loggingByUs = on or nil
  end
end

-- The game says a key is active from its start until the group leaves, so this stays true after
-- the key is completed too; `logDoneHere` is what tells those apart.
local function keyIsRunning()
  return C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
    and C_ChallengeMode.IsChallengeModeActive() == true
end

-- The names of this season's keystone dungeons, as the game lists them. Nil when the game can't
-- say yet (an old client, or the list hasn't arrived from the server), in which case any Mythic
-- dungeon run with a group counts.
local function keystoneDungeonNames()
  if not (C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapUIInfo) then
    return nil
  end
  local names, any = {}, false
  for _, id in ipairs(C_ChallengeMode.GetMapTable() or {}) do
    local name = C_ChallengeMode.GetMapUIInfo(id)
    if name then
      names[name] = true
      any = true
    end
  end
  return any and names or nil
end

-- Running a key, or in a dungeon set to Mythic where a key is about to go in: one of the
-- season's, or, when the game lists it under another name (a split mega-dungeon) or can't list
-- it yet, any Mythic dungeon run with a group. An old dungeon farmed solo on Mythic is not that.
local function inKeystoneDungeon()
  local name, instanceType, difficulty = GetInstanceInfo()
  if instanceType ~= "party" then
    return false
  end
  if difficulty == DIFFICULTY_MYTHIC_KEYSTONE then
    return true
  end
  if difficulty ~= DIFFICULTY_MYTHIC then
    return false
  end
  local season = keystoneDungeonNames()
  if season and season[name] then
    return true
  end
  return IsInGroup(LE_PARTY_CATEGORY_HOME) == true
end

-- The dungeon visit whose logging is already over: the key was completed, or the first boss went
-- down with no key, so it is a Mythic 0. Saved, so a reload for the loot doesn't start a fresh
-- log of nothing. Cleared on the next key start and on leaving the dungeon.
local function instanceId()
  return select(8, GetInstanceInfo())
end

local function logDoneHere()
  return PullwiseDB and PullwiseDB.logDoneIn ~= nil and PullwiseDB.logDoneIn == instanceId()
end

local function setLogDone(done)
  if PullwiseDB then
    PullwiseDB.logDoneIn = done and instanceId() or nil
  end
end

local function shouldLog()
  if logDoneHere() then
    return false
  end
  return keyIsRunning() or inKeystoneDungeon()
end

local function say(text)
  print("|cffd4af37Combat log:|r " .. text)
end

-- The review reads each player's health and position from the log, which the game only writes
-- with Advanced Combat Logging on, and it decides the layout from the log's first line, so the
-- setting must be on before logging starts. It is a plain game setting (Options, Network): turn
-- it on once and remember that in the saved settings. After that it is the player's: someone who
-- turns it off again on purpose isn't fought over it every dungeon. The player hears about it
-- once the log is actually running, not on a try the game refused.
local settingTurnedOn = false

local function ensureAdvancedLogging()
  if not PullwiseDB or PullwiseDB.advancedLoggingSet then
    return
  end
  if C_CVar.GetCVar("advancedCombatLogging") ~= "1" then
    if not C_CVar.SetCVar("advancedCombatLogging", "1") then
      return
    end
    settingTurnedOn = true
  end
  PullwiseDB.advancedLoggingSet = true
end

-- The game allows only a few LoggingCombat calls every 10 seconds, across all add-ons; past that
-- it returns nil and changes nothing. So check the answer and try again a little later, with one
-- retry pending at a time, so entering the dungeon and then starting the key don't each spend
-- the budget the other is waiting for. A key starting while a retry waits makes the retry speak
-- of the key.
local pendingWhat = nil

local function startLogging(what, tries)
  tries = tries or 0
  if pendingWhat then
    if what == "key" then pendingWhat = what end
    return
  end
  if LoggingCombat() then return end
  ensureAdvancedLogging()
  if LoggingCombat(true) == true then
    setStartedByUs(true)
    say("on for this " .. what .. "."
      .. (settingTurnedOn and " Advanced Combat Logging is on too, so your review can show health and positions." or ""))
    settingTurnedOn = false
  elseif tries < 3 then
    pendingWhat = what
    C_Timer.After(10, function()
      local wanted = pendingWhat
      pendingWhat = nil
      if shouldLog() then startLogging(wanted, tries + 1) end
    end)
  else
    say("the game didn't turn logging on. Type /combatlog to turn it on yourself.")
  end
end

local function stopLogging(tries)
  tries = tries or 0
  if not startedByUs() then return end
  if LoggingCombat(false) == false then
    setStartedByUs(false)
    say("off.")
  elseif tries < 3 then
    -- By the time the game lets us try again, the player may be in the next dungeon.
    C_Timer.After(10, function()
      if not shouldLog() then stopLogging(tries + 1) end
    end)
  end
end

-- The season's dungeon list comes from the server on request; ask once, early.
local mapsRequested = false
local function requestSeasonMaps()
  if mapsRequested then return end
  mapsRequested = true
  if C_MythicPlus and C_MythicPlus.RequestMapInfo then
    C_MythicPlus.RequestMapInfo()
  end
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("ENCOUNTER_START")

frame:SetScript("OnEvent", function(_, event)
  if event == "CHALLENGE_MODE_START" then
    -- Normally on already since the group walked in; this catches a key that started while the
    -- add-on was disabled or the game refused earlier.
    setLogDone(false)
    startLogging("key")
  elseif event == "CHALLENGE_MODE_COMPLETED" then
    -- A short delay lets the game write the key's end line before logging stops.
    setLogDone(true)
    C_Timer.After(5, function() stopLogging() end)
  elseif event == "ENCOUNTER_START" then
    -- A boss pulled with no key running: this is a Mythic 0, which the review can't use.
    if startedByUs() and not keyIsRunning() and not logDoneHere() then
      setLogDone(true)
      stopLogging()
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    requestSeasonMaps()
    -- Walking into one of the season's dungeons, or reconnecting or reloading mid-key: record.
    -- Leaving, or back in after the key was done: stop.
    local inDungeon = inKeystoneDungeon()
    if not inDungeon then
      setLogDone(false)
    end
    local running = keyIsRunning()
    if not logDoneHere() and (running or inDungeon) then
      startLogging(running and "key" or "dungeon")
    else
      stopLogging()
    end
  end
end)

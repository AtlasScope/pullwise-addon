-- Combat logging: on from the moment you enter one of the season's Mythic+ dungeons, off when the
-- key ends or you leave, and only if this add-on turned it on. The log file the game writes is
-- read by tools outside the game, such as the Pullwise Helper.
--
-- Logging starts on entering the dungeon, not when the key starts: the game writes the key's
-- CHALLENGE_MODE_START line the moment the key is activated, and a log turned on in reaction to
-- that moment can miss the line, which is the one line the Helper needs to find the key at all.

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

local function keyIsRunning()
  return C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
    and C_ChallengeMode.IsChallengeModeActive()
end

-- The names of this season's keystone dungeons, as the game lists them. Nil when the game can't
-- say (an old client), in which case any Mythic dungeon run with a group counts.
local function keystoneDungeonNames()
  if not (C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapUIInfo) then
    return nil
  end
  local names = {}
  for _, id in ipairs(C_ChallengeMode.GetMapTable() or {}) do
    local name = C_ChallengeMode.GetMapUIInfo(id)
    if name then
      names[name] = true
    end
  end
  return names
end

-- Running a key, or in one of the season's dungeons set to Mythic, where a key is about to go in.
-- An old dungeon farmed solo on Mythic is not that, and would only fill the log for nothing.
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
  if season then
    return season[name] == true
  end
  return IsInGroup(LE_PARTY_CATEGORY_HOME) == true
end

-- The key this dungeon visit already finished (saved, so a reload for the loot doesn't start a
-- fresh log of nothing). Cleared on the next key start and on leaving the dungeon.
local function instanceId()
  return select(8, GetInstanceInfo())
end

local function keyDoneHere()
  return PullwiseDB and PullwiseDB.keyDoneIn ~= nil and PullwiseDB.keyDoneIn == instanceId()
end

local function setKeyDone(done)
  if PullwiseDB then
    PullwiseDB.keyDoneIn = done and instanceId() or nil
  end
end

local function shouldLog()
  if keyIsRunning() then
    return true
  end
  return inKeystoneDungeon() and not keyDoneHere()
end

local function say(text)
  print("|cffd4af37Combat log:|r " .. text)
end

-- The review reads each player's health and position from the log, which the game only writes
-- with Advanced Combat Logging on, and it decides the layout from the log's first line, so the
-- setting must be on before logging starts. It is a plain game setting (Options, Network): turn
-- it on once, remember that in the saved settings, and say so. After that it is the player's:
-- someone who turns it off again on purpose isn't fought over it every dungeon.
local function ensureAdvancedLogging()
  if not PullwiseDB or PullwiseDB.advancedLoggingSet then
    return
  end
  if C_CVar.GetCVar("advancedCombatLogging") ~= "1" then
    if C_CVar.SetCVar("advancedCombatLogging", "1") == false then
      return
    end
    say("Advanced Combat Logging turned on, so your review can show health and positions.")
  end
  PullwiseDB.advancedLoggingSet = true
end

-- The game allows only a few LoggingCombat calls every 10 seconds, across all add-ons; past that
-- it returns nil and changes nothing. So check the answer and try again a little later, with one
-- retry pending at a time, so entering the dungeon and then starting the key don't each spend
-- the budget the other is waiting for.
local retryPending = false

local function startLogging(what, tries)
  tries = tries or 0
  if retryPending then return end
  if LoggingCombat() then return end
  ensureAdvancedLogging()
  if LoggingCombat(true) == true then
    setStartedByUs(true)
    say("on for this " .. what .. ".")
  elseif tries < 3 then
    retryPending = true
    C_Timer.After(10, function()
      retryPending = false
      if shouldLog() then startLogging(what, tries + 1) end
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

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")

frame:SetScript("OnEvent", function(_, event)
  if event == "CHALLENGE_MODE_START" then
    -- Normally on already since the group walked in; this catches a key that started while the
    -- add-on was disabled or the game refused earlier.
    setKeyDone(false)
    startLogging("key")
  elseif event == "CHALLENGE_MODE_COMPLETED" then
    -- A short delay lets the game write the key's end line before logging stops.
    setKeyDone(true)
    C_Timer.After(5, function() stopLogging() end)
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Walking into one of the season's dungeons, or reconnecting or reloading mid-key: record.
    -- Leaving, or back in after the key was done: stop.
    if not inKeystoneDungeon() then
      setKeyDone(false)
    end
    if shouldLog() then
      startLogging(keyIsRunning() and "key" or "dungeon")
    else
      stopLogging()
    end
  end
end)

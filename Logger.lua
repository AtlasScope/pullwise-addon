-- Combat logging: on from the moment you enter a Mythic or Mythic+ dungeon, off when the key ends
-- or you leave, and only if this add-on turned it on. The log file the game writes is read by
-- tools outside the game, such as the Pullwise Helper.
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

-- In a dungeon set to Mythic (where a key is about to be put in) or already running a key.
local function inMythicDungeon()
  local _, instanceType, difficulty = GetInstanceInfo()
  return instanceType == "party"
    and (difficulty == DIFFICULTY_MYTHIC_KEYSTONE or difficulty == DIFFICULTY_MYTHIC)
end

local function shouldLog()
  return keyIsRunning() or inMythicDungeon()
end

local function say(text)
  print("|cffd4af37Combat log:|r " .. text)
end

-- The review reads each player's health and position from the log, which the game only writes
-- with Advanced Combat Logging on. It is a plain game setting (Options, Network), so turn it on
-- the first time we start a log, and say so once. It stays on: it is what every logging site
-- asks players to set, and turning it off again behind their back would break their raid logs.
local function ensureAdvancedLogging()
  local get = C_CVar and C_CVar.GetCVar or GetCVar
  local set = C_CVar and C_CVar.SetCVar or SetCVar
  if not (get and set) then
    return
  end
  local ok, value = pcall(get, "advancedCombatLogging")
  if ok and value ~= "1" and pcall(set, "advancedCombatLogging", "1") then
    say("Advanced Combat Logging turned on, so your review can show health and positions.")
  end
end

-- The game allows only a few LoggingCombat calls every 10 seconds, across all add-ons; past that
-- it returns nil and changes nothing. So check the answer and try again a little later.
local function startLogging(tries)
  tries = tries or 0
  if LoggingCombat() then return end
  if LoggingCombat(true) == true then
    setStartedByUs(true)
    ensureAdvancedLogging()
    say(keyIsRunning() and "on for this key." or "on for this dungeon.")
  elseif tries < 3 then
    C_Timer.After(10, function()
      if shouldLog() then startLogging(tries + 1) end
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
    C_Timer.After(10, function() stopLogging(tries + 1) end)
  end
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")

frame:SetScript("OnEvent", function(_, event)
  if event == "CHALLENGE_MODE_START" then
    -- Normally on already since the group walked in; this catches a key that started while the
    -- add-on was disabled or the game refused earlier.
    startLogging()
  elseif event == "CHALLENGE_MODE_COMPLETED" then
    -- A short delay lets the game write the key's end line before logging stops.
    C_Timer.After(5, function() stopLogging() end)
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Walking into a Mythic dungeon, or reconnecting or reloading mid-key: record. Leaving: stop.
    if shouldLog() then
      startLogging()
    else
      stopLogging()
    end
  end
end)

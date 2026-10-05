-- Combat logging: on when a Mythic+ key starts, off when it ends, only if this add-on turned it on.
-- The log file the game writes is read by tools outside the game, such as the Pullwise Helper.

local frame = CreateFrame("Frame")

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

local function say(text)
  print("|cffd4af37Combat log:|r " .. text)
end

-- The game allows only a few LoggingCombat calls every 10 seconds, across all add-ons; past that
-- it returns nil and changes nothing. So check the answer and try again a little later.
local function startLogging(tries)
  tries = tries or 0
  if LoggingCombat() then return end
  if LoggingCombat(true) == true then
    setStartedByUs(true)
    say("on for this key.")
  elseif tries < 3 then
    C_Timer.After(10, function()
      if keyIsRunning() then startLogging(tries + 1) end
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
    startLogging()
  elseif event == "CHALLENGE_MODE_COMPLETED" then
    -- A short delay lets the game write the key's end line before logging stops.
    C_Timer.After(5, function() stopLogging() end)
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Reconnecting or reloading mid-key: keep recording. Leaving the dungeon early: stop.
    if keyIsRunning() then
      startLogging()
    else
      stopLogging()
    end
  end
end)

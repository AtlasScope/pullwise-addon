-- The two windows: pasting a route in, and the route itself as a pull list.

local _, ns = ...

local Window = {}
ns.Window = Window

local GOLD = "|cffd4af37"
local GREY = "|cffa0a0a0"
local WIDTH = 320
local ROW_GAP = 6

local function dungeonName(id)
  local name = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(id)
  return name or ("Dungeon " .. id)
end

local function bossName(id)
  local name = EJ_GetEncounterInfo and EJ_GetEncounterInfo(id)
  return name or "Boss"
end

local function makeFrame(name, height)
  local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(WIDTH, height)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  -- The template brings its own title text, anchored at one point with no width; give it both
  -- edges so a long route title stops short of the close button instead of running off.
  f.title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:ClearAllPoints()
  f.title:SetPoint("TOPLEFT", 8, -4)
  f.title:SetPoint("TOPRIGHT", -28, -4)
  f.title:SetJustifyH("CENTER")
  f.title:SetWordWrap(false)
  f:SetToplevel(true) -- clicking it brings it in front of the other Pullwise window
  f:Hide()
  -- Escape closes it, like the game's own windows.
  table.insert(UISpecialFrames, name)
  return f
end

-- Rounds down to one decimal, so a running total a little short never reads as 100%.
local function tenths(x)
  return math.floor(x * 10 + 1e-9) / 10
end

local function makeButton(parent, text, width)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  return b
end

-- Import window ------------------------------------------------------------------------------

local importFrame

local function buildImport()
  local f = makeFrame("PullwiseImportFrame", 260)
  f.title:SetText("Import a route")

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hint:SetPoint("TOPLEFT", 14, -34)
  hint:SetPoint("TOPRIGHT", -14, -34)
  hint:SetJustifyH("LEFT")
  hint:SetText("Copy a route on pullwise.gg, then paste it here (Ctrl+V, or Cmd+V on a Mac).")

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
  scroll:SetPoint("BOTTOMRIGHT", -32, 64)

  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetAutoFocus(false)
  box:SetFontObject(ChatFontNormal)
  box:SetWidth(WIDTH - 60)
  box:SetMaxLetters(0)
  box:SetScript("OnEscapePressed", function() f:Hide() end)
  -- Keep the cursor in view as the text grows, like the game's own scrolling edit boxes.
  if ScrollingEdit_OnCursorChanged and ScrollingEdit_OnUpdate then
    box:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
    box:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, scroll) end)
  end
  scroll:SetScrollChild(box)
  -- Clicking anywhere in the box area puts the cursor in it.
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function() box:SetFocus() end)
  f.box = box

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontRed")
  status:SetPoint("BOTTOMLEFT", 14, 38)
  status:SetPoint("BOTTOMRIGHT", -14, 38)
  status:SetJustifyH("LEFT")
  f.status = status

  local import = makeButton(f, "Import", 100)
  import:SetPoint("BOTTOMRIGHT", -12, 10)
  import:SetScript("OnClick", function()
    local ok, message = ns.ImportText(box:GetText())
    if ok then
      f:Hide()
    else
      status:SetText(message)
    end
  end)

  local cancel = makeButton(f, "Cancel", 80)
  cancel:SetPoint("RIGHT", import, "LEFT", -6, 0)
  cancel:SetScript("OnClick", function() f:Hide() end)

  box:SetScript("OnTextChanged", function() status:SetText("") end)
  f:SetScript("OnShow", function()
    box:SetText("")
    status:SetText("")
    box:SetFocus()
  end)
  return f
end

function Window.ShowImport()
  importFrame = importFrame or buildImport()
  importFrame:Show()
  importFrame:Raise()
end

-- Route window -------------------------------------------------------------------------------

local routeFrame
local rows = {}

local function getRow(content, i)
  local row = rows[i]
  if row then
    return row
  end
  row = CreateFrame("Frame", nil, content)
  row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.label:SetPoint("TOPLEFT", 0, 0)
  row.numbers = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.numbers:SetPoint("TOPRIGHT", 0, 0)
  row.numbers:SetJustifyH("RIGHT")
  row.note = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.note:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -2)
  row.note:SetJustifyH("LEFT")
  row.note:SetWordWrap(true)
  rows[i] = row
  return row
end

local function buildRoute()
  local f = makeFrame("PullwiseRouteFrame", 440)

  local summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  summary:SetPoint("TOPLEFT", 14, -32)
  summary:SetPoint("TOPRIGHT", -70, -32) -- leaves room for the arrows
  summary:SetJustifyH("LEFT")
  f.summary = summary

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -8)
  scroll:SetPoint("BOTTOMRIGHT", -32, 64)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH - 50, 1)
  scroll:SetScrollChild(content)
  f.scroll, f.content = scroll, content

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  status:SetPoint("BOTTOMLEFT", 14, 38)
  status:SetPoint("BOTTOMRIGHT", -14, 38)
  status:SetJustifyH("LEFT")
  f.status = status

  local share = makeButton(f, "Share with group", 130)
  share:SetPoint("BOTTOMLEFT", 10, 10)
  share:SetScript("OnClick", function() ns.ShareShown() end)

  local import = makeButton(f, "Import", 70)
  import:SetPoint("LEFT", share, "RIGHT", 4, 0)
  import:SetScript("OnClick", Window.ShowImport)

  local remove = makeButton(f, "Remove", 70)
  remove:SetPoint("LEFT", import, "RIGHT", 4, 0)
  remove:SetScript("OnClick", function() ns.AskRemoveShown() end)
  f.remove = remove

  local prev = makeButton(f, "<", 24)
  prev:SetPoint("TOPRIGHT", -40, -28)
  prev:SetScript("OnClick", function() ns.StepShown(-1) end)
  local nextB = makeButton(f, ">", 24)
  nextB:SetPoint("LEFT", prev, "RIGHT", 2, 0)
  nextB:SetScript("OnClick", function() ns.StepShown(1) end)
  f.prev, f.next = prev, nextB
  return f
end

local function setStatus(text)
  if routeFrame then
    routeFrame.status:SetText(text or "")
  end
end
Window.SetStatus = setStatus

-- Shows `route`, or an empty state when it is nil. `many` is true when more than one route is
-- saved, so the arrows to step between them are worth showing.
function Window.ShowRoute(route, many)
  routeFrame = routeFrame or buildRoute()
  local f = routeFrame
  f.prev:SetShown(many)
  f.next:SetShown(many)
  f.remove:SetEnabled(route ~= nil)
  for _, row in ipairs(rows) do
    row:Hide()
  end

  if not route then
    f.title:SetText("Pullwise routes")
    f.summary:SetText("No routes yet. Copy one on pullwise.gg, then press Import.")
    f.content:SetHeight(1)
    f:Show()
    return
  end

  local name = dungeonName(route.dungeon)
  local title = route.title
  -- A title that already names the dungeon is shown as is, not as "Kings' Rest: Kings' Rest: ...".
  if title and title:sub(1, #name) ~= name then
    title = name .. ": " .. title
  end
  f.title:SetText(title or name)
  local by = route.author and (" · by " .. route.author) or ""
  f.summary:SetText(GREY .. "Enemy forces needed: " .. route.total .. by .. "|r")

  local y, width = 0, f.content:GetWidth()
  for i, r in ipairs(ns.Route.Rows(route)) do
    local row = getRow(f.content, i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetWidth(width)
    row.note:SetWidth(width)
    if r.boss then
      row.label:SetText(GOLD .. bossName(r.boss) .. "|r")
      row.numbers:SetText("")
      row.note:SetText("")
    else
      row.label:SetText("Pull " .. r.pull)
      row.numbers:SetText(string.format("+%d · %.1f%%  " .. GREY .. "%.1f%% so far|r", r.forces, r.percent, tenths(r.running)))
      row.note:SetText(r.note and (GREY .. r.note .. "|r") or "")
    end
    local height = row.label:GetStringHeight()
    if r.note then
      height = height + 2 + row.note:GetStringHeight()
    end
    row:SetHeight(height)
    row:Show()
    y = y + height + ROW_GAP
  end
  f.content:SetHeight(math.max(y, 1))
  f.scroll:SetVerticalScroll(0)
  f:Show()
end

function Window.IsRouteShown()
  return routeFrame and routeFrame:IsShown()
end

function Window.HideRoute()
  if routeFrame then
    routeFrame:Hide()
  end
end

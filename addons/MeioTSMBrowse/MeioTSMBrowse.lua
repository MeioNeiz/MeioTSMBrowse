-- MeioTSMBrowse: a category tree and level filter docked beside TSM's Browse (Shopping) tab,
-- like the standard auction house, plus recipe help for your professions.
--
-- A category click runs a TSM filter string
-- ("name/minLvl/maxLvl/Class/Subclass/Slot/words") through TSMLocalShopping (patch 14), using TSM's own class names so every filter
-- parses. Patch 14 also lets us add the filter words "learnable" and "skillup", applied to
-- every auction result (non-recipes pass).
--
-- Skill-up ranges are estimates: the client has no orange/yellow/green/grey data for
-- recipes you haven't learned. Vanilla's usual spread is yellow +25, green +37, grey +50
-- over the required skill; `span` moves the grey point and the others scale with it.

local NAME = "MeioTSMBrowse"
local SV_NAME = "MeioTSMBrowseDB"
local SLASH = "/tsmbrowse"
local PATCH = "14-tsm-browse-hooks"

local WIDTH = 230
local ROW_HEIGHT = 16
local RECIPE_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Recipe or 9
local MINE_KEY = "#mine"
local api = nil
local db = {}
local panel = nil
local rows = {}
local tree = nil
local visibleNodes = {}

local GOLD_TEXT, ON, OFF, MUTED = "|cffffd100", "|cff80ff80", "|cffff8080", "|cff999999"
local SHIFT_HINT = MUTED .. "Shift: more|r"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb090ff" .. NAME .. ":|r " .. msg)
end

local function Cmd(sub)
    return GOLD_TEXT .. SLASH .. (sub and (" " .. sub) or "") .. "|r"
end

local function OnOff(on) return on and (ON .. "on|r") or (OFF .. "off|r") end

-- one "Shift: more" per tooltip across our addons; OnTooltipCleared resets it
local function AddShiftHint(tooltip)
    if tooltip.meioShiftHint then return end
    tooltip.meioShiftHint = true
    tooltip:AddLine(SHIFT_HINT)
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
    tip:HookScript("OnTooltipCleared", function(self) self.meioShiftHint = nil end)
end

local function MaxLevel()
    return GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
end

local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
local GetItemClassInfo = C_Item and C_Item.GetItemClassInfo or GetItemClassInfo
local IsAddOnLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

--------------------------------------------------
-- Professions and recipes
--------------------------------------------------
local ranks = nil -- profession name -> current skill
local recipeInfo = {} -- itemID -> { prof, req, known } or false (not a recipe)

local function Ranks()
    if ranks then return ranks end
    ranks = {}
    if GetProfessions and GetProfessionInfo then
        -- pairs: GetProfessions returns nil for empty slots
        for _, index in pairs({ GetProfessions() }) do
            local name, _, rank = GetProfessionInfo(index)
            if name then ranks[name] = rank end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank = GetSkillLineInfo(i)
            if name and not isHeader and not ranks[name] then ranks[name] = rank end
        end
    end
    return ranks
end

local function GlobalPattern(fmt)
    fmt = fmt:gsub("[%(%)%.%-%+%*%?%[%]%^%$]", "%%%0")
    fmt = fmt:gsub("%%s", "(.-)"):gsub("%%d", "(%%d+)")
    return "^" .. fmt .. "$"
end
local SKILL_PATTERN = GlobalPattern(ITEM_MIN_SKILL or "Requires %s (%d)")
local KNOWN_TEXT = ITEM_SPELL_KNOWN or "Already known"

local scanTip = nil
local function TooltipLines(itemID)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
        local data = C_TooltipInfo.GetItemByID(itemID)
        for _, line in ipairs(data and data.lines or {}) do
            if line.leftText then tinsert(lines, line.leftText) end
        end
        return lines
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", NAME .. "ScanTip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:SetItemByID(itemID)
    for i = 1, scanTip:NumLines() do
        local text = _G[NAME .. "ScanTipTextLeft" .. i]:GetText()
        if text then tinsert(lines, text) end
    end
    scanTip:Hide()
    return lines
end

-- nil while the item isn't cached yet
local function RecipeInfo(itemID)
    if recipeInfo[itemID] ~= nil then return recipeInfo[itemID] end
    local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
    if not classID then return nil end
    if classID ~= RECIPE_CLASS then
        recipeInfo[itemID] = false
        return false
    end
    local info = nil
    for _, text in ipairs(TooltipLines(itemID)) do
        local prof, req = text:match(SKILL_PATTERN)
        if prof and not info then
            info = { prof = prof, req = tonumber(req) }
        elseif text == KNOWN_TEXT and info then
            info.known = true
        end
    end
    if not info then return nil end
    recipeInfo[itemID] = info
    return info
end

local function Bands(req)
    local span = db.span or 50
    return req + math.floor(span / 2), req + math.floor(span * 3 / 4), req + span
end

-- state: "known" | "noprof" | "low" | "skillup" | "grey"
local function RecipeState(info)
    if info.known then return "known" end
    local rank = Ranks()[info.prof]
    if not rank then return "noprof" end
    if rank < info.req then return "low", rank end
    local _, _, grey = Bands(info.req)
    return rank < grey and "skillup" or "grey", rank
end

local function ItemIDFromString(itemString)
    return tonumber(itemString and itemString:match("^i:(%d+)"))
end

local function PassesLearnable(itemString)
    local info = RecipeInfo(ItemIDFromString(itemString) or 0)
    if not info then return true end
    local state = RecipeState(info)
    return state == "skillup" or state == "grey"
end

local function PassesSkillup(itemString)
    local info = RecipeInfo(ItemIDFromString(itemString) or 0)
    if not info then return true end
    return RecipeState(info) == "skillup"
end

--------------------------------------------------
-- Recipe tooltips
--------------------------------------------------
-- skill difficulty colours, as on the profession window
local GREY, ORANGE, YELLOW, LGREEN = "|cff9d9d9d", "|cffff8040", "|cffffff00", "|cff40ff40"

-- the recipe whose tooltip we'd add lines to, else nil. Meionomics' Teaches row already
-- shows the learn state.
local function TooltipRecipe(itemID)
    if not itemID or IsAddOnLoaded("Meionomics") then return nil end
    local info = RecipeInfo(itemID)
    if info and not info.known then return info end
end

local function AddRecipeLines(tooltip, itemID)
    local info = TooltipRecipe(itemID)
    if not info then return end
    local state, rank = RecipeState(info)
    local yellow, green, grey = Bands(info.req)
    local shift = IsShiftKeyDown()
    if state == "noprof" then
        if not shift then return end
        tooltip:AddLine(MUTED .. "You don't have " .. info.prof .. "|r")
    elseif state == "low" then
        tooltip:AddLine(OFF .. format("%s %d/%d: %d more skill to learn it|r",
            info.prof, rank, info.req, info.req - rank))
    elseif state == "skillup" then
        tooltip:AddLine(ON .. format("Learnable: skill-ups until ~%d (you: %d)|r",
            grey, rank))
    else
        tooltip:AddLine(MUTED .. format(
            "Learnable, but no skill-ups (grey from ~%d, you: %d)|r", grey, rank))
    end
    if shift then
        tooltip:AddLine(format("%s%d|r - %s%d|r - %s%d|r - %s%d|r",
            ORANGE, info.req, YELLOW, yellow, LGREEN, green, GREY, grey))
        tooltip:AddLine(MUTED .. "Orange / yellow / green / grey from: estimate, no server"
            .. " data|r", nil, nil, nil, true)
    elseif state ~= "noprof" then
        AddShiftHint(tooltip)
    end
    tooltip:Show()
end

local function OnTooltipItem(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    local itemID = data and data.id
    if not itemID and tooltip.GetItem then
        local _, link = tooltip:GetItem()
        itemID = link and tonumber(link:match("item:(%d+)"))
    end
    AddRecipeLines(tooltip, itemID)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
else
    GameTooltip:HookScript("OnTooltipSetItem", OnTooltipItem)
    ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipItem)
end

-- Shift changes the lines. RefreshData keeps a bag or merchant tooltip's own context but
-- did nothing on TSM's AH rows, which are set by hyperlink: set those again instead.
local function RedrawRecipeTooltip()
    local _, link = GameTooltip:GetItem()
    if not TooltipRecipe(link and tonumber(link:match("item:(%d+)"))) then return end
    local info = GameTooltip.GetPrimaryTooltipInfo and GameTooltip:GetPrimaryTooltipInfo()
    if info and info.getterName and info.getterName ~= "GetHyperlink" then
        GameTooltip:RefreshData()
    else
        GameTooltip:SetHyperlink(link)
    end
end

--------------------------------------------------
-- Category tree from TSM's class lists
--------------------------------------------------
local function Node(label, parts, depth)
    return { label = label, parts = parts, key = table.concat(parts, "/"), depth = depth,
        children = {} }
end

-- TSM lists classes the game no longer uses ("Jewelry (OBSOLETE)")
local function Current(names)
    local result = {}
    for _, name in ipairs(names or {}) do
        if not name:find("OBSOLETE", 1, true) then tinsert(result, name) end
    end
    return result
end

local function BuildTree()
    local root = {}
    local recipeClass = GetItemClassInfo(RECIPE_CLASS)
    local mine = { label = "My professions", key = MINE_KEY, depth = 0, children = {},
        group = true }
    tinsert(root, mine)
    for _, class in ipairs(Current(api.GetClasses())) do
        local classNode = Node(class, { class }, 0)
        for _, sub in ipairs(Current(api.GetSubClasses(class))) do
            local subNode = Node(sub, { class, sub }, 1)
            for _, slot in ipairs(api.GetSlots(class, sub) or {}) do
                tinsert(subNode.children, Node(slot, { class, sub, slot }, 2))
            end
            tinsert(classNode.children, subNode)
            if class == recipeClass then
                local node = Node(sub, { class, sub }, 1)
                node.profession = sub
                tinsert(mine.children, node)
            end
        end
        for _, slot in ipairs(api.GetGenericSlots(class) or {}) do
            tinsert(classNode.children, Node(slot, { class, slot }, 1))
        end
        tinsert(root, classNode)
    end
    return root
end

local function IsExpanded(node)
    if node.key == MINE_KEY then return not db.mineCollapsed end
    return db.expanded[node.key]
end

local function Flatten(nodes, out)
    for _, node in ipairs(nodes) do
        if not node.profession or Ranks()[node.profession] then
            tinsert(out, node)
            if IsExpanded(node) then Flatten(node.children, out) end
        end
    end
end

--------------------------------------------------
-- Level range
--------------------------------------------------
local function PresetRange(mode)
    local level = UnitLevel("player")
    if mode == "upto" then
        return 1, level
    elseif mode == "near" then
        return math.max(1, level - db.nearSpan), level
    end
end

local function RefreshLevel()
    local min, max = PresetRange(db.levelMode)
    if db.levelMode == "custom" then
        min, max = db.customMin, db.customMax
    end
    panel.minBox:SetText(min and tostring(min) or "")
    panel.maxBox:SetText(max and tostring(max) or "")
    for mode, button in pairs(panel.presets) do
        if mode == db.levelMode then
            button:LockHighlight()
        else
            button:UnlockHighlight()
        end
    end
end

local function SetLevelMode(mode)
    db.levelMode = mode
    RefreshLevel()
end

--------------------------------------------------
-- Search
--------------------------------------------------
local function BuildFilter()
    -- "/" separates filter parts and ";" separates searches in TSM's syntax
    local keyword = strtrim(((panel.keyword:GetText() or ""):gsub("[/;]", " ")))
    local parts = { keyword }
    local min = tonumber(panel.minBox:GetText())
    local max = tonumber(panel.maxBox:GetText())
    if min or max then
        min, max = min or 0, max or MaxLevel()
        if min > max then min, max = max, min end
        tinsert(parts, tostring(min))
        tinsert(parts, tostring(max))
    end
    if db.selected then
        for part in db.selected:gmatch("[^/]+") do tinsert(parts, part) end
    end
    if db.usable then tinsert(parts, "usable") end
    if db.skillup and api.hasWords then
        tinsert(parts, "skillup")
    elseif db.learnable and api.hasWords then
        tinsert(parts, "learnable")
    end
    return table.concat(parts, "/")
end

local function RunSearch()
    panel.keyword:ClearFocus()
    panel.minBox:ClearFocus()
    panel.maxBox:ClearFocus()
    if not api.Search(BuildFilter()) then
        Print("open the Browse tab first.")
    end
end

--------------------------------------------------
-- Tree rows
--------------------------------------------------
local RefreshTree

local function OnRowClick(row)
    local node = row.node
    if node.key == MINE_KEY then
        db.mineCollapsed = not db.mineCollapsed or nil
        RefreshTree()
        return
    end
    if #node.children > 0 then
        db.expanded[node.key] = not db.expanded[node.key] or nil
    end
    db.selected = node.key
    RefreshTree()
    RunSearch()
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Button", nil, panel.content)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", panel.content, "RIGHT")
    local hover = row:CreateTexture()
    hover:SetColorTexture(1, 1, 1, 0.08)
    row:SetHighlightTexture(hover)
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(0.3, 0.6, 1, 0.25)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("RIGHT", -2, 0)
    row.text:SetJustifyH("LEFT")
    row:SetScript("OnClick", OnRowClick)
    rows[i] = row
    return row
end

function RefreshTree()
    wipe(visibleNodes)
    Flatten(tree, visibleNodes)
    for i, node in ipairs(visibleNodes) do
        local row = GetRow(i)
        row.node = node
        local sign = #node.children == 0 and "   " or (IsExpanded(node) and "- " or "+ ")
        local label = node.label
        if node.profession then
            label = format("%s |cff9d9d9d(%d)|r", label, Ranks()[node.profession])
        elseif node.group then
            label = "|cff4fc3f7" .. label .. "|r"
        end
        row.text:SetPoint("LEFT", 4 + node.depth * 12, 0)
        row.text:SetText(sign .. label)
        row.text:SetFontObject(node.depth == 0 and GameFontNormalSmall
            or GameFontHighlightSmall)
        row.selected:SetShown(node.key == db.selected and not node.group)
        row:Show()
    end
    for i = #visibleNodes + 1, #rows do rows[i]:Hide() end
    panel.content:SetHeight(math.max(1, #visibleNodes * ROW_HEIGHT))
end

--------------------------------------------------
-- TSM and patch state
--------------------------------------------------
local function PatchState()
    if not IsAddOnLoaded("TradeSkillMaster") then return "notsm" end
    if not TSMLocalShopping then return "missing" end
    if not TSMLocalAddItemFilter then return "partial" end
    return "ok"
end

-- the CurseForge/Wago zip has only the addon; the installer lives in the GitHub download
local PATCH_HELP = "TSM needs a small patch (" .. PATCH .. "): download the installer from"
    .. " github.com/MeioNeiz/MeioTSMBrowse (\"TSM patch\" in its page), run it with WoW"
    .. " closed, then start WoW. TSM updates undo it."

local function PatchMessage()
    local state = PatchState()
    if state == "notsm" then
        return "the category panel needs TradeSkillMaster, which isn't loaded (recipe"
            .. " tooltips work without it)."
    elseif state == "missing" then
        return "TSM isn't patched, so the category panel is off (recipe tooltips still"
            .. " work). " .. PATCH_HELP
    elseif state == "partial" then
        return "TSM's patch is out of date: the recipe filters are off. " .. PATCH_HELP
    end
end

-- said when he opens the AH, not at login, and once per TSM version: an update undoes the
-- patch, and saying so at every visit would nag
local function WarnPatchOnce()
    local state = PatchState()
    if state == "ok" or state == "notsm" or db.panel == false then return end
    local version = GetAddOnMetadata("TradeSkillMaster", "Version") or "?"
    if db.warnedFor == version then return end
    db.warnedFor = version
    Print(PatchMessage())
end

--------------------------------------------------
-- Panel
--------------------------------------------------
-- TSM's flat look, so the panel reads as part of its window: dark fills, 1px borders, gold for
-- selected or focused
local GOLD = { 1, 0.82, 0 }
local LINE = { 0.3, 0.3, 0.33 }

local function Flat(frame, bg, border)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    frame:SetBackdropColor(bg, bg, bg + 0.02, 1)
    frame:SetBackdropBorderColor(unpack(border or LINE))
end

-- LockHighlight/UnlockHighlight kept as the selected state, which RefreshLevel uses
local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, 20)
    b:SetNormalFontObject(GameFontHighlightSmall)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    local function Paint(self)
        Flat(self, self:IsMouseOver() and 0.24 or 0.16, self.locked and GOLD or LINE)
        self:GetFontString():SetTextColor(unpack(self.locked and GOLD or { 1, 1, 1 }))
    end
    function b:LockHighlight() self.locked = true Paint(self) end
    function b:UnlockHighlight() self.locked = nil Paint(self) end
    b:SetScript("OnEnter", Paint)
    b:SetScript("OnLeave", Paint)
    Paint(b)
    return b
end

local function Box(parent)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetFontObject(GameFontHighlightSmall)
    box:SetTextInsets(5, 5, 0, 0)
    box:SetAutoFocus(false)
    Flat(box, 0.04)
    box:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(unpack(GOLD)) end)
    box:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(LINE)) end)
    return box
end

local function Text(t) return type(t) == "function" and t() or t end

local function ShowTip(frame)
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:SetText(Text(frame.tsmbTip), 1, 1, 1, 1, true)
    local detail = Text(frame.tsmbDetail)
    if detail and IsShiftKeyDown() then
        GameTooltip:AddLine(detail, 0.8, 0.8, 0.8, true)
    elseif detail then
        AddShiftHint(GameTooltip)
    end
    GameTooltip:Show()
end

-- short text always, detail with Shift; either may be a function, read on each hover
local function Tooltip(frame, text, detail)
    frame.tsmbTip, frame.tsmbDetail = text, detail
    frame:HookScript("OnEnter", ShowTip)
    frame:HookScript("OnLeave", GameTooltip_Hide)
end

local function NumberBox(parent)
    local box = Box(parent)
    box:SetSize(34, 18)
    box:SetJustifyH("CENTER")
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    box:SetScript("OnTextChanged", function(_, userInput)
        if not userInput then return end
        db.levelMode = "custom"
        db.customMin = tonumber(panel.minBox:GetText())
        db.customMax = tonumber(panel.maxBox:GetText())
        for _, button in pairs(panel.presets) do button:UnlockHighlight() end
    end)
    box:SetScript("OnEnterPressed", RunSearch)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnTabPressed", function(self)
        local other = self == panel.minBox and panel.maxBox or panel.minBox
        other:SetFocus()
    end)
    return box
end

local NO_WORDS = OFF .. "Off: TSM's patch is out of date|r"

local function CheckBox(y, text, key, tip, detail, needsWords)
    local cb = CreateFrame("CheckButton", nil, panel, "BackdropTemplate")
    cb:SetSize(13, 13)
    cb:SetPoint("TOPLEFT", 9, y - 4)
    Flat(cb, 0.04)
    local tick = cb:CreateTexture(nil, "ARTWORK")
    tick:SetPoint("TOPLEFT", 3, -3)
    tick:SetPoint("BOTTOMRIGHT", -3, 3)
    tick:SetColorTexture(unpack(GOLD))
    cb:SetCheckedTexture(tick)
    local off = cb:CreateTexture(nil, "ARTWORK")
    off:SetAllPoints(tick)
    off:SetColorTexture(0.45, 0.45, 0.45)
    cb:SetDisabledCheckedTexture(off)
    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    label:SetText(text)
    -- the label clicks too, as on Blizzard's check buttons
    cb:SetHitRectInsets(0, -(label:GetStringWidth() + 6), -3, -3)
    cb:SetScript("OnClick", function(self) db[key] = self:GetChecked() or nil end)
    cb.key = key
    if needsWords and not api.hasWords then
        cb:Disable()
        label:SetFontObject(GameFontDisableSmall)
        -- a disabled button gets no OnEnter: a mouse-enabled cover shows the tooltip
        local cover = CreateFrame("Frame", nil, panel)
        cover:SetPoint("TOPLEFT", cb)
        cover:SetPoint("BOTTOMRIGHT", label)
        cover:EnableMouse(true)
        Tooltip(cover, tip .. "\n" .. NO_WORDS, (detail and (detail .. "\n\n") or "")
            .. PATCH_HELP)
    else
        Tooltip(cb, tip, detail)
    end
    return cb
end

local function CreatePanel()
    panel = CreateFrame("Frame", NAME .. "Panel", UIParent, "BackdropTemplate")
    panel:SetWidth(WIDTH)
    panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    panel:SetBackdropColor(0.07, 0.07, 0.08, 0.96)
    panel:SetBackdropBorderColor(0.25, 0.25, 0.28, 1)
    panel:EnableMouse(true)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -8)
    title:SetText("Categories")

    panel.keyword = Box(panel)
    panel.keyword:SetPoint("TOPLEFT", 8, -28)
    panel.keyword:SetPoint("RIGHT", -8, 0)
    panel.keyword:SetHeight(20)
    panel.keyword:SetScript("OnEnterPressed", RunSearch)
    panel.keyword:SetScript("OnEscapePressed", panel.keyword.ClearFocus)
    Tooltip(panel.keyword, "Item name to search for (optional)", "Combined with the"
        .. " category, level range and filters below. Enter searches.")

    local levelLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    levelLabel:SetPoint("TOPLEFT", 8, -58)
    levelLabel:SetText("Required level")
    panel.minBox = NumberBox(panel)
    panel.minBox:SetPoint("LEFT", levelLabel, "RIGHT", 12, 0)
    local dash = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dash:SetPoint("LEFT", panel.minBox, "RIGHT", 2, 0)
    dash:SetText("-")
    panel.maxBox = NumberBox(panel)
    panel.maxBox:SetPoint("LEFT", dash, "RIGHT", 8, 0)

    panel.presets = {
        any = Button(panel, "Any", 66, function() SetLevelMode("any") end),
        upto = Button(panel, "Up to me", 70, function() SetLevelMode("upto") end),
        near = Button(panel, "Near me", 70, function() SetLevelMode("near") end),
    }
    panel.presets.any:SetPoint("TOPLEFT", 8, -76)
    panel.presets.upto:SetPoint("LEFT", panel.presets.any, "RIGHT", 4, 0)
    panel.presets.near:SetPoint("LEFT", panel.presets.upto, "RIGHT", 4, 0)
    Tooltip(panel.presets.any, "Any required level")
    Tooltip(panel.presets.upto, "Level 1 to your level", "Everything you can already use.")
    Tooltip(panel.presets.near, function()
        local from = math.max(1, UnitLevel("player") - db.nearSpan)
        return format("Level %d to your level", from)
    end, function()
        return format("Starts %d levels below yours. Change it with %s or in Esc >"
            .. " Options > AddOns > %s.", db.nearSpan, SLASH .. " near <n>", NAME)
    end)

    panel.checks = {
        CheckBox(-98, "Usable only", "usable", "Only items your character can use"),
        CheckBox(-118, "Recipes I can learn", "learnable", "Only recipes you can learn now",
            "For your professions, with enough skill, not already known. Other items are"
            .. " not affected.", true),
        CheckBox(-138, "Recipes that give skill-ups", "skillup",
            "Only recipes that still give skill-ups", "Learnable recipes that should still"
            .. " give skill points at your current skill. An estimate: the game has no"
            .. " skill-up data for recipes you haven't learned (" .. SLASH .. " span <n>)."
            .. " Other items are not affected.", true),
    }

    local search = Button(panel, "Search", 104, RunSearch)
    search:SetPoint("BOTTOMLEFT", 8, 8)
    Tooltip(search, "Search with the name, category, level range and filters")
    local clear = Button(panel, "Clear", 104, function()
        panel.keyword:SetText("")
        db.selected = nil
        wipe(db.expanded)
        RefreshTree()
    end)
    clear:SetPoint("LEFT", search, "RIGHT", 6, 0)
    Tooltip(clear, "Clear the name and category, collapse the tree")

    -- Blizzard's slim modern scroll bar where the client has it: closer to TSM's than the old
    -- arrowed one
    local slim = ScrollUtil and ScrollUtil.InitScrollFrameWithScrollBar
    local scroll = CreateFrame("ScrollFrame", nil, panel,
        not slim and "UIPanelScrollFrameTemplate" or nil)
    scroll:SetPoint("TOPLEFT", 6, -164)
    scroll:SetPoint("BOTTOMRIGHT", slim and -16 or -26, 34)
    if slim then
        local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
        bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
        slim(scroll, bar)
        if not scroll:GetScript("OnMouseWheel") then
            scroll:EnableMouseWheel(true)
            scroll:SetScript("OnMouseWheel", function(self, delta)
                local y = self:GetVerticalScroll() - delta * ROW_HEIGHT * 3
                self:SetVerticalScroll(math.max(0, math.min(y, self:GetVerticalScrollRange())))
            end)
        end
    end
    panel.content = CreateFrame("Frame", nil, scroll)
    panel.content:SetSize(WIDTH - 32, 1)
    scroll:SetScrollChild(panel.content)
end

--------------------------------------------------
-- Docking beside the TSM window
--------------------------------------------------
local function Dock()
    local window = api.GetWindow()
    if not window or not window:IsVisible() or db.panel == false then
        panel:Hide()
        return
    end
    if not tree or #tree <= 1 then tree = BuildTree() end
    panel:ClearAllPoints()
    local roomLeft = (window:GetLeft() or 0) * window:GetEffectiveScale()
        / panel:GetEffectiveScale()
    if roomLeft > WIDTH + 4 then
        panel:SetPoint("TOPRIGHT", window, "TOPLEFT", -2, 0)
        panel:SetPoint("BOTTOMRIGHT", window, "BOTTOMLEFT", -2, 0)
    else
        panel:SetPoint("TOPLEFT", window, "TOPRIGHT", 2, 0)
        panel:SetPoint("BOTTOMLEFT", window, "BOTTOMRIGHT", 2, 0)
    end
    panel:SetFrameStrata(window:GetFrameStrata())
    panel:SetFrameLevel(window:GetFrameLevel() + 5)
    for _, cb in ipairs(panel.checks) do cb:SetChecked(db[cb.key] and true or false) end
    RefreshLevel()
    RefreshTree()
    panel:Show()
end

-- TSM calls this while building the tab, before it is attached to its window: dock a frame
-- later
local function OnShoppingShown(shown)
    if shown then
        C_Timer.After(0, Dock)
    else
        panel:Hide()
    end
end

--------------------------------------------------
-- Settings panel (Esc > Options > AddOns > MeioTSMBrowse), bound straight to MeioTSMBrowseDB, in the
-- same words as the chat commands
--------------------------------------------------
local category, layout
-- chat and slider share these, so the slider never shows a value outside its range
local NEAR_MAX, SPAN_MIN, SPAN_MAX = 30, 10, 100

local function ShowPanel(on)
    db.panel = on
    if not panel then return end
    if on then Dock() else panel:Hide() end
end

local function OnChange(setting, fn)
    if Settings.SetOnValueChangedCallback then
        Settings.SetOnValueChangedCallback(setting:GetVariable(), function(_, _, value)
            fn(value)
        end)
    elseif setting.SetValueChangedCallback then
        setting:SetValueChangedCallback(function(_, value) fn(value) end)
    end
end

local function Slider(key, name, default, min, max, tip, fn)
    local setting = Settings.RegisterAddOnSetting(category, "TSMBROWSE_" .. key:upper(), key,
        db, Settings.VarType.Number, name, default)
    local options = Settings.CreateSliderOptions(min, max, 1)
    if MinimalSliderWithSteppersMixin and options.SetLabelFormatter then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(category, setting, options, tip)
    if fn then OnChange(setting, fn) end
end

local function Header(title, tip)
    if CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title, tip))
    end
end

local function RegisterSettings()
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
    category, layout = Settings.RegisterVerticalLayoutCategory(NAME)

    Header("Browse tab", "A category tree and level presets beside TSM's Browse tab, as"
        .. " on the standard auction house.")
    local tip = "Show the category tree beside TSM's Browse tab (" .. SLASH .. " on||off)."
    local problem = PatchMessage()
    if problem and PatchState() ~= "partial" then
        tip = tip .. "\n\n" .. OFF .. problem:gsub("^%l", string.upper) .. "|r"
    end
    local shown = Settings.RegisterAddOnSetting(category, "TSMBROWSE_PANEL", "panel", db,
        Settings.VarType.Boolean, "Category panel", true)
    Settings.CreateCheckbox(category, shown, tip)
    OnChange(shown, ShowPanel)
    Slider("nearSpan", "Near me range", 5, 0, NEAR_MAX, "How many levels below yours the"
        .. " Near me button starts (" .. SLASH .. " near <n>).", function()
            if panel and panel:IsShown() then RefreshLevel() end
        end)

    Header("Recipe tooltips", "Whether you can learn a recipe and how long it gives"
        .. " skill-ups, on its item tooltip. Hold Shift for the skill-up bands.")
    Slider("span", "Skill-up span", 50, SPAN_MIN, SPAN_MAX, "Skill points from a recipe's"
        .. " required skill until it turns grey, for the skill-up estimate in tooltips and the"
        .. " skill-ups filter (" .. SLASH .. " span <n>). Yellow and green scale with it.")
    Settings.RegisterAddOnCategory(category)
end

local function OpenSettings()
    if category then
        Settings.OpenToCategory(category:GetID())
    else
        Print("the Settings panel isn't available in this client.")
    end
end

--------------------------------------------------
-- Init
--------------------------------------------------
local function Init()
    _G[SV_NAME] = _G[SV_NAME] or {}
    db = _G[SV_NAME]
    db.expanded = db.expanded or {}
    db.levelMode = db.levelMode or "any"
    db.nearSpan = db.nearSpan or 5
    db.span = db.span or 50
    if db.hidden then db.panel = false end
    db.hidden = nil
    db.panel = db.panel ~= false
    local ok, err = pcall(RegisterSettings)
    if not ok then geterrorhandler()(err) end
    api = TSMLocalShopping
    if not api then return end
    if TSMLocalAddItemFilter then
        TSMLocalAddItemFilter("learnable", PassesLearnable)
        TSMLocalAddItemFilter("skillup", PassesSkillup)
        api.hasWords = true
    end
    CreatePanel()
    tinsert(api.callbacks, OnShoppingShown)
end

local events = CreateFrame("Frame")
-- pcall: registering an event the client lacks throws and would abort the whole file
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED",
    "CHAT_MSG_SKILL", "NEW_RECIPE_LEARNED", "SPELLS_CHANGED", "MODIFIER_STATE_CHANGED",
    "AUCTION_HOUSE_SHOW" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, key)
    if event == "PLAYER_LOGIN" then
        Init()
    elseif event == "AUCTION_HOUSE_SHOW" then
        WarnPatchOnce()
    elseif event == "MODIFIER_STATE_CHANGED" then
        if not key:find("SHIFT") or not GameTooltip:IsShown() then return end
        local owner = GameTooltip:GetOwner()
        if owner and owner.tsmbTip and owner:IsMouseOver() then
            ShowTip(owner)
        else
            RedrawRecipeTooltip()
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- UnitLevel lags the event by a moment
        if panel and panel:IsShown() then C_Timer.After(1, RefreshLevel) end
    else
        ranks = nil
        wipe(recipeInfo)
        if panel and panel:IsShown() then RefreshTree() end
    end
end)

--------------------------------------------------
-- Slash commands
--------------------------------------------------
local function PanelState()
    local state = PatchState()
    if state == "notsm" then return "off, TSM isn't loaded" end
    if state == "missing" then return "off, TSM isn't patched" end
    return db.panel and "on" or "off"
end

local function PrintHelp()
    Print("a category tree beside TSM's Browse tab, recipe help in item tooltips")
    local lines = {
        Cmd("on||off") .. " - show the category panel (now " .. PanelState() .. ")",
        Cmd("near <n>") .. " - Near me range: start n levels below yours (now "
            .. db.nearSpan .. ")",
        Cmd("span <n>") .. " - skill-up span: skill points from a recipe's required skill"
            .. " to grey (now " .. db.span .. ")",
        Cmd("settings") .. " - open the Settings panel",
        Cmd("help") .. " - this list",
        "Settings: Esc > Options > AddOns > " .. NAME .. " (" .. Cmd("settings") .. ")",
    }
    for _, line in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end
end

local function SetPanel(on)
    ShowPanel(on)
    if on and not panel then
        Print(PatchMessage())
    else
        Print("category panel " .. OnOff(on))
    end
end

local function SetNumber(key, arg, min, max, say)
    local n = tonumber(arg)
    if n then db[key] = math.max(min, math.min(max, math.floor(n))) end
    if arg and not n then
        Print(format('"%s" isn\'t a number. %s', arg, say()))
    else
        Print(say())
    end
end

_G["SLASH_" .. NAME:upper() .. "1"] = SLASH
SlashCmdList[NAME:upper()] = function(msg)
    local cmd, arg = strsplit(" ", strlower(strtrim(msg or "")), 2)
    if cmd == "on" or cmd == "off" then
        SetPanel(cmd == "on")
    elseif cmd == "near" then
        SetNumber("nearSpan", arg, 0, NEAR_MAX, function()
            return format("Near me range: %d levels below yours (%s)", db.nearSpan,
                Cmd("near <n>"))
        end)
        if panel and panel:IsShown() then RefreshLevel() end
    elseif cmd == "span" then
        SetNumber("span", arg, SPAN_MIN, SPAN_MAX, function()
            local yellow, green, grey = Bands(0)
            return format("Skill-up span: yellow +%d, green +%d, grey +%d over the required"
                .. " skill (%s)", yellow, green, grey, Cmd("span <n>"))
        end)
    elseif cmd == "settings" or cmd == "options" then
        OpenSettings()
    elseif cmd == "" or cmd == "help" or cmd == "?" then
        PrintHelp()
    else
        Print(format('unknown command "%s"', cmd))
        PrintHelp()
    end
end

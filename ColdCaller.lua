local ADDON_NAME = ...

--=========================================================================
-- Cold Caller
-- Select classes + a level range + a message, run /who queries to find
-- players, then click to whisper each one. Tracks who you've messaged and
-- persists everything between sessions.
--=========================================================================

--------------------------------------------------------------------------
-- Runtime state
--------------------------------------------------------------------------
local CLASSES = {}          -- array of { token = "MAGE", name = "Mage" }
local nameToToken = {}      -- localized class name -> token (fallback lookup)

local results = {}          -- array of { name, level, classToken, class, zone }
local resultsByName = {}    -- set for de-duplication
local filtered = {}         -- results after the "hide messaged" filter

local whoQueue = {}         -- pending /who filter strings
local whoPending = false    -- waiting on a WHO_LIST_UPDATE for the last query
local lastWhoSent = 0
local refreshing = false
local refreshGen = 0        -- bumped each StartRefresh so stale callbacks from an
                             -- interrupted search can recognize they're obsolete
local pendingGen = 0        -- generation the in-flight query belongs to

local WHO_INTERVAL = 5.0    -- seconds between /who queries (client throttles these)
local WHO_TIMEOUT  = 8.0    -- give up on a query if no response arrives

local ROW_HEIGHT = 26
local NUM_ROWS   = 10

local UI = {}               -- frame references

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------
local function MaxLevel()
    -- Classic Era / Hardcore is capped at 60
    return 60
end

-- Classic (Vanilla) classes
local CLASSIC_CLASS_TOKENS = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

local function BuildClasses()
    wipe(CLASSES)
    wipe(nameToToken)
    local L = LOCALIZED_CLASS_NAMES_MALE or {}
    for _, token in ipairs(CLASSIC_CLASS_TOKENS) do
        local name = L[token] or token
        CLASSES[#CLASSES + 1] = { token = token, name = name }
        nameToToken[name] = token
    end
end

local function InitDB()
    ColdCallerDB = ColdCallerDB or {}
    local db = ColdCallerDB
    if db.classes  == nil then db.classes  = {} end
    if db.minLevel == nil then db.minLevel = 1 end
    if db.maxLevel == nil then db.maxLevel = MaxLevel() end
    if db.message  == nil then db.message  = "Hi! Putting together a group for a dungeon run -- interested?" end
    if db.hideMessaged == nil then db.hideMessaged = false end

    ColdCallerCharDB = ColdCallerCharDB or {}
    local cdb = ColdCallerCharDB
    if cdb.messaged == nil then cdb.messaged = {} end
    if cdb.results  == nil then cdb.results  = {} end

    -- restore last results into runtime tables
    wipe(results); wipe(resultsByName)
    for _, e in ipairs(cdb.results) do
        results[#results + 1] = e
        if e.name then resultsByName[e.name] = true end
    end
end

--------------------------------------------------------------------------
-- /who querying
--------------------------------------------------------------------------
local function BuildFilter(className, minL, maxL)
    local parts = {}
    if minL and maxL then
        parts[#parts + 1] = minL .. "-" .. maxL
    end
    if className then
        parts[#parts + 1] = 'c-"' .. className .. '"'
    end
    return table.concat(parts, " ")
end

local function DoSendWho(filter)
    -- route results to the internal list so GetWhoInfo() is populated
    if C_FriendList and C_FriendList.SetWhoToUI then
        C_FriendList.SetWhoToUI(true)
    end

    -- /who silently refuses to submit unless it's driven by a real click/key
    -- event -- calling C_FriendList.SendWho (or even firing the Who edit
    -- box's OnEnterPressed) from a timer callback sets the UI text but never
    -- actually queries the server. So DoSendWho must only ever be called
    -- synchronously from an OnClick handler; drive the Who window's own edit
    -- box the same way a player typing in it and hitting Enter would.
    local editBox = _G["WhoFrameEditBox"]
    local onEnterPressed = editBox and editBox:GetScript("OnEnterPressed")
    if editBox and onEnterPressed then
        editBox:SetFocus()
        editBox:SetText(filter)
        onEnterPressed(editBox)
    elseif SlashCmdList and SlashCmdList["WHO"] then
        SlashCmdList["WHO"](filter)
    elseif C_FriendList and C_FriendList.SendWho then
        if Enum and Enum.SocialWhoOrigin then
            C_FriendList.SendWho(filter, Enum.SocialWhoOrigin.Chat)
        else
            C_FriendList.SendWho(filter)
        end
    end
end

local function CollectWhoResults()
    if not (C_FriendList and C_FriendList.GetNumWhoResults) then return end
    local n = C_FriendList.GetNumWhoResults()
    local myName = UnitName("player")
    for i = 1, n do
        local info = C_FriendList.GetWhoInfo(i)
        if info and info.fullName then
            local key = info.fullName
            local bareName = strsplit("-", key)
            if bareName ~= myName and not resultsByName[key] then
                resultsByName[key] = true
                local classLocalized = info.classStr or info.className
                local token = info.filename or (classLocalized and nameToToken[classLocalized])
                results[#results + 1] = {
                    name       = key,
                    level      = info.level,
                    class      = classLocalized or token or "",
                    classToken = token,
                    zone       = info.area,
                }
            end
        end
    end
end

-- forward declaration
local UpdateResultsDisplay

-- Keeps the button disabled with a countdown for the remainder of
-- WHO_INTERVAL after a search finishes, instead of re-enabling it right
-- away. Clicking Refresh again before that real throttle window has passed
-- can't actually search (see TrySend) -- it would just start a wait and
-- force a second click once ready. Arming it here means whenever the button
-- *is* clickable, one click reliably fires the search immediately.
local function ArmRefreshButton(gen)
    if gen ~= refreshGen or refreshing then return end
    local remaining = WHO_INTERVAL - (GetTime() - lastWhoSent)
    if remaining <= 0 then
        if UI.refreshBtn then
            UI.refreshBtn:Enable()
            UI.refreshBtn:SetText("Refresh /who")
        end
    else
        if UI.refreshBtn then
            UI.refreshBtn:Disable()
            UI.refreshBtn:SetText(("Ready in %.0fs"):format(remaining))
        end
        C_Timer.After(0.5, function() ArmRefreshButton(gen) end)
    end
end

local function FinishRefresh()
    refreshing = false
    whoPending = false
    ColdCallerCharDB.results = results
    UpdateResultsDisplay()
    ArmRefreshButton(refreshGen)
    if UI.status then UI.status:SetText(("Done -- %d player(s) found."):format(#results)) end
end

-- forward declarations: AfterQueryComplete, UpdateContinueWait, SendNextQueued
-- and TrySend are mutually referential.
local AfterQueryComplete, UpdateContinueWait, SendNextQueued, TrySend

-- /who silently ignores any query not triggered by a real click/key event --
-- calling C_FriendList.SendWho (or even firing the Who window's own edit box
-- OnEnterPressed) from a C_Timer.After callback updates nothing and never
-- contacts the server. So instead of auto-chaining queries on a timer, we
-- wait out WHO_INTERVAL and then let the player click "Refresh /who" again
-- (repurposed as "Continue" while a search is running) -- SendNextQueued only
-- ever runs synchronously from that OnClick handler.
UpdateContinueWait = function(gen)
    if not refreshing or gen ~= refreshGen then return end
    local remaining = WHO_INTERVAL - (GetTime() - lastWhoSent)
    if remaining <= 0 then
        if UI.refreshBtn then
            UI.refreshBtn:Enable()
            UI.refreshBtn:SetText(("Continue (%d left)"):format(#whoQueue))
        end
        if UI.status then
            UI.status:SetText(("Ready -- click Continue (%d left)."):format(#whoQueue))
        end
    else
        if UI.refreshBtn then
            UI.refreshBtn:Disable()
            UI.refreshBtn:SetText(("Wait %.0fs..."):format(remaining))
        end
        if UI.status then
            UI.status:SetText(("Waiting %.0fs before next query (%d left)..."):format(remaining, #whoQueue))
        end
        C_Timer.After(0.5, function() UpdateContinueWait(gen) end)
    end
end

AfterQueryComplete = function()
    if not refreshing then return end
    if #whoQueue == 0 then
        FinishRefresh()
        return
    end
    UpdateContinueWait(refreshGen)
end

-- Gatekeeps every actual send behind two independent requirements: it must
-- come from a real click (guaranteed by only ever being called from
-- RefreshButtonClicked), AND at least WHO_INTERVAL must have really elapsed
-- since the last one -- Blizzard's server-side /who throttle still applies
-- even to a genuinely-clicked query, so re-clicking Refresh right after a
-- batch just finished can otherwise silently drop the first query of the new
-- batch exactly like an unthrottled timer resend would.
TrySend = function()
    if not refreshing then return end
    if whoPending then return end
    if #whoQueue == 0 then
        FinishRefresh()
        return
    end
    local remaining = WHO_INTERVAL - (GetTime() - lastWhoSent)
    if remaining > 0 then
        UpdateContinueWait(refreshGen)
        return
    end
    SendNextQueued()
end

SendNextQueued = function()
    if not refreshing then return end
    if whoPending then return end
    if #whoQueue == 0 then
        FinishRefresh()
        return
    end
    local filter = table.remove(whoQueue, 1)
    whoPending = true
    pendingGen = refreshGen
    lastWhoSent = GetTime()
    if UI.refreshBtn then
        UI.refreshBtn:Disable()
        UI.refreshBtn:SetText("Refresh /who")
    end
    if UI.status then
        UI.status:SetText(("Searching... (%d query(s) left)"):format(#whoQueue))
    end
    DoSendWho(filter)

    -- fallback in case WHO_LIST_UPDATE never fires for this query
    local stamp = lastWhoSent
    local gen = refreshGen
    C_Timer.After(WHO_TIMEOUT, function()
        if whoPending and lastWhoSent == stamp and refreshGen == gen then
            CollectWhoResults()
            whoPending = false
            UpdateResultsDisplay()
            AfterQueryComplete()
        end
    end)
end

-- Single button does double duty: starts a fresh search when idle, or -- once
-- WHO_INTERVAL has elapsed mid-search -- sends the next queued query. Reusing
-- it (rather than a second button) sidesteps needing new layout space, and it
-- can never be clicked while a query is actually in flight since it's
-- disabled for that whole window.
local StartRefresh -- forward declaration, used by RefreshButtonClicked below

local function RefreshButtonClicked()
    if refreshing then
        TrySend()
    else
        StartRefresh()
    end
end

StartRefresh = function()
    -- Starting a new search interrupts any in-progress one instead of being
    -- ignored. refreshGen invalidates callbacks (WHO_LIST_UPDATE, the
    -- WHO_TIMEOUT fallback) still in flight for the old search.
    refreshGen = refreshGen + 1
    whoPending = false

    -- pull the latest field values into the DB before searching
    UI.SaveInputs()

    wipe(results); wipe(resultsByName); wipe(whoQueue)

    local minL = ColdCallerDB.minLevel
    local maxL = ColdCallerDB.maxLevel

    local selected = {}
    for _, c in ipairs(CLASSES) do
        if ColdCallerDB.classes[c.token] then
            selected[#selected + 1] = c
        end
    end

    if #selected == 0 then
        -- no classes ticked: one query on the level range only
        whoQueue[#whoQueue + 1] = BuildFilter(nil, minL, maxL)
    else
        -- /who can't OR classes together, so we run one query per class
        for _, c in ipairs(selected) do
            whoQueue[#whoQueue + 1] = BuildFilter(c.name, minL, maxL)
        end
    end

    refreshing = true
    whoPending = false
    if UI.refreshBtn then UI.refreshBtn:Disable() end
    if UI.status then UI.status:SetText("Searching...") end
    TrySend() -- checks WHO_INTERVAL too: a click right after a prior batch
              -- finished can still be too soon for Blizzard's real throttle
end

--------------------------------------------------------------------------
-- Whispering
--------------------------------------------------------------------------
local function WhisperPlayer(entry)
    UI.SaveInputs()
    if not entry or not entry.name then return end
    local msg = ColdCallerDB.message
    if not msg or strtrim(msg) == "" then
        if UI.status then UI.status:SetText("Type a message first.") end
        return
    end
    SendChatMessage(msg, "WHISPER", nil, entry.name)
    ColdCallerCharDB.messaged[entry.name] = true
    UpdateResultsDisplay()
end

--------------------------------------------------------------------------
-- Results list rendering
--------------------------------------------------------------------------
UpdateResultsDisplay = function()
    if not UI.scroll then return end

    wipe(filtered)
    for _, e in ipairs(results) do
        if not (ColdCallerDB.hideMessaged and ColdCallerCharDB.messaged[e.name]) then
            filtered[#filtered + 1] = e
        end
    end

    local offset = FauxScrollFrame_GetOffset(UI.scroll)
    for i = 1, NUM_ROWS do
        local row = UI.rows[i]
        local e = filtered[i + offset]
        if e then
            row.entry = e
            local messaged = ColdCallerCharDB.messaged[e.name]
            local lvl = e.level or "?"
            local label
            if messaged then
                label = string.format("|cff707070[%s] %s|r", lvl, e.name)
            else
                local col = RAID_CLASS_COLORS[e.classToken]
                if col then
                    label = string.format("|cff%02x%02x%02x[%s] %s|r",
                        col.r * 255, col.g * 255, col.b * 255, lvl, e.name)
                else
                    label = string.format("[%s] %s", lvl, e.name)
                end
            end
            if e.zone and e.zone ~= "" then
                label = label .. "  |cff707070" .. e.zone .. "|r"
            end
            row.info:SetText(label)

            if messaged then
                row.whisper:SetText("Messaged")
                row.whisper:Disable()
            else
                row.whisper:SetText("Whisper")
                row.whisper:Enable()
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end

    FauxScrollFrame_Update(UI.scroll, #filtered, NUM_ROWS, ROW_HEIGHT)
end

--------------------------------------------------------------------------
-- Clear confirmation
--------------------------------------------------------------------------
StaticPopupDialogs["COLDCALLER_CLEAR"] = {
    text = "Cold Caller: clear the results list and forget everyone you've messaged on this character?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        wipe(results); wipe(resultsByName); wipe(filtered)
        wipe(ColdCallerCharDB.messaged)
        ColdCallerCharDB.results = {}
        UpdateResultsDisplay()
        if UI.status then UI.status:SetText("Cleared.") end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

--------------------------------------------------------------------------
-- UI construction
--------------------------------------------------------------------------
local function BuildUI()
    local f = CreateFrame("Frame", "ColdCallerFrame", UIParent, "BackdropTemplate")
    f:SetSize(440, 590)
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    -- position
    local p = ColdCallerDB.point
    if p then
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        f:SetPoint("CENTER")
    end

    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ColdCallerDB.point = { point, relPoint, x, y }
    end)
    f:Hide()
    tinsert(UISpecialFrames, "ColdCallerFrame") -- closes on Escape

    -- title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Cold Caller")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local left = 20
    local anchorY = -44

    -- class section label
    local classLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    classLbl:SetPoint("TOPLEFT", left, anchorY)
    classLbl:SetText("Classes (none ticked = all):")

    -- class checkboxes, 2 columns
    UI.classChecks = {}
    local gridTop = anchorY - 20
    local colWidth = 195
    for i, c in ipairs(CLASSES) do
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        local col = (i - 1) % 2
        local rowN = math.floor((i - 1) / 2)
        cb:SetPoint("TOPLEFT", left + col * colWidth, gridTop - rowN * 25)

        local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        lbl:SetText(c.name)
        local col2 = RAID_CLASS_COLORS[c.token]
        if col2 then lbl:SetTextColor(col2.r, col2.g, col2.b) end

        cb:SetChecked(ColdCallerDB.classes[c.token] and true or false)
        cb:SetScript("OnClick", function(self)
            ColdCallerDB.classes[c.token] = self:GetChecked() and true or false
        end)
        UI.classChecks[c.token] = cb
    end

    local numRowsClasses = math.ceil(#CLASSES / 2)
    local afterClassesY = gridTop - numRowsClasses * 25 - 10

    -- level range
    local lvlLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lvlLbl:SetPoint("TOPLEFT", left, afterClassesY)
    lvlLbl:SetText("Levels")

    local function MakeNumberBox()
        local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        eb:SetSize(44, 20)
        eb:SetAutoFocus(false)
        eb:SetNumeric(true)
        eb:SetMaxLetters(3)
        eb:SetScript("OnEnterPressed", eb.ClearFocus)
        eb:SetScript("OnEscapePressed", eb.ClearFocus)
        return eb
    end

    UI.minBox = MakeNumberBox()
    UI.minBox:SetPoint("LEFT", lvlLbl, "RIGHT", 12, 0)
    UI.minBox:SetText(tostring(ColdCallerDB.minLevel))

    local toLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toLbl:SetPoint("LEFT", UI.minBox, "RIGHT", 8, 0)
    toLbl:SetText("to")

    UI.maxBox = MakeNumberBox()
    UI.maxBox:SetPoint("LEFT", toLbl, "RIGHT", 8, 0)
    UI.maxBox:SetText(tostring(ColdCallerDB.maxLevel))

    -- message
    local msgLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    msgLbl:SetPoint("TOPLEFT", left, afterClassesY - 34)
    msgLbl:SetText("Whisper message:")

    UI.msgBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    UI.msgBox:SetSize(400, 22)
    UI.msgBox:SetPoint("TOPLEFT", left + 4, afterClassesY - 52)
    UI.msgBox:SetAutoFocus(false)
    UI.msgBox:SetMaxLetters(255)
    UI.msgBox:SetText(ColdCallerDB.message or "")
    UI.msgBox:SetScript("OnEnterPressed", UI.msgBox.ClearFocus)
    UI.msgBox:SetScript("OnEscapePressed", UI.msgBox.ClearFocus)

    -- Save-inputs helper (used before searching and on hide)
    UI.SaveInputs = function()
        local mn = tonumber(UI.minBox:GetText()) or 1
        local mx = tonumber(UI.maxBox:GetText()) or MaxLevel()
        if mn < 1 then mn = 1 end
        if mx < mn then mx = mn end
        ColdCallerDB.minLevel = mn
        ColdCallerDB.maxLevel = mx
        ColdCallerDB.message  = UI.msgBox:GetText() or ""
    end

    -- buttons
    UI.refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    UI.refreshBtn:SetSize(120, 24)
    UI.refreshBtn:SetPoint("TOPLEFT", left, afterClassesY - 84)
    UI.refreshBtn:SetText("Refresh /who")
    UI.refreshBtn:SetScript("OnClick", RefreshButtonClicked)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(90, 24)
    clearBtn:SetPoint("LEFT", UI.refreshBtn, "RIGHT", 8, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("COLDCALLER_CLEAR")
    end)

    local hideCb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    hideCb:SetSize(22, 22)
    hideCb:SetPoint("LEFT", clearBtn, "RIGHT", 12, 0)
    local hideLbl = hideCb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hideLbl:SetPoint("LEFT", hideCb, "RIGHT", 2, 0)
    hideLbl:SetText("Hide messaged")
    hideCb:SetChecked(ColdCallerDB.hideMessaged and true or false)
    hideCb:SetScript("OnClick", function(self)
        ColdCallerDB.hideMessaged = self:GetChecked() and true or false
        UpdateResultsDisplay()
    end)

    -- results scroll frame
    local listTop = afterClassesY - 118
    local scroll = CreateFrame("ScrollFrame", "ColdCallerScroll", f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", left, listTop)
    scroll:SetSize(384, NUM_ROWS * ROW_HEIGHT)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateResultsDisplay)
    end)
    UI.scroll = scroll

    -- a subtle backing so the list area reads as a panel
    local listBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -4, 4)
    listBg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 26, -4)
    listBg:SetFrameLevel(scroll:GetFrameLevel() - 1)
    listBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBg:SetBackdropColor(0, 0, 0, 0.35)
    listBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    UI.rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(378, ROW_HEIGHT)
        if i == 1 then
            row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 2, 0)
        else
            row:SetPoint("TOPLEFT", UI.rows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local info = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        info:SetPoint("LEFT", row, "LEFT", 4, 0)
        info:SetPoint("RIGHT", row, "RIGHT", -86, 0)
        info:SetJustifyH("LEFT")
        info:SetWordWrap(false)
        row.info = info

        local wb = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        wb:SetSize(78, ROW_HEIGHT - 4)
        wb:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        wb:SetText("Whisper")
        wb:SetScript("OnClick", function()
            if row.entry then WhisperPlayer(row.entry) end
        end)
        row.whisper = wb

        row:Hide()
        UI.rows[i] = row
    end

    -- status line
    UI.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    UI.status:SetPoint("BOTTOMLEFT", left, 18)
    UI.status:SetPoint("BOTTOMRIGHT", -20, 18)
    UI.status:SetJustifyH("LEFT")
    UI.status:SetText("Pick classes + levels, set a message, then Refresh /who.")

    -- persist field edits when the window is closed
    f:SetScript("OnHide", function()
        if UI.SaveInputs then UI.SaveInputs() end
    end)

    UpdateResultsDisplay()
end

--------------------------------------------------------------------------
-- Events & slash command
--------------------------------------------------------------------------
local driver = CreateFrame("Frame")
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("WHO_LIST_UPDATE")
driver:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        BuildClasses()
        BuildUI()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "WHO_LIST_UPDATE" then
        if refreshing and whoPending and pendingGen == refreshGen then
            CollectWhoResults()
            whoPending = false
            UpdateResultsDisplay()
            AfterQueryComplete()
        end
    end
end)

SLASH_COLDCALLER1 = "/coldcall"
SLASH_COLDCALLER2 = "/coldcaller"
SLASH_COLDCALLER3 = "/cc"
SlashCmdList["COLDCALLER"] = function()
    local f = _G["ColdCallerFrame"]
    if not f then return end
    if f:IsShown() then f:Hide() else f:Show() end
end

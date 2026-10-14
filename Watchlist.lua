local _, addon = ...
local L = addon.L

local frame
local groupRows = {}
local itemRows = {}
local GROUP_ROW_HEIGHT = 28
local ITEM_ROW_HEIGHT = 44
local PANEL_WIDTH = 330
local LIST_TOP = 70
local LIST_BOTTOM = 58
local whisperFrame
local autoRulesFrame

local TAB_MPLUS = "mythicplus"
local TAB_RAID = "raid"

local function GetJournalInstanceMeta(journalInstanceID)
    if not journalInstanceID or type(EJ_GetInstanceInfo) ~= "function" then return nil, nil end
    local ok, name, _, _, _, _, _, _, _, _, _, _, isRaid = pcall(EJ_GetInstanceInfo, journalInstanceID)
    if not ok then return nil, nil end
    return name, isRaid
end

local function EnsureUIState()
    if not addon.db then return end
    addon.db.watchUI = addon.db.watchUI or {}
    if addon.db.watchUI.activeTab ~= TAB_RAID and addon.db.watchUI.activeTab ~= TAB_MPLUS then
        addon.db.watchUI.activeTab = TAB_MPLUS
    end
    addon.db.watchUI.collapsed = addon.db.watchUI.collapsed or {}
    addon.db.watchUI.collapsed[TAB_MPLUS] = addon.db.watchUI.collapsed[TAB_MPLUS] or {}
    addon.db.watchUI.collapsed[TAB_RAID] = addon.db.watchUI.collapsed[TAB_RAID] or {}
end

local function ResolveEntryIsRaid(entry)
    if not entry then return false end
    if type(entry.isRaid) == "boolean" then return entry.isRaid end

    if entry.journalInstanceID then
        local instanceName, isRaid = GetJournalInstanceMeta(entry.journalInstanceID)
        if instanceName and (not entry.instanceName or entry.instanceName == "") then
            entry.instanceName = instanceName
        end
        if type(isRaid) == "boolean" then
            -- Backfill older watch entries once. This becomes part of the
            -- SavedVariables table, so later refreshes do not need another API call.
            entry.isRaid = isRaid
            return isRaid
        end
    end

    return false
end

local function GetEquipmentSlotLabel(entry)
    if not entry then return nil end

    local slot = entry.slot
    if type(slot) == "string" and slot ~= "" then
        local localized = _G[slot]
        if type(localized) == "string" and localized ~= "" then
            return localized
        end
        return slot
    end

    if C_Item and C_Item.GetItemInfoInstant and entry.itemID then
        local _, _, _, equipLoc = C_Item.GetItemInfoInstant(entry.itemID)
        if type(equipLoc) == "string" and equipLoc ~= "" then
            local localized = _G[equipLoc]
            if type(localized) == "string" and localized ~= "" then
                return localized
            end
            return equipLoc
        end
    end

    return nil
end

local function SortItems(items)
    table.sort(items, function(a, b)
        if (a.minTrack or 0) ~= (b.minTrack or 0) then
            return (a.minTrack or 0) > (b.minTrack or 0)
        end
        return (a.itemName or "") < (b.itemName or "")
    end)
end

local function BuildGroups(tab)
    local byName = {}
    local total = 0
    if not addon.db or not addon.db.watchlist then return {}, 0 end

    for _, entry in pairs(addon.db.watchlist) do
        local isRaid = ResolveEntryIsRaid(entry)
        local belongs = (tab == TAB_RAID and isRaid) or (tab == TAB_MPLUS and not isRaid)
        if belongs then
            total = total + 1
            local groupName
            if tab == TAB_RAID then
                groupName = entry.encounterName
                if type(groupName) ~= "string" or groupName == "" then
                    groupName = L.UNKNOWN_BOSS
                end
            else
                groupName = entry.instanceName
                if type(groupName) ~= "string" or groupName == "" then
                    groupName = L.UNKNOWN_DUNGEON
                end
            end

            -- Group by the displayed localized name. This guarantees that a
            -- dungeon/Boss heading is rendered only once even with many items.
            local key = groupName
            local group = byName[key]
            if not group then
                group = { key = key, name = groupName, items = {} }
                byName[key] = group
            end
            group.items[#group.items + 1] = entry
        end
    end

    local groups = {}
    for _, group in pairs(byName) do
        SortItems(group.items)
        groups[#groups + 1] = group
    end
    table.sort(groups, function(a, b) return a.name < b.name end)
    return groups, total
end

local function GetTabCounts()
    local mplus, raid = 0, 0
    if addon.db and addon.db.watchlist then
        for _, entry in pairs(addon.db.watchlist) do
            if ResolveEntryIsRaid(entry) then raid = raid + 1 else mplus = mplus + 1 end
        end
    end
    return mplus, raid
end

local function ShowEntryMenu(owner, entry)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
        rootDescription:SetTag("MENU_QFX_BEGGAR_WATCHLIST")
        rootDescription:CreateTitle(L.CHANGE_TRACK)
        local tracks = {
            { addon.TRACK.MYTH, L.TRACK_MYTH },
            { addon.TRACK.HERO, L.TRACK_HERO },
            { addon.TRACK.CHAMPION, L.TRACK_CHAMPION },
            { addon.TRACK.VETERAN, L.TRACK_VETERAN },
            { addon.TRACK.ADVENTURER, L.TRACK_ADVENTURER },
            { addon.TRACK.ANY, L.TRACK_ANY },
        }
        for _, data in ipairs(tracks) do
            local rank, label = data[1], data[2]
            rootDescription:CreateRadio(label,
                function()
                    local current = addon:GetWatch(entry.itemID)
                    return current and current.minTrack == rank
                end,
                function()
                    addon:SetWatch(entry.itemID, entry.itemLink, rank, entry)
                end)
        end
        rootDescription:CreateDivider()
        rootDescription:CreateButton(L.REMOVE, function() addon:RemoveWatch(entry.itemID) end)
    end)
end

local function CreateGroupRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(GROUP_ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")

    row.Bg = row:CreateTexture(nil, "BACKGROUND")
    row.Bg:SetAllPoints()
    row.Bg:SetColorTexture(0.12, 0.10, 0.04, 0.72)

    row.Arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.Arrow:SetPoint("LEFT", 7, 0)
    row.Arrow:SetTextColor(1, 0.82, 0)

    row.Title = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.Title:SetPoint("LEFT", row.Arrow, "RIGHT", 5, 0)
    row.Title:SetPoint("RIGHT", -42, 0)
    row.Title:SetJustifyH("LEFT")
    row.Title:SetWordWrap(false)
    row.Title:SetTextColor(1, 0.82, 0)

    row.Count = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.Count:SetPoint("RIGHT", -8, 0)
    row.Count:SetJustifyH("RIGHT")
    row.Count:SetTextColor(0.20, 1.00, 0.40)

    row:SetScript("OnEnter", function(self)
        self.Bg:SetColorTexture(0.18, 0.15, 0.05, 0.82)
    end)
    row:SetScript("OnLeave", function(self)
        self.Bg:SetColorTexture(0.12, 0.10, 0.04, 0.72)
    end)
    row:SetScript("OnClick", function(self)
        if not self.groupKey or not addon.db then return end
        EnsureUIState()
        local tab = addon.db.watchUI.activeTab
        local collapsed = addon.db.watchUI.collapsed[tab]
        collapsed[self.groupKey] = not collapsed[self.groupKey]
        addon:RefreshWatchlistUI()
    end)

    return row
end

local function CreateItemRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ITEM_ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.Bg = row:CreateTexture(nil, "BACKGROUND")
    row.Bg:SetAllPoints()
    row.Bg:SetColorTexture(1, 1, 1, 0.035)

    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(34, 34)
    row.Icon:SetPoint("LEFT", 10, 0)

    row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Name:SetPoint("TOPLEFT", row.Icon, "TOPRIGHT", 6, -2)
    row.Name:SetPoint("RIGHT", row, "RIGHT", -32, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    do
        local font, size, flags = row.Name:GetFont()
        if font and size then row.Name:SetFont(font, math.max(8, size - 3), flags) end
    end

    row.Track = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.Track:SetPoint("BOTTOMLEFT", row.Name, "BOTTOMLEFT", 0, -15)
    row.Track:SetPoint("RIGHT", row, "RIGHT", -32, 0)
    row.Track:SetJustifyH("LEFT")
    row.Track:SetWordWrap(false)
    do
        local font, size, flags = row.Track:GetFont()
        if font and size then row.Track:SetFont(font, math.max(8, size - 2), flags) end
    end

    row.Remove = CreateFrame("Button", nil, row)
    row.Remove:SetSize(18, 18)
    row.Remove:SetPoint("RIGHT", -4, 0)
    row.Remove:SetFrameLevel((row:GetFrameLevel() or 1) + 4)
    row.Remove.Text = row.Remove:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.Remove.Text:SetPoint("CENTER")
    row.Remove.Text:SetText("×")
    row.Remove.Text:SetTextColor(0.9, 0.25, 0.25)
    row.Remove:SetScript("OnEnter", function(self)
        self.Text:SetTextColor(1, 0.45, 0.45)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.REMOVE)
        GameTooltip:Show()
    end)
    row.Remove:SetScript("OnLeave", function(self)
        self.Text:SetTextColor(0.9, 0.25, 0.25)
        GameTooltip:Hide()
    end)
    row.Remove:SetScript("OnClick", function(self)
        local parentRow = self:GetParent()
        if parentRow.entry then addon:RemoveWatch(parentRow.entry.itemID) end
    end)

    row:SetScript("OnClick", function(self)
        if self.entry then ShowEntryMenu(self, self.entry) end
    end)
    row:SetScript("OnEnter", function(self)
        self.Bg:SetColorTexture(1, 1, 1, 0.075)
        if self.entry and self.entry.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.entry.itemLink)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L.MIN_TRACK .. ": " .. addon:GetWatchRequirementLabel(self.entry.minTrack), 1, 0.82, 0)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.Bg:SetColorTexture(1, 1, 1, 0.035)
        GameTooltip:Hide()
    end)

    return row
end

local function AcquireGroupRow(index)
    if not groupRows[index] then groupRows[index] = CreateGroupRow(frame.ListContent) end
    return groupRows[index]
end

local function AcquireItemRow(index)
    if not itemRows[index] then itemRows[index] = CreateItemRow(frame.ListContent) end
    return itemRows[index]
end

local function HideUnusedRows(groupUsed, itemUsed)
    for i = groupUsed + 1, #groupRows do groupRows[i]:Hide() end
    for i = itemUsed + 1, #itemRows do
        itemRows[i].entry = nil
        itemRows[i]:Hide()
    end
end

local function UpdateTabVisuals(mplusCount, raidCount)
    if not frame then return end
    local active = addon.db.watchUI.activeTab
    frame.MPlusTab:SetText(string.format("%s (%d)", L.TAB_MYTHIC_PLUS, mplusCount))
    frame.RaidTab:SetText(string.format("%s (%d)", L.TAB_RAID, raidCount))

    local function StyleTab(button, selected)
        if selected then
            button:LockHighlight()
            local fs = button:GetFontString()
            if fs then fs:SetTextColor(1, 0.82, 0) end
        else
            button:UnlockHighlight()
            local fs = button:GetFontString()
            if fs then fs:SetTextColor(1, 1, 1) end
        end
    end
    StyleTab(frame.MPlusTab, active == TAB_MPLUS)
    StyleTab(frame.RaidTab, active == TAB_RAID)
end

local function ClampScroll()
    if not frame or not frame.ListScroll then return end
    local range = frame.ListScroll:GetVerticalScrollRange() or 0
    local current = frame.ListScroll:GetVerticalScroll() or 0
    if current > range then frame.ListScroll:SetVerticalScroll(range) end
    if current < 0 then frame.ListScroll:SetVerticalScroll(0) end
    frame.ScrollHint:SetShown(range > 1)
end

function addon:RefreshWatchlistUI()
    if not frame or not self.db then return end
    EnsureUIState()

    local mplusCount, raidCount = GetTabCounts()
    local total = mplusCount + raidCount
    frame.Title:SetText(string.format("%s  |cff33ff66★%d|r", L.WATCHLIST, total))
    frame.Status:SetText(L.BEGGING_RULES)
    frame.Status:SetTextColor(1.00, 0.82, 0.00)
    UpdateTabVisuals(mplusCount, raidCount)

    local activeTab = self.db.watchUI.activeTab
    local groups, activeCount = BuildGroups(activeTab)
    local collapsed = self.db.watchUI.collapsed[activeTab]

    frame.Empty:SetShown(activeCount == 0)
    frame.Empty:SetText(activeTab == TAB_RAID and L.EMPTY_RAID or L.EMPTY_MYTHIC_PLUS)
    if frame.Watermark then
        frame.Watermark:SetAlpha(activeCount == 0 and 0.72 or 0.55)
    end

    local y = 0
    local groupUsed, itemUsed = 0, 0

    for _, group in ipairs(groups) do
        groupUsed = groupUsed + 1
        local header = AcquireGroupRow(groupUsed)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.ListContent, "TOPLEFT", 0, -y)
        header:SetPoint("TOPRIGHT", frame.ListContent, "TOPRIGHT", 0, -y)
        header.groupKey = group.key
        local isCollapsed = collapsed[group.key] == true
        header.Arrow:SetText(isCollapsed and "+" or "-")
        header.Title:SetText(group.name)
        header.Count:SetText("(" .. #group.items .. ")")
        header:Show()
        y = y + GROUP_ROW_HEIGHT

        if not isCollapsed then
            for _, entry in ipairs(group.items) do
                itemUsed = itemUsed + 1
                local row = AcquireItemRow(itemUsed)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", frame.ListContent, "TOPLEFT", 0, -y)
                row:SetPoint("TOPRIGHT", frame.ListContent, "TOPRIGHT", 0, -y)
                row.entry = entry

                local name, _, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(entry.itemID)
                row.Icon:SetTexture(icon or entry.itemIcon or 134400)
                local displayName = name or entry.itemName or ("item:" .. entry.itemID)
                local slotLabel = GetEquipmentSlotLabel(entry)
                if slotLabel and slotLabel ~= "" then
                    displayName = displayName .. "  |cffb8b8b8[" .. slotLabel .. "]|r"
                end
                row.Name:SetText(displayName)
                if quality then
                    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
                    if color then row.Name:SetTextColor(color.r, color.g, color.b) else row.Name:SetTextColor(1, 1, 1) end
                else
                    row.Name:SetTextColor(1, 1, 1)
                end
                row.Track:SetText(L.WATCH_TRACK .. ": |cffffd100" .. self:GetWatchRequirementLabel(entry.minTrack) .. "|r")
                row:Show()
                y = y + ITEM_ROW_HEIGHT
            end
        end
    end

    HideUnusedRows(groupUsed, itemUsed)

    local viewportHeight = frame.ListScroll:GetHeight() or 1
    frame.ListContent:SetHeight(math.max(viewportHeight, y))
    frame.ListContent:SetWidth(math.max(1, frame.ListScroll:GetWidth() or (PANEL_WIDTH - 12)))
    ClampScroll()
end

function addon:InitWatchlistUI()
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
        self:CreateJournalWatchPanel()
    end
end

local function UpdateEditorHeight(editBox, scrollFrame)
    if not editBox or not scrollFrame then return end
    local minHeight = math.max(1, scrollFrame:GetHeight() or 1)
    local textHeight = 0
    if editBox.GetStringHeight then textHeight = editBox:GetStringHeight() or 0 end
    editBox:SetHeight(math.max(minHeight, textHeight + 14))
    if scrollFrame.UpdateScrollChildRect then scrollFrame:UpdateScrollChildRect() end
end

local function GetDefaultWhisperForMode(mode)
    return mode == TAB_RAID and L.WHISPER_TEMPLATE_RAID or L.WHISPER_TEMPLATE_MPLUS
end

local function StoreWhisperDraft(f)
    if not f or not f.activeMode or not f.EditBox then return end
    f.drafts = f.drafts or {}
    f.drafts[f.activeMode] = f.EditBox:GetText() or ""
end

local function LoadWhisperMode(f, mode, saveCurrent)
    if not f then return end
    mode = mode == TAB_RAID and TAB_RAID or TAB_MPLUS
    if saveCurrent then StoreWhisperDraft(f) end

    f.activeMode = mode
    local isRaid = mode == TAB_RAID
    if f.MPlusTab then f.MPlusTab:SetEnabled(isRaid) end
    if f.RaidTab then f.RaidTab:SetEnabled(not isRaid) end
    if f.ContentLabel then
        f.ContentLabel:SetText(string.format("%s - %s", L.WHISPER_CONTENT, isRaid and L.TAB_RAID or L.TAB_MYTHIC_PLUS))
    end

    local text = f.drafts and f.drafts[mode] or nil
    if type(text) ~= "string" or text == "" then
        text = GetDefaultWhisperForMode(mode)
    end
    f.EditBox:SetText(text)
    f.EditBox:SetCursorPosition(#text)
    UpdateEditorHeight(f.EditBox, f.ScrollFrame)
    if f:IsShown() then
        f.EditBox:SetFocus()
    end
end

local function CreateWhisperEditor()
    if whisperFrame then return whisperFrame end

    whisperFrame = CreateFrame("Frame", "QFXBeggarWhisperEditor", EncounterJournal or UIParent, "BackdropTemplate")
    whisperFrame:SetSize(PANEL_WIDTH, 252)
    whisperFrame:SetFrameStrata("DIALOG")
    whisperFrame:SetClampedToScreen(true)
    whisperFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    whisperFrame:SetBackdropColor(0.045, 0.045, 0.045, 0.98)
    whisperFrame:Hide()
    whisperFrame.drafts = {}
    whisperFrame.activeMode = TAB_MPLUS

    whisperFrame.Title = whisperFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    whisperFrame.Title:SetPoint("TOPLEFT", 12, -10)
    whisperFrame.Title:SetText(L.WHISPER_SETTINGS)

    whisperFrame.MPlusTab = CreateFrame("Button", nil, whisperFrame, "UIPanelButtonTemplate")
    whisperFrame.MPlusTab:SetSize(145, 22)
    whisperFrame.MPlusTab:SetPoint("TOPLEFT", 10, -31)
    whisperFrame.MPlusTab:SetText(L.TAB_MYTHIC_PLUS)
    whisperFrame.MPlusTab:SetScript("OnClick", function()
        LoadWhisperMode(whisperFrame, TAB_MPLUS, true)
    end)

    whisperFrame.RaidTab = CreateFrame("Button", nil, whisperFrame, "UIPanelButtonTemplate")
    whisperFrame.RaidTab:SetSize(145, 22)
    whisperFrame.RaidTab:SetPoint("TOPRIGHT", -10, -31)
    whisperFrame.RaidTab:SetText(L.TAB_RAID)
    whisperFrame.RaidTab:SetScript("OnClick", function()
        LoadWhisperMode(whisperFrame, TAB_RAID, true)
    end)

    whisperFrame.Help = whisperFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    whisperFrame.Help:SetPoint("TOPLEFT", 12, -61)
    whisperFrame.Help:SetPoint("TOPRIGHT", -12, -61)
    whisperFrame.Help:SetJustifyH("LEFT")
    whisperFrame.Help:SetWordWrap(true)
    local helpFont, helpSize, helpFlags = whisperFrame.Help:GetFont()
    if helpFont and helpSize then whisperFrame.Help:SetFont(helpFont, math.max(8, helpSize - 2), helpFlags) end
    whisperFrame.Help:SetTextColor(0.35, 1.0, 0.35)
    whisperFrame.Help:SetText(L.WHISPER_TOKENS_HELP)

    whisperFrame.ContentLabel = whisperFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    whisperFrame.ContentLabel:SetPoint("TOPLEFT", 12, -94)
    whisperFrame.ContentLabel:SetTextColor(1.00, 0.82, 0.00)

    whisperFrame.EditBorder = CreateFrame("Frame", nil, whisperFrame, "BackdropTemplate")
    whisperFrame.EditBorder:SetPoint("TOPLEFT", 11, -115)
    whisperFrame.EditBorder:SetPoint("BOTTOMRIGHT", -11, 42)
    whisperFrame.EditBorder:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    whisperFrame.EditBorder:SetBackdropColor(0, 0, 0, 0.72)
    whisperFrame.EditBorder:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.85)

    whisperFrame.ScrollFrame = CreateFrame("ScrollFrame", nil, whisperFrame.EditBorder, "UIPanelScrollFrameTemplate")
    whisperFrame.ScrollFrame:SetPoint("TOPLEFT", 7, -6)
    whisperFrame.ScrollFrame:SetPoint("BOTTOMRIGHT", -26, 6)

    whisperFrame.EditBox = CreateFrame("EditBox", nil, whisperFrame.ScrollFrame)
    whisperFrame.EditBox:SetMultiLine(true)
    whisperFrame.EditBox:SetAutoFocus(false)
    whisperFrame.EditBox:EnableMouse(true)
    if whisperFrame.EditBox.EnableKeyboard then
        whisperFrame.EditBox:EnableKeyboard(true)
    end
    whisperFrame.EditBox:SetFontObject("ChatFontNormal")
    whisperFrame.EditBox:SetTextColor(1, 1, 1)
    whisperFrame.EditBox:SetJustifyH("LEFT")
    whisperFrame.EditBox:SetJustifyV("TOP")
    whisperFrame.EditBox:SetMaxLetters(300)
    whisperFrame.EditBox:SetWidth(whisperFrame.ScrollFrame:GetWidth() or 260)
    whisperFrame.EditBox:SetHeight(70)
    whisperFrame.ScrollFrame:SetScrollChild(whisperFrame.EditBox)

    local function FocusWhisperEditBox()
        if whisperFrame and whisperFrame.EditBox then
            whisperFrame.EditBox:SetFocus()
        end
    end

    -- A bare multiline EditBox does not reliably receive focus from every
    -- part of a ScrollFrame on all clients. Explicitly focus it when the
    -- user clicks anywhere inside the editor area.
    whisperFrame.EditBorder:EnableMouse(true)
    whisperFrame.ScrollFrame:EnableMouse(true)
    whisperFrame.EditBorder:HookScript("OnMouseDown", FocusWhisperEditBox)
    whisperFrame.ScrollFrame:HookScript("OnMouseDown", FocusWhisperEditBox)
    whisperFrame.EditBox:HookScript("OnMouseDown", FocusWhisperEditBox)

    whisperFrame.ScrollFrame:SetScript("OnSizeChanged", function(self, width)
        if whisperFrame and whisperFrame.EditBox then
            whisperFrame.EditBox:SetWidth(math.max(40, (width or self:GetWidth() or 40) - 4))
            UpdateEditorHeight(whisperFrame.EditBox, self)
        end
    end)
    whisperFrame.EditBox:SetScript("OnTextChanged", function(self)
        UpdateEditorHeight(self, whisperFrame.ScrollFrame)
    end)
    whisperFrame.EditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        whisperFrame:Hide()
    end)

    local save = CreateFrame("Button", nil, whisperFrame, "UIPanelButtonTemplate")
    save:SetSize(72, 22)
    save:SetPoint("BOTTOMRIGHT", -10, 10)
    save:SetText(SAVE or L.SAVE)
    save:SetScript("OnClick", function()
        StoreWhisperDraft(whisperFrame)
        addon:SetWhisperTemplates(
            whisperFrame.drafts[TAB_MPLUS] or "",
            whisperFrame.drafts[TAB_RAID] or ""
        )
        whisperFrame:Hide()
    end)

    local reset = CreateFrame("Button", nil, whisperFrame, "UIPanelButtonTemplate")
    reset:SetSize(82, 22)
    reset:SetPoint("RIGHT", save, "LEFT", -6, 0)
    reset:SetText(L.RESET_DEFAULT)
    reset:SetScript("OnClick", function()
        local mode = whisperFrame.activeMode or TAB_MPLUS
        local defaultText = GetDefaultWhisperForMode(mode)
        whisperFrame.drafts[mode] = defaultText
        whisperFrame.EditBox:SetText(defaultText)
        whisperFrame.EditBox:SetCursorPosition(#defaultText)
        whisperFrame.EditBox:SetFocus()
    end)

    local cancel = CreateFrame("Button", nil, whisperFrame, "UIPanelButtonTemplate")
    cancel:SetSize(62, 22)
    cancel:SetPoint("BOTTOMLEFT", 10, 10)
    cancel:SetText(CANCEL or L.CANCEL)
    cancel:SetScript("OnClick", function() whisperFrame:Hide() end)

    return whisperFrame
end

function addon:OpenWhisperSettings()
    local f = CreateWhisperEditor()
    f.drafts = {
        [TAB_MPLUS] = self.db and self.db.mplusWhisperTemplate or "",
        [TAB_RAID] = self.db and self.db.raidWhisperTemplate or "",
    }
    if f.drafts[TAB_MPLUS] == "" then f.drafts[TAB_MPLUS] = L.WHISPER_TEMPLATE_MPLUS end
    if f.drafts[TAB_RAID] == "" then f.drafts[TAB_RAID] = L.WHISPER_TEMPLATE_RAID end

    local mode = self.db and self.db.watchUI and self.db.watchUI.activeTab == TAB_RAID and TAB_RAID or TAB_MPLUS
    LoadWhisperMode(f, mode, false)

    f:ClearAllPoints()
    if frame then
        f:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -4)
        f:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -4)
    else
        f:SetPoint("CENTER")
    end
    f:Show()
    UpdateEditorHeight(f.EditBox, f.ScrollFrame)
    f.EditBox:SetFocus()
    f.EditBox:SetCursorPosition(#(f.EditBox:GetText() or ""))
end

local function SetFontStringSize(fontString, size)
    if not fontString or not fontString.GetFont then return end
    local font, _, flags = fontString:GetFont()
    if font then
        fontString:SetFont(font, size, flags)
    end
end

local function CreateAutoRuleCheck(parent, y, label, description)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", 12, y)

    check.Label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    check.Label:SetPoint("LEFT", check, "RIGHT", 2, 1)
    check.Label:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    check.Label:SetJustifyH("LEFT")
    check.Label:SetTextColor(0.25, 1.00, 0.35)
    check.Label:SetText(label)

    check.Desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    check.Desc:SetPoint("TOPLEFT", check.Label, "BOTTOMLEFT", 0, -5)
    check.Desc:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    check.Desc:SetJustifyH("LEFT")
    check.Desc:SetWordWrap(true)
    check.Desc:SetTextColor(0.62, 0.62, 0.62)
    SetFontStringSize(check.Desc, 10)
    check.Desc:SetText(description)
    return check
end

local function CreateAutoRulesEditor()
    if autoRulesFrame then return autoRulesFrame end

    autoRulesFrame = CreateFrame("Frame", "QFXBeggarAutoRulesEditor", EncounterJournal or UIParent, "BackdropTemplate")
    autoRulesFrame:SetSize(PANEL_WIDTH, 292)
    autoRulesFrame:SetFrameStrata("DIALOG")
    autoRulesFrame:SetClampedToScreen(true)
    autoRulesFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    autoRulesFrame:SetBackdropColor(0.045, 0.045, 0.045, 0.98)
    autoRulesFrame:Hide()

    autoRulesFrame.Title = autoRulesFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoRulesFrame.Title:SetPoint("TOPLEFT", 12, -11)
    autoRulesFrame.Title:SetText(L.AUTO_RULES_TITLE)

    autoRulesFrame.Desc = autoRulesFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    autoRulesFrame.Desc:SetPoint("TOPLEFT", 12, -32)
    autoRulesFrame.Desc:SetPoint("TOPRIGHT", -12, -32)
    autoRulesFrame.Desc:SetJustifyH("LEFT")
    autoRulesFrame.Desc:SetWordWrap(true)
    autoRulesFrame.Desc:SetTextColor(0.72, 0.72, 0.72)
    SetFontStringSize(autoRulesFrame.Desc, 10)
    autoRulesFrame.Desc:SetText(L.AUTO_RULES_DESC)

    autoRulesFrame.MPlusWatched = CreateAutoRuleCheck(autoRulesFrame, -68, L.AUTO_RULE_MPLUS_WATCHED, L.AUTO_RULE_MPLUS_WATCHED_DESC)
    autoRulesFrame.MPlusUpgrade = CreateAutoRuleCheck(autoRulesFrame, -124, L.AUTO_RULE_MPLUS_UPGRADE, L.AUTO_RULE_MPLUS_UPGRADE_DESC)
    autoRulesFrame.RaidWatched = CreateAutoRuleCheck(autoRulesFrame, -180, L.AUTO_RULE_RAID_WATCHED, L.AUTO_RULE_RAID_WATCHED_DESC)

    local save = CreateFrame("Button", nil, autoRulesFrame, "UIPanelButtonTemplate")
    save:SetSize(72, 22)
    save:SetPoint("BOTTOMRIGHT", -10, 10)
    save:SetText(SAVE or L.SAVE)
    save:SetScript("OnClick", function()
        addon:SetAutoRules({
            mplusWatched = not not autoRulesFrame.MPlusWatched:GetChecked(),
            mplusUpgrade = not not autoRulesFrame.MPlusUpgrade:GetChecked(),
            raidWatched = not not autoRulesFrame.RaidWatched:GetChecked(),
        })
        autoRulesFrame:Hide()
    end)

    local cancel = CreateFrame("Button", nil, autoRulesFrame, "UIPanelButtonTemplate")
    cancel:SetSize(62, 22)
    cancel:SetPoint("BOTTOMLEFT", 10, 10)
    cancel:SetText(CANCEL or L.CANCEL)
    cancel:SetScript("OnClick", function() autoRulesFrame:Hide() end)

    return autoRulesFrame
end

function addon:OpenAutoRulesSettings()
    local f = CreateAutoRulesEditor()
    f.MPlusWatched:SetChecked(self:GetAutoRule("mplusWatched"))
    f.MPlusUpgrade:SetChecked(self:GetAutoRule("mplusUpgrade"))
    f.RaidWatched:SetChecked(self:GetAutoRule("raidWatched"))

    f:ClearAllPoints()
    if frame then
        f:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -4)
        f:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -4)
    else
        f:SetPoint("CENTER")
    end
    f:Show()
end

function addon:CreateJournalWatchPanel()
    if frame or not EncounterJournal then return end

    frame = CreateFrame("Frame", "QFXBeggarJournalWatchPanel", EncounterJournal, "BackdropTemplate")
    frame:SetWidth(PANEL_WIDTH)
    frame:SetPoint("TOPRIGHT", EncounterJournal, "TOPLEFT", -2, 0)
    frame:SetPoint("BOTTOMRIGHT", EncounterJournal, "BOTTOMLEFT", -2, 0)
    frame:SetFrameStrata(EncounterJournal:GetFrameStrata())
    frame:SetFrameLevel((EncounterJournal:GetFrameLevel() or 1) + 2)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.075, 0.075, 0.075, 0.66)

    frame.Title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.Title:SetPoint("TOPLEFT", 12, -12)

    frame.Status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.Status:SetPoint("TOPRIGHT", -12, -13)

    frame.AutoButton = CreateFrame("Button", nil, frame)
    frame.AutoButton:SetPoint("TOPRIGHT", frame.Status, "TOPRIGHT", 2, 3)
    frame.AutoButton:SetPoint("BOTTOMLEFT", frame.Status, "BOTTOMLEFT", -2, -3)
    frame.AutoButton:SetScript("OnClick", function()
        if autoRulesFrame and autoRulesFrame:IsShown() then autoRulesFrame:Hide() else
            if whisperFrame then whisperFrame:Hide() end
            addon:OpenAutoRulesSettings()
        end
    end)
    frame.AutoButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.BEGGING_RULES_TIP_TITLE)
        GameTooltip:AddLine(L.BEGGING_RULES_TIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame.AutoButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.MPlusTab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.MPlusTab:SetSize(145, 22)
    frame.MPlusTab:SetPoint("TOPLEFT", 10, -37)
    frame.MPlusTab:SetScript("OnClick", function()
        EnsureUIState()
        addon.db.watchUI.activeTab = TAB_MPLUS
        frame.ListScroll:SetVerticalScroll(0)
        addon:RefreshWatchlistUI()
    end)

    frame.RaidTab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.RaidTab:SetSize(145, 22)
    frame.RaidTab:SetPoint("LEFT", frame.MPlusTab, "RIGHT", 6, 0)
    frame.RaidTab:SetScript("OnClick", function()
        EnsureUIState()
        addon.db.watchUI.activeTab = TAB_RAID
        frame.ListScroll:SetVerticalScroll(0)
        addon:RefreshWatchlistUI()
    end)

    frame.Separator = frame:CreateTexture(nil, "ARTWORK")
    frame.Separator:SetHeight(1)
    frame.Separator:SetPoint("TOPLEFT", 10, -64)
    frame.Separator:SetPoint("TOPRIGHT", -10, -64)
    frame.Separator:SetColorTexture(1, 0.82, 0, 0.28)

    frame.ListScroll = CreateFrame("ScrollFrame", nil, frame)
    frame.ListScroll:SetPoint("TOPLEFT", 6, -LIST_TOP)
    frame.ListScroll:SetPoint("BOTTOMRIGHT", -6, LIST_BOTTOM)
    frame.ListScroll:EnableMouseWheel(true)

    frame.ListContent = CreateFrame("Frame", nil, frame.ListScroll)
    frame.ListContent:SetSize(PANEL_WIDTH - 12, 1)
    frame.ListScroll:SetScrollChild(frame.ListContent)

    frame.ListScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll() or 0
        self:SetVerticalScroll(current - delta * 42)
        ClampScroll()
    end)
    frame.ListScroll:SetScript("OnScrollRangeChanged", function() ClampScroll() end)
    frame.ListScroll:SetScript("OnSizeChanged", function(self, width)
        if frame and frame.ListContent then
            frame.ListContent:SetWidth(math.max(1, width or self:GetWidth() or 1))
        end
        addon:RefreshWatchlistUI()
    end)

    frame.Watermark = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.Watermark:SetTexture("Interface\\AddOns\\QFXBeggar\\Media\\Icon.tga")
    frame.Watermark:SetPoint("BOTTOM", frame, "BOTTOM", 0, 44)
    frame.Watermark:SetSize(PANEL_WIDTH - 54, PANEL_WIDTH - 54)
    frame.Watermark:SetBlendMode("BLEND")
    frame.Watermark:SetAlpha(0.55)

    frame.Empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.Empty:SetPoint("TOP", frame.ListScroll, "TOP", 0, -30)

    frame.ScrollHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.ScrollHint:SetPoint("BOTTOM", 0, 43)
    frame.ScrollHint:SetText(L.SCROLL_MORE)

    frame.FooterSeparator = frame:CreateTexture(nil, "ARTWORK")
    frame.FooterSeparator:SetHeight(1)
    frame.FooterSeparator:SetPoint("BOTTOMLEFT", 10, 38)
    frame.FooterSeparator:SetPoint("BOTTOMRIGHT", -10, 38)
    frame.FooterSeparator:SetColorTexture(1, 0.82, 0, 0.20)

    frame.WhisperButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.WhisperButton:SetSize(145, 22)
    frame.WhisperButton:SetPoint("BOTTOMLEFT", 10, 10)
    frame.WhisperButton:SetText(L.WHISPER_SETTINGS)
    frame.WhisperButton:SetScript("OnClick", function()
        if whisperFrame and whisperFrame:IsShown() then
            whisperFrame:Hide()
        else
            if autoRulesFrame then autoRulesFrame:Hide() end
            addon:OpenWhisperSettings()
        end
    end)

    frame.AutoRulesButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.AutoRulesButton:SetSize(145, 22)
    frame.AutoRulesButton:SetPoint("LEFT", frame.WhisperButton, "RIGHT", 6, 0)
    frame.AutoRulesButton:SetText(L.AUTO_WHISPER_SETTINGS)
    frame.AutoRulesButton:SetScript("OnClick", function()
        if autoRulesFrame and autoRulesFrame:IsShown() then
            autoRulesFrame:Hide()
        else
            if whisperFrame then whisperFrame:Hide() end
            addon:OpenAutoRulesSettings()
        end
    end)

    frame:SetScript("OnSizeChanged", function() addon:RefreshWatchlistUI() end)
    frame:SetScript("OnHide", function()
        if whisperFrame then whisperFrame:Hide() end
        if autoRulesFrame then autoRulesFrame:Hide() end
    end)

    EnsureUIState()
    frame:Show()
    self:RefreshWatchlistUI()
end

function addon:ToggleWatchlistUI()
    if not EncounterJournal then
        if EncounterJournal_LoadUI then EncounterJournal_LoadUI() end
    end
    if self.CreateJournalWatchPanel then self:CreateJournalWatchPanel() end
    if frame then frame:Show() end
end

local _, addon = ...
local L = addon.L

local hooked = false
local stars = setmetatable({}, { __mode = "k" })

local function SafeCall(func, ...)
    if type(func) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h = pcall(func, ...)
    if not ok then return nil end
    return a, b, c, d, e, f, g, h
end

local function GetRowLootInfo(row)
    if not row then return nil end

    -- Current Encounter Journal rows expose itemID/link directly. Try the
    -- ScrollBox element data as well so encounter/source metadata survives
    -- Blizzard implementation changes.
    local data
    if type(row.GetElementData) == "function" then
        data = SafeCall(row.GetElementData, row)
    end
    if type(data) == "table" then
        if data.itemID then return data end
        if type(data.info) == "table" and data.info.itemID then return data.info end
        if type(data.lootInfo) == "table" and data.lootInfo.itemID then return data.lootInfo end
    end

    if type(row.itemInfo) == "table" and row.itemInfo.itemID then
        return row.itemInfo
    end
    if type(row.lootInfo) == "table" and row.lootInfo.itemID then
        return row.lootInfo
    end

    local itemID = row.itemID
    if itemID and C_EncounterJournal and C_EncounterJournal.GetLootInfo then
        local info = SafeCall(C_EncounterJournal.GetLootInfo, itemID)
        if type(info) == "table" and info.itemID == itemID then
            return info
        end
    end

    return nil
end

local function GetSourceContext(row, itemID, itemLink)
    local context = {
        itemID = itemID,
        itemLink = itemLink,
    }

    local info = GetRowLootInfo(row)
    if info then
        context.encounterID = info.encounterID
        context.slot = info.slot
        context.armorType = info.armorType
        context.itemName = info.name
        context.itemIcon = info.icon
    end

    context.encounterID = context.encounterID or row.encounterID or row.journalEncounterID

    if context.encounterID and EJ_GetEncounterInfo then
        local encounterName, _, _, _, _, journalInstanceID = SafeCall(EJ_GetEncounterInfo, context.encounterID)
        context.encounterName = encounterName
        context.journalInstanceID = journalInstanceID

        if journalInstanceID and EJ_GetInstanceInfo then
            -- EJ_GetInstanceInfo also returns isRaid as its final value. Keep
            -- that source type with the watch entry so the attached list can
            -- automatically split dungeon/M+ items from raid items.
            local ok, instanceName, _, _, _, _, _, _, _, _, _, _, isRaid = pcall(EJ_GetInstanceInfo, journalInstanceID)
            if ok then
                context.instanceName = instanceName
                if type(isRaid) == "boolean" then context.isRaid = isRaid end
            end
        end
    end

    return context
end

local function ShowTrackMenu(owner, itemID, itemLink, context)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end

    MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
        rootDescription:SetTag("MENU_QFX_BEGGAR_TRACK")
        rootDescription:CreateTitle(addon:IsWatched(itemID) and L.CHANGE_TRACK or L.CHOOSE_TRACK_TO_WATCH)

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
            rootDescription:CreateRadio(
                label,
                function()
                    local entry = addon:GetWatch(itemID)
                    return entry and entry.minTrack == rank
                end,
                function()
                    -- Selecting a track is the commit point. Simply clicking
                    -- the star never creates a watch entry.
                    addon:SetWatch(itemID, itemLink, rank, context)
                end
            )
        end

        if addon:IsWatched(itemID) then
            rootDescription:CreateDivider()
            rootDescription:CreateButton(L.REMOVE, function()
                addon:RemoveWatch(itemID)
            end)
        end
    end)
end

local function UpdateStar(row)
    local star = stars[row]
    if not star then return end

    local itemID = row.itemID
    if not itemID then
        star:Hide()
        return
    end

    star.itemID = itemID
    star.itemLink = row.link
    star.context = GetSourceContext(row, itemID, row.link)
    star:Show()

    local entry = addon:GetWatch(itemID)
    -- Use inline color codes instead of relying only on SetTextColor().
    -- Encounter Journal row refreshes can re-apply font-object colors; the
    -- inline color keeps both watched and unwatched stars green reliably.
    star.Text:SetTextColor(1, 1, 1)
    if entry then
        star.Text:SetText("|cff33ff66★|r")
    else
        star.Text:SetText("|cff4bd866☆|r")
    end

    -- Keep the original Encounter Journal slot/armor text completely clear.
    -- The selected track is shown in the attached watchlist and tooltip instead.
    star.Track:SetText("")
    star.Track:Hide()
end

local function AttachStar(row)
    if stars[row] then
        UpdateStar(row)
        return
    end

    local star = CreateFrame("Button", nil, row)
    star:SetSize(24, 22)
    -- Put the star in the upper-right corner so it no longer competes with
    -- Blizzard's slot/armor-type label on the lower-right of the loot row.
    star:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -3)
    star:SetFrameLevel((row:GetFrameLevel() or 1) + 5)
    star:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    star.Text = star:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    star.Text:SetPoint("CENTER", star, "CENTER", 0, 0)
    star.Text:SetText("|cff4bd866☆|r")
    star.Text:SetTextColor(1, 1, 1)

    star.Track = star:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    star.Track:SetPoint("RIGHT", star.Text, "LEFT", -3, 0)
    star.Track:SetJustifyH("RIGHT")

    star:SetScript("OnClick", function(self)
        if not self.itemID then return end
        ShowTrackMenu(self, self.itemID, self.itemLink, self.context)
    end)
    star:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.STAR_TIP_TITLE)
        GameTooltip:AddLine(L.STAR_TIP, 1, 1, 1, true)
        local entry = self.itemID and addon:GetWatch(self.itemID)
        if entry then
            GameTooltip:AddLine(L.MIN_TRACK .. ": " .. addon:GetWatchRequirementLabel(entry.minTrack), 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
    star:SetScript("OnLeave", function() GameTooltip:Hide() end)

    stars[row] = star
    UpdateStar(row)
end

function addon:RefreshJournalStars()
    for row in pairs(stars) do
        UpdateStar(row)
    end
end

function addon:InitAdventureJournal()
    if hooked then
        if self.CreateJournalWatchPanel then self:CreateJournalWatchPanel() end
        return
    end
    if not EncounterJournalItemMixin or type(EncounterJournalItemMixin.Init) ~= "function" then
        return
    end

    hooksecurefunc(EncounterJournalItemMixin, "Init", function(row)
        AttachStar(row)
    end)
    hooked = true

    if self.CreateJournalWatchPanel then self:CreateJournalWatchPanel() end

    local lootContainer = EncounterJournal and EncounterJournal.encounter and EncounterJournal.encounter.info and EncounterJournal.encounter.info.LootContainer
    local scrollBox = lootContainer and lootContainer.ScrollBox
    if scrollBox and scrollBox.ForEachFrame then
        scrollBox:ForEachFrame(function(row)
            if row and row.itemID then AttachStar(row) end
        end)
    end
end

local _, addon = ...
local L = addon.L

local hooked = false
local buttons = setmetatable({}, { __mode = "k" })
local sentAt = {}
local autoHandled = setmetatable({}, { __mode = "k" })

local function GetItemIDFromLink(link)
    if not link or issecretvalue(link) then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

local function IsRaidInstance()
    local _, instanceType = GetInstanceInfo()
    return instanceType == "raid"
end

local function NormalizeTarget(name)
    if not name or issecretvalue(name) or name == "" then return nil end
    return name
end

local function IsSelfWinner(winner)
    if not winner then return false end
    if winner.isSelf then return true end
    local name = winner.playerName
    if not name or issecretvalue(name) then return false end
    local short = name:match("^([^%-]+)")
    return short and short == UnitName("player")
end

local function IsRaidWatch(entry)
    if not entry then return false end
    if type(entry.isRaid) == "boolean" then return entry.isRaid end
    if entry.journalInstanceID and type(EJ_GetInstanceInfo) == "function" then
        local ok, _, _, _, _, _, _, _, _, _, _, _, isRaid = pcall(EJ_GetInstanceInfo, entry.journalInstanceID)
        if ok and type(isRaid) == "boolean" then
            entry.isRaid = isRaid
            return isRaid
        end
    end
    return false
end

local function GetSentKey(target, itemID)
    return tostring(target) .. ":" .. tostring(itemID)
end

local function MarkButtonSent(button, target, itemID)
    local key = GetSentKey(target, itemID)
    sentAt[key] = GetTime()
    if not button then return end

    button:SetText(L.RAID_REQUEST_SENT)
    button:Disable()
    C_Timer.After(60, function()
        if button and button:IsObjectType("Button") then
            local data = button.qfxData
            if data and GetSentKey(data.target, data.itemID) == key then
                button:SetText(L.RAID_REQUEST)
                button:Enable()
            end
        end
    end)
end

local function WasRecentlySent(target, itemID)
    local t = sentAt[GetSentKey(target, itemID)]
    return t and (GetTime() - t) < 60
end

local function SendRaidRequestData(data, button, automatic)
    if not data then return false end
    if WasRecentlySent(data.target, data.itemID) then return false end
    if not IsRaidInstance() then return false end

    if not addon:SendWhisperSafely(data.target, data.itemLink, data.actualTrack, "raid") then
        return false
    end

    if automatic then
        addon:Print(string.format(L.RAID_AUTO_WHISPER_SENT, data.target, data.itemLink, data.actualTrack and addon:GetTrackLabel(data.actualTrack) or L.UNKNOWN_TRACK))
    else
        addon:Print(string.format(L.RAID_WHISPER_SENT, data.target, data.itemLink, data.actualTrack and addon:GetTrackLabel(data.actualTrack) or L.UNKNOWN_TRACK))
    end
    MarkButtonSent(button, data.target, data.itemID)
    return true
end

local function SendRaidRequest(button)
    local data = button.qfxData
    if not data then return end
    SendRaidRequestData(data, button, false)
end

local function CreateRequestButton(row)
    local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    button:SetSize(42, 18)
    button:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -5, 4)
    button:SetFrameLevel((row:GetFrameLevel() or 1) + 20)
    button:SetText(L.RAID_REQUEST)
    button:SetScript("OnClick", SendRaidRequest)
    button:SetScript("OnEnter", function(self)
        local data = self.qfxData
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.RAID_REQUEST_TIP_TITLE)
        if data then
            local trackText = data.actualTrack and addon:GetTrackLabel(data.actualTrack) or L.UNKNOWN_TRACK
            local watchText = data.isWatched and L.RAID_REQUEST_TIP_WATCHED or L.RAID_REQUEST_TIP_NORMAL
            GameTooltip:AddLine(string.format(L.RAID_REQUEST_TIP, data.target, trackText, watchText), 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:Hide()
    buttons[row] = button
    return button
end

local function RestoreWinnerAnchor(row)
    if row and row.WinningRollInfo and row.WinningRollInfo.qfxBeggarMoved then
        row.WinningRollInfo:ClearAllPoints()
        row.WinningRollInfo:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -7, 14)
        row.WinningRollInfo.qfxBeggarMoved = nil
    end
end

local function ReserveButtonSpace(row)
    if row and row.WinningRollInfo and not row.WinningRollInfo.qfxBeggarMoved then
        row.WinningRollInfo:ClearAllPoints()
        row.WinningRollInfo:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -52, 14)
        row.WinningRollInfo.qfxBeggarMoved = true
    end
end

local function HideRequest(row)
    local button = buttons[row]
    if button then
        button.qfxData = nil
        button:Hide()
    end
    RestoreWinnerAnchor(row)
end

local function EvaluateRow(row, dropInfo, allowAuto)
    HideRequest(row)
    if not addon.db or not IsRaidInstance() then return end
    if not dropInfo or not dropInfo.winner or dropInfo.allPassed then return end
    if IsSelfWinner(dropInfo.winner) then return end

    -- Every completed raid roll won by another player keeps a manual Ask button.
    -- Watched raid items may additionally auto-whisper when that rule is enabled.
    local itemLink = dropInfo.itemHyperlink
    if not itemLink or issecretvalue(itemLink) then return end
    local itemID = GetItemIDFromLink(itemLink)
    if not itemID then return end

    local target = NormalizeTarget(dropInfo.winner.playerName)
    if not target then return end

    local function FinishEvaluation()
        if row.dropInfo ~= dropInfo then return end

        local actualTrack = addon:GetItemTrack(itemLink)
        local watch = addon:GetWatch(itemID)
        local raidWatch = watch and IsRaidWatch(watch) and watch or nil
        local button = buttons[row] or CreateRequestButton(row)
        button.qfxData = {
            target = target,
            itemID = itemID,
            itemLink = itemLink,
            actualTrack = actualTrack,
            isWatched = raidWatch ~= nil,
        }
        ReserveButtonSpace(row)

        local recentlySent = WasRecentlySent(target, itemID)
        button:SetText(recentlySent and L.RAID_REQUEST_SENT or L.RAID_REQUEST)
        button:SetEnabled(not recentlySent)
        button:Show()

        -- Automatic raid whispers are deliberately limited to watched raid items.
        -- The player's watched-quality threshold is still respected. Unwatched
        -- items (or watched items below the threshold) remain manual-only.
        if allowAuto and raidWatch and addon:GetAutoRule("raidWatched") and not recentlySent and not autoHandled[dropInfo] then
            local meets = addon:MeetsTrackRequirement(itemLink, raidWatch.minTrack)
            if meets then
                autoHandled[dropInfo] = true
                SendRaidRequestData(button.qfxData, button, true)
            end
        end
    end

    local item = Item and Item.CreateFromItemLink and Item:CreateFromItemLink(itemLink)
    if item and item.ContinueOnItemLoad then
        item:ContinueOnItemLoad(FinishEvaluation)
    else
        FinishEvaluation()
    end
end

function addon:RefreshRaidLootButtons()
    for row in pairs(buttons) do
        if row and row.dropInfo then
            -- Refreshing UI/settings must never retroactively auto-whisper old loot.
            EvaluateRow(row, row.dropInfo, false)
        else
            HideRequest(row)
        end
    end
end

function addon:InitRaidLootIntegration()
    if hooked then return end
    if not LootHistoryElementMixin or type(LootHistoryElementMixin.Init) ~= "function" then return end

    hooksecurefunc(LootHistoryElementMixin, "Init", function(row, dropInfo)
        EvaluateRow(row, dropInfo, true)
    end)
    hooked = true
end

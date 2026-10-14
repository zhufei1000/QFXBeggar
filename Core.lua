local ADDON_NAME, addon = ...
local L = addon.L

QFXBeggar = addon
addon.version = "1.0.25"
addon.TRACK = {
    ANY = 0,
    ADVENTURER = 1,
    VETERAN = 2,
    CHAMPION = 3,
    HERO = 4,
    MYTH = 5,
}

local DB_DEFAULTS = {
    watchlist = {},
    -- Legacy master flag kept for migration and slash-command compatibility.
    autoWhisper = true,
    autoRules = {
        mplusUpgrade = true,
        mplusWatched = true,
        raidWatched = true,
    },
    autoRulesMigrated = false,
    -- v1.0.16: Mythic+ automatic requests and raid manual requests have
    -- independent whisper templates. whisperTemplate is kept only for a
    -- one-time migration from older versions.
    whisperTemplate = "",
    mplusWhisperTemplate = "",
    raidWhisperTemplate = "",
    whisperTemplatesMigrated = false,
    watchUI = {
        activeTab = "mythicplus",
        collapsed = { mythicplus = {}, raid = {} },
    },
}

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

function addon:Print(msg)
    print("|cffffd100[" .. L.ADDON_NAME .. "]|r " .. tostring(msg))
end

function addon:GetTrackLabel(rank)
    if rank == self.TRACK.MYTH then return L.TRACK_MYTH end
    if rank == self.TRACK.HERO then return L.TRACK_HERO end
    if rank == self.TRACK.CHAMPION then return L.TRACK_CHAMPION end
    if rank == self.TRACK.VETERAN then return L.TRACK_VETERAN end
    if rank == self.TRACK.ADVENTURER then return L.TRACK_ADVENTURER end
    return L.TRACK_ANY
end

function addon:GetWatchRequirementLabel(rank)
    rank = tonumber(rank) or self.TRACK.ANY
    local label = self:GetTrackLabel(rank)
    if rank == self.TRACK.ANY or rank == self.TRACK.MYTH then
        return label
    end
    return string.format(L.TRACK_OR_HIGHER, label)
end

local TRACK_MATCHES = {
    [1] = { "adventurer", "冒险者", "冒險者" },
    [2] = { "veteran", "老兵" },
    [3] = { "champion", "勇士" },
    [4] = { "hero", "英雄" },
    [5] = { "myth", "mythic", "神话", "神話", "史诗", "史詩" },
}

function addon:GetItemTrack(itemLink)
    if not itemLink or issecretvalue(itemLink) then return nil, nil end
    if not C_Item or not C_Item.GetItemUpgradeInfo then return nil, nil end

    local info = C_Item.GetItemUpgradeInfo(itemLink)
    if not info then return nil, nil end
    local trackString = info.trackString
    if not trackString or issecretvalue(trackString) then return nil, info end

    local lowered = string.lower(trackString)
    for rank = self.TRACK.MYTH, self.TRACK.ADVENTURER, -1 do
        for _, token in ipairs(TRACK_MATCHES[rank]) do
            if lowered:find(token, 1, true) then
                return rank, info
            end
        end
    end
    return nil, info
end

function addon:MeetsTrackRequirement(itemLink, minimumTrack)
    minimumTrack = tonumber(minimumTrack) or self.TRACK.ANY
    if minimumTrack <= self.TRACK.ANY then
        return true, self.TRACK.ANY, nil
    end
    local actualTrack, info = self:GetItemTrack(itemLink)
    if not actualTrack then
        return false, nil, info
    end
    return actualTrack >= minimumTrack, actualTrack, info
end



local AUTO_RULE_KEYS = {
    mplusUpgrade = true,
    mplusWatched = true,
    raidWatched = true,
}

local function MigrateAutoRules(db)
    if not db or db.autoRulesMigrated then return end
    db.autoRules = db.autoRules or {}

    -- Up to 1.0.17, autoWhisper was the only automatic-message switch.
    -- Preserve an explicit OFF choice conservatively: do not introduce a new
    -- raid auto-whisper behind the player's back during migration.
    if db.autoWhisper == false then
        db.autoRules.mplusUpgrade = false
        db.autoRules.mplusWatched = false
        db.autoRules.raidWatched = false
    end

    for key, defaultValue in pairs(AUTO_RULE_KEYS) do
        if db.autoRules[key] == nil then db.autoRules[key] = defaultValue end
    end
    db.autoRulesMigrated = true
end

function addon:GetAutoRule(key)
    if not AUTO_RULE_KEYS[key] or not self.db then return false end
    self.db.autoRules = self.db.autoRules or {}
    local value = self.db.autoRules[key]
    if value == nil then return AUTO_RULE_KEYS[key] end
    return value ~= false
end

function addon:SetAutoRules(rules, silent)
    if not self.db then return end
    self.db.autoRules = self.db.autoRules or {}
    for key in pairs(AUTO_RULE_KEYS) do
        if rules and rules[key] ~= nil then
            self.db.autoRules[key] = not not rules[key]
        end
    end
    self.db.autoRulesMigrated = true

    -- Keep the old field as a coarse compatibility mirror.
    self.db.autoWhisper = self:GetAutoRule("mplusUpgrade") or self:GetAutoRule("mplusWatched") or self:GetAutoRule("raidWatched")

    if not silent then self:Print(L.AUTO_RULES_SAVED) end
    if self.RefreshWatchlistUI then self:RefreshWatchlistUI() end
    if self.RefreshRaidLootButtons then self:RefreshRaidLootButtons() end
end

local WHISPER_MODE_MPLUS = "mythicplus"
local WHISPER_MODE_RAID = "raid"

local function NormalizeWhisperMode(mode)
    return mode == WHISPER_MODE_RAID and WHISPER_MODE_RAID or WHISPER_MODE_MPLUS
end

local function MigrateWhisperTemplates(db)
    if not db or db.whisperTemplatesMigrated then return end

    -- Older versions had one shared custom template. Preserve that user's
    -- wording by copying it into both new channels exactly once. New installs
    -- simply start with the two localized defaults.
    local legacy = type(db.whisperTemplate) == "string" and strtrim(db.whisperTemplate) or ""
    if legacy ~= "" then
        if type(db.mplusWhisperTemplate) ~= "string" or db.mplusWhisperTemplate == "" then
            db.mplusWhisperTemplate = legacy
        end
        if type(db.raidWhisperTemplate) ~= "string" or db.raidWhisperTemplate == "" then
            db.raidWhisperTemplate = legacy
        end
    end
    db.whisperTemplatesMigrated = true
end

function addon:GetWhisperTemplate(mode)
    mode = NormalizeWhisperMode(mode)
    if self.db then
        local key = mode == WHISPER_MODE_RAID and "raidWhisperTemplate" or "mplusWhisperTemplate"
        local custom = self.db[key]
        if type(custom) == "string" and custom ~= "" then
            return custom
        end
    end
    return mode == WHISPER_MODE_RAID and L.WHISPER_TEMPLATE_RAID or L.WHISPER_TEMPLATE_MPLUS
end

local function IsCompleteItemHyperlink(link)
    if type(link) ~= "string" or link == "" or issecretvalue(link) then return false end
    -- Retail 11.1.5+ uses |cnIQx... item-quality color tokens. Keep the
    -- legacy |cAARRGGBB form too, so the addon remains tolerant of links from
    -- older/other clients. SendChatMessage only accepts a complete hyperlink.
    if link:match("^|cn[^|]*|Hitem:.-|h.-|h|r$") then return true end
    if link:match("^|c%x%x%x%x%x%x%x%x|Hitem:.-|h.-|h|r$") then return true end
    return false
end

function addon:GetChatSafeItemText(itemLink, plainOnly)
    if not itemLink or issecretvalue(itemLink) then return "" end

    -- Ask Blizzard for a canonical localized link whenever possible. This also
    -- restores the quality-color prefix/suffix if our source supplied only the
    -- hyperlink body. The calling paths already wait for item data to load.
    if not plainOnly and C_Item and C_Item.GetItemInfo then
        local _, canonicalLink = C_Item.GetItemInfo(itemLink)
        if canonicalLink and not issecretvalue(canonicalLink) and IsCompleteItemHyperlink(canonicalLink) then
            return canonicalLink
        end
    end

    if not plainOnly and IsCompleteItemHyperlink(itemLink) then
        return itemLink
    end

    -- Fail safely to visible plain text. A naked |Hitem... sequence is not
    -- legal in SendChatMessage and causes "Invalid escape code".
    local visible = itemLink:match("|h(%b[])|h")
    if visible and visible ~= "" then return visible end

    local itemID = itemLink:match("item:(%d+)")
    if itemID and C_Item and C_Item.GetItemInfo then
        local name = C_Item.GetItemInfo(tonumber(itemID))
        if name and not issecretvalue(name) then return "[" .. name .. "]" end
    end
    return "[item]"
end

function addon:FormatWhisperMessage(itemLink, playerName, actualTrack, mode, plainOnly)
    local template = self:GetWhisperTemplate(mode)
    local itemText = self:GetChatSafeItemText(itemLink, plainOnly)
    local playerText = playerName or ""
    local trackText = actualTrack and self:GetTrackLabel(actualTrack) or L.UNKNOWN_TRACK

    -- A player's custom template is plain chat text. Literal pipe characters
    -- are not legal in SendChatMessage unless they form a supported complete
    -- UI escape sequence, so neutralize them before inserting our validated
    -- item hyperlink.
    template = tostring(template or ""):gsub("|", "｜")

    -- Named tokens are easier for players to understand. Keep %s as a
    -- backwards-compatible alias for the item link used by early versions.
    local message = template
    message = message:gsub("%%item%%", function() return itemText end)
    message = message:gsub("%%player%%", function() return playerText end)
    message = message:gsub("%%track%%", function() return trackText end)
    message = message:gsub("%%s", function() return itemText end)
    message = message:gsub("[\r\n]+", " ")
    return strtrim(message)
end

function addon:SendWhisperSafely(target, itemLink, actualTrack, mode)
    if issecretvalue(target) or not target or target == "" then return false end

    local social = C_SocialRestrictions
    if social and type(social.CanSendChat) == "function" then
        local ok, allowed = pcall(social.CanSendChat)
        if not ok or allowed ~= true then return false end
    end
    local chat = C_ChatInfo
    if chat and type(chat.InChatMessagingLockdown) == "function" then
        local ok, locked = pcall(chat.InChatMessagingLockdown)
        if not ok or locked then return false end
    end
    local sender = chat and chat.SendChatMessage or SendChatMessage
    if type(sender) ~= "function" then return false end

    local message = self:FormatWhisperMessage(itemLink, target, actualTrack, mode, false)
    if not message or message == "" then return false end

    -- pcall keeps a malformed/unexpected future hyperlink from surfacing as a
    -- Lua error. If Blizzard rejects the hyperlink, retry once with the item
    -- name as plain text so the request still reaches the player.
    local ok = pcall(sender, message, "WHISPER", nil, target)
    if ok then return true end

    local fallback = self:FormatWhisperMessage(itemLink, target, actualTrack, mode, true)
    if not fallback or fallback == "" then return false end
    return pcall(sender, fallback, "WHISPER", nil, target)
end

function addon:SetWhisperTemplates(mplusText, raidText)
    if not self.db then return end
    self.db.mplusWhisperTemplate = type(mplusText) == "string" and strtrim(mplusText) or ""
    self.db.raidWhisperTemplate = type(raidText) == "string" and strtrim(raidText) or ""
    self.db.whisperTemplatesMigrated = true
    self:Print(L.WHISPER_SAVED)
    if self.RefreshWatchlistUI then self:RefreshWatchlistUI() end
end

function addon:ResetWhisperTemplate(mode)
    if not self.db then return end
    mode = NormalizeWhisperMode(mode)
    if mode == WHISPER_MODE_RAID then
        self.db.raidWhisperTemplate = ""
    else
        self.db.mplusWhisperTemplate = ""
    end
    self.db.whisperTemplatesMigrated = true
    self:Print(L.WHISPER_RESET_DONE)
end

function addon:IsWatched(itemID)
    return self.db and self.db.watchlist and self.db.watchlist[itemID] ~= nil
end

function addon:GetWatch(itemID)
    return self.db and self.db.watchlist and self.db.watchlist[itemID] or nil
end

function addon:SetWatch(itemID, itemLink, minTrack, context)
    if not itemID or not self.db then return end
    local old = self.db.watchlist[itemID]
    context = context or {}

    local name = context.itemName or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID) or nil)
    if not name then
        name = C_Item.GetItemInfo(itemID)
    end

    local icon = context.itemIcon
    if not icon and C_Item.GetItemIconByID then
        icon = C_Item.GetItemIconByID(itemID)
    end

    self.db.watchlist[itemID] = {
        itemID = itemID,
        itemLink = itemLink or (old and old.itemLink),
        itemName = name or (old and old.itemName),
        itemIcon = icon or (old and old.itemIcon),
        minTrack = tonumber(minTrack) or self.TRACK.HERO,
        encounterID = context.encounterID or (old and old.encounterID),
        encounterName = context.encounterName or (old and old.encounterName),
        journalInstanceID = context.journalInstanceID or (old and old.journalInstanceID),
        instanceName = context.instanceName or (old and old.instanceName),
        slot = context.slot or (old and old.slot),
        armorType = context.armorType or (old and old.armorType),
        isRaid = type(context.isRaid) == "boolean" and context.isRaid or (old and old.isRaid),
        addedTime = old and old.addedTime or time(),
    }

    -- When an item is added from the Encounter Journal, immediately show the
    -- matching category so the newly watched item is visible without another click.
    if self.db.watchUI and type(self.db.watchlist[itemID].isRaid) == "boolean" then
        self.db.watchUI.activeTab = self.db.watchlist[itemID].isRaid and "raid" or "mythicplus"
    end

    if self.SnapshotOwnedItemGUIDs then
        self:SnapshotOwnedItemGUIDs(itemID)
    end
    if self.RefreshJournalStars then self:RefreshJournalStars() end
    if self.RefreshWatchlistUI then self:RefreshWatchlistUI() end
    if self.RefreshRaidLootButtons then self:RefreshRaidLootButtons() end

    local display = itemLink or name or ("item:" .. itemID)
    local msgKey = old and "UPDATED" or "ADDED"
    self:Print(string.format(L[msgKey], display, self:GetWatchRequirementLabel(self.db.watchlist[itemID].minTrack)))
end

function addon:RemoveWatch(itemID, silent)
    if not itemID or not self.db or not self.db.watchlist[itemID] then return end
    local entry = self.db.watchlist[itemID]
    self.db.watchlist[itemID] = nil

    if self.ClearOwnedItemGUIDs then self:ClearOwnedItemGUIDs(itemID) end
    if self.RefreshJournalStars then self:RefreshJournalStars() end
    if self.RefreshWatchlistUI then self:RefreshWatchlistUI() end
    if self.RefreshRaidLootButtons then self:RefreshRaidLootButtons() end

    if not silent then
        self:Print(string.format(L.REMOVED, entry.itemLink or entry.itemName or ("item:" .. itemID)))
    end
end

function addon:GetWatchCount()
    local count = 0
    if self.db and self.db.watchlist then
        for _ in pairs(self.db.watchlist) do count = count + 1 end
    end
    return count
end

function addon:SetAutoWhisper(enabled)
    enabled = not not enabled
    self:SetAutoRules({
        mplusUpgrade = enabled,
        mplusWatched = enabled,
        raidWatched = enabled,
    }, true)
    self:Print(enabled and L.AUTO_WHISPER_TOGGLED_ON or L.AUTO_WHISPER_TOGGLED_OFF)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            QFXBeggarDB = QFXBeggarDB or {}
            CopyDefaults(QFXBeggarDB, DB_DEFAULTS)
            addon.db = QFXBeggarDB
            MigrateWhisperTemplates(addon.db)
            MigrateAutoRules(addon.db)
        elseif arg1 == "Blizzard_EncounterJournal" then
            if addon.InitAdventureJournal then addon:InitAdventureJournal() end
        end
        -- LootHistory is normally part of Blizzard_FrameXML, but retry on
        -- later addon loads as a compatibility fallback if Blizzard moves it.
        if addon.InitRaidLootIntegration then addon:InitRaidLootIntegration() end
    elseif event == "PLAYER_LOGIN" then
        if not addon.db then
            QFXBeggarDB = QFXBeggarDB or {}
            CopyDefaults(QFXBeggarDB, DB_DEFAULTS)
            addon.db = QFXBeggarDB
            MigrateWhisperTemplates(addon.db)
            MigrateAutoRules(addon.db)
        else
            MigrateWhisperTemplates(addon.db)
            MigrateAutoRules(addon.db)
        end

        if addon.InitLootMonitor then addon:InitLootMonitor() end
        if addon.InitRaidLootIntegration then addon:InitRaidLootIntegration() end
        if addon.InitWatchlistUI then addon:InitWatchlistUI() end

        if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
            if addon.InitAdventureJournal then addon:InitAdventureJournal() end
        end
    end
end)

SLASH_QFXBEGGAR1 = "/beggar"
SLASH_QFXBEGGAR2 = "/qfxbeggar"
SlashCmdList.QFXBEGGAR = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "on" then
        addon:SetAutoWhisper(true)
    elseif msg == "off" then
        addon:SetAutoWhisper(false)
    elseif msg == "help" then
        addon:Print(L.HELP)
    else
        if addon.ToggleWatchlistUI then addon:ToggleWatchlistUI() end
    end
end

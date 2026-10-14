local _, addon = ...
local L = addon.L

local eventFrame = CreateFrame("Frame")
local playerLastWhisper = {}
local knownOwnedGUIDs = {}
local challengeActive = false
local recentChallengeCompletedAt = 0

local function ShortName(name)
    return name and name:match("^([^%-]+)") or nil
end

local function IsMe(name, guid)
    if guid and not issecretvalue(guid) and guid == UnitGUID("player") then return true end
    local short = name and not issecretvalue(name) and ShortName(name) or nil
    return short and short == UnitName("player")
end

local function GetItemIDFromLink(link)
    if not link or issecretvalue(link) then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

local function ExtractItemLink(text)
    if not text or issecretvalue(text) then return nil end

    -- CHAT_MSG_LOOT contains a complete item hyperlink. Preserve the entire
    -- quality-color wrapper because SendChatMessage rejects a naked
    -- |Hitem...|h...|h sequence as an invalid escape code.
    local link = text:match("(|cn[^|]*|Hitem:.-|h.-|h|r)")
    if link then return link end

    link = text:match("(|c%x%x%x%x%x%x%x%x|Hitem:.-|h.-|h|r)")
    if link then return link end

    -- Fallback for unusual clients/sources. Core.lua will canonicalize this
    -- before it is ever sent to chat.
    return text:match("(|Hitem:.-|h.-|h)")
end

local function LongestStaticPart(formatString)
    if not formatString or formatString == "" then return nil end
    local best = ""
    local cursor = 1
    while true do
        local s, e = formatString:find("%%[%d%$%.%-]*[sd]", cursor)
        if not s then
            local part = formatString:sub(cursor)
            if #part > #best then best = part end
            break
        end
        local part = formatString:sub(cursor, s - 1)
        if #part > #best then best = part end
        cursor = e + 1
    end
    best = best:gsub("^%s+", ""):gsub("%s+$", "")
    return #best >= 2 and best or nil
end

local BONUS_MARKERS = {}
local NON_ORDINARY_LOOT_MARKERS = {}
local ORDINARY_LOOT_MARKERS = {}

local function AddMarkers(target, names)
    for _, name in ipairs(names) do
        local marker = LongestStaticPart(_G[name])
        if marker then target[#target + 1] = marker end
    end
end

AddMarkers(BONUS_MARKERS, {
    "LOOT_ITEM_BONUS_ROLL",
    "LOOT_ITEM_BONUS_ROLL_SELF",
    "LOOT_ITEM_BONUS_ROLL_MULTIPLE",
    "LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE",
})

-- Pushed/secondary rewards are not ordinary dungeon drops.  They may include
-- Warband-bound bonus items and other personal rewards which cannot be traded
-- to the requester.  Keep them out of all automatic begging rules.
AddMarkers(NON_ORDINARY_LOOT_MARKERS, {
    "LOOT_ITEM_BONUS_ROLL",
    "LOOT_ITEM_BONUS_ROLL_SELF",
    "LOOT_ITEM_BONUS_ROLL_MULTIPLE",
    "LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE",
    "LOOT_ITEM_PUSHED",
    "LOOT_ITEM_PUSHED_MULTIPLE",
    "LOOT_ITEM_PUSHED_SELF",
    "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
    "LOOT_ITEM_CREATED_SELF",
    "LOOT_ITEM_CREATED_SELF_MULTIPLE",
    "LOOT_ITEM_REFUND",
    "LOOT_ITEM_REFUND_MULTIPLE",
    "LOOT_ITEM_WHILE_PLAYER_INELIGIBLE",
})

-- Only party-member messages that match Blizzard's ordinary loot format are
-- eligible for automatic requests. Bonus rolls and other personal rewards are
-- deliberately excluded.
AddMarkers(ORDINARY_LOOT_MARKERS, {
    "LOOT_ITEM",
    "LOOT_ITEM_MULTIPLE",
})

local function MatchesAnyMarker(text, markers)
    if not text or issecretvalue(text) then return false end
    for _, marker in ipairs(markers) do
        if text:find(marker, 1, true) then return true end
    end
    return false
end

local function IsBonusRollMessage(text)
    return MatchesAnyMarker(text, BONUS_MARKERS)
end

local function IsOrdinaryLootMessage(text)
    if #ORDINARY_LOOT_MARKERS == 0 then return false end
    if MatchesAnyMarker(text, NON_ORDINARY_LOOT_MARKERS) then return false end
    return MatchesAnyMarker(text, ORDINARY_LOOT_MARKERS)
end

local function IsAccountOrWarbandItemBind(bindType)
    if bindType == nil or issecretvalue(bindType) then return false end

    local itemBind = Enum and Enum.ItemBind
    if itemBind then
        if bindType == itemBind.ToWoWAccount
            or bindType == itemBind.ToBnetAccount
            or bindType == itemBind.ToBnetAccountUntilEquipped then
            return true
        end
    end

    -- Current Enum.ItemBind fallback values (11.0+):
    -- 7 = account, 8 = warband, 9 = warband until equipped.
    return bindType == 7 or bindType == 8 or bindType == 9
end

local function IsAccountOrWarbandTooltipBinding(bonding)
    if bonding == nil or issecretvalue(bonding) then return false end

    local binding = Enum and Enum.TooltipDataItemBinding
    if binding then
        if bonding == binding.Account
            or bonding == binding.BnetAccount
            or bonding == binding.BindToAccount
            or bonding == binding.BindToBnetAccount
            or bonding == binding.AccountUntilEquipped
            or bonding == binding.BindToAccountUntilEquipped then
            return true
        end
    end

    -- Current TooltipDataItemBinding fallback values:
    -- Account/Warband forms are 1, 2, 4, 5, 9 and 10.
    return bonding == 1 or bonding == 2 or bonding == 4 or bonding == 5
        or bonding == 9 or bonding == 10
end

local function IsWarbandOrAccountBound(itemLink)
    if not itemLink or issecretvalue(itemLink) then return false end

    -- Fast cached item-info path.  ProcessPartyLoot evaluates after
    -- ContinueOnItemLoad(), so this should normally be populated.
    if C_Item and C_Item.GetItemInfo then
        local _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = C_Item.GetItemInfo(itemLink)
        if IsAccountOrWarbandItemBind(bindType) then
            return true
        end
    end

    -- TooltipData is the second, independent check.  In 12.x the ItemBinding
    -- line exposes a bonding enum that explicitly distinguishes Warbound and
    -- Warbound-until-equipped from ordinary Bind-on-Pickup gear.
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, itemLink)
        if ok and type(data) == "table" and type(data.lines) == "table" then
            local bindingLineType = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemBinding or 20
            for _, line in ipairs(data.lines) do
                if type(line) == "table" then
                    local lineType = line.type
                    if lineType ~= nil and not issecretvalue(lineType) and lineType == bindingLineType then
                        if IsAccountOrWarbandTooltipBinding(line.bonding) then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

local function IsMythicPlusContext()
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then
        return true
    end
    if challengeActive then return true end
    if recentChallengeCompletedAt > 0 and (GetTime() - recentChallengeCompletedAt) <= 180 then
        return true
    end
    local _, instanceType, difficultyID = GetInstanceInfo()
    return instanceType == "party" and difficultyID == 8
end

local function NormalizeWhisperTarget(name)
    if not name or issecretvalue(name) then return nil end
    return name ~= "" and name or nil
end

local function SendRequest(playerName, itemLink, itemID, actualTrack)
    if not IsInGroup() or IsInRaid() then return end
    if not IsMythicPlusContext() then return end

    local target = NormalizeWhisperTarget(playerName)
    if not target or IsMe(target) then return end

    local key = target .. ":" .. tostring(itemID)
    local now = GetTime()
    if playerLastWhisper[key] and now - playerLastWhisper[key] < 60 then return end
    if not addon:SendWhisperSafely(target, itemLink, actualTrack, "mythicplus") then return end
    playerLastWhisper[key] = now
    addon:Print(string.format(L.WHISPER_SENT, target, itemLink, actualTrack and addon:GetTrackLabel(actualTrack) or L.UNKNOWN_TRACK))
end

-- ---------------------------------------------------------------------------
-- Mythic+ ordinary-upgrade evaluation
-- ---------------------------------------------------------------------------

local EQUIP_LOC_SLOTS = {
    INVTYPE_HEAD = { 1 },
    INVTYPE_NECK = { 2 },
    INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 },
    INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_SHIELD = { 17 },
    INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 16 },
    INVTYPE_RANGEDRIGHT = { 16 },
    INVTYPE_THROWN = { 16 },
}

local function GetCurrentSpecID()
    if not C_SpecializationInfo or not C_SpecializationInfo.GetSpecialization or not C_SpecializationInfo.GetSpecializationInfo then
        return nil
    end
    local specIndex = C_SpecializationInfo.GetSpecialization()
    if not specIndex or specIndex == 0 or issecretvalue(specIndex) then return nil end
    local specID = C_SpecializationInfo.GetSpecializationInfo(specIndex)
    if not specID or specID == 0 or issecretvalue(specID) then return nil end
    return specID
end

local function GetDesiredSpecIDs()
    local currentSpecID = GetCurrentSpecID()
    if not currentSpecID then return nil end

    local desired = { [currentSpecID] = true }
    if type(GetLootSpecialization) == "function" then
        local lootSpecID = GetLootSpecialization()
        if lootSpecID and lootSpecID ~= 0 and not issecretvalue(lootSpecID) then
            desired[lootSpecID] = true
        end
    end
    return desired
end

local function IsItemForDesiredSpecs(itemLink)
    if not itemLink or issecretvalue(itemLink) then return false end
    if not C_Item or not C_Item.GetItemSpecInfo then return false end

    local desired = GetDesiredSpecIDs()
    if not desired then return false end

    local ok, specs = pcall(C_Item.GetItemSpecInfo, itemLink)
    if not ok or type(specs) ~= "table" then return false end

    for _, specID in ipairs(specs) do
        if specID and not issecretvalue(specID) and desired[specID] then
            return true
        end
    end
    return false
end

local function GetDetailedItemLevel(itemLink)
    if not itemLink or issecretvalue(itemLink) then return nil end
    if not C_Item or not C_Item.GetDetailedItemLevelInfo then return nil end
    local ok, level = pcall(C_Item.GetDetailedItemLevelInfo, itemLink)
    if not ok or level == nil or issecretvalue(level) or type(level) ~= "number" then return nil end
    return level
end

local function GetEquipLoc(itemLink)
    if not itemLink or issecretvalue(itemLink) then return nil end
    if not C_Item or not C_Item.GetItemInfoInstant then return nil end
    local ok, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, itemLink)
    if not ok or not equipLoc or equipLoc == "" or issecretvalue(equipLoc) then return nil end
    return equipLoc
end

local function IsWeaponEquipLoc(equipLoc)
    return equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_WEAPONMAINHAND"
        or equipLoc == "INVTYPE_WEAPONOFFHAND"
        or equipLoc == "INVTYPE_2HWEAPON"
        or equipLoc == "INVTYPE_RANGED"
        or equipLoc == "INVTYPE_RANGEDRIGHT"
        or equipLoc == "INVTYPE_THROWN"
end

local function GetComparisonSlots(itemLink)
    local equipLoc = GetEquipLoc(itemLink)
    if not equipLoc then return nil end

    local mainLink = GetInventoryItemLink("player", 16)
    local mainLoc = mainLink and not issecretvalue(mainLink) and GetEquipLoc(mainLink) or nil

    -- An off-hand/shield cannot be equipped beside a currently equipped two-hand
    -- weapon. Without a compatible one-hand weapon already equipped, item-level
    -- comparison alone is too optimistic, so skip the automatic request.
    if equipLoc == "INVTYPE_WEAPONOFFHAND" or equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" then
        if mainLoc == "INVTYPE_2HWEAPON" then return nil end
        return { 17 }, equipLoc
    end

    -- Generic one-hand weapons can be used in either hand by dual-wield specs.
    -- If the player currently uses a two-hand weapon, compare only against that
    -- main-hand item; an empty off-hand is not a real free upgrade slot in that
    -- setup. Otherwise include the off-hand only when it is empty or already a
    -- weapon, so shields/held items are not treated as weapon replacement slots.
    if equipLoc == "INVTYPE_WEAPON" then
        local slots = { 16 }
        if mainLoc ~= "INVTYPE_2HWEAPON" then
            local offLink = GetInventoryItemLink("player", 17)
            if not offLink then
                slots[#slots + 1] = 17
            elseif not issecretvalue(offLink) then
                local offLoc = GetEquipLoc(offLink)
                if IsWeaponEquipLoc(offLoc) then
                    slots[#slots + 1] = 17
                end
            end
        end
        return slots, equipLoc
    end

    return EQUIP_LOC_SLOTS[equipLoc], equipLoc
end

local function GetEquippedItemLevel(slotID)
    local equippedLink = GetInventoryItemLink("player", slotID)
    if not equippedLink then
        -- An empty compatible slot is always an upgrade target.
        return 0
    end
    if issecretvalue(equippedLink) then return nil end
    return GetDetailedItemLevel(equippedLink)
end

local function IsItemLevelUpgrade(itemLink)
    if not itemLink or issecretvalue(itemLink) then return false, nil, nil end
    if C_Item and C_Item.IsEquippableItem then
        local ok, equippable = pcall(C_Item.IsEquippableItem, itemLink)
        if not ok or not equippable then return false, nil, nil end
    end

    local droppedLevel = GetDetailedItemLevel(itemLink)
    if not droppedLevel then return false, nil, nil end

    local slots = GetComparisonSlots(itemLink)
    if not slots or #slots == 0 then return false, droppedLevel, nil end

    local baseline
    for _, slotID in ipairs(slots) do
        local level = GetEquippedItemLevel(slotID)
        if level == nil then
            -- Fail closed if a protected/secret equipped item prevents a legal
            -- comparison. Do not guess and do not send a whisper.
            return false, droppedLevel, nil
        end
        if baseline == nil or level < baseline then baseline = level end
    end

    if baseline == nil then return false, droppedLevel, nil end
    return droppedLevel > baseline, droppedLevel, baseline
end

local function IsOrdinaryUpgradeRequest(itemLink)
    if not IsItemForDesiredSpecs(itemLink) then return false end
    local isUpgrade = IsItemLevelUpgrade(itemLink)
    return isUpgrade == true
end

local function ProcessPartyLoot(text, playerName, guid)
    if not addon.db then return end
    if not addon:GetAutoRule("mplusWatched") and not addon:GetAutoRule("mplusUpgrade") then return end
    if not text or issecretvalue(text) then return end
    if IsMe(playerName, guid) then return end
    if IsBonusRollMessage(text) then return end
    if not IsOrdinaryLootMessage(text) then return end
    if not IsMythicPlusContext() then return end

    local itemLink = ExtractItemLink(text)
    if not itemLink then return end
    local itemID = GetItemIDFromLink(itemLink)
    if not itemID then return end

    local item = Item and Item.CreateFromItemLink and Item:CreateFromItemLink(itemLink)
    local function Evaluate()
        -- Hard exclusion: account/Warband-bound rewards are personal rewards and
        -- cannot be traded to us.  This check runs before BOTH watched-item and
        -- item-level-upgrade automatic rules.
        if IsWarbandOrAccountBound(itemLink) then return end

        -- Rule A: watched Mythic+ items may auto-request regardless of equipped
        -- item level, but still honor the player's watched-quality threshold.
        local watch = addon:GetWatch(itemID)
        if watch and addon:GetAutoRule("mplusWatched") then
            local meets, actualTrack = addon:MeetsTrackRequirement(itemLink, watch.minTrack)
            if meets and (watch.minTrack <= addon.TRACK.ANY or actualTrack) then
                SendRequest(playerName, itemLink, itemID, actualTrack)
                return
            end
        end

        -- Rule B: independently, any spec-suitable item may auto-request when
        -- its actual item level is higher than the matching equipped slot.
        -- This remains available even for a watched item when Rule A is off or
        -- the watched-quality threshold was not met.
        if addon:GetAutoRule("mplusUpgrade") and IsOrdinaryUpgradeRequest(itemLink) then
            local actualTrack = addon:GetItemTrack(itemLink)
            SendRequest(playerName, itemLink, itemID, actualTrack)
        end
    end

    if item and item.ContinueOnItemLoad then
        item:ContinueOnItemLoad(Evaluate)
    else
        Evaluate()
    end
end

-- ---------------------------------------------------------------------------
-- Watched-item completion: own drop, bonus roll, or actual bag receipt/trade.
-- ---------------------------------------------------------------------------

local function ProcessOwnedItemLink(itemLink)
    if not addon.db or not itemLink or issecretvalue(itemLink) then return end
    local itemID = GetItemIDFromLink(itemLink)
    if not itemID then return end
    local entry = addon:GetWatch(itemID)
    if not entry then return end

    local item = Item and Item.CreateFromItemLink and Item:CreateFromItemLink(itemLink)
    local function Evaluate()
        local current = addon:GetWatch(itemID)
        if not current then return end
        local meets, actualTrack = addon:MeetsTrackRequirement(itemLink, current.minTrack)
        if current.minTrack > addon.TRACK.ANY and not actualTrack then return end
        if meets then
            addon:RemoveWatch(itemID, true)
            addon:Print(string.format(L.OBTAINED, itemLink))
        end
    end

    if item and item.ContinueOnItemLoad then
        item:ContinueOnItemLoad(Evaluate)
    else
        Evaluate()
    end
end

local function GetBagGUID(bag, slot)
    if not ItemLocation or not C_Item or not C_Item.GetItemGUID then return nil end
    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    return C_Item.GetItemGUID(location)
end

local function ForEachBagItem(callback)
    local maxBag = NUM_BAG_SLOTS or 4
    for bag = 0, maxBag do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and info.hyperlink then
                callback(bag, slot, info)
            end
        end
    end
end

function addon:SnapshotOwnedItemGUIDs(itemID)
    knownOwnedGUIDs[itemID] = {}
    ForEachBagItem(function(bag, slot, info)
        if info.itemID == itemID then
            local guid = GetBagGUID(bag, slot)
            if guid and not issecretvalue(guid) then
                knownOwnedGUIDs[itemID][guid] = true
            end
        end
    end)
end

function addon:ClearOwnedItemGUIDs(itemID)
    knownOwnedGUIDs[itemID] = nil
end

local function SnapshotAllWatchedItems()
    for itemID in pairs(addon.db.watchlist) do
        addon:SnapshotOwnedItemGUIDs(itemID)
    end
end

local function ProcessNewOwnedItems()
    if not addon.db then return end

    ForEachBagItem(function(bag, slot, info)
        local entry = addon:GetWatch(info.itemID)
        if not entry then return end

        knownOwnedGUIDs[info.itemID] = knownOwnedGUIDs[info.itemID] or {}
        local guid = GetBagGUID(bag, slot)
        if not guid or issecretvalue(guid) then return end
        if knownOwnedGUIDs[info.itemID][guid] then return end
        knownOwnedGUIDs[info.itemID][guid] = true

        local itemLink = info.hyperlink
        local item = Item and Item.CreateFromItemLink and Item:CreateFromItemLink(itemLink)
        local function Evaluate()
            local current = addon:GetWatch(info.itemID)
            if not current then return end
            local meets, actualTrack = addon:MeetsTrackRequirement(itemLink, current.minTrack)
            if current.minTrack > addon.TRACK.ANY and not actualTrack then return end
            if meets then
                local display = itemLink or current.itemLink or current.itemName or ("item:" .. info.itemID)
                addon:RemoveWatch(info.itemID, true)
                addon:Print(string.format(L.OBTAINED, display))
            end
        end

        if item and item.ContinueOnItemLoad then
            item:ContinueOnItemLoad(Evaluate)
        else
            Evaluate()
        end
    end)
end

function addon:InitLootMonitor()
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
    eventFrame:RegisterEvent("BONUS_ROLL_RESULT")
    eventFrame:RegisterEvent("CHALLENGE_MODE_START")
    eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    eventFrame:RegisterEvent("CHALLENGE_MODE_RESET")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

    SnapshotAllWatchedItems()

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_LOOT" then
            local text, playerName = ...
            local guid = select(12, ...)
            ProcessPartyLoot(text, playerName, guid)
        elseif event == "BAG_UPDATE_DELAYED" then
            ProcessNewOwnedItems()
        elseif event == "BONUS_ROLL_RESULT" then
            local _, itemLink = ...
            ProcessOwnedItemLink(itemLink)
        elseif event == "CHALLENGE_MODE_START" then
            challengeActive = true
            recentChallengeCompletedAt = 0
        elseif event == "CHALLENGE_MODE_COMPLETED" then
            challengeActive = false
            recentChallengeCompletedAt = GetTime()
        elseif event == "CHALLENGE_MODE_RESET" then
            challengeActive = false
            recentChallengeCompletedAt = 0
        elseif event == "PLAYER_ENTERING_WORLD" then
            challengeActive = C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() or false
            C_Timer.After(1, SnapshotAllWatchedItems)
        end
    end)
end

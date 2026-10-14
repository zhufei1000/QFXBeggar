-- Reuse the 12.1.5 chat contract regression against this repository's runtime.
local function noop() end
local blocked, locked, sent = false, false, 0
issecretvalue = function(value) return type(value) == "table" and value.secret == true end
C_SocialRestrictions = { CanSendChat = function() return not blocked end }
C_ChatInfo = {
    InChatMessagingLockdown = function() return locked end,
    SendChatMessage = function() sent = sent + 1 end,
}
CreateFrame = function() return { RegisterEvent = noop, SetScript = noop } end
SlashCmdList = {}
strtrim = function(text) return text:match("^%s*(.-)%s*$") end
local addon = { L = {} }
assert(loadfile("Core.lua"))("QFXBeggar", addon)
addon.FormatWhisperMessage = function() return "message" end
blocked = true
assert(not addon:SendWhisperSafely("Tester") and sent == 0)
blocked, locked = false, true
assert(not addon:SendWhisperSafely("Tester") and sent == 0)
locked = false
assert(addon:SendWhisperSafely("Tester") and sent == 1)
assert(not addon:SendWhisperSafely({ secret = true }) and sent == 1)
local calls = 0
C_ChatInfo.SendChatMessage = function()
    calls = calls + 1
    if calls == 1 then error("invalid hyperlink") end
end
assert(addon:SendWhisperSafely("Tester") and calls == 2)
C_SocialRestrictions.CanSendChat = function() error("unavailable") end
assert(not addon:SendWhisperSafely("Tester") and calls == 2)
print("Chat restrictions, secret target and plain-text retry regression passed")

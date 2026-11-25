-- luacheck: catches stray globals, typos and unused code. Run: luacheck IssuesWithTissues
std = "lua51"
max_line_length = false
ignore = { "212" } -- unused arguments (event handlers get more than they use)
exclude_files = { "tests" }

-- Globals the addon defines.
globals = {
	"IwTDB", "IwTCharDB", "IssuesWithTissues", "IssuesWithTissues_Toggle", "IssuesWithTissues_Chat",
	"SLASH_ISSUESWITHTISSUES1", "SLASH_ISSUESWITHTISSUES2",
	"BINDING_HEADER_ISSUESWITHTISSUES", "BINDING_NAME_IWT_TOGGLE", "BINDING_NAME_IWT_CHAT",
	SlashCmdList = { fields = { "ISSUESWITHTISSUES" } },
	StaticPopupDialogs = { other_fields = true },
}

-- The game's API, as far as the addon uses it.
read_globals = {
	"issecretvalue", "UnitIsAFK",
	"GetQuestLogTitle", "GetNumQuestLogEntries", "GetQuestTagInfo", "GetRealZoneText", "UnitLevel", "QUESTS_DISPLAYED", "QuestLog_Update",
	"GetBindingAction", "GetBindingKey", "GetCurrentBindingSet", "SaveBindings", "SetBinding",
	"ERR_GUILD_JOIN_S", "IsInInstance", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2", "TooltipDataProcessor",
	"CanGuildDemote", "CanGuildPromote", "CanGuildRemove", "GuildDemote", "GuildPromote",
	"C_ChatInfo", "C_QuestLog", "IsQuestFlaggedCompleted", "GetItemCount", "GetNumSavedInstances", "GetSavedInstanceInfo", "RequestRaidInfo", "C_Club", "C_Item", "C_Spell", "GetSpellInfo", "C_GuildInfo", "C_PartyInfo", "C_Timer", "C_TradeSkillUI", "Enum", "Settings", "SOUNDKIT",
	"ChatEdit_InsertLink", "ChatFontNormal", "ChatFrame_OpenChat", "ChatFrame_SendTell", "ChatTypeInfo",
	"CreateFrame", "DEFAULT_CHAT_FRAME", "DepositGuildBankMoney", "ERR_FRIEND_OFFLINE_S", "ERR_FRIEND_ONLINE_SS",
	"GameTooltip", "GetAddOnMemoryUsage", "GetBuildInfo", "GetCraftDisplaySkillLine", "GetCraftInfo",
	"GetCraftItemLink", "GetCursorPosition", "GetGuildBankMoney", "GetGuildInfo", "GetGuildRosterInfo",
	"GetGuildRosterLastOnline", "GetGuildRosterMOTD", "GetItemInfo", "GetLocale", "GetMinimapShape",
	"GetNormalizedRealmName", "GetNumCrafts", "GetNumGuildMembers", "GetNumSkillLines", "GetNumTradeSkills",
	"GetPVPLifetimeStats", "GetPVPThisWeekStats", "C_DateAndTime", "IsAltKeyDown", "HandleModifiedItemClick", "GetPlayerInfoByGUID", "GetProfessionInfo", "GetProfessions", "GetServerTime",
	"GetSkillLineInfo", "GetStatistic", "GetTime", "GetTradeSkillInfo", "GetTradeSkillItemLink", "GetTradeSkillLine",
	"GuildControlGetNumRanks", "GuildControlGetRankName", "GuildRoster", "HideUIPanel", "ITEM_QUALITY_COLORS",
	"InCombatLockdown", "InterfaceOptions_AddCategory", "InviteUnit", "IsControlKeyDown", "IsInGuild",
	"IsShiftKeyDown", "IsTradeSkillLinked", "Minimap", "NO", "YES", "PlaySound", "RAID_CLASS_COLORS",
	"RegisterAddonMessagePrefix", "ReloadUI", "SendAddonMessage", "SendChatMessage", "SetItemRef",
	"StaticPopup_Show", "ToggleFriendsFrame", "ToggleGuildFrame", "ToggleProfessionsBook", "UIParent",
	"UISpecialFrames", "UnitFactionGroup", "UnitFullName", "UnitGUID", "UnitName", "UpdateAddOnMemoryUsage",
	"date", "time", "debugprofilestop", "debugstack", "geterrorhandler", "seterrorhandler", "hooksecurefunc",
	"tinsert", "wipe", "TRADE_SKILLS", "SECONDARY_SKILLS",
}
